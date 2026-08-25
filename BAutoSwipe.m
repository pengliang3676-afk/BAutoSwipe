//
//  BAutoSwipe.m
//  百度极速版自动上滑（模仿真人触摸）
//  用 IOHIDEvent 模拟真实触摸事件，通过 TrollFools 注入
//  适配 iPhone SE2 / iPhone 8（375x667 点）
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach_time.h>
#import <dlfcn.h>

// The iPhoneOS SDK ships IOKit but omits these private HID declarations.
// Keep the minimal ABI declarations here so GitHub's stock Xcode can compile.
typedef double IOHIDFloat;
typedef uint32_t IOHIDEventOptionBits;
typedef uint32_t IOHIDEventField;
typedef uint32_t IOHIDDigitizerEventMask;
typedef uint32_t IOHIDDigitizerTransducerType;
typedef struct __IOHIDEvent *IOHIDEventRef;

enum {
    kIOHIDEventOptionNone = 0,
    kIOHIDDigitizerEventRange = 1 << 0,
    kIOHIDDigitizerEventTouch = 1 << 1,
    kIOHIDDigitizerEventPosition = 1 << 2,
    kIOHIDDigitizerEventCancel = 1 << 7,
    kIOHIDDigitizerTransducerTypeHand = 3,
    kIOHIDEventFieldDigitizerEventMask = (11 << 16) + 7,
};

extern IOHIDEventRef IOHIDEventCreateDigitizerEvent(
    CFAllocatorRef allocator, uint64_t timestamp,
    IOHIDDigitizerTransducerType type, uint32_t index, uint32_t identity,
    IOHIDDigitizerEventMask eventMask, uint32_t buttonMask,
    IOHIDFloat x, IOHIDFloat y, IOHIDFloat z, IOHIDFloat pressure,
    IOHIDFloat twist, boolean_t range, boolean_t touch,
    IOHIDEventOptionBits options);
extern IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(
    CFAllocatorRef allocator, uint64_t timestamp, uint32_t index,
    uint32_t identity, IOHIDDigitizerEventMask eventMask,
    IOHIDFloat x, IOHIDFloat y, IOHIDFloat z, IOHIDFloat pressure,
    IOHIDFloat twist, boolean_t range, boolean_t touch,
    IOHIDEventOptionBits options);
extern void IOHIDEventSetIntegerValue(IOHIDEventRef event,
                                       IOHIDEventField field, CFIndex value);
extern void IOHIDEventAppendEvent(IOHIDEventRef parent,
                                  IOHIDEventRef child,
                                  IOHIDEventOptionBits options);

// ===== 配置 =====
static const NSInteger kMaxSwipes = 500;        // 最多滑动次数
static const NSTimeInterval kMinSwipe = 0.20;   // 最短滑动时长
static const NSTimeInterval kMaxSwipe = 0.55;   // 最长滑动时长
static const double kSwipeDownProbability = 0.08; // 下滑概率
static const NSInteger kRestMinSwipes = 15;     // 最少多少个视频后休息
static const NSInteger kRestMaxSwipes = 30;     // 最多多少个视频后休息
static const NSTimeInterval kRestMin = 60.0;    // 最短休息时间
static const NSTimeInterval kRestMax = 180.0;   // 最长休息时间

// 观看时间分布（模拟真人）
// 20% 不感兴趣快速划走：8-25 秒
// 55% 正常观看：30-120 秒
// 20% 比较感兴趣：120-240 秒
// 5%  看完/很感兴趣：240-420 秒
static NSTimeInterval randomWatchTime(void) {
    uint32_t r = arc4random_uniform(100);
    if (r < 20) {
        return 8 + (arc4random_uniform(1700) / 100.0);        // 8-25s
    } else if (r < 75) {
        return 30 + (arc4random_uniform(9000) / 100.0);       // 30-120s
    } else if (r < 95) {
        return 120 + (arc4random_uniform(12000) / 100.0);     // 120-240s
    } else {
        return 180 + (arc4random_uniform(12000) / 100.0);     // 180-300s（3-5分钟）
    }
}

