#import "customcontrols/ControlLayout.h"
#import "customcontrols/CustomControlsUtils.h"
#import "JavaGUIViewController.h"
#import "JavaLauncher.h"
#import "LauncherPreferences.h"
#import "PLLogOutputView.h"
#import "TrackedTextField.h"
#import "UnzipKit.h"
#import "ios_uikit_bridge.h"
#include "glfw_keycodes.h"
#include "utils.h"

#define SPECIALBTN_LOGOUTPUT -100

static BOOL shouldHitEnterAfterWindowShown;
static SurfaceView* surfaceView;
// RuneLite mode: landscape, fixed render scale and desktop-style touch gestures
static BOOL isRuneLiteMode;
// Horizontal inset (points) keeping RuneLite clear of the rounded corners and the Dynamic Island in landscape
static CGFloat runeLiteSideInset;
#define RUNELITE_RENDER_SCALE 1.5

static jclass class_CTCAndroidInput;
static jmethodID method_ReceiveInput;

void AWTInputBridge_nativeSendData(int type, int i1, int i2, int i3, int i4) {
    if (!runtimeJNIEnvPtr) {
        return;
    }

    if (!method_ReceiveInput) {
        class_CTCAndroidInput = (*runtimeJNIEnvPtr)->FindClass(runtimeJNIEnvPtr, "net/java/openjdk/cacio/ctc/CTCAndroidInput");
        if ((*runtimeJNIEnvPtr)->ExceptionCheck(runtimeJNIEnvPtr) == JNI_TRUE) {
            (*runtimeJNIEnvPtr)->ExceptionClear(runtimeJNIEnvPtr);
            class_CTCAndroidInput = (*runtimeJNIEnvPtr)->FindClass(runtimeJNIEnvPtr, "com/github/caciocavallosilano/cacio/ctc/CTCAndroidInput");
        }
        assert(class_CTCAndroidInput != NULL);
        method_ReceiveInput = (*runtimeJNIEnvPtr)->GetStaticMethodID(runtimeJNIEnvPtr, class_CTCAndroidInput, "receiveData", "(IIIII)V");
        assert(method_ReceiveInput != NULL);
    }

    (*runtimeJNIEnvPtr)->CallStaticVoidMethod(
        runtimeJNIEnvPtr,
        class_CTCAndroidInput,
        method_ReceiveInput,
        type, i1, i2, i3, i4
    );
}

void AWTInputBridge_sendChar(jchar keychar) {
    AWTInputBridge_nativeSendData(EVENT_TYPE_CHAR, (unsigned int)keychar, 0, 0, 0);
}

void AWTInputBridge_sendKey(int keycode) {
    // TODO: iOS -> AWT keycode mapping
    AWTInputBridge_nativeSendData(EVENT_TYPE_KEY, ' ', keycode, 1, 0);
    AWTInputBridge_nativeSendData(EVENT_TYPE_KEY, ' ', keycode, 0, 0);
}

@interface SurfaceView() {
    JNIEnv *surfaceJNIEnv;
    jclass class_CTCScreen;
    jmethodID method_GetRGB;
    int *rgbArray; 
}
@property(nonatomic) CGColorSpaceRef colorSpace;
@end

@implementation SurfaceView
- (void)refreshBuffer {
    if (!runtimeJavaVMPtr) {
        // JVM is not ready yet
        return;
    } else if (!surfaceJNIEnv) {
        // Obtain JNIEnvs
        (*runtimeJavaVMPtr)->AttachCurrentThread(runtimeJavaVMPtr, &surfaceJNIEnv, NULL);
        assert(surfaceJNIEnv);
        dispatch_async(dispatch_get_main_queue(), ^{
            (*runtimeJavaVMPtr)->AttachCurrentThread(runtimeJavaVMPtr, &runtimeJNIEnvPtr, NULL);
            assert(runtimeJNIEnvPtr);
        });

        // Obtain CTCScreen.getCurrentScreenRGB()
        class_CTCScreen = (*surfaceJNIEnv)->FindClass(surfaceJNIEnv, "net/java/openjdk/cacio/ctc/CTCScreen");
        if ((*surfaceJNIEnv)->ExceptionCheck(surfaceJNIEnv) == JNI_TRUE) {
            (*surfaceJNIEnv)->ExceptionClear(surfaceJNIEnv);
            class_CTCScreen = (*surfaceJNIEnv)->FindClass(surfaceJNIEnv, "com/github/caciocavallosilano/cacio/ctc/CTCScreen");
        }
        assert(class_CTCScreen != NULL);
        method_GetRGB = (*surfaceJNIEnv)->GetStaticMethodID(surfaceJNIEnv, class_CTCScreen, "getCurrentScreenRGB", "()[I");
        assert(method_GetRGB != NULL);
        rgbArray = calloc(4, (size_t) (windowWidth * windowHeight));
    }

    jintArray jreRgbArray = (jintArray) (*surfaceJNIEnv)->CallStaticObjectMethod(
        surfaceJNIEnv,
        class_CTCScreen,
        method_GetRGB
    );
    if (!jreRgbArray) {
        return;
    }
    int *tmpArray = (*surfaceJNIEnv)->GetIntArrayElements(surfaceJNIEnv, jreRgbArray, 0);
    memcpy(rgbArray, tmpArray, windowWidth * windowHeight * 4);
    (*surfaceJNIEnv)->ReleaseIntArrayElements(surfaceJNIEnv, jreRgbArray, tmpArray, JNI_ABORT);
    dispatch_async(dispatch_get_main_queue(), ^{
        [surfaceView displayLayer];
    });

    // Wait until something renders at the middle
    if (shouldHitEnterAfterWindowShown && rgbArray[windowWidth/2 + windowWidth*windowHeight/2] != 0) {
        shouldHitEnterAfterWindowShown = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^(void){
            // Auto hit Enter to install immediately
            AWTInputBridge_sendKey('\n');
        });
    }
}

