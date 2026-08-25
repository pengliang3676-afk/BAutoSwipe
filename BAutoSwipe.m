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
#import <math.h>
#import <unistd.h>

// iPhoneOS SDK 不公开这些 HID 声明，运行时从 IOKit 动态解析，兼容 iOS 15.0-16.5。
typedef CFTypeRef IOHIDEventRef;
typedef CFTypeRef IOHIDEventSystemClientRef;
typedef IOHIDEventSystemClientRef (*HIDClientCreateFn)(CFAllocatorRef allocator);
typedef void (*HIDDispatchEventFn)(IOHIDEventSystemClientRef client, IOHIDEventRef event);
typedef void (*HIDAppendEventFn)(IOHIDEventRef parent, IOHIDEventRef child, uint32_t options);
typedef void (*HIDSetIntegerValueFn)(IOHIDEventRef event, uint32_t field, CFIndex value);
typedef void (*HIDSetFloatValueFn)(IOHIDEventRef event, uint32_t field, double value);
typedef void (*HIDSetSenderIDFn)(IOHIDEventRef event, uint64_t senderID);
typedef IOHIDEventRef (*HIDCreateDigitizerFn)(CFAllocatorRef, uint64_t, uint32_t,
    uint32_t, uint32_t, uint32_t, uint32_t, double, double, double, double,
    double, bool, bool, uint32_t);
typedef IOHIDEventRef (*HIDCreateFingerFn)(CFAllocatorRef, uint64_t, uint32_t,
    uint32_t, uint32_t, double, double, double, double, double, bool, bool,
    uint32_t);
typedef void (*UIEnqueueHIDEventFn)(IOHIDEventRef event);

enum {
    kBDHIDRange = 1u << 0,
    kBDHIDTouch = 1u << 1,
    kBDHIDPosition = 1u << 2,
    kBDHIDBuiltIn = 0x4,
    kBDHIDMajorRadius = 0xB0014,
    kBDHIDMinorRadius = 0xB0015,
    kBDHIDDisplayIntegrated = 0xB0019,
};

// ===== 配置 =====
static const NSInteger kMaxSwipes = 500;        // 最多滑动次数
static const NSTimeInterval kMinSwipe = 0.20;   // 最短滑动时长
static const NSTimeInterval kMaxSwipe = 0.55;   // 最长滑动时长
static const double kSwipeDownProbability = 0.08; // 下滑概率
static const NSInteger kRestMinSwipes = 15;     // 最少多少个视频后休息
static const NSInteger kRestMaxSwipes = 30;     // 最多多少个视频后休息
static const NSTimeInterval kRestMin = 60.0;    // 最短休息时间
static const NSTimeInterval kRestMax = 180.0;   // 最长休息时间

// 触控测试阶段：所有视频只等待 8-30 秒；真机滑动稳定后再恢复正式分布。
static NSTimeInterval randomWatchTime(void) {
    return 8.0 + (arc4random_uniform(2201) / 100.0);
}

// ===== 全局状态 =====
static BOOL g_running = NO;
static NSUInteger g_runGeneration = 0;
static NSInteger g_swipeCount = 0;
static NSInteger g_nextRest = 20;
static UIButton *g_floatingBtn = nil;
static dispatch_queue_t g_swipeQueue = nil;
static NSUInteger g_buttonAttachGeneration = 0;
static id g_didBecomeActiveObserver = nil;
static id g_windowDidBecomeVisibleObserver = nil;

static NSString *const kBAutoSwipeVersion = @"1.0.3-touchtest";
static const CGFloat kFloatingButtonSize = 60.0;
static const CGFloat kFloatingButtonMargin = 12.0;
static const NSInteger kWindowAttachRetryCount = 60;
static const NSTimeInterval kWindowAttachRetryDelay = 0.5;

static void *g_iokitHandle = NULL;
static IOHIDEventSystemClientRef g_hidClient = NULL;
static HIDClientCreateFn g_createClient = NULL;
static HIDDispatchEventFn g_dispatchEvent = NULL;
static HIDAppendEventFn g_appendEvent = NULL;
static HIDSetIntegerValueFn g_setIntegerValue = NULL;
static HIDSetFloatValueFn g_setFloatValue = NULL;
static HIDSetSenderIDFn g_setSenderID = NULL;
static HIDCreateDigitizerFn g_createDigitizer = NULL;
static HIDCreateFingerFn g_createFinger = NULL;
static UIEnqueueHIDEventFn g_enqueueEvent = NULL;
static BOOL g_usingSystemDispatch = NO;

