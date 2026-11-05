#!/usr/bin/env bash
# Machine tuning: slots, threads, cache, warmd.conf priority. No engine needed.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
TMP="$(mktemp -d)"
export XDG_CACHE_HOME="$TMP/cache"
unset WARMD_CORES WARMD_RAM_MB
# The suite waits once at its start until RAM is free, like any heavy run (lib/tune.sh tune_wait_ram). The wait itself stays on.
bash -c ". '$HERE/lib/platform.sh'; CACHE_ROOT='$TMP/ramwait'; common_doctor() { :; }; slot_take() { :; }; orphan_check() { :; }; . '$HERE/lib/tune.sh'; tune_wait_ram"
fails=0
expect() { if echo "$3" | grep -qE "$2"; then echo "ok   $1"; else echo "FAIL $1: wanted /$2/, got: $(echo "$3" | head -3)"; fails=$((fails+1)); fi; }
mkdir -p "$TMP/app"; cd "$TMP/app" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
echo '{ "name": "t" }' > package.json; printf '.warmd\n' > .gitignore
git add -A; git commit -qm init
slots() { WARMD_CORES="$1" WARMD_RAM_MB="$2" "$WARMD" status | grep -oE 'of [0-9]+$'; }
expect "8 cores 31 GB give 2 slots" 'of 2$' "$(slots 8 31744)"
expect "RAM is the limit" 'of 1$' "$(slots 16 12000)"
expect "cores are the limit" 'of 1$' "$(slots 2 65536)"
expect "never below 1" 'of 1$' "$(slots 1 1024)"
expect "big machine" 'of 4$' "$(slots 16 131072)"
expect "doctor reports 2 heavy slots on 8 cores 31 GB" 'heavy slots: 2 ' "$(WARMD_CORES=8 WARMD_RAM_MB=31744 "$WARMD" doctor)"
expect "doctor shows threads" 'threads per run: 3 .*Unity job workers: 3.*2 cores stay free' "$(WARMD_CORES=8 WARMD_RAM_MB=31744 "$WARMD" doctor)"
printf 'slots=3\n' > warmd.conf
expect "warmd.conf slots wins" 'of 3$' "$(slots 8 31744)"
printf 'threads=5\nunity_workers=7\n' > warmd.conf
expect "warmd.conf threads and workers win" 'threads per run: 5 .*workers: 7' "$(WARMD_CORES=8 WARMD_RAM_MB=31744 "$WARMD" doctor)"
rm warmd.conf
# real read: cached, and a second call does not read the system again
"$WARMD" status > /dev/null
expect "hardware cached" '^[0-9]+ [0-9]+$' "$(cat "$XDG_CACHE_HOME/warmd/hw" 2>/dev/null)"
echo "6 24576" > "$XDG_CACHE_HOME/warmd/hw"
expect "cache is used" 'of 1$' "$("$WARMD" status | grep -oE 'of [0-9]+$')"
echo "32 262144" > "$XDG_CACHE_HOME/warmd/hw"
expect "cache is used, large" 'of 8$' "$("$WARMD" status | grep -oE 'of [0-9]+$')"
rm -f "$XDG_CACHE_HOME/warmd/hw"

# ---- free RAM: a light suite (this web project) waits only below 3 percent, an engine below 15; warmd.conf limits win ----
cat > package.json <<'J'
{ "name": "t", "scripts": { "test": "echo ran" } }
J
export WARMD_CORES=8 WARMD_RAM_MB=31744 WARMD_RAM_POLL=1 WARMD_NOCACHE=1
out="$(WARMD_FREE_PCT=2 WARMD_RAM_WAIT=2 "$WARMD" test)"
expect "low RAM queues with one line" 'queued: only 2% RAM free, waiting for 3%' "$out"
expect "wait is bounded, run goes on" 'running anyway' "$out"
expect "after running anyway no false free-again line" '^$' "$(echo "$out" | grep 'RAM free again')"
expect "one warmd call waits once, not per build and test" '^1$' "$(echo "$out" | grep -c 'queued: only')"
expect "enough RAM runs without a wait" '^OK' "$(WARMD_FREE_PCT=40 "$WARMD" test)"
out="$(WARMD_FREE_PCT=7 WARMD_RAM_WAIT=2 "$WARMD" test)"
expect "a light suite at 7 percent free runs at once, the 15 percent limit is for engines" '^OK' "$out"
expect "and says no queue line" '^$' "$(echo "$out" | grep queued)"
expect "an engine still waits below 15 percent" 'waiting for 15%' "$(bash -c ". '$HERE/lib/platform.sh'; KIND=unity; WARMD_FREE_PCT=7 WARMD_RAM_WAIT=1 WARMD_RAM_POLL=1; orphan_check() { :; }; . '$HERE/lib/tune.sh'; tune_wait_ram")"
printf 'ram_free_min_light=0
' > warmd.conf
expect "ram_free_min_light=0 switches the wait off" '^OK' "$(WARMD_FREE_PCT=1 "$WARMD" test)"
printf 'ram_free_min_light=50
' > warmd.conf
expect "warmd.conf ram_free_min_light wins" 'queued: only 40% RAM free, waiting for 50%' "$(WARMD_FREE_PCT=40 WARMD_RAM_WAIT=1 "$WARMD" test)"
rm warmd.conf

