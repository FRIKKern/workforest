// WorkForest: every git worktree on your Mac, what it was for, whether it is merged, and what it costs on disk.
// Menu bar app + CLI. Haiku or Luna on your own subscription reviews them on a schedule and when something changes,
// and the mode decides what happens next: Idle only reports, Proactive removes merged worktrees left alone for a
// week, and Eager removes every quiet worktree that cannot show evidence that someone still wants it.
#import <Cocoa/Cocoa.h>
#import <ServiceManagement/ServiceManagement.h>
#import <UserNotifications/UserNotifications.h>
#import "Common.h"
#import "Rules.h"
#import "Trees.h"
#import "Review.h"
#import "Forest.h"

static NSString *const kReviewMinKey = @"workforest.reviewMinutes";   // default 120, 0 off
static NSString *const kModelKey     = @"workforest.model";           // default auto: Haiku, then Luna
static NSString *const kAskKey       = @"workforest.askBeforeRemoving";// default YES
static NSString *const kFetchKey     = @"workforest.fetch";           // default NO: git fetch --prune before a review
static NSString *const kPRKey        = @"workforest.checkPRs";        // default NO: ask gh for merged pull requests
static const NSTimeInterval kEventGap = 30 * 60;                      // reviews woken by events are at least this far apart
static const NSTimeInterval kScanEvery = 5 * 60;

static NSString *Plural(NSInteger n, NSString *word) { return [NSString stringWithFormat:@"%ld %@%@", (long)n, word, n == 1 ? @"" : [word hasSuffix:@"s"] ? @"es" : @"s"]; }
static NSString *Tokens(NSInteger t) { return t >= 1000 ? [NSString stringWithFormat:@"%.1fk tokens", t / 1000.0] : [NSString stringWithFormat:@"%ld tokens", (long)t]; }
static NSString *Cut(NSString *s, NSUInteger n) { return s.length > n ? [[s substringToIndex:n - 1] stringByAppendingString:@"…"] : (s ?: @""); }

static NSArray<WFTree *> *Linked(NSArray<WFTree *> *trees) { return [trees filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"isMain == NO"]]; }

static NSString *Mark(WFTree *t, WFReview *r) {
    NSString *c = WFCategory(t, r);
    if ([c isEqualToString:@"active"]) return @"●";
    if ([c isEqualToString:@"merged"]) return @"◆";
    if ([c isEqualToString:@"stale"]) return @"◇";
    if ([c isEqualToString:@"missing"]) return @"×";
    return @"○";
}

static NSString *Label(WFTree *t) { return [NSString stringWithFormat:@"%@/%@", t.repoName, [t.path isEqualToString:t.repo] ? @"" : t.name]; }

/// The path below the scan root that holds it, such as acme-web.worktrees/search, else with ~ for home.
static NSString *Rel(WFTree *t) {
    for (NSString *r in WFRules.shared.roots) if ([t.path hasPrefix:[r stringByAppendingString:@"/"]]) return [t.path substringFromIndex:r.length + 1];
    return WFTilde(t.path);
}

/// Fetches every repo with --prune, so merged and upstream gone are current. Network; only when asked.
static void FetchAll(NSArray<WFTree *> *trees) {
    NSMutableSet *repos = [NSMutableSet new];
    for (WFTree *t in trees) if (t.repo) [repos addObject:t.repo];
    for (NSString *r in repos) WFGitInput(r, @[@"fetch", @"--all", @"--prune", @"--quiet"], nil, 60, NULL);
}

#pragma mark - CLI

static void PrintJSON(id obj) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes error:nil];
    printf("%s\n", [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding].UTF8String);
}

static NSDictionary *TreeJSON(WFTree *t, WFReview *r) {
    NSMutableDictionary *j = [t.json mutableCopy];
    WFVerdict *v = r.verdicts[t.path];
    if (v) j[@"review"] = @{@"verdict": v.verdict, @"confidence": @(v.confidence), @"about": v.about ?: @"", @"reason": v.reason ?: @"",
                            @"what": v.what ?: @"", @"why": v.why ?: @"", @"state": v.state ?: @"", @"recommendation": v.recommendation ?: @"",
                            @"keep_evidence": v.keepEvidence ?: @"", @"judged": @(v.judged), @"model": r.model ?: @"", @"at": @(r.at.timeIntervalSince1970)};
    j[@"category"] = WFCategory(t, r);
    j[@"keep"] = WFMustKeep(t, r) ?: NSNull.null;
    return j;
}

static NSArray *PlanJSON(NSArray *plan) {
    NSMutableArray *o = [NSMutableArray new];
    for (NSDictionary *p in plan) {
        WFTree *t = p[@"tree"];
        [o addObject:@{@"path": t.path, @"branch": t.branch ?: NSNull.null, @"remove": p[@"remove"], @"why": p[@"why"], @"diskBytes": @(t.diskBytes)}];
    }
    return o;
}

static BOOL Confirm(NSString *q) {
    printf("%s [y/N] ", q.UTF8String); fflush(stdout);
    char buf[8] = {0};
    return fgets(buf, sizeof buf, stdin) && (buf[0] == 'y' || buf[0] == 'Y');
}

static int Usage(void) {
    fprintf(stderr,
        "usage: workforest <command> [options]\n"
        "  list                  every linked worktree: repo, branch, quiet time, disk, git state (default; --all adds main checkouts)\n"
        "  explain <path>        what it is, why it exists, where the work stands, and every fact found\n"
        "  review                ask the model which worktrees are still wanted; in Eager mode the judge looks again\n"
        "  summary               the last summary, and what the mode would remove and keep, with reasons\n"
        "  auto                  one round of the mode: remove what it decides to remove (--dry-run shows it, --review reviews first)\n"
        "  clean-up              remove every worktree the last review calls stale and nothing keeps\n"
        "  remove <path>         remove one worktree: its work checks first, ignored files saved, branch kept unless merged\n"
        "  restore <id|path>     recreate a removed worktree at its commit and put the saved files back\n"
        "  removed               what WorkForest removed, with ids to restore\n"
        "  keep <path>           no mode removes it for a week (--days N, --off to end it)\n"
        "  fetch                 git fetch --all --prune in every repo, so merged status is current\n"
        "  prune <path>          git worktree prune in that repo, for worktrees whose folder is gone\n"
        "  mode [name]           show or set the mode: idle (report only), proactive (merged and a week quiet), eager (default)\n"
        "  rules                 print the rules file path and the folders scanned\n"
        "options:\n"
        "  --json                machine-readable output\n"
        "  --yes                 do not ask\n"
        "  --model <alias>       review: auto (Haiku, then Luna), haiku, sonnet, opus, luna or a full model name (setting: workforest.model)\n"
        "  --mode <name>         review, summary, auto: use this mode instead of the setting\n"
        "  --path <path>         summary, auto, clean-up: only the worktree at this path\n"
        "  --dry-run             auto: show the plan, remove nothing\n");
    return 2;
}

