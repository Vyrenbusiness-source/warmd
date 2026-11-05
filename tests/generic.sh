#!/usr/bin/env bash
# Shell projects like warmd itself: warmd check runs only the tests/*.sh that belong to the changed files.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
TMP="$(mktemp -d)"
export XDG_CACHE_HOME="$TMP/cache" WARMD_NOCACHE=1 WARMD_SELECT=1   # selection under test, the shortcut has its own block
fails=0
. "$HERE/lib/platform.sh"
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails+1)); }
expect() { if echo "$3" | grep -qE "$2"; then ok "$1"; else no "$1: wanted /$2/, got: $(echo "$3" | head -3)"; fi; }

# Every test writes its name to ran.txt, so the test sees which ones warmd started
P="$TMP/shp"; mkdir -p "$P/bin" "$P/lib" "$P/adapters" "$P/tests/e2e" "$P/docs"; cd "$P" || exit 1
git init -q -b main .; git config core.autocrlf false; git config user.name t; git config user.email t@example.com
for t in run alpha web e2e docs; do printf 'echo %s >> "%s/ran.txt"\n' "$t" "$P" > "tests/$t.sh"; done
printf 'echo beta >> "%s/ran.txt"; exit 1\n' "$P" > tests/beta.sh
echo 'echo hi' > bin/tool; echo 'a=1' > lib/alpha.sh; echo 'b=1' > lib/beta.sh; echo 'n=1' > lib/notest.sh
echo 'w=1' > adapters/web.sh; echo 'x' > tests/e2e/case.txt; echo doc > docs/A.md
printf 'test=bash tests/run.sh\n' > warmd.conf
printf '.warmd\nran.txt\n' > .gitignore; git add -A; git commit -qm init
change() { git checkout -q main 2>/dev/null; git checkout -qB "w$RANDOM"; local f; for f in "$@"; do echo "# $RANDOM" >> "$f"; done; git commit -qam c; rm -f ran.txt; }
ran() { [ -f ran.txt ] && sort ran.txt | paste -sd' ' - || echo none; }

change lib/alpha.sh
out="$("$WARMD" check 2>&1)"; rc=$?
expect "lib change runs its own test only" '^alpha$' "$(ran)"
expect "the affected file is named" 'affected: tests/alpha.sh' "$out"
[ $rc = 0 ] && ok "green own test exits zero" || no "green own test exited $rc: $out"

change adapters/web.sh tests/e2e/case.txt docs/A.md
"$WARMD" check >/dev/null 2>&1
expect "adapter, test folder and docs map to their tests" '^docs e2e web$' "$(ran)"

change lib/beta.sh lib/alpha.sh
out="$("$WARMD" check 2>&1)"; rc=$?
expect "every affected test runs, a red one does not stop the next" '^alpha beta$' "$(ran)"
[ $rc != 0 ] && ok "a red affected test makes check red" || no "red test exited zero: $out"

change bin/tool
"$WARMD" check >/dev/null 2>&1
expect "bin change runs the full suite" '^run$' "$(ran)"
change tests/run.sh
"$WARMD" check >/dev/null 2>&1
expect "tests/run.sh change runs the full suite" '^run$' "$(ran)"
# full=ci: the full suite never runs here, check says where it runs instead.
git checkout -q main; printf 'test=bash tests/run.sh\nfull=ci\n' > warmd.conf; git commit -qam "full on ci"
change bin/tool
out="$("$WARMD" check 2>&1)"; rc=$?
expect "full=ci runs nothing locally" '^none$' "$(ran)"
expect "full=ci says where the full suite runs" '^PUSH the full suite runs on CI only \(bin/tool changed, full=ci in warmd.conf\): push, then warmd ci$' "$out"
[ $rc = 0 ] && ok "full=ci exits zero" || no "full=ci exited $rc"
change lib/alpha.sh
"$WARMD" check >/dev/null 2>&1
expect "full=ci still runs the own test of a lib file" '^alpha$' "$(ran)"
git checkout -q main; printf 'test=bash tests/run.sh\n' > warmd.conf; git commit -qam "full local again"
# A scene Unity leaves behind after a dead PlayMode run is generated, not a change.
git checkout -qB "w$RANDOM"; mkdir -p Assets; : > Assets/InitTestScene2c6c14d8-bf74-4640-a858-d42fdaa3300d.unity; : > Assets/InitTestScene2c6c14d8-bf74-4640-a858-d42fdaa3300d.unity.meta; rm -f ran.txt
out="$("$WARMD" check 2>&1)"
expect "InitTestScene leftovers are no change" 'OK no code changed' "$out"
expect "InitTestScene leftovers start no test" '^none$' "$(ran)"
rm -rf Assets
change lib/notest.sh
out="$("$WARMD" check 2>&1)"
expect "a lib file without its own test falls back to the full suite" '^run$' "$(ran)"
expect "the reason is named" 'lib/notest.sh has no tests/notest.sh' "$out"
change warmd.conf
out="$("$WARMD" check 2>&1)"
expect "a change no test belongs to runs nothing" '^none$' "$(ran)"

