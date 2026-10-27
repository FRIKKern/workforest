#import "Review.h"
#import "Common.h"

static const NSTimeInterval kTimeout = 240;
static const NSUInteger kBatch = 25;            // worktrees per model call; a hundred in one call takes longer than kTimeout
static const long kParallel = 3;                // model calls at a time

NSArray<NSArray<NSString *> *> *WFModels(void) {
    return @[@[@"auto", @"Haiku or Luna"], @[@"haiku", @"Haiku"], @[@"sonnet", @"Sonnet"], @[@"opus", @"Opus"], @[@"luna", @"Luna"]];
}

NSString *WFModelLabel(NSString *alias) {
    for (NSArray *m in WFModels()) if ([m[0] isEqualToString:alias]) return m[1];
    if ([alias hasPrefix:@"gpt-"])   // gpt-6-luna reads GPT-6-Luna, as Codex names it
        return [@"GPT" stringByAppendingString:[alias substringFromIndex:3].capitalizedString];
    return alias;
}

static BOOL IsCodexModel(NSString *m) { return [m isEqualToString:@"luna"] || [m hasPrefix:@"gpt-"]; }

@implementation WFVerdict @end

@implementation WFReview

static NSString *ReviewPath(void) { return [WFSupportDir() stringByAppendingPathComponent:@"review.json"]; }

+ (instancetype)load {
    NSData *d = [NSData dataWithContentsOfFile:ReviewPath()];
    NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if (![j isKindOfClass:NSDictionary.class]) return nil;
    NSString *(^str)(NSString *) = ^NSString *(NSString *k) { return [j[k] isKindOfClass:NSString.class] ? j[k] : nil; };
    WFReview *r = [WFReview new];
    r.at = [NSDate dateWithTimeIntervalSince1970:[j[@"at"] doubleValue]];
    r.model = str(@"model"); r.error = str(@"error"); r.note = str(@"note");
    r.tokens = [j[@"tokens"] integerValue]; r.treeCount = [j[@"treeCount"] integerValue];
    r.seconds = [j[@"seconds"] doubleValue]; r.costUSD = [j[@"costUSD"] doubleValue];
    r.summary = str(@"summary"); r.trigger = str(@"trigger"); r.mode = str(@"mode"); r.judgeError = str(@"judgeError");
    r.actions = [j[@"actions"] isKindOfClass:NSArray.class] ? j[@"actions"] : @[];
    NSMutableDictionary *v = [NSMutableDictionary new];
    NSDictionary *trees = [j[@"trees"] isKindOfClass:NSDictionary.class] ? j[@"trees"] : @{};
    for (NSString *k in trees) {
        NSDictionary *x = trees[k];
        if (![x isKindOfClass:NSDictionary.class]) continue;
        WFVerdict *w = [WFVerdict new];
        w.verdict = x[@"verdict"]; w.about = x[@"about"]; w.reason = x[@"reason"]; w.what = x[@"what"]; w.why = x[@"why"];
        w.state = x[@"state"]; w.recommendation = x[@"recommendation"]; w.keepEvidence = x[@"keep_evidence"];
        w.judged = [x[@"judged"] boolValue]; w.confidence = [x[@"confidence"] doubleValue];
        v[k] = w;
    }
    r.verdicts = v;
    return r;
}

- (void)save {
    NSMutableDictionary *trees = [NSMutableDictionary new];
    for (NSString *k in self.verdicts) {
        WFVerdict *x = self.verdicts[k];
        trees[k] = @{@"verdict": x.verdict ?: @"unsure", @"confidence": @(x.confidence), @"about": x.about ?: @"", @"reason": x.reason ?: @"",
                     @"what": x.what ?: @"", @"why": x.why ?: @"", @"state": x.state ?: @"", @"recommendation": x.recommendation ?: @"",
                     @"keep_evidence": x.keepEvidence ?: @"", @"judged": @(x.judged)};
    }
    NSDictionary *j = @{@"at": @(self.at.timeIntervalSince1970), @"model": self.model ?: @"", @"error": self.error ?: NSNull.null,
                        @"note": self.note ?: NSNull.null, @"tokens": @(self.tokens), @"treeCount": @(self.treeCount),
                        @"seconds": @(self.seconds), @"costUSD": @(self.costUSD), @"trees": trees, @"summary": self.summary ?: NSNull.null,
                        @"trigger": self.trigger ?: NSNull.null, @"mode": self.mode ?: NSNull.null,
                        @"judgeError": self.judgeError ?: NSNull.null, @"actions": self.actions ?: @[]};
    [NSFileManager.defaultManager createDirectoryAtPath:WFSupportDir() withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSJSONSerialization dataWithJSONObject:j options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes error:nil]
        writeToFile:ReviewPath() atomically:YES];
}