- (void)displayLayer {
    CGDataProviderRef bitmapProvider = CGDataProviderCreateWithData(NULL, rgbArray, windowWidth * windowHeight * 4, NULL);
    CGImageRef bitmap = CGImageCreate(windowWidth, windowHeight, 8, 32, 4 * windowWidth, _colorSpace, kCGImageAlphaFirst | kCGBitmapByteOrder32Little, bitmapProvider, NULL, FALSE, kCGRenderingIntentDefault);

    self.layer.contents = (__bridge id) bitmap;
    CGImageRelease(bitmap);
    CGDataProviderRelease(bitmapProvider);
   //  CGColorSpaceRelease(colorSpace);
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    self.layer.opaque = YES;
    self.colorSpace = CGColorSpaceCreateDeviceRGB();
    return self;
}
@end

@interface ScrollableSurfaceView<UIScrollViewDelegate> : UIScrollView
@property CGRect clickRange, virtualMouseFrame;
@property(nonatomic) UIImageView* mousePointerView;
@property BOOL shouldTriggerClick;
@end

@implementation ScrollableSurfaceView

- (instancetype)initWithFrame:(CGRect)frame {
    surfaceView = [[SurfaceView alloc] initWithFrame:frame];
    self = [super initWithFrame:frame];
    [self addSubview:surfaceView];
    self.delegate = (id)self;

    self.virtualMouseFrame = CGRectMake(frame.size.width / 2, frame.size.height / 2, 18, 27);
    self.mousePointerView = [[UIImageView alloc] initWithFrame:self.virtualMouseFrame];
    self.mousePointerView.hidden = !virtualMouseEnabled;
    self.mousePointerView.image = [UIImage imageNamed:@"MousePointer"];
    [surfaceView addSubview:self.mousePointerView];

    return self;
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    CGPoint location = [touches.anyObject locationInView:self];
    self.clickRange = CGRectMake(location.x - 2, location.y - 2, 5, 5);
    self.shouldTriggerClick = YES;
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesMoved:touches withEvent:event];
    if (isRuneLiteMode) return;
    UITouch *touchEvent = touches.anyObject;
    CGPoint location = [touchEvent locationInView:self];
    if (self.shouldTriggerClick && !CGRectContainsPoint(self.clickRange, location)) {
        self.shouldTriggerClick = NO;
    }

    if (virtualMouseEnabled) {
        CGPoint prevLocation = [touchEvent previousLocationInView:self];
        // Calculate delta
        location.x = (location.x - prevLocation.x) / self.zoomScale;
        location.y = (location.y - prevLocation.y) / self.zoomScale;
        // Update cursor's origin
        _virtualMouseFrame.origin.x = clamp(self.virtualMouseFrame.origin.x + location.x, 0, self.frame.size.width * self.zoomScale);
        _virtualMouseFrame.origin.y = clamp(self.virtualMouseFrame.origin.y + location.y, 0, self.frame.size.height * self.zoomScale);
        self.mousePointerView.frame = self.virtualMouseFrame;
        location = self.virtualMouseFrame.origin;

        CGPoint minimumContentOffset = CGPointMake(-self.contentInset.left, -self.contentInset.top);
        CGPoint maximumContentOffset = CGPointMake(
            MAX(minimumContentOffset.x, self.contentSize.width + self.contentInset.right - self.frame.size.width),
            MAX(minimumContentOffset.y, self.contentSize.height + self.contentInset.bottom - self.frame.size.height));
        // Focus scroll view's content area on virtual mouse
        self.contentOffset = CGPointMake(
            clamp(self.virtualMouseFrame.origin.x * self.zoomScale - self.center.x, minimumContentOffset.x, maximumContentOffset.x),
            clamp(self.virtualMouseFrame.origin.y * self.zoomScale - self.center.y, minimumContentOffset.y, maximumContentOffset.y));
    }

    // Send cursor position to AWT
    CGFloat screenScale = UIScreen.mainScreen.scale * getPrefFloat(@"video.resolution") / 100.0;
    AWTInputBridge_nativeSendData(EVENT_TYPE_CURSOR_POS, (int)(location.x * screenScale), (int)(location.y * screenScale), 0, 0);
}

