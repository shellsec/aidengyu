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

        NSString *hookPath = @"/Applications/CodexClaudeSignal.app/Contents/Helpers/AgentSignalHook";
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
