# File protocol shared by the Unity and Godot daemons: job.txt in, result.txt out, alive.txt as heartbeat.
# Files survive a domain reload or a script reload, so a reload in the middle of a job loses nothing.
HANG_MS=$(( ${WARMD_HANG:-600} * 1000 ))
now_ms() {
  local t
  if [ -n "${EPOCHREALTIME:-}" ]; then t="${EPOCHREALTIME//[.,]/}"; echo "${t%???}"; return; fi
  t="$(date +%s%3N)"
  case "$t" in *N) echo "$(date +%s)000";; *) echo "$t";; esac
}

daemon_pid() { local p=""; { read -r p < "$RUN/pid.txt"; } 2>/dev/null; echo "${p%$'\r'}"; }
daemon_alive() {
  local a="" age; { read -r a < "$RUN/alive.txt"; } 2>/dev/null; a="${a%$'\r'}"; [ -n "$a" ] || return 1
  age=$(( $(now_ms) - a ))
  [ "$age" -lt 3000 ] && return 0   # a fresh heartbeat proves it, a process lookup costs 100 ms on Windows
  pid_alive "$(daemon_pid)" && [ "$age" -lt "$HANG_MS" ]
}

# start_locked <starter function>: only one process starts the daemon. The lock outlives the start timeout, or a second caller would kill a starting daemon.
start_locked() {
  daemon_alive && return 0
  local lock="$STATE/start.lock" n=0
  while ! mkdir "$lock" 2>/dev/null; do
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +11 2>/dev/null)" ]; then rmdir "$lock" 2>/dev/null; continue; fi
    n=$((n+1)); [ $n -gt 1300 ] && { echo "FAIL start lock stuck: $lock"; exit 1; }
    daemon_alive && return 0
    nap 0.5
  done
  LOCK="$lock"
  "$1"
  rmdir "$lock" 2>/dev/null; LOCK=""
}

# wait_ready <seconds>: a daemon is ready once it writes its heartbeat. An engine that exits during the start
# (compiler errors end a batchmode editor with return code 1) ends the wait at once, see spawn_gone.
wait_ready() {
  local i=0
  while :; do
    nap 1; i=$((i+1))
    if [ -f "$RUN/alive.txt" ] && daemon_alive; then return 0; fi
    spawn_gone "$i" && spawn_fail
    spawn_stuck "$i" && { declare -F a_kill_daemon >/dev/null && a_kill_daemon >/dev/null 2>&1; spawn_fail "never answered, compile errors keep the daemon from loading, editor ended"; }
    [ $i -gt "$1" ] && { echo "FAIL daemon not ready after ${1}s, see $(native_path "$RUN/daemon.log")"; exit 1; }
  done
}

# spawn_stuck <seconds waited>: the editor lives (-ignoreCompilerErrors) but never beats, because compile errors keep the
# daemon's own code from loading (a Library without it). True once its log has been quiet for WARMD_STUCK_QUIET seconds
# (default 60) and holds an error CS line. Builtins every second (a stamp and -nt), one grep only after the quiet time.
spawn_stuck() {
  local lg="$RUN/warmd-daemon.log" st="$RUN/spawn.seen"
  [ -f "$lg" ] || return 1
  if [ ! -f "$st" ] || [ "$lg" -nt "$st" ]; then : > "$st"; SPAWN_QUIET=0; return 1; fi
  SPAWN_QUIET=$(( ${SPAWN_QUIET:-0} + 1 ))
  [ "$SPAWN_QUIET" -ge "${WARMD_STUCK_QUIET:-60}" ] && [ $(( SPAWN_QUIET % 10 )) = 0 ] || return 1
  grep -q 'error CS[0-9]' "$lg" 2>/dev/null
}

# spawn_gone <seconds waited>: true when the engine warmd started (pid in spawn.pid) no longer runs. Linux and macOS ask
# the kernel through the kill builtin every second. Windows has no builtin for a Windows pid: one tasklist every
# WARMD_SPAWN_POLL seconds (default 5), never a program per second. No spawn.pid: nothing to check, the timeout decides.
spawn_gone() {
  local p=""; { read -r p < "$RUN/spawn.pid"; } 2>/dev/null; p="${p%$'\r'}"; p="${p// /}"
  [ -n "$p" ] || return 1
  if [ "$OS" = win ]; then
    [ $(( $1 % ${WARMD_SPAWN_POLL:-5} )) = 0 ] || return 1
    pid_alive "$p" && return 1
  else
    kill -0 "$p" 2>/dev/null && return 1
  fi
  # It may have written its heartbeat in its last second
  [ -f "$RUN/alive.txt" ] && daemon_alive && return 1
  SPAWN_GONE_PID="$p"; return 0
}

# spawn_fail: the engine is gone before it was ready. The slot goes first, so a queued run starts while this one still
# talks; then the unique compiler errors of the engine log (at most 10) and FAIL as the closing line, exit 1 (red).
spawn_fail() { # [reason]
  [ -n "${SLOT:-}" ] && rm -rf "$SLOT"; SLOT=""
  [ -n "${GFXSLOT:-}" ] && rm -rf "$GFXSLOT"; GFXSLOT=""
  local lg="" c; for c in "$RUN/warmd-daemon.log" "$RUN/unity_out.log" "$RUN/daemon.log"; do [ -f "$c" ] && { lg="$c"; break; }; done
  local errs=""
  [ -n "$lg" ] && errs="$(cat "$RUN/warmd-daemon.log" "$RUN/unity_out.log" 2>/dev/null | tr -d '\r' | grep -E 'error CS[0-9]+' | sed 's/^[[:space:]]*//' | awk '!seen[$0]++' | head -10 | cut -c1-200)"
  [ -n "$errs" ] && printf '%s\n' "$errs"
  END_SAID=1
  echo "FAIL $(secs)s engine ${1:-exited before it was ready (pid ${SPAWN_GONE_PID:-?})}$( [ -n "$errs" ] && echo ", compiler errors above"), slot freed, log: $(native_path "${lg:-$RUN/warmd-daemon.log}")"
  exit 1
}

