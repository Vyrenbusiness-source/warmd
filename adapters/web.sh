# Web: the warm thing is the dev server. Plain HTML works without package.json.
pm() {
  if [ -f "$PROJECT/pnpm-lock.yaml" ]; then echo pnpm
  elif [ -f "$PROJECT/yarn.lock" ]; then echo yarn
  elif [ -f "$PROJECT/bun.lockb" ] || [ -f "$PROJECT/bun.lock" ]; then echo bun
  else echo npm; fi
}
has_script() { [ -f "$PROJECT/package.json" ] && grep -qE "\"$1\"[[:space:]]*:" "$PROJECT/package.json"; }
has_dep() { [ -f "$PROJECT/package.json" ] && grep -qE "\"$1\"[[:space:]]*:" "$PROJECT/package.json"; }
in_project() { ( cd "$PROJECT" && $(tune_prefix) "$@" ); }

a_build() {
  if [ -n "$CFG_build" ]; then run_bounded build in_project sh -c "$CFG_build"; return; fi
  if [ -f "$PROJECT/tsconfig.json" ] && [ -x "$PROJECT/node_modules/.bin/tsc" ]; then
    run_bounded typecheck in_project "./node_modules/.bin/tsc" --noEmit || return 1
  elif has_script build; then run_bounded build in_project "$(pm)" run build || return 1
  else echo "OK nothing to compile"; fi
  if [ -n "$CFG_lint" ]; then run_bounded lint in_project sh -c "$CFG_lint"
  elif has_script lint; then run_bounded lint in_project "$(pm)" run lint; fi
}

test_cmd() { # filter
  if [ -n "$CFG_test" ]; then run_bounded test in_project sh -c "$CFG_test ${1:-}"
  elif has_dep vitest; then run_bounded test in_project ./node_modules/.bin/vitest run --maxWorkers="$(tune_threads)" ${1:-}
  elif has_dep jest; then run_bounded test in_project ./node_modules/.bin/jest ${1:-}
  elif has_script test; then run_bounded test in_project "$(pm)" test -- ${1:-}
  else echo "OK no tests configured"; fi
}
a_test() { slot_take; cached "test|${1:-}" test_cmd "${1:-}"; }

# Tests that reach a changed file through imports, transitive ones included (lib/affected.sh). Vitest and Jest take file filters as plain arguments.
a_check() {
  . "$WARMD_HOME/lib/affected.sh"
  affected_select js
  case "$AFF_MODE" in
    CLEAN) echo "OK no code changed against $(base_branch)";;
    NONE) echo "OK no test depends on this change";;
    ALL) echo "(running all tests: $AFF_REASON)"; a_test;;
    *) echo "(affected: $(echo "$AFF_FILES" | wc -w | tr -d ' ') test files)"; a_test "$AFF_FILES";;
  esac
}

server_url() { cat "$RUN/dev.url" 2>/dev/null; }
server_up() { local u; u="$(server_url)"; [ -n "$u" ] && curl -fsS -o /dev/null --max-time 2 "$u"; }
a_start_server() {
  server_up && return 0
  local cmd="$CFG_dev"
  if [ -z "$cmd" ]; then has_script dev && cmd="$(pm) run dev"; has_script dev || { has_script start && cmd="$(pm) start"; }; fi
  [ -n "$cmd" ] || return 1
  : > "$RUN/dev.log"
  # Separate statements: a backgrounded `cd && ...` keeps the caller's pipe open and `warmd shot | tail` never ends
  ( cd "$PROJECT" || exit 1; nohup sh -c "$cmd" > "$RUN/dev.log" 2>&1 < /dev/null & echo $! > "$RUN/dev.pid" )
  local i=0 u=""
  while [ $i -lt 120 ]; do
    u="${CFG_url:-$(sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$RUN/dev.log" | grep -oE 'https?://(localhost|127\.0\.0\.1)[:0-9]*/?[^ ]*' | head -1)}"
    if [ -n "$u" ] && curl -fsS -o /dev/null --max-time 2 "$u" 2>/dev/null; then echo "$u" > "$RUN/dev.url"; return 0; fi
    nap 0.5; i=$((i+1))
  done
  echo "FAIL dev server gave no URL in 60 s, see $(native_path "$RUN/dev.log")"; return 1
}