static int RunCLI(int argc, const char **argv) {
    NSMutableArray<NSString *> *args = [NSMutableArray new];
    for (int i = 1; i < argc; i++) [args addObject:@(argv[i])];
    NSString *cmd = args.firstObject ?: @"list";
    BOOL json = [args containsObject:@"--json"], yes = [args containsObject:@"--yes"];
    NSString *(^opt)(NSString *) = ^NSString *(NSString *name) {
        NSUInteger i = [args indexOfObject:name];
        return (i != NSNotFound && i + 1 < args.count) ? args[i + 1] : nil;
    };
    NSString *arg1 = args.count > 1 && ![args[1] hasPrefix:@"--"] ? args[1] : nil;
    if ([cmd isEqualToString:@"auto"] && ![args containsObject:@"--dry-run"]) WFStartWatching();

    if ([cmd isEqualToString:@"rules"]) {
        printf("%s\n", WFRules.shared.fileURL.path.UTF8String);
        for (NSString *r in WFRules.shared.roots) printf("  scans %s%s\n", WFTilde(r).UTF8String, [NSFileManager.defaultManager fileExistsAtPath:r] ? "" : " (missing)");
        return 0;
    }
    if ([cmd isEqualToString:@"mode"]) {
        if (arg1) { if (WFModeFrom(arg1) < 0) return Usage(); WFSetMode((WFMode)WFModeFrom(arg1)); }
        printf("%s\n", WFModeNames()[WFCurrentMode()].UTF8String);
        return 0;
    }
    if ([cmd isEqualToString:@"removed"]) {
        if (json) { PrintJSON(WFRemoved()); return 0; }
        if (!WFRemoved().count) { printf("nothing removed\n"); return 0; }
        for (NSDictionary *r in WFRemoved())
            printf("%s  %-44s %-28s %s ago by %s\n          %s%s\n", [r[@"id"] UTF8String], WFTilde(r[@"path"]).UTF8String, [[r[@"branch"] description] UTF8String],
                   WFDuration(NSDate.date.timeIntervalSince1970 - [r[@"at"] doubleValue]).UTF8String, [r[@"by"] UTF8String], [r[@"why"] UTF8String],
                   [r[@"saved"] count] ? [NSString stringWithFormat:@" · saved %@", [r[@"saved"] componentsJoinedByString:@", "]].UTF8String : "");
        return 0;
    }
    if ([cmd isEqualToString:@"keep"]) {
        if (!arg1) return Usage();
        NSString *path = WFAbsolute(arg1);
        BOOL off = [args containsObject:@"--off"];
        NSInteger days = opt(@"--days") ? opt(@"--days").integerValue : 7;
        WFSetKept(path, off ? nil : [NSDate dateWithTimeIntervalSinceNow:days * 86400]);
        printf(off ? "%s is no longer kept\n" : "%s is kept for %ld days\n", WFTilde(path).UTF8String, (long)days);
        return 0;
    }
    if ([cmd isEqualToString:@"restore"]) {
        if (!arg1) return Usage();
        NSString *err = WFRestore(arg1);
        if (err) { fprintf(stderr, "restore failed: %s\n", err.UTF8String); return 1; }
        printf("restored\n");
        return 0;
    }
    if ([cmd isEqualToString:@"prune"]) {
        if (!arg1) return Usage();
        NSString *common = WFGit(WFAbsolute(arg1), @[@"rev-parse", @"--path-format=absolute", @"--git-common-dir"], NULL);
        if (!common.length) { fprintf(stderr, "not in a git repo\n"); return 1; }
        int st = 0;
        NSString *out = WFGitInput(common.stringByDeletingLastPathComponent, @[@"worktree", @"prune", @"--verbose"], nil, 30, &st);
        printf("%s\n", out.length ? out.UTF8String : "nothing to prune");
        return st == 0 ? 0 : 1;
    }
    NSArray *known = @[@"list", @"explain", @"review", @"summary", @"auto", @"clean-up", @"remove", @"fetch"];
    if (![known containsObject:cmd]) return Usage();
    NSInteger modeOpt = opt(@"--mode") ? WFModeFrom(opt(@"--mode")) : WFCurrentMode();
    if (modeOpt < 0) return Usage();
    WFMode mode = (WFMode)modeOpt;

    if ([cmd isEqualToString:@"remove"]) {
        if (!arg1) return Usage();
        NSString *path = WFAbsolute(arg1);
        if (!yes && !Confirm([NSString stringWithFormat:@"Remove the worktree at %@? Its branch stays unless it is merged.", WFTilde(path)])) { printf("aborted\n"); return 1; }
        NSString *err = nil;
        NSDictionary *rec = WFRemove(path, nil, @"removed from the command line", &err);
        if (!rec) { fprintf(stderr, "not removed: %s\n", err.UTF8String); return 1; }
        if (json) { PrintJSON(rec); return 0; }
        printf("removed %s (id %s)%s\n", WFTilde(path).UTF8String, [rec[@"id"] UTF8String], [rec[@"branchDeleted"] boolValue] ? ", merged branch deleted" : ", branch kept");
        return 0;
    }

    WFScanner *s = [WFScanner new];
    [s scan:YES done:nil];
    if ([cmd isEqualToString:@"fetch"]) {
        FetchAll(s.trees);
        printf("fetched %s\n", Plural([[NSSet setWithArray:[s.trees valueForKey:@"repo"]] count], @"repo").UTF8String);
        return 0;
    }
    WFReview *review = [WFReview load];
    NSArray<WFTree *> *linked = Linked(s.trees);

    if ([cmd isEqualToString:@"list"]) {
        BOOL all = [args containsObject:@"--all"];
        NSArray *shown = all ? s.trees : linked;
        if (json) {
            NSMutableArray *o = [NSMutableArray new];
            for (WFTree *t in shown) [o addObject:TreeJSON(t, review)];
            PrintJSON(@{@"trees": o, @"mode": WFModeNames()[mode], @"plan": PlanJSON(WFPlan(s.trees, review, mode)),
                        @"candidates": [WFCandidates(linked, review) valueForKey:@"path"], @"graceOver": @(WFGraceOver())});
            return 0;
        }
        if (!shown.count) { printf("no worktrees found under %s\n", [[WFRules.shared.roots valueForKey:@"lastPathComponent"] componentsJoinedByString:@", "].UTF8String); return 0; }
        printf("  %-56s%-34s%8s%10s  %s\n", "worktree", "branch", "quiet", "disk", "state");
        uint64_t disk = 0, cache = 0;
        for (WFTree *t in shown) {
            disk += t.diskBytes; cache += t.cacheBytes;
            printf("%s %-56s%-34s%8s%10s  %s\n", Mark(t, review).UTF8String, Cut(Rel(t), 55).UTF8String, Cut(t.branch ?: @"(detached)", 33).UTF8String,
                   WFDuration(t.quiet).UTF8String, t.sizedAt ? WFFormatBytes(t.diskBytes).UTF8String : "?", WFStateWords(t).UTF8String);
        }
        NSSet *repos = [NSSet setWithArray:[shown valueForKey:@"repo"]];
        printf("\n%s in %s · %s, %s of it caches\n", Plural(shown.count, @"worktree").UTF8String, Plural(repos.count, @"repo").UTF8String,
               WFFormatBytes(disk).UTF8String, WFFormatBytes(cache).UTF8String);
        if (review) printf("last review %s ago by %s%s\n", WFDuration(-review.at.timeIntervalSinceNow).UTF8String, WFModelLabel(review.model).UTF8String,
                           review.error ? [NSString stringWithFormat:@" (failed: %@)", review.error].UTF8String : "");
        return 0;
    }

    if ([cmd isEqualToString:@"explain"]) {
        if (!arg1) return Usage();
        WFTree *t = [s treeAt:arg1];
        if (!t) { fprintf(stderr, "no worktree at %s\n", arg1.UTF8String); return 1; }
        WFVerdict *v = review.verdicts[t.path];
        if (json) { NSMutableDictionary *j = [TreeJSON(t, review) mutableCopy]; j[@"sentToModel"] = [WFReviewer factsFor:@[t]].firstObject; PrintJSON(j); return 0; }
        printf("%s  %s  (%s)\n\n", WFTilde(t.path).UTF8String, (t.branch ?: @"detached").UTF8String, t.isMain ? "main checkout" : "linked worktree");
        if (v.what.length) printf("  What      %s\n", v.what.UTF8String);
        if (v.why.length) printf("  Why       %s\n", v.why.UTF8String);
        if (v.state.length) printf("  State     %s\n", v.state.UTF8String);
        if (v) printf("  Verdict   %s says %s (%.0f%%)%s, %s ago: %s\n", WFModelLabel(review.model).UTF8String, v.verdict.UTF8String, v.confidence * 100,
                      v.judged ? " after the judge" : "", WFDuration(-review.at.timeIntervalSinceNow).UTF8String, v.reason.UTF8String);
        if (v.keepEvidence.length) printf("  Evidence  %s\n", v.keepEvidence.UTF8String);
        if (v.recommendation.length) printf("  Advice    %s\n", v.recommendation.UTF8String);
        if (!v) printf("  (not in a review yet: run `workforest review`)\n");
        for (NSDictionary *p in WFPlan(@[t], review, mode)) printf("  %-9s %s: %s\n", WFModeLabel(mode).UTF8String, [p[@"remove"] boolValue] ? "remove" : "keep", [p[@"why"] UTF8String]);

        printf("\nWhat WorkForest found\n");
        printf("  repo      %s, default branch %s%s\n", WFTilde(t.repo).UTF8String, (t.defaultBranch ?: @"unknown").UTF8String,
               t.fetched ? [NSString stringWithFormat:@", fetched %@ ago", WFDuration(-t.fetched.timeIntervalSinceNow)].UTF8String : ", never fetched");
        if (t.lastCommit) printf("  commit    \"%s\" by %s, %s ago\n", t.lastSubject.UTF8String, t.lastAuthor.UTF8String, WFDuration(-t.lastCommit.timeIntervalSinceNow).UTF8String);
        printf("  git       %s%s\n", WFStateWords(t).UTF8String, t.stashes ? [NSString stringWithFormat:@" · %@ on this branch", Plural(t.stashes, @"stash")].UTF8String : "");
        if (t.upstream && ![t.upstream isEqualToString:@"gone"] && ![t.upstream isEqualToString:@"none"])
            printf("  upstream  %s, %ld ahead, %ld behind\n", t.upstream.UTF8String, (long)t.ahead, (long)t.behind);
        if (t.pr) printf("  pull req  %s\n", t.pr.UTF8String);
        printf("  disk      %s, %s of it caches, %s\n", WFFormatBytes(t.diskBytes).UTF8String, WFFormatBytes(t.cacheBytes).UTF8String, Plural(t.files, @"file").UTF8String);
        printf("  files     newest outside caches %s\n", t.touched ? [NSString stringWithFormat:@"%@ ago", WFDuration(-t.touched.timeIntervalSinceNow)].UTF8String : "unknown");
        if (t.created) printf("  made      %s ago\n", WFDuration(-t.created.timeIntervalSinceNow).UTF8String);
        printf("  session   %s\n", WFSessionWords(t.session).UTF8String);
        if (t.session[@"first_prompt"]) printf("            first prompt: %s\n", [t.session[@"first_prompt"] UTF8String]);
        if (t.session[@"file"]) printf("            %s\n", [t.session[@"file"] UTF8String]);
        printf("  inside    %s\n", t.processes.count ? [t.processes componentsJoinedByString:@", "].UTF8String : "no processes");
        for (NSDictionary *h in t.servers) printf("            localhost :%s %s (%s)\n", [h[@"port"] description].UTF8String, [h[@"framework"] UTF8String], [h[@"state"] UTF8String]);
        if (t.isProtected) printf("  protected never removed\n");
        return 0;
    }

    if ([cmd isEqualToString:@"review"] || ([@[@"auto", @"clean-up"] containsObject:cmd] && [args containsObject:@"--review"])) {
        NSString *model = opt(@"--model") ?: WFModel();
        if (WFPrefBool(kFetchKey, NO)) { if (!json) fprintf(stderr, "fetching…\n"); FetchAll(s.trees); [s scan:YES done:nil]; linked = Linked(s.trees); }
        if (!json) fprintf(stderr, "reviewing %s with %s…\n", Plural(linked.count, @"worktree").UTF8String, WFModelLabel(model).UTF8String);
        review = WFRunReview(s.trees, model, mode, @"manual");
        [review save];
        if (review.error) { fprintf(stderr, "review failed: %s\n", review.error.UTF8String); return 1; }
        if (review.note && !json) fprintf(stderr, "%s, so %s answered\n", review.note.UTF8String, WFModelLabel(review.model).UTF8String);
        if (review.judgeError && !json) fprintf(stderr, "the Eager judge failed: %s\n", review.judgeError.UTF8String);
        if ([cmd isEqualToString:@"review"]) {
            if (json) {
                NSMutableArray *o = [NSMutableArray new];
                for (WFTree *t in linked) [o addObject:TreeJSON(t, review)];
                PrintJSON(@{@"trees": o, @"model": review.model ?: model, @"note": review.note ?: NSNull.null, @"tokens": @(review.tokens),
                            @"seconds": @(review.seconds), @"summary": review.summary ?: NSNull.null});
                return 0;
            }
            for (WFTree *t in linked) {
                WFVerdict *v = review.verdicts[t.path];
                printf("%s %-56s %-7s %3.0f%%%s  %s\n          %s\n", Mark(t, review).UTF8String, Cut(Rel(t), 56).UTF8String, (v.verdict ?: @"-").UTF8String,
                       v.confidence * 100, v.judged ? " judged" : "", (v.about ?: @"").UTF8String, (v.reason ?: @"no verdict").UTF8String);
            }
            printf("\n%s in %.0fs · %s\n", WFModelLabel(review.model).UTF8String, review.seconds, Tokens(review.tokens).UTF8String);
            if (review.summary.length) printf("\n%s\n", review.summary.UTF8String);
            return 0;
        }
    }

    NSArray<WFTree *> *scope = s.trees;
    if (opt(@"--path")) {
        WFTree *t = [s treeAt:opt(@"--path")];
        scope = t ? @[t] : @[];
    }

    if ([cmd isEqualToString:@"clean-up"]) {
        NSArray<WFTree *> *c = WFCandidates(Linked(scope), review);
        if (!review) printf("no review yet: run `workforest review`\n");
        uint64_t disk = 0;
        for (WFTree *t in c) { disk += t.diskBytes; printf("  %-56s %-28s %9s  %s\n", Cut(Rel(t), 56).UTF8String, Cut(t.branch ?: @"", 28).UTF8String, WFFormatBytes(t.diskBytes).UTF8String, review.verdicts[t.path].reason.UTF8String); }
        if (!c.count) { printf("nothing to clean up\n"); return 0; }
        if (!yes && !Confirm([NSString stringWithFormat:@"Remove %@ (%@)? Branches stay unless merged.", Plural(c.count, @"worktree"), WFFormatBytes(disk)])) { printf("aborted\n"); return 1; }
        int rc = 0;
        for (WFTree *t in c) {
            NSString *err = nil;
            NSDictionary *rec = WFRemove(t.path, nil, review.verdicts[t.path].reason, &err);
            printf("%s %s%s\n", rec ? "removed" : "kept", WFTilde(t.path).UTF8String, rec ? "" : [NSString stringWithFormat:@": %@", err].UTF8String);
            if (!rec) rc = 3;
        }
        return rc;
    }

    if ([cmd isEqualToString:@"summary"] || [cmd isEqualToString:@"auto"]) {
        BOOL dry = [cmd isEqualToString:@"summary"] || [args containsObject:@"--dry-run"];
        NSArray *plan = WFPlan(scope, review, mode);
        NSArray *actions = dry ? @[] : WFAutoRemove(scope, review, mode);
        if (!dry && review && actions.count) { review.actions = actions; [review save]; }
        if (json) {
            PrintJSON(@{@"mode": WFModeNames()[mode], @"summary": review.summary ?: NSNull.null, @"plan": PlanJSON(plan), @"actions": actions,
                        @"reviewAt": review ? @(review.at.timeIntervalSince1970) : NSNull.null, @"trigger": review.trigger ?: NSNull.null});
            return 0;
        }
        if ([cmd isEqualToString:@"summary"]) {
            printf("%s\n\n", review.summary.length ? review.summary.UTF8String : "no summary yet: run `workforest review`");
            if (review) printf("review %s ago by %s%s\n", WFDuration(-review.at.timeIntervalSinceNow).UTF8String, WFModelLabel(review.model).UTF8String,
                               review.trigger ? [NSString stringWithFormat:@", woken by %@", review.trigger].UTF8String : "");
        }
        printf("%s mode%s:\n", WFModeLabel(mode).UTF8String, dry && [cmd isEqualToString:@"auto"] ? ", dry run" : "");
        for (NSDictionary *p in plan) {
            WFTree *t = p[@"tree"];
            printf("  %-6s %-56s %8s  %s\n", [p[@"remove"] boolValue] ? "remove" : "keep", Cut(Rel(t), 56).UTF8String,
                   t.sizedAt ? WFFormatBytes(t.diskBytes).UTF8String : "?", [p[@"why"] UTF8String]);
        }
        if (!plan.count) printf("  no linked worktrees\n");
        for (NSDictionary *a in actions)
            printf("%s %s%s\n", [a[@"removed"] boolValue] ? "removed" : "kept", WFTilde(a[@"path"]).UTF8String,
                   [a[@"removed"] boolValue] ? [NSString stringWithFormat:@" (restore with: workforest restore %@)", a[@"id"]].UTF8String : [NSString stringWithFormat:@": %@", a[@"error"]].UTF8String);
        return 0;
    }
    return Usage();
}

