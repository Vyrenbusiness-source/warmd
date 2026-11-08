# Godot: the warm thing is a headless engine running godot/daemon.gd. Nothing to install for GDScript checks.
export WARMD_IDLE_MIN="$CFG_idle_min"

godot_exe() {
  local c
  for c in "${WARMD_GODOT:-}" godot godot4 Godot; do
    [ -n "$c" ] || continue
    if [ -x "$c" ]; then echo "$c"; return 0; fi
    command -v "$c" >/dev/null 2>&1 && { command -v "$c"; return 0; }
  done
  # An engine binary kept next to project.godot (gitignored): look in the project and, for a worktree, in the main checkout
  local d main
  main="$(git -C "$PROJECT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  main="${main%/.git}"
  for d in "$PROJECT" ${main:+"$main"}; do
    for c in "$d"/Godot*console*.exe "$d"/Godot*.exe "$d"/Godot*.x86_64 "$d"/godot*.x86_64; do
      [ -f "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
    done
  done
  return 1
}

# Projects without GUT, gdUnit4 or WarmdTest often keep their own runners: tests/run_*.gd that extend SceneTree and quit(1) on failure
godot_runners() {
  local f
  for f in "$PROJECT"/tests/run_*.gd "$PROJECT"/test/run_*.gd; do
    [ -f "$f" ] && grep -q '^extends SceneTree' "$f" && echo "$f"
  done
}
# A runner that does not parse or compile still ends with exit 0 (Godot even runs what it could load): its load errors count as red.
GODOT_LOAD_ERR='(Parse|Compile) Error:|Failed to load script|Can.t load (the )?script|does not inherit from a MainLoop'
run_runners() {
  local exe="$1" f rc=0 n=0 out r bad; shift
  out="$(mktemp)"
  for f in "$@"; do
    n=$((n + 1))
    echo "== ${f#"$PROJECT"/}"
    timeout "$TIMEOUT" "$exe" --headless --path "$(native_path "$PROJECT")" --script "res://${f#"$PROJECT"/}" > "$out" 2>&1; r=$?
    cat "$out"
    if [ $r != 0 ]; then echo "FAIL runner ${f#"$PROJECT"/}"; rc=1
    else
      bad="$(tr -d '\r' < "$out" | grep -E "$GODOT_LOAD_ERR" | head -1 | cut -c1-160)"
      [ -z "$bad" ] || { echo "FAIL runner ${f#"$PROJECT"/} does not load: $bad"; rc=1; }
    fi
  done
  rm -f "$out"
  [ $rc = 0 ] && echo "$n runners passed"
  return $rc
}
project_rx() { native_path "$PROJECT" | sed 's/[]().+*?^$|\\[]/\\&/g'; }
a_daemon_procs() { procs "daemon\.gd.*warmd-daemon.*$(project_rx)|$(project_rx).*daemon\.gd" 'powershell'; }

a_kill_daemon() {
  local pid
  for pid in $(a_daemon_procs) $(daemon_pid); do kill_tree "$pid"; done
  rm -f "$RUN/alive.txt" "$RUN/pid.txt"
}

a_start_daemon() {
  local exe; exe="$(godot_exe)" || { echo "FAIL Godot not found, set WARMD_GODOT"; exit 2; }
  [ -n "$(a_daemon_procs)" ] && { echo "(daemon not answering, restarting)"; a_kill_daemon; }
  rm -f "$RUN/alive.txt" "$RUN/state.txt" "$RUN/spawn.pid"
  export WARMD_DIR; WARMD_DIR="$(native_path "$RUN")"
  # First start on a fresh checkout has to build the import cache
  . "$WARMD_HOME/lib/godot_seed.sh" && godot_seed_imports "$PROJECT"
  [ -d "$PROJECT/.godot" ] || "$exe" --headless --path "$(native_path "$PROJECT")" --import >/dev/null 2>&1
  SPAWN_PID="$RUN/spawn.pid" spawn "$RUN/warmd-daemon.log" "$exe" --headless --path "$(native_path "$PROJECT")" --script "$(native_path "$WARMD_HOME/godot/daemon.gd")"
  wait_ready 120
}

# A new class_name is only known after an import, an edit to an old one reloads in place
class_cache_fresh() {
  local cache="$PROJECT/.godot/global_script_class_cache.cfg" f
  [ -f "$cache" ] || return 1
  # A read loop, not for-in over find: a project path with a space stays one path
  while IFS= read -r f; do
    if grep -q '^class_name ' "$f" && ! grep -q "$(sed -n 's/^class_name \([A-Za-z0-9_]*\).*/\1/p' "$f" | head -1)" "$cache"; then return 1; fi
  done < <(find "$PROJECT" -name '*.gd' -newer "$cache" -not -path '*/.godot/*' 2>/dev/null)
}
refresh_classes() {
  class_cache_fresh && return 0
  daemon_alive && a_kill_daemon
  . "$WARMD_HOME/lib/godot_seed.sh" && godot_seed_imports "$PROJECT"
  "$(godot_exe)" --headless --path "$(native_path "$PROJECT")" --import >/dev/null 2>&1
  return 0
}

# job_oneshot <kind> [key=value...]: one engine start, one job, no daemon. Same scripts, same result format.
job_oneshot() {
  local kind="$1" id exe; id="j$(now_ms)"; shift
  exe="$(godot_exe)" || { echo "FAIL Godot not found, set WARMD_GODOT"; return 2; }
  rm -f "$RUN/result.txt"
  { echo "id=$id"; echo "kind=$kind"; printf '%s\n' "$@"; echo "quit_after=1"; } > "$RUN/job.txt"
  WARMD_DIR="$(native_path "$RUN")" timeout "$TIMEOUT" "$exe" --headless --path "$(native_path "$PROJECT")" --script "$(native_path "$WARMD_HOME/godot/daemon.gd")" > "$RUN/last.log" 2>&1
  local rc=$?
  if [ ! -f "$RUN/result.txt" ]; then
    [ $rc = 124 ] && echo "FAIL timeout after ${TIMEOUT}s in $(cat "$RUN/current.txt" 2>/dev/null)" || echo "FAIL Godot ended without a result (exit $rc), see $(native_path "$RUN/last.log")"
    return 1
  fi
  head -15 "$RUN/result.txt" | tr -d '\r' | sed '1s/^[^ ]* //'
  [ "$(head -1 "$RUN/result.txt" | cut -d' ' -f2)" = OK ]
}
run_job() { if [ "$CFG_warm" = 1 ]; then job "$@"; else job_oneshot "$@"; fi; }

a_build() {
  refresh_classes
  if ls "$PROJECT"/*.csproj >/dev/null 2>&1 && command -v dotnet >/dev/null 2>&1; then
    run_bounded "dotnet build" bash -c "cd '$PROJECT' && dotnet build --nologo -v q" || return 1
  fi
  run_job compile
}

a_test() {
  local filter=""
  while [ $# -gt 0 ]; do case "$1" in --*) ;; *) filter="$1";; esac; shift; done
  # GUT and gdUnit4 bring their own runner, a one-shot start is fast enough for them
  if [ -f "$PROJECT/addons/gut/gut_cmdln.gd" ]; then
    local exe; exe="$(godot_exe)"
    slot_take; cached "gut|$filter" run_bounded gut "$exe" --headless --path "$(native_path "$PROJECT")" -s addons/gut/gut_cmdln.gd -gdir=res://test -ginclude_subdirs -gexit ${filter:+-gselect="$filter"}
    return
  fi
  if [ -f "$PROJECT/addons/gdUnit4/bin/GdUnitCmdTool.gd" ]; then
    local exe; exe="$(godot_exe)"
    slot_take; cached "gdunit|$filter" run_bounded gdunit "$exe" --headless --path "$(native_path "$PROJECT")" -s addons/gdUnit4/bin/GdUnitCmdTool.gd -a "${filter:-res://test}" --ignoreHeadlessMode -c
    return
  fi
  refresh_classes
  if ! grep -rqs --include='*.gd' -e 'extends WarmdTest' -e 'extends "res://addons/warmd/warmd_test.gd"' "$PROJECT" --exclude-dir=.godot --exclude-dir=addons; then
    local -a runners=()
    mapfile -t runners < <(godot_runners)
    if [ ${#runners[@]} -gt 0 ]; then
      local exe pick=() r; exe="$(godot_exe)" || { echo "FAIL Godot not found, set WARMD_GODOT"; return 2; }
      # A filter picks runners by name; one that names none (warmd check passes changed file names) runs the whole set, runners are suites
      for r in "${runners[@]}"; do [ -n "$filter" ] && [[ "${r##*/}" =~ $filter ]] && pick+=("$r"); done
      [ ${#pick[@]} -gt 0 ] || pick=("${runners[@]}")
      slot_take; cached "runners|${pick[*]##*/}" run_bounded test run_runners "$exe" "${pick[@]}"
      return
    fi
  fi
  cached "test|$filter" run_job test "filter=$filter"
}

a_check() {
  . "$WARMD_HOME/lib/affected.sh"
  affected_select gd
  case "$AFF_MODE" in
    CLEAN) echo "OK no code changed against $(base_branch)"; return 0;;
    NONE) echo "OK no test depends on this change"; return 0;;
    ALL) echo "(running all tests: $AFF_REASON)"; a_test; return;;
  esac
  local hits f
  for f in $AFF_FILES; do f="${f##*/}"; hits="${hits:+$hits|}${f%.gd}"; done
  echo "(affected: $(echo "$hits" | tr '|' ' ' | cut -c1-120))"
  a_test "($hits)"
}

