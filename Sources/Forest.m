#import "Forest.h"
#import "Common.h"
#import "Rules.h"

static const double kMinConfidence = 0.6;        // a stale verdict below this does not count
static const double kSureConfidence = 0.8;       // a stale verdict this sure needs no second look
static const NSTimeInterval kReviewFresh = 6 * 3600;   // the modes act only on a review this recent
static const uint64_t kSaveFileMax = 20ull << 20, kSaveTotalMax = 100ull << 20;   // ignored files saved before a removal

#pragma mark - Preferences

static CFStringRef const kDomain = CFSTR("no.guerrilla.workforest");
id WFPref(NSString *key) { return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, kDomain)); }
void WFSetPref(NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, kDomain);
    CFPreferencesAppSynchronize(kDomain);
}
BOOL WFPrefBool(NSString *key, BOOL dflt) { id v = WFPref(key); return v ? [v boolValue] : dflt; }
NSInteger WFPrefInt(NSString *key, NSInteger dflt) { id v = WFPref(key); return v ? [v integerValue] : dflt; }
NSString *WFModel(void) { id v = WFPref(@"workforest.model"); return [v isKindOfClass:NSString.class] && [v length] ? v : @"auto"; }

NSArray<NSString *> *WFModeNames(void) { return @[@"idle", @"proactive", @"eager"]; }
NSString *WFModeLabel(WFMode m) { return WFModeNames()[m].capitalizedString; }
NSInteger WFModeFrom(NSString *s) { NSUInteger i = [WFModeNames() indexOfObject:s.lowercaseString ?: @""]; return i == NSNotFound ? -1 : (NSInteger)i; }
WFMode WFCurrentMode(void) { id v = WFPref(@"workforest.mode"); NSInteger m = [v isKindOfClass:NSString.class] ? WFModeFrom(v) : -1; return m < 0 ? WFModeEager : (WFMode)m; }
void WFSetMode(WFMode m) { WFSetPref(@"workforest.mode", WFModeNames()[m]); }

/// Hours or days from a test variable, else the default, as seconds.
static NSTimeInterval EnvHours(NSString *key, double hours) {
    NSString *env = NSProcessInfo.processInfo.environment[key];
    return (env.length ? env.doubleValue : hours) * 3600;
}
static NSTimeInterval Recent(void)         { return EnvHours(@"WORKFOREST_RECENT_HOURS", 24); }   // activity this recent keeps a worktree
static NSTimeInterval ProactiveQuiet(void) { return EnvHours(@"WORKFOREST_PROACTIVE_HOURS", 7 * 24); }
static NSTimeInterval Grace(void)          { return EnvHours(@"WORKFOREST_GRACE_HOURS", 24); }

static NSString *SincePath(void) { return [WFSupportDir() stringByAppendingPathComponent:@"watching-since"]; }

