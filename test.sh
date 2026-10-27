#!/bin/sh
# End-to-end checks against the installed CLI, on fixture repos only. test.sh builds a repo with a bare origin
# and twelve worktrees in a temporary folder, points WORKFOREST_ROOTS there and nowhere else, and uses
# tools/fakeclaude.py and tools/fakecodex.py in place of the claude and codex CLIs. Session logs, Codex's home
# and git's global config are moved to the temporary folder too. No other repo on the machine is read or touched.
set -u
cd "$(dirname "$0")"
TOOLS="$PWD/tools"
BIN="$HOME/.local/bin/workforest"
[ -x "$BIN" ] || { echo "workforest CLI not installed; run ./build.sh"; exit 1; }
T=$(cd "$(mktemp -d)" && pwd -P)
export WORKFOREST_HOME="$T/home" WORKFOREST_ROOTS="$T/code" WORKFOREST_LOCOHOST=/nonexistent WORKFOREST_GRACE_HOURS=0
export WORKFOREST_CLAUDE="$TOOLS/fakeclaude.py" WORKFOREST_CODEX="$TOOLS/fakecodex.py" WORKFOREST_TEST_SENT="$T/sent.json"
export CLAUDE_CONFIG_DIR="$T/claude" CODEX_HOME="$T/codex" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset ANTHROPIC_API_KEY OPENAI_API_KEY
pass=0; fail=0; procs=""
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok    %-56s %s\n' "$1" "$3"; else fail=$((fail+1)); printf '  FAIL  %-56s got %s, want %s\n' "$1" "$3" "$2"; fi; }
json() { python3 -c "import json,sys; j=json.load(sys.stdin); print($1)"; }
G() { git -c user.name=Fixture -c user.email=fixture@example.com -c commit.gpgsign=false -c init.defaultBranch=main -c advice.detachedHead=false "$@"; }
cleanup() { for p in $procs; do kill "$p" 2>/dev/null; done; rm -rf "$T"; }
trap cleanup EXIT

echo "== fixtures in $T"
export GIT_AUTHOR_DATE="2025-01-01T12:00:00" GIT_COMMITTER_DATE="2025-01-01T12:00:00"   # old commits
A="$T/code/app"; W="$T/code/app.worktrees"
mkdir -p "$T/code" "$T/codex" "$W"
G init -q --bare "$T/origin.git"
G clone -q "$T/origin.git" "$A" 2>/dev/null
( cd "$A" && printf 'node_modules/\n.env\n' > .gitignore && echo one > a.txt && G add -A && G commit -qm first && G push -q origin main )
wt() { G -C "$A" worktree add -q -b "$1" "$W/$1" main 2>/dev/null; }
commit() { ( cd "$W/$1" && echo "$2" > "$1-$2.txt" && G add -A && G commit -qm "$3" ); }
# merged: one commit, fast-forwarded into main and pushed. squash: two commits squash-merged, remote branch deleted.
wt merged; commit merged 1 "merged work"; G -C "$W/merged" push -q -u origin merged 2>/dev/null
G -C "$A" merge -q --ff-only merged; G -C "$A" push -q origin main 2>/dev/null
wt squash; commit squash 1 "squash part one"; commit squash 2 "squash part two"; G -C "$W/squash" push -q -u origin squash 2>/dev/null
( cd "$A" && G merge -q --squash squash >/dev/null && G commit -qm "squashed" && echo later > later.txt && G add -A && G commit -qm "later work on main" \
  && G push -q origin main 2>/dev/null && G push -q origin --delete squash 2>/dev/null && G fetch -q --prune )