@end

static NSString *const kSystem =
    @"You review the git worktrees on a developer's Mac and decide which ones are still wanted. The developer runs many coding agents "
    @"at once, each in its own worktree, so worktrees pile up after the agent finishes and the branch is merged or abandoned.\n\n"
    @"For every worktree return: id (copied exactly), verdict (active, stale or unsure), confidence from 0 to 1, "
    @"about (at most 12 words saying what the worktree is, for example \"checkout flow fix for acme-web, merged 9 days ago\"), "
    @"reason (one sentence naming the facts that decided it), and four plain sentences of at most 25 words each built only from the facts: "
    @"what (what the work on this branch was: the last commit subject, the agent session's title or first prompt), "
    @"why (why it still exists: who made it, and whether the task looks finished), "
    @"state (where the work stands: merged and how, upstream gone, commits only here, uncommitted files), "
    @"and recommendation (keep, remove or check, with the deciding fact).\n\n"
    @"Facts: merged says how the branch reached default_branch: ancestor (its commits are in it), tree (same files), "
    @"patch (rebased or cherry-picked), squash (one squash commit has its whole change), pr (a merged pull request). "
    @"upstream gone means the remote branch was deleted, usually after a merge. unpushed_commits are on no remote and not in the default branch: "
    @"removing the worktree keeps the branch, but they are the only copy if the branch is deleted. "
    @"newest_file_days_ago is the newest file outside .git and caches; quiet_days is the time since the last commit, file change or agent activity. "
    @"processes and servers run inside the worktree right now. agent_session is the latest Claude Code, Codex or pi session that ran in it or named it; "
    @"null means none was found, and you must not invent one. refs_fetched_days_ago says how fresh the remote information is: "
    @"when it is old or null, merged and upstream may be out of date, so prefer unsure over stale for unmerged work.\n\n"
    @"Evidence, strongest first:\n"
    @"- uncommitted or untracked files, a process or server inside, or an agent session active in the last day: active.\n"
    @"- merged (any kind) or upstream gone, and quiet for days: stale.\n"
    @"- not merged, unpushed commits, quiet for weeks: unsure, unless the last commit or session says the work was dropped.\n"
    @"- several worktrees for the same repo and task: the quiet ones are likely stale.\n"
    @"Say stale only when you would bet the developer will not miss it. Removing a worktree keeps its branch unless it is merged, "
    @"and WorkForest can recreate it, but untracked work in it would be lost. Return exactly one entry for every id.\n\n"
    @"keep_evidence: the one concrete fact that shows the work is still wanted, such as uncommitted files changed 2 hours ago, "
    @"a session active 3 hours ago, or a server running in it. Leave it empty when there is none. "
    @"That it exists, an unmerged branch nobody touched for weeks, or a recent fetch is not evidence.\n\n"
    @"summary: two or three plain sentences for the developer: which worktrees are merged or abandoned, which repos hold the most of them, "
    @"and which you would remove. WorkForest writes the totals itself, so do not count worktrees, repos or disk.";

static NSString *Schema(void) {
    NSMutableDictionary *props = [NSMutableDictionary new];
    for (NSString *k in @[@"id", @"about", @"reason", @"what", @"why", @"state", @"recommendation", @"keep_evidence"]) props[k] = @{@"type": @"string"};
    props[@"verdict"] = @{@"type": @"string", @"enum": @[@"active", @"stale", @"unsure"]};
    props[@"confidence"] = @{@"type": @"number"};
    NSDictionary *s = @{@"type": @"object", @"additionalProperties": @NO, @"required": @[@"trees", @"summary"],
                        @"properties": @{@"summary": @{@"type": @"string"}, @"trees": @{@"type": @"array", @"items": @{
                            @"type": @"object", @"additionalProperties": @NO, @"required": [props.allKeys sortedArrayUsingSelector:@selector(compare:)],
                            @"properties": props}}}};
    return [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:s options:NSJSONWritingSortedKeys error:nil] encoding:NSUTF8StringEncoding];
}

static NSString *const kSummary =
    @"You write the summary at the top of WorkForest, a menu bar app that watches the git worktrees on a developer's Mac. "
    @"Below is one line per worktree with the review's verdict. Write two or three plain sentences: which worktrees are merged or abandoned, "
    @"which repos hold the most of them, and which you would remove. WorkForest writes the totals itself, so do not count worktrees, repos or disk. "
    @"Name repos and branches, not paths.";

