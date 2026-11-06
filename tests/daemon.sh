#!/usr/bin/env bash
# Unity daemon rounds without Unity: after a HUNG test the run goes on in a fresh editor without the tests that ran and the
# hung one, and every round ends up in one list. The daemon is a stub that answers like WarmdDaemon.cs. No engine needed.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; export XDG_CACHE_HOME="$TMP/cache"
trap 'rm -rf "$TMP"' EXIT
. "$HERE/lib/platform.sh"   # OS
fails=0
expect() { if echo "$3" | grep -qE "$2"; then echo "ok   $1"; else echo "FAIL $1: wanted /$2/, got: $(echo "$3" | head -4)"; fails=$((fails+1)); fi; }
refuse() { if echo "$3" | grep -qE "$2"; then echo "FAIL $1: $(echo "$3" | grep -E "$2" | head -2)"; fails=$((fails+1)); else echo "ok   $1"; fi; }

P="$TMP/game"; mkdir -p "$P/ProjectSettings" "$P/Assets"; printf 'm_EditorVersion: 6000.0.0f1\n' > "$P/ProjectSettings/ProjectVersion.txt"
( cd "$P" && git init -q -b main . && git config user.name t && git config user.email t@example.com && printf '.warmd\n' > .gitignore && git add -A && git commit -qm init )

# The stub plays one round per call from $SCRIPT: round N reads rounds/N.tests (tests.txt rows), rounds/N.hung (full name of
# the hung test, empty file = hung outside a test) and logs its arguments. A round without .hung ends green.
rounds() { # hung_resume -> output of unity_test_rounds, then "rc=N"
  ( cd "$P" && WARMD_HOME="$HERE" && . "$HERE/lib/platform.sh" && . "$HERE/lib/core.sh" && detect_project >/dev/null 2>&1 && . "$HERE/adapters/unity.sh" \
    && CFG_hung_resume="$1" && mkdir -p "$RUN" && rm -f "$TMP/calls" \
    && job() {
      local n; n=$(( $(cat "$TMP/calls" 2>/dev/null | wc -l) + 1 )); echo "$*" >> "$TMP/calls"
      case "$*" in *skip=*) cp "$(printf '%s\n' "$@" | sed -n 's/^skip=//p')" "$TMP/skip.$n";; esac
      rm -f "$RUN/tests.txt" "$RUN/current.full"
      [ -f "$TMP/rounds/$n.tests" ] && cp "$TMP/rounds/$n.tests" "$RUN/tests.txt"
      if [ -f "$TMP/rounds/$n.hung" ]; then
        [ -s "$TMP/rounds/$n.hung" ] && cp "$TMP/rounds/$n.hung" "$RUN/current.full"
        printf 'j%s FAIL 9s test\nHUNG %s: hung after 5s (test_timeout)\nbefore it: 1 passed\n' "$n" "$(sed 's/.*\.//' "$TMP/rounds/$n.hung")" > "$RUN/result.txt"
        sed '1s/^[^ ]* //' "$RUN/result.txt"; return 1
      fi
      printf 'j%s OK 3s test\n%s passed, 0 failed, 0 skipped\n' "$n" "$(grep -c . "$RUN/tests.txt")" > "$RUN/result.txt"
      sed '1s/^[^ ]* //' "$RUN/result.txt"; return 0
    } && unity_test_rounds mode=Play filter=Ship cat= speed= test_timeout=5; echo "rc=$?" )
}
mkdir -p "$TMP/rounds"
printf 'P\tGame.Tests.ShipTests.Floats\t\nF\tGame.Tests.ShipTests.Steers\tShipTests.cs:12 Expected 1 but was 2\n' > "$TMP/rounds/1.tests"
echo "Game.Tests.ShipTests.Docks" > "$TMP/rounds/1.hung"
printf 'P\tGame.Tests.ShipTests.Sinks\t\nP\tGame.Tests.ShipTests.Turns\t\n' > "$TMP/rounds/2.tests"