# ---- a green-cache hit never waits for RAM or a slot; ram_wait=0 and WARMD_NO_RAM_WAIT=1 switch the wait off ----
printf 'slots=1\n' > warmd.conf   # before the fill: warmd.conf is part of the code key
export WARMD_NOCACHE=1; "$WARMD" test > /dev/null; unset WARMD_NOCACHE   # fills the green cache
mkdir -p "$XDG_CACHE_HOME/warmd/slots/1"; echo $$ > "$XDG_CACHE_HOME/warmd/slots/1/pid"   # the only slot is held by a live process
t0=$(date +%s)
out="$(WARMD_FREE_PCT=1 WARMD_RAM_WAIT=60 "$WARMD" test)"
expect "cache hit returns at once" 'OK cached' "$out"
expect "cache hit has no queue line" '^0$' "$(echo "$out" | grep -c queued)"
[ $(( $(date +%s) - t0 )) -lt 5 ] && echo "ok   cache hit took under 5s with full slots and low RAM" || { echo "FAIL cache hit waited"; fails=$((fails+1)); }
rm -rf "$XDG_CACHE_HOME/warmd/slots/1"; rm warmd.conf
export WARMD_NOCACHE=1
expect "a real run still waits for RAM" 'queued: only 1% RAM free' "$(WARMD_FREE_PCT=1 WARMD_RAM_WAIT=1 "$WARMD" test)"
out="$(WARMD_NO_RAM_WAIT=1 WARMD_FREE_PCT=1 "$WARMD" test)"
expect "WARMD_NO_RAM_WAIT=1 skips the wait" '^OK' "$out"
expect "WARMD_NO_RAM_WAIT=1 has no queue line" '^0$' "$(echo "$out" | grep -c queued)"
printf 'ram_wait=0\n' > warmd.conf
out="$(WARMD_FREE_PCT=1 "$WARMD" test)"
expect "ram_wait=0 skips the wait" '^OK' "$out"
expect "ram_wait=0 has no queue line" '^0$' "$(echo "$out" | grep -c queued)"
rm warmd.conf; unset WARMD_NOCACHE
expect "no missing-file noise without a cache dir" '^0$' "$(XDG_CACHE_HOME="$TMP/fresh" WARMD_GPU="" "$WARMD" doctor 2>&1 | grep -c 'No such file')"

# ---- low priority and the 2 free cores ----
expect "child runs with nice" 'nice -n 10' "$(bash -c ". '$HERE/lib/platform.sh'; CACHE_ROOT=$TMP/c; common_doctor() { :; }; slot_take() { :; }; . '$HERE/lib/tune.sh'; tune_prefix")"
expect "2 cores free on 2 cores" 'threads per run: 1 ' "$(WARMD_CORES=2 WARMD_RAM_MB=65536 "$WARMD" doctor)"
expect "2 cores free on 16 cores" 'threads per run: 3 ' "$(WARMD_CORES=16 WARMD_RAM_MB=65536 "$WARMD" doctor)"

# ---- the slot limit holds across separate processes, also with dead owners lying around ----
mkdir -p "$TMP/conc"; cd "$TMP/conc" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
echo '{ "name": "t" }' > package.json; printf '.warmd
live
peak
' > .gitignore
cat > hold.sh <<'H'
#!/bin/sh
# counts the runs that are active at the same time
mkdir -p live; mkdir "live/$$"; n=$(ls live | wc -l | tr -d " ")
echo "$n" >> peak
sleep 2
rmdir "live/$$"
H
printf 'test=sh ./hold.sh
slots=2
ram_free_min=0
' > warmd.conf
git add -A; git commit -qm init
SL="$XDG_CACHE_HOME/warmd/slots"; mkdir -p "$SL/1" "$SL/2"; echo 999999 > "$SL/1/pid"; echo 999998 > "$SL/2/pid"   # dead owners
for i in 1 2 3 4 5 6; do WARMD_DETACHED=1 "$WARMD" test "f$i" > "out$i" 2>&1 & done
wait
peak="$(sort -n peak | tail -1)"; runs="$(wc -l < peak | tr -d ' ')"
expect "all 6 runs happened" '^6$' "$runs"
expect "never more than 2 heavy runs at once (peak $peak)" '^[12]$' "$peak"
unset WARMD_NOCACHE

