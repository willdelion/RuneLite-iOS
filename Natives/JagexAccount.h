#import <UIKit/UIKit.h>

// Jagex Account sign-in for RuneLite, following the Jagex Launcher's OAuth flow
// (same flow as the open-source Bolt launcher). The resulting game session is handed
// to RuneLite through the JX_* environment variables, like the Jagex Launcher does.
// Posted on the main queue after sign-in, character switch or sign-out
extern NSNotificationName const JagexAccountDidChangeNotification;

@interface JagexAccount : NSObject

// Saved session: @{sessionId, characterId, displayName}, or nil when signed out
+ (NSDictionary *)current;

+ (void)signOut;

// Sets or clears JX_SESSION_ID / JX_CHARACTER_ID / JX_DISPLAY_NAME for the JVM about to launch
+ (void)applyEnvironment;

// Shows the account menu (sign in / switch character / sign out)
+ (void)presentMenuFrom:(UIViewController *)vc sourceView:(UIView *)sourceView;

+ (void)presentLoginFrom:(UIViewController *)vc completion:(void (^)(NSDictionary *session))completion;

@end