- (void)scrollViewDidZoom:(UIScrollView *)scrollView {
    if (virtualMouseEnabled) {
        // Keep virtual mouse in the middle of screen while zooming
        _virtualMouseFrame.origin.x = (self.contentOffset.x + self.center.x) / self.zoomScale;
        _virtualMouseFrame.origin.y = (self.contentOffset.y + self.center.y) / self.zoomScale;
        self.mousePointerView.frame = self.virtualMouseFrame;
        // Send cursor position to AWT
        CGFloat screenScale = UIScreen.mainScreen.scale * getPrefFloat(@"video.resolution") / 100.0;
        AWTInputBridge_nativeSendData(EVENT_TYPE_CURSOR_POS, (int)(_virtualMouseFrame.origin.x * screenScale), (int)(_virtualMouseFrame.origin.y * screenScale), 0, 0);
    }
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)view {
    return surfaceView;
}

@end

@interface JavaGUIViewController ()<UIGestureRecognizerDelegate, UITextFieldDelegate>

@property(nonatomic) TrackedTextField* inputTextField;
@property(nonatomic) ControlLayout* ctrlView;
@property(nonatomic) NSArray<UIButton *> *runeLiteSideButtons;
@property(nonatomic) PLLogOutputView* logOutputView;
@property(nonatomic) ScrollableSurfaceView* surfaceScrollView;

@end

@implementation JavaGUIViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    [self.navigationController setNavigationBarHidden:YES animated:NO];
    [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
    [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    virtualMouseEnabled = getPrefBool(@"control.virtmouse_enable");
    isRuneLiteMode = [self.filepath.lastPathComponent isEqualToString:@"RuneLite.jar"];

    CGRect screenBounds = self.view.bounds;
    CGFloat screenScale = UIScreen.mainScreen.scale * getPrefFloat(@"video.resolution") / 100.0;
    if (isRuneLiteMode) {
        // The view may still be portrait here; RuneLite always runs in landscape
        CGSize size = UIScreen.mainScreen.bounds.size;
        // In landscape the side insets equal the portrait top inset (island/notch side); take the largest
        // inset so this works whichever orientation the launcher was in
        UIEdgeInsets insets = UIApplication.sharedApplication.windows.firstObject.safeAreaInsets;
        runeLiteSideInset = MAX(MAX(insets.top, insets.bottom), MAX(insets.left, insets.right));
        screenBounds.size = CGSizeMake(MAX(size.width, size.height) - 2 * runeLiteSideInset, MIN(size.width, size.height));
        screenScale = RUNELITE_RENDER_SCALE;
        virtualMouseEnabled = NO;
    }
    windowWidth = roundf(screenBounds.size.width * screenScale);
    windowHeight = roundf(screenBounds.size.height * screenScale);
    // Resolution should not be odd
    if ((windowWidth % 2) != 0) {
        --windowWidth;
    }
    if ((windowHeight % 2) != 0) {
        --windowHeight;
    }

    self.surfaceScrollView = [[ScrollableSurfaceView alloc] initWithFrame:self.view.frame];
    self.surfaceScrollView.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
    self.surfaceScrollView.minimumZoomScale = 1;
    self.surfaceScrollView.maximumZoomScale = 5;
    self.surfaceScrollView.scrollEnabled = NO;
    [self.view addSubview:self.surfaceScrollView];

    self.inputTextField = [[TrackedTextField alloc] initWithFrame:CGRectMake(0, -32.0, self.view.frame.size.width, 30.0)];
    self.inputTextField.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.inputTextField.delegate = self;
    self.inputTextField.font = [UIFont fontWithName:@"Menlo-Regular" size:20];
    self.inputTextField.clearsOnBeginEditing = YES;
    self.inputTextField.textAlignment = NSTextAlignmentCenter;
    self.inputTextField.sendChar = ^(jchar keychar){
        AWTInputBridge_sendChar(keychar);
    };
    self.inputTextField.sendKey = ^(int key, int scancode, int action, int mods) {
        if (action == 0) return;
        switch (key) {
            case GLFW_KEY_BACKSPACE:
                AWTInputBridge_sendKey('\b'); // VK_BACK_SPACE
                break;
            case GLFW_KEY_ENTER:
                AWTInputBridge_sendKey('\n'); // VK_ENTER;
                break;
            case GLFW_KEY_DPAD_LEFT:
                AWTInputBridge_sendKey(0xE2); // VK_KP_LEFT;
                break;
            case GLFW_KEY_DPAD_RIGHT:
                AWTInputBridge_sendKey(0xE3); // VK_KP_RIGHT;
                break;
        }
    };
    [self.view addSubview:self.inputTextField];

    if (isRuneLiteMode) {
        self.surfaceScrollView.maximumZoomScale = 1;
        [self setupRuneLiteGestures];
    } else {
        UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(surfaceOnClick:)];
        tapGesture.delegate = self;
        tapGesture.numberOfTapsRequired = 1;
        tapGesture.numberOfTouchesRequired = 1;
        tapGesture.cancelsTouchesInView = NO;
        [surfaceView addGestureRecognizer:tapGesture];
    }

    // Borrowing custom controls, might be useful later (full-blown jar launcher with control support?)
    self.ctrlView = [[ControlLayout alloc] initWithFrame:UIEdgeInsetsInsetRect(self.view.frame, self.view.safeAreaInsets)];
    [self.view addSubview:self.ctrlView];
    [self loadCustomControls];
    if (isRuneLiteMode) {
        // The on-screen control layout would cover RuneLite's sidebar; use icons in the empty side band instead
        self.ctrlView.hidden = YES;
        self.runeLiteSideButtons = @[
            [self runeLiteSideButton:@"keyboard" action:@selector(toggleSoftKeyboard)],
            [self runeLiteSideButton:@"text.alignleft" action:@selector(runeLiteToggleLog)],
        ];
    }

    self.logOutputView = [[PLLogOutputView alloc] initWithFrame:self.view.frame];
    self.logOutputView.navController.additionalSafeAreaInsets = self.view.safeAreaInsets;
    [self addChildViewController:self.logOutputView.navController];
    [self.view addSubview:self.logOutputView.navController.view];

    setenv("AME_SKIP_JNI_GLFW", "1", 1);
 
    // Register the display loop
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        CADisplayLink *displayLink = [CADisplayLink displayLinkWithTarget:surfaceView selector:@selector(refreshBuffer)];
        if (@available(iOS 15.0, tvOS 15.0, *)) {
            if(getPrefBool(@"video.max_framerate")) {
                displayLink.preferredFrameRateRange = CAFrameRateRangeMake(30, 120, 120);
            } else {
                displayLink.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
            }
        }
        [displayLink addToRunLoop:NSRunLoop.currentRunLoop forMode:NSRunLoopCommonModes];
        [NSRunLoop.currentRunLoop run];
    });

    
dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        launchJVM(nil, self.filepath, windowWidth, windowHeight, _requiredJavaVersion);
        _requiredJavaVersion = 0;
    });
}

- (void)loadCustomControls {
    NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
    dict[@"version"] = @(4);
    dict[@"scaledAt"] = @(100);
    dict[@"mControlDataList"] = [[NSMutableArray alloc] init];
    //dict[@"mDrawerDataList"] = [[NSMutableArray alloc] init];
    [dict[@"mControlDataList"] addObject:createButton(@"Keyboard",
        (int[]){SPECIALBTN_KEYBOARD,0,0,0},
        @"${margin}", @"${margin}",
        BTN_RECT
    )];
    [dict[@"mControlDataList"] addObject:createButton(localize(@"game.menu.log_output", nil),
        (int[]){SPECIALBTN_LOGOUTPUT,0,0,0},
        @"${right} - ${margin}", @"${margin}",
        BTN_RECT
    )];
    if (isRuneLiteMode) {
        // Mouse buttons are replaced by gestures in RuneLite mode
        [self.ctrlView loadControlLayout:dict];
        for (ControlButton *button in self.ctrlView.subviews) {
            [button addTarget:self action:@selector(executebtn_down:) forControlEvents:UIControlEventTouchDown];
            [button addTarget:self action:@selector(executebtn_up:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
        }
        return;
    }
    [dict[@"mControlDataList"] addObject:createButton(@"Mouse",
        (int[]){SPECIALBTN_VIRTUALMOUSE,0,0,0},
        @"${right} - ${margin}", @"${margin} * 2 + ${height}",
        BTN_RECT
    )];
    [dict[@"mControlDataList"] addObject:createButton(@"PRI",
        (int[]){SPECIALBTN_MOUSEPRI,0,0,0},
        @"${margin}", @"${bottom} - ${margin}",
        BTN_RECT
    )];
    [dict[@"mControlDataList"] addObject:createButton(@"SEC",
        (int[]){SPECIALBTN_MOUSESEC,0,0,0},
        @"${margin} * 2 + ${width}", @"${bottom} - ${margin}",
        BTN_RECT
    )];
    [self.ctrlView loadControlLayout:dict];

    // Implement a subset of custom controls functionalites enough for few buttons
    for (ControlButton *button in self.ctrlView.subviews) {
        [button addTarget:self action:@selector(executebtn_down:) forControlEvents:UIControlEventTouchDown];
        [button addTarget:self action:@selector(executebtn_up:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    }
}

@synthesize requiredJavaVersion = _requiredJavaVersion;
- (int)requiredJavaVersion {
    if (_requiredJavaVersion) {
        return _requiredJavaVersion;
    }

    NSError *error;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:self.filepath error:&error];
    if (error) {
        [self showErrorMessage:error.localizedDescription];
        return _requiredJavaVersion = 0;
    }

    NSData *manifestData = [archive extractDataFromFile:@"META-INF/MANIFEST.MF" error:&error];
    if (error) {
        [self showErrorMessage:error.localizedDescription];
        return _requiredJavaVersion = 0;
    }

    NSString *manifestStr = [[NSString alloc] initWithData:manifestData encoding:NSUTF8StringEncoding];
    NSArray *manifestLines = [manifestStr componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSString *mainClass;
    for (NSString *line in manifestLines) {
        if ([line hasPrefix:@"Main-Class: "]) {
            mainClass = [line substringFromIndex:12];
            break;
        }
    }
    if (!mainClass) {
        [self showErrorMessage:[NSString stringWithFormat:
            localize(@"java.error.missing_main_class", nil), self.filepath.lastPathComponent]];
        return _requiredJavaVersion = 0;
    }
    mainClass = [NSString stringWithFormat:@"%@.class",
        [mainClass stringByReplacingOccurrencesOfString:@"." withString:@"/"]];

    NSData *mainClassData = [archive extractDataFromFile:mainClass error:&error];
    if (error) {
        [self showErrorMessage:error.localizedDescription];
        return _requiredJavaVersion = 0;
    }

    uint32_t magic = OSSwapConstInt32(*(uint32_t*)mainClassData.bytes);
    if (magic != 0xCAFEBABE) {
        [self showErrorMessage:[NSString stringWithFormat:@"Invalid magic number: 0x%x", magic]];
        return _requiredJavaVersion = 0;
    }

    uint16_t *version = (uint16_t *)(mainClassData.bytes+sizeof(magic));
    uint16_t minorVer = OSSwapConstInt16(version[0]);
    uint16_t majorVer = OSSwapConstInt16(version[1]);
    NSLog(@"[ModInstaller] Main class version: %u.%u", majorVer, minorVer);

    return _requiredJavaVersion = MAX(2, majorVer - 44);
}

- (void)showErrorMessage:(NSString *)message {
    surfaceView = nil;
    showDialog(localize(@"Error", nil), message);
}

- (void)setHitEnterAfterWindowShown:(BOOL)hitEnter {
    shouldHitEnterAfterWindowShown = hitEnter;
}

- (void)executebtn:(ControlButton *)sender withAction:(int)action {
    int held = action == ACTION_DOWN;
    for (int i = 0; i < 4; i++) {
        int keycode = ((NSNumber *)sender.properties[@"keycodes"][i]).intValue;
        if (keycode < 0) {
            switch (keycode) {
                case SPECIALBTN_KEYBOARD:
                    if (held) return;
                    [self toggleSoftKeyboard];
                    break;

                case SPECIALBTN_MOUSEPRI:
                    AWTInputBridge_nativeSendData(EVENT_TYPE_MOUSE_BUTTON, BUTTON1_DOWN_MASK, held, 0, 0);
                    break;

                case SPECIALBTN_MOUSEMID:
                    AWTInputBridge_nativeSendData(EVENT_TYPE_MOUSE_BUTTON, BUTTON2_DOWN_MASK, held, 0, 0);
                    break;

                case SPECIALBTN_MOUSESEC:
                    AWTInputBridge_nativeSendData(EVENT_TYPE_MOUSE_BUTTON, BUTTON3_DOWN_MASK, held, 0, 0);
                    break;

                case SPECIALBTN_VIRTUALMOUSE:
                    if (held) break;
                    virtualMouseEnabled = !virtualMouseEnabled;
                    self.surfaceScrollView.mousePointerView.hidden = !virtualMouseEnabled;
                    setPrefBool(@"control.virtmouse_enable", virtualMouseEnabled);
                    break;

                case SPECIALBTN_LOGOUTPUT:
                    if (held) break;
                    [self.logOutputView actionToggleLogOutput];
                    break;

                default:
                    NSLog(@"Warning: button %@ sent unknown special keycode: %d", sender.titleLabel.text, keycode);
                    break;
            }
        } else if (keycode > 0) {
            // unimplemented
        }
    }
}

- (void)executebtn_down:(ControlButton *)button {
    [self executebtn:button withAction:ACTION_DOWN];
}

- (void)executebtn_up:(ControlButton *)button {
    [self executebtn:button withAction:ACTION_UP];
}

- (void)surfaceOnClick:(UITapGestureRecognizer *)sender {
    if (!self.surfaceScrollView.shouldTriggerClick) return;
    if (sender.state == UIGestureRecognizerStateRecognized) {
        CGFloat screenScale = UIScreen.mainScreen.scale * getPrefFloat(@"video.resolution") / 100.0;
        CGPoint location = virtualMouseEnabled ?
            self.surfaceScrollView.virtualMouseFrame.origin:
            [sender locationInView:sender.view];
        CGFloat x = location.x * screenScale;
        CGFloat y = location.y * screenScale;
        AWTInputBridge_nativeSendData(EVENT_TYPE_CURSOR_POS, (int)x, (int)y, 0, 0);
        AWTInputBridge_nativeSendData(EVENT_TYPE_MOUSE_BUTTON, BUTTON1_DOWN_MASK, 1, 0, 0);
        AWTInputBridge_nativeSendData(EVENT_TYPE_MOUSE_BUTTON, BUTTON1_DOWN_MASK, 0, 0, 0);
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    self.inputTextField.sendKey(GLFW_KEY_ENTER, 0, 1, 0);
    //self.inputTextField.sendKey(GLFW_KEY_ENTER, 0, 0, 0);
    textField.text = @"";
    return YES;
}


- (void)toggleSoftKeyboard {
    if (self.inputTextField.isFirstResponder) {
        [self.inputTextField resignFirstResponder];
    } else {
        [self.inputTextField becomeFirstResponder];
    }
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext>  _Nonnull context) {
        self.ctrlView.frame = UIEdgeInsetsInsetRect(self.view.frame, self.view.safeAreaInsets);
        [self.ctrlView.subviews makeObjectsPerformSelector:@selector(update)];
    } completion:^(id<UIViewControllerTransitionCoordinatorContext>  _Nonnull context) {
        self.surfaceScrollView.virtualMouseFrame = self.surfaceScrollView.mousePointerView.frame;
    }];
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!isRuneLiteMode) return;
    // Views are created before the landscape rotation; the surface has no autoresizing of its own.
    // Keep it between the side insets so RuneLite's sidebar isn't hidden under the screen corners.
    CGRect content = CGRectInset(self.view.bounds, runeLiteSideInset, 0);
    self.surfaceScrollView.frame = content;
    self.surfaceScrollView.contentSize = content.size;
    surfaceView.frame = (CGRect){CGPointZero, content.size};
    // Side buttons live in the left band, clear of the Dynamic Island in the middle of the edge
    CGFloat bandCenter = runeLiteSideInset / 2;
    CGFloat height = self.view.bounds.size.height;
    for (NSUInteger i = 0; i < self.runeLiteSideButtons.count; i++) {
        self.runeLiteSideButtons[i].center = CGPointMake(MAX(bandCenter, 22), i == 0 ? height * 0.2 : height * 0.8);
    }
    CGRect ctrlFrame = UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets);
    if (!CGRectEqualToRect(self.ctrlView.frame, ctrlFrame)) {
        self.ctrlView.frame = ctrlFrame;
        [self.ctrlView.subviews makeObjectsPerformSelector:@selector(update)];
    }
}

- (UIButton *)runeLiteSideButton:(NSString *)symbol action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(0, 0, 44, 44);
    [button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    button.tintColor = [UIColor colorWithWhite:1 alpha:0.6];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:button];
    return button;
}