/// When WorkForest started watching: the app's first launch, or the first real `workforest auto`. nil before that,
/// so a mode never acts on the strength of the CLI having been tried once. Kept in the support folder.
static NSDate *Since(void) {
    NSString *s = [NSString stringWithContentsOfFile:SincePath() encoding:NSUTF8StringEncoding error:nil];
    return s.doubleValue > 0 ? [NSDate dateWithTimeIntervalSince1970:s.doubleValue] : nil;
}
void WFStartWatching(void) {
    if (Since()) return;
    [NSFileManager.defaultManager createDirectoryAtPath:WFSupportDir() withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSString stringWithFormat:@"%.0f\n", NSDate.date.timeIntervalSince1970] writeToFile:SincePath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
NSTimeInterval WFGraceLeft(void) { NSDate *d = Since(); return d ? MAX(0, Grace() + d.timeIntervalSinceNow) : Grace(); }
BOOL WFGraceOver(void) { NSDate *d = Since(); return d && -d.timeIntervalSinceNow >= Grace(); }
NSString *WFGraceWords(void) {
    NSDate *d = Since();
    return d ? [NSString stringWithFormat:@"WorkForest has watched for %@; modes act after %@", WFDuration(-d.timeIntervalSinceNow), WFDuration(Grace())]
             : [NSString stringWithFormat:@"WorkForest has not started watching; modes act %@ after the app first runs", WFDuration(Grace())];
}

#pragma mark - Words

static NSString *Plural(NSInteger n, NSString *word) { return [NSString stringWithFormat:@"%ld %@%@", (long)n, word, n == 1 ? @"" : @"s"]; }

NSString *WFStateWords(WFTree *t) {
    if (t.prunable) return @"folder missing";
    NSMutableArray *p = [NSMutableArray new];
    if (t.merged) [p addObject:[t.merged isEqualToString:@"ancestor"] ? @"merged" : [t.merged stringByAppendingString:@"-merged"]];
    if ([t.upstream isEqualToString:@"gone"]) [p addObject:@"remote branch deleted"];
    else if ([t.upstream isEqualToString:@"none"] && !t.isMain) [p addObject:@"never pushed"];
    if (t.dirty > 0) [p addObject:Plural(t.dirty, @"change")];
    if (t.dirty < 0) [p addObject:@"status unknown"];
    if (t.untracked > 0) [p addObject:Plural(t.untracked, @"untracked file")];
    if (t.unpushed > 0 && !t.merged) [p addObject:[NSString stringWithFormat:@"%@ only here", Plural(t.unpushed, @"commit")]];
    if (t.detached) [p addObject:t.orphanCommits > 0 ? [NSString stringWithFormat:@"detached, %ld commits no branch holds", (long)t.orphanCommits] : @"detached"];
    if (t.locked) [p addObject:@"locked"];
    if (!t.merged && t.notInDefault > 0) [p addObject:[NSString stringWithFormat:@"%@ not in %@", Plural(t.notInDefault, @"commit"), t.defaultBranch ?: @"the default branch"]];
    return p.count ? [p componentsJoinedByString:@" · "] : @"clean";
}

NSString *WFSessionWords(NSDictionary *s) {
    if (!s) return @"no agent session found";
    NSString *t = s[@"title"] ?: s[@"first_prompt"];
    return [NSString stringWithFormat:@"%@%@, %@, last active %@ ago", s[@"agent"], t ? [NSString stringWithFormat:@" \"%@\"", t] : @"", s[@"match"],
            WFDuration([s[@"last_active_minutes_ago"] doubleValue] * 60)];
}

#pragma mark - Keep

static NSString *KeptPath(void) { return [WFSupportDir() stringByAppendingPathComponent:@"kept.json"]; }

static NSMutableDictionary *KeptAll(void) {
    NSData *d = [NSData dataWithContentsOfFile:KeptPath()];
    id j = d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil] : nil;
    return [j isKindOfClass:NSMutableDictionary.class] ? j : [NSMutableDictionary new];
}

NSDate *WFKeptUntil(NSString *path) {
    NSNumber *n = KeptAll()[path];
    return [n isKindOfClass:NSNumber.class] && n.doubleValue > NSDate.date.timeIntervalSince1970 ? [NSDate dateWithTimeIntervalSince1970:n.doubleValue] : nil;
}

void WFSetKept(NSString *path, NSDate *until) {
    NSMutableDictionary *all = KeptAll();
    for (NSString *k in all.allKeys) if ([all[k] doubleValue] <= NSDate.date.timeIntervalSince1970) [all removeObjectForKey:k];
    if (until) all[path] = @(until.timeIntervalSince1970); else [all removeObjectForKey:path];
    [NSFileManager.defaultManager createDirectoryAtPath:WFSupportDir() withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSJSONSerialization dataWithJSONObject:all options:0 error:nil] writeToFile:KeptPath() atomically:YES];
}

#pragma mark - Decisions

