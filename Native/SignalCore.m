#import "SignalCore.h"

NSString * const ASAgentCodex = @"codex";
NSString * const ASAgentClaude = @"claude";
NSString * const ASAgentCursor = @"cursor";

NSString * const ASStateReady = @"ready";
NSString * const ASStateThinking = @"thinking";
NSString * const ASStateWorking = @"working";
NSString * const ASStateWaitingInput = @"waiting_input";
NSString * const ASStateWaitingApproval = @"waiting_approval";
NSString * const ASStateAttention = @"attention";
NSString * const ASStateCompleted = @"completed";
NSString * const ASStateFailed = @"failed";
NSString * const ASStateBlocked = @"blocked";
NSString * const ASStateStale = @"stale";
NSString * const ASStateOffline = @"offline";

static NSString * const ASErrorDomain = @"aidengyu";
static NSString * const ASManagedHookToken = @"AgentSignalHook";
static NSString * const ASLegacyManagedHookToken = @"CodexClaudeSignal";

NSArray<NSString *> *ASCodexHookEvents(void) {
    return @[
        @"SessionStart", @"UserPromptSubmit", @"PreToolUse", @"PostToolUse",
        @"PermissionRequest", @"SubagentStart", @"SubagentStop", @"Stop", @"SessionEnd"
    ];
}

NSArray<NSString *> *ASClaudeHookEvents(void) {
    return @[
        @"SessionStart", @"UserPromptSubmit", @"PreToolUse", @"PostToolUse",
        @"PostToolUseFailure", @"PermissionRequest", @"Notification",
        @"SubagentStart", @"SubagentStop", @"Stop", @"SessionEnd"
    ];
}

NSArray<NSString *> *ASCursorHookEvents(void) {
    return @[
        @"sessionStart", @"beforeSubmitPrompt", @"preToolUse", @"postToolUse",
        @"postToolUseFailure", @"subagentStart", @"subagentStop", @"preCompact",
        @"stop", @"sessionEnd"
    ];
}

NSString *ASAgentDisplayName(NSString *agent) {
    if ([agent isEqualToString:ASAgentClaude]) return @"Claude Code";
    if ([agent isEqualToString:ASAgentCursor]) return @"Cursor";
    return @"Codex";
}

// Attribution by event-name dialect (exact match, case-sensitive):
// - Cursor alone imports ~/.claude/settings.json and re-invokes those commands with
//   camelCase payloads while keeping --agent claude. Prefer dialect over --agent.
// - Claude Code and Codex only read their own configs; they do not execute
//   ~/.cursor/hooks.json. Their PascalCase events must stay put.
NSString *ASResolveAgent(NSString *agent, NSString *eventName) {
    if (eventName.length && [ASCursorHookEvents() containsObject:eventName]) return ASAgentCursor;
    if ([agent isEqualToString:ASAgentClaude] ||
        [agent isEqualToString:ASAgentCursor] ||
        [agent isEqualToString:ASAgentCodex]) return agent;
    return ASAgentCodex;
}

NSString *ASStateTitle(NSString *state) {
    NSDictionary *titles = @{
        ASStateReady: @"就绪",
        ASStateThinking: @"思考中",
        ASStateWorking: @"执行中",
        ASStateWaitingInput: @"等待回答",
        ASStateWaitingApproval: @"等待授权",
        ASStateAttention: @"需要留意",
        ASStateCompleted: @"已完成",
        ASStateFailed: @"执行失败",
        ASStateBlocked: @"已阻塞",
        ASStateStale: @"状态过期",
        ASStateOffline: @"已退出"
    };
    return titles[state] ?: @"未知";
}

NSInteger ASStatePriority(NSString *state) {
    if ([state isEqualToString:ASStateBlocked]) return 100;
    if ([state isEqualToString:ASStateFailed]) return 90;
    if ([state isEqualToString:ASStateWaitingApproval]) return 80;
    if ([state isEqualToString:ASStateWaitingInput]) return 70;
    if ([state isEqualToString:ASStateAttention]) return 60;
    if ([state isEqualToString:ASStateWorking]) return 50;
    if ([state isEqualToString:ASStateThinking]) return 40;
    if ([state isEqualToString:ASStateCompleted]) return 30;
    if ([state isEqualToString:ASStateReady]) return 20;
    if ([state isEqualToString:ASStateOffline]) return 10;
    if ([state isEqualToString:ASStateStale]) return 0;
    return 0;
}

static NSISO8601DateFormatter *ASDateFormatter(void) {
    static NSISO8601DateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSISO8601DateFormatter alloc] init];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    });
    return formatter;
}