out="$(rounds 10)"
expect "after a HUNG the run goes on in a fresh editor" '^\(goes on after HUNG Docks: fresh editor, round 2, 3 tests done or hung\)$' "$out"
expect "two rounds ran" '^2$' "$(wc -l < "$TMP/calls" | tr -d ' ')"
refuse "the first round has no skip list" 'skip=' "$(sed -n 1p "$TMP/calls")"
expect "the second round runs the same filter" 'mode=Play filter=Ship .*test_timeout=5 skip=' "$(sed -n 2p "$TMP/calls")"
expect "its skip list holds the finished tests and the hung one" '^Game.Tests.ShipTests.Floats,Game.Tests.ShipTests.Steers,Game.Tests.ShipTests.Docks$' "$(paste -sd, "$TMP/skip.2")"
expect "one list over all rounds" '^all rounds: 3 passed, 1 failed, 0 skipped, 1 hung$' "$out"
expect "the hung test is named with its reason" '^HUNG Docks: hung after 5s \(test_timeout\)$' "$out"
expect "the red test is named" '^RED Steers: ShipTests.cs:12 Expected 1 but was 2$' "$out"
expect "a hung test keeps the run red" '^rc=1$' "$out"
expect "tests.txt holds every round, the hung test as an H row" '^P,F,H,P,P$' "$(cut -f1 "$P/.warmd/run/tests.txt" | paste -sd, -)"
expect "result.txt holds the list too" '^j1 FAIL [0-9]+s test$' "$(head -1 "$P/.warmd/run/result.txt")"
expect "and its counts" '^all rounds: 3 passed, 1 failed, 0 skipped, 1 hung$' "$(sed -n 2p "$P/.warmd/run/result.txt")"

out="$(rounds 0)"
expect "hung_resume=0 stops at the first HUNG" '^1$' "$(wc -l < "$TMP/calls" | tr -d ' ')"
refuse "and prints no list of rounds" 'all rounds' "$out"
expect "and stays red" '^rc=1$' "$out"

: > "$TMP/rounds/1.hung"
out="$(rounds 10)"
expect "a hang outside any test is not stepped over" '^1$' "$(wc -l < "$TMP/calls" | tr -d ' ')"
expect "and says where it hung" '^HUNG outside any test in round 1: hung after 5s' "$out"

echo "Game.Tests.ShipTests.Docks" > "$TMP/rounds/1.hung"; echo "Game.Tests.ShipTests.Sinks" > "$TMP/rounds/2.hung"; echo "Game.Tests.ShipTests.Rolls" > "$TMP/rounds/3.hung"
out="$(rounds 2)"
expect "hung_resume caps the rounds" '^\(hung_resume: 2 rounds reached, the rest stays unrun\)$' "$out"
expect "every hung test is in the list" '^all rounds: 3 passed, 1 failed, 0 skipped, 3 hung$' "$out"

rm -f "$TMP/rounds/"*.hung
out="$(rounds 10)"
expect "a green run stays one round" '^1$' "$(wc -l < "$TMP/calls" | tr -d ' ')"
refuse "without a list of rounds" 'all rounds|goes on' "$out"

