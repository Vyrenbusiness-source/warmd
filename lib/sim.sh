# warmd sim: gameplay scenarios for Godot, headless under a fixed physics tick, one line of metrics against limits each.
#   sim_main [--seed N] [file.sim|dir|name...]   every tests/sim/*.sim without arguments
#   sim_main --record <scene> [--seed N] [--frames N] [--name x] [--headless]   play the scene, the input goes to tests/sim/<x>.sim
# All scenarios that need a run share ONE engine start (godot/sim.gd). --fixed-fps <physics ticks per second> makes every frame
# exactly one physics tick and lets the engine run as fast as it can: no --time-scale, which keeps the ticks and loses exactness.
# A scenario stops as soon as its verdict is decided. A line "isolate" gives one scenario an engine of its own (autoloads,
# static state). Verdicts are cached per scenario: code (every file except *.sim) + engine + the scenario file + seed.
# Changing or adding one scenario reruns only that one. A crash or timeout is never cached, the scenarios after it get a new engine.
# Headless is not rendered: shaders, rendering, audio timing and the real mouse are not there (godot-ship's rendered smoke run is).

SIM_TICKS=60
sim_main() {
  [ "$KIND" = godot ] && [ -n "$(type -t godot_exe)" ] || { echo "FAIL warmd sim is for Godot projects"; return 2; }
  local seed="" files=() a rec="" frames=0 name="" headless=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --record) rec=1; case "${2:-}" in ""|--*) ;; *) files+=("$2"); shift;; esac;;
      --seed) seed="${2:-}"; shift; case "$seed" in ''|*[!0-9-]*) echo "FAIL --seed wants a whole number"; return 2;; esac;;
      --frames) frames="${2:-}"; shift; case "$frames" in ''|*[!0-9]*) echo "FAIL --frames wants a number"; return 2;; esac;;
      --name) name="${2:-}"; shift;;
      --headless) headless=1;;
      --*) echo "FAIL unknown option $1"; return 2;;
      *) files+=("$1");;
    esac
    shift
  done
  a="$(tr -d '\r' < "$PROJECT/project.godot" 2>/dev/null | sed -n 's/^common\/physics_ticks_per_second=\([0-9][0-9]*\).*/\1/p' | head -1)"
  SIM_TICKS="${a:-60}"
  if [ -n "$rec" ]; then sim_record "${files[0]:-}" "$seed" "$frames" "$name" "$headless"; return; fi
  sim_run "$seed" "${files[@]}"
}

# sim_files <arg...>: the scenario files, absolute, one per line. No argument: tests/sim/*.sim of the project.
sim_files() {
  local a f
  if [ $# = 0 ]; then [ -d "$PROJECT/tests/sim" ] && find "$PROJECT/tests/sim" -maxdepth 1 -type f -name '*.sim' | sort; return 0; fi
  for a in "$@"; do
    for f in "$a" "$PROJECT/$a" "$PROJECT/tests/sim/$a" "$PROJECT/tests/sim/$a.sim"; do
      if [ -d "$f" ]; then find "$f" -maxdepth 1 -type f -name '*.sim' | sort; continue 2
      elif [ -f "$f" ]; then echo "$(cd "$(dirname "$f")" && pwd)/${f##*/}"; continue 2; fi
    done
    echo "MISSING $a"
  done
}

# The key every scenario shares: the git tree and the changed files minus *.sim, the engine, warmd's sim scripts.
# The scenario's own file is added per scenario, so a new or edited scenario does not rerun the others.
sim_base_key() {
  local top="${GIT_ROOT:-}" list
  [ -n "$top" ] || return 1
  # Untracked .uid files are left out: the first engine start of a checkout writes them (Godot 4.4), they change no verdict
  list="$( { git -C "$top" ls-files -m; git -C "$top" ls-files -o --exclude-standard | grep -vE '\.uid$'; } | tr -d '\r' | grep -vE '\.sim$' | sort -u)"
  {
    git -C "$top" ls-tree -r HEAD 2>/dev/null | grep -vE '\.sim$'
    echo "$list"; engine_key; echo "ticks $SIM_TICKS"
    [ -n "$list" ] && (cd "$top" && printf '%s\n' "$list" | while IFS= read -r f; do [ -f "$f" ] && printf '%s\0' "$f"; done | xargs -0 -r sha1sum 2>/dev/null)
    cat "$WARMD_HOME/godot/sim.gd" "$WARMD_HOME/godot/replay.gd"
  } | { sha1sum 2>/dev/null || shasum; } | cut -c1-20
}

# sim_engine <jobs file> <log>: one engine start for the scenarios in the jobs file
sim_engine() {
  WARMD_SIM_JOBS="$(native_path "$1")" WARMD_SIM_REPLAY="$(native_path "$WARMD_HOME/godot/replay.gd")" WARMD_SIM_SEED="$SIM_SEED" \
    timeout "$SIM_TIMEOUT" "$SIM_EXE" --headless --fixed-fps "$SIM_TICKS" --path "$(native_path "$PROJECT")" \
    --script "$(native_path "$WARMD_HOME/godot/sim.gd")" > "$2" 2>&1
}

# sim_verdict <END text> <segment log>: the scenario's line. Script errors the engine printed while it ran make it red,
# other engine errors only add one capped warning.
sim_verdict() {
  local v="$1" seg="$2" errs n w=""
  errs="$(godot_errors "$seg")"
  n="$(printf '%s' "$errs" | grep -c .)"
  [ "$n" -gt 1 ] && w=" (+$((n - 1)) more)"
  if [ "$n" -gt 0 ]; then
    case "$v" in
      OK*) v="FAIL script error $(echo "$errs" | head -1 | cut -c1-160)$w, metrics: ${v#OK }";;
      *) v="$v; script error $(echo "$errs" | head -1 | cut -c1-160)$w";;
    esac
  else
    n="$(tr -d '\r' < "$seg" | grep -cE '^(ERROR|WARNING):')"
    [ "$n" -gt 0 ] && v="$v (warning: $n engine errors or warnings while it ran, see the log)"
  fi
  echo "$v"
}