static NSDate *ASDateFromString(NSString *value) {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSDate *date = [ASDateFormatter() dateFromString:value];
    if (date) return date;

    NSISO8601DateFormatter *fallback = [[NSISO8601DateFormatter alloc] init];
    fallback.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    return [fallback dateFromString:value];
}

NSDate *ASSignalUpdatedAt(NSDictionary *signal) {
    return ASDateFromString(signal[@"updated_at"]);
}

static NSString *ASNormalize(NSString *value);
static BOOL ASPostToolIdleEvent(NSString *eventName);

NSString *ASDisplayState(NSDictionary *signal, NSDate *now) {
    NSString *state = signal[@"state"] ?: ASStateStale;
    NSDate *updatedAt = ASDateFromString(signal[@"updated_at"]);
    if (!updatedAt) return ASStateStale;

    NSTimeInterval age = [now timeIntervalSinceDate:updatedAt];
    if ([state isEqualToString:ASStateCompleted] && age > 15) return ASStateReady;
    if ([state isEqualToString:ASStateWaitingApproval] && age > 30) return ASStateAttention;
    if ([state isEqualToString:ASStateWorking] && age > 45 && ASPostToolIdleEvent(signal[@"event_name"])) {
        return ASStateReady;
    }

    NSSet *terminalStates = [NSSet setWithArray:@[
        ASStateOffline, ASStateCompleted, ASStateFailed, ASStateBlocked
    ]];
    if (![terminalStates containsObject:state] && age > 600) return ASStateStale;
    return state;
}

static BOOL ASPostToolIdleEvent(NSString *eventName) {
    NSString *event = ASNormalize(eventName ?: @"");
    return [event isEqualToString:@"posttooluse"] ||
        [event isEqualToString:@"posttoolbatch"] ||
        [event isEqualToString:@"taskcompleted"];
}

BOOL ASIsPhantomReadySession(NSDictionary *signal) {
    if (![signal[@"state"] isEqualToString:ASStateReady]) return NO;
    if ([signal[@"cwd"] length] > 0 || [signal[@"task_title"] length] > 0) return NO;
    NSString *event = ASNormalize(signal[@"event_name"] ?: @"");
    return [event isEqualToString:@"sessionstart"] || event.length == 0;
}

BOOL ASShouldShowSignal(NSDictionary *signal, NSDate *now) {
    if (ASIsPhantomReadySession(signal)) return NO;
    if (![signal[@"state"] isEqualToString:ASStateOffline]) return YES;
    NSDate *updatedAt = ASDateFromString(signal[@"updated_at"]);
    if (!updatedAt) return NO;
    return [now timeIntervalSinceDate:updatedAt] <= 3;
}

NSDictionary<NSString *, NSString *> *ASLampPresentation(NSString *state) {
    if ([state isEqualToString:ASStateReady]) return @{ @"color": @"green", @"effect": @"steady" };
    if ([state isEqualToString:ASStateThinking]) return @{ @"color": @"green", @"effect": @"breathe" };
    if ([state isEqualToString:ASStateWorking]) return @{ @"color": @"green", @"effect": @"slow_blink" };
    if ([state isEqualToString:ASStateWaitingInput]) return @{ @"color": @"yellow", @"effect": @"slow_blink" };
    if ([state isEqualToString:ASStateWaitingApproval]) return @{ @"color": @"yellow", @"effect": @"fast_blink" };
    if ([state isEqualToString:ASStateAttention] || [state isEqualToString:ASStateStale]) {
        return @{ @"color": @"yellow", @"effect": @"steady" };
    }
    if ([state isEqualToString:ASStateCompleted]) return @{ @"color": @"green", @"effect": @"double_flash" };
    if ([state isEqualToString:ASStateFailed]) return @{ @"color": @"red", @"effect": @"steady" };
    if ([state isEqualToString:ASStateBlocked]) return @{ @"color": @"red", @"effect": @"fast_blink" };
    return @{ @"color": @"off", @"effect": @"off" };
}

static NSString *ASFirstString(NSDictionary *payload, NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        id value = payload[key];
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) return value;
    }
    return nil;
}

static NSString *ASNormalize(NSString *value) {
    if (![value isKindOfClass:[NSString class]]) return @"";
    NSCharacterSet *allowed = [NSCharacterSet alphanumericCharacterSet];
    NSMutableString *result = [NSMutableString string];
    NSString *lowercase = value.lowercaseString;
    for (NSUInteger index = 0; index < lowercase.length; index++) {
        unichar character = [lowercase characterAtIndex:index];
        if ([allowed characterIsMember:character]) [result appendFormat:@"%C", character];
    }
    return result;
}