- (void)runeLiteToggleLog {
    [self.logOutputView actionToggleLogOutput];
}

#pragma mark - RuneLite gestures

// Touch controls modelled on OSRS mobile:
//   tap                      -> left click (near-misses snap to RuneLite's small Swing buttons)
//   drag on the game         -> rotate the camera (middle-button drag)
//   drag on RuneLite panels  -> scroll (mouse wheel)
//   pinch                    -> zoom (mouse wheel)
//   hold, release            -> right click (menu)
//   hold, then drag          -> left-button drag (move inventory items, sliders)

static jclass runeLiteSupportClass(void) {
    static jclass cls;
    if (!cls && runtimeJNIEnvPtr) {
        jclass local = (*runtimeJNIEnvPtr)->FindClass(runtimeJNIEnvPtr, "net/kdt/pojavlaunch/uikit/RuneLiteSupport");
        if (local) {
            cls = (*runtimeJNIEnvPtr)->NewGlobalRef(runtimeJNIEnvPtr, local);
        } else {
            (*runtimeJNIEnvPtr)->ExceptionClear(runtimeJNIEnvPtr);
        }
    }
    return cls;
}

static void runeLiteWheel(CGPoint at, int amount) {
    static jmethodID wheel;
    jclass cls = runeLiteSupportClass();
    if (!cls) return;
    if (!wheel) wheel = (*runtimeJNIEnvPtr)->GetStaticMethodID(runtimeJNIEnvPtr, cls, "mouseWheel", "(III)V");
    (*runtimeJNIEnvPtr)->CallStaticVoidMethod(runtimeJNIEnvPtr, cls, wheel, (int)at.x, (int)at.y, amount);
    if ((*runtimeJNIEnvPtr)->ExceptionCheck(runtimeJNIEnvPtr)) (*runtimeJNIEnvPtr)->ExceptionClear(runtimeJNIEnvPtr);
}

