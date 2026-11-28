#!/usr/bin/env bash
# The life of one task around the batch: split waits for a running merge and names its base commit, a red gate= script
# runs once more alone, the FALLBACK line for a session started elsewhere, finish of a read-only task, the
# reading grace of warmd watch. No engine needed.
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

# (4) a read-only task (files: none) has no worktree: finish in the base checkout records it without a commit
printf 'ro | measure the load | numbers noted | none
rp | read the docs | summary | none
' > tasks4.txt
out="$("$WARMD" split tasks4.txt 2>&1)"
expect "a read-only task file says how it ends" '^End: nothing to commit, run warmd finish --task ro' "$(cat .warmd/tasks/ro.md)"
expect "two open read-only tasks need --task" '^FAIL 2 read-only tasks are open: ro rp\. Run warmd finish --task <name>' "$("$WARMD" finish 2>&1)"
expect "finish --task records a read-only task" '^DONE ro read only, nothing to commit' "$("$WARMD" finish --task ro 2>&1)"
expect "the last open read-only task finishes without --task" '^DONE rp read only, nothing to commit' "$("$WARMD" finish 2>&1)"
expect "the ledger has both" 'ro.*rp|rp.*ro' "$(cut -f2 "$(git rev-parse --path-format=absolute --git-common-dir)/warmd-ledger.tsv" 2>&1 | tr '
' ' ')"
expect "without an open read-only task the base checkout still refuses" '^FAIL warmd finish runs in the base checkout' "$("$WARMD" finish 2>&1)"
"$WARMD" batch-done >/dev/null

# (5) watch: the first minutes of a task are reading, no WAKE before the grace of its tier ends (watch_grace_mid=10)
printf 'rd | read then edit | y | src/r.ts
' > tasks5.txt
"$WARMD" split tasks5.txt >/dev/null 2>&1
wr="$(dirname "$PWD")/.warmd-worktrees/app/rd"
t1h=$(( $(date +%s) - 3600 )); t1h="$(date -d "@$t1h" +%Y%m%d%H%M 2>/dev/null || date -r "$t1h" +%Y%m%d%H%M)"
find "$wr" -type f -not -path '*/.git/*' -exec touch -t "$t1h" {} +
GIT_COMMITTER_DATE='2020-01-01T00:00:00' git -C "$wr" commit -q --allow-empty --date='2020-01-01T00:00:00' -m old
touch -t "$t1h" "$(git rev-parse --path-format=absolute --git-common-dir)/warmd-batch"
echo $(( $(date +%s) - 480 )) > .warmd/tasks/rd.start; echo mid > .warmd/tasks/rd.tier
expect "8 minutes into a mid task: still reading, no WAKE" '^OK all worktrees moved' "$("$WARMD" watch --once 5 2>&1)"
printf 'watch_grace_mid=6
' > warmd.conf
expect "past watch_grace_mid the idle task gets its WAKE" '^WAKE rd: idle' "$("$WARMD" watch --once 5 2>&1)"
rm -f warmd.conf
echo top > .warmd/tasks/rd.tier; echo $(( $(date +%s) - 840 )) > .warmd/tasks/rd.start
expect "14 minutes into a top task: still reading" '^OK all worktrees moved' "$("$WARMD" watch --once 5 2>&1)"
"$WARMD" batch-done >/dev/null

# (6) a worktree made by hand on a branch with a slash, while a batch runs: it is no shared checkout, finish marks it done
printf '%s\n' "$TMP/elsewhere" > "$(git rev-parse --path-format=absolute --git-common-dir)/warmd-batch"
git worktree add -q -b fix/hand "$TMP/hand" HEAD; printf 'test=true\n' > "$TMP/hand/warmd.conf"
expect "a hand-made worktree runs its tests during a batch" '^OK' "$(cd "$TMP/hand" && WARMD_NO_RAM_WAIT=1 "$WARMD" test 2>&1)"
out="$(cd "$TMP/hand" && "$WARMD" finish 2>&1)"
expect "finish on fix/hand says DONE without a path error" '^DONE fix/hand ' "$out"
[ -f "$(git rev-parse --path-format=absolute --git-common-dir)/warmd-auto/done/fix-hand" ] && ! echo "$out" | grep -q 'No such file' && echo "ok   its done marker is one file fix-hand" || { echo "FAIL done marker: $out"; fails=$((fails+1)); }
rm -f "$(git rev-parse --path-format=absolute --git-common-dir)/warmd-batch"

cd "$HERE" || exit 1
rm -rf "$TMP" 2>/dev/null
echo; [ $fails = 0 ] && echo "taskflow: all green" || echo "taskflow: $fails failed"
exit $fails