static NSString *ASTaskTitleFromPayload(NSDictionary *payload) {
    NSString *prompt = ASFirstString(payload, @[@"prompt", @"user_prompt", @"userPrompt"]);
    if (!prompt.length) return nil;

    NSArray<NSString *> *lines = [prompt componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSString *firstLine = nil;
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (trimmed.length) {
            firstLine = trimmed;
            break;
        }
    }
    if (!firstLine.length) return nil;

    NSRegularExpression *whitespace = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil];
    NSString *clean = [whitespace stringByReplacingMatchesInString:firstLine
        options:0 range:NSMakeRange(0, firstLine.length) withTemplate:@" "];
    clean = [clean stringByTrimmingCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@" #>*-`\t"]];
    if (!clean.length) return nil;

    __block NSUInteger count = 0;
    __block NSRange titleRange = NSMakeRange(0, 0);
    [clean enumerateSubstringsInRange:NSMakeRange(0, clean.length)
        options:NSStringEnumerationByComposedCharacterSequences
        usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
            if (count >= 36) {
                *stop = YES;
                return;
            }
            titleRange.length = NSMaxRange(substringRange);
            count++;
        }];

    NSString *title = [clean substringWithRange:titleRange];
    return titleRange.length < clean.length ? [title stringByAppendingString:@"..."] : title;
}

static BOOL ASValueMeansFailure(id value) {
    if (!value || value == [NSNull null]) return NO;
    if ([value isKindOfClass:[NSString class]]) return [value length] > 0;
    if ([value isKindOfClass:[NSNumber class]]) return [value boolValue];
    return YES;
}

static BOOL ASHasStructuredFailure(NSDictionary *payload) {
    for (NSString *key in @[@"error", @"failure", @"exception"]) {
        if (ASValueMeansFailure(payload[key])) return YES;
    }

    for (NSString *key in @[@"exit_status", @"exitStatus", @"exit_code", @"exitCode"]) {
        id value = payload[key];
        if ([value respondsToSelector:@selector(integerValue)] && [value integerValue] != 0) return YES;
    }

    for (NSString *key in @[@"is_error", @"isError"]) {
        if ([payload[key] respondsToSelector:@selector(boolValue)] && [payload[key] boolValue]) return YES;
    }

    id nested = payload[@"tool_response"] ?: payload[@"toolResponse"];
    if ([nested isKindOfClass:[NSDictionary class]]) return ASHasStructuredFailure(nested);
    return NO;
}

static BOOL ASIsHardBlock(NSDictionary *payload, NSString *event) {
    NSString *reason = ASFirstString(payload, @[
        @"error", @"failure", @"reason", @"stop_reason", @"stopReason"
    ]) ?: @"";
    NSString *combined = [NSString stringWithFormat:@"%@%@", ASNormalize(event), ASNormalize(reason)];
    for (NSString *term in @[
        @"ratelimit", @"usagelimit", @"maxbudget", @"maxtokens", @"authentication",
        @"unauthorized", @"forbidden", @"permissiondenied", @"blocked"
    ]) {
        if ([combined containsString:term]) return YES;
    }
    return NO;
}

static NSString *ASStateForEvent(NSString *eventName, NSDictionary *payload) {
    NSString *event = ASNormalize(eventName);
    NSString *tool = ASNormalize(ASFirstString(payload, @[@"tool_name", @"toolName"]) ?: @"");
    NSString *notification = ASNormalize(ASFirstString(payload, @[
        @"notification_type", @"notificationType", @"type"
    ]) ?: @"");
    NSString *status = ASNormalize(ASFirstString(payload, @[@"status"]) ?: @"");

    if ([status isEqualToString:@"error"] || ASHasStructuredFailure(payload) ||
        [event containsString:@"failure"] || [event containsString:@"error"]) {
        return ASIsHardBlock(payload, event) ? ASStateBlocked : ASStateFailed;
    }
    if ([event containsString:@"permissiondenied"]) return ASStateBlocked;
    if ([event isEqualToString:@"permissionrequest"]) return ASStateWaitingApproval;

    if ([event isEqualToString:@"notification"]) {
        if ([notification containsString:@"permission"]) return ASStateWaitingApproval;
        if ([notification containsString:@"idleprompt"] || [notification containsString:@"question"]) {
            return ASStateWaitingInput;
        }
        return ASStateAttention;
    }

    if ([event isEqualToString:@"pretooluse"]) {
        if ([tool containsString:@"askuserquestion"] ||
            [tool containsString:@"requestuserinput"] ||
            [tool containsString:@"elicitation"]) {
            return ASStateWaitingInput;
        }
        return ASStateWorking;
    }

    if ([event isEqualToString:@"sessionstart"]) return ASStateReady;
    if ([event isEqualToString:@"userpromptsubmit"] ||
        [event isEqualToString:@"userpromptexpansion"] ||
        [event isEqualToString:@"beforesubmitprompt"]) {
        return ASStateThinking;
    }
    if ([event isEqualToString:@"subagentstop"]) return ASStateCompleted;

    NSSet *workingEvents = [NSSet setWithArray:@[
        @"posttooluse", @"posttoolbatch", @"precompact", @"postcompact",
        @"subagentstart", @"taskcreated", @"taskcompleted",
        @"worktreecreate", @"elicitationresult"
    ]];
    if ([workingEvents containsObject:event]) return ASStateWorking;

    if ([event isEqualToString:@"askuserquestion"] ||
        [event isEqualToString:@"requestuserinput"] ||
        [event isEqualToString:@"elicitation"]) return ASStateWaitingInput;

    NSSet *attentionEvents = [NSSet setWithArray:@[
        @"configchange", @"cwdchanged", @"filechanged", @"instructionsloaded", @"worktreeremove"
    ]];
    if ([attentionEvents containsObject:event]) return ASStateAttention;

    if ([event isEqualToString:@"stop"]) {
        return ASIsHardBlock(payload, event) ? ASStateBlocked : ASStateCompleted;
    }
    if ([event isEqualToString:@"sessionend"]) return ASStateOffline;
    return ASStateThinking;
}