# ---- warmd test --window: a visible editor, moved to monitor 2 by the daemon, closed after the run ----
mkdir -p "$P/Assets/Editor/Warmd" "$P/Packages"; cp "$HERE"/unity/* "$P/Assets/Editor/Warmd/"; echo '{ "dependencies": {} }' > "$P/Packages/manifest.json"
printf '#!/bin/sh\nexit 0\n' > "$TMP/Unity"; chmod +x "$TMP/Unity"
# start <WARMD_WINDOW>: a_start_daemon with spawn and the waits as stubs, prints the spawn line
start() {
  ( cd "$P" && WARMD_HOME="$HERE" && . "$HERE/lib/platform.sh" && . "$HERE/lib/core.sh" && detect_project >/dev/null 2>&1 && . "$HERE/adapters/unity.sh" \
    && export WARMD_UNITY="$TMP/Unity" WARMD_WINDOW="$1" && mkdir -p "$RUN" \
    && unity_sync() { :; } && a_daemon_procs() { :; } && foreign_unity() { :; } && gfx_take() { :; } && tune_unity_gpu_flag() { :; } && tune_unity_workers() { echo 3; } \
    && spawn() { echo "spawn style=$SPAWN_STYLE pid=${SPAWN_PID##*/} monitor=$WARMD_MONITOR window=$WARMD_WINDOW $*"; } \
    && wait_ready() { echo "wait_ready"; } && unity_wait_window() { echo "wait_window"; } && a_start_daemon ); echo "rc=$?"
}
mkdir -p "$P/Temp/__Backupscenes"; echo x > "$P/Temp/__Backupscenes/0.backup"
out="$(start 1)"
expect "a window start shows the editor" '^spawn style=Normal pid=spawn.pid monitor=2 window=1 ' "$out"
refuse "without -batchmode and -nographics" 'spawn .*(-batchmode|-nographics)' "$out"
expect "and waits for the window editor" '^wait_window$' "$out"
[ -d "$P/Temp/__Backupscenes" ] && { echo "FAIL scene backups still there, the editor would ask to recover them"; fails=$((fails+1)); } || echo "ok   scene backups are gone before a window start"
expect "window.txt marks the window daemon" '^1$' "$(cat "$P/.warmd/run/window.txt")"
out="$(WARMD_MONITOR=3 start 1)"
expect "WARMD_MONITOR picks another monitor" '^spawn .* monitor=3 window=1 ' "$out"
out="$(start 0)"
expect "a headless start stays hidden in batchmode" '^spawn style=Hidden pid=spawn.pid monitor=2 window=0 .*/Unity -batchmode .*-nographics ' "$out"
expect "a compile error never ends the daemon editor" '^spawn style=Hidden .* -ignoreCompilerErrors -projectPath ' "$out"
expect "and waits as before" '^wait_ready$' "$out"
echo '{ "dependencies": { "com.x.local": "file:../../gone/x" } }' > "$P/Packages/manifest.json"
out="$(start 1)"
expect "a missing local package stops the window start before the dialog" '^FAIL Packages/manifest.json names a local package that is missing: \.\./\.\./gone/x\. A window editor would stop at the dialog Packages with Errors$' "$out"
expect "with exit 2" '^rc=2$' "$out"
refuse "and no editor starts" '^spawn' "$out"
echo '{ "dependencies": {} }' > "$P/Packages/manifest.json"

# A dialog the watcher found ends the wait at once and the editor with it
ww() { ( cd "$P" && WARMD_HOME="$HERE" && . "$HERE/lib/platform.sh" && . "$HERE/lib/core.sh" && detect_project >/dev/null 2>&1 && . "$HERE/adapters/unity.sh" \
  && mkdir -p "$RUN" && rm -f "$RUN/alive.txt" && unity_dialog_watch() { :; } && a_kill_daemon() { echo "killed"; } && daemon_alive() { [ -f "$RUN/alive.txt" ]; } && unity_wait_window 5; echo "rc=$?" ); }
echo 'Packages with Errors: An error occurred while resolving packages [Retry/Continue/Quit]' > "$P/.warmd/run/dialog.txt"
out="$(ww 2>/dev/null)"
expect "a dialog is named with its text and buttons" '^FAIL a dialog stops the window editor: Packages with Errors: An error occurred while resolving packages \[Retry/Continue/Quit\]\. Editor ended, nothing answered$' "$out"
expect "and the editor is ended" '^killed$' "$out"
expect "a dialog is a blocked start, no red test" '^blocked BLOCKED a dialog stops the window editor: Packages with Errors' "$(head -1 "$P/.warmd/run/result.txt")"
out="$(ww 2>&1 >/dev/null)"
expect "and is said on stderr too" '^FAIL a dialog stops the window editor' "$out"
rm -f "$P/.warmd/run/dialog.txt"; echo "window editor on monitor 2 of 2 (2560x1400 at 1920,0)" > "$P/.warmd/run/screen.txt"; echo 1 > "$P/.warmd/run/alive.txt"
out="$( ( cd "$P" && WARMD_HOME="$HERE" && . "$HERE/lib/platform.sh" && . "$HERE/lib/core.sh" && detect_project >/dev/null 2>&1 && . "$HERE/adapters/unity.sh" \
  && unity_dialog_watch() { :; } && daemon_alive() { :; } && unity_wait_window 5; echo "rc=$?" ) )"
