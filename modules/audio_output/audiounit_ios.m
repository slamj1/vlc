/*****************************************************************************
 * audiounit_ios.m: AudioUnit output plugin for iOS
 *****************************************************************************
 * Copyright (C) 2012 - 2017 VLC authors and VideoLAN
 *
 * Authors: Felix Paul Kühne <fkuehne at videolan dot org>
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin Street, Fifth Floor, Boston MA 02110-1301, USA.
 *****************************************************************************/

#pragma mark includes

#import "coreaudio_common.h"

#import <vlc_plugin.h>
#import <vlc_memory.h>

#import <CoreAudio/CoreAudioTypes.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <mach/mach_time.h>

#pragma mark -
#pragma mark local prototypes & module descriptor

static int  Open  (vlc_object_t *);
static void Close (vlc_object_t *);

vlc_module_begin ()
    set_shortname("audiounit_ios")
    set_description("AudioUnit output for iOS")
    set_capability("audio output", 101)
    set_category(CAT_AUDIO)
    set_subcategory(SUBCAT_AUDIO_AOUT)
    set_callbacks(Open, Close)
vlc_module_end ()

#pragma mark -
#pragma mark private declarations

/* aout wrapper: used as observer for notifications */
@interface AoutWrapper : NSObject
- (instancetype)initWithAout:(audio_output_t *)aout;
@property (readonly, assign) audio_output_t* aout;
@end

/*****************************************************************************
 * aout_sys_t: private audio output method descriptor
 *****************************************************************************
 * This structure is part of the audio output thread descriptor.
 * It describes the CoreAudio specific properties of an output thread.
 *****************************************************************************/
struct aout_sys_t
{
    struct aout_sys_common c;

    AVAudioSession *avInstance;
    AoutWrapper *aoutWrapper;
    /* The AudioUnit we use */
    AudioUnit au_unit;
    bool      b_muted;
};

enum dev_type {
    DEV_TYPE_DEFAULT,
    DEV_TYPE_USB,
    DEV_TYPE_HDMI
};

#pragma mark -
#pragma mark AVAudioSession route and output handling

@implementation AoutWrapper

- (instancetype)initWithAout:(audio_output_t *)aout
{
    self = [super init];
    if (self)
        _aout = aout;
    return self;
}

- (void)audioSessionRouteChange:(NSNotification *)notification
{
    audio_output_t *p_aout = [self aout];
    NSDictionary *userInfo = notification.userInfo;
    NSInteger routeChangeReason =
        [[userInfo valueForKey:AVAudioSessionRouteChangeReasonKey] integerValue];

    msg_Dbg(p_aout, "Audio route changed: %ld", (long) routeChangeReason);

    if (routeChangeReason == AVAudioSessionRouteChangeReasonNewDeviceAvailable
     || routeChangeReason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable)
        aout_RestartRequest(p_aout, AOUT_RESTART_OUTPUT);
}

@end