static NSString *const kJudge =
    @"You are the judge in WorkForest's Eager mode. Each git worktree below is quiet, has no uncommitted work, nothing running in it "
    @"and no recent agent session, and a first review was not sure enough to remove it. The burden of proof is on the worktree: "
    @"keep it only when a concrete fact shows that someone still wants it. Otherwise remove it. Removal keeps the branch unless it is merged, "
    @"and WorkForest can recreate the worktree at the same commit.\n\n"
    @"Evidence that counts: work that is not merged and was committed in the last two weeks, an agent session that named it in the last few days, "
    @"a branch name or commit subject that says the work is ongoing or parked on purpose (wip, keep, parked, draft), "
    @"or a worktree that is the only place a branch is checked out while its pull request is still open.\n"
    @"Not evidence: that it exists, that its branch has commits nobody touched for weeks, that it might be useful someday, "
    @"or caches such as node_modules.\n\n"
    @"first_review is the first pass, for reference. Weigh the facts, not its verdict. "
    @"For every worktree return: id (copied exactly), decision (keep or remove), confidence from 0 to 1, "
    @"evidence (the deciding fact for keep, empty for remove), and reason (one plain sentence naming the facts). Return exactly one entry for every id.";

static NSString *JudgeSchema(void) {
    NSDictionary *s = @{@"type": @"object", @"additionalProperties": @NO, @"required": @[@"trees"], @"properties": @{@"trees": @{@"type": @"array", @"items": @{
        @"type": @"object", @"additionalProperties": @NO, @"required": @[@"confidence", @"decision", @"evidence", @"id", @"reason"],
        @"properties": @{@"id": @{@"type": @"string"}, @"decision": @{@"type": @"string", @"enum": @[@"keep", @"remove"]},
                         @"confidence": @{@"type": @"number"}, @"evidence": @{@"type": @"string"}, @"reason": @{@"type": @"string"}}}}}};
    return [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:s options:NSJSONWritingSortedKeys error:nil] encoding:NSUTF8StringEncoding];
}

/// A CLI by name: the test variable, the setting, the usual install paths, then a login shell's PATH.
static NSString *FindTool(NSString *name, NSString *envKey, NSString *prefKey, NSArray<NSString *> *paths) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *env = NSProcessInfo.processInfo.environment[envKey];
    if (env.length) return env;
    id pref = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)prefKey, CFSTR("no.guerrilla.workforest")));
    if ([pref isKindOfClass:NSString.class] && [fm isExecutableFileAtPath:pref]) return pref;
    for (NSString *p in paths)
        if ([fm isExecutableFileAtPath:p.stringByExpandingTildeInPath]) return p.stringByExpandingTildeInPath;
    // Last resort: ask a login shell, which knows the user's PATH. whence -p skips aliases.
    NSTask *t = [NSTask new]; NSPipe *out = [NSPipe pipe];
    t.executableURL = [NSURL fileURLWithPath:@"/bin/zsh"]; t.arguments = @[@"-lc", [@"whence -p " stringByAppendingString:name]];
    t.standardOutput = out; t.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![t launchAndReturnError:nil]) return nil;
    [t waitUntilExit];
    NSString *p = [[[NSString alloc] initWithData:[out.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding]
                   stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [fm isExecutableFileAtPath:p] ? p : nil;
}

/// Runs a CLI with the prompt on stdin, in the support folder, with the given variables removed.
/// Returns NO with *error set when it could not start or did not finish in time.
static BOOL Run(NSString *path, NSArray *args, NSData *input, BOOL (^drop)(NSString *key), NSData **outData, NSData **errData, int *status, NSString **error) {
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:path];
    t.arguments = args;
    NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
    for (NSString *k in env.allKeys) if (drop(k)) [env removeObjectForKey:k];
    env[@"PATH"] = [NSString stringWithFormat:@"%@:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", [@"~/.local/bin" stringByExpandingTildeInPath]];
    t.environment = env;
    [NSFileManager.defaultManager createDirectoryAtPath:WFSupportDir() withIntermediateDirectories:YES attributes:nil error:nil];
    t.currentDirectoryURL = [NSURL fileURLWithPath:WFSupportDir()];   // no project CLAUDE.md or AGENTS.md is picked up
    NSPipe *in = [NSPipe pipe], *out = [NSPipe pipe], *err = [NSPipe pipe];
    t.standardInput = in; t.standardOutput = out; t.standardError = err;
    NSError *e = nil;
    if (![t launchAndReturnError:&e]) { *error = [NSString stringWithFormat:@"could not start %@: %@", path.lastPathComponent, e.localizedDescription]; return NO; }
    [in.fileHandleForWriting writeData:input];
    [in.fileHandleForWriting closeFile];

    __block NSData *o = nil, *x = nil;
    dispatch_group_t g = dispatch_group_create();
    dispatch_group_async(g, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ o = [out.fileHandleForReading readDataToEndOfFile]; });
    dispatch_group_async(g, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ x = [err.fileHandleForReading readDataToEndOfFile]; });
    if (dispatch_group_wait(g, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kTimeout * NSEC_PER_SEC))) != 0) {
        [t terminate];
        *error = [NSString stringWithFormat:@"%@ did not answer within %.0f seconds", path.lastPathComponent, kTimeout];
        return NO;
    }
    [t waitUntilExit];
    *outData = o; *errData = x; *status = t.terminationStatus;
    return YES;
}