NSString *WFWorkKeeps(WFTree *t) {
    if (t.isMain) return @"the main checkout";
    if (t.prunable) return @"its folder is missing; `workforest prune` tidies git's record of it";
    if (t.isProtected) return @"protected";
    NSDate *kept = WFKeptUntil(t.path);
    if (kept) return [NSString stringWithFormat:@"kept by you for %@ more", WFDuration(kept.timeIntervalSinceNow)];
    if (t.locked) return t.lockReason.length ? [@"locked: " stringByAppendingString:t.lockReason] : @"locked";
    if (!t.factsRead) return @"not read yet";
    if (t.dirty < 0) return @"git status failed, so its changes are unknown";
    if (t.dirty > 0) return [NSString stringWithFormat:@"%@ not committed", Plural(t.dirty, @"change")];
    if (t.untracked > 0) return [NSString stringWithFormat:@"%@ not committed", Plural(t.untracked, @"untracked file")];
    if (t.detached && t.orphanCommits != 0) return t.orphanCommits < 0 ? @"detached, and its commits could not be counted" : [NSString stringWithFormat:@"detached with %@ no branch holds", Plural(t.orphanCommits, @"commit")];
    if (t.unpushed < 0 && !t.merged) return @"its commits could not be counted";
    if (t.unpushed > 0 && !t.merged) return [NSString stringWithFormat:@"%@ on no remote and not in %@", Plural(t.unpushed, @"commit"), t.defaultBranch ?: @"the default branch"];
    if (t.processes.count) return [NSString stringWithFormat:@"%@ running inside", [t.processes.firstObject componentsSeparatedByString:@" (pid"].firstObject];
    if (t.servers.count) return [NSString stringWithFormat:@"localhost :%@ running inside", t.servers.firstObject[@"port"]];
    id m = t.session[@"last_active_minutes_ago"];
    if (m && [m doubleValue] * 60 < Recent()) return [NSString stringWithFormat:@"%@ session active %@ ago", t.session[@"agent"], WFDuration([m doubleValue] * 60)];
    if (t.touched && -t.touched.timeIntervalSinceNow < Recent()) return [NSString stringWithFormat:@"files changed %@ ago", WFDuration(-t.touched.timeIntervalSinceNow)];
    if (!t.sizedAt) return @"its files are not read yet";
    if (t.created && -t.created.timeIntervalSinceNow < Recent()) return [NSString stringWithFormat:@"made %@ ago", WFDuration(-t.created.timeIntervalSinceNow)];
    return nil;
}

NSString *WFMustKeep(WFTree *t, WFReview *r) {
    NSString *work = WFWorkKeeps(t);
    if (work || !r) return work ?: @"no review yet";
    if (r.error) return @"the last review failed";
    if (-r.at.timeIntervalSinceNow > kReviewFresh) return [NSString stringWithFormat:@"the last review is %@ old", WFDuration(-r.at.timeIntervalSinceNow)];
    if (t.lastWork && [t.lastWork compare:r.at] == NSOrderedDescending) return @"worked on after the last review";
    if (!r.verdicts[t.path]) return @"not in the last review";
    return nil;
}

