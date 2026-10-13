#import "JagexAccount.h"
#import "JavaGUIViewController.h"
#import "LauncherPreferences.h"
#import "RuneLiteLauncherViewController.h"
#import "utils.h"

#define RL_ORANGE [UIColor colorWithRed:0.86 green:0.54 blue:0.0 alpha:1.0]
#define RL_BACKGROUND [UIColor colorWithRed:0.09 green:0.09 blue:0.09 alpha:1.0]
#define RL_CARD [UIColor colorWithRed:0.16 green:0.16 blue:0.16 alpha:1.0]

@interface RuneLiteLauncherViewController ()
@property(nonatomic) UIImageView *iconView;
@property(nonatomic) UILabel *subtitleLabel;
@property(nonatomic) UIButton *accountCard;
@property(nonatomic) UIImageView *accountIcon;
@property(nonatomic) UILabel *accountName;
@property(nonatomic) UILabel *accountHint;
@property(nonatomic) UIButton *playButton;
@property(nonatomic) UIActivityIndicatorView *spinner;
@property(nonatomic) UILabel *statusLabel;
@property(nonatomic) BOOL launching;
@end

// Only the settings that matter for RuneLite: how much memory Java may use
@interface RuneLiteSettingsViewController : UITableViewController
@property(nonatomic) UISlider *memorySlider;
@property(nonatomic) UILabel *memoryLabel;
@end

@implementation RuneLiteSettingsViewController

static NSInteger autoMemoryMB(void) {
    // Same ratio JavaLauncher uses for java.auto_ram
    CGFloat ratio = getEntitlementValue(@"com.apple.private.memorystatus") ? 0.4 : 0.25;
    return roundf((NSProcessInfo.processInfo.physicalMemory >> 20) * ratio);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Настройки";

    self.memoryLabel = [[UILabel alloc] init];
    self.memoryLabel.font = [UIFont monospacedDigitSystemFontOfSize:17 weight:UIFontWeightRegular];
    self.memoryLabel.textColor = UIColor.secondaryLabelColor;
    self.memorySlider = [[UISlider alloc] init];
    self.memorySlider.minimumValue = 512;
    self.memorySlider.maximumValue = (NSProcessInfo.processInfo.physicalMemory >> 20) * 0.6;
    self.memorySlider.tintColor = RL_ORANGE;
    [self.memorySlider addTarget:self action:@selector(memoryChanged) forControlEvents:UIControlEventValueChanged];
    [self updateMemory];
}

- (void)updateMemory {
    BOOL automatic = getPrefBool(@"java.auto_ram");
    NSInteger mb = automatic ? autoMemoryMB() : getPrefInt(@"java.allocated_memory");
    self.memorySlider.value = mb;
    self.memorySlider.enabled = !automatic;
    self.memoryLabel.text = [NSString stringWithFormat:@"%ld МБ", (long)mb];
}

- (void)memoryChanged {
    NSInteger mb = lroundf(self.memorySlider.value / 64) * 64;
    setPrefInt(@"java.allocated_memory", mb);
    self.memoryLabel.text = [NSString stringWithFormat:@"%ld МБ", (long)mb];
}

