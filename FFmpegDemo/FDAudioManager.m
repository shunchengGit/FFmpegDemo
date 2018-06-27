//
//  FDAudioManager.m
//  FFmpegDemo
//
//  Created by chengshun on 2018/6/27.
//  Copyright © 2018年 shuncheng. All rights reserved.
//

#import "FDAudioManager.h"

#import <AudioToolbox/AudioToolbox.h>
#import <Accelerate/Accelerate.h>

static const NSInteger kMaxFrameSize = 4096;
static const NSInteger kMaxChannel = 2;

static BOOL checkError(OSStatus error, const char *operation);
static void sessionPropertyListener(void *inClientData, AudioSessionPropertyID inID, UInt32 inDataSize, const void *inData);
static void sessionInterruptionListener(void *inClientData, UInt32 inInterruption);
static OSStatus renderCallback (void *inRefCon, AudioUnitRenderActionFlags    *ioActionFlags, const AudioTimeStamp * inTimeStamp, UInt32 inOutputBusNumber, UInt32 inNumberFrames, AudioBufferList* ioData);

static BOOL checkErrorWithLog(OSStatus status, NSString *logString)
{
    if (status == noErr) {
        return NO;
    } else {
        NSLog(@"%@", logString);
        return YES;
    }
}

@interface FDAudioManager ()

@property (nonatomic, assign) BOOL activated;
@property (nonatomic, assign) BOOL initialized;
@property (nonatomic, assign) BOOL playing;
@property (nonatomic, assign) AudioUnit audioUnit;
@property (nonatomic, strong) NSString *audioRoute;


@property (nonatomic, assign) AudioStreamBasicDescription outputFormat;

@property (nonatomic, assign) float *outData;


@end

@implementation FDAudioManager

+ (instancetype)sharedInstance
{
    static FDAudioManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[FDAudioManager alloc] init];
    });
    return instance;
}

- (instancetype)init
{
    if (self = [super init]) {
        _outData = (float *)calloc(kMaxChannel * kMaxFrameSize, sizeof(float));
        _outputVolume = 0.5;
    }
    return self;
}

- (void)dealloc
{
    if (_outData) {
        free(_outData);
        _outData = NULL;
    }
}

- (BOOL)activateAudioSession
{
    if (self.activated) {
        return self.activated;
    }
    
    if (!self.initialized) {
        if (checkErrorWithLog(AudioSessionInitialize(NULL, kCFRunLoopDefaultMode, sessionInterruptionListener, (__bridge void *)(self)), @"Couldn't initialize audio session")) {
            return  NO;
        } else {
            self.initialized = YES;
        }
    }
    
    if ([self checkAudioRoute] && [self setupAudio]) {
        self.activated = YES;
    }
    
    return self.activated;
}

- (BOOL)play
{
    if (!self.playing) {
        self.playing = !checkErrorWithLog(AudioOutputUnitStart(self.audioUnit),
                                          @"Couldn't start the output unit");
    }
    return self.playing;
}

- (BOOL)setupAudio
{
    // --- Audio Session Setup ---
    
    UInt32 sessionCategory = kAudioSessionCategory_MediaPlayback;
    //UInt32 sessionCategory = kAudioSessionCategory_PlayAndRecord;
    if (checkErrorWithLog(AudioSessionSetProperty(kAudioSessionProperty_AudioCategory,
                                                  sizeof(sessionCategory),
                                                  &sessionCategory),
                          @"Couldn't set audio category"))
        return NO;
    
    
    if (checkErrorWithLog(AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange,
                                                          sessionPropertyListener,
                                                          (__bridge void *)(self)),
                          @"Couldn't add audio session property listener"))
    {
        // just warning
    }
    
    if (checkErrorWithLog(AudioSessionAddPropertyListener(kAudioSessionProperty_CurrentHardwareOutputVolume,
                                                          sessionPropertyListener,
                                                          (__bridge void *)(self)),
                          @"Couldn't add audio session property listener"))
    {
        // just warning
    }
    
#if !TARGET_IPHONE_SIMULATOR
    Float32 preferredBufferSize = 0.0232;
    if (checkErrorWithLog(AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration,
                                           sizeof(preferredBufferSize),
                                           &preferredBufferSize),
                          @"Couldn't set the preferred buffer duration")) {
        
        // just warning
    }