NSArray<NSDictionary *> *WFPlan(NSArray<WFTree *> *trees, WFReview *r, WFMode mode) {
    NSMutableArray *plan = [NSMutableArray new];
    BOOL grace = WFGraceOver();
    for (WFTree *t in trees) {
        if (t.isMain) continue;
        NSString *why = WFMustKeep(t, r);
        BOOL remove = NO;
        WFVerdict *v = r.verdicts[t.path];
        BOOL stale = [v.verdict isEqualToString:@"stale"];
        NSString *quiet = WFDuration(t.quiet);
        if (why) {
        } else if (mode == WFModeIdle) {
            why = stale ? [NSString stringWithFormat:@"Idle mode only reports; the review calls it stale: %@", v.reason] : @"Idle mode only reports";
        } else if (mode == WFModeProactive) {
            BOOL done = t.merged || [t.upstream isEqualToString:@"gone"];
            if (!done) why = @"not merged and the remote branch still exists";
            else if (t.quiet < ProactiveQuiet()) why = [NSString stringWithFormat:@"quiet %@; Proactive waits %@", quiet, WFDuration(ProactiveQuiet())];
            else if (v.keepEvidence.length && ![v.verdict isEqualToString:@"stale"]) why = [@"evidence: " stringByAppendingString:v.keepEvidence];
            else { remove = YES; why = [NSString stringWithFormat:@"%@, quiet %@", t.merged ? [NSString stringWithFormat:@"merged (%@)", t.merged] : @"upstream gone", quiet]; }
        } else if (v.judged) {
            if (stale && v.confidence >= kMinConfidence) { remove = YES; why = [NSString stringWithFormat:@"quiet %@, no evidence to keep it: %@", quiet, v.reason]; }
            else why = stale ? [NSString stringWithFormat:@"the judge was not sure (%.0f%%)", v.confidence * 100]
                             : [NSString stringWithFormat:@"evidence: %@", v.keepEvidence.length ? v.keepEvidence : v.reason];
        } else if (stale && v.confidence >= kSureConfidence) {
            remove = YES; why = [NSString stringWithFormat:@"quiet %@: %@", quiet, v.reason];
        } else if (v.keepEvidence.length) {
            why = [@"evidence: " stringByAppendingString:v.keepEvidence];
        } else if (r.judgeError && stale && v.confidence >= kMinConfidence && (t.merged || [t.upstream isEqualToString:@"gone"])) {
            remove = YES; why = [NSString stringWithFormat:@"quiet %@: %@ (the judge failed)", quiet, v.reason];
        } else {
            why = r.judgeError ? [@"the judge failed: " stringByAppendingString:r.judgeError] : @"not judged yet";
        }
        if (remove && !grace) { remove = NO; why = [NSString stringWithFormat:@"would remove (%@), but %@", why, WFGraceWords()]; }
        [plan addObject:@{@"tree": t, @"remove": @(remove), @"why": why}];
    }
    return plan;
}

NSArray<WFTree *> *WFJudgeSubjects(NSArray<WFTree *> *trees, WFReview *r) {
    NSMutableArray *j = [NSMutableArray new];
    for (WFTree *t in trees) {
        if (WFMustKeep(t, r)) continue;
        WFVerdict *v = r.verdicts[t.path];
        if (v.judged || ([v.verdict isEqualToString:@"stale"] && v.confidence >= kSureConfidence)) continue;
        [j addObject:t];
    }
    return j;
}

NSArray<WFTree *> *WFCandidates(NSArray<WFTree *> *trees, WFReview *r) {
    NSMutableArray *c = [NSMutableArray new];
    for (WFTree *t in trees) {
        if (WFMustKeep(t, r)) continue;
        WFVerdict *v = r.verdicts[t.path];
        if ([v.verdict isEqualToString:@"stale"] && v.confidence >= kMinConfidence) [c addObject:t];
    }
    return c;
}

WFReview *WFRunReview(NSArray<WFTree *> *trees, NSString *model, WFMode mode, NSString *trigger) {
    NSArray *linked = [trees filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"isMain == NO AND prunable == NO"]];
    WFReview *r = [WFReviewer review:linked model:model];
    r.mode = WFModeNames()[mode]; r.trigger = trigger;
    if (!r.error && mode == WFModeEager) [WFReviewer judge:WFJudgeSubjects(linked, r) review:r model:model];
    return r;
}

NSString *WFCategory(WFTree *t, WFReview *r) {
    if (t.prunable) return @"missing";
    NSString *work = WFWorkKeeps(t);
    if (work && !t.isProtected && !t.locked && !t.prunable && ![work hasPrefix:@"not read"] && ![work hasPrefix:@"its files"] && ![work hasPrefix:@"kept by"]) return @"active";
    if (t.merged || [t.upstream isEqualToString:@"gone"]) return @"merged";
    if ([r.verdicts[t.path].verdict isEqualToString:@"stale"] || t.quiet > 14 * 86400) return @"stale";
    return @"quiet";
}

#pragma mark - Removal

static NSString *RemovedPath(void) { return [WFSupportDir() stringByAppendingPathComponent:@"removed.json"]; }
static NSString *SavedDir(NSString *rid) { return [[WFSupportDir() stringByAppendingPathComponent:@"removed"] stringByAppendingPathComponent:rid]; }