static NSString *Trimmed(NSData *d, NSUInteger max) {
    NSString *s = [[[NSString alloc] initWithData:d ?: NSData.data encoding:NSUTF8StringEncoding] ?: @""
                   stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return s.length > max ? [s substringToIndex:max] : s;
}

/// Claude through `claude -p`. Returns the structured answer, or nil with r.error set.
static NSDictionary *AskClaude(WFReview *r, NSString *claude, NSString *model, NSString *system, NSString *schema, NSData *prompt) {
    NSArray *args = @[@"-p", @"--model", model, @"--output-format", @"json", @"--json-schema", schema, @"--tools", @"",
                      @"--no-session-persistence", @"--strict-mcp-config", @"--setting-sources", @"", @"--system-prompt", system];
    // The user's own Claude login, never an API key from the environment, and not a nested session of the agent that launched us.
    NSArray *dropped = @[@"ANTHROPIC_API_KEY", @"ANTHROPIC_AUTH_TOKEN", @"CLAUDECODE", @"CLAUDE_CODE_ENTRYPOINT", @"CLAUDE_CODE_SSE_PORT"];
    NSData *out, *err; int status; NSString *e = nil;
    r.model = model;
    if (!Run(claude, args, prompt, ^BOOL(NSString *k) { return [dropped containsObject:k]; }, &out, &err, &status, &e)) { r.error = e; return nil; }

    NSDictionary *j = out.length ? [NSJSONSerialization JSONObjectWithData:out options:0 error:nil] : nil;
    if (![j isKindOfClass:NSDictionary.class]) {
        NSString *msg = Trimmed(err.length ? err : out, 300);
        r.error = msg.length ? msg : [NSString stringWithFormat:@"claude exited with status %d", status];
        return nil;
    }
    NSDictionary *u = j[@"usage"];
    r.tokens = [u[@"input_tokens"] integerValue] + [u[@"output_tokens"] integerValue] +
               [u[@"cache_creation_input_tokens"] integerValue] + [u[@"cache_read_input_tokens"] integerValue];
    r.costUSD = [j[@"total_cost_usd"] doubleValue];
    if ([j[@"is_error"] boolValue]) { r.error = [j[@"result"] description] ?: @"claude reported an error"; return nil; }
    id so = j[@"structured_output"];
    if (![so isKindOfClass:NSDictionary.class]) {
        NSData *d = [[j[@"result"] description] dataUsingEncoding:NSUTF8StringEncoding];
        so = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    }
    if (![so isKindOfClass:NSDictionary.class]) { r.error = @"the answer did not match the schema"; return nil; }
    return so;
}

/// The Luna models Codex offers this account, newest first as Codex lists them, then the known names.
static NSArray<NSString *> *LunaModels(void) {
    NSString *home = NSProcessInfo.processInfo.environment[@"CODEX_HOME"] ?: [@"~/.codex" stringByExpandingTildeInPath];
    NSData *d = [NSData dataWithContentsOfFile:[home stringByAppendingPathComponent:@"models_cache.json"]];
    NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    NSMutableArray *l = [NSMutableArray new];
    if ([j isKindOfClass:NSDictionary.class] && [j[@"models"] isKindOfClass:NSArray.class])
        for (NSDictionary *m in j[@"models"])
            if ([m isKindOfClass:NSDictionary.class] && [m[@"slug"] isKindOfClass:NSString.class] && [m[@"slug"] containsString:@"luna"]) [l addObject:m[@"slug"]];
    for (NSString *m in @[@"gpt-6-luna", @"gpt-5.6-luna"]) if (![l containsObject:m]) [l addObject:m];
    return l;
}

/// A TOML basic string, for codex -c key=value.
static NSString *TOMLString(NSString *s) {
    s = [s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    s = [s stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    return [NSString stringWithFormat:@"\"%@\"", s];
}

/// The message inside a codex error, which is often an API error body as JSON.
static NSString *CodexMessage(NSString *m) {
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:[m dataUsingEncoding:NSUTF8StringEncoding] ?: NSData.data options:0 error:nil];
    if ([j isKindOfClass:NSDictionary.class] && [j[@"error"] isKindOfClass:NSDictionary.class] && [j[@"error"][@"message"] isKindOfClass:NSString.class])
        return j[@"error"][@"message"];
    return m;
}

/// OpenAI through `codex exec`. Every tool is turned off and the sandbox is read-only, so the model only answers.
static NSDictionary *AskCodexModel(WFReview *r, NSString *codex, NSString *model, NSString *system, NSString *schemaText, NSData *prompt) {
    NSString *dir = WFSupportDir();
    NSString *tag = [NSUUID.UUID.UUIDString substringToIndex:8];   // batches run side by side, each with its own files
    NSString *schema = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"review-schema-%@.json", tag]];
    NSString *answer = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"review-answer-%@.json", tag]];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [schemaText writeToFile:schema atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [NSFileManager.defaultManager removeItemAtPath:answer error:nil];
    NSMutableArray *args = [@[@"exec", @"--model", model, @"--json", @"--output-schema", schema, @"--output-last-message", answer,
                              @"--sandbox", @"read-only", @"--skip-git-repo-check", @"--ephemeral", @"--ignore-user-config", @"--ignore-rules",
                              @"-c", @"model_reasoning_effort=\"low\"", @"-c", @"web_search=\"disabled\"", @"-c", @"approval_policy=\"never\"",
                              @"-c", @"include_apply_patch_tool=false", @"-c", @"features.multi_agent=false",
                              @"-c", [@"developer_instructions=" stringByAppendingString:TOMLString(system)]] mutableCopy];
    for (NSString *f in @[@"shell_tool", @"unified_exec", @"apps", @"plugins", @"browser_use", @"computer_use", @"image_generation",
                          @"multi_agent", @"hooks", @"view_image", @"skill_search", @"tool_suggest", @"goals", @"sleep_tool"])
        [args addObjectsFromArray:@[@"--disable", f]];
    [args addObject:@"-"];
    // The user's ChatGPT login from ~/.codex, never an API key from the environment, and not a nested session of a running Codex.
    NSData *out, *err; int status; NSString *e = nil;
    r.model = model;
    BOOL ran = Run(codex, args, prompt, ^BOOL(NSString *k) {
        return [@[@"OPENAI_API_KEY", @"OPENAI_BASE_URL"] containsObject:k] || ([k hasPrefix:@"CODEX_"] && ![k isEqualToString:@"CODEX_HOME"]);
    }, &out, &err, &status, &e);
    if (!ran) { r.error = e; return nil; }

    NSString *failure = nil;
    for (NSString *line in [[[NSString alloc] initWithData:out ?: NSData.data encoding:NSUTF8StringEncoding] componentsSeparatedByString:@"\n"]) {
        NSDictionary *ev = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] ?: NSData.data options:0 error:nil];
        if (![ev isKindOfClass:NSDictionary.class]) continue;
        if ([ev[@"type"] isEqual:@"turn.completed"]) {
            NSDictionary *u = ev[@"usage"];
            r.tokens += [u[@"input_tokens"] integerValue] + [u[@"output_tokens"] integerValue];
        } else if ([ev[@"type"] isEqual:@"turn.failed"] && [ev[@"error"][@"message"] isKindOfClass:NSString.class]) {
            failure = CodexMessage(ev[@"error"][@"message"]);
        } else if ([ev[@"type"] isEqual:@"error"] && [ev[@"message"] isKindOfClass:NSString.class]) {
            failure = failure ?: CodexMessage(ev[@"message"]);
        }
    }
    NSData *d = [NSData dataWithContentsOfFile:answer];
    [NSFileManager.defaultManager removeItemAtPath:answer error:nil];
    [NSFileManager.defaultManager removeItemAtPath:schema error:nil];
    id so = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if ([so isKindOfClass:NSDictionary.class]) return so;
    NSString *msg = failure ?: Trimmed(err, 300);
    r.error = msg.length ? [msg substringToIndex:MIN(300, msg.length)] : [NSString stringWithFormat:@"codex exited with status %d", status];
    return nil;
}