NSDictionary *ASMapHookPayload(
    NSDictionary *payload,
    NSString *agent,
    NSString *fallbackEvent,
    NSDate *now,
    NSError **error
) {
    NSString *sessionID = ASFirstString(payload, @[
        @"session_id", @"sessionId", @"conversation_id", @"conversationId"
    ]);
    if (!sessionID.length) {
        if (error) {
            *error = [NSError errorWithDomain:ASErrorDomain code:1 userInfo:@{
                NSLocalizedDescriptionKey: @"Hook input has no session id."
            }];
        }
        return nil;
    }

    NSString *eventName = ASFirstString(payload, @[
        @"hook_event_name", @"hookEventName", @"event", @"event_name", @"eventName"
    ]) ?: fallbackEvent ?: @"Unknown";
    NSString *cwd = ASFirstString(payload, @[@"cwd", @"working_directory", @"workingDirectory"]);
    if (!cwd.length && [payload[@"workspace_roots"] isKindOfClass:[NSArray class]]) {
        for (id root in payload[@"workspace_roots"]) {
            if ([root isKindOfClass:[NSString class]] && [root length]) {
                cwd = root;
                break;
            }
        }
    }
    NSString *detail = ASFirstString(payload, @[
        @"message", @"error", @"reason", @"stop_reason", @"stopReason",
        @"notification_type", @"notificationType"
    ]);

    NSMutableDictionary *signal = [@{
        @"schema_version": @1,
        @"agent": ASResolveAgent(agent, eventName),
        @"session_id": sessionID,
        @"state": ASStateForEvent(eventName, payload),
        @"event_name": eventName,
        @"updated_at": [ASDateFormatter() stringFromDate:now]
    } mutableCopy];
    if (cwd.length) signal[@"cwd"] = cwd;
    if (detail.length) signal[@"detail"] = detail;
    NSString *taskTitle = ASTaskTitleFromPayload(payload);
    if (taskTitle.length) signal[@"task_title"] = taskTitle;
    return signal;
}

