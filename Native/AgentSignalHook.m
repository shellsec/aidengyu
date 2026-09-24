#import <Foundation/Foundation.h>
#import "SignalCore.h"

static NSString *ASArgumentValue(NSArray<NSString *> *arguments, NSString *name) {
    NSUInteger index = [arguments indexOfObject:name];
    if (index == NSNotFound || index + 1 >= arguments.count) return nil;
    return arguments[index + 1];
}

static NSString *ASExecutablePath(void) {
    NSString *path = NSProcessInfo.processInfo.arguments.firstObject;
    if ([path hasPrefix:@"/"]) return path;
    return [[NSURL fileURLWithPath:NSFileManager.defaultManager.currentDirectoryPath]
        URLByAppendingPathComponent:path].standardizedURL.path;
}

static void ASPrintJSON(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text) fprintf(stdout, "%s\n", text.UTF8String);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
        NSURL *homeURL = NSFileManager.defaultManager.homeDirectoryForCurrentUser;
        NSString *hookPath = ASArgumentValue(arguments, @"--hook-path") ?: ASExecutablePath();
        NSError *error = nil;

        if ([arguments containsObject:@"--install"]) {
            if (!ASInstallHooks(hookPath, homeURL, &error)) {
                fprintf(stderr, "AgentSignalHook: %s\n", error.localizedDescription.UTF8String);
                return EXIT_FAILURE;
            }
            ASPrintJSON(ASHookStatus(hookPath, homeURL));
            return EXIT_SUCCESS;
        }

        if ([arguments containsObject:@"--uninstall"]) {
            if (!ASUninstallHooks(homeURL, &error)) {
                fprintf(stderr, "AgentSignalHook: %s\n", error.localizedDescription.UTF8String);
                return EXIT_FAILURE;
            }
            ASPrintJSON(@{ @"uninstalled": @YES });
            return EXIT_SUCCESS;
        }

        if ([arguments containsObject:@"--status"]) {
            ASPrintJSON(ASHookStatus(hookPath, homeURL));
            return EXIT_SUCCESS;
        }

        NSString *agent = ASArgumentValue(arguments, @"--agent");
        if (![agent isEqualToString:ASAgentCodex] &&
            ![agent isEqualToString:ASAgentClaude] &&
            ![agent isEqualToString:ASAgentCursor]) {
            fprintf(stderr, "AgentSignalHook requires --agent codex|claude|cursor.\n");
            return EXIT_FAILURE;
        }

        NSData *input = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
        // Cursor may prefix hook stdin with a UTF-8 BOM; NSJSONSerialization rejects it.
        if (input.length >= 3) {
            const uint8_t *bytes = input.bytes;
            if (bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
                input = [input subdataWithRange:NSMakeRange(3, input.length - 3)];
            }
        }
        NSMutableDictionary *payload = nil;
        if (input.length) {
            id object = [NSJSONSerialization JSONObjectWithData:input options:NSJSONReadingMutableContainers error:nil];
            if ([object isKindOfClass:[NSMutableDictionary class]]) payload = object;
        }
        if (!payload) payload = [NSMutableDictionary dictionary];

        NSString *manualSession = ASArgumentValue(arguments, @"--session");
        NSString *manualCwd = ASArgumentValue(arguments, @"--cwd");
        if (!payload[@"session_id"] && manualSession.length) payload[@"session_id"] = manualSession;
        if (!payload[@"cwd"] && manualCwd.length) payload[@"cwd"] = manualCwd;

        NSDictionary *signal = ASMapHookPayload(
            payload,
            agent,
            ASArgumentValue(arguments, @"--event"),
            NSDate.date,
            &error
        );
        if (signal && !ASWriteSignal(signal, ASSignalRootURL(), &error)) signal = nil;
        if ([agent isEqualToString:ASAgentCursor]) ASPrintJSON(@{});

        if (!signal && error) {
            // Status reporting must never break or delay the agent lifecycle.
            fprintf(stderr, "AgentSignalHook: %s\n", error.localizedDescription.UTF8String);
        }
        return EXIT_SUCCESS;
    }
}
