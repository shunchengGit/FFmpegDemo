//
//  ViewController.m
//  FFmpegDemo
//
//  Created by chengshun on 2018/6/14.
//  Copyright © 2018年 chengshun. All rights reserved.
//

#import "ViewController.h"
#include <libavformat/avformat.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>
#import <Accelerate/Accelerate.h>

#import "FDAudioManager.h"

static BOOL audioCodecIsSupported(AVCodecContext *audio)
{
    if (audio->sample_fmt == AV_SAMPLE_FMT_S16) {
        
        FDAudioManager *audioManager = [FDAudioManager sharedInstance];
        return  (int)audioManager.samplingRate == audio->sample_rate &&
        audioManager.numOutputChannels == audio->channels;
    }
    return NO;
}


static void avStreamFPSTimeBase(AVStream *st, CGFloat defaultTimeBase, CGFloat *pFPS, CGFloat *pTimeBase)
{
    CGFloat fps, timebase;
    
    if (st->time_base.den && st->time_base.num)
        timebase = av_q2d(st->time_base);
    else if(st->codec->time_base.den && st->codec->time_base.num)
        timebase = av_q2d(st->codec->time_base);
    else
        timebase = defaultTimeBase;
    
    if (st->codec->ticks_per_frame != 1) {
//        LoggerStream(0, @"WARNING: st.codec.ticks_per_frame=%d", st->codec->ticks_per_frame);
        //timebase *= st->codec->ticks_per_frame;
    }
    
    if (st->avg_frame_rate.den && st->avg_frame_rate.num)
        fps = av_q2d(st->avg_frame_rate);
    else if (st->r_frame_rate.den && st->r_frame_rate.num)
        fps = av_q2d(st->r_frame_rate);
    else
        fps = 1.0 / timebase;
    
    if (pFPS)
        *pFPS = fps;
    if (pTimeBase)
        *pTimeBase = timebase;
}

@interface ViewController ()
{
    AVFormatContext *_formatContext;
    int _videoStream;
    AVStream *_stream;
    AVCodecContext *_codecContext;
    AVFrame *_frame;
    double _fps;
    
    int _audioStream;
    AVFrame             *_audioFrame;
    AVCodecContext      *_audioCodecCtx;
    SwrContext          *_swrContext;
    CGFloat             _audioTimeBase;
    void                *_swrBuffer;
    NSUInteger          _swrBufferSize;
}

@property (nonatomic,assign) int outputWidth, outputHeight;

@property (nonatomic, strong) UIImageView *movieView;

@end

@implementation ViewController

+(NSString *)bundlePath:(NSString *)fileName
{
    return [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:fileName];
}

- (void)seekTime:(double)seconds
{
    AVRational timeBase = _stream->time_base;
    int64_t targetFrame = (int64_t)((double)timeBase.den / timeBase.num * seconds);
    avformat_seek_file(_formatContext, _videoStream, 0, targetFrame, targetFrame, AVSEEK_FLAG_FRAME);
    avcodec_flush_buffers(_codecContext);
}

- (void)openVideoWithFilePath:(NSString *)videoPath
{
    avcodec_register_all();
    av_register_all();
    avformat_network_init();
    
    if (avformat_open_input(&_formatContext, [videoPath UTF8String], NULL, NULL)) {
        NSLog(@"open file failed");
        return;
    }
    
    if (avformat_find_stream_info(_formatContext, NULL) < 0) {
        NSLog(@"check data stream failed");
        return;
    }
    
    if ((_videoStream = av_find_best_stream(_formatContext, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0)) < 0) {
        NSLog(@"can`t find first video stream");
        return;
    }
    
#ifdef DUMP_INFO
    av_dump_format(_formatContext, _videoStream, [videoPath UTF8String], 0);
#endif
    
    _stream = _formatContext->streams[_videoStream];
    
    if(_stream->avg_frame_rate.den && _stream->avg_frame_rate.num) {
        _fps = av_q2d(_stream->avg_frame_rate);
    } else {
        _fps = 30;
    }
    
    // create codec and it`s context
    AVCodec *codec = avcodec_find_decoder(_stream->codecpar->codec_id);
    _codecContext = avcodec_alloc_context3(codec);
    _codecContext->opaque = NULL;
    avcodec_parameters_to_context(_codecContext, _stream->codecpar);
    if (avcodec_open2(_codecContext, codec, NULL) < 0) {
        NSLog(@"open codec failed");
        return;
    }
    
    _outputWidth = _codecContext->width;
    _outputHeight = _codecContext->height;
}