- (void)autoChanged:(UISwitch *)sender {
    setPrefBool(@"java.auto_ram", sender.on);
    if (!sender.on && getPrefInt(@"java.allocated_memory") < self.memorySlider.minimumValue) {
        setPrefInt(@"java.allocated_memory", autoMemoryMB());
    }
    [self updateMemory];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @"Память для RuneLite";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"Больше памяти — меньше подвисаний, но iOS может закрыть игру, если выделить слишком много. Изменения применяются при следующем запуске.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (indexPath.row == 0) {
        cell.textLabel.text = @"Автоматически";
        UISwitch *toggle = [[UISwitch alloc] init];
        toggle.onTintColor = RL_ORANGE;
        toggle.on = getPrefBool(@"java.auto_ram");
        [toggle addTarget:self action:@selector(autoChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    } else {
        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[self.memorySlider, self.memoryLabel]];
        row.spacing = 12;
        row.alignment = UIStackViewAlignmentCenter;
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [self.memoryLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [cell.contentView addSubview:row];
        UILayoutGuide *margins = cell.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [row.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [row.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [row.topAnchor constraintEqualToAnchor:margins.topAnchor],
            [row.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],
        ]];
    }
    return cell;
}

@end

@implementation RuneLiteLauncherViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = RL_BACKGROUND;
    if ([getPrefObject(@"control.control_safe_area") length] == 0) {
        setPrefObject(@"control.control_safe_area", NSStringFromUIEdgeInsets(getDefaultSafeArea()));
    }

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = NO;
    [self.view addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];

    // Header: icon + name
    self.iconView = [[UIImageView alloc] initWithImage:[UIImage imageWithContentsOfFile:
        [NSBundle.mainBundle pathForResource:@"RuneLiteIcon" ofType:@"png"]]];
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    [self.iconView.heightAnchor constraintEqualToConstant:96].active = YES;

    UILabel *title = [[UILabel alloc] init];
    title.text = @"RuneLite";
    title.font = [UIFont systemFontOfSize:34 weight:UIFontWeightBold];
    title.textColor = UIColor.whiteColor;
    title.textAlignment = NSTextAlignmentCenter;

    self.subtitleLabel = [[UILabel alloc] init];
    self.subtitleLabel.text = @"Old School RuneScape";
    self.subtitleLabel.font = [UIFont systemFontOfSize:15];
    self.subtitleLabel.textColor = UIColor.secondaryLabelColor;
    self.subtitleLabel.textAlignment = NSTextAlignmentCenter;

    [stack addArrangedSubview:self.iconView];
    [stack addArrangedSubview:title];
    [stack setCustomSpacing:2 afterView:title];
    [stack addArrangedSubview:self.subtitleLabel];
    [stack setCustomSpacing:28 afterView:self.subtitleLabel];

    [stack addArrangedSubview:[self makeAccountCard]];

    // Play
    self.playButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.playButton.backgroundColor = RL_ORANGE;
    self.playButton.layer.cornerRadius = 14;
    self.playButton.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    self.playButton.tintColor = UIColor.blackColor;
    [self.playButton setTitle:@"Играть" forState:UIControlStateNormal];
    [self.playButton addTarget:self action:@selector(play) forControlEvents:UIControlEventPrimaryActionTriggered];
    [self.playButton.heightAnchor constraintEqualToConstant:56].active = YES;
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.color = UIColor.blackColor;
    self.spinner.hidesWhenStopped = YES;
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.playButton addSubview:self.spinner];
    [NSLayoutConstraint activateConstraints:@[
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.playButton.centerYAnchor],
        [self.spinner.leadingAnchor constraintEqualToAnchor:self.playButton.leadingAnchor constant:20],
    ]];
    [stack addArrangedSubview:self.playButton];
    [stack setCustomSpacing:8 afterView:self.playButton];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.font = [UIFont systemFontOfSize:13];
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    [stack addArrangedSubview:self.statusLabel];
    [stack setCustomSpacing:24 afterView:self.statusLabel];

    [stack addArrangedSubview:[self makeSecondaryButton:@"Настройки" image:@"gearshape" action:@selector(openSettings)]];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSLayoutConstraint *preferredWidth = [stack.widthAnchor constraintEqualToAnchor:safe.widthAnchor constant:-40];
    preferredWidth.priority = UILayoutPriorityDefaultHigh;
    NSLayoutConstraint *centerY = [stack.centerYAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.centerYAnchor];
    centerY.priority = UILayoutPriorityDefaultLow;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [stack.topAnchor constraintGreaterThanOrEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-20],
        [scroll.contentLayoutGuide.heightAnchor constraintGreaterThanOrEqualToAnchor:scroll.frameLayoutGuide.heightAnchor],
        [scroll.contentLayoutGuide.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
        [stack.centerXAnchor constraintEqualToAnchor:scroll.centerXAnchor],
        [stack.widthAnchor constraintLessThanOrEqualToConstant:420],
        preferredWidth, centerY,
    ]];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateAccount)
        name:JagexAccountDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateStatus)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    [self updateAccount];
    [self updateStatus];
    [self checkJITSupport];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self updateAccount];
    [self updateStatus];
    static BOOL autoLaunched;
    // Env var rather than argv: main() treats argc == 2 as the JIT ptrace child
    if (!autoLaunched && getenv("AUTO_RUNELITE")) {
        autoLaunched = YES;
        [self play];
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    // Landscape iPhone: keep everything on one screen
    BOOL compact = self.traitCollection.verticalSizeClass == UIUserInterfaceSizeClassCompact;
    self.iconView.hidden = compact;
    self.subtitleLabel.hidden = compact;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    return YES;
}

#pragma mark - Views