# ---- GPU: one graphics place per 6 GB VRAM, own queue, conf wins ----
gslots() { WARMD_GPU="$1" "$WARMD" doctor | grep -oE 'graphics slots: [0-9]+'; }
expect "12 GB card gives 2 graphics slots" 'slots: 2$' "$(gslots '0|12227|RTX')"
expect "24 GB card gives 4" 'slots: 4$' "$(gslots '0|24576|RTX')"
expect "8 GB card gives 1" 'slots: 1$' "$(gslots '0|8192|RTX')"
expect "no GPU still gives 1" 'slots: 1$' "$(gslots '0|0|none')"
expect "doctor shows GPU name and VRAM" 'gpu: RTX, 12 GB VRAM, device index 0' "$(WARMD_GPU='0|12227|RTX' "$WARMD" doctor)"
printf 'gfx_slots=3
' > warmd.conf
expect "warmd.conf gfx_slots wins" 'slots: 3$' "$(gslots '0|8192|RTX')"
rm warmd.conf
gfx_flag() { bash -c ". '$HERE/lib/platform.sh'; CACHE_ROOT='$TMP/gc'; common_doctor() { :; }; slot_take() { :; }; . '$HERE/lib/tune.sh'; WARMD_GPU='$1' tune_unity_gpu_flag"; }
expect "second GPU picks -force-device-index" '^-force-device-index 1$' "$(gfx_flag '1|24000|X')"
expect "first GPU needs no flag" '^$' "$(gfx_flag '0|24000|X')"
cat > "$TMP/gfxrun.sh" <<'H'
. "$1/lib/platform.sh"; CACHE_ROOT="$2"; SLOT=""; LOCK=""; JOBLOCK=""; MERGELOCK=""; PARENT_PID=1
common_doctor() { :; }; slot_take() { :; }; orphan_check() { :; }
. "$1/lib/tune.sh"; CFG_gfx_slots=1
trap on_exit EXIT
gfx_take > /dev/null; mkdir -p "$3/live"; mkdir "$3/live/$$"; ls "$3/live" | wc -l | tr -d " " >> "$3/peak"; sleep 1; rmdir "$3/live/$$"
H
mkdir -p "$TMP/gq"
for i in 1 2 3; do bash "$TMP/gfxrun.sh" "$HERE" "$TMP/gc2" "$TMP/gq" & done; wait
expect "graphics queue holds 1 place at a time" '^1$' "$(sort -n "$TMP/gq/peak" | tail -1)"
expect "all 3 graphics runs happened" '^3$' "$(wc -l < "$TMP/gq/peak" | tr -d ' ')"
# ---- warmd status: free RAM, Unity editors with their project, the batch per branch; warmd stop ends other editors on this project ----
. "$HERE/lib/platform.sh"
U="$TMP/uproj"; mkdir -p "$U/ProjectSettings" "$TMP/fake"; printf 'm_EditorVersion: 6000.0.0f1\n' > "$U/ProjectSettings/ProjectVersion.txt"
( cd "$U" && git init -q -b main . && git config user.name t && git config user.email t@example.com && printf '.warmd\n' > .gitignore && git add -A && git commit -qm init && git worktree add -q -b warmd/side "$TMP/uside" )
( cd "$TMP/uside" && pwd ) > "$(git -C "$U" rev-parse --path-format=absolute --git-common-dir)/warmd-batch"
printf 'for i in $(seq 60); do sleep 1; done\n' > "$TMP/fake/Unity"
UN="$(native_path "$U")"
bash "$TMP/fake/Unity" -batchmode -nographics -projectPath "$UN" & f1=$!
bash "$TMP/fake/Unity" -batchmode -projectPath "${UN}2" & f2=$!
sleep 2
out="$(cd "$U" && "$WARMD" status 2>&1)"
expect "status: free RAM in MB and percent" '^RAM free: [0-9]+ MB of [0-9]+ MB \([0-9]+%\)$' "$out"
expect "status: a Unity editor with its project" "^Unity pid [0-9]+: $UN \(batchmode\), this project$" "$out"
expect "status: the batch per branch, last commit and its age" '^batch warmd/side: [0-9a-f]+ [0-9]+ min ago, init$' "$out"
out="$(cd "$U" && WARMD_STOP_GRACE=1 "$WARMD" stop 2>&1)"
expect "stop ends another tool's editor on exactly this project" '^OK stopped other Unity pid [0-9]+ on this project \((friendly|hard), batchmode\)$' "$out"
sleep 1; kill -0 $f1 2>/dev/null && echo "FAIL the editor on this project still runs" && fails=$((fails+1)) || echo "ok   the editor on this project is gone"
kill -0 $f2 2>/dev/null && echo "ok   an editor on another project path stays" || { echo "FAIL the editor on ${UN}2 was ended"; fails=$((fails+1)); }
kill $f2 2>/dev/null; wait $f1 $f2 2>/dev/null
if [ "$OS" = win ]; then
  bash "$TMP/fake/Unity" -projectPath "$UN" & f3=$!; sleep 2
  expect "an editor with a window is only asked, it may hold unsaved work" '^WARN Unity pid [0-9]+ has this project open in a window' "$(cd "$U" && "$WARMD" stop 2>&1)"
  kill -0 $f3 2>/dev/null && echo "ok   the window editor stays open" || { echo "FAIL the window editor was ended without --force"; fails=$((fails+1)); }
  expect "stop --force ends it" '^OK stopped other Unity pid [0-9]+ on this project \((friendly|hard)\)$' "$(cd "$U" && WARMD_STOP_GRACE=1 "$WARMD" stop --force 2>&1)"
  kill $f3 2>/dev/null; wait $f3 2>/dev/null