// Caciocavallo only maps the left button correctly; tell the Java side which button is really pressed
static void runeLiteMouseButton(int mask, BOOL down) {
    if (down) {
        static jmethodID setActive;
        jclass cls = runeLiteSupportClass();
        if (cls) {
            if (!setActive) setActive = (*runtimeJNIEnvPtr)->GetStaticMethodID(runtimeJNIEnvPtr, cls, "setActiveButton", "(I)V");
            int button = mask == BUTTON3_DOWN_MASK ? 3 : mask == BUTTON2_DOWN_MASK ? 2 : 1;
            (*runtimeJNIEnvPtr)->CallStaticVoidMethod(runtimeJNIEnvPtr, cls, setActive, button);
            if ((*runtimeJNIEnvPtr)->ExceptionCheck(runtimeJNIEnvPtr)) (*runtimeJNIEnvPtr)->ExceptionClear(runtimeJNIEnvPtr);
        }
    }
    AWTInputBridge_nativeSendData(EVENT_TYPE_MOUSE_BUTTON, mask, down, 0, 0);
}

static BOOL runeLiteIsOverGame(int x, int y) {
    static jmethodID method;
    jclass cls = runeLiteSupportClass();
    if (!cls) return YES;
    if (!method) method = (*runtimeJNIEnvPtr)->GetStaticMethodID(runtimeJNIEnvPtr, cls, "isOverGame", "(II)Z");
    jboolean result = (*runtimeJNIEnvPtr)->CallStaticBooleanMethod(runtimeJNIEnvPtr, cls, method, x, y);
    if ((*runtimeJNIEnvPtr)->ExceptionCheck(runtimeJNIEnvPtr)) {
        (*runtimeJNIEnvPtr)->ExceptionClear(runtimeJNIEnvPtr);
        return YES;
    }
    return result;
}