NSArray<NSDictionary *> *WFRemoved(void) {
    NSData *d = [NSData dataWithContentsOfFile:RemovedPath()];
    id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    return [j isKindOfClass:NSArray.class] ? j : @[];
}

static void SetRemoved(NSArray *all) {
    [NSFileManager.defaultManager createDirectoryAtPath:WFSupportDir() withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSJSONSerialization dataWithJSONObject:all ?: @[] options:NSJSONWritingPrettyPrinted | NSJSONWritingWithoutEscapingSlashes error:nil] writeToFile:RemovedPath() atomically:YES];
}

void WFClearRemoved(void) {
    for (NSDictionary *r in WFRemoved()) [NSFileManager.defaultManager removeItemAtPath:SavedDir(r[@"id"]) error:nil];
    SetRemoved(@[]);
}

static uint64_t SizeOf(NSString *path) {
    NSDictionary *a = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    if (![a.fileType isEqualToString:NSFileTypeDirectory]) return a.fileSize;
    uint64_t n = 0;
    NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtPath:path];
    while ([e nextObject]) { n += e.fileAttributes.fileSize; if (n > kSaveTotalMax) break; }
    return n;
}

/// Ignored files that are not caches, such as .env.local: git would delete them with the worktree.
/// Copied into the support folder, each up to 20 MB and 100 MB in all. Returns the saved and the skipped relative paths.
static void SaveIgnored(NSString *path, NSString *dest, NSMutableArray *saved, NSMutableArray *skipped) {
    int st = 0;
    NSString *out = WFGitInput(path, @[@"ls-files", @"--others", @"--ignored", @"--exclude-standard", @"--directory", @"--no-empty-directory"], nil, 30, &st);
    if (st != 0) return;
    NSSet *caches = WFRules.shared.caches;
    uint64_t total = 0;
    for (NSString *raw in [out componentsSeparatedByString:@"\n"]) {
        NSString *rel = [raw hasSuffix:@"/"] ? [raw substringToIndex:raw.length - 1] : raw;
        if (!rel.length) continue;
        BOOL cache = NO;
        for (NSString *c in rel.pathComponents) if ([caches containsObject:c] || [c isEqualToString:@".DS_Store"]) { cache = YES; break; }
        if (cache) continue;
        NSString *src = [path stringByAppendingPathComponent:rel];
        uint64_t size = SizeOf(src);
        if (size > kSaveFileMax || total + size > kSaveTotalMax) { [skipped addObject:rel]; continue; }
        NSString *to = [dest stringByAppendingPathComponent:rel];
        [NSFileManager.defaultManager createDirectoryAtPath:to.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        if ([NSFileManager.defaultManager copyItemAtPath:src toPath:to error:nil]) { [saved addObject:rel]; total += size; }
        else [skipped addObject:rel];
    }
}

NSDictionary *WFRemove(NSString *path, NSString *by, NSString *why, NSString **error) {
    path = WFAbsolute(path);
    WFTree *t = [WFScanner fresh:path];   // a new walk, sessions and processes: the decision is checked on what is true now
    if (!t) { *error = @"not a git worktree"; return nil; }
    NSString *keep = WFWorkKeeps(t);
    if (keep) { *error = [@"kept: " stringByAppendingString:keep]; return nil; }
    NSString *rid = [[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""] substringToIndex:8].lowercaseString;
    NSString *dir = SavedDir(rid);
    NSMutableArray *saved = [NSMutableArray new], *skipped = [NSMutableArray new];
    SaveIgnored(t.path, [dir stringByAppendingPathComponent:@"files"], saved, skipped);
    int st = 0;
    WFGitInput(t.repo, @[@"worktree", @"remove", t.path], nil, 120, &st);   // never --force: git refuses a worktree with changes
    if (st != 0) {
        [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
        *error = @"git worktree remove refused; the worktree is unchanged";
        return nil;
    }
    BOOL branchDeleted = NO;
    if (t.branch && t.merged) {   // -d, never -D: git deletes only a branch it can see is merged
        WFGit(t.repo, @[@"branch", @"-d", t.branch], &st);
        branchDeleted = st == 0;
    }
    NSDictionary *rec = @{@"id": rid, @"at": @(NSDate.date.timeIntervalSince1970), @"repo": t.repo, @"path": t.path,
                          @"branch": t.branch ?: NSNull.null, @"head": t.head ?: @"", @"branchDeleted": @(branchDeleted),
                          @"merged": t.merged ?: NSNull.null, @"subject": t.lastSubject ?: @"", @"diskBytes": @(t.diskBytes),
                          @"cacheBytes": @(t.cacheBytes), @"saved": saved, @"skipped": skipped, @"by": by ?: @"you", @"why": why ?: @""};
    NSMutableArray *all = [WFRemoved() mutableCopy];
    [all insertObject:rec atIndex:0];
    while (all.count > 50) { [NSFileManager.defaultManager removeItemAtPath:SavedDir(all.lastObject[@"id"]) error:nil]; [all removeLastObject]; }
    SetRemoved(all);
    return rec;
}

NSString *WFRestore(NSString *key) {
    NSString *path = WFAbsolute(key);
    NSDictionary *rec = nil;
    for (NSDictionary *r in WFRemoved()) if ([r[@"id"] isEqual:key] || [r[@"path"] isEqual:path]) { rec = r; break; }
    if (!rec) return @"no removed worktree with that id or path";
    if ([NSFileManager.defaultManager fileExistsAtPath:rec[@"path"]]) return @"something already exists at that path";
    int st = 0;
    NSString *branch = [rec[@"branch"] isKindOfClass:NSString.class] ? rec[@"branch"] : nil;
    NSArray *args;
    if (branch) {
        WFGit(rec[@"repo"], @[@"rev-parse", @"--verify", @"--quiet", [@"refs/heads/" stringByAppendingString:branch]], &st);
        args = st == 0 ? @[@"worktree", @"add", rec[@"path"], branch] : @[@"worktree", @"add", @"-b", branch, rec[@"path"], rec[@"head"]];
    } else args = @[@"worktree", @"add", @"--detach", rec[@"path"], rec[@"head"]];
    WFGitInput(rec[@"repo"], args, nil, 120, &st);
    if (st != 0) return @"git worktree add failed: the branch may be checked out elsewhere, or the commit is gone";
    NSString *files = [SavedDir(rec[@"id"]) stringByAppendingPathComponent:@"files"];
    for (NSString *rel in rec[@"saved"]) {
        NSString *to = [rec[@"path"] stringByAppendingPathComponent:rel];
        if ([NSFileManager.defaultManager fileExistsAtPath:to]) continue;
        [NSFileManager.defaultManager createDirectoryAtPath:to.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        [NSFileManager.defaultManager copyItemAtPath:[files stringByAppendingPathComponent:rel] toPath:to error:nil];
    }
    NSMutableArray *all = [NSMutableArray new];
    for (NSDictionary *r in WFRemoved()) if (![r[@"id"] isEqual:rec[@"id"]]) [all addObject:r];
    SetRemoved(all);
    [NSFileManager.defaultManager removeItemAtPath:SavedDir(rec[@"id"]) error:nil];
    return nil;
}

NSArray<NSDictionary *> *WFAutoRemove(NSArray<WFTree *> *trees, WFReview *r, WFMode mode) {
    if (mode == WFModeIdle) return @[];
    NSMutableArray *actions = [NSMutableArray new];
    for (NSDictionary *p in WFPlan(trees, r, mode)) {
        if (![p[@"remove"] boolValue]) continue;
        WFTree *t = p[@"tree"];
        NSString *err = nil;
        NSDictionary *rec = WFRemove(t.path, WFModeLabel(mode), p[@"why"], &err);
        [actions addObject:@{@"path": t.path, @"repo": t.repoName ?: @"", @"branch": t.branch ?: @"", @"diskBytes": @(t.diskBytes),
                             @"why": p[@"why"], @"removed": @(rec ? YES : NO), @"id": rec[@"id"] ?: NSNull.null, @"error": err ?: NSNull.null,
                             @"at": @(NSDate.date.timeIntervalSince1970)}];
    }
    return actions;
}