NSDictionary *ASMergeSignal(NSDictionary *existing, NSDictionary *incoming) {
    if (!existing) return incoming;
    NSString *oldState = existing[@"state"];
    NSString *newState = incoming[@"state"];
    NSString *event = ASNormalize(incoming[@"event_name"] ?: @"");

    BOOL oldNeedsProtection = [@[
        ASStateAttention, ASStateFailed, ASStateBlocked
    ] containsObject:oldState];
    BOOL resolvingEvent = [@[
        @"sessionstart", @"userpromptsubmit", @"posttooluse"
    ] containsObject:event];
    BOOL lowPriorityEvent = [event isEqualToString:@"stop"] || [event hasPrefix:@"subagent"];

    // Claude emits a PermissionRequest and then a duplicate permission Notification,
    // but does not emit an outcome hook when the user rejects the request. Keep the
    // original timestamp so the urgent flash can age into a steady attention state.
    if ([oldState isEqualToString:ASStateWaitingApproval] &&
        [newState isEqualToString:ASStateWaitingApproval] &&
        [event isEqualToString:@"notification"]) {
        NSMutableDictionary *deduplicated = [incoming mutableCopy];
        if ([existing[@"updated_at"] length]) deduplicated[@"updated_at"] = existing[@"updated_at"];
        if (![deduplicated[@"task_title"] length] && [existing[@"task_title"] length]) {
            deduplicated[@"task_title"] = existing[@"task_title"];
        }
        if (![deduplicated[@"cwd"] length] && [existing[@"cwd"] length]) {
            deduplicated[@"cwd"] = existing[@"cwd"];
        }
        return deduplicated;
    }

    if ([oldState isEqualToString:ASStateCompleted] &&
        [newState isEqualToString:ASStateWorking] &&
        ASPostToolIdleEvent(incoming[@"event_name"])) {
        NSMutableDictionary *kept = [existing mutableCopy];
        if ([incoming[@"task_title"] length]) kept[@"task_title"] = incoming[@"task_title"];
        if ([incoming[@"cwd"] length]) kept[@"cwd"] = incoming[@"cwd"];
        return kept;
    }

    if (oldNeedsProtection && !resolvingEvent && lowPriorityEvent &&
        ASStatePriority(oldState) > ASStatePriority(newState)) {
        return existing;
    }

    NSMutableDictionary *merged = [incoming mutableCopy];
    if (![merged[@"task_title"] length] && [existing[@"task_title"] length]) {
        merged[@"task_title"] = existing[@"task_title"];
    }
    if (![merged[@"cwd"] length] && [existing[@"cwd"] length]) {
        merged[@"cwd"] = existing[@"cwd"];
    }
    return merged;
}

NSURL *ASSignalRootURL(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"AIDENGYU_HOME"];
    if (!override.length) {
        override = NSProcessInfo.processInfo.environment[@"CODEX_CLAUDE_SIGNAL_HOME"];
    }
    if (override.length) return [NSURL fileURLWithPath:override isDirectory:YES];

    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *support = [fm.homeDirectoryForCurrentUser
        URLByAppendingPathComponent:@"Library/Application Support" isDirectory:YES];
    NSURL *preferred = [support URLByAppendingPathComponent:@"aidengyu" isDirectory:YES];
    BOOL preferredIsDir = NO;
    if ([fm fileExistsAtPath:preferred.path isDirectory:&preferredIsDir] && preferredIsDir) {
        return preferred;
    }

    NSArray<NSString *> *legacyNames = @[@"CodexClaudeSignal", @"CodexClaudeSignalWindows"];
    for (NSString *name in legacyNames) {
        NSURL *legacy = [support URLByAppendingPathComponent:name isDirectory:YES];
        BOOL legacyIsDir = NO;
        if (![fm fileExistsAtPath:legacy.path isDirectory:&legacyIsDir] || !legacyIsDir) continue;
        NSError *renameError = nil;
        if ([fm moveItemAtURL:legacy toURL:preferred error:&renameError]) {
            return preferred;
        }
        return legacy;
    }
    return preferred;
}

static NSURL *ASSessionsURL(NSURL *rootURL) {
    return [rootURL URLByAppendingPathComponent:@"sessions" isDirectory:YES];
}

static NSString *ASSafeFilePart(NSString *value) {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
    ];
    NSMutableString *safe = [NSMutableString string];
    for (NSUInteger index = 0; index < MIN(value.length, 160); index++) {
        unichar character = [value characterAtIndex:index];
        unichar safeCharacter = [allowed characterIsMember:character] ? character : (unichar)'_';
        [safe appendFormat:@"%C", safeCharacter];
    }
    return safe;
}

static NSURL *ASSignalFileURL(NSDictionary *signal, NSURL *rootURL) {
    NSString *filename = [NSString stringWithFormat:@"%@-%@.json",
        signal[@"agent"], ASSafeFilePart(signal[@"session_id"])
    ];
    return [ASSessionsURL(rootURL) URLByAppendingPathComponent:filename];
}

NSArray<NSDictionary *> *ASLoadSignals(NSURL *rootURL) {
    NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:ASSessionsURL(rootURL)
        includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
    NSMutableDictionary<NSString *, NSDictionary *> *byKey = [NSMutableDictionary dictionary];
    for (NSURL *file in files) {
        if (![file.pathExtension isEqualToString:@"json"]) continue;
        NSData *data = [NSData dataWithContentsOfURL:file];
        NSDictionary *raw = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![raw isKindOfClass:[NSDictionary class]] || [raw[@"schema_version"] integerValue] != 1) continue;
        NSMutableDictionary *signal = [raw mutableCopy];
        signal[@"agent"] = ASResolveAgent(raw[@"agent"], raw[@"event_name"]);
        NSString *key = [NSString stringWithFormat:@"%@\0%@", signal[@"agent"], signal[@"session_id"]];
        NSDictionary *previous = byKey[key];
        if (!previous) {
            byKey[key] = signal;
            continue;
        }
        NSString *incomingUpdated = signal[@"updated_at"] ?: @"";
        NSString *previousUpdated = previous[@"updated_at"] ?: @"";
        BOOL newerFirst = [incomingUpdated compare:previousUpdated] != NSOrderedAscending;
        byKey[key] = newerFirst ? ASMergeSignal(previous, signal) : ASMergeSignal(signal, previous);
    }
    return byKey.allValues;
}

