//
//  FDAudioManager.h
//  FFmpegDemo
//
//  Created by chengshun on 2018/6/27.
//  Copyright © 2018年 shuncheng. All rights reserved.
//

#import <Foundation/Foundation.h>

typedef void(^FDAudioManagerOutputBlock)(float *data, UInt32 numFrames, UInt32 numChannels);

@interface FDAudioManager : NSObject

@property (nonatomic, copy) FDAudioManagerOutputBlock outputBlock;

+ (instancetype)sharedInstance;

- (BOOL)activateAudioSession;

@property (nonatomic, assign) Float32 outputVolume;
@property (nonatomic, assign) UInt32 numOutputChannels;
@property (nonatomic, assign) UInt32 numBytesPerSample;
@property (nonatomic, assign) Float64 samplingRate;

- (BOOL)play;

@end
