#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const ASAgentCodex;
FOUNDATION_EXPORT NSString * const ASAgentClaude;
FOUNDATION_EXPORT NSString * const ASAgentCursor;

FOUNDATION_EXPORT NSString * const ASStateReady;
FOUNDATION_EXPORT NSString * const ASStateThinking;
FOUNDATION_EXPORT NSString * const ASStateWorking;
FOUNDATION_EXPORT NSString * const ASStateWaitingInput;
FOUNDATION_EXPORT NSString * const ASStateWaitingApproval;
FOUNDATION_EXPORT NSString * const ASStateAttention;
FOUNDATION_EXPORT NSString * const ASStateCompleted;
FOUNDATION_EXPORT NSString * const ASStateFailed;
FOUNDATION_EXPORT NSString * const ASStateBlocked;
FOUNDATION_EXPORT NSString * const ASStateStale;
FOUNDATION_EXPORT NSString * const ASStateOffline;

FOUNDATION_EXPORT NSArray<NSString *> *ASCodexHookEvents(void);
FOUNDATION_EXPORT NSArray<NSString *> *ASClaudeHookEvents(void);
FOUNDATION_EXPORT NSArray<NSString *> *ASCursorHookEvents(void);

FOUNDATION_EXPORT NSString *ASAgentDisplayName(NSString *agent);
FOUNDATION_EXPORT NSString *ASStateTitle(NSString *state);
FOUNDATION_EXPORT NSInteger ASStatePriority(NSString *state);
FOUNDATION_EXPORT NSDate * _Nullable ASSignalUpdatedAt(NSDictionary *signal);
FOUNDATION_EXPORT NSString *ASDisplayState(NSDictionary *signal, NSDate *now);
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *ASLampPresentation(NSString *state);

FOUNDATION_EXPORT NSDictionary * _Nullable ASMapHookPayload(
    NSDictionary *payload,
    NSString *agent,
    NSString * _Nullable fallbackEvent,
    NSDate *now,
    NSError **error
);

FOUNDATION_EXPORT NSDictionary *ASMergeSignal(
    NSDictionary * _Nullable existing,
    NSDictionary *incoming
);

FOUNDATION_EXPORT NSURL *ASSignalRootURL(void);
FOUNDATION_EXPORT NSArray<NSDictionary *> *ASLoadSignals(NSURL *rootURL);
FOUNDATION_EXPORT BOOL ASWriteSignal(NSDictionary *signal, NSURL *rootURL, NSError **error);
FOUNDATION_EXPORT BOOL ASClearSignals(NSURL *rootURL, NSError **error);

FOUNDATION_EXPORT NSURL *ASCodexHooksURL(NSURL *homeURL);
FOUNDATION_EXPORT NSURL *ASClaudeSettingsURL(NSURL *homeURL);
FOUNDATION_EXPORT NSURL *ASCursorHooksURL(NSURL *homeURL);
FOUNDATION_EXPORT NSDictionary<NSString *, NSNumber *> *ASHookStatus(
    NSString *hookPath,
    NSURL *homeURL
);
FOUNDATION_EXPORT BOOL ASInstallHooks(NSString *hookPath, NSURL *homeURL, NSError **error);
FOUNDATION_EXPORT BOOL ASUninstallHooks(NSURL *homeURL, NSError **error);

NS_ASSUME_NONNULL_END