- (void)openAudio
{
    int audioStream;
    if ((audioStream = av_find_best_stream(_formatContext, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0)) < 0) {
        NSLog(@"can`t find best video stream");
        return;
    }
    
    // create codec and it`s context
    AVCodec *codec = avcodec_find_decoder(_formatContext->streams[audioStream]->codecpar->codec_id);
    AVCodecContext *codecCtx = avcodec_alloc_context3(codec);
    codecCtx->opaque = NULL;
    avcodec_parameters_to_context(codecCtx, _formatContext->streams[audioStream]->codecpar);
    
    
    SwrContext *swrContext = NULL;
    
    if (!codec) {
        NSLog(@"avcodec_find_decoder error");
        return;
    }
    
    if (avcodec_open2(codecCtx, codec, NULL) < 0) {
        NSLog(@"avcodec_open2 error");
        return;
    }
    
    if (!audioCodecIsSupported(codecCtx)) {
        
        FDAudioManager *audioManager = [FDAudioManager sharedInstance];
        swrContext = swr_alloc_set_opts(NULL,
                                        av_get_default_channel_layout(audioManager.numOutputChannels),
                                        AV_SAMPLE_FMT_S16,
                                        audioManager.samplingRate,
                                        av_get_default_channel_layout(codecCtx->channels),
                                        codecCtx->sample_fmt,
                                        codecCtx->sample_rate,
                                        0,
                                        NULL);
        
        if (!swrContext ||
            swr_init(swrContext)) {
            
            if (swrContext)
                swr_free(&swrContext);
            avcodec_close(codecCtx);
            
            return ;
        }
    }
    
    
    _audioFrame = av_frame_alloc();
    
    if (!_audioFrame) {
        if (swrContext)
            swr_free(&swrContext);
        avcodec_close(codecCtx);
        return ;
    }
    
    _audioStream = audioStream;
    _audioCodecCtx = codecCtx;
    _swrContext = swrContext;
    
    AVStream *st = _formatContext->streams[_audioStream];
    avStreamFPSTimeBase(st, 0.025, 0, &_audioTimeBase);
    
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
    
    
    [[FDAudioManager sharedInstance] activateAudioSession];
    [FDAudioManager sharedInstance].outputBlock = ^(float *data, UInt32 numFrames, UInt32 numChannels) {
        [self audioCallbackFillData:data numFrames:numFrames numChannels:numChannels];
    };
    
    [self openVideoWithFilePath:[self.class bundlePath:@"for_the_birds.avi"]];
    [self openAudio];
    
    self.movieView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, _outputWidth, _outputHeight)];
    [self.view addSubview:self.movieView];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self seekTime:0];
        [[FDAudioManager sharedInstance] play];
//        [NSTimer scheduledTimerWithTimeInterval: 1 / self->_fps
//                                         target:self
//                                       selector:@selector(displayNextFrame:)
//                                       userInfo:nil
//                                        repeats:YES];
    });
}