BOOL ASWriteSignal(NSDictionary *signal, NSURL *rootURL, NSError **error) {
    NSURL *sessionsURL = ASSessionsURL(rootURL);
    if (![NSFileManager.defaultManager createDirectoryAtURL:sessionsURL
        withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:error]) return NO;

    NSMutableDictionary *corrected = [signal mutableCopy];
    corrected[@"agent"] = ASResolveAgent(signal[@"agent"], signal[@"event_name"]);

    NSDictionary *existing = nil;
    NSURL *fileURL = ASSignalFileURL(corrected, rootURL);
    NSData *existingData = [NSData dataWithContentsOfURL:fileURL];
    if (existingData) existing = [NSJSONSerialization JSONObjectWithData:existingData options:0 error:nil];
    NSDictionary *merged = ASMergeSignal(existing, corrected);
    NSData *data = [NSJSONSerialization dataWithJSONObject:merged options:NSJSONWritingPrettyPrinted error:error];
    if (!data || ![data writeToURL:fileURL options:NSDataWritingAtomic error:error]) return NO;

    if ([corrected[@"agent"] isEqualToString:ASAgentCursor]) {
        for (NSString *other in @[ASAgentCodex, ASAgentClaude]) {
            NSDictionary *siblingProbe = @{
                @"agent": other,
                @"session_id": corrected[@"session_id"] ?: @""
            };
            NSURL *siblingURL = ASSignalFileURL(siblingProbe, rootURL);
            NSData *siblingData = [NSData dataWithContentsOfURL:siblingURL];
            if (!siblingData) continue;
            NSDictionary *prior = [NSJSONSerialization JSONObjectWithData:siblingData options:0 error:nil];
            if ([prior isKindOfClass:[NSDictionary class]] &&
                [ASResolveAgent(prior[@"agent"], prior[@"event_name"]) isEqualToString:ASAgentCursor]) {
                [NSFileManager.defaultManager removeItemAtURL:siblingURL error:nil];
            }
        }
    }
    return YES;
}

BOOL ASClearSignals(NSURL *rootURL, NSError **error) {
    NSURL *sessionsURL = ASSessionsURL(rootURL);
    NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:sessionsURL
        includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
    for (NSURL *file in files) {
        if ([file.pathExtension isEqualToString:@"json"] &&
            ![NSFileManager.defaultManager removeItemAtURL:file error:error]) return NO;
    }
    return YES;
}

NSURL *ASCodexHooksURL(NSURL *homeURL) {
    return [[homeURL URLByAppendingPathComponent:@".codex" isDirectory:YES]
        URLByAppendingPathComponent:@"hooks.json"];
}

NSURL *ASClaudeSettingsURL(NSURL *homeURL) {
    NSString *custom = NSProcessInfo.processInfo.environment[@"CLAUDE_CONFIG_DIR"];
    NSURL *directory = custom.length ? [NSURL fileURLWithPath:custom isDirectory:YES] :
        [homeURL URLByAppendingPathComponent:@".claude" isDirectory:YES];
    return [directory URLByAppendingPathComponent:@"settings.json"];
}

NSURL *ASCursorHooksURL(NSURL *homeURL) {
    return [[homeURL URLByAppendingPathComponent:@".cursor" isDirectory:YES]
        URLByAppendingPathComponent:@"hooks.json"];
}

static NSMutableDictionary *ASLoadMutableJSON(NSURL *url, NSError **error) {
    if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) return [NSMutableDictionary dictionary];
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:error];
    if (!data) return nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:error];
    if (![root isKindOfClass:[NSMutableDictionary class]]) {
        if (error) *error = [NSError errorWithDomain:ASErrorDomain code:2 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"配置文件不是有效 JSON，未做修改：%@", url.path]
        }];
        return nil;
    }
    return root;
}

static BOOL ASCommandIsManaged(NSString *command) {
    if (![command isKindOfClass:[NSString class]] || !command.length) return NO;
    BOOL hasAgent = [command containsString:@"--agent"];
    if (!hasAgent) return NO;
    return [command containsString:ASManagedHookToken] ||
        [command containsString:ASLegacyManagedHookToken] ||
        [command containsString:@"--aidengyu-hook"] ||
        [command containsString:@"--codex-claude-signal-hook"];
}