# One job at a time per daemon: a second caller waits instead of overwriting job.txt and losing both results.
job_lock() {
  local dir="$STATE/job.lock" holder said=""
  [ -n "$JOBLOCK" ] && return 0
  until mkdir "$dir" 2>/dev/null; do
    holder="$(cat "$dir/pid" 2>/dev/null)"
    if [ -n "$holder" ] && ! shell_alive "$holder"; then rm -rf "$dir"; continue; fi
    [ -n "$said" ] || { echo "(queued: another job runs on this project)"; said=1; queue_mark; }
    nap 1; orphan_check
  done
  [ -z "$said" ] || queue_done
  echo "$$" > "$dir/pid"; JOBLOCK="$dir"
}

# job <kind> [key=value...]: blocks until the result. If the daemon dies or the job gets lost: restart and repeat exactly once.
job() {
  local kind="$1" attempt=1 id waited lost; shift
  [ "$kind" = quit ] || { [ "$kind" = ping ] && daemon_alive; } || slot_take
  [ "$kind" = quit ] || job_lock
  while :; do
    start_locked a_start_daemon
    id="j$(now_ms)"
    rm -f "$RUN/result.txt" "$RUN/stop.flag"
    { echo "id=$id"; echo "kind=$kind"; echo "timeout=$TIMEOUT"; printf '%s\n' "$@"; } > "$RUN/job.tmp"
    mv "$RUN/job.tmp" "$RUN/job.txt"
    waited=0; lost=""
    while :; do
      if [ -f "$RUN/result.txt" ] && [ "$(head -1 "$RUN/result.txt" | cut -d' ' -f1)" = "$id" ]; then
        head -15 "$RUN/result.txt" | tr -d '\r' | sed '1s/^[^ ]* //'
        # Timeout: the run is still stuck in the engine, the next job needs a fresh daemon
        # HUNG: the test runner is still inside a test that never ended (lib unity daemon, test_timeout)
        if grep -qE '^(timeout after|HUNG )' "$RUN/result.txt"; then a_kill_daemon; return 1; fi
        [ "$(head -1 "$RUN/result.txt" | cut -d' ' -f2)" = OK ] || return 1
        # Details follow the OK line: a closing OK, so the last line still says green (a red one gets its FAIL in on_exit)
        { read -r _; read -r _; } < "$RUN/result.txt" && echo "OK $(secs)s $kind"
        return 0
      fi
      if [ $waited -lt 40 ]; then nap 0.05; else nap 0.4; fi
      waited=$((waited+1))
      if [ $waited -ge 40 ] && [ $((waited % 25)) = 0 ]; then
        orphan_check
        if ! daemon_alive; then lost="daemon died or hangs"; break; fi
        if [ $waited -ge 65 ] && [ ! -f "$RUN/job.txt" ] && [ ! -f "$RUN/result.txt" ] && grep -q '^phase=idle' "$RUN/state.txt" 2>/dev/null && ! grep -q "^id=$id" "$RUN/state.txt" 2>/dev/null; then lost="job lost"; break; fi
      fi
      [ $waited -gt $(( (TIMEOUT + 120) * 5 / 2 )) ] && { echo "FAIL wait limit exceeded ($kind, $(secs)s)"; return 1; }
    done
    # 130, not 1: cut off from outside is no red test, auto_red never escalates it
    if [ -f "$RUN/stop.flag" ]; then echo "FAIL $kind stopped by warmd stop ($(secs)s)"; return 130; fi
    if [ $attempt -ge 2 ]; then echo "FAIL $lost, also after retry ($kind, $(secs)s)"; return 1; fi
    echo "(retry: $lost)"; attempt=2
    a_kill_daemon
  done
}

# Fire and forget: the engine compiles in the background, the next job waits for it, the caller does not.
job_async() { { echo "id=c$(now_ms)"; echo "kind=$1"; echo "timeout=$TIMEOUT"; } > "$RUN/job.tmp"; mv "$RUN/job.tmp" "$RUN/job.txt"; }

# Clean quit when idle, hard stop when busy or after 30 s. A wait in job() must not bring the daemon back.
daemon_stop() {
  local had="" pid i
  daemon_alive && had=1
  : > "$RUN/stop.flag"
  if [ -n "$had" ] && ! grep -q '^phase=[^i]' "$RUN/state.txt" 2>/dev/null; then
    pid="$(daemon_pid)"; { echo "id=q$(now_ms)"; echo "kind=quit"; } > "$RUN/job.tmp"; mv "$RUN/job.tmp" "$RUN/job.txt"; i=0
    while pid_alive "$pid" && [ $i -lt 60 ]; do nap 0.5; i=$((i+1)); done
  fi
  if [ -n "$(a_daemon_procs)" ]; then
    a_kill_daemon
    i=0; while [ -n "$(a_daemon_procs)" ] && [ $i -lt 8 ]; do nap 1; i=$((i+1)); done   # Windows ends a killed process with a delay
    [ -n "$(a_daemon_procs)" ] && { echo "FAIL daemon still alive after kill"; return 1; }
    echo "OK daemon killed"
  elif [ -n "$had" ]; then rm -f "$RUN/alive.txt" "$RUN/pid.txt"; echo "OK daemon stopped"
  else echo "OK no daemon"; fi
}
