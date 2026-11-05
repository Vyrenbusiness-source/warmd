#!/usr/bin/env bash
# Automatics self-test, driven only by hook JSON as Claude Code sends it: a failed or red stop goes up one tier, once,
# the second failure lands on top, a failure at the top goes to a human; a compaction and a context past 70% of the budget
# write a handoff and stop the agent with its AGENT line; warmd watch prints the queued lines and skips paused tasks. No network.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
TMP="$(mktemp -d)"
# One path form on Windows: long names, no /tmp mount. A runner TEMP like RUNNER~1 otherwise differs from what git reports
command -v cygpath >/dev/null 2>&1 && TMP="$(cygpath -u "$(cygpath -l -m "$TMP")")"
export XDG_CACHE_HOME="$TMP/cache" AUTO_EVERY=0 WARMD_TRANSCRIPTS="$TMP/transcripts"
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails+1)); }
PY=python3; "$PY" -c 'import json' >/dev/null 2>&1 || PY=python
. "$HERE/lib/platform.sh"
jstr() { "$PY" -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }
# A detached job gets 20 s, then the test fails fast and shows the job logs instead of waiting for the CI timeout
waitfor() { local end=$((SECONDS + ${WAIT_MAX:-20})); until eval "$1"; do
  [ $SECONDS -ge $end ] && { echo "  waited ${WAIT_MAX:-20}s for: $1" >&2; tail -n 6 "$C/warmd-hook.log" "$C/warmd-automerge.log" 2>/dev/null | sed 's/^/  /' >&2; return 1; }
  sleep 0.2; done; }

B="$TMP/origin.git"; git init -q --bare "$B"
R="$TMP/repo"; mkdir -p "$R" && cd "$R" && git init -q -b main . && git config core.autocrlf false && git config user.name t && git config user.email t@example.com || exit 1
echo '{ "name": "t", "scripts": { "test": "true" } }' > package.json
printf '.warmd\n' > .gitignore
printf 'gate=true\ncheap=haiku-x\nmid=sonnet-x\ntop=opus-x\nbudget_mid=3\n' > warmd.conf
git add -A && git commit -qm init && git remote add origin "$B" && git push -q -u origin main || exit 1
printf 'a | add a | a.txt exists | a.txt\nb | add b | b.txt exists | b.txt\nc | add c | c.txt exists | c.txt\nd | add d | d.txt exists | d.txt\n' > "$TMP/tasks.txt"
WARMD_NO_PREWARM=1 "$WARMD" split "$TMP/tasks.txt" > "$TMP/split.out" || no "split: $(cat "$TMP/split.out")"
C="$(git rev-parse --path-format=absolute --git-common-dir)"
W="$(dirname "$R")/.warmd-worktrees/repo"
taskpath() { sed -n "s/^AGENT $1: .*prompt=\"Read \(.*\) and do it.\"/\1/p" "$TMP/split.out"; }
work() { (cd "$W/$1" && echo "$1" > "$2" && git add "$2" && git commit -qm "$1 $2"); }
transcript() { # file, task name, last text: 2227 tokens in the last turn, 2 tool calls
  local u='"usage":{"input_tokens":20,"cache_creation_input_tokens":200,"cache_read_input_tokens":2000,"output_tokens":7}'
  {
    printf '{"type":"user","message":{"role":"user","content":%s}}\n' "$(jstr "Read $(taskpath "$2") and do it.")"
    printf '{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}],"usage":{"input_tokens":10,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":5}}}\n'
    printf '{"type":"assistant","message":{"id":"m2","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{}}],%s}}\n' "$u"
    printf '{"type":"assistant","message":{"id":"m2","content":[{"type":"text","text":%s}],%s}}\n' "$(jstr "$3")" "$u"
  } > "$1"
}
N=0
stop() { # name, last text: the SubagentStop for that agent, then wait for the detached job
  N=$((N+1)); local t="$TMP/$1-$N.jsonl"
  transcript "$t" "$1" "$2"
  printf '{"session_id":"s1","hook_event_name":"SubagentStop","agent_id":"x","agent_transcript_path":"%s"}' "$(native_path "$t")" | "$WARMD" hook-subagent
  waitfor "[ \"\$(cat '$C/warmd-hook.log' 2>/dev/null | grep -c '^DONE warmd/$1 ')\" -ge $N ]" || no "job for $1 never finished: $(tail -3 "$C/warmd-hook.log")"
}
tier() { cat "$R/.warmd/tasks/$1.tier"; }
outcome() { grep "	$1	" "$C/warmd-ledger.tsv" | tail -1 | cut -f8; }
old() { # the last stop of a task is past the duplicate window
  local t; t=$(( $(date +%s) - 600 )); touch -t "$(date -d "@$t" +%Y%m%d%H%M 2>/dev/null || date -r "$t" +%Y%m%d%H%M)" "$C/warmd-auto/paused/$1"
}

