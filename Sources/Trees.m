#import "Trees.h"
#import "Common.h"
#import "Rules.h"
#import <libproc.h>
#import <sys/proc_info.h>
#import <fts.h>
#import <sys/stat.h>

static const NSTimeInterval kFactsFresh = 600;        // history and merge state are read again after ten minutes, or when HEAD moves; status every scan
static const NSTimeInterval kSizeFresh = 6 * 3600;    // full disk walks are repeated after six hours
static const NSTimeInterval kQuickFresh = 15 * 60;    // walks for the newest change outside caches, after fifteen minutes; a removal always walks again
static const NSTimeInterval kMentionWindow = 14 * 86400;   // session logs older than this are not searched for mentions
static const NSUInteger kTailBytes = 16 << 20;        // the part of a long session log searched for mentions

#pragma mark - WFTree

@implementation WFTree

- (NSString *)name { return self.path.lastPathComponent; }
- (NSString *)repoName { return self.repo.lastPathComponent; }

- (NSDate *)lastWork {
    NSDate *d = self.lastCommit ?: self.created;
    if (self.touched && (!d || [self.touched compare:d] == NSOrderedDescending)) d = self.touched;
    id m = self.session[@"last_active_minutes_ago"];
    NSDate *s = m ? [NSDate dateWithTimeIntervalSinceNow:-[m doubleValue] * 60] : nil;
    if (s && (!d || [s compare:d] == NSOrderedDescending)) d = s;
    return d;
}

- (NSTimeInterval)quiet { return self.lastWork ? -self.lastWork.timeIntervalSinceNow : 0; }

static id Days(NSDate *d) { return d ? @(round(-d.timeIntervalSinceNow / 8640) / 10) : NSNull.null; }

- (NSDictionary *)json {
    return @{@"path": self.path, @"repo": self.repo ?: @"", @"branch": self.branch ?: NSNull.null, @"head": self.head ?: @"",
             @"main": @(self.isMain), @"locked": @(self.locked), @"prunable": @(self.prunable), @"detached": @(self.detached),
             @"lastCommitAt": self.lastCommit ? @(self.lastCommit.timeIntervalSince1970) : NSNull.null, @"lastSubject": self.lastSubject ?: NSNull.null,
             @"lastAuthor": self.lastAuthor ?: NSNull.null, @"dirty": @(self.dirty), @"untracked": @(self.untracked), @"stashes": @(self.stashes),
             @"unpushed": @(self.unpushed), @"orphanCommits": @(self.orphanCommits), @"notInDefault": @(self.notInDefault),
             @"merged": self.merged ?: NSNull.null, @"pr": self.pr ?: NSNull.null, @"upstream": self.upstream ?: NSNull.null,
             @"ahead": @(self.ahead), @"behind": @(self.behind), @"defaultBranch": self.defaultBranch ?: NSNull.null,
             @"fetchedAt": self.fetched ? @(self.fetched.timeIntervalSince1970) : NSNull.null,
             @"createdAt": self.created ? @(self.created.timeIntervalSince1970) : NSNull.null,
             @"diskBytes": @(self.diskBytes), @"cacheBytes": @(self.cacheBytes), @"files": @(self.files),
             @"touchedAt": self.touched ? @(self.touched.timeIntervalSince1970) : NSNull.null, @"sized": @(self.sizedAt != nil),
             @"processes": self.processes ?: @[], @"servers": self.servers ?: @[], @"session": self.session ?: NSNull.null,
             @"protected": @(self.isProtected), @"quietDays": Days(self.lastWork)};
}

@end

#pragma mark - Discovery

/// Folders under the roots that hold a .git: a folder for a main checkout, a file for a linked worktree.
/// Caches, hidden folders and the inside of repos are not searched; linked worktrees inside a repo come from git itself.
static void Walk(NSString *dir, NSInteger depth, BOOL root, NSSet *caches, NSMutableSet *mains, NSMutableSet *linked) {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    NSString *git = [dir stringByAppendingPathComponent:@".git"];
    if ([fm fileExistsAtPath:git isDirectory:&isDir]) {
        [(isDir ? mains : linked) addObject:dir];
        if (!root) return;   // a scan root that is itself a repo, such as a folder of projects under git, is still searched
    }
    if (depth <= 0) return;
    for (NSString *n in [fm contentsOfDirectoryAtPath:dir error:nil]) {
        if ([n hasPrefix:@"."] || [caches containsObject:n]) continue;
        NSString *p = [dir stringByAppendingPathComponent:n];
        NSDictionary *a = [fm attributesOfItemAtPath:p error:nil];
        if (![a.fileType isEqualToString:NSFileTypeDirectory]) continue;   // symlinks are not followed
        Walk(p, depth - 1, NO, caches, mains, linked);
    }
}

/// `git worktree list --porcelain` for one repo: the main worktree first.
static NSArray<WFTree *> *Worktrees(NSString *repo) {
    int st = 0;
    NSString *out = WFGit(repo, @[@"worktree", @"list", @"--porcelain"], &st);
    NSString *common = WFGit(repo, @[@"rev-parse", @"--path-format=absolute", @"--git-common-dir"], NULL);
    if (st != 0 || !out.length) return @[];
    NSMutableArray *trees = [NSMutableArray new];
    WFTree *t = nil;
    for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"worktree "]) {
            t = [WFTree new]; t.path = [line substringFromIndex:9]; t.commonDir = common;
            t.isMain = trees.count == 0; [trees addObject:t];
        } else if ([line isEqualToString:@"bare"]) { [trees removeObject:t]; t = nil; }
        else if ([line hasPrefix:@"HEAD "]) t.head = [line substringFromIndex:5];
        else if ([line hasPrefix:@"branch "]) t.branch = [[line substringFromIndex:7] stringByReplacingOccurrencesOfString:@"refs/heads/" withString:@""];
        else if ([line isEqualToString:@"detached"]) t.detached = YES;
        else if ([line hasPrefix:@"locked"]) { t.locked = YES; t.lockReason = line.length > 7 ? [line substringFromIndex:7] : nil; }
        else if ([line hasPrefix:@"prunable"]) t.prunable = YES;
    }
    NSString *main = [(WFTree *)trees.firstObject path] ?: repo;
    for (WFTree *w in trees) w.repo = main;
    return trees;
}

#pragma mark - Git facts

static NSString *PatchPath(void) { return [WFSupportDir() stringByAppendingPathComponent:@"patch-ids.json"]; }

