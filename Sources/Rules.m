#import "Rules.h"
#import "Common.h"

static NSDictionary *Defaults(void) {
    return @{
        @"version": @1,
        @"roots": @[@"~/Documents/GitHub", @"~/Developer", @"~/code", @"~/src", @"~/Projects", @"~/repos", @"~/dev"],
        @"depth": @3,
        @"protect": @{
            @"paths": @[],
            // Long-lived branches. A worktree on one of these is a checkout someone keeps on purpose.
            @"branches": @[@"main", @"master", @"develop", @"development", @"dev", @"staging", @"production", @"prod", @"release", @"trunk"]},
        @"ignore": @{@"paths": @[]},
        @"caches": @[@"node_modules", @".next", @".nuxt", @".svelte-kit", @".turbo", @".parcel-cache", @".vite", @".cache", @"dist", @"build",
                     @"out", @"coverage", @".output", @"target", @"_build", @"deps", @".venv", @"venv", @"__pycache__", @".pytest_cache",
                     @".mypy_cache", @".gradle", @"Pods", @"DerivedData", @".expo", @".angular", @".elixir_ls", @".dart_tool"]};
}

@implementation WFRules {
    NSMutableDictionary *_r;
}

+ (instancetype)shared {
    static WFRules *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [WFRules new]; [s reload]; });
    return s;
}

- (NSURL *)fileURL { return [NSURL fileURLWithPath:[WFSupportDir() stringByAppendingPathComponent:@"rules.json"]]; }

static NSMutableArray *List(NSMutableDictionary *r, NSString *group, NSString *key) {
    NSMutableDictionary *g = group ? r[group] : r;
    if (![g isKindOfClass:NSMutableDictionary.class]) { g = [NSMutableDictionary new]; r[group] = g; }
    NSMutableArray *l = g[key];
    if (![l isKindOfClass:NSMutableArray.class]) { l = [NSMutableArray new]; g[key] = l; }
    return l;
}

- (void)reload {
    @synchronized (self) {
        NSData *d = [NSData dataWithContentsOfURL:self.fileURL];
        id j = d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil] : nil;
        BOOL changed = ![j isKindOfClass:NSMutableDictionary.class];
        _r = changed ? [NSMutableDictionary new] : j;
        NSDictionary *def = Defaults();
        for (NSString *key in @[@"roots", @"caches"]) {
            NSMutableArray *l = List(_r, nil, key);
            for (id v in def[key]) if (![l containsObject:v]) { [l addObject:v]; changed = YES; }
        }
        for (NSString *group in @[@"protect", @"ignore"])
            for (NSString *key in def[group]) {
                NSMutableArray *l = List(_r, group, key);
                for (id v in def[group][key]) if (![l containsObject:v]) { [l addObject:v]; changed = YES; }
            }
        if (![_r[@"depth"] isKindOfClass:NSNumber.class]) { _r[@"depth"] = def[@"depth"]; changed = YES; }
        if (![_r[@"version"] isEqual:def[@"version"]]) { _r[@"version"] = def[@"version"]; changed = YES; }
        if (changed) [self save];
    }
}

- (void)save {
    [NSFileManager.defaultManager createDirectoryAtPath:WFSupportDir() withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *d = [NSJSONSerialization dataWithJSONObject:_r options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes error:nil];
    [d writeToURL:self.fileURL atomically:YES];
}

static NSArray<NSString *> *Expanded(NSArray *paths) {
    NSMutableArray *o = [NSMutableArray new];
    for (NSString *p in paths) if ([p isKindOfClass:NSString.class] && p.length) [o addObject:WFAbsolute(p)];
    return o;
}

- (NSArray<NSString *> *)roots {
    NSString *env = NSProcessInfo.processInfo.environment[@"WORKFOREST_ROOTS"];
    if (env.length) return Expanded([env componentsSeparatedByString:@":"]);
    @synchronized (self) { return Expanded(_r[@"roots"]); }
}

- (NSInteger)depth { @synchronized (self) { return MAX(1, MIN(6, [_r[@"depth"] integerValue])); } }

static BOOL Under(NSString *path, NSArray<NSString *> *prefixes) {
    for (NSString *p in prefixes) if ([path isEqualToString:p] || [path hasPrefix:[p stringByAppendingString:@"/"]]) return YES;
    return NO;
}

- (BOOL)protectsPath:(NSString *)path branch:(NSString *)branch {
    @synchronized (self) {
        if (branch && [List(_r, @"protect", @"branches") containsObject:branch]) return YES;
        return Under(path, Expanded(List(_r, @"protect", @"paths")));
    }
}

- (BOOL)ignoresPath:(NSString *)path { @synchronized (self) { return Under(path, Expanded(List(_r, @"ignore", @"paths"))); } }

- (void)setProtected:(BOOL)on path:(NSString *)path {
    @synchronized (self) {
        NSMutableArray *l = List(_r, @"protect", @"paths");
        NSString *t = WFTilde(path);
        [l removeObject:t]; [l removeObject:path];
        if (on) [l addObject:t];
        [self save];
    }
}

- (NSSet<NSString *> *)caches { @synchronized (self) { return [NSSet setWithArray:_r[@"caches"] ?: @[]]; } }

@end
