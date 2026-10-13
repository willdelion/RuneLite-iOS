#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#import <WebKit/WebKit.h>
#import "JagexAccount.h"

static NSString *const kOrigin = @"https://account.jagex.com";
static NSString *const kLauncherClientId = @"com_jagex_auth_desktop_launcher";
static NSString *const kLauncherRedirect = @"https://secure.runescape.com/m=weblogin/launcher-redirect";
// Client used for the game session consent step; it redirects to http://localhost with a fragment
static NSString *const kConsentClientId = @"1fddee4e-b100-4f4e-b2b0-097f9088f9d2";
static NSString *const kGameSessionAPI = @"https://auth.jagex.com/game-session/v1";

NSNotificationName const JagexAccountDidChangeNotification = @"JagexAccountDidChange";

static NSString *const kKeychainService = @"runelite.jagex-account";

#pragma mark - Helpers

static NSString *base64URL(NSData *data) {
    NSString *s = [data base64EncodedStringWithOptions:0];
    s = [s stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    s = [s stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [s stringByReplacingOccurrencesOfString:@"=" withString:@""];
}

static NSString *randomURLSafeString(NSUInteger bytes) {
    NSMutableData *data = [NSMutableData dataWithLength:bytes];
    if (SecRandomCopyBytes(kSecRandomDefault, bytes, data.mutableBytes) != errSecSuccess) {
        arc4random_buf(data.mutableBytes, bytes);
    }
    return base64URL(data);
}

static NSString *sha256Base64URL(NSString *input) {
    NSData *data = [input dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    return base64URL([NSData dataWithBytes:digest length:sizeof(digest)]);
}

static NSString *queryString(NSDictionary<NSString *, NSString *> *params) {
    NSURLComponents *c = [NSURLComponents new];
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *key in params) {
        [items addObject:[NSURLQueryItem queryItemWithName:key value:params[key]]];
    }
    c.queryItems = items;
    // NSURLComponents leaves '+' alone, which form decoding would read as a space
    return [c.percentEncodedQuery stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"];
}

static NSDictionary *parseParams(NSString *s) {
    NSURLComponents *c = [NSURLComponents new];
    c.percentEncodedQuery = s;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in c.queryItems) {
        if (item.value) out[item.name] = item.value;
    }
    return out;
}

static NSDictionary *jwtPayload(NSString *jwt) {
    NSArray *parts = [jwt componentsSeparatedByString:@"."];
    if (parts.count != 3) return nil;
    NSString *b64 = [[parts[1] stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
        stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    while (b64.length % 4) b64 = [b64 stringByAppendingString:@"="];
    NSData *data = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
}

static void sendRequest(NSURLRequest *request, void (^completion)(id json, NSString *error)) {
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *message = nil;
        if (error) {
            message = error.localizedDescription;
        } else if (status != 200 || !json) {
            // Error bodies are OAuth error codes/descriptions, never tokens
            NSString *body = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
            if (body.length > 300) body = [body substringToIndex:300];
            message = [NSString stringWithFormat:@"%@ returned HTTP %ld %@", request.URL.path, (long)status, body ?: @""];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(message ? nil : json, message);
        });
    }] resume];
}

#pragma mark - Login view controller

@interface JagexLoginViewController : UIViewController <WKNavigationDelegate>
@property(nonatomic) WKWebView *webView;
@property(nonatomic) UIActivityIndicatorView *spinner;
@property(nonatomic, copy) NSString *verifier, *state, *nonce;
@property(nonatomic, copy) void (^completion)(NSString *sessionId, NSString *error);
@property(nonatomic) BOOL finished;
// Each redirect must be handled once: cancelling it also reports a failed load for the same URL,
// and replaying the one-time authorization code makes the token endpoint answer HTTP 400
@property(nonatomic) BOOL codeHandled, consentHandled;
@end