/// The patch-ids of the newest 400 commits on the default branch, kept on disk by the branch's tip, so a squash
/// merge is found by comparing one patch-id per worktree instead of reading the branch's history every scan.
static NSSet<NSString *> *DefaultPatchIds(NSString *repo, NSString *def) {
    static NSMutableDictionary *disk; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSData *d = [NSData dataWithContentsOfFile:PatchPath()];
        id j = d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil] : nil;
        disk = [j isKindOfClass:NSMutableDictionary.class] ? j : [NSMutableDictionary new];
    });
    int st = 0;
    NSString *tip = WFGit(repo, @[@"rev-parse", @"--verify", @"--quiet", [def stringByAppendingString:@"^{commit}"]], &st);
    if (st != 0 || !tip.length) return [NSSet set];
    @synchronized (disk) {
        NSDictionary *hit = disk[repo];
        if ([hit[@"tip"] isEqual:tip] && [hit[@"ids"] isKindOfClass:NSArray.class]) return [NSSet setWithArray:hit[@"ids"]];
    }
    NSString *log = WFGitInput(repo, @[@"log", @"-p", @"--no-merges", @"--no-color", @"--no-ext-diff", @"-n", @"400", @"--format=commit %H", def], nil, 60, &st);
    NSMutableArray *ids = [NSMutableArray new];
    if (st == 0 && log.length) {
        NSString *out = WFGitInput(repo, @[@"patch-id", @"--stable"], [[log stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding], 60, &st);
        for (NSString *line in [out componentsSeparatedByString:@"\n"]) { NSString *i = [line componentsSeparatedByString:@" "].firstObject; if (i.length) [ids addObject:i]; }
    }
    @synchronized (disk) {
        disk[repo] = @{@"tip": tip, @"ids": ids};
        [NSFileManager.defaultManager createDirectoryAtPath:WFSupportDir() withIntermediateDirectories:YES attributes:nil error:nil];
        [[NSJSONSerialization dataWithJSONObject:disk options:0 error:nil] writeToFile:PatchPath() atomically:YES];
    }
    return [NSSet setWithArray:ids];
}

/// Per repo: the default branch, stash subjects and the last fetch, read once per scan.
static NSDictionary *RepoFacts(NSString *repo, NSString *common, NSMutableDictionary *memo) {
    @synchronized (memo) { if (memo[repo]) return memo[repo]; }
    NSMutableDictionary *r = [NSMutableDictionary new];
    int st = 0;
    NSString *def = WFGit(repo, @[@"symbolic-ref", @"--quiet", @"--short", @"refs/remotes/origin/HEAD"], &st);
    if (st != 0 || !def.length) {
        def = nil;
        for (NSString *c in @[@"origin/main", @"origin/master", @"main", @"master"]) {
            WFGit(repo, @[@"rev-parse", @"--verify", @"--quiet", [c stringByAppendingString:@"^{commit}"]], &st);
            if (st == 0) { def = c; break; }
        }
    }
    if (def) { r[@"default"] = def; r[@"patchIds"] = DefaultPatchIds(repo, def); }
    NSString *stash = WFGit(repo, @[@"stash", @"list", @"--format=%gs"], NULL);
    r[@"stash"] = stash.length ? [stash componentsSeparatedByString:@"\n"] : @[];
    NSDate *f = [NSFileManager.defaultManager attributesOfItemAtPath:[common stringByAppendingPathComponent:@"FETCH_HEAD"] error:nil].fileModificationDate;
    if (f) r[@"fetched"] = f;
    @synchronized (memo) { memo[repo] = r; }
    return r;
}

/// Squash merge: the branch's whole change, as one patch, equals a recent commit on the default branch.
static BOOL SquashMerged(NSString *dir, NSString *def, NSSet<NSString *> *defaultIds) {
    if (!defaultIds.count) return NO;
    int st = 0;
    NSString *base = WFGit(dir, @[@"merge-base", def, @"HEAD"], &st);
    if (st != 0 || !base.length) return NO;
    NSString *diff = WFGitInput(dir, @[@"diff", @"--no-color", @"--no-ext-diff", base, @"HEAD"], nil, 20, &st);
    if (st != 0 || !diff.length || diff.length > 8 << 20) return NO;
    NSString *mine = WFGitInput(dir, @[@"patch-id", @"--stable"], [[diff stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding], 20, &st);
    NSString *myId = [mine componentsSeparatedByString:@" "].firstObject;
    return myId.length && [defaultIds containsObject:myId];
}

static NSString *GhPath(void) {
    for (NSString *p in @[@"/opt/homebrew/bin/gh", @"/usr/local/bin/gh", @"~/.local/bin/gh".stringByExpandingTildeInPath])
        if ([NSFileManager.defaultManager isExecutableFileAtPath:p]) return p;
    return nil;
}

/// A merged pull request for the branch, through the user's gh login. Network; only when the setting asks for it.
static NSString *MergedPR(NSString *dir, NSString *branch) {
    NSString *gh = GhPath();
    if (!gh || !branch) return nil;
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:gh];
    t.arguments = @[@"pr", @"list", @"--head", branch, @"--state", @"merged", @"--json", @"number,mergedAt", @"--limit", @"1"];
    t.currentDirectoryURL = [NSURL fileURLWithPath:dir];
    NSPipe *out = [NSPipe pipe]; t.standardOutput = out; t.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![t launchAndReturnError:nil]) return nil;
    __block NSData *d = nil;
    dispatch_group_t g = dispatch_group_create();
    dispatch_group_async(g, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ d = [out.fileHandleForReading readDataToEndOfFile]; });
    if (dispatch_group_wait(g, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)) != 0) { [t terminate]; return nil; }
    [t waitUntilExit];
    NSArray *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    NSDictionary *pr = [j isKindOfClass:NSArray.class] ? j.firstObject : nil;
    if (![pr isKindOfClass:NSDictionary.class] || !pr[@"number"]) return nil;
    NSISO8601DateFormatter *f = [NSISO8601DateFormatter new];
    NSDate *at = [pr[@"mergedAt"] isKindOfClass:NSString.class] ? [f dateFromString:pr[@"mergedAt"]] : nil;
    return at ? [NSString stringWithFormat:@"#%@ merged %@ ago", pr[@"number"], WFDuration(-at.timeIntervalSinceNow)] : [NSString stringWithFormat:@"#%@ merged", pr[@"number"]];
}

static BOOL CheckPRs(void) {
    id v = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("workforest.checkPRs"), CFSTR("no.guerrilla.workforest")));
    return [v boolValue];
}