expect "a ready window editor says where it is" '^\(window editor on monitor 2 of 2 \(2560x1400 at 1920,0\)\)$' "$out"
expect "and the start goes on" '^rc=0$' "$out"
rm -f "$P/.warmd/run/screen.txt" "$P/.warmd/run/alive.txt"

# --window: the cache keeps it apart, a headless daemon makes way, the window closes after the run
wt() { ( cd "$P" && WARMD_HOME="$HERE" && . "$HERE/lib/platform.sh" && . "$HERE/lib/core.sh" && detect_project >/dev/null 2>&1 && . "$HERE/adapters/unity.sh" \
  && unity_world() { :; } && unity_sync() { :; } && daemon_alive() { :; } && daemon_stop() { echo "daemon_stop window=${WARMD_WINDOW:-0}" >> "$TMP/order"; } \
  && cached() { echo "cached $1 window=${WARMD_WINDOW:-0}" | tee -a "$TMP/order"; } && a_test "$@" ); }
echo 0 > "$P/.warmd/run/window.txt"; rm -f "$TMP/order"
out="$(wt ShotTests --play --window)"
expect "the window run has a cache key of its own" '^cached test\|Play\|ShotTests\|\|\|gfx0\|window window=1$' "$out"
expect "a headless daemon makes way first, the window closes after" '^daemon_stop window=1,cached .*,daemon_stop window=1$' "$(paste -sd, "$TMP/order")"
expect "and says so" '^\(window editor closed\)$' "$out"
expect "WARMD_WINDOW=1 does the same" '^cached test\|Play\|ShotTests\|\|\|gfx0\|window window=1$' "$(WARMD_WINDOW=1 wt ShotTests --play)"
rm -f "$TMP/order"; out="$(wt ShotTests --play)"
expect "without it the key stays as before" '^cached test\|Play\|ShotTests\|\|\|gfx0 window=0$' "$out"
refuse "and nothing is closed" 'daemon_stop|window editor closed' "$out$(cat "$TMP/order" 2>/dev/null)"

# An editor that exits during the start (compiler errors, return code 1) ends the wait at once: slot freed, unique
# error CS lines, FAIL as the closing line, exit 1. No 600 s wait with nobody alive.
dead() { ( cd "$P" && WARMD_HOME="$HERE" && . "$HERE/lib/platform.sh" && . "$HERE/lib/core.sh" && detect_project >/dev/null 2>&1 && . "$HERE/lib/daemon.sh" && . "$HERE/adapters/unity.sh" \
  && mkdir -p "$RUN" "$TMP/slots/1" && SLOT="$TMP/slots/1" && rm -f "$RUN/alive.txt" && WARMD_SPAWN_POLL=1 wait_ready 30 ); echo "rc=$?"; }
{ echo "Assets/A.cs(3,5): error CS0103: The name 'x' does not exist in the current context"; echo "Assets/A.cs(3,5): error CS0103: The name 'x' does not exist in the current context"
  echo "  Assets/B.cs(9,1): error CS1002: ; expected"; echo "Scripts have compiler errors."; echo "Exiting without the bug reporter. Application will terminate with return code 1"; } > "$P/.warmd/run/warmd-daemon.log"
