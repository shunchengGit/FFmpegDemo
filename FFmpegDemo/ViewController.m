//
//  ViewController.m
//  FFmpegDemo
//
//  Created by chengshun on 2018/6/14.
//  Copyright © 2018年 chengshun. All rights reserved.
//

#import "ViewController.h"
#include <libavformat/avformat.h>

@interface ViewController ()
{
    AVFormatContext *_formatContext;
    int _videoStream;
    AVStream *_stream;
    AVCodecContext *_codecContext;
    double _fps;
}

@property (nonatomic,assign) int outputWidth, outputHeight;

@end

@implementation ViewController

+(NSString *)bundlePath:(NSString *)fileName
{
    return [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:fileName];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
    
    NSString *videoPath = [self.class bundlePath:@"for_the_birds.avi"];
    
    // 初始化
    avcodec_register_all();
    av_register_all();
    avformat_network_init();
    
    if (avformat_open_input(&_formatContext, [videoPath UTF8String], NULL, NULL)) {
        NSLog(@"打开文件失败");
        return;
    }
    
    if (avformat_find_stream_info(_formatContext, NULL) < 0) {
        NSLog(@"检查数据流失败");
        return;
    }
    
    if ((_videoStream = av_find_best_stream(_formatContext, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0)) < 0) {
        NSLog(@"没有找到第一个视频流");
        return;
    }
    
    _stream = _formatContext->streams[_videoStream];
    _codecContext = _stream->codec;
    
    av_dump_format(_formatContext, _videoStream, [videoPath UTF8String], 0);
    
    if(_stream->avg_frame_rate.den && _stream->avg_frame_rate.num) {
        _fps = av_q2d(_stream->avg_frame_rate);
    } else {
        _fps = 30;
    }
    
    _outputWidth = _codecContext->width;
    _outputHeight = _codecContext->height;
}

@end