#pragma mark - App

@interface WorkForest : NSObject <NSApplicationDelegate>
@property (strong) NSStatusItem *statusItem;
@property (strong) WFScanner *scanner;
@property (strong) WFReview *review;
@property (strong) NSTimer *timer;
@property BOOL reviewing, removing, learned;
// What wakes a review besides the schedule: a new worktree, a worktree passing an age mark, low disk.
@property (strong) NSMutableSet<NSString *> *known;
@property (strong) NSMutableDictionary<NSString *, NSNumber *> *ageMark;
@property (copy) NSString *pending;
@property (strong) NSDate *lastEvent;
@property (strong) NSDictionary<NSString *, NSDictionary *> *plan;       // by path, built when the menu opens
@property (strong) NSDictionary<NSString *, NSString *> *prefixes;     // by repo: the folder-name start its worktrees share
@end

@implementation WorkForest

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    WFStartWatching();
    self.scanner = [WFScanner new];
    self.review = [WFReview load];
    self.known = [NSMutableSet new]; self.ageMark = [NSMutableDictionary new];
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(handleClick:);
    self.statusItem.button.imagePosition = NSImageLeft;
    [self.statusItem.button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];
    [UNUserNotificationCenter.currentNotificationCenter requestAuthorizationWithOptions:UNAuthorizationOptionAlert completionHandler:^(BOOL ok, NSError *e) {}];
    [self updateButton];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:60 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    self.timer.tolerance = 10;
    [self rescan];
}

- (void)rescan {
    [self.scanner scan:NO done:^{ [self watchEvents]; [self decide]; [self updateButton]; }];
}

- (void)tick {
    if (!self.scanner.scanning && (!self.scanner.scannedAt || -self.scanner.scannedAt.timeIntervalSinceNow >= kScanEvery)) [self rescan];
    else [self decide];
}