/// "luna" tries each Luna model this account offers, moving on only when the account cannot use that model.
static NSDictionary *AskCodex(WFReview *r, NSString *codex, NSString *model, NSString *system, NSString *schema, NSData *prompt) {
    NSArray *models = [model isEqualToString:@"luna"] ? LunaModels() : @[model];
    for (NSString *m in models) {
        r.error = nil;
        NSDictionary *so = AskCodexModel(r, codex, m, system, schema, prompt);
        if (so) return so;
        if (!([r.error containsString:@"not supported"] || [r.error containsString:@"model_not_found"] || [r.error containsString:@"does not exist"])) return nil;
    }
    return nil;
}

/// One structured answer from the chosen model. "auto" asks Haiku, then Luna when Haiku can't answer.
/// Sets r.model to the model that answered, r.note when Haiku was skipped, and r.error when nothing answered.
static NSDictionary *Ask(WFReview *r, NSString *model, NSString *system, NSString *schema, NSData *prompt) {
    NSDictionary *so = nil;
    if ([model isEqualToString:@"auto"]) {
        // Haiku first. Luna when claude is missing, signed out, out of usage or fails in any other way.
        NSString *claude = [WFReviewer claudePath], *codex = nil;
        if (claude) so = AskClaude(r, claude, @"haiku", system, schema, prompt);
        if (!so) {
            NSString *why = claude ? r.error : @"claude CLI not found";
            r.note = [NSString stringWithFormat:@"Haiku: %@", why];
            r.error = nil; r.tokens = 0; r.costUSD = 0;
            if ((codex = [WFReviewer codexPath])) so = AskCodex(r, codex, @"luna", system, schema, prompt);
            else r.error = @"codex CLI not found";
            if (!so) r.error = [NSString stringWithFormat:@"%@. Luna: %@", r.note, r.error];
        }
    } else if (IsCodexModel(model)) {
        NSString *codex = [WFReviewer codexPath];
        if (codex) so = AskCodex(r, codex, model, system, schema, prompt);
        else r.error = @"codex CLI not found. Install Codex and sign in, or set workforest.codexPath.";
    } else {
        NSString *claude = [WFReviewer claudePath];
        if (claude) so = AskClaude(r, claude, model, system, schema, prompt);
        else r.error = @"claude CLI not found. Install Claude Code and sign in, or set workforest.claudePath.";
    }
    return so;
}


