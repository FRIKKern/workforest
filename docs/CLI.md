# CLI

The app's binary is also a command line tool, at `~/.local/bin/workforest`. It does not need the menu bar app, and it shares its state with it.

```sh
workforest list                  # every linked worktree: path, branch, quiet time, disk, git state; --all adds main checkouts
workforest list --json           # the same with every fact, the review's verdict and the mode's plan
workforest explain <path>        # what it was for, whether it is merged, what keeps it; `explain .` for the current folder
workforest review                # ask the model now; in Eager mode the judge looks again; --model luna to pick one
workforest summary               # the last summary, and what the mode would remove and keep, with reasons
workforest auto --dry-run        # one round of the mode without removing; drop --dry-run to remove; --path for one worktree
workforest clean-up              # remove what the last review calls stale and nothing keeps, after a question
workforest remove <path>         # remove one worktree: every keep rule is checked first
workforest removed               # what was removed, with ids
workforest restore <id|path>     # recreate a removed worktree at its commit, with its saved .env files
workforest keep <path>           # no mode removes it for a week; --days 30 for longer, --off to end it
workforest fetch                 # git fetch --all --prune in every repo
workforest prune <path>          # git worktree prune in that repo, for worktrees whose folder is gone
workforest mode eager            # show or set the mode: idle, proactive or eager
workforest rules                 # the rules file and the folders scanned
```

Exit codes: 0 done, 1 not found, refused, aborted or failed, 2 usage, 3 some worktrees were kept during clean-up.

`--mode` works with `review`, `summary` and `auto`. `--path` works with `summary`, `auto` and `clean-up`. `--yes` skips the question for `remove` and `clean-up`. A real `workforest auto` starts the one-day grace period, and a dry run does not.

## For agents

```sh
workforest explain .             # before starting: is this worktree still wanted, and is its branch merged?
workforest list --json           # which other worktrees exist for this repo
workforest auto --dry-run        # what the mode would remove
```

Ask the user before `workforest auto`, `workforest clean-up` or `workforest remove`. Never remove a worktree another agent works in without saying so.

## URL scheme

The app answers `open workforest://review`, `workforest://clean-up` with a confirmation, `workforest://rescan`, `workforest://login-on`, `workforest://login-off` and `workforest://quit`.

## Settings

| Key in `no.guerrilla.workforest` | Default | Meaning |
|---|---|---|
| `workforest.mode` | `eager` | `idle` reports only, `proactive` removes merged worktrees quiet a week, `eager` removes what can't show evidence |
| `workforest.model` | `auto` | `auto` is Haiku, then Luna. Also `haiku`, `sonnet`, `opus`, `luna` or any model name |
| `workforest.reviewMinutes` | 120 | Minutes between reviews, 0 off |
| `workforest.fetch` | false | `git fetch --all --prune` in every repo before a review |
| `workforest.checkPRs` | false | Ask `gh` for merged pull requests |
| `workforest.askBeforeRemoving` | true | Confirm Clean Up and Remove in the menu |
| `workforest.claudePath`, `workforest.codexPath` | found | Where the CLIs are |