static int
avas_GetOptimalChannelLayout(audio_output_t *p_aout, unsigned channel_count,
                             enum dev_type *pdev_type,
                             AudioChannelLayout **playout)
{
    struct aout_sys_t * p_sys = p_aout->sys;
    AVAudioSession *instance = p_sys->avInstance;
    AudioChannelLayout *layout = NULL;
    *pdev_type = DEV_TYPE_DEFAULT;
    NSInteger max_channel_count = [instance maximumOutputNumberOfChannels];

    /* Increase the preferred number of output channels if possible */
    if (channel_count > 2 && max_channel_count > 2)
    {
        channel_count = __MIN(channel_count, max_channel_count);
        bool success = [instance setPreferredOutputNumberOfChannels:channel_count
                        error:nil];
        if (!success || [instance outputNumberOfChannels] != channel_count)
        {
            /* Not critical, output channels layout will be Stereo */
            msg_Warn(p_aout, "setPreferredOutputNumberOfChannels failed");
        }
    }

    long last_channel_count = 0;
    for (AVAudioSessionPortDescription *out in [[instance currentRoute] outputs])
    {
        /* Choose the layout with the biggest number of channels or the HDMI
         * one */

        enum dev_type dev_type;
        if ([out.portType isEqualToString: AVAudioSessionPortUSBAudio])
            dev_type = DEV_TYPE_USB;
        else if ([out.portType isEqualToString: AVAudioSessionPortHDMI])
            dev_type = DEV_TYPE_HDMI;
        else
            dev_type = DEV_TYPE_DEFAULT;

        NSArray<AVAudioSessionChannelDescription *> *chans = [out channels];

        if (chans.count > last_channel_count || dev_type == DEV_TYPE_HDMI)
        {
            /* We don't need a layout specification for stereo */
            if (chans.count > 2)
            {
                bool labels_valid = false;
                for (AVAudioSessionChannelDescription *chan in chans)
                {
                    if ([chan channelLabel] != kAudioChannelLabel_Unknown)
                    {
                        labels_valid = true;
                        break;
                    }
                }
                if (!labels_valid)
                {
                    /* TODO: Guess labels ? */
                    msg_Warn(p_aout, "no valid channel labels");
                    continue;
                }
                assert(max_channel_count >= chans.count);

                if (layout == NULL
                 || layout->mNumberChannelDescriptions < chans.count)
                {
                    const size_t layout_size = sizeof(AudioChannelLayout)
                        + chans.count * sizeof(AudioChannelDescription);
                    layout = realloc_or_free(layout, layout_size);
                    if (layout == NULL)
                        return VLC_ENOMEM;
                }

                layout->mChannelLayoutTag =
                    kAudioChannelLayoutTag_UseChannelDescriptions;
                layout->mNumberChannelDescriptions = chans.count;

                unsigned i = 0;
                for (AVAudioSessionChannelDescription *chan in chans)
                    layout->mChannelDescriptions[i++].mChannelLabel
                        = [chan channelLabel];

                last_channel_count = chans.count;
            }
            *pdev_type = dev_type;
        }

        if (dev_type == DEV_TYPE_HDMI) /* Prefer HDMI */
            break;
    }

    msg_Dbg(p_aout, "Output on %s, channel count: %u",
            *pdev_type == DEV_TYPE_HDMI ? "HDMI" :
            *pdev_type == DEV_TYPE_USB ? "USB" : "Default",
            layout ? layout->mNumberChannelDescriptions : 2);

    *playout = layout;
    return VLC_SUCCESS;
}

static int
avas_SetActive(audio_output_t *p_aout, bool active, NSUInteger options)
{
    struct aout_sys_t * p_sys = p_aout->sys;
    AVAudioSession *instance = p_sys->avInstance;
    BOOL ret = false;
    NSError *error = nil;

    if (active)
    {
        ret = [instance setCategory:AVAudioSessionCategoryPlayback error:&error];
        ret = ret && [instance setMode:AVAudioSessionModeMoviePlayback error:&error];
        ret = ret && [instance setActive:YES withOptions:options error:&error];
    }
    else
        ret = [instance setActive:NO withOptions:options error:&error];

    if (!ret)
    {
        msg_Err(p_aout, "AVAudioSession playback change failed: %s(%d)",
                error.domain.UTF8String, (int)error.code);
        return VLC_EGENERIC;
    }

    return VLC_SUCCESS;
}

#pragma mark -
#pragma mark actual playback

static void
Pause (audio_output_t *p_aout, bool pause, mtime_t date)
{
    struct aout_sys_t * p_sys = p_aout->sys;

    /* We need to start / stop the audio unit here because otherwise the OS
     * won't believe us that we stopped the audio output so in case of an
     * interruption, our unit would be permanently silenced. In case of
     * multi-tasking, the multi-tasking view would still show a playing state
     * despite we are paused, same for lock screen */

    OSStatus err;
    if (pause)
    {
        err = AudioOutputUnitStop(p_sys->au_unit);
        if (err != noErr)
            msg_Err(p_aout, "AudioOutputUnitStart failed [%4.4s]",
                    (const char *) &err);
        avas_SetActive(p_aout, false, 0);
    }
    else
    {
        if (avas_SetActive(p_aout, true, 0) == VLC_SUCCESS)
        {
            err = AudioOutputUnitStart(p_sys->au_unit);
            if (err != noErr)
            {
                msg_Err(p_aout, "AudioOutputUnitStart failed [%4.4s]",
                        (const char *) &err);
                /* Do not un-pause, the Render Callback won't run, and next call
                 * of ca_Play will deadlock */
                return;
            }
        }
    }
    ca_Pause(p_aout, pause, date);
}

static int
MuteSet(audio_output_t *p_aout, bool mute)
{
    struct aout_sys_t * p_sys = p_aout->sys;

    p_sys->b_muted = mute;
    if (p_sys->au_unit != NULL)
    {
        Pause(p_aout, mute, 0);
        if (mute)
            ca_Flush(p_aout, false);
    }

    return VLC_SUCCESS;
}

static void
Play(audio_output_t * p_aout, block_t * p_block)
{
    struct aout_sys_t * p_sys = p_aout->sys;

    if (p_sys->b_muted)
        block_Release(p_block);
    else
        ca_Play(p_aout, p_block);
}