# ---- failed run: one tier up, once, with the earlier commits ----
echo cheap > "$R/.warmd/tasks/a.tier"
work a a.txt
stop a "Tests stay red.
ESCALATE: tests red"
[ "$(tier a)" = mid ] && [ "$(outcome a)" = escalated ] && ok "failed run escalates one tier, ledger says escalated" || no "first failure: tier $(tier a), outcome $(outcome a)"
out="$("$WARMD" watch --once)"; rc=$?
[ "$rc" = 3 ] && echo "$out" | grep -qF "AGENT a: subagent_type=warmd-worker model=sonnet-x prompt=\"Read $(taskpath a) and do it. State: warmd/a at" && ok "watch wakes the session with the next AGENT line" || no "watch after escalation rc=$rc: $out"
sha="$(git -C "$W/a" rev-parse --short HEAD)"
grep -q "^Earlier commits: $sha a a.txt" "$R/.warmd/tasks/a.md" && grep -q '^Earlier attempt failed' "$R/.warmd/tasks/a.md" && ok "the next tier gets the earlier commits as context" || no "task a: $(tail -3 "$R/.warmd/tasks/a.md")"
grep -q '^Budget: under 3k' "$R/.warmd/tasks/a.md" && [ "$(sed -n 2p "$C/warmd-handoff/a.task")" = mid ] && ok "budget and handoff index follow the new tier" || no "budget or index: $(sed -n 2p "$C/warmd-handoff/a.task")"
stop a "ESCALATE: tests red"
[ "$(tier a)" = mid ] && ! "$WARMD" watch --once 2>&1 | grep -q '^AGENT a' && ok "the same stop twice escalates once" || no "duplicate stop escalated again: tier $(tier a)"

# ---- second failure, this time a red last run behind an ok text: top ----
old a; work a a2.txt
mkdir -p "$W/a/.warmd/run"; printf '7 FAIL\n2 tests failed\n' > "$W/a/.warmd/run/result.txt"
stop a "All done."
[ "$(tier a)" = top ] && [ "$(outcome a)" = escalated ] && ok "second failure (red run) goes to top" || no "second failure: tier $(tier a), outcome $(outcome a)"
out="$("$WARMD" watch --once)"
echo "$out" | grep -q '^AGENT a: subagent_type=warmd-worker model=opus-x' && ok "top AGENT line queued" || no "top line: $out"
grep -c '^Earlier commits: ' "$R/.warmd/tasks/a.md" | grep -qx 1 && grep -q "^Earlier commits: .*a a2.txt; .*a a.txt" "$R/.warmd/tasks/a.md" && ok "earlier commits refreshed, one line" || no "commit lines: $(grep Earlier "$R/.warmd/tasks/a.md")"
old a
stop a "ESCALATE: still red"
out="$("$WARMD" watch --once)"
[ "$(tier a)" = top ] && [ "$(outcome a)" = failed ] && echo "$out" | grep -q '^ESCALATE a: failed at the top tier' && ok "failure at the top goes to a human" || no "top failure: tier $(tier a), outcome $(outcome a), $out"
rm -f "$W/a/.warmd/run/result.txt"