# ---- small suite: when the full run is cheaper than build plus selection, check runs the full suite ----
S="$TMP/small"; mkdir -p "$S/src" "$S/tests"; cd "$S" || exit 1
git init -q -b main .; git config core.autocrlf false; git config user.name t; git config user.email t@example.com
echo 'v=1' > src/a.py; echo 'pass' > tests/test_a.py
printf 'build=sleep 4\ntest=true\n' > warmd.conf; printf '.warmd\n' > .gitignore; git add -A; git commit -qm init
git checkout -qb w1; echo 'v=2' > src/a.py; git commit -qam c
ms() { local s e; s="$(date +%s%N)"; "$@" >/dev/null 2>&1; e="$(date +%s%N)"; echo $(( (e - s) / 1000000 )); }
WARMD_SELECT=0 "$WARMD" test >/dev/null 2>&1
[ -s .warmd/full.ms ] && ok "a full warmd test records its time" || no "full.ms missing"
WARMD_SELECT=0 "$WARMD" check >/dev/null 2>&1
[ -s .warmd/check.ms ] && [ "$(cat .warmd/check.ms)" -ge 4000 ] && ok "a selective check records build plus selection" || no "check.ms: $(cat .warmd/check.ms 2>&1)"
out="$(WARMD_SELECT=0 "$WARMD" check 2>&1)"; t="$(ms env WARMD_SELECT=0 "$WARMD" check)"; sel="$(ms env WARMD_SELECT=1 "$WARMD" check)"
expect "small suite: check runs the full suite instead" '^\(running all tests: the full suite took' "$out"
# Same clock on both sides: a slow runner's warmd start-up counts for both
[ "$t" -lt "$sel" ] && ok "small suite: check ${t}ms stays under build plus selection ${sel}ms" || no "small suite: check took ${t}ms, build plus selection ${sel}ms"
WARMD_SELECT=1 "$WARMD" check 2>&1 | grep -q 'running all tests: the full suite' && no "WARMD_SELECT=1 still took the shortcut" || ok "WARMD_SELECT=1 keeps the selection"
echo 9999999 > .warmd/full.ms
WARMD_SELECT=0 "$WARMD" check 2>&1 | grep -q 'running all tests: the full suite' && no "a slow full suite still took the shortcut" || ok "a slow full suite keeps build plus selection"
cd "$HERE" || exit 1