// ===== IOHIDEvent 触摸模拟 =====

typedef NS_ENUM(NSInteger, BDTouchPhase) {
    BDTouchPhaseDown,
    BDTouchPhaseMove,
    BDTouchPhaseUp,
};

static BOOL hidBackendReady(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_iokitHandle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_LOCAL);
        if (!g_iokitHandle) return;

        g_createClient = (HIDClientCreateFn)dlsym(g_iokitHandle, "IOHIDEventSystemClientCreate");
        g_dispatchEvent = (HIDDispatchEventFn)dlsym(g_iokitHandle, "IOHIDEventSystemClientDispatchEvent");
        g_appendEvent = (HIDAppendEventFn)dlsym(g_iokitHandle, "IOHIDEventAppendEvent");
        g_setIntegerValue = (HIDSetIntegerValueFn)dlsym(g_iokitHandle, "IOHIDEventSetIntegerValue");
        g_setFloatValue = (HIDSetFloatValueFn)dlsym(g_iokitHandle, "IOHIDEventSetFloatValue");
        g_setSenderID = (HIDSetSenderIDFn)dlsym(g_iokitHandle, "IOHIDEventSetSenderID");
        g_createDigitizer = (HIDCreateDigitizerFn)dlsym(g_iokitHandle, "IOHIDEventCreateDigitizerEvent");
        g_createFinger = (HIDCreateFingerFn)dlsym(g_iokitHandle, "IOHIDEventCreateDigitizerFingerEvent");
        g_enqueueEvent = (UIEnqueueHIDEventFn)dlsym(RTLD_DEFAULT, "_UIEnqueueHIDEvent");
        if (g_createClient) g_hidClient = g_createClient(kCFAllocatorDefault);
        g_usingSystemDispatch = g_hidClient != NULL && g_dispatchEvent != NULL;

        NSLog(@"[BAutoSwipe] %@ HID backend selected=%@ enqueue=%d system=%d",
              kBAutoSwipeVersion, g_usingSystemDispatch ? @"system" : @"enqueue",
              g_enqueueEvent != NULL,
              g_hidClient != NULL && g_dispatchEvent != NULL);
    });

    BOOL canCreate = g_appendEvent && g_setIntegerValue && g_setFloatValue &&
                     g_setSenderID && g_createDigitizer && g_createFinger;
    BOOL canDispatch = g_enqueueEvent || (g_hidClient && g_dispatchEvent);
    return canCreate && canDispatch;
}

static BOOL sendNormalizedTouch(double x, double y, BDTouchPhase phase) {
    if (!hidBackendReady() || !isfinite(x) || !isfinite(y)) return NO;

    x = MIN(MAX(x, 0.001), 0.999);
    y = MIN(MAX(y, 0.001), 0.999);
    BOOL touching = phase != BDTouchPhaseUp;
    uint32_t childMask = kBDHIDPosition;
    if (phase == BDTouchPhaseDown) childMask = kBDHIDTouch | kBDHIDRange;
    if (phase == BDTouchPhaseUp) childMask = kBDHIDTouch;

    uint64_t timestamp = mach_absolute_time();
    IOHIDEventRef parent = g_createDigitizer(kCFAllocatorDefault, timestamp,
        3, 99, 1, 0, 0, 0, 0, 0, 0, 0, false, false, 0);
    IOHIDEventRef finger = g_createFinger(kCFAllocatorDefault, timestamp,
        1, 3, childMask, x, y, 0, touching ? 1.0 : 0.0, 0,
        touching, touching, 0);
    if (!parent || !finger) {
        if (parent) CFRelease(parent);
        if (finger) CFRelease(finger);
        return NO;
    }

    g_setIntegerValue(parent, kBDHIDBuiltIn, 1);
    g_setIntegerValue(parent, kBDHIDDisplayIntegrated, 1);
    g_setIntegerValue(finger, kBDHIDDisplayIntegrated, 1);
    g_setFloatValue(finger, kBDHIDMajorRadius, 0.04);
    g_setFloatValue(finger, kBDHIDMinorRadius, 0.04);
    g_appendEvent(parent, finger, 0);
    g_setSenderID(parent, 0x8000000817319371ULL);

    if (g_usingSystemDispatch) {
        g_dispatchEvent(g_hidClient, parent);
    } else {
        g_enqueueEvent(parent);
    }

    CFRelease(finger);
    CFRelease(parent);
    return YES;
}