# ---- compaction: work committed, handoff written, the agent's next Bash call ends it ----
echo half > "$W/b/b.txt"; echo never-added > "$W/b/fresh.txt"; mkdir -p "$W/b/.warmd"; echo junk > "$W/b/.warmd/ignored.txt"
transcript "$TMP/b.jsonl" b "working"
printf '{"session_id":"s1","transcript_path":"%s","hook_event_name":"PreCompact","trigger":"auto"}' "$(native_path "$TMP/b.jsonl")" | "$WARMD" hook-compact; rc=$?
[ "$rc" = 0 ] && [ -z "$(git -C "$W/b" status --porcelain -uno)" ] && git -C "$W/b" log -1 --format=%s | grep -q '^WIP b: automatic handoff at compaction' && ok "compaction commits the work" || no "compaction commit rc=$rc: $(git -C "$W/b" log -1 --format=%s)"
git -C "$W/b" ls-tree --name-only HEAD | grep -qx fresh.txt && ok "the WIP commit takes a file the agent never added" || no "WIP commit misses an untracked file: $(git -C "$W/b" status --porcelain)"
[ -z "$(git -C "$W/b" ls-tree -r --name-only HEAD .warmd)" ] && ok "the WIP commit leaves gitignored files out" || no "WIP commit took ignored files"
grep -q '^## Handoff 1' "$C/warmd-handoff/b.md" && grep -q 'Automatic handoff at compaction' "$C/warmd-handoff/b.md" && ok "compaction writes a handoff" || no "handoff note: $(cat "$C/warmd-handoff/b.md" 2>&1)"
pre() { printf '{"session_id":"s1","transcript_path":"%s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}' "$(native_path "$1")" | "$WARMD" hook-pre; }
out="$(pre "$TMP/b.jsonl")"
echo "$out" | "$PY" -c 'import json,sys; h=json.load(sys.stdin)["hookSpecificOutput"]; assert h["permissionDecision"]=="deny"; r=h["permissionDecisionReason"]; assert "AGENT b: " in r and "then " in r, r' 2>/dev/null && ok "next Bash call is denied with the AGENT line" || no "deny after compaction: $out"
printf '{"session_id":"s1","transcript_path":"%s","hook_event_name":"PreCompact"}' "$(native_path "$TMP/b.jsonl")" | "$WARMD" hook-compact
[ "$(grep -c '^## Handoff' "$C/warmd-handoff/b.md")" = 1 ] && ok "a second compaction of the same agent writes no second handoff" || no "handoff rounds: $(grep -c '^## Handoff' "$C/warmd-handoff/b.md")"
transcript "$TMP/b2.jsonl" b "fresh"
[ -z "$(AUTO_PCT=99 pre "$TMP/b2.jsonl")" ] && ok "the fresh agent of b is not blocked" || no "fresh agent blocked"

# ---- context past 70% of the budget: 2227 of 3k tokens ----
transcript "$TMP/c.jsonl" c "working"
[ -z "$(AUTO_PCT=80 pre "$TMP/c.jsonl")" ] && [ ! -f "$C/warmd-handoff/c.md" ] && ok "under the limit: nothing" || no "handoff under the limit"
out="$(pre "$TMP/c.jsonl")"
echo "$out" | grep -q '"deny"' && echo "$out" | grep -q '74% of the 3k budget' && echo "$out" | grep -q 'AGENT c: ' && grep -q 'Automatic handoff at 74%' "$C/warmd-handoff/c.md" && ok "past 70% of the budget: handoff and deny" || no "70%: $out"
printf '{"transcript_path":"%s","agent_id":"q1"}' "$(native_path "$TMP/none.jsonl")" | "$WARMD" hook-pre >/dev/null; [ $? = 0 ] && ok "missing transcript: exit 0" || no "missing transcript"

