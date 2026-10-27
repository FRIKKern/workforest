# The review

The review asks a model which worktrees are still wanted. Each one gets a verdict, `active`, `stale` or `unsure`, with a confidence and a reason. It also gets four short sentences: what the work was, why the worktree exists, where the work stands, and a recommendation. It names the one fact that shows the work is still wanted, as `keep_evidence`, or leaves it empty. And the review writes a summary of the whole Mac.

## Haiku or Luna

The default model is *Haiku or Luna*. WorkForest asks Haiku through the `claude` CLI first, and Luna through the `codex` CLI when Haiku can't answer. That happens when `claude` is missing, signed out or out of usage, or when its answer fails. The commands are the same as in [LocoHost](https://github.com/FRIKKern/locohost/blob/main/docs/REVIEW.md):

```
claude -p --model haiku --output-format json --json-schema <schema> --tools "" \
       --no-session-persistence --strict-mcp-config --setting-sources "" --system-prompt <prompt>

codex exec --model gpt-6-luna --json --output-schema <schema> --output-last-message <file> \
           --sandbox read-only --ephemeral --ignore-user-config --ignore-rules \
           -c developer_instructions=<prompt> --disable shell_tool --disable unified_exec … -
```

Both run on the login the CLI already has. `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` and `OPENAI_API_KEY` are removed from the environment. Both run in WorkForest's support folder, so no project `CLAUDE.md` or `AGENTS.md` is picked up.

## The judge

In Eager mode a second pass follows for every worktree that nothing keeps and that the first pass did not call clearly stale. The judge gets the same facts plus the first verdict, and the burden of proof is on the worktree. It answers keep or remove, with the evidence for keep and one sentence of reason.

Evidence that counts:
- unmerged work committed in the last two weeks
- an agent session that named the worktree in the last few days
- a branch name or commit subject that says the work is parked on purpose, such as wip, keep, parked or draft
- the only checkout of a branch whose pull request is still open

These do not count: that the worktree exists, commits nobody touched for weeks, or caches.

## What is sent

For each linked worktree:

- **Identity.** The path with `~` for the home folder, the repo, folder and branch, and whether it is the main checkout, locked, detached, missing or protected.
- **Git.**
  - the default branch, uncommitted and untracked file counts, stashes
  - unpushed commits and commits not in the default branch, plus orphan commits for a detached worktree
  - how it is merged, the upstream with ahead and behind, and a merged pull request when gh found one
  - the last commit's subject and author, and how many days ago it was made
- **Time.** Days since the refs were fetched, since the worktree was made, since the newest file outside caches changed, and since any work.
- **Disk.** Megabytes in all and in caches, and the file count.
- **Activity.** The names of processes inside, without pids. LocoHost's localhosts inside, with port, framework and state. The agent session's agent, title, first prompt, start, last activity and how it matched. The path of the session log stays on your Mac.

The judge also gets the first verdict, confidence, reason and keep evidence. The summary call after several batches gets one line per worktree: repo, branch, verdict, about, merged, quiet days and disk.

Commit subjects, author names, session titles and prompts go through the same redaction as LocoHost. Values after secret-looking keys and flags (`token`, `password`, `api-key`, `secret` and the like), passwords in URLs, and opaque strings of 40 or more characters become `<redacted>`. Subjects are capped at 200 characters. No file content is read for the review. `test.sh` checks that a token in a commit subject, a password in `.env` and one in a session prompt are not sent.

## Measured

| Model | Worktrees | Calls | Time | Tokens |
|---|---|---|---|---|
| Haiku, one call | 98 | 1 | over 240 s, timed out | |
| Haiku, Eager, batched with the judge | 99 | 4 batches, a judge pass and the summary | 184 s | 191.7k |

These are single runs on one Mac on 2026-10-27. The timeout is why reviews run in batches of 25.