browser_shot() { # exe width height scale url png
  $(tune_prefix) "$1" --headless=new --disable-gpu --hide-scrollbars --no-first-run --user-data-dir="$(native_path "$RUN/browser")"     --force-device-scale-factor="$4" --window-size="$2,$3" --virtual-time-budget=3000 --allow-file-access-from-files     --screenshot="$(native_path "$6")" "$5" >/dev/null 2>&1
}

# Two widths in one call, at a scale that keeps each image small: an agent sees layout breaks for a fraction of the tokens.
a_shot() {
  local target="${1:-}" browser out="$RUN/shots"
  gfx_take
  browser="$(find_browser)" || { echo "FAIL no Chrome, Edge or Chromium found, set WARMD_BROWSER"; return 1; }
  if [ -z "$target" ]; then
    if [ -f "$PROJECT/index.html" ] && ! has_script dev; then target="file:///$(native_path "$PROJECT/index.html")"
    else a_start_server || return 1; target="$(server_url)"; fi
  elif [ -f "$target" ]; then target="file:///$(native_path "$(cd "$(dirname "$target")" && pwd)/$(basename "$target")")"
  fi
  mkdir -p "$out"
  browser_shot "$browser" 1440 900 0.55 "$target" "$out/desktop.png"
  # Headless Chrome never goes below 500 px wide, a 390 px frame gives the page real phone media queries
  printf '<!doctype html><body style="margin:0"><iframe src="%s" width="390" height="844" style="border:0"></iframe>' "$target" > "$RUN/phone.html"
  browser_shot "$browser" 500 844 1 "file:///$(native_path "$RUN/phone.html")" "$out/phone.png"
  echo "image $(native_path "$out/desktop.png")"
  echo "image $(native_path "$out/phone.png")"
  echo "OK $(secs)s shot $target"
}

a_stop() {
  local pid; pid="$(cat "$RUN/dev.pid" 2>/dev/null)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    if [ "$OS" = win ]; then kill_tree "$(cat "/proc/$pid/winpid" 2>/dev/null || echo "$pid")"; else pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; fi
    rm -f "$RUN/dev.pid" "$RUN/dev.url"; echo "OK dev server stopped"
  else rm -f "$RUN/dev.pid" "$RUN/dev.url"; echo "OK nothing warm"; fi
}
a_status() { if server_up; then echo "dev server warm: $(server_url)"; else echo "dev server off"; fi; }
a_call() { echo "warmd call is for engines"; return 2; }
a_seed() { # node_modules is the slow part, a link costs nothing
  [ -d "$1/node_modules" ] || return 0
  [ -e "$2/node_modules" ] && return 0   # a reused worktree keeps its link
  if [ "$OS" = win ]; then powershell.exe -NoProfile -Command "New-Item -ItemType Junction -Path '$(native_path "$2/node_modules")' -Target '$(native_path "$1/node_modules")'" >/dev/null
  else ln -s "$1/node_modules" "$2/node_modules"; fi
}
a_has_cache() { [ -d "$1/node_modules" ] || [ ! -f "$1/package.json" ]; }
a_package() { echo "warmd package is for Unity"; return 2; }
a_init() { :; }
a_doctor() {
  find_browser >/dev/null && echo "ok browser for shot" || echo "MISSING Chrome, Edge or Chromium (warmd shot)"
  [ -f "$PROJECT/package.json" ] || echo "note: plain site, shot opens index.html directly"
  [ -d "$PROJECT/node_modules" ] || { [ ! -f "$PROJECT/package.json" ] || echo "MISSING node_modules, run $(pm) install"; }
}