// ===== 全局状态 =====
static BOOL g_running = NO;
static NSInteger g_swipeCount = 0;
static NSInteger g_nextRest = 20;
static UIButton *g_floatingBtn = nil;
static dispatch_queue_t g_swipeQueue = nil;

// _UIEnqueueHIDEvent：UIKit 内部函数，将 HID 事件送入系统事件队列
typedef void (*UIEnqueueHIDEventFunc)(IOHIDEventRef);
static UIEnqueueHIDEventFunc g_enqueueFunc = NULL;

static UIEnqueueHIDEventFunc getEnqueueFunc(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_enqueueFunc = (UIEnqueueHIDEventFunc)dlsym(RTLD_DEFAULT, "_UIEnqueueHIDEvent");
    });
    return g_enqueueFunc;
}

// ===== IOHIDEvent 触摸模拟 =====

static uint64_t nowMachTime(void) {
    return mach_absolute_time();
}

static IOHIDEventRef createDigitizerEvent(uint64_t timestamp,
                                           IOHIDDigitizerEventMask eventMask,
                                           BOOL isTouching) {
    return IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, timestamp,
        kIOHIDDigitizerTransducerTypeHand,
        0,  // index
        0,  // identity
        eventMask,
        0,  // button mask
        0, 0, 0, 0, 0,
        isTouching, isTouching,
        kIOHIDEventOptionNone
    );
}

static IOHIDEventRef createFingerEvent(uint64_t timestamp, int fingerId,
                                       IOHIDDigitizerEventMask eventMask,
                                       BOOL isTouching,
                                       CGFloat x, CGFloat y, CGFloat pressure) {
    return IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault, timestamp,
        fingerId, fingerId, eventMask,
        x, y, 0.0, pressure,
        0.0, isTouching, isTouching,
        kIOHIDEventOptionNone
    );
}

static void sendTouchEvent(int fingerId, UITouchPhase phase, CGFloat x, CGFloat y, CGFloat pressure) {
    UIEnqueueHIDEventFunc enqueue = getEnqueueFunc();
    if (!enqueue) return;

    uint64_t ts = nowMachTime();
    BOOL isTouching = !(phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled);
    IOHIDDigitizerEventMask options = kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch;
    if (phase == UITouchPhaseMoved) options = kIOHIDDigitizerEventPosition;
    if (phase == UITouchPhaseCancelled) options |= kIOHIDDigitizerEventCancel;

    IOHIDEventRef digitizer = createDigitizerEvent(ts, options, isTouching);

    IOHIDEventSetIntegerValue(digitizer, kIOHIDEventFieldDigitizerEventMask, options);

    IOHIDEventRef finger = createFingerEvent(ts, fingerId, options, isTouching, x, y, pressure);
    IOHIDEventAppendEvent(digitizer, finger, kIOHIDEventOptionNone);
    CFRelease(finger);

    enqueue(digitizer);
    CFRelease(digitizer);
}

// 发送移动事件（不需要重新创建完整 digitizer）
static void sendMoveEvent(int fingerId, CGFloat x, CGFloat y) {
    UIEnqueueHIDEventFunc enqueue = getEnqueueFunc();
    if (!enqueue) return;

    uint64_t ts = nowMachTime();
    IOHIDDigitizerEventMask options = kIOHIDDigitizerEventPosition;
    IOHIDEventRef digitizer = createDigitizerEvent(ts, options, YES);
    IOHIDEventSetIntegerValue(digitizer, kIOHIDEventFieldDigitizerEventMask, options);
    IOHIDEventRef finger = createFingerEvent(ts, fingerId, options, YES, x, y, 0.03);
    IOHIDEventAppendEvent(digitizer, finger, kIOHIDEventOptionNone);
    CFRelease(finger);

    enqueue(digitizer);
    CFRelease(digitizer);
}