// ===== 滑动手势 =====

static CGFloat randFloat(CGFloat min, CGFloat max) {
    return min + ((CGFloat)arc4random_uniform(10000) / 10000.0) * (max - min);
}

static NSInteger randInt(NSInteger min, NSInteger max) {
    return min + arc4random_uniform((uint32_t)(max - min + 1));
}

// HID 坐标必须是 0.0-1.0；不能直接传 SE2 的 375x667 屏幕点。
static BOOL performSwipe(BOOL up) {
    double startX = randFloat(0.45, 0.55);
    double endX = startX + randFloat(-0.025, 0.025);
    double startY = up ? randFloat(0.80, 0.87) : randFloat(0.24, 0.31);
    double endY = up ? randFloat(0.20, 0.28) : randFloat(0.70, 0.79);
    double controlOffset = randFloat(-0.018, 0.018);
    NSTimeInterval duration = randFloat(kMinSwipe, kMaxSwipe);
    NSInteger steps = MAX(18, (NSInteger)llround(duration / 0.016));

    BOOL started = sendNormalizedTouch(startX, startY, BDTouchPhaseDown);
    if (!started) return NO;
    usleep((useconds_t)randInt(30000, 65000));

    BOOL moved = YES;
    for (NSInteger i = 1; i <= steps; i++) {
        double t = (double)i / (double)steps;
        double eased = t * t * (3.0 - 2.0 * t);
        double curve = 4.0 * t * (1.0 - t) * controlOffset;
        double x = startX + (endX - startX) * eased + curve;
        double y = startY + (endY - startY) * eased;
        if (!sendNormalizedTouch(x, y, BDTouchPhaseMove)) {
            moved = NO;
            break;
        }
        usleep((useconds_t)((duration / (double)steps) * 1000000.0));
    }

    usleep((useconds_t)randInt(12000, 28000));
    BOOL lifted = sendNormalizedTouch(endX, endY, BDTouchPhaseUp);
    return moved && lifted;
}

// 测试版只允许真实 HID 触控；不使用 setContentOffset 伪造页面滚动。
static BOOL performSwipeAuto(BOOL up) {
    if (!hidBackendReady()) return NO;
    BOOL sent = performSwipe(up);
    if (sent) {
        NSLog(@"[BAutoSwipe] %@ dispatched %@ swipe via %@ backend",
              kBAutoSwipeVersion, up ? @"up" : @"down",
              g_usingSystemDispatch ? @"system" : @"enqueue");
    }
    return sent;
}

// ===== 主循环 =====

static BOOL swipeRunIsActive(NSUInteger generation) {
    return g_running && generation == g_runGeneration;
}

static void swipeLoop(NSUInteger generation) {
    BOOL hidFailed = NO;
    while (swipeRunIsActive(generation) && g_swipeCount < kMaxSwipes) {
        @autoreleasepool {
            // 观看视频（随机时长，分段 sleep 以便及时响应停止）
            NSTimeInterval watchTime = randomWatchTime();
            NSTimeInterval watched = 0;
            while (watched < watchTime && swipeRunIsActive(generation)) {
                NSTimeInterval chunk = MIN(randFloat(2, 5), watchTime - watched);
                usleep((useconds_t)(chunk * 1000000));
                watched += chunk;
            }

            if (!swipeRunIsActive(generation)) break;

            // 8% 概率下滑回看
            BOOL goBack = (arc4random_uniform(100) < (uint32_t)(kSwipeDownProbability * 100));
            if (!performSwipeAuto(!goBack)) {
                hidFailed = YES;
                break;
            }
            g_swipeCount++;

            // 更新按钮标题
            dispatch_async(dispatch_get_main_queue(), ^{
                [g_floatingBtn setTitle:[NSString stringWithFormat:@"发%ld次\n停止", (long)g_swipeCount]
                               forState:UIControlStateNormal];
            });

            if (goBack) {
                // 回看后看几秒再滑回来
                usleep(randInt(3, 10) * 1000000);
                if (!swipeRunIsActive(generation)) break;
                if (!performSwipeAuto(YES)) {
                    hidFailed = YES;
                    break;
                }
                g_swipeCount++;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [g_floatingBtn setTitle:[NSString stringWithFormat:@"发%ld次\n停止", (long)g_swipeCount]
                                   forState:UIControlStateNormal];
                });
            }

            // 定期长休息
            if (g_swipeCount >= g_nextRest) {
                NSTimeInterval restTime = randFloat(kRestMin, kRestMax);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [g_floatingBtn setTitle:@"休息中\n停止" forState:UIControlStateNormal];
                });
                NSTimeInterval rested = 0;
                while (rested < restTime && swipeRunIsActive(generation)) {
                    usleep(2000000);
                    rested += 2;
                }
                g_nextRest = g_swipeCount + randInt(kRestMinSwipes, kRestMaxSwipes);
            }
        }
    }

    if (generation == g_runGeneration) {
        g_running = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (hidFailed) {
                [g_floatingBtn setTitle:@"HID失败\n点重试" forState:UIControlStateNormal];
                g_floatingBtn.backgroundColor = [UIColor colorWithRed:0.85 green:0.45 blue:0.05 alpha:0.9];
            } else {
                [g_floatingBtn setTitle:@"开始" forState:UIControlStateNormal];
                g_floatingBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:0.2 alpha:0.85];
            }
        });
    }
}