- (void)setupRuneLiteGestures {
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(runeLiteTap:)];
    [surfaceView addGestureRecognizer:tap];

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(runeLiteLongPress:)];
    longPress.minimumPressDuration = 0.35;
    [surfaceView addGestureRecognizer:longPress];

    UIPanGestureRecognizer *drag = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(runeLiteDrag:)];
    drag.minimumNumberOfTouches = 1;
    drag.maximumNumberOfTouches = 1;
    [surfaceView addGestureRecognizer:drag];

    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(runeLitePinch:)];
    [surfaceView addGestureRecognizer:pinch];

    [tap requireGestureRecognizerToFail:longPress];
}

- (CGPoint)runeLiteBufferPoint:(UIGestureRecognizer *)sender {
    CGPoint p = [sender locationInView:surfaceView];
    return CGPointMake((int)(p.x * windowWidth / surfaceView.bounds.size.width),
                       (int)(p.y * windowHeight / surfaceView.bounds.size.height));
}

- (void)runeLiteMoveTo:(UIGestureRecognizer *)sender {
    [self runeLiteMoveTo:sender snapToButtons:NO];
}

- (void)runeLiteMoveTo:(UIGestureRecognizer *)sender snapToButtons:(BOOL)snap {
    CGPoint p = [self runeLiteBufferPoint:sender];
    int x = p.x, y = p.y;
    jclass cls = snap ? runeLiteSupportClass() : NULL;
    if (cls) {
        // Let near-misses on RuneLite's small Swing buttons (sidebar tabs etc.) still hit them
        static jmethodID snapMethod;
        if (!snapMethod) snapMethod = (*runtimeJNIEnvPtr)->GetStaticMethodID(runtimeJNIEnvPtr, cls, "snapToButton", "(II)J");
        jlong packed = (*runtimeJNIEnvPtr)->CallStaticLongMethod(runtimeJNIEnvPtr, cls, snapMethod, x, y);
        if ((*runtimeJNIEnvPtr)->ExceptionCheck(runtimeJNIEnvPtr)) {
            (*runtimeJNIEnvPtr)->ExceptionClear(runtimeJNIEnvPtr);
        } else {
            x = (int)(packed >> 32);
            y = (int)(packed & 0xffffffff);
        }
    }
    NSDebugLog(@"[RuneLite] %@ state=%ld -> (%d, %d) of %dx%d", NSStringFromClass(sender.class), (long)sender.state, x, y, windowWidth, windowHeight);
    AWTInputBridge_nativeSendData(EVENT_TYPE_CURSOR_POS, x, y, 0, 0);
}

- (void)runeLiteClick:(int)button {
    runeLiteMouseButton(button, YES);
    // The game polls input on its own tick; an instant press+release can be missed
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        runeLiteMouseButton(button, NO);
    });
}