sim_run() {
  SIM_SEED="$1"; shift
  local list f n k key base="" i t0 starts=0 red=0 hit=0 ran=0 total=0 dir jobs log names=() paths=() fshas=() iso=() todo=() verdict store=() s sd sf sl
  t0="$(now_ms)"
  list="$(sim_files "$@")"
  if echo "$list" | grep -q '^MISSING '; then echo "$list" | sed -n 's/^MISSING \(.*\)/FAIL no scenario \1/p'; return 2; fi
  [ -n "$list" ] || { echo "FAIL no scenarios: write tests/sim/<name>.sim (scene, seed, frames, metric lines) or record one: warmd sim --record <scene>"; return 2; }
  SIM_TIMEOUT="${WARMD_SIM_TIMEOUT:-${TIMEOUT:-900}}"
  [ "${WARMD_NOCACHE:-0}" = 1 ] || base="$(sim_base_key)"
  mkdir -p "$CACHE_ROOT/sim/green" "$CACHE_ROOT/sim/red" "$RUN"
  find "$CACHE_ROOT/sim/green" -type f -mtime +7 -delete 2>/dev/null
  find "$CACHE_ROOT/sim/red" -type f -mmin +"${RED_MIN:-120}" -delete 2>/dev/null
  while IFS= read -r f; do
    n="${f##*/}"; n="${n%.sim}"; n="${n// /_}"
    total=$((total + 1))
    # Cheap checks first: a scenario without a scene, or with a scene file that is not there, needs no engine start
    k="$(tr -d '\r' < "$f" | sed -n 's/^[[:space:]]*scene[[:space:]]\{1,\}\([^[:space:]#]*\).*/\1/p' | head -1)"
    if [ -z "$k" ]; then echo "FAIL $n: no scene line"; red=$((red + 1)); continue; fi
    case "$k" in res://*) [ -f "$PROJECT/${k#res://}" ] || { echo "FAIL $n: no scene $k"; red=$((red + 1)); continue; };; esac
    k="$( { sha1sum < "$f" 2>/dev/null || shasum < "$f"; } | cut -c1-40)"
    if [ -n "$base" ]; then
      key="$(sha_of "$base|$k|seed $SIM_SEED")"
      if [ -f "$CACHE_ROOT/sim/green/$key" ]; then echo "$(cat "$CACHE_ROOT/sim/green/$key") (cached)"; hit=$((hit + 1)); continue; fi
      if [ -f "$CACHE_ROOT/sim/red/$key" ]; then echo "$(cat "$CACHE_ROOT/sim/red/$key") (cached, code unchanged)"; hit=$((hit + 1)); red=$((red + 1)); continue; fi
    fi
    names+=("$n"); paths+=("$f"); fshas+=("$k")
    if tr -d '\r' < "$f" | grep -qE '^[[:space:]]*isolate([[:space:]]|$)'; then iso+=("${#names[@]}"); else todo+=("${#names[@]}"); fi
  done <<< "$list"

  if [ ${#names[@]} -gt 0 ]; then
    SIM_EXE="$(godot_exe)" || { echo "FAIL Godot not found, set WARMD_GODOT"; return 2; }
    slot_take
    if [ -d "$PROJECT/.godot" ]; then refresh_classes; else refresh_classes force; fi
    dir="$(mktemp -d)"; log="$RUN/sim.log"; : > "$log"
    # One engine for the shared scenarios, one per isolated scenario; after a crash the rest go on in a new engine
    local groups=() g
    [ ${#todo[@]} -gt 0 ] && groups+=("${todo[*]}")
    for i in "${iso[@]}"; do groups+=("$i"); done
    for g in "${groups[@]}"; do
      local left=($g)
      while [ ${#left[@]} -gt 0 ]; do
        jobs="$dir/jobs"; : > "$jobs"
        for i in "${left[@]}"; do printf '%s\t%s\n' "${names[i-1]}" "$(native_path "${paths[i-1]}")" >> "$jobs"; done
        rm -f "$dir"/seg* "$dir/res"
        sim_engine "$jobs" "$dir/run.log"; local rc=$?
        starts=$((starts + 1))
        tr -d '\r' < "$dir/run.log" >> "$log"
        tr -d '\r' < "$dir/run.log" | awk -v D="$dir" '
          /^SIM BEGIN / { k++; seg = D "/seg" k; printf "" > seg; inseg = 1; next }
          /^SIM END / { sub(/^SIM END [^ ]+ /, ""); print k "\t" $0 > (D "/res"); close(seg); inseg = 0; next }
          inseg { print > seg }'
        local begun done_n=0 j=0
        begun="$(grep -c '^SIM BEGIN ' "$dir/run.log")"
        while IFS=$'\t' read -r j verdict; do
          [ -n "$j" ] || continue
          i="${left[j-1]}"; done_n="$j"
          verdict="$(sim_verdict "$verdict" "$dir/seg$j")"
          ran=$((ran + 1))
          f="${verdict%% *} ${names[i-1]}: ${verdict#* }"
          echo "$f"
          case "$verdict" in OK*) store+=("green ${fshas[i-1]} $f");; *) red=$((red + 1)); store+=("red ${fshas[i-1]} $f");; esac
        done < <(cat "$dir/res" 2>/dev/null)
        [ "$done_n" -ge ${#left[@]} ] && break
        if [ "$begun" -gt 0 ] && [ "$begun" = "$done_n" ]; then
          left=("${left[@]:done_n}")   # it ended between two scenarios: the rest go on in a new engine
        elif [ "$begun" -gt "$done_n" ]; then
          # The engine ended inside a scenario: that one is red (never cached), the ones after it get a new engine
          i="${left[done_n]}"; red=$((red + 1)); ran=$((ran + 1))
          verdict="$(godot_errors "$dir/seg$begun" | head -1 | cut -c1-160)"
          echo "FAIL ${names[i-1]}: the engine ended in this scenario ($(runner_why "$rc" "$dir/run.log" "$SIM_TIMEOUT"))${verdict:+: $verdict}"
          left=("${left[@]:done_n+1}")
        else
          # No scenario started: the engine or warmd's script did not come up, a new start would end the same way
          echo "FAIL sim: Godot ended before a scenario ran (exit $rc), see $(native_path "$log")"
          { godot_errors "$dir/run.log"; grep -E "$GODOT_LOAD_ERR|^SIM FATAL" "$dir/run.log"; } | awk '!seen[$0]++' | head -3 | cut -c1-200
          rm -rf "$dir"; return 1
        fi
      done
    done
    rm -rf "$dir"
    for s in "${store[@]}"; do
      read -r sd sf sl <<< "$s"
      [ -n "$base" ] && echo "$sl" > "$CACHE_ROOT/sim/$sd/$(sha_of "$base|$sf|seed $SIM_SEED")"
    done
  fi
  local how="$((total - red)) of $total green"
  [ "$hit" -gt 0 ] && how="$how, $hit cached"
  how="$how, $starts engine start$([ "$starts" = 1 ] || echo s), $(( ($(now_ms) - t0) / 1000 ))s"
  if [ "$red" -gt 0 ]; then echo "FAIL sim: $how${log:+, log $(native_path "$log")}"; return 1; fi
  echo "OK sim: $how"
}

# sim_record <scene> <seed> <frames> <name> <headless>: plays the scene in a window (a human plays) and writes every input
# change per physics tick to tests/sim/<name>.sim. That file is a scenario: add the metric that is red for the bug.
sim_record() {
  local scene="$1" seed="$2" frames="$3" name="$4" headless="$5" res f n out log rc args=()
  [ -n "$scene" ] || { echo "warmd sim --record <scene.tscn | res://path | name> [--seed N] [--frames N] [--name x] [--headless]"; return 2; }
  case "$scene" in
    res://*) res="$scene"; [ -f "$PROJECT/${res#res://}" ] || { echo "FAIL no scene $res"; return 1; };;
    *)
      if [ -f "$scene" ]; then f="$scene"
      elif [ -f "$PROJECT/$scene" ]; then f="$PROJECT/$scene"
      else
        f="$(find "$PROJECT" -type f \( -name "$scene" -o -name "$scene.tscn" \) -not -path '*/.godot/*' -not -path '*/.git/*' -not -path '*/addons/*' 2>/dev/null | sort | head -2)"
        [ -n "$f" ] || { echo "FAIL no scene named $scene"; return 1; }
        [ "$(printf '%s\n' "$f" | wc -l)" -gt 1 ] && { echo "FAIL $scene names more than one scene, give the path"; return 1; }
      fi
      f="$(cd "$(dirname "$f")" && pwd)/${f##*/}"
      case "$f" in "$PROJECT"/*) res="res://${f#"$PROJECT"/}";; *) echo "FAIL $scene is outside the project"; return 1;; esac;;
  esac
  [ -n "$seed" ] || seed=$(( RANDOM * 32768 + RANDOM ))
  [ -n "$name" ] || { name="${res##*/}"; name="rec_${name%.*}_$(date +%Y%m%d_%H%M%S)"; }
  out="$PROJECT/tests/sim/$name.sim"
  [ -e "$out" ] && { echo "FAIL $out exists, give another --name"; return 1; }
  SIM_EXE="$(godot_exe)" || { echo "FAIL Godot not found, set WARMD_GODOT"; return 2; }
  mkdir -p "$PROJECT/tests/sim" "$RUN"
  slot_take
  if [ -d "$PROJECT/.godot" ]; then refresh_classes; else refresh_classes force; fi
  # A human plays in real time with a window; --headless (scripted input, CI) runs under the fixed tick as fast as it can
  [ "$headless" = 1 ] && args=(--headless --fixed-fps "$SIM_TICKS")
  [ "$headless" = 1 ] || echo "(recording $res: play, then close the window)"
  log="$RUN/sim-record.log"
  WARMD_SIM_MODE=record WARMD_SCENE="$res" WARMD_SIM_OUT="$(native_path "$out")" WARMD_SIM_SEED="$seed" WARMD_SIM_FRAMES="$frames" \
    WARMD_SIM_REPLAY="$(native_path "$WARMD_HOME/godot/replay.gd")" \
    timeout "${WARMD_SIM_RECORD_TIMEOUT:-7200}" "$SIM_EXE" "${args[@]}" --path "$(native_path "$PROJECT")" \
    --script "$(native_path "$WARMD_HOME/godot/sim.gd")" > "$log" 2>&1
  rc=$?
  if [ ! -s "$out" ]; then
    echo "FAIL nothing recorded (exit $rc), see $(native_path "$log")"
    { tr -d '\r' < "$log" | sed -n 's/^SIM FATAL //p'; godot_errors "$log"; } | head -3 | cut -c1-200
    rm -f "$out"; return 1
  fi
  # A crash or a kill leaves no frames line: the scenario then ends one tick after the last input
  if ! tr -d '\r' < "$out" | grep -q '^frames '; then
    f="$(tr -d '\r' < "$out" | awk '$1 ~ /^[0-9]+$/ { n = $1 } END { print n + 1 }')"
    echo "frames $f" >> "$out"
  fi
  f="$(tr -d '\r' < "$out" | sed -n 's/^frames //p' | tail -1)"
  n="$(tr -d '\r' < "$out" | grep -cE '^[0-9]+ ')"
  echo "OK recorded $f frames, $n inputs, seed $seed to tests/sim/$name.sim. Add a metric line that is red for the bug, then: warmd sim tests/sim/$name.sim"
}
