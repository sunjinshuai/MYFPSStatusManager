//
//  MYFPSStatusManager.m
//  MYFPSStatusManager
//
//  Created by sunjinshuai on 2018/2/23.
//  Copyright © 2018年 MYFPSStatusManager. All rights reserved.
//

#import "MYFPSStatusManager.h"
#import <mach/mach.h>
#import <objc/runtime.h>
#include <ifaddrs.h>
#include <sys/socket.h>
#include <net/if.h>
#include <arpa/inet.h>
#include <net/if_dl.h>

@implementation MYFPSStatusManager {
    CADisplayLink *_displayLink;
    NSUInteger _count;
    NSTimeInterval _lastTime;
    UILabel *_statusBarLabel;
    int _lastNetSent;
    int _lasNetReceived;
}

+ (instancetype)shareManager {
    static MYFPSStatusManager *_shareManager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _shareManager = [[MYFPSStatusManager alloc] init];
        if ([[UIDevice currentDevice].systemVersion floatValue] >= 9.0) {
            _shareManager.rootViewController = [UIViewController new];
        }
    });
    return _shareManager;
}

- (void)dealloc {
    [_displayLink setPaused:YES];
    [_displayLink removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
}

- (instancetype)init {
    if ((self = [super initWithFrame:[[UIApplication sharedApplication] statusBarFrame]])) {
        
        [self setWindowLevel: UIWindowLevelStatusBar + 1.0f];
        [self setBackgroundColor:[UIColor colorWithWhite:0.000 alpha:0.700]];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidBecomeActiveNotification)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationWillResignActiveNotification)
                                                     name:UIApplicationWillResignActiveNotification
                                                   object:nil];
        
        // Track FPS using display link
        _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayLinkTick:)];
        [_displayLink setPaused:YES];
        [_displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
        
        // Show FPS CPU RAM
        _statusBarLabel = [[UILabel alloc] initWithFrame:self.frame];
        _statusBarLabel.textAlignment = NSTextAlignmentCenter;
        [_statusBarLabel setTextColor:[UIColor whiteColor]];
        _statusBarLabel.font = [UIFont systemFontOfSize:13.0];
        _statusBarLabel.minimumScaleFactor = 0.5;
        _statusBarLabel.adjustsFontSizeToFitWidth = YES;
        [self addSubview:_statusBarLabel];
        
    }
    return self;
}

- (void)applicationDidBecomeActiveNotification {
    [_displayLink setPaused:NO];
}

- (void)applicationWillResignActiveNotification {
    [_displayLink setPaused:YES];
}

- (void)becomeKeyWindow {
    //prevent self to be key window
    [self setHidden: YES];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0f * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self setHidden: NO];
    });
}

- (void)displayLinkTick:(CADisplayLink *)link {
    if (_lastTime == 0) {
        _lastTime = link.timestamp;
        return;
    }
    
    _count++;
    NSTimeInterval delta = link.timestamp - _lastTime;
    if (delta < 1) return;
    _lastTime = link.timestamp;
    float fps = _count / delta;
    _count = 0;
    
    NSString *netInfo = @"";
    if (_lastNetSent == 0 && _lasNetReceived == 0) {
        _lastNetSent = [[self getNetwork].firstObject intValue];
        _lasNetReceived = [[self getNetwork].lastObject intValue];
        netInfo = [NSString stringWithFormat:@"↓0KB/s"];
    } else {
        int netSent = [[self getNetwork].firstObject intValue];
        int netReceived = [[self getNetwork].lastObject intValue];
        netInfo = [NSString stringWithFormat:@"↓%.1fKB/s",(netReceived - _lasNetReceived)/1024.0];
        _lastNetSent = netSent;
        _lasNetReceived = netReceived;
    }
    
    CGFloat progress = fps / 60.0;
    UIColor *color = [UIColor colorWithHue:0.27 * (progress - 0.2) saturation:1 brightness:0.9 alpha:1];
    NSString *fpsStr = [NSString stringWithFormat:@"%d",(int)round(fps)];
    
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:[NSString stringWithFormat:@"FPS:%@ CPU:%@ RAM:%@ %@ 🔋%d",fpsStr,[self getCpuUsage],[self getCurrentTaskUsedMemory],netInfo,[self getCurrentBatteryLevel]]];
    [text addAttribute:NSForegroundColorAttributeName value:color range:NSMakeRange(4, fpsStr.length)];
    [text addAttribute:NSFontAttributeName value:[UIFont fontWithName:@"Menlo" size:14] range:NSMakeRange(0, text.length)];
    [_statusBarLabel setAttributedText:text];
}

