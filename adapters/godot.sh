# Godot: the warm thing is a headless engine running godot/daemon.gd. Nothing to install for GDScript checks.
export WARMD_IDLE_MIN="$CFG_idle_min"
# godot_allow_errors=<regex> in warmd.conf: script errors it matches, as "file:line message", are noise. Every other
# script error is red, an addon's too: noise passes only by name, never silently.
export WARMD_ALLOW_ERRORS="${CFG_godot_allow_errors:-}"

godot_exe() {
  local c
  [ -n "${WARMD_GODOT:-}" ] || { [ -f "$CACHE_ROOT/godot.path" ] && read -r WARMD_GODOT < "$CACHE_ROOT/godot.path"; }
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
# godot_errors <log>: the engine's script errors as "file:line message" and its aborts, one line each, minus the allowlist.
# A runtime error ends only the function it happens in, the runner still quits with 0: the output is the one witness.
godot_errors() {
  tr -d '\r' < "$1" | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | awk '
    pend != "" { at = ""; if ($0 ~ /^[[:space:]]*at: .*\(.*:[0-9]+\)[[:space:]]*$/) { at = $0; sub(/^.*\(/, "", at); sub(/\)[[:space:]]*$/, "", at); sub(/^res:\/\//, "", at) }
                 print (at != "" ? at " " : "") pend; pend = "" }
    /^SCRIPT ERROR:/ { pend = $0; sub(/^SCRIPT ERROR:[[:space:]]*/, "", pend); next }
    /Program crashed|CrashHandlerException/ { print "engine abort: " $0 }
    END { if (pend != "") print pend }' | { if [ -n "${CFG_godot_allow_errors:-}" ]; then grep -vE -- "$CFG_godot_allow_errors"; else cat; fi; } | awk '!seen[$0]++'
  return 0
}
# godot_exit_leak <log> <rel>: a debug engine names what was never freed when it ends ("ObjectDB instances leaked",
# "resources still in use"): prints the verdict and succeeds when the runner leaked. godot_allow_errors matching
# "<rel>: leaked at exit" makes it noise.
godot_exit_leak() {
  local n
  # Godot 4.4: "ObjectDB instances leaked at exit", 4.7: "1 ObjectDB instance was leaked at exit" (with the count)
  n="$(tr -d '\r' < "$1" | grep -E 'ObjectDB instances? (was |were )?leaked at exit|resources? still in use at exit' | head -1 | cut -c1-120)"
  [ -n "$n" ] || return 1
  [ -n "${CFG_godot_allow_errors:-}" ] && printf '%s: leaked at exit\n' "$2" | grep -qE -- "$CFG_godot_allow_errors" && return 1
  echo "leaks at exit: ${n#WARNING: } (run it with --verbose for the list)"
}
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
  tr -d '\r' < "$out" | grep -qE '^ALL OK|^=== .* 0 fehlgeschlagen ===|^FAILED: 0' && ok=" after success output"
  echo "exit $r$ok"
}
# Per-runner timeout: a line "# warmd: timeout=300" in the first 10 lines of the runner, else TIMEOUT
runner_timeout() {
  local t; t="$(head -n 10 "$1" | tr -d '\r' | sed -n 's/^#[[:space:]]*warmd:[[:space:]]*timeout=\([0-9][0-9]*\).*/\1/p' | head -1)"
  echo "${t:-$TIMEOUT}"
}
# A runner with a line "# warmd: isolate" in its first 10 lines changes autoloads or static state: it gets an engine of its own
runner_isolated() { head -n 10 "$1" | tr -d '\r' | grep -qE '^#[[:space:]]*warmd:[[:space:]]*isolate'; }
# runner_shuffle <seed> <file...>: the files in an order the seed fixes, the same on every machine (own LCG, no awk rand)
runner_shuffle() {
  local s="$1" i j t; shift
  local -a a=("$@")
  for (( i = ${#a[@]} - 1; i > 0; i-- )); do
    s=$(( (s * 1103515245 + 12345) % 2147483648 )); j=$(( s % (i + 1) ))
    t="${a[i]}"; a[i]="${a[j]}"; a[j]="$t"
  done
  [ ${#a[@]} -gt 0 ] && printf '%s\n' "${a[@]}"
  return 0
}
# run_alone <exe> <runner>: the runner as the engine's main loop, one engine start for it
run_alone() {
  local exe="$1" f="$2" out r bad load where t leak rc=0
  out="$(mktemp)"
  echo "== ${f#"$PROJECT"/} (own engine)"
  t="$(runner_timeout "$f")"
  timeout "$t" "$exe" --headless --path "$(native_path "$PROJECT")" --script "res://${f#"$PROJECT"/}" > "$out" 2>&1; r=$?
  cat "$out"
  bad="$(godot_errors "$out" | head -1 | cut -c1-200)"
  if [ $r != 0 ]; then echo "FAIL runner ${f#"$PROJECT"/} ($(runner_why "$r" "$out" "$t"))${bad:+: $bad}"; rc=1
  else
    where=""; [[ ${bad%% *} =~ :[0-9]+$ ]] && where=" at ${bad%% *}"
    load="$(tr -d '\r' < "$out" | grep -E "$GODOT_LOAD_ERR" | head -1 | cut -c1-160)"
    if [ -n "$load" ]; then echo "FAIL runner ${f#"$PROJECT"/} does not load: $load$where"; rc=1
    elif [ -n "$bad" ]; then echo "FAIL runner ${f#"$PROJECT"/} script error ${bad} (exit 0)"; rc=1
    elif leak="$(godot_exit_leak "$out" "${f#"$PROJECT"/}")"; then echo "FAIL runner ${f#"$PROJECT"/} $leak"; rc=1; fi
  fi
  rm -f "$out"
  return $rc
}
# run_shared <exe> <runner...>: the runners one after another in one engine (godot/daemon.gd, job kind runners), each with
# its own verdict. A runner that ends the engine (a crash, a hang the engine cannot time out, a quit through the real tree)
# is named: red for a crash or hang, its own engine for a clean quit. The runners after it get a new engine.
# Runners that do not compile as a guest go to SHARED_ALONE, passes are counted in SHARED_OK.
run_shared() {
  local exe="$1" f rel st detail t total list r cur ended rc=0 res="$RUN/runners.txt" log="$RUN/runners.log"; shift
  local -a rest=("$@") next=()
  local -A verdict=()
  while [ ${#rest[@]} -gt 0 ]; do
    rm -f "$res" "$RUN/current.txt" "$RUN/result.txt"
    total=30; list=""
    for f in "${rest[@]}"; do t="$(runner_timeout "$f")"; total=$((total + t)); list="${list:+$list,}res://${f#"$PROJECT"/}|$t"; done
    { echo "id=r$(now_ms)"; echo "kind=runners"; echo "list=$list"; echo "quit_after=1"; } > "$RUN/job.txt"
    WARMD_DIR="$(native_path "$RUN")" WARMD_LOG="$(native_path "$log")" timeout "$total" "$exe" --headless --path "$(native_path "$PROJECT")" --script "$(native_path "$WARMD_HOME/godot/daemon.gd")" > "$log" 2>&1; r=$?
    tr -d '\r' < "$log"
    verdict=()
    while IFS=$'\t' read -r rel st detail; do [ -n "$rel" ] && verdict["$rel"]="$st"$'\t'"$detail"; done < <(tr -d '\r' < "$res" 2>/dev/null)
    cur="$(tr -d '\r' < "$RUN/current.txt" 2>/dev/null)"; cur="${cur#res://}"
    next=(); ended=""
    for f in "${rest[@]}"; do
      rel="${f#"$PROJECT"/}"
      if [ -n "${verdict[$rel]+x}" ]; then
        st="${verdict[$rel]%%$'\t'*}"; detail="${verdict[$rel]#*$'\t'}"
        case "$st" in
          OK) SHARED_OK=$((SHARED_OK + 1));;
          ALONE) echo "(runner $rel gets its own engine: $detail)"; SHARED_ALONE+=("$f");;
          *) echo "FAIL runner $rel $detail"; rc=1;;
        esac
      elif [ "$ended" = all ]; then SHARED_ALONE+=("$f")
      elif [ -n "$ended" ]; then next+=("$f")
      elif [ "$cur" != "$rel" ]; then
        # The engine ended before this runner started: no runner is to blame, every one left gets an engine of its own
        ended=all; echo "(shared engine ended before $rel started, exit $r: the rest run alone)"; SHARED_ALONE+=("$f")
      else
        ended=1
        case "$r" in
          124|137) echo "FAIL runner $rel (timeout: the shared engine hung in it and was ended after ${total}s)"; rc=1;;
          0) echo "(runner $rel ended the shared engine: it gets its own)"; SHARED_ALONE+=("$f");;
          *) echo "FAIL runner $rel ($(runner_why "$r" "$log" "$total"), the shared engine ended in it)"; rc=1;;
        esac
      fi
    done
    rest=("${next[@]}")
  done
  return $rc
}
# All runners in one engine start (speed on a low-RAM PC), in an order from a printed seed: WARMD_SEED=<n> replays it.
# A runner marked "# warmd: isolate", and one that does not compile as a guest, gets an engine of its own.
run_runners() {
  local exe="$1" f rc=0 seed; shift
  local -a shared=() alone=()
  seed="${WARMD_SEED:-$(( (RANDOM << 15) | RANDOM ))}"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if runner_isolated "$f"; then alone+=("$f"); else shared+=("$f"); fi
  done < <(runner_shuffle "$seed" "$@")
  echo "(runner order from seed $seed, WARMD_SEED=$seed replays it)"
  SHARED_OK=0; SHARED_ALONE=()
  # One runner alone gains nothing from a shared engine: it runs as the main loop, exactly as Godot runs it
  if [ ${#shared[@]} -gt 1 ]; then run_shared "$exe" "${shared[@]}" || rc=1; alone=("${SHARED_ALONE[@]}" "${alone[@]}")
  else alone=("${shared[@]}" "${alone[@]}"); fi
  for f in "${alone[@]}"; do run_alone "$exe" "$f" || rc=1; done
  [ $rc = 0 ] && echo "$# runners passed ($SHARED_OK in one engine, ${#alone[@]} alone)"
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
  # The daemon reads its own errors back from its output: spawn writes stdout to the log, on Windows stderr to log.err
  export WARMD_LOG; WARMD_LOG="$(native_path "$RUN/warmd-daemon.log")|$(native_path "$RUN/warmd-daemon.log.err")"
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
  # Godot skips a folder with a .gdignore and every hidden one: their scripts are never in the cache.
  # Both searches run from inside the project on ".": grep's --exclude-dir matches any suffix of a path it is given, so
  # with an absolute path a hidden folder above the project (warmd's own .warmd-worktrees) excluded every script.
  while IFS= read -r p; do skip+=("${p%.gdignore}"); done < <(cd "$PROJECT" && find . \( -name .gdignore -print \) -o \( -name '.?*' -prune \) 2>/dev/null)
  while IFS= read -r line; do
    line="${line%$'\r'}"; rel="${line#./}"; cls="${rel#*:}"; rel="${rel%%:*}"
    [[ $cls =~ ^class_name[[:space:]]+([A-Za-z0-9_]+) ]] || continue
    for p in "${skip[@]}"; do [[ "./$rel" == "$p"* ]] && continue 2; done
    mine+=("${BASH_REMATCH[1]}|res://$rel")
  done < <(cd "$PROJECT" && grep -r -m1 -H -E --include='*.gd' --exclude-dir='.?*' '^class_name[[:space:]]' . 2>/dev/null)
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
  # JOB_GFX=1: the engine renders (a graphics slot, the GPU warmd picked), else it runs headless
  local -a view=(--headless)
  if [ "${JOB_GFX:-0}" = 1 ]; then gfx_take; read -ra view <<< "$(tune_godot_gpu_flag "$exe")"; fi
  WARMD_DIR="$(native_path "$RUN")" WARMD_LOG="$(native_path "$RUN/last.log")" timeout "$TIMEOUT" "$exe" "${view[@]}" --path "$(native_path "$PROJECT")" --script "$(native_path "$WARMD_HOME/godot/daemon.gd")" > "$RUN/last.log" 2>&1
  local rc=$?
  if [ ! -f "$RUN/result.txt" ]; then
    [ $rc = 124 ] && echo "FAIL timeout after ${TIMEOUT}s in $(cat "$RUN/current.txt" 2>/dev/null)" || echo "FAIL Godot ended without a result (exit $rc), see $(native_path "$RUN/last.log")"
    # The engine's own reason (warmd's script does not load, a parse error in it), so nobody has to open the log
    { godot_errors "$RUN/last.log"; tr -d '\r' < "$RUN/last.log" | grep -E "$GODOT_LOAD_ERR"; } | awk '!seen[$0]++' | head -3 | cut -c1-200
    return 1
  fi
  head -15 "$RUN/result.txt" | tr -d '\r' | sed '1s/^[^ ]* //'
  [ "$(head -1 "$RUN/result.txt" | cut -d' ' -f2)" = OK ]
}
run_job() { if [ "$CFG_warm" = 1 ]; then job "$@"; else job_oneshot "$@"; fi; }

# engine_refresh: warmd's own files in the project (only addons/warmd/warmd_test.gd, the daemon and drivers run from
# $WARMD_HOME) follow a newer warmd without a manual warmd init. One file compare, no engine start. Only a copy warmd
# installed is replaced, known by its header; content only, so the .uid next to it stays valid. Never committed here.
engine_refresh() {
  local f="$PROJECT/addons/warmd/warmd_test.gd" src="$WARMD_HOME/godot/warmd_test.gd"
  [ -f "$f" ] && [ -f "$src" ] || return 0
  [ "$(tr -d '\r' < "$f")" = "$(tr -d '\r' < "$src")" ] && return 0
  head -n 3 "$f" | tr -d '\r' | grep -qx '## Tiny base class for warmd tests\..*' || return 0
  [ "$(head -n 1 "$f" | tr -d '\r')" = "class_name WarmdTest" ] || return 0
  cat "$src" > "$f" && echo "updated addons/warmd/warmd_test.gd to warmd ${WARMD_VERSION:-?}"
}
# A green compile stays green until the code (project.godot included) or the engine changes: the build is cached like a test
a_build() {
  engine_refresh
  local exe; exe="$(godot_exe)" || exe=none
  cached "build|$exe|${WARMD_VERSION:-}" godot_build
}
godot_build() {
  refresh_classes
  if ls "$PROJECT"/*.csproj >/dev/null 2>&1 && command -v dotnet >/dev/null 2>&1; then
    run_bounded "dotnet build" bash -c "cd '$PROJECT' && dotnet build --nologo -v q" || return 1
  fi
  local scenes; scenes="$(changed_scenes)"
  class_retry run_job compile ${scenes:+"scenes=$scenes"}
}
# changed_scenes: the .tscn and .tres changed against HEAD and the base branch (warmd check's selection), as res:// paths
# with a comma between. The build's cache key covers them: a green load stays green until one of them changes.
changed_scenes() {
  [ -n "$(type -t aff_changed)" ] || . "$WARMD_HOME/lib/affected.sh"
  aff_changed | grep -E '\.(tscn|tres)$' | grep -vE '(^|/)\.(godot|warmd)/' | while IFS= read -r f; do
    [ -f "$PROJECT/$f" ] && printf 'res://%s,' "$f"
  done | sed 's/,$//'
}

a_test() {
  engine_refresh
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
      # A replay (WARMD_SEED) really runs: its order is the point. A random order is green for the same code either way.
      slot_take; cached "runners|${pick[*]##*/}${WARMD_SEED:+|seed $WARMD_SEED}" run_bounded test class_retry run_runners "$exe" "${pick[@]}"
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

# Budgets at merge (WARMD_BUDGET=1 runs them in any warmd check), set in warmd.conf next to perf_scene:
#   budget_texture_px=2048        no changed texture longer than this on its long side (after process/size_limit)
#   budget_texture_raw_px=512     no changed texture stored lossless or VRAM uncompressed (compress/mode 0 or 3) longer
#   budget_<scene>=draw_calls=200,memory_mb=64,nodes=500   <scene>.tscn over budget_frames frames (default 60):
#                                 its peak draw calls, memory and nodes. Draw calls need a renderer.
#   rendered_smoke=1              the main scene runs with graphics on every merge (graphics slot): a script error is red
# One engine start for all of it, rendered when a draw call budget or rendered_smoke asks for it.
godot_budgets() {
  local k spec f s rel w h long lim mode line kind a b c d e list_t="" list_s="" gfx=0 rc=0 main res
  local -A tex=() scene_of=() want=()
  [ -n "$(type -t aff_changed)" ] || . "$WARMD_HOME/lib/affected.sh"
  if [ -n "${CFG_budget_texture_px:-}${CFG_budget_texture_raw_px:-}" ]; then
    while IFS= read -r f; do
      f="${f%.import}"
      [ -f "$PROJECT/$f" ] && [ -f "$PROJECT/$f.import" ] && tr -d '\r' < "$PROJECT/$f.import" | grep -q '^importer="texture"' && tex["$f"]=1
    done < <(aff_changed | grep -vE '(^|/)\.(godot|warmd)/')
    for f in "${!tex[@]}"; do list_t="${list_t:+$list_t,}res://$f"; done
  fi
  for k in $(compgen -v CFG_budget_); do
    s="${k#CFG_budget_}"
    case "$s" in cheap|mid|top|texture_px|texture_raw_px|frames) continue;; esac
    spec="${!k}"; [[ $spec == *=* ]] || continue
    f="$(cd "$PROJECT" && find . \( -name .godot -o -name .git -o -name .warmd -o -name addons \) -prune -o -name "$s.tscn" -print 2>/dev/null | head -1)"
    [ -n "$f" ] || { echo "FAIL budget_$s: no $s.tscn in the project"; rc=1; continue; }
    f="res://${f#./}"; scene_of["$f"]="$s"; want["$s"]="$spec"; list_s="${list_s:+$list_s,}$f"
    [[ $spec == *draw_calls=* ]] && gfx=1
  done
  if [ "${CFG_rendered_smoke:-0}" = 1 ]; then
    gfx=1
    main="$(tr -d '\r' < "$PROJECT/project.godot" | sed -n 's/^run\/main_scene="\(.*\)"/\1/p' | head -1)"
    case "$main" in uid://*) main="";; esac   # a uid main scene: the engine resolves it, warmd cannot from here
    [ -n "$main" ] && [ -z "${scene_of[$main]+x}" ] && list_s="${list_s:+$list_s,}$main"
    [ -n "$main" ] || echo "WARN rendered_smoke=1 but no res:// main scene in project.godot"
  fi
  [ -n "$list_t$list_s" ] || return $rc
  rm -f "$RUN/budget.txt"
  res="$(JOB_GFX=$gfx job_oneshot budget ${list_t:+"textures=$list_t"} ${list_s:+"scenes=$list_s"} "frames=${CFG_budget_frames:-60}")" || { printf '%s\n' "$res"; return 1; }
  printf '%s\n' "$res" | head -1
  while IFS=$'\t' read -r kind a b c d e; do
    case "$kind" in
      texture)
        rel="${a#res://}"; w="$b"; h="$c"; long=$(( w > h ? w : h ))
        lim="$(tr -d '\r' < "$PROJECT/$rel.import" | sed -n 's/^process\/size_limit=\([0-9]*\)/\1/p' | head -1)"
        [ "${lim:-0}" -gt 0 ] && [ "$long" -gt "$lim" ] && long="$lim"
        mode="$(tr -d '\r' < "$PROJECT/$rel.import" | sed -n 's/^compress\/mode=\([0-9]*\)/\1/p' | head -1)"
        case "${mode:-0}" in 0) mode=lossless;; 1) mode=lossy;; 2) mode="vram compressed";; 3) mode="vram uncompressed";; 4) mode=basis;; esac
        if [ -n "${CFG_budget_texture_px:-}" ] && [ "$long" -gt "$CFG_budget_texture_px" ]; then
          echo "FAIL budget: texture $rel ${w}x$h ($mode) is over budget_texture_px=$CFG_budget_texture_px"; rc=1
        elif [ -n "${CFG_budget_texture_raw_px:-}" ] && [ "$long" -gt "$CFG_budget_texture_raw_px" ] && { [ "$mode" = lossless ] || [ "$mode" = "vram uncompressed" ]; }; then
          echo "FAIL budget: texture $rel ${w}x$h is stored $mode, over budget_texture_raw_px=$CFG_budget_texture_raw_px: use VRAM compressed"; rc=1
        fi;;
      scene)
        s="${scene_of[$a]:-}"; [ -n "$s" ] || continue
        echo "(scene $s: $b $c $d)"
        for line in ${want[$s]//,/ }; do
          k="${line%%=*}"; spec="${line#*=}"
          case "$k" in
            draw_calls) [ "${e#rendered=}" = 1 ] || { echo "FAIL budget_$s: draw_calls need a renderer, this engine ran headless"; rc=1; continue; }; f="${d#draw_calls=}";;
            memory_mb) f="${c#memory_mb=}";;
            nodes) f="${b#nodes=}";;
            *) echo "FAIL budget_$s: unknown key $k (draw_calls, memory_mb, nodes)"; rc=1; continue;;
          esac
          awk -v x="$f" -v m="$spec" 'BEGIN { exit !(x + 0 > m + 0) }' && { echo "FAIL budget_$s: $k $f is over $spec"; rc=1; }
        done;;
    esac
  done < <(tr -d '\r' < "$RUN/budget.txt" 2>/dev/null)
  [ $rc = 0 ] && echo "OK budgets kept"
  return $rc
}