/// The worktree's own index file, whose time moves on every add, commit, checkout or reset.
static NSDate *IndexTime(WFTree *t) {
    NSString *dotgit = [t.path stringByAppendingPathComponent:@".git"];
    BOOL dir = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:dotgit isDirectory:&dir]) return nil;
    NSString *gitdir = dotgit;
    if (!dir) {
        NSString *txt = [NSString stringWithContentsOfFile:dotgit encoding:NSUTF8StringEncoding error:nil];
        NSString *g = [[txt stringByReplacingOccurrencesOfString:@"gitdir:" withString:@""] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!g.length) return nil;
        gitdir = g.isAbsolutePath ? g : [t.path stringByAppendingPathComponent:g];
    }
    return [NSFileManager.defaultManager attributesOfItemAtPath:[gitdir stringByAppendingPathComponent:@"index"] error:nil].fileModificationDate;
}

/// Uncommitted and untracked counts.
static void ReadStatus(WFTree *t) {
    int st = 0;
    NSString *status = WFGitInput(t.path, @[@"status", @"--porcelain=v1", @"--untracked-files=normal", @"--ignore-submodules=dirty"], nil, 30, &st);
    t.dirty = 0; t.untracked = 0;
    if (st == 0) for (NSString *l in [status componentsSeparatedByString:@"\n"]) {
        if (l.length < 3) continue;
        if ([l hasPrefix:@"??"]) t.untracked++; else t.dirty++;
    } else t.dirty = -1;   // unknown counts as dirty: never removed on a guess
}

/// History and merge state, which change only when HEAD or the default branch moves. Cached by HEAD for ten minutes.
static void ReadFacts(WFTree *t, NSMutableDictionary *memo) {
    if (t.prunable || ![NSFileManager.defaultManager fileExistsAtPath:t.path]) { t.prunable = YES; t.factsRead = YES; return; }
    NSString *dir = t.path;
    int st = 0;
    NSDictionary *repo = RepoFacts(t.repo, t.commonDir, memo);
    t.defaultBranch = repo[@"default"]; t.fetched = repo[@"fetched"];
    t.created = [NSFileManager.defaultManager attributesOfItemAtPath:[dir stringByAppendingPathComponent:@".git"] error:nil].fileCreationDate;

    NSString *last = WFGit(dir, @[@"log", @"-1", @"--format=%ct%x1f%an%x1f%s", @"HEAD"], &st);
    NSArray *p = [last componentsSeparatedByString:@"\x1f"];
    if (st == 0 && p.count == 3) {
        t.lastCommit = [NSDate dateWithTimeIntervalSince1970:[p[0] doubleValue]];
        t.lastAuthor = p[1]; t.lastSubject = p[2];
    }
    if (t.branch) {
        NSString *track = WFGit(dir, @[@"for-each-ref", @"--format=%(upstream:short)%1f%(upstream:track)", [@"refs/heads/" stringByAppendingString:t.branch]], NULL);
        NSArray *u = [track componentsSeparatedByString:@"\x1f"];
        NSString *name = u.count > 0 ? u[0] : @"", *tr = u.count > 1 ? u[1] : @"";
        if (!name.length) t.upstream = @"none";
        else if ([tr containsString:@"gone"]) t.upstream = @"gone";
        else {
            t.upstream = name;
            NSScanner *s;
            NSRange a = [tr rangeOfString:@"ahead "], b = [tr rangeOfString:@"behind "];
            NSInteger n = 0;
            if (a.location != NSNotFound) { s = [NSScanner scannerWithString:[tr substringFromIndex:NSMaxRange(a)]]; [s scanInteger:&n]; t.ahead = n; }
            if (b.location != NSNotFound) { s = [NSScanner scannerWithString:[tr substringFromIndex:NSMaxRange(b)]]; [s scanInteger:&n]; t.behind = n; }
        }
        NSInteger stashes = 0;
        for (NSString *s in repo[@"stash"]) if ([s hasPrefix:[NSString stringWithFormat:@"WIP on %@:", t.branch]] || [s hasPrefix:[NSString stringWithFormat:@"On %@:", t.branch]]) stashes++;
        t.stashes = stashes;
    }
    NSString *def = t.defaultBranch;
    t.merged = nil; t.notInDefault = 0;
    if (def) {
        NSString *n = WFGit(dir, @[@"rev-list", @"--count", [def stringByAppendingString:@"..HEAD"]], &st);
        t.notInDefault = st == 0 ? n.integerValue : -1;
        t.unpushed = [WFGit(dir, @[@"rev-list", @"--count", @"HEAD", @"--not", def, @"--remotes"], &st) integerValue];
        if (st != 0) t.unpushed = -1;
        if (!t.isMain && t.notInDefault == 0) t.merged = @"ancestor";
        else if (!t.isMain && t.notInDefault > 0) {
            WFGit(dir, @[@"diff", @"--quiet", def, @"HEAD", @"--"], &st);
            if (st == 0) t.merged = @"tree";
            if (!t.merged) {
                NSString *cherry = WFGit(dir, @[@"cherry", def, @"HEAD"], &st);
                if (st == 0 && cherry.length && ![cherry containsString:@"+ "] && ![cherry hasPrefix:@"+"]) t.merged = @"patch";
            }
            if (!t.merged && SquashMerged(dir, def, repo[@"patchIds"])) t.merged = @"squash";
        }
    } else {
        t.unpushed = [WFGit(dir, @[@"rev-list", @"--count", @"HEAD", @"--not", @"--remotes"], &st) integerValue];
        if (st != 0) t.unpushed = -1;
    }
    if (t.detached) {
        t.orphanCommits = [WFGit(dir, @[@"rev-list", @"--count", @"HEAD", @"--not", @"--branches", @"--remotes", @"--tags"], &st) integerValue];
        if (st != 0) t.orphanCommits = -1;
    }
    if (!t.isMain && !t.merged && t.branch && CheckPRs()) { t.pr = MergedPR(dir, t.branch); if (t.pr) t.merged = @"pr"; }
    t.factsRead = YES;
}

#pragma mark - Disk