# ---- watch: paused tasks never alarm ----
t2h=$(( $(date +%s) - 7200 )); t2h="$(date -d "@$t2h" +%Y%m%d%H%M 2>/dev/null || date -r "$t2h" +%Y%m%d%H%M)"
for n in a b c d; do
  find "$W/$n" -type f -not -path '*/.git/*' -exec touch -t "$t2h" {} +
  (cd "$W/$n" && GIT_COMMITTER_DATE='2020-01-01T00:00:00' git commit -q --allow-empty --date='2020-01-01T00:00:00' -m old)
done
touch -t "$t2h" "$C/warmd-batch"
"$WARMD" watch --pause b | grep -q '^OK b paused' && ok "watch --pause" || no "watch --pause"
out="$("$WARMD" watch --once)"; rc=$?
[ "$rc" = 3 ] && echo "$out" | grep -q '^WAKE c:' && echo "$out" | grep -q '^WAKE d:' && ! echo "$out" | grep -qE '^WAKE (a|b):' && ok "a stopped and a paused task raise no WAKE" || no "paused watch rc=$rc: $out"
"$WARMD" watch --pause c >/dev/null; "$WARMD" watch --pause d >/dev/null
out="$("$WARMD" watch 5)"; rc=$?
[ "$rc" = 0 ] && [ "$out" = "OK no agent runs, paused: b c d" ] && ok "all paused or finished: watch ends instead of waiting" || no "all paused rc=$rc: $out"
old d   # find -newer may compare whole seconds: a marker from this very second would hide the move
echo more > "$W/d/d.txt"
out="$("$WARMD" watch --once)"; rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q '^OK all worktrees moved.*paused: b c$' && [ ! -f "$C/warmd-auto/paused/d" ] && ok "a worktree that moves is live again" || no "resume rc=$rc: $out"

# ---- a new agent on a paused task: the Agent call clears the marker, watch does not end while it still reads ----
agent() { printf '{"session_id":"s1","transcript_path":"%s","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"description":"t","prompt":%s}}' "$(native_path "$TMP/main.jsonl")" "$(jstr "Read $1 and do it.")" | "$WARMD" hook-pre; }
out="$(agent "$(taskpath a)")"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && [ ! -f "$C/warmd-auto/paused/a" ] && [ -f "$C/warmd-auto/paused/b" ] && ok "an Agent call on a task clears only its pause marker" || no "agent start rc=$rc, out $out, paused: $(ls "$C/warmd-auto/paused")"
out="$("$WARMD" watch --once)"
echo "$out" | grep -q '^WAKE a:' && ok "watch counts the new agent as running" || no "watch after agent start: $out"