#endif
    
    if (checkErrorWithLog(AudioSessionSetActive(YES),
                          @"Couldn't activate the audio session")) {
        return NO;
    }
    
    [self checkSessionProperties];
    
    // ----- Audio Unit Setup -----
    
    // Describe the output unit.
    
    AudioComponentDescription description = {0};
    description.componentType = kAudioUnitType_Output;
    description.componentSubType = kAudioUnitSubType_RemoteIO;
    description.componentManufacturer = kAudioUnitManufacturer_Apple;
    
    // Get component
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    if (checkErrorWithLog(AudioComponentInstanceNew(component, &_audioUnit),
                          @"Couldn't create the output audio unit"))
        return NO;
    
    UInt32 size;
    
    // Check the output stream format
    size = sizeof(AudioStreamBasicDescription);
    if (checkErrorWithLog(AudioUnitGetProperty(_audioUnit,
                                        kAudioUnitProperty_StreamFormat,
                                        kAudioUnitScope_Input,
                                        0,
                                        &_outputFormat,
                                        &size),
                   @"Couldn't get the hardware output stream format"))
        return NO;
    
    
    _outputFormat.mSampleRate = _samplingRate;
    if (checkErrorWithLog(AudioUnitSetProperty(_audioUnit,
                                        kAudioUnitProperty_StreamFormat,
                                        kAudioUnitScope_Input,
                                        0,
                                        &_outputFormat,
                                        size),
                   @"Couldn't set the hardware output stream format")) {
        
        // just warning
    }
    
    self.numBytesPerSample = self.outputFormat.mBitsPerChannel / 8;
    self.numOutputChannels = self.outputFormat.mChannelsPerFrame;
    
    // Slap a render callback on the unit
    AURenderCallbackStruct callbackStruct;
    callbackStruct.inputProc = renderCallback;
    callbackStruct.inputProcRefCon = (__bridge void *)(self);
    
    if (checkErrorWithLog(AudioUnitSetProperty(_audioUnit,
                                               kAudioUnitProperty_SetRenderCallback,
                                               kAudioUnitScope_Input,
                                               0,
                                               &callbackStruct,
                                               sizeof(callbackStruct)),
                          @"Couldn't set the render callback on the audio unit"))
        return NO;
    
    if (checkErrorWithLog(AudioUnitInitialize(_audioUnit),
                          @"Couldn't initialize the audio unit"))
        return NO;
    
    return YES;
}

- (BOOL)checkSessionProperties
{
    [self checkAudioRoute];
    
    // Check the number of output channels.
    UInt32 newNumChannels;
    UInt32 size = sizeof(newNumChannels);
    if (checkErrorWithLog(AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareOutputNumberChannels,
                                           &size,
                                           &newNumChannels),
                   @"Checking number of output channels"))
        return NO;
    
//    LoggerAudio(2, @"We've got %lu output channels", newNumChannels);
    
    // Get the hardware sampling rate. This is settable, but here we're only reading.
    size = sizeof(_samplingRate);
    if (checkErrorWithLog(AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareSampleRate,
                                           &size,
                                           &_samplingRate),
                   @"Checking hardware sampling rate"))
        
        return NO;
    
//    LoggerAudio(2, @"Current sampling rate: %f", _samplingRate);
    
    size = sizeof(_outputVolume);
    if (checkErrorWithLog(AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareOutputVolume,
                                           &size,
                                           &_outputVolume),
                   @"Checking current hardware output volume"))
        return NO;
    
//    LoggerAudio(1, @"Current output volume: %f", _outputVolume);
    
    return YES;
}

