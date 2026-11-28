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
expect "a check that ran tests ends with one result line" '^OK [0-9]+s check: compiled, tests green$' "$(echo "$out" | tail -1)"
expect "a cache hit ends with a result line too" '^OK [0-9]+s check: compiled, .*green from the cache$' "$(WARMD_NOCACHE=0 "$WARMD" check 2>&1 | tail -1)"
change warmd.conf
out="$("$WARMD" check 2>&1)"
expect "a change no test belongs to runs nothing" '^none$' "$(ran)"
expect "a check with no test touched still ends with a result line" '^OK [0-9]+s check: compiled, no tests affected$' "$(echo "$out" | tail -1)"
# caches and editor droppings never count as a change
refuse() { if echo "$3" | grep -qE "$2"; then no "$1: $(echo "$3" | grep -E "$2" | head -2)"; else ok "$1"; fi; }
git checkout -qB "w$RANDOM"; mkdir -p Art/__pycache__; : > Art/__pycache__/x.cpython-312.pyc; : > .DS_Store; rm -f ran.txt
out="$("$WARMD" check 2>&1)"; expect "pycache and .DS_Store start no test" '^none$' "$(ran)"
refuse "pycache and .DS_Store are no change" 'pycache|DS_Store|running all' "$out"
rm -rf Art .DS_Store