@implementation WFReviewer

+ (NSString *)claudePath {
    return FindTool(@"claude", @"WORKFOREST_CLAUDE", @"workforest.claudePath",
                    @[@"~/.local/bin/claude", @"~/.claude/local/claude", @"/opt/homebrew/bin/claude", @"/usr/local/bin/claude", @"~/.npm-global/bin/claude", @"~/.bun/bin/claude"]);
}

+ (NSString *)codexPath {
    return FindTool(@"codex", @"WORKFOREST_CODEX", @"workforest.codexPath",
                    @[@"~/.local/bin/codex", @"/opt/homebrew/bin/codex", @"/usr/local/bin/codex", @"~/.npm-global/bin/codex", @"~/.bun/bin/codex"]);
}

+ (NSString *)idFor:(WFTree *)t { return WFTilde(t.path); }

static id DaysAgo(NSDate *d) { return d ? @(round(-d.timeIntervalSinceNow / 8640) / 10) : NSNull.null; }

+ (NSArray<NSDictionary *> *)factsFor:(NSArray<WFTree *> *)trees {
    NSMutableArray *facts = [NSMutableArray new];
    for (WFTree *t in trees) {
        NSMutableDictionary *f = [@{@"id": [self idFor:t], @"repo": t.repoName ?: @"", @"folder": t.name, @"branch": t.branch ?: NSNull.null,
                                    @"main_checkout": @(t.isMain), @"locked": @(t.locked), @"detached": @(t.detached), @"missing_folder": @(t.prunable),
                                    @"default_branch": t.defaultBranch ?: NSNull.null, @"protected": @(t.isProtected),
                                    @"dirty_files": @(t.dirty), @"untracked_files": @(t.untracked), @"stashes": @(t.stashes),
                                    @"unpushed_commits": @(t.unpushed), @"commits_not_in_default": @(t.notInDefault),
                                    @"merged": t.merged ?: NSNull.null, @"upstream": t.upstream ?: NSNull.null,
                                    @"ahead": @(t.ahead), @"behind": @(t.behind), @"refs_fetched_days_ago": DaysAgo(t.fetched),
                                    @"created_days_ago": DaysAgo(t.created), @"newest_file_days_ago": DaysAgo(t.touched),
                                    @"quiet_days": DaysAgo(t.lastWork),
                                    @"disk_mb": @(t.diskBytes >> 20), @"cache_mb": @(t.cacheBytes >> 20), @"files": @(t.files)} mutableCopy];
        if (t.detached) f[@"orphan_commits"] = @(t.orphanCommits);
        if (t.pr) f[@"pull_request"] = t.pr;
        f[@"last_commit"] = t.lastCommit ? @{@"subject": WFClip(t.lastSubject, 200) ?: @"", @"author": WFClip(t.lastAuthor, 60) ?: @"",
                                             @"days_ago": DaysAgo(t.lastCommit)} : NSNull.null;
        NSMutableArray *procs = [NSMutableArray new];
        for (NSString *p in t.processes) [procs addObject:[p componentsSeparatedByString:@" (pid"].firstObject];
        f[@"processes"] = procs;
        f[@"servers"] = t.servers ?: @[];
        if (t.session) {
            NSMutableDictionary *s = [t.session mutableCopy];
            [s removeObjectForKey:@"file"];   // a local path, not evidence
            f[@"agent_session"] = s;
        } else f[@"agent_session"] = NSNull.null;
        [facts addObject:f];
    }
    return facts;
}