/// One walk: allocated size, the part in cache folders, the file count and the newest file outside .git and caches.
/// quick skips the caches, for the newest change alone: cheap enough for every scan. Folder times count, so an
/// added or deleted file shows too.
/// Nested worktrees and repos are skipped, so a main checkout does not count the worktrees inside it.
static NSDictionary *WalkDisk(NSString *root, NSSet *caches, BOOL quick) {
    char *paths[] = {(char *)root.fileSystemRepresentation, NULL};
    FTS *fts = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, NULL);
    if (!fts) return nil;
    uint64_t disk = 0, cache = 0; NSInteger files = 0; double newest = 0;
    short cacheLevel = -1;
    FTSENT *e;
    while ((e = fts_read(fts))) {
        if (e->fts_info == FTS_D) {
            if (cacheLevel < 0 && e->fts_statp) {   // a folder's time moves when a file in it is added, removed or renamed
                double m = e->fts_statp->st_mtimespec.tv_sec;
                if (m > newest && m <= NSDate.date.timeIntervalSince1970 + 60) newest = m;
            }
            if (e->fts_level > 0) {
                NSString *n = @(e->fts_name);
                if ([n isEqualToString:@".git"]) { fts_set(fts, e, FTS_SKIP); continue; }
                char git[PATH_MAX];
                snprintf(git, sizeof git, "%s/.git", e->fts_path);
                if (cacheLevel < 0 && access(git, F_OK) == 0) { fts_set(fts, e, FTS_SKIP); continue; }   // another worktree or repo
                if (cacheLevel < 0 && [caches containsObject:n]) { if (quick) { fts_set(fts, e, FTS_SKIP); continue; } cacheLevel = e->fts_level; }
            }
            continue;
        }
        if (e->fts_info == FTS_DP) { if (e->fts_level == cacheLevel) cacheLevel = -1; continue; }
        if (!e->fts_statp || e->fts_info == FTS_NS || e->fts_info == FTS_ERR || e->fts_info == FTS_DNR) continue;
        uint64_t b = (uint64_t)e->fts_statp->st_blocks * 512;
        disk += b; files++;
        if (cacheLevel >= 0) cache += b;
        else if (e->fts_info == FTS_F || e->fts_info == FTS_SL) {
            double m = e->fts_statp->st_mtimespec.tv_sec;
            if (m > newest && m <= NSDate.date.timeIntervalSince1970 + 60) newest = m;
        }
    }
    fts_close(fts);
    return @{@"disk": @(disk), @"cache": @(cache), @"files": @(files), @"touched": @(newest), @"at": @(NSDate.date.timeIntervalSince1970)};
}

static NSString *SizesPath(void) { return [WFSupportDir() stringByAppendingPathComponent:@"sizes.json"]; }
static NSString *FactsPath(void) { return [WFSupportDir() stringByAppendingPathComponent:@"facts.json"]; }

static id Num(NSDate *d) { return d ? @(d.timeIntervalSince1970) : NSNull.null; }
static NSDate *Date(id n) { return [n isKindOfClass:NSNumber.class] ? [NSDate dateWithTimeIntervalSince1970:[n doubleValue]] : nil; }
static NSString *Str(id s) { return [s isKindOfClass:NSString.class] ? s : nil; }

/// The git facts of a worktree, as kept in facts.json between runs.
static NSDictionary *FactsDict(WFTree *t) {
    return @{@"head": t.head ?: @"", @"at": @(NSDate.date.timeIntervalSince1970), @"lastCommit": Num(t.lastCommit), @"lastSubject": t.lastSubject ?: NSNull.null,
             @"lastAuthor": t.lastAuthor ?: NSNull.null, @"stashes": @(t.stashes),
             @"unpushed": @(t.unpushed), @"orphanCommits": @(t.orphanCommits), @"notInDefault": @(t.notInDefault), @"merged": t.merged ?: NSNull.null,
             @"pr": t.pr ?: NSNull.null, @"upstream": t.upstream ?: NSNull.null, @"ahead": @(t.ahead), @"behind": @(t.behind),
             @"defaultBranch": t.defaultBranch ?: NSNull.null, @"fetched": Num(t.fetched), @"created": Num(t.created)};
}

static void ApplyFacts(WFTree *t, NSDictionary *f) {
    t.lastCommit = Date(f[@"lastCommit"]); t.lastSubject = Str(f[@"lastSubject"]); t.lastAuthor = Str(f[@"lastAuthor"]);
    t.stashes = [f[@"stashes"] integerValue];
    t.unpushed = [f[@"unpushed"] integerValue]; t.orphanCommits = [f[@"orphanCommits"] integerValue]; t.notInDefault = [f[@"notInDefault"] integerValue];
    t.merged = Str(f[@"merged"]); t.pr = Str(f[@"pr"]); t.upstream = Str(f[@"upstream"]); t.ahead = [f[@"ahead"] integerValue]; t.behind = [f[@"behind"] integerValue];
    t.defaultBranch = Str(f[@"defaultBranch"]); t.fetched = Date(f[@"fetched"]); t.created = Date(f[@"created"]); t.factsRead = YES;
}

#pragma mark - Processes

static NSString *ProcName(pid_t pid) {
    char name[2 * MAXCOMLEN + 1] = {0};
    return proc_name(pid, name, sizeof name) > 0 ? @(name) : @"?";
}

/// Every process of this user whose working directory is inside a worktree, assigned to the deepest one.
static NSDictionary<NSString *, NSArray *> *ProcessesIn(NSArray<WFTree *> *trees) {
    NSArray *sorted = [trees sortedArrayUsingComparator:^NSComparisonResult(WFTree *a, WFTree *b) { return a.path.length > b.path.length ? NSOrderedAscending : NSOrderedDescending; }];
    NSMutableDictionary *out = [NSMutableDictionary new];
    int n = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0) / sizeof(pid_t) + 64;
    pid_t *pids = calloc(n, sizeof(pid_t));
    n = proc_listpids(PROC_ALL_PIDS, 0, pids, n * sizeof(pid_t)) / sizeof(pid_t);
    uid_t me = getuid(); pid_t self = getpid();
    for (int i = 0; i < n; i++) {
        pid_t pid = pids[i];
        if (pid <= 1 || pid == self) continue;
        struct proc_bsdinfo bi;
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, sizeof bi) != sizeof bi || bi.pbi_uid != me || bi.pbi_ppid == self) continue;
        struct proc_vnodepathinfo v;
        if (proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &v, sizeof v) != sizeof v) continue;
        NSString *cwd = @(v.pvi_cdir.vip_path);
        if (cwd.length < 2) continue;
        for (WFTree *t in sorted) {
            if ([cwd isEqualToString:t.path] || [cwd hasPrefix:[t.path stringByAppendingString:@"/"]]) {
                NSString *name = ProcName(pid);
                if ([name isEqualToString:@"git"]) break;   // our own scans and the user's short git commands
                NSMutableArray *l = out[t.path] ?: [NSMutableArray new]; out[t.path] = l;
                [l addObject:[NSString stringWithFormat:@"%@ (pid %d)", name, pid]];
                break;
            }
        }
    }
    free(pids);
    return out;
}