static BOOL ASIsManagedGroup(NSDictionary *group) {
    NSArray *handlers = [group[@"hooks"] isKindOfClass:[NSArray class]] ? group[@"hooks"] : @[];
    for (NSDictionary *handler in handlers) {
        NSString *command = [handler[@"command"] isKindOfClass:[NSString class]] ? handler[@"command"] : @"";
        if (ASCommandIsManaged(command)) return YES;
    }
    return NO;
}

static BOOL ASIsManagedCursorEntry(NSDictionary *entry) {
    NSString *command = [entry[@"command"] isKindOfClass:[NSString class]] ? entry[@"command"] : @"";
    return ASCommandIsManaged(command) && [command containsString:@"--agent cursor"];
}

static NSString *ASShellQuote(NSString *value) {
    return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

static BOOL ASWriteConfigJSON(NSDictionary *root, NSURL *url, NSError **error) {
    if (![NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:error]) return NO;

    if ([NSFileManager.defaultManager fileExistsAtPath:url.path]) {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"yyyyMMddHHmmssSSS";
        NSURL *backup = [url URLByAppendingPathExtension:
            [NSString stringWithFormat:@"bak-%@", [formatter stringFromDate:NSDate.date]]
        ];
        [NSFileManager.defaultManager copyItemAtURL:url toURL:backup error:nil];
    }

    NSData *data = [NSJSONSerialization dataWithJSONObject:root
        options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:error];
    return data ? [data writeToURL:url options:NSDataWritingAtomic error:error] : NO;
}

static BOOL ASMergeHooksAtURL(
    NSURL *url,
    NSArray<NSString *> *events,
    NSString *agent,
    NSString *hookPath,
    NSError **error
) {
    NSMutableDictionary *root = ASLoadMutableJSON(url, error);
    if (!root) return NO;
    NSMutableDictionary *hooks = [root[@"hooks"] isKindOfClass:[NSMutableDictionary class]] ?
        root[@"hooks"] : [NSMutableDictionary dictionary];
    NSString *command = [NSString stringWithFormat:@"%@ --agent %@", ASShellQuote(hookPath), agent];

    for (NSString *event in events) {
        NSArray *current = [hooks[event] isKindOfClass:[NSArray class]] ? hooks[event] : @[];
        NSMutableArray *groups = [NSMutableArray array];
        for (NSDictionary *group in current) if (!ASIsManagedGroup(group)) [groups addObject:group];
        [groups addObject:@{
            @"hooks": @[@{
                @"type": @"command",
                @"command": command,
                @"timeout": [event isEqualToString:@"PermissionRequest"] ? @5 : @3
            }]
        }];
        hooks[event] = groups;
    }
    root[@"hooks"] = hooks;
    return ASWriteConfigJSON(root, url, error);
}

static BOOL ASMergeCursorHooksAtURL(NSURL *url, NSString *hookPath, NSError **error) {
    NSMutableDictionary *root = ASLoadMutableJSON(url, error);
    if (!root) return NO;
    NSMutableDictionary *hooks = [root[@"hooks"] isKindOfClass:[NSMutableDictionary class]] ?
        root[@"hooks"] : [NSMutableDictionary dictionary];
    NSString *command = [NSString stringWithFormat:@"%@ --agent %@", ASShellQuote(hookPath), ASAgentCursor];

    for (NSString *event in ASCursorHookEvents()) {
        NSArray *current = [hooks[event] isKindOfClass:[NSArray class]] ? hooks[event] : @[];
        NSMutableArray *entries = [NSMutableArray array];
        for (NSDictionary *entry in current) if (!ASIsManagedCursorEntry(entry)) [entries addObject:entry];
        [entries addObject:@{ @"command": command }];
        hooks[event] = entries;
    }
    if (!root[@"version"]) root[@"version"] = @1;
    root[@"hooks"] = hooks;
    return ASWriteConfigJSON(root, url, error);
}

static BOOL ASConfigContainsHook(NSURL *url, NSString *hookPath, NSString *agent) {
    NSMutableDictionary *root = ASLoadMutableJSON(url, nil);
    NSDictionary *hooks = [root[@"hooks"] isKindOfClass:[NSDictionary class]] ? root[@"hooks"] : nil;
    NSArray *groups = [hooks[@"SessionStart"] isKindOfClass:[NSArray class]] ? hooks[@"SessionStart"] : @[];
    for (NSDictionary *group in groups) {
        for (NSDictionary *handler in group[@"hooks"] ?: @[]) {
            NSString *command = handler[@"command"];
            if ([command isKindOfClass:[NSString class]] && [command containsString:hookPath] &&
                [command containsString:[NSString stringWithFormat:@"--agent %@", agent]]) return YES;
        }
    }
    return NO;
}

static BOOL ASCursorConfigContainsHook(NSURL *url, NSString *hookPath) {
    NSMutableDictionary *root = ASLoadMutableJSON(url, nil);
    NSDictionary *hooks = [root[@"hooks"] isKindOfClass:[NSDictionary class]] ? root[@"hooks"] : nil;
    NSArray *entries = [hooks[@"sessionStart"] isKindOfClass:[NSArray class]] ? hooks[@"sessionStart"] : @[];
    for (NSDictionary *entry in entries) {
        NSString *command = entry[@"command"];
        if ([command isKindOfClass:[NSString class]] && [command containsString:hookPath] &&
            [command containsString:@"--agent cursor"]) return YES;
    }
    return NO;
}

NSDictionary<NSString *, NSNumber *> *ASHookStatus(NSString *hookPath, NSURL *homeURL) {
    BOOL codex = ASConfigContainsHook(ASCodexHooksURL(homeURL), hookPath, ASAgentCodex);
    BOOL claude = ASConfigContainsHook(ASClaudeSettingsURL(homeURL), hookPath, ASAgentClaude);
    BOOL cursor = ASCursorConfigContainsHook(ASCursorHooksURL(homeURL), hookPath);
    return @{
        @"codex_installed": @(codex),
        @"claude_installed": @(claude),
        @"cursor_installed": @(cursor),
        @"all_installed": @((BOOL)(codex && claude && cursor))
    };
}

BOOL ASInstallHooks(NSString *hookPath, NSURL *homeURL, NSError **error) {
    if (!ASMergeHooksAtURL(ASCodexHooksURL(homeURL), ASCodexHookEvents(), ASAgentCodex, hookPath, error)) return NO;
    if (!ASMergeHooksAtURL(ASClaudeSettingsURL(homeURL), ASClaudeHookEvents(), ASAgentClaude, hookPath, error)) return NO;
    return ASMergeCursorHooksAtURL(ASCursorHooksURL(homeURL), hookPath, error);
}

static BOOL ASRemoveHooksAtURL(NSURL *url, NSError **error) {
    if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) return YES;
    NSMutableDictionary *root = ASLoadMutableJSON(url, error);
    if (!root) return NO;
    NSMutableDictionary *hooks = [root[@"hooks"] isKindOfClass:[NSMutableDictionary class]] ? root[@"hooks"] : nil;
    if (!hooks) return YES;

    for (NSString *event in [hooks.allKeys copy]) {
        NSArray *groups = [hooks[event] isKindOfClass:[NSArray class]] ? hooks[event] : @[];
        NSMutableArray *filtered = [NSMutableArray array];
        for (NSDictionary *group in groups) if (!ASIsManagedGroup(group)) [filtered addObject:group];
        if (filtered.count) hooks[event] = filtered;
        else [hooks removeObjectForKey:event];
    }
    root[@"hooks"] = hooks;
    return ASWriteConfigJSON(root, url, error);
}