/// Notes the events that should wake a review: a linked worktree not seen before, one whose quiet time passes a week,
/// a month or three months, and less than 10% or 15 GB free on the home volume. The first scan only learns what exists.
- (void)watchEvents {
    BOOL first = !self.learned;
    self.learned = YES;
    static const double marks[] = {7 * 86400, 30 * 86400, 90 * 86400};
    for (WFTree *t in Linked(self.scanner.trees)) {
        NSInteger passed = 0; while (passed < 3 && t.quiet >= marks[passed]) passed++;
        if (![self.known containsObject:t.path]) {
            [self.known addObject:t.path]; self.ageMark[t.path] = @(passed);
            if (!first) self.pending = [@"new worktree " stringByAppendingString:Label(t)];
            continue;
        }
        if (passed > [self.ageMark[t.path] integerValue]) {
            self.ageMark[t.path] = @(passed);
            self.pending = [NSString stringWithFormat:@"%@ quiet %@", Label(t), WFDuration(marks[passed - 1])];
        }
    }
    NSDictionary *v = [[NSURL fileURLWithPath:NSHomeDirectory()] resourceValuesForKeys:@[NSURLVolumeAvailableCapacityForImportantUsageKey, NSURLVolumeTotalCapacityKey] error:nil];
    double free = [v[NSURLVolumeAvailableCapacityForImportantUsageKey] doubleValue], total = [v[NSURLVolumeTotalCapacityKey] doubleValue];
    if (total > 0 && (free < total * 0.10 || free < 15e9)) self.pending = [NSString stringWithFormat:@"low disk: %@ free", WFFormatBytes((uint64_t)free)];
}

- (void)decide {
    NSInteger every = WFPrefInt(kReviewMinKey, 120);
    BOOL any = Linked(self.scanner.trees).count > 0;
    if (every <= 0 || self.reviewing || self.removing || !any || !self.scanner.scannedAt) return;
    if (!self.review || -self.review.at.timeIntervalSinceNow >= every * 60) [self reviewBecause:@"schedule"];
    else if (self.pending && (!self.lastEvent || -self.lastEvent.timeIntervalSinceNow >= kEventGap)) { self.lastEvent = NSDate.date; [self reviewBecause:self.pending]; }
}

- (void)updateButton {
    NSArray *linked = Linked(self.scanner.trees);
    NSInteger stale = 0;
    for (WFTree *t in linked) { NSString *c = WFCategory(t, self.review); if ([c isEqualToString:@"merged"] || [c isEqualToString:@"stale"]) stale++; }
    NSImage *img = [NSImage imageWithSystemSymbolName:@"tree" accessibilityDescription:@"WorkForest"] ?: [NSImage imageWithSystemSymbolName:@"leaf" accessibilityDescription:@"WorkForest"];
    img = [img imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightRegular]];
    img.template = YES;
    self.statusItem.button.image = img;
    NSString *t = !self.scanner.scannedAt ? @" …" : stale ? [NSString stringWithFormat:@" %lu · %ld stale", (unsigned long)linked.count, (long)stale] : [NSString stringWithFormat:@" %lu", (unsigned long)linked.count];
    self.statusItem.button.attributedTitle = [[NSAttributedString alloc] initWithString:t attributes:@{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize weight:NSFontWeightRegular]}];
    self.statusItem.button.toolTip = [NSString stringWithFormat:@"WorkForest: %@, %ld merged or stale", Plural(linked.count, @"worktree"), (long)stale];
}

#pragma mark Review

- (void)reviewNow { [self reviewBecause:@"manual"]; }

/// Reviews in the background, then lets the mode act on fresh facts.
- (void)reviewBecause:(NSString *)trigger {
    if (self.reviewing) return;
    self.reviewing = YES; self.pending = nil;
    NSString *model = WFModel(); WFMode mode = WFCurrentMode();
    BOOL fetch = WFPrefBool(kFetchKey, NO);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (fetch) FetchAll(self.scanner.trees);
        if (fetch) [self.scanner scan:YES done:nil];
        WFReview *r = WFRunReview(self.scanner.trees, model, mode, trigger);
        r.actions = WFAutoRemove(self.scanner.trees, r, mode);   // each removal reads its worktree again first
        [r save];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.review = r; self.reviewing = NO;
            [self notify:r.actions mode:mode];
            if (r.actions.count) [self rescan]; else [self updateButton];
        });
    });
}

- (void)notify:(NSArray<NSDictionary *> *)actions mode:(WFMode)mode {
    NSArray *done = [actions filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"removed == YES"]];
    if (!done.count) return;
    uint64_t disk = 0; NSMutableArray *lines = [NSMutableArray new];
    for (NSDictionary *a in done) { disk += [a[@"diskBytes"] unsignedLongLongValue]; [lines addObject:[NSString stringWithFormat:@"%@ %@", a[@"repo"], a[@"branch"]]]; }
    UNMutableNotificationContent *c = [UNMutableNotificationContent new];
    c.title = [NSString stringWithFormat:@"%@ removed %@, %@ freed", WFModeLabel(mode), Plural(done.count, @"worktree"), WFFormatBytes(disk)];
    c.body = [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\nRecently Removed can restore each one."];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:[UNNotificationRequest requestWithIdentifier:NSUUID.UUID.UUIDString content:c trigger:nil]
                                                         withCompletionHandler:nil];
}

#pragma mark Menu

static NSMenuItem *Item(NSMenu *m, NSString *t, SEL a, id target, BOOL on) {
    NSMenuItem *i = [[NSMenuItem alloc] initWithTitle:t action:a keyEquivalent:@""];
    i.target = target; i.state = on ? NSControlStateValueOn : NSControlStateValueOff; [m addItem:i]; return i;
}
static NSMenuItem *Header(NSMenu *m, NSString *t) { NSMenuItem *i = Item(m, t, NULL, nil, NO); i.enabled = NO; return i; }
static NSMenuItem *Sub(NSMenu *m, NSString *t, NSMenu *sub) { NSMenuItem *i = Item(m, t, NULL, nil, NO); i.submenu = sub; return i; }

/// A menu line with a gray tail, such as "Review Now   9m ago".
static NSAttributedString *Titled(NSString *title, NSString *tail) {
    NSFont *f = [NSFont menuFontOfSize:0];
    NSMutableAttributedString *t = [[NSMutableAttributedString alloc] initWithString:title attributes:@{NSFontAttributeName: f}];
    if (tail.length) [t appendAttributedString:[[NSAttributedString alloc] initWithString:title.length ? [@"   " stringByAppendingString:tail] : tail
                                                                              attributes:@{NSFontAttributeName: f, NSForegroundColorAttributeName: NSColor.secondaryLabelColor}]];
    return t;
}

/// Wrapped, readable text of a fixed width and at most `lines` lines (0 for no limit), sized to fit.
static NSTextField *Para(NSString *text, NSFont *font, NSColor *color, CGFloat width, NSInteger lines) {
    NSTextField *t = [NSTextField wrappingLabelWithString:text ?: @""];
    t.font = font; t.textColor = color; t.preferredMaxLayoutWidth = width;
    t.maximumNumberOfLines = lines; t.cell.truncatesLastVisibleLine = YES; t.lineBreakMode = NSLineBreakByWordWrapping;
    CGFloat h = [t.cell cellSizeForBounds:NSMakeRect(0, 0, width, 4000)].height;
    if (lines > 0) h = MIN(h, ceil(lines * (font.ascender - font.descender + font.leading) + 1));
    [t.widthAnchor constraintEqualToConstant:width].active = YES; [t.heightAnchor constraintEqualToConstant:h].active = YES;
    t.frame = NSMakeRect(0, 0, width, h);
    return t;
}

/// A bold colored head, then plain text: "Staying. 3 changes not committed."
static NSAttributedString *Rich(NSString *bold, NSColor *boldColor, NSString *rest, CGFloat size) {
    NSMutableAttributedString *a = [[NSMutableAttributedString alloc] initWithString:bold attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:size weight:NSFontWeightSemibold], NSForegroundColorAttributeName: boldColor}];
    if (rest.length) [a appendAttributedString:[[NSAttributedString alloc] initWithString:[@" " stringByAppendingString:rest] attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:size], NSForegroundColorAttributeName: NSColor.labelColor}]];
    return a;
}

/// Text inside a menu at a readable width, in secondary text color rather than the gray of a disabled item.
static NSMenuItem *TextItem(NSString *text, NSInteger lines) {
    NSTextField *t = Para(text, [NSFont systemFontOfSize:12.5], NSColor.secondaryLabelColor, 312, lines);
    NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 340, t.frame.size.height + 10)];
    t.frame = NSMakeRect(14, 5, 312, t.frame.size.height); [box addSubview:t];
    NSMenuItem *i = [NSMenuItem new]; i.view = box;
    return i;
}

static NSString *Sentence(NSString *s) {
    if (!s.length) return @"";
    s = [[s substringToIndex:1].uppercaseString stringByAppendingString:[s substringFromIndex:1]];
    return [s hasSuffix:@"."] || [s hasSuffix:@"?"] ? s : [s stringByAppendingString:@"."];
}