- (void)displayNextFrame:(NSTimer *)timer
{
    AVPacket packet;
    
    while (av_read_frame(_formatContext, &packet) >= 0) {
        if (packet.stream_index == _videoStream) {
            if (_frame) {
                if(_frame->data[0] != NULL) {
                    av_frame_unref(_frame);
                }
                av_frame_free(&_frame);
            }
            _frame = av_frame_alloc();
            
            int rtn1 = avcodec_send_packet(_codecContext, &packet);
            int rtn2 = avcodec_receive_frame(_codecContext, _frame);
            if (rtn2 == 0) {
                break;
            }
            break;
        }
    }
    
    self.movieView.image = [self imageFromAVPicture];
}

- (UIImage *)imageFromAVPicture
{
    AVPicture picture;
    avpicture_alloc(&picture, AV_PIX_FMT_RGB24, _outputWidth, _outputHeight);
    struct SwsContext * imgConvertCtx = sws_getContext(_frame->width,
                                                       _frame->height,
                                                       AV_PIX_FMT_YUV420P,
                                                       _outputWidth,
                                                       _outputHeight,
                                                       AV_PIX_FMT_RGB24,
                                                       SWS_FAST_BILINEAR,
                                                       NULL,
                                                       NULL,
                                                       NULL);
    if(imgConvertCtx == nil) return nil;
    sws_scale(imgConvertCtx,
              _frame->data,
              _frame->linesize,
              0,
              _frame->height,
              picture.data,
              picture.linesize);
    sws_freeContext(imgConvertCtx);
    
    CGBitmapInfo bitmapInfo = kCGBitmapByteOrderDefault;
    CFDataRef data = CFDataCreate(kCFAllocatorDefault,
                                  picture.data[0],
                                  picture.linesize[0] * _outputHeight);
    
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGImageRef cgImage = CGImageCreate(_outputWidth,
                                       _outputHeight,
                                       8,
                                       24,
                                       picture.linesize[0],
                                       colorSpace,
                                       bitmapInfo,
                                       provider,
                                       NULL,
                                       NO,
                                       kCGRenderingIntentDefault);
    UIImage *image = [UIImage imageWithCGImage:cgImage];
    CGImageRelease(cgImage);
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
    CFRelease(data);
    
    return image;
}

- (void)audioCallbackFillData: (float *) outData
                    numFrames: (UInt32) numFrames
                  numChannels: (UInt32) numChannels
{
    NSMutableData *currentAudioFrame = [[self decodeFrames:0] firstObject];
    
    NSInteger currentAudioFramePos = 0;
    
    const void *bytes = (Byte *)currentAudioFrame.bytes + currentAudioFramePos;
    const NSUInteger bytesLeft = (currentAudioFrame.length - currentAudioFramePos);
    const NSUInteger frameSizeOf = numChannels * sizeof(float);
    const NSUInteger bytesToCopy = MIN(numFrames * frameSizeOf, bytesLeft);
    const NSUInteger framesToCopy = bytesToCopy / frameSizeOf;
    
    memcpy(outData, bytes, bytesToCopy);
    numFrames -= framesToCopy;
    outData += framesToCopy * numChannels;
    
//    if (bytesToCopy < bytesLeft)
//        _currentAudioFramePos += bytesToCopy;
//    else
//        _currentAudioFrame = nil;
}


- (NSArray *)decodeFrames: (CGFloat) minDuration
{
    NSMutableArray *result = [NSMutableArray array];
    
    AVPacket packet;
    
    CGFloat decodedDuration = 0;
    
    BOOL finished = NO;
    
    while (!finished) {
        if (av_read_frame(_formatContext, &packet) < 0) {
//            _isEOF = YES;
            break;
        }
        
        int pktSize = packet.size;
        
        while (pktSize > 0) {
            
            int gotframe = 0;
            
//            Use avcodec_send_packet() and avcodec_receive_frame().
            
            avcodec_send_packet(_audioCodecCtx, &packet);
            avcodec_receive_frame(_audioCodecCtx, _audioFrame);
            
//            int len = avcodec_decode_audio4(_audioCodecCtx,
//                                            _audioFrame,
//                                            &gotframe,
//                                            &packet);
            
//            if (len < 0) {
//                LoggerAudio(0, @"decode audio error, skip packet");
//                break;
//            }
            
            if (gotframe) {
                
                NSMutableData * data = [self handleAudioFrame];
                if (data) {
                    
                    [result addObject:data];
                    
                    finished = YES;
                    
//                    if (_videoStream == -1) {
//
//                        _position = frame.position;
//                        decodedDuration += frame.duration;
//                        if (decodedDuration > minDuration)
//                            finished = YES;
//                    }
                }
            }
            
            break;
            
//            if (0 == len)
//                break;
//
//            pktSize -= len;
        }
        
    }
    
    return result;
}