# ---- red cache: the same red call on the same state answers at once, with the saved log; WARMD_NOCACHE, age and flaky reds run again ----
change lib/beta.sh
WARMD_NOCACHE=0 "$WARMD" check >/dev/null 2>&1; rc1=$?
expect "a red run starts its test" '^beta$' "$(ran)"; rm -f ran.txt
out="$(WARMD_NOCACHE=0 "$WARMD" check 2>&1)"; rc2=$?
expect "the same red call runs nothing again" '^none$' "$(ran)"
expect "it answers from the red cache" '^RED cached, code unchanged: .*\. Change code first\. Log: ' "$out"
[ $rc1 != 0 ] && [ $rc2 = $rc1 ] && ok "a cached red keeps the exit code ($rc1)" || no "cached red exited $rc2, the run $rc1"
lg="$(echo "$out" | sed -n 's/.*Change code first\. Log: //p' | head -1)"
[ -n "$lg" ] && grep -q 'FAIL' "$lg" 2>/dev/null && ok "the saved log holds the cause" || no "saved log missing or empty: $lg"
WARMD_NOCACHE=1 "$WARMD" check >/dev/null 2>&1
expect "WARMD_NOCACHE=1 runs a cached red again" '^beta$' "$(ran)"; rm -f ran.txt
for r in "$XDG_CACHE_HOME"/warmd/red/*; do case "$r" in *.log) ;; *) { read -r a b; read -r l; } < "$r"; printf '%s %s\n%s\n' "$a" $(( b - 7300 )) "$l" > "$r";; esac; done
WARMD_NOCACHE=0 "$WARMD" check >/dev/null 2>&1
expect "a red older than 2 hours runs again" '^beta$' "$(ran)"
git checkout -q main; git checkout -qB "w$RANDOM"; printf 'echo beta >> "%s/ran.txt"; echo "FAIL timeout after 900s"; exit 1\n' "$P" > tests/beta.sh; git commit -qam flaky; rm -f ran.txt
WARMD_NOCACHE=0 "$WARMD" check >/dev/null 2>&1; rm -f ran.txt; WARMD_NOCACHE=0 "$WARMD" check >/dev/null 2>&1
expect "a timeout red is never cached" '^beta$' "$(ran)"
printf 'echo run >> "%s/ran.txt"; exit 137\n' "$P" > tests/run.sh; echo '# k' >> lib/notest.sh; git commit -qam killed; rm -f ran.txt
WARMD_NOCACHE=0 "$WARMD" check >/dev/null 2>&1; rm -f ran.txt; WARMD_NOCACHE=0 "$WARMD" check >/dev/null 2>&1
expect "a killed run (exit 137) is never cached" '^run$' "$(ran)"
# One killed test inside the sh suite loop: it is named, and the same call runs it again instead of a red cache answer
git checkout -q main; git checkout -qB "w$RANDOM"; printf 'echo beta >> "%s/ran.txt"; exit 137\n' "$P" > tests/beta.sh; echo '# k' >> lib/beta.sh; git commit -qam killed1; rm -f ran.txt
out="$(WARMD_NOCACHE=0 "$WARMD" check 2>&1)"
expect "a single killed sh test is named" 'beta killed \(exit 137\)' "$out"
rm -f ran.txt; out="$(WARMD_NOCACHE=0 "$WARMD" check 2>&1)"
expect "a single killed sh test is never red-cached" '^beta$' "$(ran)"
refuse "the second call is no red cache answer" '^RED cached' "$out"
git checkout -q main


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
printf 'test=sleep 20\n' > warmd.conf; printf '.warmd\n' > .gitignore; git add -A; git commit -qm init
WARMD_DETACHED=1 "$WARMD" test > "$TMP/bg.out" 2>&1 & bg=$!
for _ in $(seq 300); do ls .warmd/run/active/* >/dev/null 2>&1 && break; sleep 0.2; done
out="$("$WARMD" stop --idle 2>&1)"; expect "stop --idle keeps the engine while a warmd test of this project runs" '^OK engine kept, warmd test runs here' "$out [marks: $(ls .warmd/run/active 2>&1 | paste -sd' ' -), bg pid $bg]"
wait $bg; expect "the background test was not cut off" '^OK .*test' "$(tail -1 "$TMP/bg.out")"
[ -z "$(ls .warmd/run/active 2>/dev/null)" ] && ok "the run mark goes with the run" || no "run mark left: $(ls .warmd/run/active)"
expect "stop --idle stops once the run is over" '^OK nothing warm' "$("$WARMD" stop --idle 2>&1)"
cd "$HERE" || exit 1

# ---- the stop hook of an agent that waits for its own background run records nothing; a queued run is no failure ----
cd "$Q" || exit 1
QC="$(git rev-parse --path-format=absolute --git-common-dir)"
WARMD_DETACHED=1 "$WARMD" test > /dev/null 2>&1 & bg=$!
for _ in $(seq 300); do ls .warmd/run/active/* >/dev/null 2>&1 && break; sleep 0.2; done
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

# ---- disk: a merged worktree gives its Library back; a fresh one, an unmerged one and the running batch keep theirs ----
U="$TMP/udisk"; mkdir -p "$U/ProjectSettings" "$U/Assets"; cd "$U" || exit 1
printf 'm_EditorVersion: 6000.0.0f1\n' > ProjectSettings/ProjectVersion.txt
git init -q -b main .; git config user.name t; git config user.email t@example.com; printf '.warmd\nLibrary\n' > .gitignore; git add -A; git commit -qm init
git worktree add -q -b warmd/done "$TMP/ud-done"; (cd "$TMP/ud-done" && echo d > d.txt && git add d.txt && git commit -qm d); git merge -q --no-ff -m "Merge warmd/done" warmd/done
git worktree add -q -b warmd/fresh "$TMP/ud-fresh"
git worktree add -q -b warmd/open "$TMP/ud-open"; (cd "$TMP/ud-open" && echo o > o.txt && git add o.txt && git commit -qm o)
git worktree add -q -b warmd/batch "$TMP/ud-batch"; (cd "$TMP/ud-batch" && echo b > b.txt && git add b.txt && git commit -qm b); git merge -q --no-ff -m "Merge warmd/batch" warmd/batch
(cd "$TMP/ud-batch" && pwd) > "$(git rev-parse --path-format=absolute --git-common-dir)/warmd-batch"
for w in done fresh open batch; do mkdir -p "$TMP/ud-$w/Library"; echo x > "$TMP/ud-$w/Library/ArtifactDB"; done
expect "disk lists what a merge would free" 'note: 1 finished worktrees hold a Library' "$(WARMD_BASE=1 "$WARMD" disk 2>&1)"
out="$(WARMD_BASE=1 "$WARMD" disk --free 2>&1)"
expect "disk --free frees the Library of a just merged worktree, removes none in its first 30 minutes" '^OK removed 0 merged worktrees, freed the caches of 1 others' "$out"
[ ! -e "$TMP/ud-done/Library" ] && [ -d "$TMP/ud-fresh/Library" ] && [ -d "$TMP/ud-open/Library" ] && [ -d "$TMP/ud-batch/Library" ] && ok "fresh, unmerged and batch worktrees keep their Library" || no "freed wrong: $out"
expect "disk below disk_min_mb is reported" '^LOW disk: .* GB free on ' "$(WARMD_BASE=1 WARMD_DISK_MIN_MB=999999999 "$WARMD" disk 2>&1)"
rm -f "$(git rev-parse --path-format=absolute --git-common-dir)/warmd-batch"
cd "$HERE" || exit 1

# Committed work of an unknown language, no test=: not "no code changed", and no file of the task is missed.
Q="$TMP/luau"; mkdir -p "$Q"; cd "$Q" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
echo a > a.luau; git add -A; git commit -qm init; git checkout -qb task; echo b >> a.luau; git commit -qam work
out="$("$WARMD" check 2>&1)"
expect "committed luau work is reported as changed" 'OK 1 files changed against main, no test=' "$out"
cd "$HERE" || exit 1

# ---- cache key: a git-ignored engine binary, export_presets.cfg and the warmd version count, the engine starts once per binary ----
G="$TMP/gd"; mkdir -p "$G"; cd "$G" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
: > project.godot; printf 'godot.x86_64\nexport_presets.cfg\ncalls.txt\n.warmd\n' > .gitignore; git add -A; git commit -qm init
printf '#!/bin/sh\necho v >> "%s/calls.txt"; echo 4.3.stable\n' "$G" > godot.x86_64; chmod +x godot.x86_64
gkey() { ( cd "$G" && WARMD_HOME="$HERE" && . "$HERE/lib/platform.sh" && . "$HERE/lib/core.sh" && detect_project >/dev/null 2>&1 && load_config 2>/dev/null; . "$HERE/adapters/godot.sh"; code_key ) 2>/dev/null; }
k1="$(gkey)"; k2="$(gkey)"
[ -n "$k1" ] && [ "$k1" = "$k2" ] && ok "same engine, same key" || no "key unstable: '$k1' '$k2'"
expect "the engine version is asked once per binary" '^1$' "$(wc -l < calls.txt | tr -d ' ')"
printf '#!/bin/sh\necho v >> "%s/calls.txt"; echo 4.4.1.stable\n' "$G" > godot.x86_64
k3="$(gkey)"; [ "$k3" != "$k1" ] && ok "a new git-ignored engine binary changes the key" || no "engine update kept key $k1"
expect "the new binary is asked once" '^2$' "$(wc -l < calls.txt | tr -d ' ')"
echo 'preset' > export_presets.cfg; k4="$(gkey)"
[ "$k4" != "$k3" ] && ok "a git-ignored export_presets.cfg changes the key" || no "export_presets.cfg not in the key"
k5="$(WARMD_VERSION=9.9.9 gkey)"; [ "$k5" != "$k4" ] && ok "the warmd version changes the key" || no "warmd version not in the key"
k6="$(WARMD_GFX=1 gkey)"; [ "$k6" != "$k4" ] && ok "WARMD_GFX changes the key" || no "WARMD_GFX not in the key"
cd "$HERE" || exit 1

echo
[ $fails = 0 ] && echo "all green" || echo "$fails failed"
cd "$HERE" || exit 1; rm -rf "$TMP" 2>/dev/null
exit $fails