static void Section(NSMenu *m, NSString *title) {
    if (@available(macOS 14.0, *)) [m addItem:[NSMenuItem sectionHeaderWithTitle:title]];
    else Header(m, title);
}

/// The first part of a duration: "5d" from "5d 17h".
static NSString *Short(NSTimeInterval s) { return [WFDuration(s) componentsSeparatedByString:@" "].firstObject; }

/// The one thing to know about a worktree's git state, for its row.
static NSString *ShortState(WFTree *t) {
    if (t.prunable) return @"folder missing";
    if (t.dirty > 0) return Plural(t.dirty, @"change");
    if (t.untracked > 0) return [NSString stringWithFormat:@"%ld untracked", (long)t.untracked];
    if (t.unpushed > 0 && !t.merged) return [NSString stringWithFormat:@"%@ only here", Plural(t.unpushed, @"commit")];
    if (t.merged) return [t.merged isEqualToString:@"ancestor"] ? @"merged" : [t.merged stringByAppendingString:@"-merged"];
    if ([t.upstream isEqualToString:@"gone"]) return @"remote branch deleted";
    if (t.locked) return @"locked";
    if (t.notInDefault > 0) return [NSString stringWithFormat:@"%@ not in %@", Plural(t.notInDefault, @"commit"), [t.defaultBranch.lastPathComponent ?: @"main" lastPathComponent]];
    return @"clean";
}

/// The top of the menu: reclaimable disk in large type, and one line of counts.
static NSView *MenuHeader(uint64_t reclaim, NSString *line) {
    CGFloat w = 340;
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, w, 62)];
    NSMutableAttributedString *big = [[NSMutableAttributedString alloc] initWithString:reclaim ? WFFormatBytes(reclaim) : @"Nothing"
        attributes:@{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:22 weight:NSFontWeightSemibold], NSForegroundColorAttributeName: NSColor.labelColor}];
    [big appendAttributedString:[[NSAttributedString alloc] initWithString:reclaim ? @"  to reclaim" : @"  to reclaim"
        attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:13], NSForegroundColorAttributeName: NSColor.secondaryLabelColor}]];
    NSTextField *n = [NSTextField labelWithAttributedString:big]; n.frame = NSMakeRect(14, 24, w - 28, 28); [v addSubview:n];
    NSTextField *l = [NSTextField labelWithString:line];
    l.font = [NSFont systemFontOfSize:12]; l.textColor = NSColor.secondaryLabelColor; l.lineBreakMode = NSLineBreakByTruncatingTail;
    l.frame = NSMakeRect(14, 8, w - 28, 15); [v addSubview:l];
    return v;
}

/// The name a row shows: the folder without the start its repo's worktrees share, such as "acme-web-".
- (NSString *)nameFor:(WFTree *)t {
    if (t.isMain) return t.name;
    NSString *name = t.name, *p = self.prefixes[t.repo];
    if (p.length && [name hasPrefix:p] && name.length > p.length) return [name substringFromIndex:p.length];
    NSString *rp = [t.repoName stringByAppendingString:@"-"];
    if ([name hasPrefix:rp] && name.length > rp.length) return [name substringFromIndex:rp.length];
    return name;
}

/// "quiet 6d: squash-merged…" reads "squash-merged…": the card's Last work line already says how quiet it is.
static NSString *WithoutQuietLead(NSString *why) {
    NSRange colon = [why rangeOfString:@": "];
    return [why hasPrefix:@"quiet "] && colon.location != NSNotFound && colon.location < 16 ? [why substringFromIndex:NSMaxRange(colon)] : why;
}