- (UIView *)makeAccountCard {
    self.accountCard = [UIButton buttonWithType:UIButtonTypeCustom];
    self.accountCard.backgroundColor = RL_CARD;
    self.accountCard.layer.cornerRadius = 14;
    [self.accountCard addTarget:self action:@selector(openAccount) forControlEvents:UIControlEventPrimaryActionTriggered];
    [self.accountCard.heightAnchor constraintEqualToConstant:68].active = YES;

    self.accountIcon = [[UIImageView alloc] init];
    self.accountIcon.tintColor = RL_ORANGE;
    self.accountIcon.contentMode = UIViewContentModeScaleAspectFit;
    [self.accountIcon.widthAnchor constraintEqualToConstant:34].active = YES;

    self.accountName = [[UILabel alloc] init];
    self.accountName.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    self.accountName.textColor = UIColor.whiteColor;
    self.accountHint = [[UILabel alloc] init];
    self.accountHint.font = [UIFont systemFontOfSize:13];
    self.accountHint.textColor = UIColor.secondaryLabelColor;
    UIStackView *labels = [[UIStackView alloc] initWithArrangedSubviews:@[self.accountName, self.accountHint]];
    labels.axis = UILayoutConstraintAxisVertical;
    labels.spacing = 2;

    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    chevron.tintColor = UIColor.tertiaryLabelColor;
    [chevron setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[self.accountIcon, labels, chevron]];
    content.axis = UILayoutConstraintAxisHorizontal;
    content.alignment = UIStackViewAlignmentCenter;
    content.spacing = 14;
    content.userInteractionEnabled = NO;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.accountCard addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:self.accountCard.leadingAnchor constant:16],
        [content.trailingAnchor constraintEqualToAnchor:self.accountCard.trailingAnchor constant:-16],
        [content.centerYAnchor constraintEqualToAnchor:self.accountCard.centerYAnchor],
    ]];
    return self.accountCard;
}

- (UIButton *)makeSecondaryButton:(NSString *)title image:(NSString *)imageName action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.backgroundColor = RL_CARD;
    button.layer.cornerRadius = 12;
    button.tintColor = UIColor.whiteColor;
    button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [button setTitle:[@" " stringByAppendingString:title] forState:UIControlStateNormal];
    [button setImage:[UIImage systemImageNamed:imageName] forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventPrimaryActionTriggered];
    [button.heightAnchor constraintEqualToConstant:46].active = YES;
    return button;
}

#pragma mark - State

- (void)updateAccount {
    NSDictionary *session = [JagexAccount current];
    if (!session) {
        self.accountIcon.image = [UIImage systemImageNamed:@"person.crop.circle.badge.plus"];
        self.accountName.text = @"Войти в аккаунт Jagex";
        self.accountHint.text = @"Без входа — экран логина RuneScape";
    } else if (!session[@"characterId"]) {
        self.accountIcon.image = [UIImage systemImageNamed:@"person.crop.circle.badge.questionmark"];
        self.accountName.text = @"Персонаж не выбран";
        self.accountHint.text = @"Нажмите, чтобы выбрать персонажа";
    } else {
        self.accountIcon.image = [UIImage systemImageNamed:@"person.crop.circle.fill"];
        NSString *name = session[@"displayName"];
        self.accountName.text = name.length ? name : @"Новый персонаж";
        self.accountHint.text = @"Аккаунт Jagex · сменить";
    }
}

- (void)updateStatus {
    if (self.launching) return;
    if (isJITEnabled(false)) {
        self.statusLabel.text = @"JIT включён";
    } else if (getEntitlementValue(@"jb.pmap_cs.custom_trust")) {
        self.statusLabel.text = @"JIT включится через TrollStore";
    } else {
        self.statusLabel.text = @"При запуске откроется StikDebug для включения JIT";
    }
}

- (void)setLaunching:(BOOL)launching status:(NSString *)status {
    self.launching = launching;
    self.playButton.enabled = !launching;
    self.playButton.alpha = launching ? 0.7 : 1;
    self.accountCard.enabled = !launching;
    if (launching) {
        [self.spinner startAnimating];
        self.statusLabel.text = status;
    } else {
        [self.spinner stopAnimating];
        [self updateStatus];
    }
}