static BOOL ASRemoveCursorHooksAtURL(NSURL *url, NSError **error) {
    if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) return YES;
    NSMutableDictionary *root = ASLoadMutableJSON(url, error);
    if (!root) return NO;
    NSMutableDictionary *hooks = [root[@"hooks"] isKindOfClass:[NSMutableDictionary class]] ? root[@"hooks"] : nil;
    if (!hooks) return YES;

    for (NSString *event in [hooks.allKeys copy]) {
        NSArray *current = [hooks[event] isKindOfClass:[NSArray class]] ? hooks[event] : @[];
        NSMutableArray *filtered = [NSMutableArray array];
        for (NSDictionary *entry in current) if (!ASIsManagedCursorEntry(entry)) [filtered addObject:entry];
        if (filtered.count) hooks[event] = filtered;
        else [hooks removeObjectForKey:event];
    }
    root[@"hooks"] = hooks;
    return ASWriteConfigJSON(root, url, error);
}

BOOL ASUninstallHooks(NSURL *homeURL, NSError **error) {
    if (!ASRemoveHooksAtURL(ASCodexHooksURL(homeURL), error)) return NO;
    if (!ASRemoveHooksAtURL(ASClaudeSettingsURL(homeURL), error)) return NO;
    return ASRemoveCursorHooksAtURL(ASCursorHooksURL(homeURL), error);
}