@implementation JagexLoginViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Jagex Account";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];

    WKWebViewConfiguration *config = [WKWebViewConfiguration new];
    // Fresh login every time; don't keep Jagex web cookies around
    config.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:config];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.navigationDelegate = self;
    [self.view addSubview:self.webView];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.spinner.center = self.view.center;
    self.spinner.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin |
        UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    self.spinner.hidesWhenStopped = YES;
    [self.view addSubview:self.spinner];

    self.verifier = randomURLSafeString(48);
    self.state = randomURLSafeString(16);
    NSString *url = [NSString stringWithFormat:@"%@/oauth2/auth?%@", kOrigin, queryString(@{
        @"auth_method": @"",
        @"login_type": @"",
        @"flow": @"launcher",
        @"response_type": @"code",
        @"client_id": kLauncherClientId,
        @"redirect_uri": kLauncherRedirect,
        @"code_challenge": sha256Base64URL(self.verifier),
        @"code_challenge_method": @"S256",
        @"prompt": @"login",
        @"scope": @"openid offline gamesso.token.create user.profile.read",
        @"state": self.state,
    })];
    [self.webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:url]]];
}

- (void)cancel {
    [self finishWithSession:nil error:nil];
}

- (void)finishWithSession:(NSString *)sessionId error:(NSString *)error {
    if (self.finished) return;
    self.finished = YES;
    [self.webView stopLoading];
    void (^completion)(NSString *, NSString *) = self.completion;
    [self dismissViewControllerAnimated:YES completion:^{
        if (completion) completion(sessionId, error);
    }];
}

- (void)setBusy:(BOOL)busy {
    self.webView.hidden = busy;
    busy ? [self.spinner startAnimating] : [self.spinner stopAnimating];
}

// Both redirects of the flow point at pages we must not load; intercept them here
- (BOOL)handleURL:(NSURL *)url {
    if (!url) return NO;
    if ([url.absoluteString hasPrefix:kLauncherRedirect]) {
        if (self.codeHandled) return YES;
        self.codeHandled = YES;
        NSDictionary *params = parseParams(url.query);
        if (![params[@"state"] isEqualToString:self.state] || !params[@"code"]) {
            [self finishWithSession:nil error:params[@"error_description"] ?: @"Unexpected response from the Jagex login page."];
        } else {
            [self exchangeCode:params[@"code"]];
        }
        return YES;
    }
    if ([url.host isEqualToString:@"localhost"]) {
        if (self.consentHandled) return YES;
        self.consentHandled = YES;
        NSDictionary *params = parseParams(url.fragment ?: url.query);
        NSString *idToken = params[@"id_token"];
        if (![params[@"state"] isEqualToString:self.state] || !idToken) {
            [self finishWithSession:nil error:params[@"error_description"] ?: @"Jagex did not grant a game session."];
        } else if (![jwtPayload(idToken)[@"nonce"] isEqualToString:self.nonce]) {
            [self finishWithSession:nil error:@"Invalid id_token received from Jagex."];
        } else {
            [self createGameSession:idToken];
        }
        return YES;
    }
    return NO;
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    if ([self handleURL:action.request.URL]) {
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    // A redirect to http://localhost may surface as a failed load instead of a navigation action
    NSURL *failing = error.userInfo[NSURLErrorFailingURLErrorKey];
    if ([self handleURL:failing]) return;
    if (error.code == NSURLErrorCancelled || error.code == 102 /* WebKit frame load interrupted */) return;
    [self finishWithSession:nil error:error.localizedDescription];
}

// Step 2: exchange the launcher's authorization code for tokens
- (void)exchangeCode:(NSString *)code {
    [self setBusy:YES];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[kOrigin stringByAppendingString:@"/oauth2/token"]]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    req.HTTPBody = [queryString(@{
        @"grant_type": @"authorization_code",
        @"client_id": kLauncherClientId,
        @"code": code,
        @"code_verifier": self.verifier,
        @"redirect_uri": kLauncherRedirect,
    }) dataUsingEncoding:NSUTF8StringEncoding];
    sendRequest(req, ^(NSDictionary *json, NSString *error) {
        NSString *idToken = json[@"id_token"];
        if (!idToken) {
            [self finishWithSession:nil error:error ?: @"No id_token in the Jagex token response."];
            return;
        }
        [self requestConsent:idToken];
    });
}