echo 999999 > "$P/.warmd/run/spawn.pid"
mkdir -p "$TMP/slots/1"; t0=$SECONDS; out="$(dead)"
expect "a gone editor ends the wait at once" '^rc=1$' "$out"
[ $((SECONDS - t0)) -le 10 ] && echo "ok   within seconds, not after the timeout" || { echo "FAIL the wait took $((SECONDS - t0))s"; fails=$((fails+1)); }
[ -d "$TMP/slots/1" ] && { echo "FAIL the slot is still held"; fails=$((fails+1)); } || echo "ok   and frees its slot"
expect "every compiler error once" '^2$' "$(echo "$out" | grep -c 'error CS')"
expect "trimmed" "^Assets/B.cs\(9,1\): error CS1002" "$out"
expect "FAIL closes the output" '^FAIL [0-9]+s engine exited before it was ready \(pid 999999\), compiler errors above, slot freed, log: ' "$(echo "$out" | grep -v '^rc=' | tail -1)"
rm -f "$P/.warmd/run/spawn.pid"; echo 1 > "$P/.warmd/run/alive.txt"
out="$( ( cd "$P" && WARMD_HOME="$HERE" && . "$HERE/lib/platform.sh" && . "$HERE/lib/core.sh" && detect_project >/dev/null 2>&1 && . "$HERE/lib/daemon.sh" && . "$HERE/adapters/unity.sh" \
  && daemon_alive() { :; } && wait_ready 5 ); echo "rc=$?")"
expect "a ready editor still goes on" '^rc=0$' "$out"
rm -f "$P/.warmd/run/alive.txt" "$P/.warmd/run/warmd-daemon.log"

# An editor that lives but never beats (compile errors keep the daemon code from loading) ends after a quiet log
me=$$; [ -r "/proc/$$/winpid" ] && read -r me < "/proc/$$/winpid"; echo "$me" > "$P/.warmd/run/spawn.pid"
echo "Assets/C.cs(1,1): error CS0246: The type or namespace name 'Foo' could not be found" > "$P/.warmd/run/warmd-daemon.log"; rm -f "$P/.warmd/run/spawn.seen"
out="$( ( cd "$P" && WARMD_HOME="$HERE" && . "$HERE/lib/platform.sh" && . "$HERE/lib/core.sh" && detect_project >/dev/null 2>&1 && . "$HERE/lib/daemon.sh" && . "$HERE/adapters/unity.sh" \
  && rm -f "$RUN/alive.txt" && a_kill_daemon() { echo killed > "$TMP/killed"; } && WARMD_STUCK_QUIET=3 WARMD_SPAWN_POLL=1000 wait_ready 40 ); echo "rc=$?")"
expect "a living editor without heartbeat and with compile errors is ended" "^killed$" "$(cat "$TMP/killed" 2>/dev/null)"
expect "and named as stuck" '^FAIL [0-9]+s engine never answered, compile errors keep the daemon from loading, editor ended, compiler errors above, slot freed' "$out"
expect "exit 1" '^rc=1$' "$out"
rm -f "$P/.warmd/run/spawn.pid" "$P/.warmd/run/spawn.seen" "$P/.warmd/run/warmd-daemon.log"

# A reused worktree gets the base's Library mirrored: stale files go. Never while an engine works there.
mkdir -p "$TMP/src/Library/sub" "$TMP/dst/Library" "$TMP/dst/.warmd/run"; echo new > "$TMP/src/Library/sub/a.asset"; echo stale > "$TMP/dst/Library/old.asset"
seed() { ( WARMD_HOME="$HERE" && . "$HERE/lib/platform.sh" && . "$HERE/lib/core.sh" && . "$HERE/lib/daemon.sh" && cd "$P" && detect_project >/dev/null 2>&1 && . "$HERE/adapters/unity.sh" && a_seed "$TMP/src" "$TMP/dst" ); }
now_ms_t() { ( . "$HERE/lib/daemon.sh"; now_ms ); }
now_ms_t > "$TMP/dst/.warmd/run/alive.txt"; seed
[ -f "$TMP/dst/Library/old.asset" ] && [ ! -f "$TMP/dst/Library/sub/a.asset" ] && echo "ok   a live engine in the target keeps its Library" || { echo "FAIL Library copied under a live engine"; fails=$((fails+1)); }
rm -f "$TMP/dst/.warmd/run/alive.txt"; seed
[ ! -f "$TMP/dst/Library/old.asset" ] && [ -f "$TMP/dst/Library/sub/a.asset" ] && [ ! -d "$TMP/dst/Library/Library" ] && echo "ok   the Library is mirrored, stale files gone" || { echo "FAIL mirror: $(cd "$TMP/dst" && find Library | paste -sd' ' -)"; fails=$((fails+1)); }

