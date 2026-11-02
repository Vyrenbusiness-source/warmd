# Everything that differs between Windows (Git Bash), Linux and macOS lives here.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) OS=win;;
  Darwin) OS=mac;;
  *) OS=linux;;
esac

native_path() { if [ "$OS" = win ]; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }
self_pid() { if [ "$OS" = win ]; then cat "/proc/$$/winpid"; else echo "$$"; fi; }

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

# spawn <log> <program> <args...>: start detached, output goes to the log
spawn() {
  local log="$1" exe="$2"; shift 2
  if [ "$OS" = win ]; then
    local list="" a
    for a in "$@"; do list="$list'$(printf '%s' "$a" | sed "s/'/''/g")',"; done
    powershell.exe -NoProfile -Command "Start-Process -FilePath '$(native_path "$exe")' -ArgumentList ${list%,} -WindowStyle Hidden -RedirectStandardOutput '$(native_path "$log")' -RedirectStandardError '$(native_path "$log.err")'" >/dev/null 2>&1
  else
    nohup "$exe" "$@" > "$log" 2>&1 < /dev/null &
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

cpu_count() { getconf _NPROCESSORS_ONLN 2>/dev/null || echo "${NUMBER_OF_PROCESSORS:-4}"; }
