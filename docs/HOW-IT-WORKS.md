# How WorkForest works

## Finding worktrees

WorkForest looks in the folders listed under `roots` in the [rules file](RULES.md), three levels deep. A folder with a `.git` folder is a main checkout. A folder with a `.git` file is a linked worktree, and the file names its repo. WorkForest skips hidden folders and caches such as node_modules, and does not look inside repos. A root that is itself a repo, such as a folder of projects under git, is still searched.

For every repo it runs `git worktree list --porcelain`. That also finds the worktrees outside the roots, such as `.claude/worktrees`, `*.worktrees` folders next to the repo, and `~/.cursor/worktrees`. Main checkouts are listed but never removed.

Every git command runs with `GIT_OPTIONAL_LOCKS=0` and no prompts, so a scan never writes to a repo. WorkForest does not fetch unless *Fetch Before Each Review* is on. Without a fetch, merged and upstream gone are as fresh as your last `git fetch`, and the facts say how old that is.

## What it reads

For each worktree:

- **History.** The last commit's subject, author and date. The default branch is `origin/HEAD`, or else the first of `origin/main`, `origin/master`, `main` and `master` that exists.
- **Merged.** One of these, in order:
  - *ancestor*: every commit is in the default branch
  - *tree*: the files are the same as the default branch
  - *patch*: `git cherry` finds every commit in it, after a rebase or cherry-pick
  - *squash*: the branch's whole change, as one patch-id, matches one of the newest 400 commits on the default branch
  - *pr*: `gh` finds a merged pull request for the branch, when *Check Merged Pull Requests* is on
- **Upstream.** The remote branch, ahead and behind, or *gone* when the remote branch was deleted, usually after a merge.
- **What would be lost.**
  - uncommitted and untracked files, from `git status`
  - commits on no remote and not in the default branch
  - for a detached worktree, commits that no branch, tag or remote holds
  - stashes made on the branch
- **Disk.** The allocated size, the part inside cache folders, the file count, and the newest change outside `.git` and caches. Folder times count, so an added or deleted file shows.
- **Who is in it.**
  - every process of yours with its working folder inside, through `libproc`
  - LocoHost's localhosts running there, through `locohost list --json` when [LocoHost](https://github.com/FRIKKern/locohost) is installed
  - the latest agent session for the worktree: a Claude Code, Codex or pi session that ran in the folder, or one in a parent folder that named it in the last two weeks. A mention inside tool output, such as a listing of every worktree, does not count.

## Caching

A full disk walk is repeated after six hours. A quick walk for the newest change, which skips caches, is repeated after fifteen minutes. History and merge state are read again after ten minutes, or when HEAD moves. `git status` is read again when HEAD, the index or the newest change moves. A first scan of about a hundred worktrees and 80 GB took 1 minute 44 seconds on one Mac. A warm one took about 5 seconds.

None of the caches decide a removal. Right before removing a worktree, WorkForest reads everything again with no cache.

## When the review runs

On a schedule, every two hours by default, set under *Review Every*. With the app running, these events also wake a review, at most every 30 minutes:

- A linked worktree that was not there before. The worktrees that exist when WorkForest starts do not count.
- A worktree whose quiet time passes a week, a month or three months.
- Less than 10% or 15 GB free on the home volume.

Reviews of many worktrees run in batches of 25, three at a time. When there is more than one batch, a short last call writes the summary from one line per worktree. WorkForest counts the totals in the summary itself.

## Modes

After each review the mode decides what to remove. *Mode* in the menu, or `workforest mode <name>`, sets it.

Every mode keeps a worktree when any of these holds:

- it is the main checkout, locked, protected, kept by you with *Keep for a Week* or `workforest keep`, or its folder is missing
- it has uncommitted or untracked files, or git status failed
- it has commits on no remote that are not in the default branch, unless the branch is merged by squash or patch. Those commits are kept anyway, because the unmerged branch stays.
- it is detached with commits no branch holds
- a process or localhost runs inside
- an agent session was active in it, or a file changed, in the last day, or it was made in the last day
- there is no review from the last six hours without an error, it was worked on after the review, or the review did not cover it

Then:

- **Idle** removes nothing.
- **Proactive** removes a worktree that is merged, or whose upstream is gone, and quiet for a week, unless the review found evidence to keep it.
- **Eager** removes a worktree the review calls stale with at least 80% confidence. Every other worktree that nothing keeps goes to the judge, which keeps it only with evidence and otherwise removes it with at least 60% confidence. If the judge fails, Eager removes only merged worktrees the first pass called stale with at least 60%.

No mode acts until WorkForest has watched for a day. The day starts at the app's first launch or the first `workforest auto` that is not a dry run.

## The menu

The top of the menu says how much disk the worktrees that would go next hold, and one line of counts with the mode. The review's summary follows in plain sentences. *Clean Up* appears only when the last review calls something stale that nothing keeps. *Review Now* says how long ago the last review ran, and its tooltip names the model, the tokens and what woke it.

Worktrees are listed under section headers: merged or upstream gone, stale, holding work or in use, and quiet, with the largest first and eight per section before a *More* submenu. A row shows the folder name without the start its repo's worktrees share, the branch when it says something more, and a line with the repo, disk, quiet time and state. A *removes next* badge marks what the mode removes at the next review.

Each row opens a card: what the worktree is, then in color whether it stays and why, or that it goes at the next review. Then come the facts behind that, the model's note, and Open in Finder, Open in Terminal, Keep for a Week, Remove and More. Remove is greyed out while a keep rule holds, and its tooltip says which one.

## Removing

`WFRemove` in `Sources/Forest.m` is the one way a worktree is removed, whether by a mode, *Clean Up*, the menu or the CLI:

1. Read the worktree again: git, a full walk, processes and sessions, with no cache. Check every keep rule.
2. Copy ignored files that are not caches into `~/Library/Application Support/WorkForest/removed/<id>/files`, such as `.env` and `.env.local`. Each file is copied up to 20 MB, and up to 100 MB in all. Larger ones are listed as skipped.
3. Run `git worktree remove <path>` without `--force`. git refuses a worktree with changes or a lock.
4. If the branch is merged, run `git branch -d`, which refuses a branch git does not see as merged. Unmerged branches stay.
5. Record the repo, path, branch, commit, saved files, who removed it and why in `removed.json`.

`workforest restore <id or path>` runs `git worktree add` at the same branch, or recreates the branch at the recorded commit if it was deleted, and copies the saved files back. node_modules and other caches do not come back.

## Limits

- Merged status is as fresh as the last fetch, unless *Fetch Before Each Review* is on.
- Squash detection compares against the newest 400 commits on the default branch. Older squash merges show as not merged.
- WorkForest reads only what your user can read, in the scanned folders.
- The app is not notarised. Building locally avoids Gatekeeper.