#pragma - private
- (NSString *)getCpuUsage {
    kern_return_t kr;
    task_info_data_t tinfo;
    mach_msg_type_number_t task_info_count;
    
    task_info_count = TASK_INFO_MAX;
    kr = task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)tinfo, &task_info_count);
    if (kr != KERN_SUCCESS) {
        return @"-%%";
    }
    
    task_basic_info_t      basic_info;
    thread_array_t         thread_list;
    mach_msg_type_number_t thread_count;
    
    thread_info_data_t     thinfo;
    mach_msg_type_number_t thread_info_count;
    
    thread_basic_info_t basic_info_th;
    uint32_t stat_thread = 0; // Mach threads
    
    basic_info = (task_basic_info_t)tinfo;
    
    // get threads in the task
    kr = task_threads(mach_task_self(), &thread_list, &thread_count);
    if (kr != KERN_SUCCESS) {
        return @"-%%";
    }
    if (thread_count > 0)
        stat_thread += thread_count;
    
    long tot_sec = 0;
    long tot_usec = 0;
    float tot_cpu = 0;
    int j;
    
    for (j = 0; j < thread_count; j++) {
        thread_info_count = THREAD_INFO_MAX;
        kr = thread_info(thread_list[j], THREAD_BASIC_INFO,
                         (thread_info_t)thinfo, &thread_info_count);
        if (kr != KERN_SUCCESS) {
            return @"-%%";
        }
        
        basic_info_th = (thread_basic_info_t)thinfo;
        
        if (!(basic_info_th->flags & TH_FLAGS_IDLE)) {
            tot_sec = tot_sec + basic_info_th->user_time.seconds + basic_info_th->system_time.seconds;
            tot_usec = tot_usec + basic_info_th->system_time.microseconds + basic_info_th->system_time.microseconds;
            tot_cpu = tot_cpu + basic_info_th->cpu_usage / (float)TH_USAGE_SCALE * 100.0;
        }
        
    } // for each thread
    
    kr = vm_deallocate(mach_task_self(), (vm_offset_t)thread_list, thread_count * sizeof(thread_t));
    assert(kr == KERN_SUCCESS);
    
    return [NSString stringWithFormat:@"%.1f%%", tot_cpu];
}

- (NSString *)getCurrentTaskUsedMemory {
    task_basic_info_data_t taskInfo;
    mach_msg_type_number_t infoCount = TASK_BASIC_INFO_COUNT;
    kern_return_t kernReturn = task_info(mach_task_self(),
                                         TASK_BASIC_INFO, (task_info_t)&taskInfo, &infoCount);
    
    if (kernReturn != KERN_SUCCESS) {
        return @"-%%";
    }
    
    return [NSString stringWithFormat:@"%.1fM", taskInfo.resident_size / 1024.0 / 1024.0];
}

- (int)getCurrentBatteryLevel {
    UIApplication *app = [UIApplication sharedApplication];
    if (app.applicationState == UIApplicationStateActive||app.applicationState==UIApplicationStateInactive) {
        Ivar ivar = class_getInstanceVariable([app class],"_statusBar");
        id status = object_getIvar(app, ivar);
        for (id aview in [status subviews]) {
            int batteryLevel = 0;
            for (id bview in [aview subviews]) {
                if ([NSStringFromClass([bview class]) caseInsensitiveCompare:@"UIStatusBarBatteryItemView"] == NSOrderedSame&&[[[UIDevice currentDevice] systemVersion] floatValue] >=6.0) {
                    
                    Ivar ivar = class_getInstanceVariable([bview class],"_capacity");
                    if (ivar) {
                        batteryLevel = ((int (*)(id, Ivar))object_getIvar)(bview, ivar);
                        //这种方式也可以
                        /*ptrdiff_t offset = ivar_getOffset(ivar);
                         unsigned char *stuffBytes = (unsigned char *)(__bridge void *)bview;
                         batteryLevel = * ((int *)(stuffBytes + offset));*/
                        if (batteryLevel > 0 && batteryLevel <= 100) {
                            return batteryLevel;
                            
                        } else {
                            return 0;
                        }
                    }
                    
                }
                
            }
        }
    }
    
    return 0;
}

- (NSArray *)getNetwork {
    BOOL   success;
    struct ifaddrs *addrs;
    const struct ifaddrs *cursor;
    const struct if_data *networkStatisc;
    
    int WiFiSent = 0;
    int WiFiReceived = 0;
    int WWANSent = 0;
    int WWANReceived = 0;
    
    NSString *name = @"";
    
    success = getifaddrs(&addrs) == 0;
    if (success) {
        cursor = addrs;
        while (cursor != NULL) {
            name = [NSString stringWithFormat:@"%s",cursor->ifa_name];
            
            // names of interfaces: en0 is WiFi ,pdp_ip0 is WWAN
            if (cursor->ifa_addr->sa_family == AF_LINK) {
                if ([name hasPrefix:@"en"]) {
                    networkStatisc = (const struct if_data *) cursor->ifa_data;
                    WiFiSent+=networkStatisc->ifi_obytes;
                    WiFiReceived+=networkStatisc->ifi_ibytes;
                }
                if ([name hasPrefix:@"pdp_ip"]) {
                    networkStatisc = (const struct if_data *) cursor->ifa_data;
                    WWANSent+=networkStatisc->ifi_obytes;
                    WWANReceived+=networkStatisc->ifi_ibytes;
                }
            }
            cursor = cursor->ifa_next;
        }
        freeifaddrs(addrs);
    }
    // it is count by byte
    return @[@(WiFiSent+WWANSent),@(WiFiReceived+WWANReceived)];
}

@end
