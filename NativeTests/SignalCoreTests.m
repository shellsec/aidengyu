#import <Foundation/Foundation.h>
#import "SignalCore.h"

static NSInteger failures = 0;
static NSInteger assertions = 0;

static void ASAssert(BOOL condition, NSString *message) {
    assertions++;
    if (!condition) {
        failures++;
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    }
}

static NSDictionary *ASPayload(NSString *event) {
    return @{
        @"session_id": @"session-1",
        @"hook_event_name": event,
        @"cwd": @"/tmp/example"
    };
}

static NSDictionary *ASMap(NSDictionary *payload) {
    NSError *error = nil;
    NSDictionary *signal = ASMapHookPayload(payload, ASAgentCodex, nil, NSDate.date, &error);
    ASAssert(signal != nil && error == nil, @"payload should map without error");
    return signal;
}

static NSInteger ASManagedCount(NSDictionary *root, NSString *event) {
    NSInteger count = 0;
    for (NSDictionary *group in root[@"hooks"][event] ?: @[]) {
        for (NSDictionary *handler in group[@"hooks"] ?: @[]) {
            NSString *command = handler[@"command"];
            if ([command containsString:@"AgentSignalHook"] && [command containsString:@"--agent"]) count++;
        }
    }
    return count;
}

static NSInteger ASManagedCursorCount(NSDictionary *root, NSString *event) {
    NSInteger count = 0;
    for (NSDictionary *entry in root[@"hooks"][event] ?: @[]) {
        NSString *command = entry[@"command"];
        if ([command containsString:@"AgentSignalHook"] && [command containsString:@"--agent cursor"]) count++;
    }
    return count;
}

