# Changelog

All notable changes to WorkForest. Format follows [Keep a Changelog](https://keepachangelog.com/).

## [0.1.0] - 2026-10-27

### Added
- Menu bar list of every git worktree under the scan roots, found through `git worktree list` in every repo, including `.claude/worktrees`, `*.worktrees` folders and `~/.cursor/worktrees`. Rows are in sections: holding work or in use, merged or upstream gone, stale, and quiet. Main checkouts and missing folders sit in submenus.
- Facts per worktree:
  - the last commit, uncommitted and untracked files, stashes, commits on no remote, and detached commits no branch holds
  - merged status by ancestry, tree, `git cherry`, patch-id for squash merges, and optionally a merged pull request through `gh`
  - upstream gone, locked and missing
  - disk use with the share in caches, and the newest change outside caches
  - processes and LocoHost localhosts inside, and the latest Claude Code, Codex or pi session
- Review by Haiku, or Luna when Haiku can't answer, on the user's own login with no tools. It runs in batches of 25, three at a time, and writes a summary whose totals WorkForest counts itself.
- Three modes. Idle reports. Proactive removes merged or upstream-gone worktrees quiet for a week. Eager, the default, removes every quiet worktree that can't show evidence, after a judge pass. Every mode keeps work, and no mode acts in the first day.
- Removal through git's own checks: a fresh read first, `git worktree remove` without `--force`, and `git branch -d` only when merged. Ignored files that are not caches, such as `.env`, are saved first. `workforest restore` brings a worktree back at its commit.
- Reviews wake on a schedule, a new worktree, quiet time passing a week, a month or three months, and low disk.
- CLI: `list`, `explain`, `review`, `summary`, `auto`, `clean-up`, `remove`, `restore`, `removed`, `fetch`, `prune`, `mode` and `rules`, with `--json`.
- The menu: reclaimable disk in large type over one line of counts, the review's summary as readable text, Clean Up only when there is something to remove, and native section headers. Rows have a title, a subtitle and a *removes next* badge. Each row's card says in color whether the worktree stays and why, lists the facts in aligned columns, and offers four actions.
- Keep for a Week, in the menu or as `workforest keep <path>`: every mode leaves the worktree alone until the keep ends.
- URL scheme `workforest://review|clean-up|rescan|login-on|login-off|quit`. Launch at Login. Universal binary. `install.sh`, `uninstall.sh`, which keeps the saved files of removed worktrees, and `test.sh` with 62 checks against fixtures. `tools/render.m` renders the menu and cards to PNG.