a_check() {
  engine_refresh
  godot_lint || return 1
  if [ "${WARMD_IN_MERGE:-0}" = 1 ] || [ "${WARMD_BUDGET:-0}" = 1 ]; then godot_budgets || return 1; fi
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

# warmd shot [scene] [--golden | --golden-update] [--from image.png]
#   --golden         the shot against this machine's reference (.warmd/golden/<machine>/<scene>.png), answer as text:
#                    SAME, or DIFF 3.2% in region x,y,w,h. golden_tolerance=<percent> in warmd.conf (default 0.5).
#   --golden-update  makes or renews the reference, the only way one changes: a DIFF never renews it.
#   --from <png>     compares an image made elsewhere (a CI artifact) instead of taking a shot.
a_shot() {
  local exe scene="" out="$RUN/shots/game.png" mode="" from=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --golden) mode=check;; --golden-update) mode=update;;
      --from) from="${2:-}"; shift;;
      -*) echo "FAIL unknown option $1: warmd shot [scene] [--golden|--golden-update] [--from image.png]"; return 2;;
      *) scene="$1";;
    esac; shift
  done
  if [ -n "$from" ]; then
    [ -s "$from" ] || { echo "FAIL no image at $from"; return 1; }
    out="$from"
  else
    gfx_take
    exe="$(godot_exe)" || { echo "FAIL Godot not found"; return 1; }
    mkdir -p "$RUN/shots"; rm -f "$out"
    # shellcheck disable=SC2046  # the GPU flag is one word or none, quoted it would pass an empty argument
    WARMD_SHOT="$(native_path "$out")" WARMD_SCENE="$scene" run_bounded shot "$exe" $(tune_godot_gpu_flag "$exe") --path "$(native_path "$PROJECT")" --resolution 960x540 --script "$(native_path "$WARMD_HOME/godot/shot.gd")"
    local rc=$?
    if [ ! -s "$out" ]; then
      # A headless engine (no display, no GPU) renders nothing: there is no image to compare, never a SAME
      [ -n "$mode" ] && echo "FAIL golden: the engine gave no image (exit $rc). Headless renders nothing: golden shots need graphics, run with WARMD_GFX=1 on a machine with a display and GPU"
      return 1
    fi
    [ $rc = 0 ] || return 1
  fi
  [ -n "$mode" ] || { echo "image $(native_path "$out")"; return 0; }
  golden "$mode" "$out" "$scene"
}
# golden <check|update> <image> <scene>: the reference lives per machine, a driver or GPU change renders differently
golden() {
  local mode="$1" img="$2" scene="$3" machine name ref res v rc
  machine="${COMPUTERNAME:-$(uname -n 2>/dev/null)}"; machine="$(printf '%s' "${machine:-local}" | tr -c 'A-Za-z0-9._-' '_')"
  name="${scene##*/}"; name="${name%.*}"; name="${name:-main}"
  ref="$PROJECT/.warmd/golden/$machine/$name.png"
  if [ "$mode" = update ]; then
    mkdir -p "${ref%/*}" && cp "$img" "$ref" || { echo "FAIL golden: cannot write $ref"; return 1; }
    echo "OK golden reference for $name on $machine: $(native_path "$ref")"; return 0
  fi
  [ -f "$ref" ] || { echo "FAIL golden: no reference for $name on $machine. warmd shot ${scene:+$scene }--golden-update makes one"; return 1; }
  res="$(run_job golden "shot=$(native_path "$img")" "ref=$(native_path "$ref")" "tol=${CFG_golden_tolerance:-0.5}")"; rc=$?
  v="$(printf '%s\n' "$res" | sed -n '2{/^\(SAME\|DIFF\)/p}')"
  if [ -n "$v" ]; then echo "$v"; else printf '%s\n' "$res"; fi
  [ $rc = 0 ] || { [ -n "$v" ] && echo "image $(native_path "$img"), reference $(native_path "$ref")"; return 1; }
}

