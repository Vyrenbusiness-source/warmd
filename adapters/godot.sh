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
    [ -f "$f" ] && grep -qE '^[[:space:]]*(@tool[[:space:]]+)?(class_name[[:space:]]+[A-Za-z0-9_]+[[:space:]]+)?extends[[:space:]]+SceneTree' "$f" && echo "$f"
  done
}
# A runner that does not parse or compile still ends with exit 0 (Godot even runs what it could load): its load errors count as red.
GODOT_LOAD_ERR='(Parse|Compile) Error:|Failed to load script|Can.t load (the )?script|does not inherit from a MainLoop'
# Why a runner failed, for the FAIL line: exit code, timeout, Windows crash code, and whether it printed a success marker first.
runner_why() {
  local r="$1" out="$2" t="$3" sig="" ok=""
  case "$r" in
    124|137) echo "timeout after ${t}s"; return;;
    3221225477|-1073741819) sig="0xC0000005 access violation";;
    3221225725|-1073741571) sig="0xC00000FD stack overflow";;
    3221226505|-1073740791) sig="0xC0000409 fast fail";;
    3221225501|-1073741795) sig="0xC000001D illegal instruction";;
    13[0-9]|14[0-9]) sig="signal $((r - 128))";;
  esac
  [ -n "$sig" ] && { echo "crashed: $sig, exit $r"; return; }
  tr -d '' < "$out" | grep -qE '^ALL OK|^=== .* 0 fehlgeschlagen ===|^FAILED: 0' && ok=" after success output"
  echo "exit $r$ok"
}
# Per-runner timeout: a line "# warmd: timeout=300" in the first 10 lines of the runner, else TIMEOUT
runner_timeout() {
  local t; t="$(head -n 10 "$1" | tr -d '\r' | sed -n 's/^#[[:space:]]*warmd:[[:space:]]*timeout=\([0-9][0-9]*\).*/\1/p' | head -1)"
  echo "${t:-$TIMEOUT}"
}
run_runners() {
  local exe="$1" f rc=0 n=0 out r bad t; shift
  out="$(mktemp)"
  for f in "$@"; do
    n=$((n + 1))
    echo "== ${f#"$PROJECT"/}"
    t="$(runner_timeout "$f")"
    timeout "$t" "$exe" --headless --path "$(native_path "$PROJECT")" --script "res://${f#"$PROJECT"/}" > "$out" 2>&1; r=$?
    cat "$out"
    if [ $r != 0 ]; then echo "FAIL runner ${f#"$PROJECT"/} ($(runner_why "$r" "$out" "$t"))"; rc=1
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

# A new class_name is only known after an import, an edit to an old one reloads in place. The class cache also goes stale
# when a branch moves a class_name script: the cache still names the old path, and the compile sees the class twice
# ("Class X hides a global script class"). class_cache_drift prints one line per difference between the class_name
# scripts on disk and .godot/global_script_class_cache.cfg, nothing when they agree. Three process starts, whatever the
# project size: this PC pays for every one.
class_cache_drift() {
  local cache="$PROJECT/.godot/global_script_class_cache.cfg" line rel cls p
  local -a skip=() mine=()
  local -A have=()
  [ -d "$PROJECT/.godot" ] || { echo "no import yet"; return 0; }
  [ -f "$cache" ] || cache=/dev/null   # no cache is an empty one: stale only once a script has a class_name
  # Godot skips a folder with a .gdignore and every hidden one: their scripts are never in the cache
  while IFS= read -r p; do skip+=("${p%.gdignore}"); done < <(find "$PROJECT" \( -name .gdignore -print \) -o \( -name '.?*' -prune \) 2>/dev/null)
  while IFS= read -r line; do
    line="${line%$'\r'}"; rel="${line#"$PROJECT"/}"; cls="${rel#*:}"; rel="${rel%%:*}"
    [[ $cls =~ ^class_name[[:space:]]+([A-Za-z0-9_]+) ]] || continue
    for p in "${skip[@]}"; do [[ "$PROJECT/$rel" == "$p"* ]] && continue 2; done
    mine+=("${BASH_REMATCH[1]}|res://$rel")
  done < <(grep -r -m1 -H -E --include='*.gd' --exclude-dir='.?*' '^class_name[[:space:]]' "$PROJECT" 2>/dev/null)
  while IFS='|' read -r cls p; do
    [ -n "$cls" ] || continue
    have["$cls"]="$p"
    [[ $p == res://* ]] && [ ! -f "$PROJECT/${p#res://}" ] && echo "$cls: cache names $p, which is gone"
  done < <(awk -F'"' '/^"class":/{c=$4} /^"path":/{print c"|"$4; c=""}' "$cache" | tr -d '\r')
  for line in "${mine[@]}"; do
    cls="${line%%|*}"; p="${line#*|}"
    [ "${have[$cls]:-}" = "$p" ] || echo "$cls: $p is not in the cache${have[$cls]:+ (cache: ${have[$cls]})}"
  done
  return 0
}
class_cache_fresh() { [ -z "$(class_cache_drift)" ]; }
# refresh_classes [force]: an import rebuilds the cache. A difference the import did not clear (two scripts with one
# class_name) is the code's error, the compile reports it: it is noted and does not cost an import on every build.
refresh_classes() {
  local drift mark="$RUN/class_drift.txt"
  drift="$(class_cache_drift)"
  if [ "${1:-}" != force ]; then
    [ -z "$drift" ] && return 0
    [ -f "$mark" ] && [ "$drift" = "$(cat "$mark" 2>/dev/null)" ] && return 0
  fi
  daemon_alive && a_kill_daemon
  . "$WARMD_HOME/lib/godot_seed.sh" && godot_seed_imports "$PROJECT"
  "$(godot_exe)" --headless --path "$(native_path "$PROJECT")" --import >/dev/null 2>&1
  drift="$(class_cache_drift)"
  if [ -n "$drift" ]; then printf '%s\n' "$drift" > "$mark" 2>/dev/null; else rm -f "$mark"; fi
  return 0
}
# class_retry <command...>: "hides a global script class" comes from a class cache that names a script twice. Its run
# is repeated once after an import, and only a run that still says so counts as red.
CLASS_HIDES='hides a global script class'
class_retry() {
  local out rc t0; out="$(mktemp)"; t0="$(mktemp)"   # t0: a log newer than it was written by this run
  "$@" > "$out" 2>&1; rc=$?
  # The engine's own lines land in a log, not in the output: a one-shot's last.log, the warm daemon's log
  local hit=0 lg
  grep -q "$CLASS_HIDES" "$out" && hit=1
  [ $rc = 0 ] || for lg in "$RUN/last.log" "$RUN/warmd-daemon.log"; do
    [ -f "$lg" ] && [ "$lg" -nt "$t0" ] && tail -50 "$lg" | grep -q "$CLASS_HIDES" && hit=1
  done
  if [ $hit = 1 ]; then
    echo "(class cache named a script twice: import, then once more)"
    refresh_classes force
    "$@" > "$out" 2>&1; rc=$?
  fi
  cat "$out"; rm -f "$out" "$t0"
  return $rc
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
  class_retry run_job compile
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
      slot_take; cached "runners|${pick[*]##*/}" run_bounded test class_retry run_runners "$exe" "${pick[@]}"
      return
    fi
  fi
  # Never a silent green: no GUT, no gdUnit4, no runner and no WarmdTest class means nothing can run
  if ! grep -rqs --include='*.gd' -e 'extends WarmdTest' -e 'extends "res://addons/warmd/warmd_test.gd"' "$PROJECT" --exclude-dir=.godot --exclude-dir=addons; then
    echo "WARN no tests found: no GUT, no gdUnit4, no WarmdTest class and no tests/run_*.gd that extends SceneTree. Nothing ran"
    return 0
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