- (void)checkJITSupport {
    if (getEntitlementValue(@"get-task-allow") || NSProcessInfo.processInfo.macCatalystApp || getenv("SIMULATOR_DEVICE_NAME")) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"login.jit.fail.title", nil)
            message:localize(@"login.jit.fail.description_unsupported", nil)
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDefault handler:^(id action) {
            exit(-1);
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

#pragma mark - Actions

- (void)openAccount {
    [JagexAccount presentMenuFrom:self sourceView:self.accountCard];
}

- (void)openSettings {
    RuneLiteSettingsViewController *prefs = [[RuneLiteSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    prefs.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Готово" style:UIBarButtonItemStyleDone target:self action:@selector(dismissPresented)];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:prefs];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)dismissPresented {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)play {
    if (self.launching) return;

    // RuneLite.jar is bundled; copy it to a writable dir so the launcher can self-manage alongside ~/.runelite
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = [NSString stringWithFormat:@"%s/runelite", getenv("AME_HOME")];
    NSString *jar = [dir stringByAppendingPathComponent:@"RuneLite.jar"];
    NSString *bundled = [NSBundle.mainBundle pathForResource:@"RuneLite" ofType:@"jar"];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    if (bundled && ![fm contentsEqualAtPath:bundled andPath:jar]) {
        [fm removeItemAtPath:jar error:nil];
        [fm copyItemAtPath:bundled toPath:jar error:nil];
    }
    setenv("GAME_DIR", dir.UTF8String, 1);
    [JagexAccount applyEnvironment];

    JavaGUIViewController *vc = [[JavaGUIViewController alloc] init];
    vc.filepath = jar;
    [vc setHitEnterAfterWindowShown:NO];
    if (!vc.requiredJavaVersion) {
        return;
    }
    [self invokeAfterJITEnabled:^{
        [self setLaunching:NO status:nil];
        vc.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:vc animated:YES completion:nil];
    }];
}

- (void)invokeAfterJITEnabled:(void (^)(void))handler {
    if (isJITEnabled(false) || getPrefBool(@"debug.debug_skip_wait_jit")) {
        handler();
        return;
    }

    if (getEntitlementValue(@"jb.pmap_cs.custom_trust")) {
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:[NSString stringWithFormat:@"apple-magnifier://enable-jit?bundle-id=%@", NSBundle.mainBundle.bundleIdentifier]] options:@{} completionHandler:nil];
    } else if (@available(iOS 17.4, *)) {
        NSString *scriptDataString = @"";
        if (DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM)) {
            NSData *scriptData = [NSData dataWithContentsOfFile:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"UniversalJIT26.js"]];
            scriptDataString = [@"&script-data=" stringByAppendingString:[scriptData base64EncodedStringWithOptions:0]];
        }
        NSURL *stikURL = [NSURL URLWithString:[NSString stringWithFormat:@"stikjit://enable-jit?bundle-id=%@&pid=%d%@", NSBundle.mainBundle.bundleIdentifier, getpid(), scriptDataString]];
        // Without StikDebug installed nothing would ever enable JIT; don't leave the player waiting forever
        if (![UIApplication.sharedApplication canOpenURL:stikURL]) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Нужен StikDebug"
                message:@"Чтобы RuneLite работал быстро, iOS требует включить JIT через StikDebug, а он не установлен. Установите StikDebug, импортируйте в нём файл сопряжения и запустите RuneLite снова."
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
            return;
        }
        [UIApplication.sharedApplication openURL:stikURL options:@{} completionHandler:nil];
    } else {
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:[NSString stringWithFormat:@"sidestore://sidejit-enable?pid=%d", getpid()]] options:@{} completionHandler:nil];
    }

    [self setLaunching:YES status:@"Ожидание JIT от StikDebug — игра запустится сама"];
    // While waiting, Play cancels the wait instead of launching
    self.playButton.enabled = YES;
    [self.playButton setTitle:@"Отмена" forState:UIControlStateNormal];
    [self.playButton removeTarget:self action:@selector(play) forControlEvents:UIControlEventPrimaryActionTriggered];
    [self.playButton addTarget:self action:@selector(cancelWait) forControlEvents:UIControlEventPrimaryActionTriggered];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        while (!isJITEnabled(false)) {
            if (!self.launching) return;
            usleep(200 * 1000);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.launching) return;
            [self restorePlayButton];
            handler();
        });
    });
}

- (void)cancelWait {
    [self restorePlayButton];
    [self setLaunching:NO status:nil];
}

- (void)restorePlayButton {
    [self.playButton setTitle:@"Играть" forState:UIControlStateNormal];
    [self.playButton removeTarget:self action:@selector(cancelWait) forControlEvents:UIControlEventPrimaryActionTriggered];
    [self.playButton addTarget:self action:@selector(play) forControlEvents:UIControlEventPrimaryActionTriggered];
}

@end