// Step 3: ask for a game-session id_token (normally invisible, auto-approved)
- (void)requestConsent:(NSString *)launcherIdToken {
    self.nonce = NSUUID.UUID.UUIDString;
    self.state = randomURLSafeString(16);
    NSString *url = [NSString stringWithFormat:@"%@/oauth2/auth?%@", kOrigin, queryString(@{
        @"id_token_hint": launcherIdToken,
        @"nonce": self.nonce,
        @"prompt": @"consent",
        @"redirect_uri": @"http://localhost",
        @"response_type": @"id_token code",
        @"state": self.state,
        @"client_id": kConsentClientId,
        @"scope": @"openid offline",
    })];
    [self setBusy:NO];
    [self.webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:url]]];
}

// Step 4: create the game session the client logs in with
- (void)createGameSession:(NSString *)idToken {
    [self setBusy:YES];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[kGameSessionAPI stringByAppendingString:@"/sessions"]]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"idToken": idToken} options:0 error:nil];
    sendRequest(req, ^(NSDictionary *json, NSString *error) {
        NSString *sessionId = json[@"sessionId"];
        [self finishWithSession:sessionId error:sessionId ? nil : (error ?: @"No sessionId in the Jagex response.")];
    });
}

@end

#pragma mark - JagexAccount

// The launcher menu that starts sign-in is often dismissed by the time a later step needs to show
// something (iPhone split view), and presenting from an off-screen controller silently does nothing
static UIViewController *topPresenter(UIViewController *fallback) {
    UIViewController *vc = fallback.view.window.rootViewController ?: UIApplication.sharedApplication.windows.firstObject.rootViewController;
    while (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) {
        vc = vc.presentedViewController;
    }
    return vc ?: fallback;
}

@implementation JagexAccount

+ (NSDictionary *)keychainQuery {
    return @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kKeychainService,
        (__bridge id)kSecAttrAccount: @"session",
    };
}

// Some sideloading setups sign without a keychain access group; fall back to a protected file then
+ (NSString *)fallbackPath {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [dir stringByAppendingPathComponent:@"jagex-session.json"];
}

+ (NSDictionary *)current {
    NSMutableDictionary *query = [self keychainQuery].mutableCopy;
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    NSData *data = nil;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) == errSecSuccess && result) {
        data = (__bridge_transfer NSData *)result;
    } else {
        data = [NSData dataWithContentsOfFile:[self fallbackPath]];
    }
    if (!data) return nil;
    NSDictionary *session = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [session isKindOfClass:NSDictionary.class] && session[@"sessionId"] ? session : nil;
}

+ (BOOL)save:(NSDictionary *)session {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:JagexAccountDidChangeNotification object:nil];
    });
    SecItemDelete((__bridge CFDictionaryRef)[self keychainQuery]);
    NSMutableDictionary *item = [self keychainQuery].mutableCopy;
    item[(__bridge id)kSecValueData] = [NSJSONSerialization dataWithJSONObject:session options:0 error:nil];
    item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    if (status == errSecSuccess) {
        [NSFileManager.defaultManager removeItemAtPath:[self fallbackPath] error:nil];
        return YES;
    }
    NSLog(@"[JagexAccount] Keychain unavailable (%d), storing session in a protected file", (int)status);
    NSString *path = [self fallbackPath];
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    return [item[(__bridge id)kSecValueData] writeToFile:path
        options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:nil];
}

+ (void)signOut {
    SecItemDelete((__bridge CFDictionaryRef)[self keychainQuery]);
    [NSFileManager.defaultManager removeItemAtPath:[self fallbackPath] error:nil];
    [NSNotificationCenter.defaultCenter postNotificationName:JagexAccountDidChangeNotification object:nil];
}

+ (void)applyEnvironment {
    NSDictionary *session = [self current];
    NSLog(@"[JagexAccount] Launching %@", session[@"characterId"] ? [NSString stringWithFormat:@"with Jagex session for %@", session[@"displayName"] ?: @"<new character>"] : @"without a Jagex session");
    if (session[@"characterId"]) {
        setenv("JX_SESSION_ID", [session[@"sessionId"] UTF8String], 1);
        setenv("JX_CHARACTER_ID", [session[@"characterId"] UTF8String], 1);
        // New characters have no display name yet; the client handles an empty one
        setenv("JX_DISPLAY_NAME", [session[@"displayName"] ?: @"" UTF8String], 1);
    } else {
        unsetenv("JX_SESSION_ID");
        unsetenv("JX_CHARACTER_ID");
        unsetenv("JX_DISPLAY_NAME");
    }
    unsetenv("JX_ACCESS_TOKEN");
    unsetenv("JX_REFRESH_TOKEN");
}