- (NSMutableData *)handleAudioFrame
{
    if (!_audioFrame->data[0])
        return nil;
    
    FDAudioManager *audioManager = [FDAudioManager sharedInstance];
    
//    id<KxAudioManager> audioManager = [KxAudioManager audioManager];
    
    const NSUInteger numChannels = audioManager.numOutputChannels;
    NSInteger numFrames;
    
    void * audioData;
    
    if (_swrContext) {
        
        const NSUInteger ratio = MAX(1, audioManager.samplingRate / _audioCodecCtx->sample_rate) *
        MAX(1, audioManager.numOutputChannels / _audioCodecCtx->channels) * 2;
        
        const int bufSize = av_samples_get_buffer_size(NULL,
                                                       audioManager.numOutputChannels,
                                                       _audioFrame->nb_samples * ratio,
                                                       AV_SAMPLE_FMT_S16,
                                                       1);
        
        if (!_swrBuffer || _swrBufferSize < bufSize) {
            _swrBufferSize = bufSize;
            _swrBuffer = realloc(_swrBuffer, _swrBufferSize);
        }
        
        Byte *outbuf[2] = { _swrBuffer, 0 };
        
        numFrames = swr_convert(_swrContext,
                                outbuf,
                                _audioFrame->nb_samples * ratio,
                                (const uint8_t **)_audioFrame->data,
                                _audioFrame->nb_samples);
        
        if (numFrames < 0) {
//            LoggerAudio(0, @"fail resample audio");
            return nil;
        }
        
        //int64_t delay = swr_get_delay(_swrContext, audioManager.samplingRate);
        //if (delay > 0)
        //    LoggerAudio(0, @"resample delay %lld", delay);
        
        audioData = _swrBuffer;
        
    } else {
        
        if (_audioCodecCtx->sample_fmt != AV_SAMPLE_FMT_S16) {
            NSAssert(false, @"bucheck, audio format is invalid");
            return nil;
        }
        
        audioData = _audioFrame->data[0];
        numFrames = _audioFrame->nb_samples;
    }
    
    const NSUInteger numElements = numFrames * numChannels;
    NSMutableData *data = [NSMutableData dataWithLength:numElements * sizeof(float)];
    
    float scale = 1.0 / (float)INT16_MAX ;
    vDSP_vflt16((SInt16 *)audioData, 1, data.mutableBytes, 1, numElements);
    vDSP_vsmul(data.mutableBytes, 1, &scale, data.mutableBytes, 1, numElements);
    
//    KxAudioFrame *frame = [[KxAudioFrame alloc] init];
//    frame.position = av_frame_get_best_effort_timestamp(_audioFrame) * _audioTimeBase;
//    frame.duration = av_frame_get_pkt_duration(_audioFrame) * _audioTimeBase;
//    frame.samples = data;
    
//    if (frame.duration == 0) {
//        // sometimes ffmpeg can't determine the duration of audio frame
//        // especially of wma/wmv format
//        // so in this case must compute duration
//        frame.duration = frame.samples.length / (sizeof(float) * numChannels * audioManager.samplingRate);
//    }
    
#if 0
    LoggerAudio(2, @"AFD: %.4f %.4f | %.4f ",
                frame.position,
                frame.duration,
                frame.samples.length / (8.0 * 44100.0));
#endif
    
    return data;
}





@end
