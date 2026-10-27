#import "Common.h"

NSString *WFFormatBytes(uint64_t b) {
    if (b >= 1ull << 30) return [NSString stringWithFormat:@"%.1f GB", b / (double)(1ull << 30)];
    if (b >= 1ull << 20) return [NSString stringWithFormat:@"%.0f MB", b / (double)(1ull << 20)];
    return [NSString stringWithFormat:@"%.0f KB", b / 1024.0];
}

NSString *WFDuration(NSTimeInterval s) {
    long t = (long)MAX(0, s);
    if (t < 60) return [NSString stringWithFormat:@"%lds", t];
    if (t < 3600) return [NSString stringWithFormat:@"%ldm", t / 60];
    if (t < 86400) return t % 3600 >= 60 ? [NSString stringWithFormat:@"%ldh %ldm", t / 3600, t % 3600 / 60] : [NSString stringWithFormat:@"%ldh", t / 3600];
    return t % 86400 >= 3600 && t < 7 * 86400 ? [NSString stringWithFormat:@"%ldd %ldh", t / 86400, t % 86400 / 3600] : [NSString stringWithFormat:@"%ldd", t / 86400];
}

NSString *WFSupportDir(void) {
    NSString *env = NSProcessInfo.processInfo.environment[@"WORKFOREST_HOME"];
    if (env.length) return env;
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/WorkForest"];
}

NSString *WFShellQuote(NSString *s) {
    if (s.length && [s rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:@%+,"] invertedSet]].location == NSNotFound) return s;
    return [NSString stringWithFormat:@"'%@'", [s stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

NSString *WFRedact(NSString *s) {
    static NSArray<NSArray *> *rules; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *word = @"(?:token|secret|password|passwd|pwd|api[_-]?key|apikey|auth|credential|private[_-]?key|session|cookie|bearer)";
        rules = @[
            @[[NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"(?i)(\\b[\\w.-]*%@[\\w.-]*\\s*[=:]\\s*)[^\\s'\"]+", word] options:0 error:nil], @"$1<redacted>"],
            @[[NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"(?i)(--?[\\w-]*%@[\\w-]*\\s+)[^\\s-][^\\s]*", word] options:0 error:nil], @"$1<redacted>"],
            @[[NSRegularExpression regularExpressionWithPattern:@"(://)[^/\\s:@]+:[^/\\s@]+@" options:0 error:nil], @"$1<redacted>@"],
            @[[NSRegularExpression regularExpressionWithPattern:@"[A-Za-z0-9+_\\-]{40,}" options:0 error:nil], @"<redacted>"]];
    });
    if (!s) return nil;
    NSMutableString *m = [s mutableCopy];
    for (NSArray *r in rules) [r[0] replaceMatchesInString:m options:0 range:NSMakeRange(0, m.length) withTemplate:r[1]];
    return m;
}

NSString *WFAbsolute(NSString *path) {
    path = path.stringByExpandingTildeInPath;
    if (!path.isAbsolutePath) path = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:path];
    // realpath, not stringByStandardizingPath: the kernel and git name /var as /private/var, and paths must match theirs.
    // A path that does not exist yet, such as a worktree to restore, resolves through its nearest existing parent.
    char buf[PATH_MAX];
    if (realpath(path.fileSystemRepresentation, buf)) return @(buf);
    NSString *parent = path.stringByDeletingLastPathComponent;
    if (parent.length > 1 && ![parent isEqualToString:path]) return [WFAbsolute(parent) stringByAppendingPathComponent:path.lastPathComponent];
    return path.stringByStandardizingPath;
}

NSString *WFTilde(NSString *path) {
    NSString *home = NSHomeDirectory();
    return [path hasPrefix:home] ? [@"~" stringByAppendingString:[path substringFromIndex:home.length]] : path;
}

NSString *WFClip(NSString *s, NSUInteger n) {
    if (![s isKindOfClass:NSString.class]) return nil;
    s = [[[s componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
          filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]] componentsJoinedByString:@" "];
    s = [WFRedact(s) stringByReplacingOccurrencesOfString:NSHomeDirectory() withString:@"~"];
    if (!s.length) return nil;
    return s.length > n ? [[s substringToIndex:n - 1] stringByAppendingString:@"…"] : s;
}

NSString *WFGitPath(void) {
    for (NSString *p in @[@"/Library/Developer/CommandLineTools/usr/bin/git", @"/opt/homebrew/bin/git", @"/usr/local/bin/git",
                          @"/Applications/Xcode.app/Contents/Developer/usr/bin/git"])
        if ([NSFileManager.defaultManager isExecutableFileAtPath:p]) return p;
    return nil;   // /usr/bin/git without the tools installed would ask the user to install them
}

NSString *WFGitInput(NSString *dir, NSArray<NSString *> *args, NSData *input, NSTimeInterval timeout, int *status) {
    NSString *git = WFGitPath();
    if (status) *status = -1;
    if (!git) return nil;
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:git];
    t.arguments = [@[@"-C", dir, @"--no-pager"] arrayByAddingObjectsFromArray:args];
    NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
    env[@"GIT_OPTIONAL_LOCKS"] = @"0"; env[@"GIT_TERMINAL_PROMPT"] = @"0"; env[@"LC_ALL"] = @"C";
    t.environment = env;
    NSPipe *out = [NSPipe pipe], *in = input ? [NSPipe pipe] : nil;
    t.standardOutput = out; t.standardError = [NSFileHandle fileHandleWithNullDevice];
    t.standardInput = in ?: [NSFileHandle fileHandleWithNullDevice];
    if (![t launchAndReturnError:nil]) return nil;
    __block NSData *d = nil;
    dispatch_group_t g = dispatch_group_create();
    dispatch_group_async(g, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ d = [out.fileHandleForReading readDataToEndOfFile]; });
    if (in) dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try { [in.fileHandleForWriting writeData:input]; } @catch (NSException *e) {}
        [in.fileHandleForWriting closeFile];
    });
    if (dispatch_group_wait(g, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) != 0) { [t terminate]; return nil; }
    [t waitUntilExit];
    if (status) *status = t.terminationStatus;
    return [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
}

NSString *WFGit(NSString *dir, NSArray<NSString *> *args, int *status) { return WFGitInput(dir, args, nil, 10, status); }