int main(void) {
    @autoreleasepool {
        unsetenv("CLAUDE_CONFIG_DIR");

        ASAssert([ASMap(ASPayload(@"SessionStart"))[@"state"] isEqualToString:ASStateReady], @"SessionStart is ready");
        ASAssert([ASMap(ASPayload(@"UserPromptSubmit"))[@"state"] isEqualToString:ASStateThinking], @"prompt submit is thinking");
        ASAssert([ASMap(ASPayload(@"PreToolUse"))[@"state"] isEqualToString:ASStateWorking], @"tool use is working");

        NSMutableDictionary *question = [ASPayload(@"PreToolUse") mutableCopy];
        question[@"tool_name"] = @"AskUserQuestion";
        ASAssert([ASMap(question)[@"state"] isEqualToString:ASStateWaitingInput], @"question waits for input");

        ASAssert([ASMap(ASPayload(@"PermissionRequest"))[@"state"] isEqualToString:ASStateWaitingApproval], @"permission waits for approval");
        ASAssert([ASMap(ASPayload(@"PostToolUseFailure"))[@"state"] isEqualToString:ASStateFailed], @"tool failure is failed");
        ASAssert([ASMap(ASPayload(@"beforeSubmitPrompt"))[@"state"] isEqualToString:ASStateThinking], @"Cursor prompt is thinking");
        NSMutableDictionary *cursorError = [ASPayload(@"stop") mutableCopy];
        cursorError[@"status"] = @"error";
        ASAssert([ASMap(cursorError)[@"state"] isEqualToString:ASStateFailed], @"Cursor error stop is failed");
        ASAssert([ASMap(ASPayload(@"SubagentStop"))[@"state"] isEqualToString:ASStateCompleted], @"subagent stop completes its activity");
        ASAssert([ASMap(ASPayload(@"Stop"))[@"state"] isEqualToString:ASStateCompleted], @"normal stop is completed");

        NSMutableDictionary *limited = [ASPayload(@"Stop") mutableCopy];
        limited[@"stop_reason"] = @"rate_limit";
        ASAssert([ASMap(limited)[@"state"] isEqualToString:ASStateBlocked], @"rate limit is blocked");

        NSMutableDictionary *titledPrompt = [ASPayload(@"UserPromptSubmit") mutableCopy];
        titledPrompt[@"prompt"] = @"  ## 优化登录页面的状态管理和错误提示\n不要修改接口协议";
        NSDictionary *titledSignal = ASMap(titledPrompt);
        ASAssert([titledSignal[@"task_title"] isEqualToString:@"优化登录页面的状态管理和错误提示"], @"prompt first line becomes task title");
        NSDictionary *workingAfterTitle = ASMergeSignal(titledSignal, ASMap(ASPayload(@"PreToolUse")));
        ASAssert([workingAfterTitle[@"task_title"] isEqualToString:titledSignal[@"task_title"]], @"task title survives later events");

        NSDictionary *cursorSignal = ASMapHookPayload(@{
            @"conversation_id": @"cursor-conversation-1",
            @"hook_event_name": @"beforeSubmitPrompt",
            @"workspace_roots": @[@"/tmp/cursor-project"],
            @"prompt": @"支持 Cursor 状态灯"
        }, ASAgentCursor, nil, NSDate.date, nil);
        ASAssert([cursorSignal[@"session_id"] isEqualToString:@"cursor-conversation-1"], @"Cursor conversation id maps to session");
        ASAssert([cursorSignal[@"cwd"] isEqualToString:@"/tmp/cursor-project"], @"Cursor workspace root maps to cwd");
        ASAssert([cursorSignal[@"task_title"] isEqualToString:@"支持 Cursor 状态灯"], @"Cursor prompt becomes task title");

        NSDictionary *importedAsClaude = ASMapHookPayload(@{
            @"session_id": @"shared-session",
            @"hook_event_name": @"postToolUse",
            @"cwd": @"/tmp/minx"
        }, ASAgentClaude, nil, NSDate.date, nil);
        ASAssert([importedAsClaude[@"agent"] isEqualToString:ASAgentCursor],
            @"Cursor camelCase events stay Cursor even when Claude hooks were imported");
        ASAssert([ASResolveAgent(ASAgentClaude, @"sessionStart") isEqualToString:ASAgentCursor],
            @"sessionStart resolves to Cursor");
        ASAssert([ASResolveAgent(ASAgentClaude, @"SessionStart") isEqualToString:ASAgentClaude],
            @"SessionStart keeps Claude");
        ASAssert([ASResolveAgent(ASAgentCodex, @"Stop") isEqualToString:ASAgentCodex],
            @"Codex PascalCase Stop stays Codex");
        ASAssert([ASResolveAgent(ASAgentClaude, @"Stop") isEqualToString:ASAgentClaude],
            @"Claude Stop is not Cursor stop");
        ASAssert([ASResolveAgent(ASAgentClaude, @"stop") isEqualToString:ASAgentCursor],
            @"lowercase stop is Cursor dialect");
        for (NSString *event in ASClaudeHookEvents()) {
            ASAssert([ASResolveAgent(ASAgentClaude, event) isEqualToString:ASAgentClaude],
                @"Claude PascalCase events stay Claude");
        }
        for (NSString *event in ASCodexHookEvents()) {
            ASAssert([ASResolveAgent(ASAgentCodex, event) isEqualToString:ASAgentCodex],
                @"Codex PascalCase events stay Codex");
        }

        NSDictionary *failed = ASMap(ASPayload(@"PostToolUseFailure"));
        NSDictionary *completed = ASMap(ASPayload(@"Stop"));
        ASAssert([ASMergeSignal(failed, completed)[@"state"] isEqualToString:ASStateFailed], @"Stop does not hide a failure");
        NSDictionary *waitingApproval = ASMap(ASPayload(@"PermissionRequest"));
        ASAssert([ASMergeSignal(waitingApproval, completed)[@"state"] isEqualToString:ASStateCompleted], @"Stop clears resolved permission request");

        NSDate *permissionTime = [NSDate dateWithTimeIntervalSinceNow:-31];
        NSDictionary *agedPermission = ASMapHookPayload(
            ASPayload(@"PermissionRequest"), ASAgentClaude, nil, permissionTime, nil);
        ASAssert([ASDisplayState(agedPermission, NSDate.date) isEqualToString:ASStateAttention],
            @"unresolved permission flash settles to attention");

        NSMutableDictionary *permissionNotificationPayload = [ASPayload(@"Notification") mutableCopy];
        permissionNotificationPayload[@"notification_type"] = @"permission_prompt";
        NSDictionary *permissionNotification = ASMapHookPayload(
            permissionNotificationPayload, ASAgentClaude, nil, NSDate.date, nil);
        NSDictionary *deduplicatedPermission = ASMergeSignal(agedPermission, permissionNotification);
        ASAssert([deduplicatedPermission[@"updated_at"] isEqualToString:agedPermission[@"updated_at"]],
            @"duplicate permission notification keeps original timestamp");
        ASAssert([ASDisplayState(deduplicatedPermission, NSDate.date) isEqualToString:ASStateAttention],
            @"duplicate permission notification does not restart flashing");

        NSDate *oldDate = [NSDate dateWithTimeIntervalSinceNow:-16];
        NSError *mapError = nil;
        NSDictionary *oldCompleted = ASMapHookPayload(ASPayload(@"Stop"), ASAgentCodex, nil, oldDate, &mapError);
        ASAssert([ASDisplayState(oldCompleted, NSDate.date) isEqualToString:ASStateReady], @"completed settles to ready");

        ASAssert(ASStatePriority(ASStateStale) < ASStatePriority(ASStateReady), @"stale sorts below ready");
        ASAssert(ASStatePriority(ASStateStale) < ASStatePriority(ASStateWorking), @"stale sorts below working");
        ASAssert(ASStatePriority(ASStateStale) < ASStatePriority(ASStateOffline), @"stale sorts below offline");
        ASAssert(ASStatePriority(ASStateAttention) > ASStatePriority(ASStateWorking), @"attention stays above working");
        ASAssert(ASStatePriority(ASStateWorking) > ASStatePriority(ASStateReady), @"working stays above ready");

        NSURL *temporary = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
        NSURL *stateRoot = [temporary URLByAppendingPathComponent:@"state" isDirectory:YES];
        NSDictionary *codexSignal = ASMap(ASPayload(@"SessionStart"));
        NSMutableDictionary *claudePayload = [ASPayload(@"SessionStart") mutableCopy];
        claudePayload[@"session_id"] = @"session-2";
        NSDictionary *claudeSignal = ASMapHookPayload(claudePayload, ASAgentClaude, nil, NSDate.date, nil);
        ASAssert(ASWriteSignal(codexSignal, stateRoot, nil), @"writes Codex signal");
        ASAssert(ASWriteSignal(claudeSignal, stateRoot, nil), @"writes Claude signal");
        ASAssert(ASWriteSignal(cursorSignal, stateRoot, nil), @"writes Cursor signal");
        ASAssert(ASLoadSignals(stateRoot).count == 3, @"sessions use separate files");

        NSMutableDictionary *sameTarget = [cursorSignal mutableCopy];
        sameTarget[@"state"] = ASStateWorking;
        sameTarget[@"event_name"] = @"postToolUse";
        sameTarget[@"updated_at"] = @"2099-01-01T00:00:00.000Z";
        ASAssert(ASWriteSignal(sameTarget, stateRoot, nil), @"updates same Cursor session");
        ASAssert(ASLoadSignals(stateRoot).count == 3, @"same session update must not add a row");

        NSMutableArray *many = [NSMutableArray array];
        for (NSInteger i = 0; i < 8; i++) {
            [many addObject:@{
                @"agent": ASAgentCursor,
                @"session_id": [NSString stringWithFormat:@"s%ld", (long)i],
                @"state": ASStateReady,
                @"event_name": @"sessionStart",
                @"updated_at": [NSString stringWithFormat:@"2026-09-24T%02ld:00:00.000Z", (long)i],
                @"cwd": @"/tmp/project"
            }];
        }
        NSArray *limited = ASLimitVisibleSignals(many, 5);
        ASAssert(limited.count == 5, @"limit keeps only newest N sessions");
        ASAssert([limited[0][@"session_id"] isEqualToString:@"s7"], @"newest session stays first after limit");
        ASAssert(ASNormalizeMaxVisibleSessions(0) == ASDefaultMaxVisibleSessions(), @"zero uses default");
        ASAssert(ASNormalizeMaxVisibleSessions(9) == 9, @"positive limit passes through");
        NSArray *limitedTen = ASLimitVisibleSignals(many, 10);
        ASAssert(limitedTen.count == 8, @"limit above count keeps all");

        NSArray *attentionMix = @[
            @{ @"agent": ASAgentCursor, @"session_id": @"old-failed", @"state": ASStateFailed,
               @"event_name": @"stop", @"updated_at": @"2026-09-24T01:00:00.000Z", @"cwd": @"/tmp/a" },
            @{ @"agent": ASAgentCodex, @"session_id": @"old-wait", @"state": ASStateWaitingApproval,
               @"event_name": @"PermissionRequest", @"updated_at": @"2026-09-24T01:30:00.000Z", @"cwd": @"/tmp/b" },
            @{ @"agent": ASAgentClaude, @"session_id": @"fresh-ready", @"state": ASStateReady,
               @"event_name": @"sessionStart", @"updated_at": @"2026-09-24T09:00:00.000Z", @"cwd": @"/tmp/c" },
            @{ @"agent": ASAgentCursor, @"session_id": @"fresh-work", @"state": ASStateWorking,
               @"event_name": @"postToolUse", @"updated_at": @"2026-09-24T09:30:00.000Z", @"cwd": @"/tmp/d" },
            @{ @"agent": ASAgentCodex, @"session_id": @"fresh-think", @"state": ASStateThinking,
               @"event_name": @"UserPromptSubmit", @"updated_at": @"2026-09-24T10:00:00.000Z", @"cwd": @"/tmp/e" }
        ];
        NSArray *keptAttention = ASLimitVisibleSignals(attentionMix, 3);
        ASAssert(keptAttention.count == 3, @"attention mix keeps N rows");
        NSMutableSet *keptIDs = [NSMutableSet set];
        for (NSDictionary *row in keptAttention) [keptIDs addObject:row[@"session_id"]];
        ASAssert([keptIDs containsObject:@"old-failed"], @"old failed survives newer ready/working");
        ASAssert([keptIDs containsObject:@"old-wait"], @"old waiting_approval survives newer ready/working");
        ASAssert([keptIDs containsObject:@"fresh-think"], @"remaining seat is newest non-attention");
        ASAssert(![keptIDs containsObject:@"fresh-ready"], @"newer ready yields to attention");
        ASAssert(![keptIDs containsObject:@"fresh-work"], @"newer working yields to attention");
        ASAssert(ASNeedsUserAttention(ASStateFailed), @"failed needs attention");
        ASAssert(!ASNeedsUserAttention(ASStateReady), @"ready does not need attention");

        ASAssert(ASRecordHookWriteError(stateRoot, @"disk full", nil), @"records hook write error");
        ASAssert([ASLoadHookWriteError(stateRoot) isEqualToString:@"disk full"], @"loads hook write error");
        NSDictionary *clearingSignal = @{
            @"schema_version": @1,
            @"agent": ASAgentCursor,
            @"session_id": @"clear-err",
            @"state": ASStateReady,
            @"event_name": @"sessionStart",
            @"updated_at": @"2026-09-24T12:00:00.000Z",
            @"cwd": @"/tmp/clear"
        };
        ASAssert(ASWriteSignal(clearingSignal, stateRoot, nil), @"successful write clears hook error");
        ASAssert(ASLoadHookWriteError(stateRoot) == nil, @"hook write error cleared after success");

        for (NSNumber *preset in @[@5, @10, @20]) {
            NSInteger limit = preset.integerValue;
            NSMutableArray *overflow = [NSMutableArray array];
            for (NSInteger i = 0; i < limit + 4; i++) {
                [overflow addObject:@{
                    @"agent": ASAgentCursor,
                    @"session_id": [NSString stringWithFormat:@"p%ld", (long)i],
                    @"state": ASStateReady,
                    @"event_name": @"sessionStart",
                    @"updated_at": [NSString stringWithFormat:@"2026-09-24T%02ld:00:00.000Z", (long)i],
                    @"cwd": @"/tmp/project"
                }];
            }
            NSArray *capped = ASLimitVisibleSignals(overflow, limit);
            ASAssert(capped.count == (NSUInteger)limit, @"menu preset truncates to selected limit");
        }
        NSString *defaultsKey = @"maxVisibleSessions";
        NSInteger previous = [NSUserDefaults.standardUserDefaults integerForKey:defaultsKey];
        [NSUserDefaults.standardUserDefaults setInteger:20 forKey:defaultsKey];
        ASAssert([NSUserDefaults.standardUserDefaults integerForKey:defaultsKey] == 20, @"selected limit persists in defaults");
        [NSUserDefaults.standardUserDefaults setInteger:previous forKey:defaultsKey];

        NSURL *codexURL = ASCodexHooksURL(temporary);
        [[NSFileManager defaultManager] createDirectoryAtURL:codexURL.URLByDeletingLastPathComponent
            withIntermediateDirectories:YES attributes:nil error:nil];
        NSDictionary *originalCodex = @{
            @"description": @"keep me",
            @"hooks": @{ @"SessionStart": @[@{ @"hooks": @[@{
                @"type": @"command", @"command": @"echo existing"
            }]}] }
        };
        NSData *originalData = [NSJSONSerialization dataWithJSONObject:originalCodex options:0 error:nil];
        [originalData writeToURL:codexURL atomically:YES];

        NSURL *cursorURL = ASCursorHooksURL(temporary);
        [[NSFileManager defaultManager] createDirectoryAtURL:cursorURL.URLByDeletingLastPathComponent
            withIntermediateDirectories:YES attributes:nil error:nil];
        NSDictionary *originalCursor = @{
            @"version": @1,
            @"description": @"keep cursor config",
            @"hooks": @{ @"sessionStart": @[@{ @"command": @"echo existing-cursor" }] }
        };
        NSData *originalCursorData = [NSJSONSerialization dataWithJSONObject:originalCursor options:0 error:nil];
        [originalCursorData writeToURL:cursorURL atomically:YES];

        NSString *hookPath = @"/Applications/aidengyu.app/Contents/Helpers/AgentSignalHook";
        NSError *installError = nil;
        ASAssert(ASInstallHooks(hookPath, temporary, &installError), @"installs hook configuration");
        ASAssert(ASInstallHooks(hookPath, temporary, &installError), @"reinstall is idempotent");
        NSDictionary *status = ASHookStatus(hookPath, temporary);
        ASAssert([status[@"all_installed"] boolValue], @"all integrations report installed");
        ASAssert([status[@"cursor_installed"] boolValue], @"Cursor integration reports installed");

        NSDictionary *installedCodex = [NSJSONSerialization JSONObjectWithData:
            [NSData dataWithContentsOfURL:codexURL] options:0 error:nil];
        ASAssert([installedCodex[@"description"] isEqualToString:@"keep me"], @"existing top-level config survives");
        ASAssert([installedCodex[@"hooks"][@"SessionStart"] count] == 2, @"existing hook survives exactly once");
        ASAssert(ASManagedCount(installedCodex, @"SessionStart") == 1, @"managed hook is not duplicated");

        NSDictionary *installedCursor = [NSJSONSerialization JSONObjectWithData:
            [NSData dataWithContentsOfURL:cursorURL] options:0 error:nil];
        ASAssert([installedCursor[@"description"] isEqualToString:@"keep cursor config"], @"existing Cursor config survives");
        ASAssert([installedCursor[@"hooks"][@"sessionStart"] count] == 2, @"existing Cursor hook survives exactly once");
        ASAssert(ASManagedCursorCount(installedCursor, @"sessionStart") == 1, @"managed Cursor hook is not duplicated");
        ASAssert([installedCursor[@"hooks"][@"preToolUse"] count] == 1, @"Cursor event uses direct hook entries");

        ASAssert(ASUninstallHooks(temporary, nil), @"uninstalls managed hooks");
        NSDictionary *uninstalledCodex = [NSJSONSerialization JSONObjectWithData:
            [NSData dataWithContentsOfURL:codexURL] options:0 error:nil];
        ASAssert([uninstalledCodex[@"hooks"][@"SessionStart"] count] == 1, @"uninstall preserves existing hook");
        ASAssert(ASManagedCount(uninstalledCodex, @"SessionStart") == 0, @"managed hook is removed");
        NSDictionary *uninstalledCursor = [NSJSONSerialization JSONObjectWithData:
            [NSData dataWithContentsOfURL:cursorURL] options:0 error:nil];
        ASAssert([uninstalledCursor[@"hooks"][@"sessionStart"] count] == 1, @"uninstall preserves existing Cursor hook");
        ASAssert(ASManagedCursorCount(uninstalledCursor, @"sessionStart") == 0, @"managed Cursor hook is removed");

        [[NSFileManager defaultManager] removeItemAtURL:temporary error:nil];
        fprintf(stdout, "%ld assertions, %ld failures\n", (long)assertions, (long)failures);
        return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
    }
}