// ===== 滑动手势 =====

static CGFloat randFloat(CGFloat min, CGFloat max) {
    return min + ((CGFloat)arc4random_uniform(10000) / 10000.0) * (max - min);
}

static NSInteger randInt(NSInteger min, NSInteger max) {
    return min + arc4random_uniform((uint32_t)(max - min + 1));
}

// 用 IOHIDEvent 模拟一次滑动
static void performSwipe(BOOL up) {
    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;

    CGFloat startX, startY, endX, endY;

    if (up) {
        startX = randFloat(screenW * 0.30, screenW * 0.70);
        startY = randFloat(screenH * 0.65, screenH * 0.80);
        endY = startY - randFloat(280, 450);
        endX = startX + randFloat(-25, 25);
    } else {
        startX = randFloat(screenW * 0.35, screenW * 0.65);
        startY = randFloat(screenH * 0.30, screenH * 0.45);
        endY = startY + randFloat(200, 350);
        endX = startX + randFloat(-20, 20);
    }

    NSTimeInterval duration = randFloat(kMinSwipe, kMaxSwipe);
    int steps = (int)(duration / 0.016);  // ~60fps
    int fingerId = 0;

    // 按下
    sendTouchEvent(fingerId, UITouchPhaseBegan, startX, startY, 0.02);
    usleep(randInt(30000, 80000));  // 按下后停留 30-80ms

    // 滑动（easeOutCubic：先快后慢）
    for (int i = 1; i <= steps; i++) {
        double t = (double)i / steps;
        double ease = 1.0 - (1.0 - t) * (1.0 - t) * (1.0 - t);
        CGFloat x = startX + (endX - startX) * ease;
        CGFloat y = startY + (endY - startY) * ease;
        sendMoveEvent(fingerId, x, y);
        usleep(16000);
    }

    // 确保到达终点
    sendMoveEvent(fingerId, endX, endY);
    usleep(randInt(20000, 60000));

    // 抬手
    sendTouchEvent(fingerId, UITouchPhaseEnded, endX, endY, 0.0);
}

// 回退方案：直接滚动 UIScrollView（如果 HID 事件不可用）
static void performSwipeFallback(BOOL up) {
    UIWindow *keyWindow = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) { keyWindow = w; break; }
            }
        }
    }
    if (!keyWindow) return;

    // 找到当前可见的 UIScrollView
    UIScrollView *targetSV = nil;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:keyWindow];
    while (stack.count > 0 && !targetSV) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if ([v isKindOfClass:[UIScrollView class]]) {
            UIScrollView *sv = (UIScrollView *)v;
            if (sv.contentSize.height > sv.bounds.size.height &&
                sv.bounds.size.width > 100 && sv.bounds.size.height > 200 &&
                !sv.dragging && !sv.decelerating) {
                targetSV = sv;
            }
        }
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }

    if (targetSV) {
        CGFloat pageH = targetSV.bounds.size.height;
        CGPoint offset = targetSV.contentOffset;
        offset.y += up ? pageH : -pageH;
        offset.y = MAX(0, MIN(offset.y, targetSV.contentSize.height - pageH));
        [targetSV setContentOffset:offset animated:YES];
    }
}

static void performSwipeAuto(BOOL up) {
    if (getEnqueueFunc()) {
        performSwipe(up);
    } else {
        // HID 不可用，回退到主线程执行 setContentOffset
        dispatch_async(dispatch_get_main_queue(), ^{
            performSwipeFallback(up);
        });
        usleep(300000);
    }
}

// ===== 主循环 =====