a_call() { [ -n "${1:-}" ] || { echo "warmd call res://path/script.gd"; return 2; }; run_job call "script=$1"; }

a_shot() {
  local exe scene="${1:-}" out="$RUN/shots/game.png"
  gfx_take
  exe="$(godot_exe)" || { echo "FAIL Godot not found"; return 1; }
  mkdir -p "$RUN/shots"
  # shellcheck disable=SC2046  # the GPU flag is one word or none, quoted it would pass an empty argument
  WARMD_SHOT="$(native_path "$out")" WARMD_SCENE="$scene" run_bounded shot "$exe" $(tune_godot_gpu_flag "$exe") --path "$(native_path "$PROJECT")" --resolution 960x540 --script "$(native_path "$WARMD_HOME/godot/shot.gd")" || return 1
  echo "image $(native_path "$out")"
}

a_stop() { daemon_stop; }
a_status() { if [ "$CFG_warm" != 1 ]; then echo "Godot one-shot (starts in about 0.2 s, warm=1 keeps a process)"; elif daemon_alive; then echo "Godot warm, pid $(daemon_pid)"; else echo "Godot cold"; fi; }
a_seed() { [ -d "$1/.godot" ] && [ ! -e "$2/.godot" ] && cp -R "$1/.godot" "$2/.godot"; return 0; }
a_has_cache() { [ -d "$1/.godot" ]; }
a_package() { echo "warmd package is for Unity"; return 2; }
a_init() {
  mkdir -p "$PROJECT/addons/warmd"
  cp "$WARMD_HOME/godot/warmd_test.gd" "$PROJECT/addons/warmd/"
  echo "OK test base class in addons/warmd/warmd_test.gd"
}
a_doctor() {
  godot_exe >/dev/null && echo "ok Godot" || echo "MISSING Godot, set WARMD_GODOT"
}
