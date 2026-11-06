# Everything that differs between Windows (Git Bash), Linux and macOS lives here.
# $OSTYPE is set by bash itself, so no process starts
case "${OSTYPE:-$(uname -s)}" in
  msys*|cygwin*|mingw*|MINGW*|MSYS*|CYGWIN*) OS=win;;
  darwin*|Darwin) OS=mac;;
  *) OS=linux;;
esac

# nap <seconds>: a wait without a process start. Under Git Bash every `sleep` is a new process, and some Windows machines
# keep kernel memory per process start until reboot: eight queued runs polling with sleep cost 64 starts a second and
# ate 40 GB in 40 minutes. read -t on a FIFO that nobody writes waits in bash itself. The FIFO is opened once per shell,
# subshells inherit the descriptor. Without mkfifo it falls back to sleep.
nap_init() {
  [ -n "${NAP_FD:-}" ] && return 0
  [ "${NAP_OFF:-0}" = 1 ] && return 1
  local f="${TMPDIR:-/tmp}/warmd-nap-$$-$RANDOM"
  mkfifo "$f" 2>/dev/null || { NAP_OFF=1; return 1; }
  exec {NAP_FD}<>"$f" || { NAP_OFF=1; rm -f "$f"; return 1; }
  rm -f "$f"
}
nap() {
  if nap_init; then read -r -t "$1" -u "$NAP_FD" _ 2>/dev/null; return 0; fi
  sleep "$1"
}