fi

# ---- another tool's batchmode editor on a batch worktree no longer blocks the start: it is ended, the run goes on ----
V="$TMP/ubatch"; mkdir -p "$V/ProjectSettings" "$V/Assets/Editor/Warmd"; printf 'm_EditorVersion: 6000.0.0f1\n' > "$V/ProjectSettings/ProjectVersion.txt"; cp "$HERE"/unity/* "$V/Assets/Editor/Warmd/"
( cd "$V" && git init -q -b main . && git config user.name t && git config user.email t@example.com && printf '.warmd\n' > .gitignore && git add -A && git commit -qm init )
git -C "$V" rev-parse --show-toplevel > "$(git -C "$V" rev-parse --path-format=absolute --git-common-dir)/warmd-batch"   # the form git reports: runner temp paths come in 8.3 and long spellings
VN="$(native_path "$V")"
bash "$TMP/fake/Unity" -batchmode -nographics -projectPath "$VN" & f4=$!; sleep 2
out="$(cd "$V" && WARMD_STOP_GRACE=1 WARMD_UNITY=/nonexistent/Unity WARMD_NO_RAM_WAIT=1 "$WARMD" test 2>&1)"
expect "a batchmode editor of another tool on a batch worktree is ended" "^\(ended another tool's batchmode Unity pid [0-9]+ on this batch worktree, (friendly|hard)\)$" "$out"
expect "and the start goes on" '^FAIL Unity 6000.0.0f1 not found' "$out"
sleep 1; kill -0 $f4 2>/dev/null && { echo "FAIL the blocking editor still runs"; fails=$((fails+1)); } || echo "ok   the blocking editor is gone"
wait $f4 2>/dev/null
if [ "$OS" = win ]; then
  bash "$TMP/fake/Unity" -projectPath "$VN" & f5=$!; sleep 2
  err="$(cd "$V" && WARMD_UNITY=/nonexistent/Unity WARMD_NO_RAM_WAIT=1 "$WARMD" test 2>&1 >/dev/null)"
  expect "a window editor blocks with a reason on stderr too" '^FAIL another Unity \(pid [0-9]+\) has this project open' "$err"
  expect "and in result.txt, not counted as red" '^blocked BLOCKED another Unity' "$(head -1 "$V/.warmd/run/result.txt" 2>/dev/null)"
  kill -0 $f5 2>/dev/null && echo "ok   a window editor is never ended by a start" || { echo "FAIL window editor ended"; fails=$((fails+1)); }
  kill $f5 2>/dev/null; wait $f5 2>/dev/null
fi

rm -rf "$TMP"
[ "$fails" = 0 ] && echo "ALL OK" || { echo "$fails failed"; exit 1; }