/// LocoHost's localhosts, when it is installed: port, framework and its state, by working directory.
static NSArray<NSDictionary *> *LocoHosts(void) {
    NSString *path = NSProcessInfo.processInfo.environment[@"WORKFOREST_LOCOHOST"] ?: [@"~/.local/bin/locohost" stringByExpandingTildeInPath];
    if (![NSFileManager.defaultManager isExecutableFileAtPath:path]) return @[];
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:path]; t.arguments = @[@"list", @"--json"];
    NSPipe *out = [NSPipe pipe]; t.standardOutput = out; t.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![t launchAndReturnError:nil]) return @[];
    __block NSData *d = nil;
    dispatch_group_t g = dispatch_group_create();
    dispatch_group_async(g, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ d = [out.fileHandleForReading readDataToEndOfFile]; });
    if (dispatch_group_wait(g, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)) != 0) { [t terminate]; return @[]; }
    NSDictionary *j = d.length ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    NSMutableArray *hosts = [NSMutableArray new];
    for (NSDictionary *h in [j isKindOfClass:NSDictionary.class] ? j[@"hosts"] : nil) {
        if (![h isKindOfClass:NSDictionary.class] || ![h[@"cwd"] isKindOfClass:NSString.class]) continue;
        NSArray *ports = h[@"ports"];
        [hosts addObject:@{@"cwd": h[@"cwd"], @"port": [ports isKindOfClass:NSArray.class] ? ports.firstObject ?: @0 : @0,
                           @"framework": h[@"framework"] ?: @"server", @"state": h[@"state"] ?: @"?"}];
    }
    return hosts;
}

#pragma mark - Agent sessions

static NSDate *ISODate(NSString *s) {
    static NSISO8601DateFormatter *f, *g; static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [NSISO8601DateFormatter new]; f.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        g = [NSISO8601DateFormatter new];
    });
    return s ? ([f dateFromString:s] ?: [g dateFromString:s]) : nil;
}

static NSString *Match(NSString *s, NSString *pattern) {
    if (!s) return nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionAnchorsMatchLines error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    return m && [m rangeAtIndex:1].location != NSNotFound ? [s substringWithRange:[m rangeAtIndex:1]] : nil;
}