# ---- a finished task (stop hook wrote warmd-batch-done) is never woken, even when someone touches its worktree ----
printf '%s\tok\n' "$(cd "$W/a" && pwd)" >> "$C/warmd-batch-done"
out="$("$WARMD" watch --once)"
! echo "$out" | grep -q '^WAKE a:' && ok "a finished task raises no WAKE" || no "finished task woken: $out"
agent "$(taskpath a)" >/dev/null
! grep -qF "$(cd "$W/a" && pwd)	" "$C/warmd-batch-done" && ok "an Agent call on a finished task makes it live again" || no "batch-done kept: $(cat "$C/warmd-batch-done")"
out="$("$WARMD" watch --once)"
echo "$out" | grep -q '^WAKE a:' && ok "the restarted task is watched again" || no "restarted task not watched: $out"
case "$(taskpath b)" in ?:/*)
  agent "$(taskpath b | tr '/' '\\')" >/dev/null
  [ ! -f "$C/warmd-auto/paused/b" ] && ok "a Windows path with backslashes clears the marker too" || no "backslash path kept the marker";;
esac

# ---- red run for every adapter: the exit code of the last warmd test or check, not only the daemon's result.txt ----
G="$TMP/gen"; mkdir -p "$G" && cd "$G" && git init -q -b main . && git config core.autocrlf false && git config user.name t && git config user.email t@example.com
printf 'test=exit 1\n' > warmd.conf; printf '.warmd\n' > .gitignore; git add -A && git commit -qm init
WARMD_NOCACHE=1 "$WARMD" test >/dev/null 2>&1
red() { (WARMD_HOME="$HERE"; . "$HERE/lib/auto.sh"; auto_red "$1"); }
[ "$(cut -d' ' -f1 "$G/.warmd/run/last.rc" 2>/dev/null)" != 0 ] && red "$G" && ok "a red warmd test in a generic project counts as red" || no "generic red run not seen: $(cat "$G/.warmd/run/last.rc" 2>&1)"
printf 'test=true\n' > warmd.conf
WARMD_NOCACHE=1 "$WARMD" test >/dev/null 2>&1
! red "$G" && ok "a green rerun clears the red" || no "green rerun still red: $(cat "$G/.warmd/run/last.rc" 2>&1)"
printf '7 FAIL\n' > "$G/.warmd/run/result.txt"; touch -t 202001010000 "$G/.warmd/run/result.txt"
! red "$G" && ok "an older daemon FAIL does not beat the newer green run" || no "old result.txt overrode last.rc"
echo "4 test" > "$G/.warmd/run/last.rc"; touch -t 201901010000 "$G/.warmd/run/last.rc"
red "$G" && ok "a newer daemon FAIL still counts" || no "newer result.txt FAIL not seen"
rm -f "$G/.warmd/run/result.txt"
! red "$G" && ok "a refused run (merge running) is not red" || no "refusal counted as red"

# ---- an automatic commit never takes engine leftovers along ----
J="$TMP/junk"; mkdir -p "$J/Game/ProjectSettings" "$J/Game/Assets" "$J/Game/Packages" && cd "$J" && git init -q -b main . && git config user.name t && git config user.email t@example.com || exit 1
printf 'm_EditorVersion: 6000.0.0f1\n' > Game/ProjectSettings/ProjectVersion.txt; echo '{}' > Game/Packages/manifest.json; echo '{"a":1}' > Game/Packages/packages-lock.json; echo '<keep/>' > Game/kept.xml
git add -A && git commit -qm init
echo 'class A {}' > Game/Assets/A.cs; echo s > Game/Assets/InitTestScene0a1b2c3d.unity; echo m > Game/Assets/InitTestScene0a1b2c3d.unity.meta
echo '<test-run/>' > Game/editmode.xml; echo '<x/>' > Game/kept.xml; echo '{"a":2}' > Game/Packages/packages-lock.json
( . "$HERE/lib/platform.sh"; . "$HERE/lib/auto.sh"; git add -A; auto_unjunk "$J" )
staged="$(git diff --cached --name-only | tr -d '\r' | sort | paste -sd' ' -)"
[ "$staged" = "Game/Assets/A.cs Game/kept.xml" ] && ok "WIP commit: InitTestScene, test result XML and lock without manifest change stay out, real work goes in" || no "staged: $staged"
[ -f Game/editmode.xml ] && [ -f Game/Assets/InitTestScene0a1b2c3d.unity ] && ok "the left out files stay on disk" || no "junk files deleted"
echo '{"b":1}' > Game/Packages/manifest.json; ( . "$HERE/lib/platform.sh"; . "$HERE/lib/auto.sh"; git add -A; auto_unjunk "$J" )
git diff --cached --name-only | grep -q 'packages-lock.json' && ok "a lock that goes with a manifest change is committed" || no "lock with manifest change dropped"
printf 'world_outputs=Assets/Generated\n' > Game/warmd.conf; mkdir -p Game/Assets/Generated; echo g > Game/Assets/Generated/level.asset; echo 'class B {}' > Game/Assets/B.cs
( . "$HERE/lib/platform.sh"; . "$HERE/lib/auto.sh"; git add -A; auto_unjunk "$J" )
staged="$(git diff --cached --name-only | tr -d '\r' | grep -v -e Packages/ -e A.cs -e kept.xml | sort | paste -sd' ' -)"
[ "$staged" = "Game/Assets/B.cs Game/warmd.conf" ] && ok "world_outputs stay out of an automatic commit" || no "world outputs staged: $staged"

# ---- the warmd block in CLAUDE.md stays current: init and the session start renew it ----
cd "$R" || exit 1
printf '# Project\n\nOwn rules, warmd mentioned here.\n' > CLAUDE.md
"$WARMD" init >/dev/null 2>&1
grep -qF '<!-- warmd: kept current by warmd' CLAUDE.md && grep -qF 'at most 2 lines, result first' CLAUDE.md && grep -q '^Own rules, warmd mentioned here.$' CLAUDE.md && ok "init adds the block although the file mentions warmd" || no "init block: $(cat CLAUDE.md)"
sed -i 's/at most 2 lines, result first/old text/' CLAUDE.md; echo "old" > .claude/agents/warmd-worker.md
out="$(printf '{"source":"startup"}' | "$WARMD" hook-session)"
grep -qF 'at most 2 lines, result first' CLAUDE.md && ! grep -q 'old text' CLAUDE.md && [ "$(grep -c 'kept current by warmd' CLAUDE.md)" = 1 ] && echo "$out" | grep -q 'warmd block in CLAUDE.md renewed' && ok "session start renews an outdated block once, in place" || no "session renew: $out $(cat CLAUDE.md)"
cmp -s .claude/agents/warmd-worker.md "$HERE/agents/warmd-worker.md" && echo "$out" | grep -q 'agent definitions renewed: warmd-worker.md' && ok "session start renews an outdated agent definition" || no "agent def: $out"
out="$(printf '{"source":"startup"}' | "$WARMD" hook-session)"; echo "$out" | grep -q 'renewed' && no "renewed twice: $out" || ok "a current block is left alone"
printf '# P\n\n## warmd\n\nUse `warmd` for every build, test and screenshot.\n\n- Short replies: result first, no preamble.\n\n## Other\nkeep\n' > "$TMP/legacy.md"
( . "$HERE/lib/platform.sh"; WARMD_HOME="$HERE"; . "$HERE/lib/core.sh"; instr_sync "$TMP/legacy.md" )
! grep -q 'Short replies' "$TMP/legacy.md" && grep -q '^keep$' "$TMP/legacy.md" && [ "$(grep -c '^## warmd$' "$TMP/legacy.md")" = 1 ] && ok "an older unmarked block is replaced, the sections after it stay" || no "legacy: $(cat "$TMP/legacy.md")"

# ---- a handoff carries the green runs from warmd's own record, not from the agent's memory ----
cd "$R" || exit 1
printf 'hh | add hh | hh.txt exists | hh.txt\n' > "$TMP/hh.txt"; WARMD_NO_PREWARM=1 WARMD_BASE=1 "$WARMD" split "$TMP/hh.txt" > /dev/null 2>&1
( cd "$W/hh" && echo hh > hh.txt && git add hh.txt && git commit -qm hh && WARMD_NOCACHE=1 "$WARMD" test >/dev/null 2>&1; "$WARMD" handoff hh "hh written" "nothing" >/dev/null 2>&1 )
sha="$(git -C "$W/hh" rev-parse --short HEAD)"
grep -q "^- test all: green at $sha, " "$C/warmd-handoff/hh.md" 2>/dev/null && ok "handoff note lists the green run with commit and time" || no "handoff note: $(cat "$C/warmd-handoff/hh.md" 2>/dev/null)"

cd /; rm -rf "$TMP" "$(dirname "$R")/.warmd-worktrees" 2>/dev/null
[ $fails = 0 ] && echo "auto: all ok" || { echo "auto: $fails failed"; exit 1; }
