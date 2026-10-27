# For AI agents working in this repo

**Build and verify**

```sh
./build.sh                       # universal build, installs ~/Applications/WorkForest.app and ~/.local/bin/workforest
workforest list                  # read-only: every worktree and its state
workforest auto --dry-run        # read-only: what the mode would remove
./test.sh                        # fixtures only: a repo with twelve worktrees in a temp folder, fake claude and codex
```

Never run `workforest auto` without `--dry-run`, `clean-up`, `remove` or `prune` on real repos while developing. Test them with `./test.sh`, which scans only its own temporary folder.

**Layout**
- `Sources/Common.m`: formatting, redaction, paths through `realpath`, and the read-only git runner.
- `Sources/Rules.m`: `rules.json`, which holds scan roots, protected paths and branches, ignored paths and cache folder names.
- `Sources/Trees.m`: discovery, git facts, merge detection, disk walks, processes, LocoHost servers, agent sessions, and the caches in `facts.json`, `sizes.json` and `patch-ids.json`.
- `Sources/Review.m`: the facts sent to the model, the claude and codex calls copied from LocoHost, batching, the summary and the judge.
- `Sources/Forest.m`: the decisions (`WFWorkKeeps`, `WFMustKeep`, `WFPlan`, `WFJudgeSubjects`, `WFCandidates`), the grace period, and removal and restore (`WFRemove`, `WFRestore`).
- `Sources/main.m`: the CLI (`RunCLI`), the review triggers (`watchEvents`) and the menu bar UI.
- `tools/`: `mkicon.m` renders the icon. The fakes for tests are `fakeclaude.py`, `fakecodex.py` and `fakeanswer.py`. `tools/render.m` renders the menu and hover cards offscreen to PNG, as [docs/RENDER.md](docs/RENDER.md) describes.

**The menu** is a native NSMenu, kept that way on purpose. Text meant to be read is a custom view in secondaryLabelColor (`TextItem`, `Para`), never a disabled item, which macOS greys out. Rows use title, subtitle and badge from macOS 14.4, with a one-line fallback. Each row's submenu starts with one card (`cardFor:`), whose status (`statusFor:`) says in plain words why the worktree stays or when it goes. Use tail truncation only. No decorative SF Symbols on items. After a change to the menu, render it with `tools/render.m` and look at the PNGs.

**Invariants that must hold after any change**

1. `WFRemove` is the only way a worktree is removed. It reads the worktree again with no cache and refuses when `WFWorkKeeps` gives a reason. It runs `git worktree remove` without `--force`, and deletes a branch only with `git branch -d` when the worktree is merged. Never `--force`, never `-D`, never `rm -rf` on a worktree.
2. `WFWorkKeeps` holds in every mode and for every caller. It covers:
   - the main checkout, a locked, protected, kept (`kept.json`) or missing worktree, and unread facts
   - uncommitted or untracked files, or failed status
   - commits on no remote that are not merged, and detached commits no branch holds
   - a process or localhost inside
   - an agent session or file change in the last day, and a worktree made in the last day
3. `WFPlan` is the only way a mode removes anything, and `WFAutoRemove` is the only caller that acts on it. Idle removes nothing. Proactive removes only merged or upstream-gone worktrees quiet for `ProactiveQuiet`. Eager removes a stale verdict of at least `kSureConfidence`, or a judged stale of at least `kMinConfidence`. No mode acts before `WFGraceOver`, which needs the app's first launch or a real `workforest auto` and then a day.
4. Before removal, ignored files outside the cache list are copied to the support folder, and `removed.json` records the repo, path, branch, commit and saved files. `WFRestore` must be able to recreate every recorded removal whose commit still exists.
5. Scanning is read-only. Every git command runs with `GIT_OPTIONAL_LOCKS=0` and no prompts, and nothing fetches unless the user turned on *Fetch Before Each Review* or ran `workforest fetch`. Caches only speed up display. The fresh read before a removal decides.
6. The review sends only `+[WFReviewer factsFor:]`, plus the first verdict for the judge and one line per worktree for the summary. Commit subjects, authors, session titles and prompts go through `WFClip`, which redacts and caps them. File contents, environment variables and session log paths are never sent.
7. The review runs on the user's own login, as in LocoHost. For claude, API keys are removed and tools are disabled with `--tools ""`. For codex, `OPENAI_API_KEY` and `CODEX_*` except `CODEX_HOME` are removed, the sandbox is read-only, the user config is ignored and every tool feature is disabled. The fakes fail a test when one of those flags is missing or a key reaches them.
8. Paths are compared as `realpath` gives them. Never use `stringByStandardizingPath`, which turns `/private/var` into `/var` and breaks the match with git, the kernel and session logs.
9. Builds with clang alone. No Swift, no packages, no Xcode project.

**Test hooks**
- `WORKFOREST_HOME` moves every state file.
- `WORKFOREST_ROOTS` replaces the scan roots. `test.sh` always sets it, so no real repo is scanned.
- `WORKFOREST_CLAUDE` and `WORKFOREST_CODEX` replace the two CLIs. `WORKFOREST_LOCOHOST` replaces the locohost CLI, and the tests point it at nothing.
- `WORKFOREST_GRACE_HOURS`, `WORKFOREST_RECENT_HOURS` and `WORKFOREST_PROACTIVE_HOURS` change the day of grace, the day of recent activity and Proactive's week.
- `WORKFOREST_BATCH` changes the batch size. `WORKFOREST_DEBUG` prints how long each scan phase took.
- `CLAUDE_CONFIG_DIR` and `CODEX_HOME` move the session logs, and `GIT_CONFIG_GLOBAL=/dev/null` keeps the user's git config out of the fixtures.

**Using WorkForest from an agent**: `workforest explain .` tells you whether the current worktree is still wanted and whether its branch is merged. Ask the user before any command that removes, and never remove a worktree another agent works in without saying so.