static NSString *HeadText(NSString *path, NSUInteger max) {
    NSFileHandle *f = [NSFileHandle fileHandleForReadingAtPath:path];
    NSData *d = [f readDataUpToLength:max error:nil];
    [f closeFile];
    return d ? ([[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding]) : nil;
}

/// The first thing the user typed in a session log, skipping injected context.
static NSString *FirstPrompt(NSString *head) {
    for (NSString *line in [head componentsSeparatedByString:@"\n"]) {
        if (![line containsString:@"\"user\""]) continue;
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if (![j isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *m = [j[@"message"] isKindOfClass:NSDictionary.class] ? j[@"message"] : [j[@"payload"] isKindOfClass:NSDictionary.class] ? j[@"payload"] : nil;
        if (![m[@"role"] isEqual:@"user"]) continue;
        NSMutableArray *texts = [NSMutableArray new];
        if ([m[@"content"] isKindOfClass:NSString.class]) [texts addObject:m[@"content"]];
        else if ([m[@"content"] isKindOfClass:NSArray.class])
            for (NSDictionary *c in m[@"content"])
                if ([c isKindOfClass:NSDictionary.class] && [@[@"text", @"input_text"] containsObject:c[@"type"] ?: @""] && [c[@"text"] isKindOfClass:NSString.class]) [texts addObject:c[@"text"]];
        for (NSString *t in texts) {
            NSString *x = [t stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (!x.length || [x hasPrefix:@"<"] || [x hasPrefix:@"Caveat:"] || [x containsString:@"AGENTS.md instructions"] || [x hasPrefix:@"# AGENTS.md"]) continue;
            return x;
        }
    }
    return nil;
}

static NSString *ClaudeTitle(NSString *file) {
    NSData *all = [NSData dataWithContentsOfFile:file options:NSDataReadingMappedIfSafe error:nil];
    NSUInteger from = all.length > 524288 ? all.length - 524288 : 0;
    NSString *tail = [[NSString alloc] initWithData:[all subdataWithRange:NSMakeRange(from, all.length - from)] encoding:NSUTF8StringEncoding];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\"aiTitle\":\\s*\"((?:[^\"\\\\]|\\\\.)*)\"" options:0 error:nil];
    NSTextCheckingResult *m = tail ? [re matchesInString:tail options:0 range:NSMakeRange(0, tail.length)].lastObject : nil;
    return m ? [tail substringWithRange:[m rangeAtIndex:1]] : nil;
}

static NSArray<NSString *> *Logs(NSString *dir, NSString *prefix) {
    NSMutableArray *l = [NSMutableArray new];
    for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil])
        if ([f hasSuffix:@".jsonl"] && (!prefix || [f hasPrefix:prefix])) [l addObject:[dir stringByAppendingPathComponent:f]];
    return l;
}

static NSDate *MTime(NSString *f) { return [NSFileManager.defaultManager attributesOfItemAtPath:f error:nil].fileModificationDate; }

/// The timestamp of the JSON line around a byte offset.
static NSDate *LineTime(NSData *all, NSUInteger at) {
    NSData *nl = [NSData dataWithBytes:"\n" length:1];
    NSRange ls = [all rangeOfData:nl options:NSDataSearchBackwards range:NSMakeRange(0, at)];
    NSRange le = [all rangeOfData:nl options:0 range:NSMakeRange(at, all.length - at)];
    NSUInteger from = ls.location == NSNotFound ? 0 : ls.location + 1, to = le.location == NSNotFound ? all.length : le.location;
    NSUInteger n = to - from;
    const char *b = all.bytes;
    NSString *head = [[NSString alloc] initWithBytes:b + from length:MIN(n, 600) encoding:NSUTF8StringEncoding];
    NSString *tail = n > 600 ? [[NSString alloc] initWithBytes:b + to - 600 length:600 encoding:NSUTF8StringEncoding] : nil;
    return ISODate(Match(head, @"\"timestamp\":\\s*\"([^\"]+)\"") ?: Match(tail, @"\"timestamp\":\\s*\"([^\"]+)\""));
}

/// A log line that carries what a tool printed, such as a listing of every worktree. Naming a folder there is not working in it.
static BOOL ToolOutput(NSData *all, NSUInteger at) {
    NSData *nl = [NSData dataWithBytes:"\n" length:1];
    NSRange ls = [all rangeOfData:nl options:NSDataSearchBackwards range:NSMakeRange(0, at)];
    NSUInteger from = ls.location == NSNotFound ? 0 : ls.location + 1;
    NSRange le = [all rangeOfData:nl options:0 range:NSMakeRange(at, all.length - at)];
    NSRange line = NSMakeRange(from, (le.location == NSNotFound ? all.length : le.location) - from);
    for (NSString *k in @[@"\"tool_result\"", @"\"toolUseResult\"", @"\"function_call_output\"", @"\"exec_command_end\"", @"\"toolResult\""])
        if ([all rangeOfData:[k dataUsingEncoding:NSUTF8StringEncoding] options:0 range:line].location != NSNotFound) return YES;
    return NO;
}

/// Where in the tail of a session log each worktree is last named as a whole path, as the time of that line.
/// Only what the user wrote and the commands an agent ran count, not what tools printed.
/// One pass: every path under the home folder in the text is looked up, component by component, in the set of worktree paths.
static void Mentions(NSString *file, NSSet<NSString *> *paths, NSString *agent, NSMutableDictionary *best) {
    NSData *all = [NSData dataWithContentsOfFile:file options:NSDataReadingMappedIfSafe error:nil];
    if (!all.length) return;
    NSUInteger from = all.length > kTailBytes ? all.length - kTailBytes : 0;
    NSData *home = [[NSHomeDirectory() stringByAppendingString:@"/"] dataUsingEncoding:NSUTF8StringEncoding];
    const char *b = all.bytes;
    NSMutableDictionary<NSString *, NSNumber *> *last = [NSMutableDictionary new];
    NSRange r = NSMakeRange(from, all.length - from);
    while (r.length) {
        NSRange m = [all rangeOfData:home options:0 range:r];
        if (m.location == NSNotFound) break;
        NSUInteger end = m.location;
        while (end < all.length && end - m.location < 1024) {
            char c = b[end];
            if (c == '"' || c == ' ' || c == '\\' || c == '\n' || c == '\'' || c == '`' || c == ')' || c == ',' || c == ':') break;
            end++;
        }
        NSString *s = [[NSString alloc] initWithBytes:b + m.location length:end - m.location encoding:NSUTF8StringEncoding];
        for (; s.length > home.length; s = s.stringByDeletingLastPathComponent)
            if ([paths containsObject:s]) { if (!ToolOutput(all, m.location)) last[s] = @(m.location); break; }
        r = NSMakeRange(end, all.length - end);
    }
    for (NSString *p in last) {
        NSDate *t = LineTime(all, last[p].unsignedIntegerValue) ?: MTime(file);
        NSDictionary *old = best[p];
        if (!old || [t compare:old[@"at"]] == NSOrderedDescending)
            best[p] = @{@"agent": agent, @"at": t, @"file": file, @"match": @"a session named this folder"};
    }
}

static NSString *ClaudeEnc(NSString *d) { return [[d stringByReplacingOccurrencesOfString:@"/" withString:@"-"] stringByReplacingOccurrencesOfString:@"." withString:@"-"]; }
static NSString *PiEnc(NSString *d) { return [NSString stringWithFormat:@"--%@--", [[d substringFromIndex:1] stringByReplacingOccurrencesOfString:@"/" withString:@"-"]]; }

/// For every worktree, the most recent agent session that ran in it or named it: Claude Code, Codex and pi logs on this Mac.
static NSDictionary<NSString *, NSDictionary *> *Sessions(NSArray<WFTree *> *trees) {
    NSString *home = NSHomeDirectory();
    NSDictionary *env = NSProcessInfo.processInfo.environment;
    NSString *claude = [env[@"CLAUDE_CONFIG_DIR"] ?: [home stringByAppendingPathComponent:@".claude"] stringByAppendingPathComponent:@"projects"];
    NSString *codex = env[@"CODEX_HOME"] ?: [home stringByAppendingPathComponent:@".codex"];
    NSString *pi = [home stringByAppendingPathComponent:@".pi/agent/sessions"];
    NSMutableSet *paths = [NSMutableSet new];
    for (WFTree *t in trees) [paths addObject:t.path];
    NSMutableDictionary *exact = [NSMutableDictionary new], *named = [NSMutableDictionary new];
    NSDate *window = [NSDate dateWithTimeIntervalSinceNow:-kMentionWindow];

    void (^consider)(NSString *, NSString *, NSString *) = ^(NSString *path, NSString *agent, NSString *file) {
        NSDate *m = MTime(file);
        if (!m) return;
        NSDictionary *old = exact[path];
        if (!old || [m compare:old[@"at"]] == NSOrderedDescending) exact[path] = @{@"agent": agent, @"at": m, @"file": file, @"match": @"a session ran in this folder"};
    };
    NSMutableOrderedSet *parents = [NSMutableOrderedSet new];
    for (WFTree *t in trees) {
        for (NSString *f in Logs([claude stringByAppendingPathComponent:ClaudeEnc(t.path)], nil)) consider(t.path, @"Claude Code", f);
        for (NSString *f in Logs([pi stringByAppendingPathComponent:PiEnc(t.path)], nil)) consider(t.path, @"pi", f);
        for (NSString *d = t.path.stringByDeletingLastPathComponent; d.length >= home.length && [d hasPrefix:home]; d = d.stringByDeletingLastPathComponent) [parents addObject:d];
    }
    // Sessions in parent folders, where agents are often started, count when they named the worktree.
    for (NSString *d in parents) {
        for (NSString *f in Logs([claude stringByAppendingPathComponent:ClaudeEnc(d)], nil)) if ([MTime(f) compare:window] == NSOrderedDescending) Mentions(f, paths, @"Claude Code", named);
        for (NSString *f in Logs([pi stringByAppendingPathComponent:PiEnc(d)], nil)) if ([MTime(f) compare:window] == NSOrderedDescending) Mentions(f, paths, @"pi", named);
    }
    // Codex keeps logs by date; the first line holds the working directory.
    NSDateFormatter *day = [NSDateFormatter new]; day.dateFormat = @"yyyy/MM/dd"; day.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    for (NSDate *d = [NSDate dateWithTimeIntervalSinceNow:-30 * 86400]; [d timeIntervalSinceNow] < 86400; d = [d dateByAddingTimeInterval:86400])
        for (NSString *f in Logs([[codex stringByAppendingPathComponent:@"sessions"] stringByAppendingPathComponent:[day stringFromDate:d]], @"rollout-")) {
            NSString *cwd = [Match(HeadText(f, 16384), @"\"cwd\":\\s*\"([^\"]+)\"") stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
            if (cwd && [paths containsObject:cwd]) consider(cwd, @"Codex", f);
            else if ([MTime(f) compare:window] == NSOrderedDescending) Mentions(f, paths, @"Codex", named);
        }
    NSMutableDictionary *titles = [NSMutableDictionary new];
    NSString *index = [NSString stringWithContentsOfFile:[codex stringByAppendingPathComponent:@"session_index.jsonl"] encoding:NSUTF8StringEncoding error:nil];
    for (NSString *line in [index componentsSeparatedByString:@"\n"]) {
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] ?: NSData.data options:0 error:nil];
        if ([j isKindOfClass:NSDictionary.class] && [j[@"id"] isKindOfClass:NSString.class] && [j[@"thread_name"] isKindOfClass:NSString.class]) titles[j[@"id"]] = j[@"thread_name"];
    }

    NSMutableDictionary *out = [NSMutableDictionary new];
    for (NSString *p in paths) {
        NSDictionary *e = exact[p], *n = named[p];
        NSDictionary *best = e && n ? ([n[@"at"] compare:e[@"at"]] == NSOrderedDescending ? n : e) : e ?: n;
        if (!best) continue;
        NSMutableDictionary *s = [@{@"agent": best[@"agent"], @"match": best[@"match"],
                                    @"last_active_minutes_ago": @((long)round(-[best[@"at"] timeIntervalSinceNow] / 60)),
                                    @"file": WFTilde(best[@"file"])} mutableCopy];
        // Title and first prompt come from the session that ran in the folder, the one that says what the work was.
        NSString *f = e[@"file"];
        if (f) {
            NSString *head = HeadText(f, 256 * 1024);
            NSString *t = [e[@"agent"] isEqual:@"Claude Code"] ? ClaudeTitle(f) : [e[@"agent"] isEqual:@"Codex"] ? titles[Match(head, @"\"id\":\\s*\"([^\"]+)\"") ?: @""] : nil;
            if (WFClip(t, 200)) s[@"title"] = WFClip(t, 200);
            if (WFClip(FirstPrompt(head), 200)) s[@"first_prompt"] = WFClip(FirstPrompt(head), 200);
            NSDate *started = ISODate(Match(head, @"\"timestamp\":\\s*\"([^\"]+)\""));
            if (started) s[@"started_minutes_ago"] = @((long)round(-started.timeIntervalSinceNow / 60));
        }
        out[p] = s;
    }
    return out;
}