+ (void)showError:(NSString *)message from:(UIViewController *)vc {
    NSLog(@"[JagexAccount] Error: %@", message);
    vc = topPresenter(vc);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Jagex Account"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:alert animated:YES completion:nil];
}

+ (void)presentLoginFrom:(UIViewController *)vc completion:(void (^)(NSDictionary *))completion {
    JagexLoginViewController *login = [JagexLoginViewController new];
    login.completion = ^(NSString *sessionId, NSString *error) {
        NSLog(@"[JagexAccount] Sign-in finished: %@", sessionId ? @"game session created" : (error ?: @"cancelled"));
        if (!sessionId) {
            if (error) [self showError:error from:vc];
            if (completion) completion(nil);
            return;
        }
        [self chooseCharacterForSession:sessionId from:vc sourceView:vc.view completion:completion];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:login];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [topPresenter(vc) presentViewController:nav animated:YES completion:nil];
}

+ (void)chooseCharacterForSession:(NSString *)sessionId from:(UIViewController *)vc sourceView:(UIView *)sourceView completion:(void (^)(NSDictionary *))completion {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[kGameSessionAPI stringByAppendingString:@"/accounts"]]];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [req setValue:[@"Bearer " stringByAppendingString:sessionId] forHTTPHeaderField:@"Authorization"];
    sendRequest(req, ^(NSArray *accounts, NSString *error) {
        NSLog(@"[JagexAccount] Accounts response: %lu character(s)%@", (unsigned long)([accounts isKindOfClass:NSArray.class] ? accounts.count : 0), error ? [@", error: " stringByAppendingString:error] : @"");
        if (![accounts isKindOfClass:NSArray.class] || accounts.count == 0) {
            [self showError:error ?: @"No RuneScape characters found on this Jagex Account." from:vc];
            if (completion) completion(nil);
            return;
        }
        void (^pick)(NSDictionary *) = ^(NSDictionary *account) {
            NSMutableDictionary *session = [NSMutableDictionary dictionaryWithObject:sessionId forKey:@"sessionId"];
            session[@"characterId"] = [account[@"accountId"] description];
            if ([account[@"displayName"] isKindOfClass:NSString.class]) {
                session[@"displayName"] = account[@"displayName"];
            }
            BOOL saved = [self save:session];
            NSLog(@"[JagexAccount] Selected character %@ (saved: %@)", session[@"displayName"] ?: @"<new>", saved ? @"YES" : @"NO");
            if (completion) completion(session);
        };
        if (accounts.count == 1) {
            pick(accounts.firstObject);
            return;
        }
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Choose a character"
            message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSDictionary *account in accounts) {
            NSString *name = [account[@"displayName"] isKindOfClass:NSString.class] ? account[@"displayName"] : @"New character";
            [sheet addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                pick(account);
            }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
            if (completion) completion(nil);
        }]];
        UIViewController *presenter = topPresenter(vc);
        sheet.popoverPresentationController.sourceView = presenter.view;
        sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(presenter.view.bounds), CGRectGetMidY(presenter.view.bounds), 0, 0);
        [presenter presentViewController:sheet animated:YES completion:nil];
    });
}

+ (void)presentMenuFrom:(UIViewController *)vc sourceView:(UIView *)sourceView {
    NSDictionary *session = [self current];
    if (!session) {
        [self presentLoginFrom:vc completion:nil];
        return;
    }
    NSString *title = [NSString stringWithFormat:@"Signed in as %@", session[@"displayName"] ?: @"a new character"];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Jagex Account"
        message:title preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Switch character" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        // An expired session shows an error; the player can then pick "Sign in again"
        [self chooseCharacterForSession:session[@"sessionId"] from:vc sourceView:sourceView completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Sign in again" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self presentLoginFrom:vc completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Sign out" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [self signOut];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *presenter = topPresenter(vc);
    sheet.popoverPresentationController.sourceView = presenter.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(presenter.view.bounds), CGRectGetMidY(presenter.view.bounds), 0, 0);
    [presenter presentViewController:sheet animated:YES completion:nil];
}

@end