# RAM short: the engine idle longest in another worktree goes, a busy one or this run's own stays
git -C "$P" worktree add -q "$TMP/wt2" -b w2 2>/dev/null; git -C "$P" worktree add -q "$TMP/wt3" -b w3 2>/dev/null
for w in wt2 wt3; do mkdir -p "$TMP/$w/.warmd/run"; now_ms_t > "$TMP/$w/.warmd/run/alive.txt"; echo phase=idle > "$TMP/$w/.warmd/run/state.txt"; done
echo r > "$TMP/wt3/.warmd/run/result.txt"; touch -d "-30 min" "$TMP/wt3/.warmd/run/result.txt"; echo r > "$TMP/wt2/.warmd/run/result.txt"
mkdir -p "$P/.warmd/run"; now_ms_t > "$P/.warmd/run/alive.txt"; echo phase=idle > "$P/.warmd/run/state.txt"; touch -d "-60 min" "$P/.warmd/run/state.txt"
sti() { ( cd "$P" && WARMD_HOME="$HERE" && . "$HERE/lib/platform.sh" && . "$HERE/lib/core.sh" && . "$HERE/lib/tune.sh" && . "$HERE/lib/daemon.sh" && detect_project >/dev/null 2>&1 && tune_stop_idle && echo "stopped $REPLY" ); }
expect "the engine idle longest goes" "^stopped .*/wt3$" "$(sti)"
echo "kind=test" > "$TMP/wt3/.warmd/run/job.txt"; echo phase=run > "$TMP/wt2/.warmd/run/state.txt"
expect "a busy one stays, and the own one too" '^$' "$(sti)"
rm -f "$P/.warmd/run/alive.txt" "$P/.warmd/run/state.txt"

# test_port_env: every heavy run its own port from the slot number, handed to the daemon with the job
out="$( ( cd "$P" && WARMD_HOME="$HERE" && . "$HERE/lib/platform.sh" && . "$HERE/lib/core.sh" && detect_project >/dev/null 2>&1 && CFG_test_port_env=GAME_PORT && SLOT="$TMP/cache/slots/3" && slot_port && echo "port=$GAME_PORT" ) )"
expect "slot 3 gets base 7930 plus 3" '^port=7933$' "$out"
out="$( ( cd "$P" && WARMD_HOME="$HERE" && . "$HERE/lib/platform.sh" && . "$HERE/lib/core.sh" && detect_project >/dev/null 2>&1 && CFG_test_port_env=GAME_PORT && CFG_test_port_base=9000 && SLOT="$TMP/cache/slots/2" && slot_port && echo "port=$GAME_PORT" ) )"
expect "test_port_base moves the range" '^port=9002$' "$out"
expect "the daemon sets the run's port before the run" 'SetEnvironmentVariable\(Get\(job, "port_env"\), Get\(job, "port"\)\)' "$(cat "$HERE/unity/WarmdDaemon.cs")"
expect "and mutes every run unless it asks for sound" 'audioMasterMute = Get\(job, "sound"\) != "1"' "$(cat "$HERE/unity/WarmdDaemon.cs")"

# ---- warmd package with package_dir: one fixed folder, the method gets it, a running player is waited for ----
printf '#!/bin/sh\nwhile [ $# -gt 0 ]; do [ "$1" = -warmdPackageDir ] && [ "${PKG_IGNORE:-0}" != 1 ] && echo player > "$2/start.exe"; shift; done\nexit 0\n' > "$TMP/UnityPkg"; chmod +x "$TMP/UnityPkg"
pk() { ( cd "$P" && WARMD_HOME="$HERE" && . "$HERE/lib/platform.sh" && . "$HERE/lib/core.sh" && . "$HERE/lib/tune.sh" && detect_project >/dev/null 2>&1 && . "$HERE/lib/daemon.sh" && . "$HERE/adapters/unity.sh" \
  && mkdir -p "$RUN" && export WARMD_UNITY="$TMP/UnityPkg" WARMD_NO_RAM_WAIT=1 && CFG_package_method=Game.Build.Player && CFG_package_dir=../Player \
  && a_stop() { :; } && foreign_unity() { :; } && a_package ); echo "rc=$?"; }