/// Whole sentences of text that fit in `lines` lines at this width, so a summary never stops mid-word.
static NSString *FitSentences(NSString *text, NSFont *font, CGFloat width, NSInteger lines) {
    NSMutableArray *parts = [NSMutableArray new];
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationBySentences usingBlock:^(NSString *sub, NSRange r, NSRange er, BOOL *stop) {
        [parts addObject:[text substringWithRange:er]];
    }];
    CGFloat limit = lines * (font.ascender - font.descender + font.leading) + 1;
    NSMutableString *out = [NSMutableString new];
    for (NSString *p in parts) {
        NSString *next = [[out stringByAppendingString:p] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        CGFloat h = [next boundingRectWithSize:NSMakeSize(width, 4000) options:NSStringDrawingUsesLineFragmentOrigin attributes:@{NSFontAttributeName: font}].size.height;
        if (h > limit && out.length) break;
        [out setString:[out stringByAppendingString:p]];
    }
    return [out stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

/// Will this worktree go, and when. Plan entries that wait for the first day still count.
- (BOOL)removesNext:(WFTree *)t {
    NSDictionary *p = self.plan[t.path];
    return [p[@"remove"] boolValue] || [p[@"why"] hasPrefix:@"would remove"];
}

/// Why a worktree is still here, in plain words: a short colored head, then the reason and what happens next.
- (NSArray *)statusFor:(WFTree *)t {
    if (t.isMain) return @[@"Main checkout.", NSColor.secondaryLabelColor, @"WorkForest never removes a main checkout."];
    if (t.prunable) return @[@"Folder is gone.", NSColor.secondaryLabelColor, @"Git still lists this worktree. Prune, under More, tidies git's record of it."];
    NSDictionary *p = self.plan[t.path];
    NSString *why = p[@"why"] ?: WFMustKeep(t, self.review) ?: @"";
    if ([p[@"remove"] boolValue]) return @[@"Removes at the next review.", NSColor.systemOrangeColor, Sentence(Cut(WithoutQuietLead(why), 220))];
    if ([why hasPrefix:@"would remove ("]) {
        NSRange end = [why rangeOfString:@"), but " options:NSBackwardsSearch];
        NSString *inner = end.location != NSNotFound ? [why substringWithRange:NSMakeRange(14, end.location - 14)] : why;
        return @[@"Removes after the first day.", NSColor.systemOrangeColor,
                 [Sentence(Cut(inner, 180)) stringByAppendingString:@" WorkForest watches for a day before any mode acts."]];
    }
    WFMode mode = WFCurrentMode();
    if (mode == WFModeIdle && !WFWorkKeeps(t)) return @[@"Staying.", NSColor.systemGreenColor, @"Idle mode only reports. Clean Up or Remove are up to you."];
    NSString *next = @"";
    if ([why containsString:@"not committed"]) next = @" Commit or discard them, and the next review looks again.";
    else if ([why containsString:@"on no remote"]) next = @" Push or merge them first; until then this is the only copy.";
    else if ([why containsString:@"no branch holds"]) next = @" Put them on a branch first.";
    else if ([why containsString:@"running inside"]) {   // process names keep their case: "node", not "Node"
        NSString *what = [why stringByReplacingOccurrencesOfString:@" running inside" withString:@""];
        why = [what hasPrefix:@"localhost "] ? [NSString stringWithFormat:@"a %@ runs inside", what] : [@"a process runs inside: " stringByAppendingString:what];
        next = @" It stays while that runs.";
    }
    else if ([why containsString:@"session active"]) next = @" The agent may still be working here.";
    else if ([why hasPrefix:@"files changed"]) next = @" After a quiet day the next review looks again.";
    else if ([why hasPrefix:@"made "]) next = @" New worktrees get a day.";
    else if ([why isEqualToString:@"protected"]) next = @" Unprotect it under More to let the mode decide.";
    else if ([why hasPrefix:@"locked"]) next = @" Unlock it with git worktree unlock to let the mode decide.";
    else if ([why hasPrefix:@"not judged yet"]) next = @" The judge looks at it in the next review.";
    else if ([why hasPrefix:@"not merged and the remote"]) next = @" Proactive removes only merged work.";
    else if ([why hasPrefix:@"evidence: "]) why = [@"the judge found evidence: " stringByAppendingString:[why substringFromIndex:10]];
    else if ([why hasPrefix:@"no review"] || [why hasPrefix:@"the last review"] || [why hasPrefix:@"worked on after"] || [why hasPrefix:@"not in the last"])
        next = @" The next review looks again.";
    return @[@"Staying.", NSColor.systemGreenColor, [Sentence(Cut(why, 200)) stringByAppendingString:next]];
}

/// The readable card at the top of a worktree's submenu.
- (NSMenuItem *)cardFor:(WFTree *)t {
    CGFloat inner = 360;
    WFVerdict *v = self.review.verdicts[t.path];
    NSStackView *s = [NSStackView new];
    s.orientation = NSUserInterfaceLayoutOrientationVertical; s.alignment = NSLayoutAttributeLeading; s.spacing = 8;
    s.edgeInsets = NSEdgeInsetsMake(10, 16, 10, 16);

    NSString *title = v.about.length ? v.about : t.isMain ? [NSString stringWithFormat:@"The main checkout of %@", t.repoName]
                    : [NSString stringWithFormat:@"%@ worktree for %@", t.repoName, t.branch ?: @"a detached commit"];
    [s addArrangedSubview:Para(Sentence(title), [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], NSColor.labelColor, inner, 2)];
    NSArray *st = [self statusFor:t];
    NSTextField *status = Para(@"", [NSFont systemFontOfSize:12.5], NSColor.labelColor, inner, 4);
    status.attributedStringValue = Rich(st[0], st[1], st[2], 12.5);
    status.constraints.lastObject.active = NO;   // the label's own size, which wraps exactly as it draws
    status.preferredMaxLayoutWidth = inner;
    [s addArrangedSubview:status];

    // Facts as label and value, in two aligned columns.
    NSMutableArray *rows = [NSMutableArray new];
    void (^fact)(NSString *, NSString *) = ^(NSString *label, NSString *value) {
        if (!value.length) return;
        NSTextField *l = [NSTextField labelWithString:label]; l.font = [NSFont systemFontOfSize:11.5]; l.textColor = NSColor.tertiaryLabelColor;
        NSTextField *x = [NSTextField labelWithString:value]; x.font = [NSFont systemFontOfSize:12]; x.textColor = NSColor.labelColor;
        x.lineBreakMode = NSLineBreakByTruncatingTail; [x.widthAnchor constraintLessThanOrEqualToConstant:inner - 74].active = YES;
        x.toolTip = value;
        [rows addObject:@[l, x]];
    };
    fact(@"Branch", [NSString stringWithFormat:@"%@ in %@", t.branch ?: @"detached commit", t.repoName]);
    if (t.lastWork) fact(@"Last work", [NSString stringWithFormat:@"%@ ago%@", WFDuration(t.quiet),
                                        t.lastSubject.length ? [NSString stringWithFormat:@" · “%@”", t.lastSubject] : @""]);
    fact(@"Disk", t.sizedAt ? (t.cacheBytes ? [NSString stringWithFormat:@"%@, of which %@ is caches", WFFormatBytes(t.diskBytes), WFFormatBytes(t.cacheBytes)] : WFFormatBytes(t.diskBytes)) : @"still measuring");
    fact(@"Git", WFStateWords(t));
    NSDictionary *se = t.session;
    NSString *seTitle = se[@"title"] ?: se[@"first_prompt"];
    fact(@"Agent", se ? [NSString stringWithFormat:@"%@%@, %@ ago", se[@"agent"], seTitle ? [NSString stringWithFormat:@", “%@”", seTitle] : @"",
                         Short([se[@"last_active_minutes_ago"] doubleValue] * 60)] : @"none found");
    NSMutableArray *inside = [NSMutableArray new];
    for (NSDictionary *h in t.servers) [inside addObject:[NSString stringWithFormat:@":%@ %@", h[@"port"], h[@"framework"]]];
    for (NSString *p in t.processes) [inside addObject:[p componentsSeparatedByString:@" (pid"].firstObject];
    if (inside.count) fact(@"Running", [[NSOrderedSet orderedSetWithArray:inside].array componentsJoinedByString:@", "]);
    NSGridView *g = [NSGridView gridViewWithViews:rows];
    g.rowSpacing = 4; g.columnSpacing = 10; [g columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    [g columnAtIndex:0].width = 62; [g columnAtIndex:1].xPlacement = NSGridCellPlacementLeading;   // the same columns on every card
    [s addArrangedSubview:g];
    NSString *said = [st[2] lowercaseString], *reason = [WithoutQuietLead(v.reason ?: @"") lowercaseString];
    BOOL repeats = reason.length > 12 && [said containsString:[reason substringToIndex:MIN(reason.length, 40)]];
    if (v.reason.length && !repeats)
        [s addArrangedSubview:Para([NSString stringWithFormat:@"%@ says %@%@: %@", WFModelLabel(self.review.model), v.verdict, v.judged ? @" after the judge" : @"", v.reason],
                                   [NSFont systemFontOfSize:11.5], NSColor.secondaryLabelColor, inner, 2)];
    NSSize fit = s.fittingSize;
    s.frame = NSMakeRect(0, 0, MAX(fit.width, inner + 32), fit.height);
    NSMenuItem *i = [NSMenuItem new]; i.view = s;
    return i;
}

- (NSMenuItem *)treeItem:(WFTree *)t showRepo:(BOOL)showRepo {
    NSString *name = [self nameFor:t];
    NSMenuItem *i = [[NSMenuItem alloc] initWithTitle:name action:nil keyEquivalent:@""];
    // At most three facts: the repo when there are several, the size, and the one state the section does not already say.
    NSString *section = WFCategory(t, self.review), *state = ShortState(t);
    BOOL said = ([section isEqualToString:@"merged"] && (t.merged || [state isEqualToString:@"remote branch deleted"])) || [state isEqualToString:@"clean"];
    NSMutableArray *facts = [NSMutableArray new];
    if (showRepo) [facts addObject:t.repoName];
    [facts addObject:t.sizedAt ? WFFormatBytes(t.diskBytes) : @"sizing"];
    [facts addObject:said ? [NSString stringWithFormat:@"quiet %@", Short(t.quiet)] : state];
    NSString *sub = [facts componentsJoinedByString:@" · "];
    BOOL modern = NO;
    if (@available(macOS 14.4, *)) { modern = YES; i.title = Cut(name, 48); i.subtitle = sub; }
    if (!modern) i.attributedTitle = Titled(Cut(name, 48), sub);

    NSMenu *m = [NSMenu new];
    [m addItem:[self cardFor:t]];
    [m addItem:NSMenuItem.separatorItem];
    Item(m, @"Open in Finder", @selector(reveal:), self, NO).representedObject = t.path;
    Item(m, @"Open in Terminal", @selector(openTerminal:), self, NO).representedObject = t.path;
    if (!t.isMain && !t.prunable) {
        NSDate *kept = WFKeptUntil(t.path);
        Item(m, kept ? [NSString stringWithFormat:@"Kept for %@ More", Short(kept.timeIntervalSinceNow)] : @"Keep for a Week", @selector(toggleKeep:), self, kept != nil).representedObject = t.path;
        NSString *keep = WFWorkKeeps(t);
        NSMenuItem *rm = Item(m, @"Remove…", keep ? NULL : @selector(removeOne:), self, NO);
        rm.representedObject = t.path; rm.enabled = !keep;
        if (keep) rm.toolTip = [@"Kept: " stringByAppendingString:keep];
    }
    NSMenu *more = [NSMenu new];
    for (NSArray *app in @[@[@"Cursor", @"com.todesktop.230313mzl4w4u92"], @[@"Visual Studio Code", @"com.microsoft.VSCode"], @[@"Zed", @"dev.zed.Zed"]])
        if ([NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:app[1]]) {
            Item(more, [@"Open in " stringByAppendingString:app[0]], @selector(openEditor:), self, NO).representedObject = @[t.path, app[0]];
            break;
        }
    Item(more, @"Copy Path", @selector(copyPath:), self, NO).representedObject = t.path;
    if (!t.isMain) Item(more, @"Protect", @selector(toggleProtect:), self, t.isProtected).representedObject = t.path;
    if (t.prunable) Item(more, @"Prune Git's Record", @selector(prune:), self, NO).representedObject = t.repo;
    Sub(m, @"More", more);
    i.submenu = m;
    return i;
}

/// The start every worktree folder in a repo shares, up to a dash, such as "app-": left out of the rows.
static NSDictionary<NSString *, NSString *> *Prefixes(NSArray<WFTree *> *trees) {
    NSMutableDictionary<NSString *, NSMutableArray *> *byRepo = [NSMutableDictionary new];
    for (WFTree *t in trees) if (!t.isMain) [(byRepo[t.repo] ?: (byRepo[t.repo] = [NSMutableArray new])) addObject:t.name];
    NSMutableDictionary *out = [NSMutableDictionary new];
    for (NSString *repo in byRepo) {
        NSArray *names = byRepo[repo];
        if (names.count < 2) continue;
        NSString *common = names.firstObject;
        for (NSString *n in names) common = [common commonPrefixWithString:n options:0];
        NSRange dash = [common rangeOfString:@"-" options:NSBackwardsSearch];
        if (dash.location != NSNotFound && dash.location >= 2) out[repo] = [common substringToIndex:dash.location + 1];
    }
    return out;
}

- (void)handleClick:(id)sender {
    NSMenu *menu = [self buildMenu];
    self.statusItem.menu = menu;
    [self.statusItem.button performClick:nil];
    self.statusItem.menu = nil;
}

- (NSMenu *)buildMenu {
    WFReview *r = self.review;
    NSArray<WFTree *> *all = self.scanner.trees, *linked = Linked(all);
    NSMutableDictionary *plan = [NSMutableDictionary new];
    for (NSDictionary *p in WFPlan(all, r, WFCurrentMode())) plan[[p[@"tree"] path]] = p;
    self.plan = plan;
    self.prefixes = Prefixes(all);
    NSArray *clean = WFCandidates(linked, r);
    uint64_t reclaim = 0, cleanDisk = 0; NSInteger removable = 0;
    NSMutableSet *counted = [NSMutableSet new];
    for (WFTree *t in linked) if ([self removesNext:t] || [clean containsObject:t]) { reclaim += t.diskBytes; removable++; [counted addObject:t.path]; }
    for (WFTree *t in clean) cleanDisk += t.diskBytes;
    NSUInteger repos = [[NSSet setWithArray:[all valueForKey:@"repo"]] count];
    BOOL showRepo = repos > 1;

    NSMenu *menu = [NSMenu new];
    NSString *line = !self.scanner.scannedAt ? @"Looking for worktrees…"
        : [NSString stringWithFormat:@"%@ in %@ · %@", Plural(linked.count, @"worktree"), Plural(repos, @"repo"),
           WFCurrentMode() != WFModeIdle && !WFGraceOver() ? [NSString stringWithFormat:@"%@ starts in %@", WFModeLabel(WFCurrentMode()), Short(WFGraceLeft())] : WFModeLabel(WFCurrentMode())];
    (void)removable;
    NSMenuItem *head = [NSMenuItem new];
    head.view = MenuHeader(reclaim, line);
    [menu addItem:head];
    [menu addItem:NSMenuItem.separatorItem];

    // What is going on, in up to four readable lines. The review's details sit in Review Now's tooltip.
    NSString *note = nil;
    if (r.error) note = [@"The last review failed: " stringByAppendingString:r.error];
    else if (r.summary.length) {
        // The header already counts worktrees and disk, so the menu shows the review's own sentences after the totals.
        NSRange totals = [r.summary rangeOfString:@"caches such as node_modules. "];
        note = totals.location != NSNotFound && NSMaxRange(totals) < r.summary.length ? [r.summary substringFromIndex:NSMaxRange(totals)] : r.summary;
    }
    else if (!r && linked.count) note = @"No review yet. Review Now asks Haiku or Luna which worktrees are still wanted.";
    if (note) { [menu addItem:TextItem(FitSentences(note, [NSFont systemFontOfSize:12.5], 312, 3), 3)]; [menu addItem:NSMenuItem.separatorItem]; }

    if (clean.count) {
        NSMenuItem *go = Item(menu, @"Clean Up", self.removing ? NULL : @selector(cleanUp), self, NO);
        go.attributedTitle = Titled(@"Clean Up", [NSString stringWithFormat:@"%@, %@", Plural(clean.count, @"worktree"), WFFormatBytes(cleanDisk)]);
        go.toolTip = @"Removes what the last review calls stale, when nothing keeps it: no changes, no commits only here, nothing running, no agent or file change in the last day.";
    }
    NSMenuItem *rv = Item(menu, self.reviewing ? @"Reviewing…" : @"Review Now", self.reviewing ? NULL : @selector(reviewNow), self, NO);
    rv.attributedTitle = Titled(rv.title, self.reviewing ? WFModelLabel(WFModel()) : r ? [NSString stringWithFormat:@"%@ ago", Short(-r.at.timeIntervalSinceNow)] : @"");
    rv.toolTip = r ? [NSString stringWithFormat:@"Last review by %@, %@, %.0f s%@%@", WFModelLabel(r.model), Tokens(r.tokens), r.seconds,
                      r.trigger && ![r.trigger isEqualToString:@"manual"] ? [@", woken by " stringByAppendingString:r.trigger] : @"", r.note ? [@". " stringByAppendingString:r.note] : @""] : nil;
    rv.enabled = !self.reviewing && linked.count;

    NSMutableDictionary<NSString *, NSMutableArray *> *groups = [NSMutableDictionary new];
    for (WFTree *t in linked) {
        NSString *c = WFCategory(t, r);
        [(groups[c] ?: (groups[c] = [NSMutableArray new])) addObject:t];
    }
    if (self.scanner.scannedAt && !linked.count) Header(menu, @"No linked worktrees");
    for (NSArray *sec in @[@[@"merged", @"Merged"], @[@"stale", @"Stale"], @[@"active", @"In use"], @[@"quiet", @"Quiet"]]) {
        NSArray *g = [groups[sec[0]] sortedArrayUsingComparator:^NSComparisonResult(WFTree *a, WFTree *b) {
            return a.diskBytes > b.diskBytes ? NSOrderedAscending : a.diskBytes < b.diskBytes ? NSOrderedDescending : NSOrderedSame; }];
        if (!g.count) continue;
        Section(menu, sec[1]);
        NSMenu *rest = [NSMenu new];
        NSUInteger n = 0;
        for (WFTree *t in g) [(n++ < 6 ? menu : rest) addItem:[self treeItem:t showRepo:showRepo]];
        if (rest.numberOfItems) Sub(menu, [NSString stringWithFormat:@"%ld More", (long)rest.numberOfItems], rest);
    }
    [menu addItem:NSMenuItem.separatorItem];
    NSArray *gone = groups[@"missing"];
    if (gone.count) {
        NSMenu *gm = [NSMenu new];
        for (WFTree *t in gone) [gm addItem:[self treeItem:t showRepo:showRepo]];
        Sub(menu, @"Missing Folders", gm);
    }
    NSArray *rem = WFRemoved();
    if (rem.count) {
        NSMenu *rm = [NSMenu new];
        for (NSDictionary *x in rem) {
            NSMenu *sm = [NSMenu new];
            NSString *why = [x[@"why"] length] ? Sentence(x[@"why"]) : @"Removed.";
            NSArray *saved = x[@"saved"];
            if (saved.count) why = [why stringByAppendingFormat:@" Saved: %@.", [saved componentsJoinedByString:@", "]];
            [sm addItem:TextItem(why, 4)];
            [sm addItem:NSMenuItem.separatorItem];
            Item(sm, @"Restore", @selector(restore:), self, NO).representedObject = x[@"id"];
            Item(sm, @"Copy Path", @selector(copyPath:), self, NO).representedObject = x[@"path"];
            NSMenuItem *ri = Sub(rm, @"", sm);
            ri.attributedTitle = Titled([NSString stringWithFormat:@"%@   %@", [x[@"path"] lastPathComponent], [x[@"branch"] isKindOfClass:NSString.class] ? x[@"branch"] : @"detached"],
                                        [NSString stringWithFormat:@"%@ ago by %@", Short(NSDate.date.timeIntervalSince1970 - [x[@"at"] doubleValue]), x[@"by"]]);
        }
        [rm addItem:NSMenuItem.separatorItem];
        Item(rm, @"Forget All", @selector(clearRemoved), self, NO);
        Sub(menu, @"Recently Removed", rm);
    }

    NSMenu *set = [NSMenu new];
    NSMenu *modes = [NSMenu new];
    NSArray *help = @[@"Reviews and reports. Removes nothing by itself.",
                      @"Removes merged worktrees quiet for a week.",
                      @"Removes quiet worktrees that can't show evidence."];
    for (WFMode m = WFModeIdle; m <= WFModeEager; m++) {
        NSMenuItem *mi = Item(modes, @"", @selector(setMode:), self, WFCurrentMode() == m);
        mi.attributedTitle = Titled(WFModeLabel(m), help[m]); mi.tag = m;
    }
    [modes addItem:NSMenuItem.separatorItem];
    [modes addItem:TextItem(@"No mode removes changes, commits only here, anything running inside, or a worktree with an agent session or file change in the last day.", 3)];
    Sub(set, [NSString stringWithFormat:@"Mode: %@", WFModeLabel(WFCurrentMode())], modes);
    NSMenu *models = [NSMenu new];
    BOOL known = NO;
    for (NSArray *m in WFModels()) { BOOL on = [WFModel() isEqualToString:m[0]]; known |= on; Item(models, m[1], @selector(setModel:), self, on).representedObject = m[0]; }
    if (!known) Item(models, WFModel(), NULL, nil, YES).enabled = NO;
    [models addItem:NSMenuItem.separatorItem];
    [models addItem:TextItem(@"Haiku first, Luna when Claude is out of usage. Both run on your own login, with no tools.", 2)];
    Sub(set, [NSString stringWithFormat:@"Model: %@", WFModelLabel(WFModel())], models);
    NSMenu *every = [NSMenu new];
    for (NSNumber *m in @[@0, @60, @120, @360, @720, @1440])
        Item(every, m.integerValue ? WFDuration(m.integerValue * 60) : @"Off", @selector(setReviewEvery:), self, WFPrefInt(kReviewMinKey, 120) == m.integerValue).tag = m.integerValue;
    [every addItem:NSMenuItem.separatorItem];
    [every addItem:TextItem(@"New worktrees, long quiet times and low disk also wake a review.", 2)];
    Sub(set, [NSString stringWithFormat:@"Review Every: %@", WFPrefInt(kReviewMinKey, 120) ? WFDuration(WFPrefInt(kReviewMinKey, 120) * 60) : @"Off"], every);
    [set addItem:NSMenuItem.separatorItem];
    Item(set, @"Fetch Before Each Review", @selector(toggleFetch), self, WFPrefBool(kFetchKey, NO)).toolTip = @"git fetch --all --prune in every repo before a review, so merged and upstream gone are current.";
    Item(set, @"Check Merged Pull Requests", @selector(togglePRs), self, WFPrefBool(kPRKey, NO)).toolTip = @"Asks gh, on your login, whether a branch that looks unmerged has a merged pull request.";
    Item(set, @"Ask Before Removing", @selector(toggleAsk), self, WFPrefBool(kAskKey, YES));
    Item(set, @"Launch at Login", @selector(toggleLogin), self, SMAppService.mainAppService.status == SMAppServiceStatusEnabled);
    Item(set, @"Edit Rules…", @selector(editRules), self, NO);
    Item(set, @"Rescan Now", @selector(rescan), self, NO);
    NSArray *mains = [all filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"isMain == YES"]];
    if (mains.count) {
        NSMenu *mm = [NSMenu new];
        for (WFTree *t in mains) [mm addItem:[self treeItem:t showRepo:NO]];
        Sub(set, @"Main Checkouts", mm);
    }
    [set addItem:NSMenuItem.separatorItem];
    Header(set, [NSString stringWithFormat:@"WorkForest %@ · scanned %@", NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"",
                 self.scanner.scannedAt ? [NSString stringWithFormat:@"%@ ago", Short(-self.scanner.scannedAt.timeIntervalSinceNow)] : @"now"]);
    Sub(menu, @"Settings", set);
    Item(menu, @"Quit WorkForest", @selector(quit), self, NO).keyEquivalent = @"q";
    return menu;
}

#pragma mark Actions

- (void)cleanUp { [self cleanUpConfirm:WFPrefBool(kAskKey, YES)]; }

- (void)cleanUpConfirm:(BOOL)confirm {
    NSArray<WFTree *> *c = WFCandidates(Linked(self.scanner.trees), self.review);
    if (!c.count || self.removing) return;
    if (confirm) {
        NSAlert *a = [NSAlert new];
        uint64_t disk = 0; for (WFTree *t in c) disk += t.diskBytes;
        a.messageText = [NSString stringWithFormat:@"Remove %@ (%@)?", Plural(c.count, @"stale worktree"), WFFormatBytes(disk)];
        NSMutableString *list = [NSMutableString new];
        for (WFTree *t in c) [list appendFormat:@"•  %@  %@\n     %@\n", Label(t), t.branch ?: @"", self.review.verdicts[t.path].reason ?: @""];
        [list appendString:@"\nEach is checked again first. Branches stay unless merged, ignored files such as .env are saved, and Recently Removed can restore each one."];
        a.informativeText = list;
        [a addButtonWithTitle:@"Remove Them"]; [a addButtonWithTitle:@"Cancel"];
        a.showsSuppressionButton = YES; a.suppressionButton.title = @"Don't ask again";
        [NSApp activateIgnoringOtherApps:YES];
        if ([a runModal] != NSAlertFirstButtonReturn) return;
        if (a.suppressionButton.state == NSControlStateValueOn) WFSetPref(kAskKey, @NO);
    }
    [self removePaths:[c valueForKey:@"path"] by:nil];
}

- (void)removePaths:(NSArray<NSString *> *)paths by:(NSString *)by {
    self.removing = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableArray *failed = [NSMutableArray new];
        for (NSString *p in paths) {
            NSString *err = nil;
            if (!WFRemove(p, by, self.review.verdicts[p].reason ?: @"removed from the menu", &err)) [failed addObject:[NSString stringWithFormat:@"%@: %@", WFTilde(p), err]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.removing = NO;
            if (failed.count) {
                NSAlert *a = [NSAlert new];
                a.messageText = [NSString stringWithFormat:@"%@ kept", Plural(failed.count, @"worktree")];
                a.informativeText = [failed componentsJoinedByString:@"\n"];
                [NSApp activateIgnoringOtherApps:YES]; [a runModal];
            }
            [self rescan];
        });
    });
}

