#!/usr/bin/env bash
# The life of one task around the batch: split waits for a running merge and names its base commit, a red gate= script
# runs once more alone. No engine needed.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
TMP="$(mktemp -d)"
export XDG_CACHE_HOME="$TMP/cache" WARMD_NO_PREWARM=1 WARMD_TRANSCRIPTS="$TMP/transcripts"
unset CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID
fails=0
expect() { if echo "$3" | grep -qE "$2"; then echo "ok   $1"; else echo "FAIL $1: wanted /$2/, got: $(echo "$3" | head -3)"; fails=$((fails+1)); fi; }
mkdir -p "$TMP/app"; cd "$TMP/app" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com; git config core.autocrlf false
echo '{ "name": "t" }' > package.json; printf '.warmd\n' > .gitignore
git add -A; git commit -qm init
mkdir -p .warmd

# (1) split during a merge waits for it: the worktree starts on the merged state, the task file names that commit
sleep 30 & m=$!
echo "$m" > .warmd/merge.owner
( sleep 3; echo b > b.txt; git add b.txt; git commit -qm "merged meanwhile"; kill $m ) &
printf 'mw | a goal | y | src/a.ts\n' > tasks.txt
out="$(WARMD_MERGE_POLL=1 "$WARMD" split tasks.txt 2>&1)"
wait
expect "split says it waits for the merge" 'a merge runs in this project, pid [0-9]+: split waits' "$out"
wt="$(dirname "$PWD")/.warmd-worktrees/app/mw"
expect "the worktree starts on the merged state" 'merged meanwhile' "$(git -C "$wt" log -1 --format=%s)"
expect "the task file names its base commit" "^Base: main at $(git rev-parse --short=9 main) merged meanwhile" "$(cat .warmd/tasks/mw.md)"
rm -f .warmd/merge.owner
"$WARMD" batch-done >/dev/null

# (2) a red gate= script runs once more alone: green then merges with "red only under load", red twice rolls back
printf 'echo run >> .warmd/gates.txt
[ -f .warmd/load ] && { rm -f .warmd/load; echo "FAIL test_timing too slow"; exit 1; }
exit 0
' > gate.sh
printf 'gate=sh gate.sh
' > warmd.conf; git add gate.sh warmd.conf; git commit -qm gate
git checkout -qb warmd/g1; echo g1 > g1.txt; git add g1.txt; git commit -qm g1; git checkout -q main
: > .warmd/load; rm -f .warmd/gates.txt
out="$("$WARMD" merge warmd/g1 2>&1)"
expect "a gate red under load merges when green alone" '^OK .*merged warmd/g1' "$out"
expect "the merge says the gate was red only under load" '^WARN gate red only under load: .*FAIL test_timing too slow' "$out"
expect "the gate ran twice" '^2$' "$(grep -c run .warmd/gates.txt)"
printf 'echo run >> .warmd/gates.txt; echo "FAIL test_real broke"; exit 1
' > gate.sh; git commit -qam redgate
git checkout -qb warmd/g2; echo g2 > g2.txt; git add g2.txt; git commit -qm g2; git checkout -q main
rm -f .warmd/gates.txt; out="$("$WARMD" merge warmd/g2 2>&1)"
expect "a gate red twice rolls back" '^FAIL merge warmd/g2: FAIL test_real broke' "$out"
expect "a red gate ran once more" '^2$' "$(grep -c run .warmd/gates.txt)"
printf 'gate=sh gate.sh
gate_retry=0
' > warmd.conf; git commit -qam noretry
rm -f .warmd/gates.txt; out="$("$WARMD" merge warmd/g2 2>&1)"
expect "gate_retry=0 runs a red gate once" '^1$' "$(grep -c run .warmd/gates.txt)"
rm -f warmd.conf gate.sh; git commit -qam "no gate"

# (3) the session started in another folder (Desktop\mc, the agents in mcttrition\.claudegents): FALLBACK line
mkdir -p .claude/agents; cp "$HERE/agents/warmd-worker.md" .claude/agents/
printf 'sa | a goal | y | src/s.ts
' > tasks3.txt
out="$("$WARMD" split tasks3.txt 2>&1)"; "$WARMD" batch-done >/dev/null
case "$out" in *FALLBACK*) echo "FAIL a session in the project folder got a FALLBACK line"; fails=$((fails+1));; *) echo "ok   a session in the project folder needs no FALLBACK";; esac
slug="$(cd "$TMP" && pwd -W 2>/dev/null || pwd)"; slug="${slug//[^A-Za-z0-9]/-}"
mkdir -p "$TMP/transcripts/$slug"; : > "$TMP/transcripts/$slug/s1.jsonl"
out="$(CLAUDE_CODE_SESSION_ID=s1 "$WARMD" split tasks3.txt 2>&1)"; "$WARMD" batch-done >/dev/null
expect "a session started in a parent folder gets the FALLBACK line" '^FALLBACK sa \(no warmd-worker agent in .*\.claude/agents\): subagent_type=general-purpose' "$out"
expect "init says the session does not see the agents" 'WARN this Claude Code session started in .*its Agent tool does not see' "$(CLAUDE_CODE_SESSION_ID=s1 bash -c "WARMD_HOME='$HERE'; . '$HERE/lib/platform.sh'; . '$HERE/lib/core.sh'; detect_project >/dev/null 2>&1; . '$HERE/lib/team.sh'; common_init" 2>&1)"
git checkout -q -- . 2>/dev/null; git clean -qfd -e .warmd 2>/dev/null

cd "$HERE" || exit 1
rm -rf "$TMP" 2>/dev/null
echo; [ $fails = 0 ] && echo "taskflow: all green" || echo "taskflow: $fails failed"
exit $fails