// ===== 悬浮按钮（挂载到 App 主窗口，避免与其他插件的 UIWindow 冲突）=====

static void toggleRunning(void) {
    if (!g_running) {
        g_running = YES;
        NSUInteger generation = ++g_runGeneration;
        g_swipeCount = 0;
        g_nextRest = randInt(kRestMinSwipes, kRestMaxSwipes);
        g_floatingBtn.backgroundColor = [UIColor colorWithRed:0.8 green:0.2 blue:0.2 alpha:0.85];
        [g_floatingBtn setTitle:@"等待中\n停止" forState:UIControlStateNormal];
        dispatch_async(g_swipeQueue, ^{
            swipeLoop(generation);
        });
    } else {
        g_running = NO;
        ++g_runGeneration;
        g_floatingBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:0.2 alpha:0.85];
        [g_floatingBtn setTitle:@"开始" forState:UIControlStateNormal];
    }
}

static BOOL isFullScreenAppWindow(UIWindow *window, UIWindowScene *scene) {
    if (!window || window.hidden || window.alpha <= 0.0 || window.windowLevel != UIWindowLevelNormal) return NO;
    CGRect sceneBounds = scene.coordinateSpace.bounds;
    CGSize size = window.bounds.size;
    return size.width >= CGRectGetWidth(sceneBounds) * 0.8 &&
           size.height >= CGRectGetHeight(sceneBounds) * 0.8;
}

static UIWindow *foregroundAppWindow(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive ||
            ![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }

        UIWindowScene *windowScene = (UIWindowScene *)scene;
        UIWindow *visibleCandidate = nil;
        for (UIWindow *window in windowScene.windows) {
            if (!isFullScreenAppWindow(window, windowScene)) continue;
            if (window.isKeyWindow) return window;
            if (!visibleCandidate) visibleCandidate = window;
        }
        if (visibleCandidate) return visibleCandidate;
    }
    return nil;
}

static CGRect leftMiddleButtonFrame(UIWindow *window) {
    CGRect bounds = window.bounds;
    UIEdgeInsets safeInsets = window.safeAreaInsets;
    CGFloat x = CGRectGetMinX(bounds) + safeInsets.left + kFloatingButtonMargin;
    CGFloat minimumY = CGRectGetMinY(bounds) + safeInsets.top + kFloatingButtonMargin;
    CGFloat maximumY = CGRectGetMaxY(bounds) - safeInsets.bottom -
                       kFloatingButtonMargin - kFloatingButtonSize;
    CGFloat y = CGRectGetMidY(bounds) - kFloatingButtonSize / 2.0;
    y = MIN(MAX(y, minimumY), maximumY);
    return CGRectMake(x, y, kFloatingButtonSize, kFloatingButtonSize);
}

static UIButton *createFloatingButton(void) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:0.2 alpha:0.88];
    [button setTitle:@"开始" forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    button.titleLabel.numberOfLines = 2;
    button.titleLabel.textAlignment = NSTextAlignmentCenter;
    button.layer.cornerRadius = kFloatingButtonSize / 2.0;
    button.layer.masksToBounds = YES;
    button.autoresizingMask = UIViewAutoresizingFlexibleRightMargin |
                              UIViewAutoresizingFlexibleTopMargin |
                              UIViewAutoresizingFlexibleBottomMargin;
    button.accessibilityLabel = @"百度自动滑屏开始按钮";

    [button addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
        toggleRunning();
    }] forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *drag = [[UIPanGestureRecognizer alloc] initWithTarget:button
                                                                           action:@selector(bdas_handlePan:)];
    [button addGestureRecognizer:drag];
    return button;
}