out="$(pk)"
expect "the player goes into package_dir" '^OK [0-9]+s package in .*/Player$' "$out"
expect "the method built there" '^player$' "$(tr -d '\r' < "$TMP/Player/start.exe" 2>/dev/null)"
expect "no second folder" '^Player game$' "$(ls "$TMP" | grep -E '^(Player|game)' | paste -sd' ' -)"
out="$(pk)"; expect "a second package overwrites the same folder" '^rc=0$' "$out"
out="$(PKG_IGNORE=1 pk)"
expect "a method that ignores the folder is red" '^FAIL [0-9]+s package: the method built nothing into .*/Player, it has to read -warmdPackageDir$' "$out"
if [ "$OS" = win ]; then
  cp /c/Windows/System32/PING.EXE "$TMP/Player/start.exe"; "$TMP/Player/start.exe" -n 5 127.0.0.1 >/dev/null 2>&1 & bg=$!
  until tasklist //FI "IMAGENAME eq start.exe" //NH 2>/dev/null | grep -q start.exe; do nap 0.2; done
  out="$( ( cd "$P" && WARMD_HOME="$HERE" && . "$HERE/lib/platform.sh" && . "$HERE/lib/core.sh" && detect_project >/dev/null 2>&1 && mkdir -p "$RUN" && WARMD_PACKAGE_POLL=1 package_wait_free "$TMP/Player" ); echo "rc=$?")"
  wait $bg
  expect "a running player is waited for, said in one line" '^WAIT start.exe runs from .*/Player, the package starts when it is closed$' "$out"
  expect "and the package goes on when it is closed" '^rc=0$' "$out"
  expect "nothing written meanwhile" '^0$' "$(ls "$TMP" | grep -c 'Player.')"
fi

if [ "$OS" = win ]; then
  # spawn hands back the system pid of the new process
  ( . "$HERE/lib/platform.sh"; SPAWN_PID="$TMP/sp.pid" spawn "$TMP/sp.log" "$(cygpath -u "$COMSPEC")" /c exit 0 )
  expect "spawn writes the pid of the new process" '^[0-9]+$' "$(tr -d '\r' < "$TMP/sp.pid" 2>/dev/null)"
  # The watcher finds a real modal dialog by its buttons and names it. The box is up for a few seconds only.
  W="$TMP/watch"; mkdir -p "$W"
  powershell.exe -NoProfile -Command "\$p = Start-Process -PassThru powershell.exe -ArgumentList '-NoProfile','-Command','Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show(''warmd self-test, closes by itself'', ''warmd self-test'', ''YesNo'')'; Set-Content -Path '$(native_path "$W/spawn.pid")' -Value \$p.Id" >/dev/null 2>&1
  ( cd "$P" && WARMD_HOME="$HERE" && . "$HERE/lib/platform.sh" && . "$HERE/lib/core.sh" && detect_project >/dev/null 2>&1 && . "$HERE/adapters/unity.sh" && RUN="$W" && unity_dialog_watch 20 )
  expect "the watcher names a dialog with its buttons" '^warmd self-test: warmd self-test, closes by itself \[(Yes|Ja)/(No|Nein)\]$' "$(tr -d '\r' < "$W/dialog.txt" 2>/dev/null)"
  kill_tree "$(tr -d '\r' < "$W/spawn.pid")"
  rm -f "$W/dialog.txt"; echo 999999 > "$W/spawn.pid"
  ( cd "$P" && WARMD_HOME="$HERE" && . "$HERE/lib/platform.sh" && . "$HERE/lib/core.sh" && detect_project >/dev/null 2>&1 && . "$HERE/adapters/unity.sh" && RUN="$W" && unity_dialog_watch 20 )
  [ -f "$W/dialog.txt" ] && { echo "FAIL the watcher reported a dialog of a gone process"; fails=$((fails+1)); } || echo "ok   the watcher ends quietly when the editor is gone"
fi

[ $fails = 0 ] && echo "ALL OK" || { echo "$fails failed"; exit 1; }