# The keep rules: each worktree has one reason to stay.
wt dirty; echo changed >> "$W/dirty/a.txt"
wt untracked; echo new > "$W/untracked/new.txt"
wt unpushed; commit unpushed 1 "only here"
wt locked; G -C "$A" worktree lock --reason "fixture lock" "$W/locked"
wt busy
# loose: detached, with a commit that no branch holds.
G -C "$A" worktree add -q --detach "$W/loose" main 2>/dev/null; ( cd "$W/loose" && echo l > l.txt && G add -A && G commit -qm "loose commit" )
wt recent
wt agent
# judged: pushed, not merged, quiet. A secret in its commit subject must not reach the model.
wt judged; commit judged 1 "try a thing token=SUPERSECRETVALUE123"; G -C "$W/judged" push -q -u origin judged 2>/dev/null
# envy: merged, with an ignored .env that is saved before removal and an ignored node_modules that is not.
wt envy; printf 'DB_PASSWORD=hunter2\n' > "$W/envy/.env"; mkdir -p "$W/envy/node_modules/pkg"; echo x > "$W/envy/node_modules/pkg/index.js"
for d in "$W"/*; do [ "$d" = "$W/recent" ] || find "$d" -exec touch -h -t 202501011200 {} +; done
# agent: a Claude Code session that ran in it a minute ago.
S="$CLAUDE_CONFIG_DIR/projects/$(printf %s "$W/agent" | tr '/.' '--')"; mkdir -p "$S"
NOW=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
printf '{"type":"user","timestamp":"%s","cwd":"%s","message":{"role":"user","content":"Finish the agent fixture, password=hunter2"}}\n' "$NOW" "$W/agent" > "$S/s.jsonl"
( ( cd "$W/busy" && exec sleep 600 ) >/dev/null 2>&1 & echo $! > "$T/busy.pid" ); procs="$(cat "$T/busy.pid")"   # detached, so the shell reports nothing when it is killed
unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE
sleep 1

echo "== discovery and git facts"
"$BIN" auto --mode idle --dry-run >/dev/null
check "a dry run does not start watching" no "$([ -f "$WORKFOREST_HOME/watching-since" ] && echo yes || echo no)"
"$BIN" auto --mode idle >/dev/null   # a real run starts the grace period; WORKFOREST_GRACE_HOURS=0 ends it at once
check "a real auto run starts watching" yes "$([ -f "$WORKFOREST_HOME/watching-since" ] && echo yes || echo no)"
L=$("$BIN" list --json)
r=$(echo "$L" | json "len(j['trees'])");                                  check "list finds the twelve linked worktrees" 12 "$r"
r=$("$BIN" list --all --json | json "len(j['trees'])");                    check "--all adds the main checkout" 13 "$r"
get() { echo "$L" | json "[t$2 for t in j['trees'] if t['path'].endswith('/$1')][0]"; }
check "a fast-forward merge is merged by ancestry" ancestor "$(get merged "['merged']")"
check "a squash merge is found by patch-id" squash "$(get squash "['merged']")"
check "a deleted remote branch is upstream gone" gone "$(get squash "['upstream']")"
check "an unmerged branch is not merged" None "$(get judged "['merged']")"
check "unpushed commits are counted" 1 "$(get unpushed "['unpushed']")"
check "the ignored cache counts as cache" True "$(get envy "['cacheBytes'] > 0")"
check "a process inside is found" True "$(get busy "['processes'] != []")"
check "the agent session is found" "Claude Code" "$(get agent "['session']['agent']")"

echo "== every mode keeps work, even when the review calls it all stale"
ALL="merged,squash,dirty,untracked,unpushed,locked,busy,loose,recent,agent,judged,envy"
WORKFOREST_TEST_STALE=$ALL "$BIN" review --model haiku --mode eager >/dev/null 2>&1; check "the review succeeds" 0 "$?"
P=$("$BIN" auto --mode eager --dry-run --json)
why() { echo "$P" | json "[p['why'] for p in j['plan'] if p['path'].endswith('/$1')][0]"; }
rm_() { echo "$P" | json "[p['remove'] for p in j['plan'] if p['path'].endswith('/$1')][0]"; }
for k in "dirty:not committed" "untracked:untracked file" "unpushed:on no remote" "locked:locked" "busy:running inside" "loose:no branch holds" "recent:files changed" "agent:session active"; do
  n=${k%%:*}; w=${k#*:}
  case "$(why "$n")" in *"$w"*) r=kept;; *) r="$(why "$n")";; esac
  check "$n stays: $w" kept "$r"
done
check "a merged, quiet worktree may go" True "$(rm_ merged)"
r=$("$BIN" auto --mode idle --dry-run --json | json "sum(p['remove'] for p in j['plan'])"); check "idle mode removes nothing" 0 "$r"
r=$(json "j['summary']" < "$WORKFOREST_HOME/review.json");                 check "the summary starts with WorkForest's own totals" "12 worktrees in 1 repo hold" "$(echo "$r" | cut -d' ' -f1-6)"

r=$(WORKFOREST_BATCH=5 "$BIN" review --model haiku --mode idle --json | json "j['summary'] + ' ' + str(sum(1 for t in j['trees'] if 'review' in t))")
                                                                            check "three batches and one summary cover every worktree" "Fixture overall summary: 12 lines. 12" "$(echo "$r" | sed 's/.*caches such as node_modules. //')"

echo "== what the model gets"
grep -q "SUPERSECRETVALUE123" "$WORKFOREST_TEST_SENT";                     check "a secret in a commit subject is redacted" 1 "$?"
grep -q "hunter2" "$WORKFOREST_TEST_SENT";                                 check "no .env content or session secret is sent" 1 "$?"
grep -q "try a thing" "$WORKFOREST_TEST_SENT";                             check "the rest of the subject is sent" 0 "$?"
ANTHROPIC_API_KEY=sk-ant-test "$BIN" review --model haiku --mode idle >/dev/null 2>&1; check "an API key never reaches claude" 0 "$?"
r=$(WORKFOREST_TEST_CLAUDE_LIMIT=1 OPENAI_API_KEY=sk-test "$BIN" review --model auto --mode idle --json | json "j['model']")
                                                                            check "out of Haiku usage, Luna answers without the key" gpt-6-luna "$r"
WORKFOREST_CLAUDE=/usr/bin/false WORKFOREST_CODEX=/usr/bin/false "$BIN" review --model auto >/dev/null 2>&1; check "both models failing exits 1" 1 "$?"
r=$("$BIN" auto --mode eager --dry-run --json | json "sum(p['remove'] for p in j['plan'])"); check "and after a failed review nothing goes" 0 "$r"

echo "== proactive: merged and a week quiet"
WORKFOREST_TEST_STALE=$ALL "$BIN" review --model haiku --mode proactive >/dev/null 2>&1
P=$("$BIN" auto --mode proactive --dry-run --json)
check "proactive removes a merged worktree" True "$(rm_ merged)"
check "and a squash-merged one" True "$(rm_ squash)"
check "but not unmerged work" False "$(rm_ judged)"
r=$(WORKFOREST_PROACTIVE_HOURS=100000 "$BIN" auto --mode proactive --dry-run --json | json "[p['remove'] for p in j['plan'] if p['path'].endswith('/merged')][0]")
                                                                            check "proactive waits for the quiet time" False "$r"
"$BIN" auto --mode proactive --path "$W/merged" >/dev/null
check "auto removes the folder" no "$([ -d "$W/merged" ] && echo yes || echo no)"
G -C "$A" rev-parse --verify -q merged >/dev/null;                         check "and deletes the merged branch with -d" 1 "$?"
check "removed.json records the mode" Proactive "$("$BIN" removed --json | json "j[0]['by']")"
"$BIN" restore "$W/merged" >/dev/null;                                     check "restore recreates it" 0 "$?"
check "at the same commit" "merged work" "$(G -C "$W/merged" log -1 --format=%s)"
find "$W/merged" -exec touch -h -t 202501011200 {} +
python3 - "$WORKFOREST_HOME/rules.json" "$W/merged" <<'PY'
import json,sys; p,w=sys.argv[1],sys.argv[2]; j=json.load(open(p)); j['protect']['paths'].append(w); json.dump(j,open(p,'w'))
PY
WORKFOREST_TEST_STALE=merged "$BIN" review --model haiku --mode proactive >/dev/null 2>&1
P=$("$BIN" auto --mode proactive --dry-run --json)
check "a protected path stays" protected "$(why merged)"
"$BIN" keep "$W/squash" >/dev/null
P=$("$BIN" auto --mode proactive --dry-run --json)
case "$(why squash)" in "kept by you"*) r=kept;; *) r="$(why squash)";; esac;      check "a worktree you keep stays" kept "$r"
"$BIN" keep "$W/squash" --off >/dev/null
P=$("$BIN" auto --mode proactive --dry-run --json)
check "and the mode decides again when the keep ends" True "$(rm_ squash)"

echo "== eager: the worktree must show evidence"
WORKFOREST_TEST_UNSURE=judged WORKFOREST_TEST_KEEP=judged "$BIN" review --model haiku --mode eager >/dev/null 2>&1
r=$(json "any(t['folder'] == 'judged' for t in j['worktrees'])" < "$WORKFOREST_TEST_SENT.judge"); check "an unsure worktree goes to the judge" True "$r"
P=$("$BIN" auto --mode eager --dry-run --json)
check "the judge keeps it with evidence" False "$(rm_ judged)"
case "$(why judged)" in evidence:*) r=yes;; *) r="$(why judged)";; esac;    check "and says what the evidence is" yes "$r"
WORKFOREST_TEST_UNSURE=judged "$BIN" review --model haiku --mode eager >/dev/null 2>&1
P=$("$BIN" auto --mode eager --dry-run --json)
check "without evidence eager removes it" True "$(rm_ judged)"
r=$(WORKFOREST_GRACE_HOURS=1000 "$BIN" auto --mode eager --dry-run --json | json "[p['remove'] for p in j['plan'] if p['path'].endswith('/judged')][0]")
                                                                            check "but not before WorkForest has watched a day" False "$r"
"$BIN" auto --mode eager --path "$W/judged" >/dev/null
check "auto removes it" no "$([ -d "$W/judged" ] && echo yes || echo no)"
G -C "$A" rev-parse --verify -q judged >/dev/null;                         check "and keeps the unmerged branch" 0 "$?"

echo "== ignored files are saved, caches are not"
WORKFOREST_TEST_STALE=envy "$BIN" review --model haiku --mode eager >/dev/null 2>&1
"$BIN" auto --mode eager --path "$W/envy" >/dev/null
check "envy is removed" no "$([ -d "$W/envy" ] && echo yes || echo no)"
REC=$("$BIN" removed --json)
check ".env is saved" True "$(echo "$REC" | json "'.env' in j[0]['saved']")"
check "node_modules is not" False "$(echo "$REC" | json "any('node_modules' in s for s in j[0]['saved'])")"
"$BIN" restore "$(echo "$REC" | json "j[0]['id']")" >/dev/null;           check "restore by id works" 0 "$?"
check "and puts .env back" "DB_PASSWORD=hunter2" "$(cat "$W/envy/.env" 2>/dev/null)"
check "without the cache" no "$([ -d "$W/envy/node_modules" ] && echo yes || echo no)"

echo "== remove checks again"
"$BIN" remove "$W/dirty" --yes >/dev/null 2>&1;                            check "remove refuses uncommitted changes, exit 1" 1 "$?"
check "and the worktree is still there" yes "$([ -d "$W/dirty" ] && echo yes || echo no)"
"$BIN" remove "$W/busy" --yes >/dev/null 2>&1;                             check "remove refuses with a process inside" 1 "$?"
echo late > "$W/squash/late.txt"; rm "$W/squash/late.txt"; touch "$W/squash"
WORKFOREST_TEST_STALE=squash "$BIN" review --model haiku --mode eager >/dev/null 2>&1
r=$("$BIN" auto --mode eager --path "$W/squash" --json | json "'removed' if j['actions'] and j['actions'][0]['removed'] else 'kept'")
                                                                            check "a change just before removal keeps it" kept "$r"
check "and the worktree is still there" yes "$([ -d "$W/squash" ] && echo yes || echo no)"

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