# ---- an agent ended its turn while its own warmd test runs in the background: warmd stop --idle keeps the engine ----
Q="$TMP/bg"; mkdir -p "$Q"; cd "$Q" || exit 1
git init -q -b main .; git config core.autocrlf false; git config user.name t; git config user.email t@example.com
printf 'test=sleep 6\n' > warmd.conf; printf '.warmd\n' > .gitignore; git add -A; git commit -qm init
WARMD_DETACHED=1 "$WARMD" test > "$TMP/bg.out" 2>&1 & bg=$!
for _ in $(seq 50); do ls .warmd/run/active/* >/dev/null 2>&1 && break; sleep 0.2; done
expect "stop --idle keeps the engine while a warmd test of this project runs" '^OK engine kept, warmd test runs here' "$("$WARMD" stop --idle 2>&1)"
wait $bg; expect "the background test was not cut off" '^OK .*test' "$(tail -1 "$TMP/bg.out")"
[ -z "$(ls .warmd/run/active 2>/dev/null)" ] && ok "the run mark goes with the run" || no "run mark left: $(ls .warmd/run/active)"
expect "stop --idle stops once the run is over" '^OK nothing warm' "$("$WARMD" stop --idle 2>&1)"
cd "$HERE" || exit 1

# ---- the stop hook of an agent that waits for its own background run records nothing; a queued run is no failure ----
cd "$Q" || exit 1
QC="$(git rev-parse --path-format=absolute --git-common-dir)"
WARMD_DETACHED=1 "$WARMD" test > /dev/null 2>&1 & bg=$!
for _ in $(seq 50); do ls .warmd/run/active/* >/dev/null 2>&1 && break; sleep 0.2; done
out="$("$WARMD" hook-job bgtask "$Q" 100 2 escalated 2>&1)"
expect "stop hook during the agent's own run: nothing recorded" 'bgtask: its warmd run still works or waits here, no stop recorded' "$out"
[ ! -f "$QC/warmd-batch-done" ] && [ ! -s "$QC/warmd-auto/queue" ] && ok "no batch-done line, no escalation queued" || no "recorded during a run: $(cat "$QC/warmd-batch-done" "$QC/warmd-auto/queue" 2>/dev/null)"
wait $bg
: > .warmd/run/queued
out="$("$WARMD" hook-job bgtask "$Q" 100 2 escalated 2>&1)"
[ ! -s "$QC/warmd-auto/queue" ] && [ ! -f "$QC/warmd-batch-done" ] && ok "a stop after a run that died in the queue is no failure: no escalation, task stays open" || no "queued stop escalated: $out $(cat "$QC/warmd-auto/queue" 2>/dev/null)"
rm -f .warmd/run/queued

# warmd watch holds an AGENT line back while the task's old agent still works
mkdir -p "$QC/warmd-auto" "$QC/warmd-handoff" .warmd/tasks
printf 'Task held. First run: cd "%s". Every command of this task runs there.\n' "$(native_path "$Q")" > .warmd/tasks/held.md
printf '%s\nmid\n' "$(native_path "$Q/.warmd/tasks/held.md")" > "$QC/warmd-handoff/held.task"
printf 'AGENT held: subagent_type=warmd-worker model=opus prompt="x"\nSHIP batch done\n' > "$QC/warmd-auto/queue"
drain() { ( cd "$Q" && WARMD_HOME="$HERE" && . "$HERE/lib/platform.sh" && . "$HERE/lib/core.sh" && detect_project >/dev/null 2>&1 && . "$HERE/lib/team.sh" && auto_drain "$QC" ); }
sleep 30 & s=$!; echo "- test" > ".warmd/run/active/$s"
out="$(WARMD_TRANSCRIPTS="$TMP/none" drain)"
[ "$out" = "SHIP batch done" ] && grep -q '^AGENT held:' "$QC/warmd-auto/queue" && ok "an AGENT line waits while the old agent's run is active, other lines go" || no "drain during a run: $out"
kill $s 2>/dev/null; wait $s 2>/dev/null
mkdir -p "$TMP/tr/s1/subagents"; echo '{"prompt":"Read .warmd/tasks/held.md"}' > "$TMP/tr/s1/subagents/agent-1.jsonl"
out="$(WARMD_TRANSCRIPTS="$TMP/tr" drain)"; rc=$?
[ $rc = 1 ] && grep -q '^AGENT held:' "$QC/warmd-auto/queue" && ok "an AGENT line waits while the old agent's transcript grows" || no "drain while talking: rc=$rc $out"
touch -d "-10 min" "$TMP/tr/s1/subagents/agent-1.jsonl"
out="$(WARMD_TRANSCRIPTS="$TMP/tr" drain)"
case "$out" in "AGENT held:"*) ok "the line goes once the old agent is quiet";; *) no "drain after: $out";; esac
cd "$HERE" || exit 1

# ---- a warmd test that ends inside the engine start never ends silently: reason and log ----
U="$TMP/usilent"; mkdir -p "$U/ProjectSettings" "$U/Assets/Editor/Warmd"; cd "$U" || exit 1
printf 'm_EditorVersion: 6000.0.0f1\n' > ProjectSettings/ProjectVersion.txt; cp "$HERE"/unity/* Assets/Editor/Warmd/
git init -q -b main .; git config user.name t; git config user.email t@example.com; printf '.warmd\n' > .gitignore; git add -A; git commit -qm init
out="$(WARMD_UNITY=/nonexistent/Unity WARMD_NO_RAM_WAIT=1 "$WARMD" test 2>&1)"; rc=$?
[ $rc != 0 ] && echo "$out" | grep -q '^FAIL Unity 6000.0.0f1 not found' && ok "a refusal inside the engine start is shown, exit $rc" || no "silent exit: rc=$rc out=[$out]"
expect "and closes with exit code and reason" "^FAIL warmd test ended with exit $rc" "$out"
cd "$HERE" || exit 1

echo
[ $fails = 0 ] && echo "all green" || echo "$fails failed"
cd "$HERE" || exit 1; rm -rf "$TMP" 2>/dev/null
exit $fails
