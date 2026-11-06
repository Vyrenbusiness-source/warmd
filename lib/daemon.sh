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

# wait_ready <seconds>: a daemon is ready once it writes its heartbeat
wait_ready() {
  local i=0
  while :; do
    nap 1; i=$((i+1))
    if [ -f "$RUN/alive.txt" ] && daemon_alive; then return 0; fi
    [ $i -gt "$1" ] && { echo "FAIL daemon not ready after ${1}s, see $(native_path "$RUN/daemon.log")"; exit 1; }
  done
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
        [ "$(head -1 "$RUN/result.txt" | cut -d' ' -f2)" = OK ]; return
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