#pragma mark - Scanner

@implementation WFScanner {
    NSArray<WFTree *> *_trees;
    NSMutableDictionary *_facts;                         // path → facts as in facts.json, with head and time
    BOOL _noCache;                                       // read everything again: the check right before a removal
    NSMutableDictionary *_sizes;                         // path → walk result, persisted in sizes.json
    BOOL _scanning;
    NSDate *_scannedAt;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSData *f = [NSData dataWithContentsOfFile:FactsPath()];
        id fj = f ? [NSJSONSerialization JSONObjectWithData:f options:NSJSONReadingMutableContainers error:nil] : nil;
        _facts = [fj isKindOfClass:NSMutableDictionary.class] ? fj : [NSMutableDictionary new];
        NSData *d = [NSData dataWithContentsOfFile:SizesPath()];
        id j = d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil] : nil;
        _sizes = [j isKindOfClass:NSMutableDictionary.class] ? j : [NSMutableDictionary new];
    }
    return self;
}

- (NSArray<WFTree *> *)trees { @synchronized (self) { return _trees ?: @[]; } }
- (NSDate *)scannedAt { @synchronized (self) { return _scannedAt; } }
- (BOOL)scanning { @synchronized (self) { return _scanning; } }

- (WFTree *)treeAt:(NSString *)path {
    path = WFAbsolute(path);
    WFTree *best = nil;
    for (WFTree *t in self.trees)
        if (([path isEqualToString:t.path] || [path hasPrefix:[t.path stringByAppendingString:@"/"]]) && t.path.length > best.path.length) best = t;
    return best;
}