static void attachFloatingButton(NSUInteger generation, NSInteger retriesRemaining) {
    if (generation != g_buttonAttachGeneration) return;

    UIWindow *targetWindow = foregroundAppWindow();
    if (!targetWindow) {
        if (retriesRemaining > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(kWindowAttachRetryDelay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                attachFloatingButton(generation, retriesRemaining - 1);
            });
        } else {
            NSLog(@"[BAutoSwipe] %@ could not find the full-screen app window", kBAutoSwipeVersion);
        }
        return;
    }

    BOOL needsInitialPosition = !g_floatingBtn || g_floatingBtn.superview != targetWindow;
    if (!g_floatingBtn) g_floatingBtn = createFloatingButton();
    if (g_floatingBtn.superview != targetWindow) {
        [g_floatingBtn removeFromSuperview];
        [targetWindow addSubview:g_floatingBtn];
    }
    if (needsInitialPosition) g_floatingBtn.frame = leftMiddleButtonFrame(targetWindow);

    g_floatingBtn.hidden = NO;
    g_floatingBtn.alpha = 1.0;
    [targetWindow bringSubviewToFront:g_floatingBtn];
    NSLog(@"[BAutoSwipe] %@ button attached to app window frame=%@",
          kBAutoSwipeVersion, NSStringFromCGRect(g_floatingBtn.frame));
}

static void scheduleButtonAttachment(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSUInteger generation = ++g_buttonAttachGeneration;
        attachFloatingButton(generation, kWindowAttachRetryCount);
    });
}

// 用 category 实现拖动，只移动按钮，不创建或移动额外 UIWindow。
@interface UIButton (BDAutoSwipe)
@end

@implementation UIButton (BDAutoSwipe)
- (void)bdas_handlePan:(UIPanGestureRecognizer *)pan {
    UIView *container = self.superview;
    if (!container) return;

    CGPoint translation = [pan translationInView:container];
    CGPoint center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    CGRect bounds = container.bounds;
    UIEdgeInsets safeInsets = container.safeAreaInsets;
    CGFloat halfW = CGRectGetWidth(self.bounds) / 2.0;
    CGFloat halfH = CGRectGetHeight(self.bounds) / 2.0;
    CGFloat minX = CGRectGetMinX(bounds) + safeInsets.left + halfW + kFloatingButtonMargin;
    CGFloat maxX = CGRectGetMaxX(bounds) - safeInsets.right - halfW - kFloatingButtonMargin;
    CGFloat minY = CGRectGetMinY(bounds) + safeInsets.top + halfH + kFloatingButtonMargin;
    CGFloat maxY = CGRectGetMaxY(bounds) - safeInsets.bottom - halfH - kFloatingButtonMargin;
    center.x = MIN(MAX(center.x, minX), maxX);
    center.y = MIN(MAX(center.y, minY), maxY);
    self.center = center;
    [pan setTranslation:CGPointZero inView:container];
}
@end

// ===== 入口 =====

__attribute__((constructor))
static void bdas_init(void) {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (!bundleID || [[bundleID lowercaseString] rangeOfString:@"baidu"].location == NSNotFound) return;

    g_swipeQueue = dispatch_queue_create("com.bdas.autoswipe", DISPATCH_QUEUE_SERIAL);
    NSLog(@"[BAutoSwipe] %@ loaded in %@", kBAutoSwipeVersion, bundleID);

    dispatch_async(dispatch_get_main_queue(), ^{
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        g_didBecomeActiveObserver = [center addObserverForName:UIApplicationDidBecomeActiveNotification
                                                       object:nil
                                                        queue:[NSOperationQueue mainQueue]
                                                   usingBlock:^(__unused NSNotification *notification) {
            scheduleButtonAttachment();
        }];
        g_windowDidBecomeVisibleObserver = [center addObserverForName:UIWindowDidBecomeVisibleNotification
                                                               object:nil
                                                                queue:[NSOperationQueue mainQueue]
                                                           usingBlock:^(__unused NSNotification *notification) {
            scheduleButtonAttachment();
        }];

        hidBackendReady();
        scheduleButtonAttachment();
    });
}