static NSData *Prompt(NSDictionary *input) {
    return [NSJSONSerialization dataWithJSONObject:input options:NSJSONWritingPrettyPrinted | NSJSONWritingWithoutEscapingSlashes error:nil];
}

static NSString *Now(void) {
    return [NSISO8601DateFormatter stringFromDate:NSDate.date timeZone:NSTimeZone.localTimeZone formatOptions:NSISO8601DateFormatWithInternetDateTime];
}

/// Runs one call per batch of kBatch, kParallel at a time. Each answer goes through parse with its own scratch review,
/// whose model, note, tokens and error are folded into r. Returns NO when any batch failed, with r.error naming it.
static BOOL Batches(NSArray<WFTree *> *trees, WFReview *r, NSString *model, NSString *system, NSString *schema,
                    NSDictionary *(^input)(NSArray<WFTree *> *), void (^parse)(NSDictionary *so, NSArray<WFTree *> *batch)) {
    NSUInteger size = NSProcessInfo.processInfo.environment[@"WORKFOREST_BATCH"].integerValue ?: kBatch;   // tests use small batches
    NSMutableArray *batches = [NSMutableArray new];
    for (NSUInteger i = 0; i < trees.count; i += size) [batches addObject:[trees subarrayWithRange:NSMakeRange(i, MIN(size, trees.count - i))]];
    dispatch_semaphore_t gate = dispatch_semaphore_create(kParallel);
    __block BOOL ok = YES;
    dispatch_apply(batches.count, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(size_t i) {
        dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER);
        WFReview *one = [WFReview new];
        NSDictionary *so = Ask(one, model, system, schema, Prompt(input(batches[i])));
        dispatch_semaphore_signal(gate);
        @synchronized (r) {
            r.tokens += one.tokens; r.costUSD += one.costUSD;
            if (one.model) r.model = one.model;
            if (one.note && !r.note) r.note = one.note;
            if (so) parse(so, batches[i]);
            else { ok = NO; if (!r.error) r.error = batches.count > 1 ? [NSString stringWithFormat:@"batch %zu of %lu: %@", i + 1, (unsigned long)batches.count, one.error] : one.error; }
        }
    });
    return ok;
}

+ (WFReview *)review:(NSArray<WFTree *> *)trees model:(NSString *)model {
    WFReview *r = [WFReview new];
    r.at = NSDate.date; r.model = model; r.treeCount = trees.count; r.verdicts = @{};
    if (!trees.count) return r;
    NSMutableDictionary *v = [NSMutableDictionary new];
    NSMutableArray *summaries = [NSMutableArray new];
    Batches(trees, r, model, kSystem, Schema(), ^NSDictionary *(NSArray<WFTree *> *batch) {
        return @{@"now": Now(), @"worktrees": [self factsFor:batch]};
    }, ^(NSDictionary *so, NSArray<WFTree *> *batch) {
        NSMutableDictionary *byId = [NSMutableDictionary new];
        for (WFTree *t in batch) byId[[self idFor:t]] = t.path;
        for (NSDictionary *x in [so[@"trees"] isKindOfClass:NSArray.class] ? so[@"trees"] : @[]) {
            if (![x isKindOfClass:NSDictionary.class] || ![x[@"id"] isKindOfClass:NSString.class] || !byId[x[@"id"]]) continue;
            WFVerdict *w = [WFVerdict new];
            w.verdict = [@[@"active", @"stale", @"unsure"] containsObject:x[@"verdict"]] ? x[@"verdict"] : @"unsure";
            w.confidence = MAX(0, MIN(1, [x[@"confidence"] doubleValue]));
            w.about = [x[@"about"] description]; w.reason = [x[@"reason"] description]; w.what = [x[@"what"] description];
            w.why = [x[@"why"] description]; w.state = [x[@"state"] description]; w.recommendation = [x[@"recommendation"] description];
            w.keepEvidence = [x[@"keep_evidence"] isKindOfClass:NSString.class] ? x[@"keep_evidence"] : @"";
            v[byId[x[@"id"]]] = w;
        }
        if ([so[@"summary"] isKindOfClass:NSString.class]) [summaries addObject:so[@"summary"]];
    });
    r.verdicts = v;
    // The totals are counted here, not by the model: it miscounted 99 worktrees as 92 in a real run.
    uint64_t allDisk = 0, allCache = 0;
    for (WFTree *t in trees) { allDisk += t.diskBytes; allCache += t.cacheBytes; }
    NSUInteger repoCount = [[NSSet setWithArray:[trees valueForKey:@"repo"]] count];
    NSString *totals = [NSString stringWithFormat:@"%lu worktree%@ in %lu repo%@ hold %@, %@ of it caches such as node_modules.",
                        (unsigned long)trees.count, trees.count == 1 ? @"" : @"s", (unsigned long)repoCount, repoCount == 1 ? @"" : @"s",
                        WFFormatBytes(allDisk), WFFormatBytes(allCache)];
    if (summaries.count == 1 || r.error) r.summary = summaries.firstObject;
    else if (summaries.count) {
        // Several batches: one more short call sees every worktree as a line and writes the summary for all of them.
        NSMutableArray *rows = [NSMutableArray new];
        for (WFTree *t in trees) {
            WFVerdict *w = v[t.path];
            [rows addObject:@{@"repo": t.repoName ?: @"", @"branch": t.branch ?: @"(detached)", @"verdict": w.verdict ?: @"none", @"about": w.about ?: @"",
                              @"merged": t.merged ?: NSNull.null, @"quiet_days": @(round(t.quiet / 8640) / 10), @"disk_mb": @(t.diskBytes >> 20), @"cache_mb": @(t.cacheBytes >> 20)}];
        }
        NSDictionary *input = @{@"lines": rows};
        NSDictionary *sumSchema = @{@"type": @"object", @"additionalProperties": @NO, @"required": @[@"summary"], @"properties": @{@"summary": @{@"type": @"string"}}};
        NSString *schema = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:sumSchema options:0 error:nil] encoding:NSUTF8StringEncoding];
        WFReview *one = [WFReview new];
        NSDictionary *so = Ask(one, model, kSummary, schema, Prompt(input));
        r.tokens += one.tokens; r.costUSD += one.costUSD;
        r.summary = [so[@"summary"] isKindOfClass:NSString.class] ? so[@"summary"] : [summaries componentsJoinedByString:@" "];
    }
    r.summary = r.summary.length ? [NSString stringWithFormat:@"%@ %@", totals, r.summary] : totals;
    if (!r.error && v.count < trees.count) r.error = [NSString stringWithFormat:@"the answer covered %lu of %lu worktrees", (unsigned long)v.count, (unsigned long)trees.count];
    r.seconds = -r.at.timeIntervalSinceNow;
    return r;
}