- (void)removeOne:(NSMenuItem *)i {
    NSString *path = i.representedObject;
    if (WFPrefBool(kAskKey, YES)) {
        NSAlert *a = [NSAlert new];
        a.messageText = [NSString stringWithFormat:@"Remove the worktree %@?", WFTilde(path)];
        a.informativeText = @"It is checked again first. The branch stays unless it is merged, ignored files such as .env are saved, and Recently Removed can restore it.";
        [a addButtonWithTitle:@"Remove"]; [a addButtonWithTitle:@"Cancel"];
        [NSApp activateIgnoringOtherApps:YES];
        if ([a runModal] != NSAlertFirstButtonReturn) return;
    }
    [self removePaths:@[path] by:nil];
}

- (void)restore:(NSMenuItem *)i {
    NSString *err = WFRestore(i.representedObject);
    if (err) { NSAlert *a = [NSAlert new]; a.messageText = @"Could not restore"; a.informativeText = err; [NSApp activateIgnoringOtherApps:YES]; [a runModal]; }
    [self rescan];
}

- (void)toggleKeep:(NSMenuItem *)i {
    NSString *path = i.representedObject;
    WFSetKept(path, WFKeptUntil(path) ? nil : [NSDate dateWithTimeIntervalSinceNow:7 * 86400]);
}
- (void)prune:(NSMenuItem *)i { WFGitInput(i.representedObject, @[@"worktree", @"prune"], nil, 30, NULL); [self rescan]; }
- (void)clearRemoved { WFClearRemoved(); }
- (void)reveal:(NSMenuItem *)i { [NSWorkspace.sharedWorkspace selectFile:nil inFileViewerRootedAtPath:i.representedObject]; }
- (void)openTerminal:(NSMenuItem *)i {
    [NSWorkspace.sharedWorkspace openURLs:@[[NSURL fileURLWithPath:i.representedObject]] withApplicationAtURL:[NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.apple.Terminal"]
                            configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
}
- (void)openEditor:(NSMenuItem *)i {
    NSArray *a = i.representedObject;
    NSTask *t = [NSTask new]; t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"]; t.arguments = @[@"-a", a[1], a[0]];
    [t launchAndReturnError:nil];
}
- (void)copyPath:(NSMenuItem *)i { [NSPasteboard.generalPasteboard clearContents]; [NSPasteboard.generalPasteboard setString:i.representedObject forType:NSPasteboardTypeString]; }
- (void)toggleProtect:(NSMenuItem *)i {
    WFTree *t = [self.scanner treeAt:i.representedObject];
    [WFRules.shared setProtected:!t.isProtected path:i.representedObject];
    t.isProtected = !t.isProtected;
}
- (void)setReviewEvery:(NSMenuItem *)i { WFSetPref(kReviewMinKey, @(i.tag)); }
- (void)setModel:(NSMenuItem *)i       { WFSetPref(kModelKey, i.representedObject); }
- (void)setMode:(NSMenuItem *)i        { WFSetMode((WFMode)i.tag); }
- (void)toggleFetch                    { WFSetPref(kFetchKey, @(!WFPrefBool(kFetchKey, NO))); }
- (void)togglePRs                      { WFSetPref(kPRKey, @(!WFPrefBool(kPRKey, NO))); }
- (void)toggleAsk                      { WFSetPref(kAskKey, @(!WFPrefBool(kAskKey, YES))); }
- (void)editRules { [WFRules.shared reload]; [NSWorkspace.sharedWorkspace openURL:WFRules.shared.fileURL]; }
- (void)toggleLogin {
    SMAppService *s = SMAppService.mainAppService; NSError *e = nil;
    if (s.status == SMAppServiceStatusEnabled) [s unregisterAndReturnError:&e]; else [s registerAndReturnError:&e];
    if (e) NSBeep();
}
- (void)quit { [NSApp terminate:nil]; }

/// workforest://review | clean-up (with confirmation) | rescan | login-on | login-off | quit
- (void)application:(NSApplication *)app openURLs:(NSArray<NSURL *> *)urls {
    for (NSURL *u in urls) {
        NSString *c = u.host.lowercaseString ?: @"";
        if      ([c isEqualToString:@"review"])   [self reviewNow];
        else if ([c isEqualToString:@"clean-up"]) [self cleanUpConfirm:YES];
        else if ([c isEqualToString:@"rescan"])   [self rescan];
        else if ([c isEqualToString:@"login-on"] || [c isEqualToString:@"login-off"]) {
            BOOL want = [c isEqualToString:@"login-on"];
            if ((SMAppService.mainAppService.status == SMAppServiceStatusEnabled) != want) [self toggleLogin];
        }
        else if ([c isEqualToString:@"quit"])     [NSApp terminate:nil];
    }
}

@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc > 1 && argv[1][0] != '-') return RunCLI(argc, argv);    // CLI mode
        if (argc > 1 && (!strcmp(argv[1], "--help") || !strcmp(argv[1], "-h"))) return Usage();
        NSApplication *app = NSApplication.sharedApplication;
        WorkForest *delegate = [WorkForest new];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