- (void)runeLiteTap:(UITapGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateRecognized) return;
    [self runeLiteMoveTo:sender snapToButtons:YES];
    [self runeLiteClick:BUTTON1_DOWN_MASK];
}

// Hold: release in place opens the menu; moving after the hold drags with the left button
- (void)runeLiteLongPress:(UILongPressGestureRecognizer *)sender {
    static CGPoint start;
    static BOOL dragging;
    CGPoint p = [self runeLiteBufferPoint:sender];
    switch (sender.state) {
        case UIGestureRecognizerStateBegan: {
            start = p;
            dragging = NO;
            [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
            [self runeLiteMoveTo:sender];
            break;
        }
        case UIGestureRecognizerStateChanged:
            if (!dragging && hypot(p.x - start.x, p.y - start.y) > 12 * RUNELITE_RENDER_SCALE) {
                dragging = YES;
                AWTInputBridge_nativeSendData(EVENT_TYPE_CURSOR_POS, (int)start.x, (int)start.y, 0, 0);
                runeLiteMouseButton(BUTTON1_DOWN_MASK, YES);
            }
            if (dragging) [self runeLiteMoveTo:sender];
            break;
        case UIGestureRecognizerStateEnded:
            if (dragging) {
                [self runeLiteMoveTo:sender];
                runeLiteMouseButton(BUTTON1_DOWN_MASK, NO);
            } else {
                [self runeLiteMoveTo:sender];
                [self runeLiteClick:BUTTON3_DOWN_MASK];
            }
            dragging = NO;
            break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            if (dragging) runeLiteMouseButton(BUTTON1_DOWN_MASK, NO);
            dragging = NO;
            break;
        default:
            break;
    }
}

// Drag: rotate the camera over the game (the game's own middle-button drag, which handles speed and
// wrapping past north), scroll over RuneLite's panels
- (void)runeLiteDrag:(UIPanGestureRecognizer *)sender {
    static BOOL camera, cameraPressed;
    static NSUInteger gestureId;
    static CGFloat scrolled;
    CGPoint p = [self runeLiteBufferPoint:sender];
    if (sender.state == UIGestureRecognizerStateBegan) {
        // Decide from where the finger went down, not where the pan was recognised
        CGPoint t = [sender translationInView:surfaceView];
        CGPoint origin = CGPointMake(p.x - t.x * windowWidth / surfaceView.bounds.size.width,
                                     p.y - t.y * windowHeight / surfaceView.bounds.size.height);
        camera = runeLiteIsOverGame((int)origin.x, (int)origin.y);
        scrolled = 0;
        if (camera) {
            // The game samples the mouse once per frame. Pressing in the same frame as the jump from the
            // previous drag's end point would count that jump as rotation, so let it see the new position first.
            cameraPressed = NO;
            NSUInteger thisGesture = ++gestureId;
            AWTInputBridge_nativeSendData(EVENT_TYPE_CURSOR_POS, (int)origin.x, (int)origin.y, 0, 0);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                if (thisGesture != gestureId || !camera) return;
                runeLiteMouseButton(BUTTON2_DOWN_MASK, YES);
                cameraPressed = YES;
                [self runeLiteMoveTo:sender];
            });
        } else {
            [self runeLiteMoveTo:sender];
        }
    }
    if (camera) {
        if (sender.state >= UIGestureRecognizerStateEnded) {
            ++gestureId;
            if (cameraPressed) {
                [self runeLiteMoveTo:sender];
                runeLiteMouseButton(BUTTON2_DOWN_MASK, NO);
            }
            cameraPressed = NO;
        } else if (cameraPressed) {
            [self runeLiteMoveTo:sender];
        }
        return;
    }
    // Natural scrolling: content follows the finger, one wheel notch per ~16pt
    CGFloat dy = [sender translationInView:surfaceView].y;
    const CGFloat notch = 16;
    while (dy - scrolled <= -notch) { scrolled -= notch; runeLiteWheel(p, 1); }
    while (dy - scrolled >= notch) { scrolled += notch; runeLiteWheel(p, -1); }
}

- (void)runeLitePinch:(UIPinchGestureRecognizer *)sender {
    static CGFloat lastScale;
    if (sender.state == UIGestureRecognizerStateBegan) {
        lastScale = 1;
        [self runeLiteMoveTo:sender];
    }
    // One wheel notch per 6% of pinch; scrolling up (negative) zooms in
    const CGFloat step = 1.06;
    CGPoint at = [self runeLiteBufferPoint:sender];
    while (sender.scale > lastScale * step) {
        lastScale *= step;
        runeLiteWheel(at, -1);
    }
    while (sender.scale < lastScale / step) {
        lastScale /= step;
        runeLiteWheel(at, 1);
    }
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return isRuneLiteMode ? UIInterfaceOrientationMaskLandscape : UIInterfaceOrientationMaskAll;
}

- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    return UIRectEdgeBottom;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    return NO;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

@end