#pragma mark initialization

static void
Stop(audio_output_t *p_aout)
{
    struct aout_sys_t   *p_sys = p_aout->sys;
    OSStatus err;

    err = AudioOutputUnitStop(p_sys->au_unit);
    if (err != noErr)
        msg_Warn(p_aout, "AudioOutputUnitStop failed [%4.4s]",
                 (const char *)&err);

    au_Uninitialize(p_aout, p_sys->au_unit);

    err = AudioComponentInstanceDispose(p_sys->au_unit);
    if (err != noErr)
        msg_Warn(p_aout, "AudioComponentInstanceDispose failed [%4.4s]",
                 (const char *)&err);

    avas_SetActive(p_aout, false,
                   AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation);
}

static int
Start(audio_output_t *p_aout, audio_sample_format_t *restrict fmt)
{
    struct aout_sys_t *p_sys = p_aout->sys;
    OSStatus err;
    OSStatus status;
    AudioChannelLayout *layout = NULL;

    if (aout_FormatNbChannels(fmt) == 0
     || aout_BitsPerSample(fmt->i_format) == 0 /* No Passthrough support */)
        return VLC_EGENERIC;

    aout_FormatPrint(p_aout, "VLC is looking for:", fmt);

    p_sys->au_unit = NULL;

    fmt->i_format = VLC_CODEC_FL32;

    /* Activate the AVAudioSession */
    if (avas_SetActive(p_aout, true, 0) != VLC_SUCCESS)
        return VLC_EGENERIC;

    p_sys->au_unit = au_NewOutputInstance(p_aout, kAudioUnitSubType_RemoteIO);
    if (p_sys->au_unit == NULL)
        goto error;

    err = AudioUnitSetProperty(p_sys->au_unit,
                               kAudioOutputUnitProperty_EnableIO,
                               kAudioUnitScope_Output, 0,
                               &(UInt32){ 1 }, sizeof(UInt32));
    if (err != noErr)
        msg_Warn(p_aout, "failed to set IO mode [%4.4s]", (const char *)&err);

    enum dev_type dev_type;
    int ret = avas_GetOptimalChannelLayout(p_aout, aout_FormatNbChannels(fmt),
                                           &dev_type, &layout);
    if (ret != VLC_SUCCESS)
        goto error;

    /* TODO: Do passthrough if dev_type allows it */

    ret = au_Initialize(p_aout, p_sys->au_unit, fmt, layout,
                        [p_sys->avInstance outputLatency] * CLOCK_FREQ);
    if (ret != VLC_SUCCESS)
        goto error;

    p_aout->play = Play;

    err = AudioOutputUnitStart(p_sys->au_unit);
    if (err != noErr)
    {
        msg_Err(p_aout, "AudioOutputUnitStart failed [%4.4s]",
                (const char *) &err);
        au_Uninitialize(p_aout, p_sys->au_unit);
        goto error;
    }

    if (p_sys->b_muted)
        Pause(p_aout, true, 0);

    [[NSNotificationCenter defaultCenter] addObserver:p_sys->aoutWrapper
           selector:@selector(audioSessionRouteChange:)
           name:AVAudioSessionRouteChangeNotification object:nil];

    free(layout);
    p_aout->mute_set  = MuteSet;
    p_aout->pause = Pause;
    msg_Dbg(p_aout, "analog AudioUnit output successfully opened");
    return VLC_SUCCESS;

error:
    free(layout);
    avas_SetActive(p_aout, false,
                   AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation);
    AudioComponentInstanceDispose(p_sys->au_unit);
    msg_Err(p_aout, "opening AudioUnit output failed");
    return VLC_EGENERIC;
}

static void
Close(vlc_object_t *obj)
{
    audio_output_t *aout = (audio_output_t *)obj;
    aout_sys_t *sys = aout->sys;

    [sys->aoutWrapper release];

    free(sys);
}

static int
Open(vlc_object_t *obj)
{
    audio_output_t *aout = (audio_output_t *)obj;
    aout_sys_t *sys = calloc(1, sizeof (*sys));

    if (unlikely(sys == NULL))
        return VLC_ENOMEM;

    sys->avInstance = [AVAudioSession sharedInstance];
    assert(sys->avInstance != NULL);

    sys->aoutWrapper = [[AoutWrapper alloc] initWithAout:aout];
    if (sys->aoutWrapper == NULL)
    {
        free(sys);
        return VLC_ENOMEM;
    }

    sys->b_muted = false;
    aout->sys = sys;
    aout->start = Start;
    aout->stop = Stop;

    return VLC_SUCCESS;
}