/// Every worktree under the roots, main checkouts included, ordered by repo with the main one first.
static NSArray<WFTree *> *Discover(void) {
    WFRules *rules = WFRules.shared;
    NSMutableSet *mains = [NSMutableSet new], *linked = [NSMutableSet new];
    for (NSString *root in rules.roots) Walk(root, rules.depth, YES, rules.caches, mains, linked);
    NSMutableSet *repos = [mains mutableCopy];
    for (NSString *w in linked) {   // a linked worktree's .git file names its repo: gitdir: <repo>/.git/worktrees/<name>
        NSString *txt = [NSString stringWithContentsOfFile:[w stringByAppendingPathComponent:@".git"] encoding:NSUTF8StringEncoding error:nil];
        NSString *g = [[txt stringByReplacingOccurrencesOfString:@"gitdir:" withString:@""] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSRange r = [g rangeOfString:@"/.git/worktrees/" options:NSBackwardsSearch];
        if (r.location != NSNotFound) [repos addObject:WFAbsolute([g substringToIndex:r.location])];
        else {
            NSString *common = WFGit(w, @[@"rev-parse", @"--path-format=absolute", @"--git-common-dir"], NULL);
            if (common.length) [repos addObject:common.stringByDeletingLastPathComponent];
        }
    }
    NSArray *sorted = [repos.allObjects sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    NSMutableArray *lists = [NSMutableArray new];
    for (NSUInteger i = 0; i < sorted.count; i++) [lists addObject:@[]];
    dispatch_apply(sorted.count, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(size_t i) {
        NSArray *l = Worktrees(sorted[i]);
        @synchronized (lists) { lists[i] = l; }
    });
    NSMutableDictionary<NSString *, WFTree *> *all = [NSMutableDictionary new];
    NSMutableArray *order = [NSMutableArray new];
    for (NSArray *l in lists)
        for (WFTree *t in l) if (!all[t.path] && ![rules ignoresPath:t.path]) { all[t.path] = t; [order addObject:t]; }
    return order;
}

/// Reads facts, sizes, processes, sessions and servers for these trees. full is a complete scan, which also
/// forgets the sizes of worktrees that are gone.
- (void)readAll:(NSArray<WFTree *> *)trees full:(BOOL)full {
    NSMutableDictionary *memo = [NSMutableDictionary new];
    NSSet *caches = WFRules.shared.caches;
    NSDate *start = NSDate.date;
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_semaphore_t gate = dispatch_semaphore_create(6);   // six worktrees at a time
    dispatch_group_t g = dispatch_group_create();
    for (WFTree *t in trees) {
        NSDictionary *old;
        @synchronized (self) { old = _noCache ? nil : _facts[t.path]; }
        BOOL fresh = [old[@"head"] isEqual:t.head] && NSDate.date.timeIntervalSince1970 - [old[@"at"] doubleValue] < kFactsFresh;
        dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER);
        dispatch_group_async(g, q, ^{
            if (fresh) ApplyFacts(t, old);
            else {
                ReadFacts(t, memo);
                if (!t.prunable) @synchronized (self) { self->_facts[t.path] = FactsDict(t); }
            }
            NSDictionary *s;
            @synchronized (self) { s = self->_sizes[t.path]; }
            BOOL stale = !s || self->_noCache || NSDate.date.timeIntervalSince1970 - [s[@"at"] doubleValue] > kSizeFresh;
            NSDictionary *q = nil;
            if (!t.prunable) {
                if (stale) { s = WalkDisk(t.path, caches, NO); q = s; if (s) @synchronized (self) { self->_sizes[t.path] = s; } }
                else if (NSDate.date.timeIntervalSince1970 - [s[@"qat"] ?: s[@"at"] doubleValue] < kQuickFresh) q = s;
                else {
                    q = WalkDisk(t.path, caches, YES);
                    NSMutableDictionary *m = [s mutableCopy];
                    m[@"touched"] = q[@"touched"] ?: @0; m[@"qat"] = q[@"at"] ?: @0;
                    s = m;
                    @synchronized (self) { self->_sizes[t.path] = m; }
                }
            }
            if (s) {
                t.diskBytes = [s[@"disk"] unsignedLongLongValue]; t.cacheBytes = [s[@"cache"] unsignedLongLongValue]; t.files = [s[@"files"] integerValue];
                t.sizedAt = [NSDate dateWithTimeIntervalSince1970:[s[@"at"] doubleValue]];
            }
            double touched = [(q ?: s)[@"touched"] doubleValue];
            t.touched = touched > 0 ? [NSDate dateWithTimeIntervalSince1970:touched] : nil;
            // git status reads every file, because it may not refresh the index. Its answer can only change when HEAD,
            // the index or a file or folder outside the caches changes, so it is kept by those three.
            if (!t.prunable) {
                NSString *sig = [NSString stringWithFormat:@"%@ %.0f %.0f", t.head, IndexTime(t).timeIntervalSince1970, touched];
                NSDictionary *c = self->_noCache ? nil : old[@"status"];
                if ([c[@"sig"] isEqual:sig] && t.factsRead) { t.dirty = [c[@"dirty"] integerValue]; t.untracked = [c[@"untracked"] integerValue]; }
                else {
                    ReadStatus(t);
                    @synchronized (self) {
                        NSMutableDictionary *f = [self->_facts[t.path] mutableCopy];
                        if (f && t.dirty >= 0) { f[@"status"] = @{@"sig": sig, @"dirty": @(t.dirty), @"untracked": @(t.untracked)}; self->_facts[t.path] = f; }
                    }
                }
            }
            dispatch_semaphore_signal(gate);
        });
    }
    dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
    BOOL debug = NSProcessInfo.processInfo.environment[@"WORKFOREST_DEBUG"].length > 0;
    if (debug) fprintf(stderr, "git and disk %.1fs\n", -start.timeIntervalSinceNow);
    NSDictionary *procs = ProcessesIn(trees);
    if (debug) fprintf(stderr, "processes %.1fs\n", -start.timeIntervalSinceNow);
    NSDictionary *sessions = Sessions(trees);
    if (debug) fprintf(stderr, "sessions %.1fs\n", -start.timeIntervalSinceNow);
    NSArray *hosts = LocoHosts();
    if (debug) fprintf(stderr, "locohost %.1fs\n", -start.timeIntervalSinceNow);
    for (WFTree *t in trees) {
        t.processes = procs[t.path] ?: @[];
        t.session = sessions[t.path];
        NSMutableArray *srv = [NSMutableArray new];
        for (NSDictionary *h in hosts) {
            NSString *cwd = h[@"cwd"];
            if ([cwd isEqualToString:t.path] || [cwd hasPrefix:[t.path stringByAppendingString:@"/"]]) [srv addObject:@{@"port": h[@"port"], @"framework": h[@"framework"], @"state": h[@"state"]}];
        }
        t.servers = srv;
        t.isProtected = [WFRules.shared protectsPath:t.path branch:t.branch];
    }
    if (full) @synchronized (self) {
        [NSFileManager.defaultManager createDirectoryAtPath:WFSupportDir() withIntermediateDirectories:YES attributes:nil error:nil];
        NSSet *live = [NSSet setWithArray:[trees valueForKey:@"path"]];
        for (NSString *k in _sizes.allKeys) if (![live containsObject:k]) [_sizes removeObjectForKey:k];
        for (NSString *k in _facts.allKeys) if (![live containsObject:k]) [_facts removeObjectForKey:k];
        [[NSJSONSerialization dataWithJSONObject:_sizes options:0 error:nil] writeToFile:SizesPath() atomically:YES];
        [[NSJSONSerialization dataWithJSONObject:_facts options:0 error:nil] writeToFile:FactsPath() atomically:YES];
    }
}

- (void)scan:(BOOL)wait done:(void (^)(void))done {
    @synchronized (self) { if (_scanning) { if (done) dispatch_async(dispatch_get_main_queue(), done); return; } _scanning = YES; }
    void (^work)(void) = ^{
        [WFRules.shared reload];
        NSDate *t0 = NSDate.date;
        NSArray *trees = Discover();
        if (NSProcessInfo.processInfo.environment[@"WORKFOREST_DEBUG"].length) fprintf(stderr, "discover %.1fs\n", -t0.timeIntervalSinceNow);
        [self readAll:trees full:YES];
        @synchronized (self) { self->_trees = trees; self->_scannedAt = NSDate.date; self->_scanning = NO; }
    };
    if (wait) { work(); if (done) done(); return; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        work();
        if (done) dispatch_async(dispatch_get_main_queue(), done);
    });
}

+ (WFTree *)fresh:(NSString *)path {
    path = WFAbsolute(path);
    NSString *common = WFGit(path, @[@"rev-parse", @"--path-format=absolute", @"--git-common-dir"], NULL);
    if (!common.length) return nil;
    WFTree *found = nil;
    for (WFTree *t in Worktrees(common.stringByDeletingLastPathComponent)) if ([t.path isEqualToString:path]) found = t;
    if (!found) return nil;
    WFScanner *s = [WFScanner new];
    s->_noCache = YES;   // git, the walk, sessions and processes all read again: the newest file decides
    [s readAll:@[found] full:NO];
    return found;
}

@end