+ (void)judge:(NSArray<WFTree *> *)trees review:(WFReview *)r model:(NSString *)model {
    if (!trees.count) return;
    // A scratch review carries the judge's own model, tokens and error; the totals are added to r.
    WFReview *j = [WFReview new];
    NSDate *start = NSDate.date;
    NSMutableDictionary *v = [r.verdicts mutableCopy];
    BOOL ok = Batches(trees, j, model, kJudge, JudgeSchema(), ^NSDictionary *(NSArray<WFTree *> *batch) {
        NSMutableArray *facts = [[self factsFor:batch] mutableCopy];
        for (NSUInteger i = 0; i < facts.count; i++) {
            WFVerdict *w = r.verdicts[batch[i].path];
            NSMutableDictionary *f = [facts[i] mutableCopy];
            f[@"first_review"] = w ? @{@"verdict": w.verdict ?: @"unsure", @"confidence": @(w.confidence), @"reason": w.reason ?: @"",
                                       @"keep_evidence": w.keepEvidence ?: @""} : NSNull.null;
            facts[i] = f;
        }
        return @{@"now": Now(), @"worktrees": facts};
    }, ^(NSDictionary *so, NSArray<WFTree *> *batch) {
        NSMutableDictionary *byId = [NSMutableDictionary new];
        for (WFTree *t in batch) byId[[self idFor:t]] = t.path;
        for (NSDictionary *x in [so[@"trees"] isKindOfClass:NSArray.class] ? so[@"trees"] : @[]) {
            if (![x isKindOfClass:NSDictionary.class] || ![x[@"id"] isKindOfClass:NSString.class] || !byId[x[@"id"]] ||
                ![@[@"keep", @"remove"] containsObject:x[@"decision"]]) continue;
            NSString *path = byId[x[@"id"]];
            WFVerdict *old = v[path], *w = [WFVerdict new];
            w.about = old.about; w.what = old.what; w.why = old.why; w.state = old.state; w.recommendation = old.recommendation;
            BOOL keep = [x[@"decision"] isEqualToString:@"keep"];
            w.verdict = keep ? @"active" : @"stale";
            w.confidence = MAX(0, MIN(1, [x[@"confidence"] doubleValue]));
            w.keepEvidence = keep && [x[@"evidence"] isKindOfClass:NSString.class] ? x[@"evidence"] : @"";
            w.reason = [x[@"reason"] description];
            w.judged = YES;
            v[path] = w;
        }
    });
    r.verdicts = v;
    r.tokens += j.tokens; r.costUSD += j.costUSD; r.seconds += -start.timeIntervalSinceNow;
    if (!ok) r.judgeError = j.error ?: @"the answer did not match the schema";
}

@end