- (BOOL)renderFrames:(UInt32)numFrames
              ioData:(AudioBufferList *)ioData
{
    for (int iBuffer=0; iBuffer < ioData->mNumberBuffers; ++iBuffer) {
        memset(ioData->mBuffers[iBuffer].mData, 0, ioData->mBuffers[iBuffer].mDataByteSize);
    }
    
    if (_playing && _outputBlock) {
        
        // Collect data to render from the callbacks
        _outputBlock(_outData, numFrames, _numOutputChannels);
        
        // Put the rendered data into the output buffer
        if (_numBytesPerSample == 4) // then we've already got floats
        {
            float zero = 0.0;
            
            for (int iBuffer=0; iBuffer < ioData->mNumberBuffers; ++iBuffer) {
                
                int thisNumChannels = ioData->mBuffers[iBuffer].mNumberChannels;
                
                for (int iChannel = 0; iChannel < thisNumChannels; ++iChannel) {
                    vDSP_vsadd(_outData+iChannel, _numOutputChannels, &zero, (float *)ioData->mBuffers[iBuffer].mData, thisNumChannels, numFrames);
                }
            }
        }
        else if (_numBytesPerSample == 2) // then we need to convert SInt16 -> Float (and also scale)
        {
            //            dumpAudioSamples(@"Audio frames decoded by FFmpeg:\n",
            //                             _outData, @"% 12.4f ", numFrames, _numOutputChannels);
            
            float scale = (float)INT16_MAX;
            vDSP_vsmul(_outData, 1, &scale, _outData, 1, numFrames*_numOutputChannels);
            
#ifdef DUMP_AUDIO_DATA
            LoggerAudio(2, @"Buffer %u - Output Channels %u - Samples %u",
                        (uint)ioData->mNumberBuffers, (uint)ioData->mBuffers[0].mNumberChannels, (uint)numFrames);
#endif
            
            for (int iBuffer=0; iBuffer < ioData->mNumberBuffers; ++iBuffer) {
                
                int thisNumChannels = ioData->mBuffers[iBuffer].mNumberChannels;
                
                for (int iChannel = 0; iChannel < thisNumChannels; ++iChannel) {
                    vDSP_vfix16(_outData+iChannel, _numOutputChannels, (SInt16 *)ioData->mBuffers[iBuffer].mData+iChannel, thisNumChannels, numFrames);
                }
#ifdef DUMP_AUDIO_DATA
                dumpAudioSamples(@"Audio frames decoded by FFmpeg and reformatted:\n",
                                 ((SInt16 *)ioData->mBuffers[iBuffer].mData),
                                 @"% 8d ", numFrames, thisNumChannels);
#endif
            }
            
        }
    }
    
    return noErr;
}

- (BOOL)checkAudioRoute
{
    // Check what the audio route is.
    UInt32 propertySize = sizeof(CFStringRef);
    CFStringRef route;
    if (checkErrorWithLog(AudioSessionGetProperty(kAudioSessionProperty_AudioRoute,
                                           &propertySize,
                                           &route),
                   @"Couldn't check the audio route"))
        return NO;
    
    self.audioRoute = CFBridgingRelease(route);
    return YES;
}

@end

#pragma mark - callbacks

static void sessionInterruptionListener(void *inClientData, UInt32 inInterruption)
{
    FDAudioManager *sm = (__bridge FDAudioManager *)inClientData;
    
    if (inInterruption == kAudioSessionBeginInterruption) {
        
        //        LoggerAudio(2, @"Begin interuption");
        //        sm.playAfterSessionEndInterruption = sm.playing;
        //        [sm pause];
        
    } else if (inInterruption == kAudioSessionEndInterruption) {
        
        //        LoggerAudio(2, @"End interuption");
        //        if (sm.playAfterSessionEndInterruption) {
        //            sm.playAfterSessionEndInterruption = NO;
        //            [sm play];
        //        }
    }
}

static void sessionPropertyListener(void *                  inClientData,
                                    AudioSessionPropertyID  inID,
                                    UInt32                  inDataSize,
                                    const void *            inData)
{
    FDAudioManager *sm = (__bridge FDAudioManager *)inClientData;
    
    if (inID == kAudioSessionProperty_AudioRouteChange) {
        
        //        if ([sm checkAudioRoute]) {
        //            [sm checkSessionProperties];
        //        }
        
    } else if (inID == kAudioSessionProperty_CurrentHardwareOutputVolume) {
        
        if (inData && inDataSize == 4) {
            
            sm.outputVolume = *(float *)inData;
        }
    }
}

static OSStatus renderCallback (void                        *inRefCon,
                                AudioUnitRenderActionFlags    * ioActionFlags,
                                const AudioTimeStamp         * inTimeStamp,
                                UInt32                        inOutputBusNumber,
                                UInt32                        inNumberFrames,
                                AudioBufferList                * ioData)
{
    FDAudioManager *sm = (__bridge FDAudioManager *)inRefCon;
    return [sm renderFrames:inNumberFrames ioData:ioData];
}