# On Windows /c/dir becomes C:/dir in pure bash, only other roots such as /tmp need cygpath
native_path() {
  if [ "$OS" != win ]; then printf '%s\n' "$1"; return; fi
  case "$1" in
    /[a-zA-Z]) _d="${1:1:1}"; printf '%s:/\n' "${_d^^}";;
    /[a-zA-Z]/*) _d="${1:1:1}"; printf '%s:%s\n' "${_d^^}" "${1:2}";;
    [a-zA-Z]:*) _d='\'; printf '%s\n' "${1//"$_d"//}";;
    *) cygpath -m "$1";;
  esac
}
# Shell pids work across every session on all systems and need no process listing, which stalls under load on Windows
shell_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }
# .warmd/run/queued: this project's last run waited in a queue (slot, RAM, graphics, job lock). It goes when the wait ends
# or the next run starts. A run that died while queued leaves it: a wait is no failure of the agent (lib/auto.sh).
queue_mark() { [ -n "${RUN:-}" ] && [ -d "$RUN" ] && : > "$RUN/queued" 2>/dev/null; return 0; }
queue_done() { [ -n "${RUN:-}" ] && rm -f "$RUN/queued" 2>/dev/null; return 0; }

pid_alive() {
  [ -n "${1:-}" ] || return 1
  if [ "$OS" = win ]; then tasklist //FI "PID eq $1" //NH 2>/dev/null | grep -q " $1 "; else kill -0 "$1" 2>/dev/null; fi
}

# procs <must-match regex> <must-not-match regex>: pids of processes by full command line
procs() {
  if [ "$OS" = win ]; then
    powershell.exe -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { \$c=\$_.CommandLine; \$c -and \$c.Replace('\\','/') -match '$1' -and \$c -notmatch '$2' -and \$c -notmatch 'Get-CimInstance' } | Select-Object -ExpandProperty ProcessId" 2>/dev/null | tr -d '\r'
  else
    ps -eo pid=,args= | grep -E -- "$1" | grep -vE -- "$2" | grep -v grep | awk '{print $1}'
  fi
}

kill_tree() {
  local pid="$1"
  if [ "$OS" = win ]; then taskkill //PID "$pid" //T //F >/dev/null 2>&1
  else pkill -9 -P "$pid" 2>/dev/null; kill -9 "$pid" 2>/dev/null; fi
}

# spawn <log> <program> <args...>: start detached, output goes to the log.
# SPAWN_STYLE=Normal shows the program's windows (default Hidden), SPAWN_PID=<file> receives the system pid.
spawn() {
  local log="$1" exe="$2"; shift 2
  if [ "$OS" = win ]; then
    local list="" a keep=""
    for a in "$@"; do list="$list'$(printf '%s' "$a" | sed "s/'/''/g")',"; done
    [ -n "${SPAWN_PID:-}" ] && keep="; Set-Content -Path '$(native_path "$SPAWN_PID")' -Value \$p.Id"
    powershell.exe -NoProfile -Command "\$p = Start-Process -PassThru -FilePath '$(native_path "$exe")' -ArgumentList ${list%,} -WindowStyle ${SPAWN_STYLE:-Hidden} -RedirectStandardOutput '$(native_path "$log")' -RedirectStandardError '$(native_path "$log.err")'$keep" >/dev/null 2>&1
  else
    nohup "$exe" "$@" > "$log" 2>&1 < /dev/null &
    [ -z "${SPAWN_PID:-}" ] || echo "$!" > "$SPAWN_PID"
  fi
}

find_browser() {
  local c
  for c in "${WARMD_BROWSER:-}" chrome google-chrome google-chrome-stable chromium chromium-browser msedge \
    "/c/Program Files/Google/Chrome/Application/chrome.exe" "/c/Program Files (x86)/Google/Chrome/Application/chrome.exe" \
    "/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe" "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"; do
    [ -n "$c" ] || continue
    if [ -x "$c" ]; then echo "$c"; return 0; fi
    if command -v "$c" >/dev/null 2>&1; then command -v "$c"; return 0; fi
  done
  return 1
}

cpu_count() {
  if [ "$OS" = win ] && [ -n "${NUMBER_OF_PROCESSORS:-}" ]; then echo "$NUMBER_OF_PROCESSORS"; return; fi
  getconf _NPROCESSORS_ONLN 2>/dev/null || echo "${NUMBER_OF_PROCESSORS:-4}"
}

# Unity editors by command line, AssetImportWorkers left out: one line per editor, pid<TAB>projectPath<TAB>flags
# (b = -batchmode, d = warmd's daemon). Pids are system pids; the path has forward slashes and no trailing slash.
unity_procs() {
  if [ "$OS" = win ]; then
    # shellcheck disable=SC2016  # PowerShell variables, not bash ones
    printf '%s\n' 'Get-CimInstance Win32_Process | ForEach-Object { $c = $_.CommandLine; if ($c -and $c -notmatch "AssetImportWorker|Get-CimInstance" -and $c -match "[^A-Za-z0-9]Unity(\.exe)?""?\s" -and $c -match "-projectPath\s+(?:""([^""]+)""|(\S+))") { $p = $matches[1]; if (-not $p) { $p = $matches[2] }; $f = ""; if ($c -match "-batchmode") { $f += "b" }; if ($c -match "warmd-daemon") { $f += "d" }; "{0}`t{1}`t{2}" -f $_.ProcessId, $p.Replace("\", "/").TrimEnd("/"), $f } }' \
      | powershell.exe -NoProfile -NonInteractive -Command - 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+	'
  else
    ps -eo pid=,args= 2>/dev/null | grep -E '[/ ]Unity( |$)|Unity\.app' | grep -v -e AssetImportWorker -e grep | while read -r pid args; do
      p="$(printf '%s' "$args" | sed -nE 's/.*-projectPath +("([^"]+)"|([^ ]+)).*/\2\3/p')"; [ -n "$p" ] || continue
      f=""; case " $args " in *" -batchmode "*) f=b;; esac; case "$args" in *warmd-daemon*) f="${f}d";; esac
      printf '%s\t%s\t%s\n' "$pid" "${p%/}" "$f"
    done
  fi
}

# Ask a process to end, then end it hard. 0 when it is gone. Windows: taskkill without /F closes windows politely.
stop_gently() { # pid grace-seconds
  local i=0
  if [ "$OS" = win ]; then taskkill //PID "$1" >/dev/null 2>&1; else kill -TERM "$1" 2>/dev/null; fi
  while pid_alive "$1" && [ $i -lt "$2" ]; do nap 1; i=$((i+1)); done
  pid_alive "$1" || { STOP_HOW=friendly; return 0; }
  STOP_HOW=hard; kill_tree "$1"; i=0
  while pid_alive "$1" && [ $i -lt 8 ]; do nap 1; i=$((i+1)); done
  ! pid_alive "$1"
}