static void swipeLoop(void) {
    while (g_running && g_swipeCount < kMaxSwipes) {
        @autoreleasepool {
            // 观看视频（随机时长，分段 sleep 以便及时响应停止）
            NSTimeInterval watchTime = randomWatchTime();
            NSTimeInterval watched = 0;
            while (watched < watchTime && g_running) {
                NSTimeInterval chunk = MIN(randFloat(2, 5), watchTime - watched);
                usleep((useconds_t)(chunk * 1000000));
                watched += chunk;
            }

            if (!g_running) break;

            // 8% 概率下滑回看
            BOOL goBack = (arc4random_uniform(100) < (uint32_t)(kSwipeDownProbability * 100));
            performSwipeAuto(!goBack);
            g_swipeCount++;

            // 更新按钮标题
            dispatch_async(dispatch_get_main_queue(), ^{
                [g_floatingBtn setTitle:[NSString stringWithFormat:@"滑%ld 停", (long)g_swipeCount]
                               forState:UIControlStateNormal];
            });

            if (goBack) {
                // 回看后看几秒再滑回来
                usleep(randInt(3, 10) * 1000000);
                if (!g_running) break;
                performSwipeAuto(YES);
                g_swipeCount++;
            }

            // 定期长休息
            if (g_swipeCount >= g_nextRest) {
                NSTimeInterval restTime = randFloat(kRestMin, kRestMax);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [g_floatingBtn setTitle:@"休息中" forState:UIControlStateNormal];
                });
                NSTimeInterval rested = 0;
                while (rested < restTime && g_running) {
                    usleep(2000000);
                    rested += 2;
                }
                g_nextRest = g_swipeCount + randInt(kRestMinSwipes, kRestMaxSwipes);
            }
        }
    }

    g_running = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        [g_floatingBtn setTitle:@"开始" forState:UIControlStateNormal];
        g_floatingBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:0.2 alpha:0.85];
    });
}

// ===== 悬浮按钮 =====

static void toggleRunning(void) {
    g_running = !g_running;
    if (g_running) {
        g_swipeCount = 0;
        g_nextRest = randInt(kRestMinSwipes, kRestMaxSwipes);
        g_floatingBtn.backgroundColor = [UIColor colorWithRed:0.8 green:0.2 blue:0.2 alpha:0.85];
        [g_floatingBtn setTitle:@"运行中" forState:UIControlStateNormal];
        dispatch_async(g_swipeQueue, ^{
            swipeLoop();
        });
    } else {
        g_floatingBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:0.2 alpha:0.85];
        [g_floatingBtn setTitle:@"开始" forState:UIControlStateNormal];
    }
}

static void addFloatingButton(void) {
    if (g_floatingBtn) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        CGFloat btnSize = 60;
        CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
        CGFloat screenH = [UIScreen mainScreen].bounds.size.height;

        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(screenW - btnSize - 15, screenH * 0.4, btnSize, btnSize);
        btn.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:0.2 alpha:0.85];
        [btn setTitle:@"开始" forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:14];
        btn.layer.cornerRadius = btnSize / 2;
        btn.layer.masksToBounds = YES;
        btn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;

        // 点击开始/停止
        [btn addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
            toggleRunning();
        }] forControlEvents:UIControlEventTouchUpInside];

        // 拖动按钮位置
        UIPanGestureRecognizer *drag = [[UIPanGestureRecognizer alloc] initWithTarget:btn action:@selector(bdas_handlePan:)];
        [btn addGestureRecognizer:drag];

        UIWindow *keyWindow = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w.isKeyWindow) { keyWindow = w; break; }
                }
            }
        }
        if (keyWindow) {
            [keyWindow addSubview:btn];
        }
        g_floatingBtn = btn;
    });
}

// 用 category 实现拖动
@interface UIButton (BDAutoSwipe)
@end

@implementation UIButton (BDAutoSwipe)
- (void)bdas_handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.superview];
    self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:self.superview];
}
@end

// ===== 入口 =====

__attribute__((constructor))
static void bdas_init(void) {
    // 只在百度极速版中加载
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (![bundleID containsString:@"baidu"]) return;

    g_swipeQueue = dispatch_queue_create("com.bdas.autoswipe", DISPATCH_QUEUE_SERIAL);

    // 延迟 2 秒添加按钮，等 App 启动完成
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        addFloatingButton();
    });
}