a_stop() { daemon_stop; }
a_status() { if [ "$CFG_warm" != 1 ]; then echo "Godot one-shot (starts in about 0.2 s, warm=1 keeps a process)"; elif daemon_alive; then echo "Godot warm, pid $(daemon_pid)"; else echo "Godot cold"; fi; }
a_seed() { [ -d "$1/.godot" ] && [ ! -e "$2/.godot" ] && cp -R "$1/.godot" "$2/.godot"; return 0; }
a_has_cache() { [ -d "$1/.godot" ]; }
# warmd package: export smoke. The first preset of export_presets.cfg exported with --export-release into a temp folder,
# the build started headless for export_frames frames (default 120): red on a script error, a load error or a crash.
# This finds what the editor hides: files the export filter leaves out, loads that only work from the source tree.
# An engine without export templates exports the pack (--export-pack) and runs it on the editor binary (--main-pack).
a_package() {
  local exe presets="$PROJECT/export_presets.cfg" preset platform tmp log="$RUN/export.log" runlog="$RUN/export_run.log" ext="" r
  local frames="${CFG_export_frames:-120}" how=release bad
  local -a run=()
  exe="$(godot_exe)" || { echo "FAIL Godot not found, set WARMD_GODOT"; return 2; }
  [ -f "$presets" ] || { echo "FAIL no export_presets.cfg: add an export preset in the editor (Project > Export)"; return 2; }
  preset="$(tr -d '\r' < "$presets" | awk -F'"' '/^\[preset\.[0-9]+\]/ {on=1; next} /^\[/ {on=0} on && /^name=/ {print $2; exit}')"
  platform="$(tr -d '\r' < "$presets" | awk -F'"' '/^\[preset\.[0-9]+\]/ {on=1; next} /^\[/ {on=0} on && /^platform=/ {print $2; exit}')"
  [ -n "$preset" ] || { echo "FAIL export_presets.cfg names no preset"; return 2; }
  tr -d '\r' < "$PROJECT/project.godot" | grep -q '^run/main_scene=' || { echo "FAIL no main scene in project.godot: the exported build would start nothing"; return 1; }
  case "$platform" in "Windows Desktop") ext=.exe;; Linux*) ext=.x86_64;; esac
  tmp="$(mktemp -d)"
  slot_take
  echo "(export: preset \"$preset\" ($platform) into $(native_path "$tmp"))"
  timeout "${CFG_export_timeout:-600}" "$exe" --headless --path "$(native_path "$PROJECT")" --export-release "$preset" "$(native_path "$tmp/game$ext")" > "$log" 2>&1
  if [ ! -s "$tmp/game$ext" ]; then
    if tr -d '\r' < "$log" | grep -qi 'export template'; then
      how=pack
      timeout "${CFG_export_timeout:-600}" "$exe" --headless --path "$(native_path "$PROJECT")" --export-pack "$preset" "$(native_path "$tmp/game.pck")" > "$log" 2>&1
    fi
    if [ ! -s "$tmp/game$ext" ] && [ ! -s "$tmp/game.pck" ]; then
      echo "FAIL export of \"$preset\" made no build, see $(native_path "$log")"
      tr -d '\r' < "$log" | grep -E '^(ERROR|SCRIPT ERROR)|rror:' | awk '!s[$0]++' | head -3 | cut -c1-200
      rm -rf "$tmp"; return 1
    fi
  fi
  # A release build reports no GDScript error (no debugger in it): it proves the start, a crash or a load error. The same
  # pack on the editor binary (--main-pack) then shows the script errors the release build swallows.
  local start="" said
  if [ $how = release ]; then
    if { [ "$platform" = "Windows Desktop" ] && [ "$OS" = win ]; } || { [ "$ext" = .x86_64 ] && [ "$OS" != win ] && [ "$OS" != mac ]; }; then
      export_run release "$tmp/game$ext" || { rm -rf "$tmp"; return 1; }
      start="the release build and "
    else echo "(a $platform build does not start on this machine: only its pack runs)"; fi
    if [ ! -s "$tmp/game.pck" ]; then   # the pack is embedded in the binary: export it on its own
      timeout "${CFG_export_timeout:-600}" "$exe" --headless --path "$(native_path "$PROJECT")" --export-pack "$preset" "$(native_path "$tmp/game.pck")" > "$log" 2>&1
      [ -s "$tmp/game.pck" ] || { echo "FAIL export smoke: --export-pack made no pack, see $(native_path "$log")"; rm -rf "$tmp"; return 1; }
    fi
  fi
  export_run pack "$exe" --main-pack "$(native_path "$tmp/game.pck")" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  said="release export"; [ $how = pack ] && said="pack only, no export templates for this engine"
  echo "OK export smoke: \"$preset\" exported ($said), ${start}its pack on the editor binary ran headless for $frames frames, no script error, no crash"
}
# export_run <label> <command...>: the exported build headless for export_frames frames. Red on a crash, a non-zero exit,
# a script error, a load error (minus godot_allow_errors).
export_run() {
  local label="$1" r bad runlog="$RUN/export_run_$1.log" frames="${CFG_export_frames:-120}" t="${CFG_export_run_timeout:-120}"; shift
  timeout "$t" "$@" --headless --quit-after "$frames" > "$runlog" 2>&1; r=$?
  bad="$( { godot_errors "$runlog"; tr -d '\r' < "$runlog" | grep -E "$GODOT_LOAD_ERR|Failed loading resource|Cannot open file|Resource file not found" | { if [ -n "${CFG_godot_allow_errors:-}" ]; then grep -vE -- "$CFG_godot_allow_errors"; else cat; fi; }; } | awk '!s[$0]++' | head -3 | cut -c1-200)"
  if [ $r != 0 ]; then echo "FAIL export smoke: the exported build ($label) ended with $(runner_why "$r" "$runlog" "$t"), see $(native_path "$runlog")"; [ -n "$bad" ] && echo "$bad"; return 1; fi
  if [ -n "$bad" ]; then echo "FAIL export smoke: the exported build ($label) has errors, see $(native_path "$runlog")"; echo "$bad"; return 1; fi
  return 0
}
a_init() {
  mkdir -p "$PROJECT/addons/warmd"
  cp "$WARMD_HOME/godot/warmd_test.gd" "$PROJECT/addons/warmd/"
  echo "OK test base class in addons/warmd/warmd_test.gd"
}
# Errors that break a clone or a teammate: .uid and .import files not versioned (Godot 4.4 links by uid), the import
# cache .godot/ not ignored, an engine that is not the version the project is pinned to.
a_doctor() {
  local exe="" v="" pin src bad n rc=0 found=""
  src="godot_version in warmd.conf"; pin="${CFG_godot_version:-}"
  if [ -z "$pin" ]; then
    src="config/features in project.godot"
    pin="$(tr -d '\r' < "$PROJECT/project.godot" 2>/dev/null | sed -n 's/^config\/features=PackedStringArray("\([0-9][0-9.]*\)".*/\1/p' | head -1)"
  fi
  if exe="$(godot_exe)"; then echo "ok Godot"
  # Not on PATH, not in WARMD_GODOT: an engine in a common place (brake_godot_find) of the pinned version is taken over
  # into the cache (godot.path), so no session sets WARMD_GODOT again. Another version is only named, never remembered.
  elif declare -F brake_godot_find >/dev/null && brake_godot_find --no-save; then
    found="$REPLY"; v="$("$found" --version 2>/dev/null | tr -d '\r' | grep -E '^[0-9]' | head -1)"
    if [ -n "$v" ] && [ -n "$pin" ] && { [ "$v" = "$pin" ] || [[ $v == "$pin".* ]]; }; then
      exe="$found"; WARMD_GODOT="$found"; GODOT_DOCTOR_FOUND=1
      { mkdir -p "$CACHE_ROOT" && printf '%s\n' "$found" > "$CACHE_ROOT/godot.path"; } 2>/dev/null
      echo "ok Godot $v found at $(native_path "$found"), not on PATH: remembered in the warmd cache (godot.path)"
    else
      echo "MISSING Godot, set WARMD_GODOT: found Godot ${v:-of unknown version} at $(native_path "$found"), not the pinned ${pin:-version}"
      exe=""; v=""; GODOT_DOCTOR_FOUND=1
    fi
  else exe=""; echo "MISSING Godot, set WARMD_GODOT"; fi
  if [ -n "$GIT_ROOT" ]; then
    if git -C "$PROJECT" check-ignore -q .godot/ 2>/dev/null; then echo "ok .godot/ ignored"
    else echo "ERROR .godot/ is not ignored: the import cache would land in git. Fix: echo .godot/ >> .gitignore"; rc=1; fi
    # An ignored .uid is an error, an ignored folder is not the project: .claude/worktrees/ held 255 old worktrees (24089
    # files counted). git lists a wholly ignored folder as one "dir/" line, also one that holds only *.uid files of an
    # ignored *.uid pattern: check-ignore keeps the folders a pattern names themselves.
    bad="$(git -C "$PROJECT" ls-files --others -- '*.uid' '*.import' ':!:.godot/*' ':!:.warmd/*' ':!:.claude/worktrees/*' 2>/dev/null |
      awk -v skip="$(git -C "$PROJECT" ls-files --others --ignored --exclude-standard --directory 2>/dev/null | grep '/$' | git -C "$PROJECT" check-ignore --stdin 2>/dev/null)" '
        BEGIN { n = split(skip, s, "\n") } { for (i = 1; i <= n; i++) if (s[i] != "" && index($0, s[i]) == 1) next; print }')"
    if [ -z "$bad" ]; then echo "ok .uid and .import files versioned"
    else
      n="$(printf '%s\n' "$bad" | wc -l | tr -d ' ')"
      echo "ERROR $n .uid/.import files not versioned ($(printf '%s\n' "$bad" | head -3 | tr '\n' ' ' | sed 's/ $//')): a clone without them loses uid links and import settings. Fix: git add them, take them out of .gitignore"; rc=1
    fi
  fi
  [ -n "$exe" ] && [ -z "$v" ] && v="$("$exe" --version 2>/dev/null | tr -d '\r' | grep -E '^[0-9]' | head -1)"
  if [ -z "$pin" ]; then echo "ERROR Godot version not pinned: project.godot has no config/features version, warmd.conf no godot_version. Fix: godot_version=${v%%.stable*} in warmd.conf"; rc=1
  elif [ -z "$v" ]; then echo "note: Godot $pin pinned ($src), no engine here to compare"
  elif [ "$v" = "$pin" ] || [[ $v == "$pin".* ]]; then echo "ok Godot $v matches the pin $pin ($src)"
  else echo "ERROR Godot $v is not the pinned $pin ($src): imports and .uid files would churn. Fix: WARMD_GODOT=<a $pin engine>"; rc=1; fi
  return $rc
}
