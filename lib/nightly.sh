# warmd nightly: once a night everything without the cache, each part in a process of its own, to prove the shortcuts of
# the day were right. Three questions, each answered by a real run:
#   cache   a result that differs from the cached one means the cache key misses an input: printed loudly as MISMATCH,
#           after a second fresh run confirmed it (a test that changes its mind is FLAKY, no key error)
#   graph   Godot runners run one engine each with --verbose: every script, scene or resource the engine really loads
#           and the static graph (lib/affected.sh) cannot reach is a selection error. It is printed as GAP and kept as an
#           extra edge in warmd-edges.tsv (common git dir), so the next nights know it
#   mutate  warmd mutate on the lines changed since the last nightly run (mutate=off in warmd.conf skips it)
# Determinism: warmd sim twice, the two outputs must match (only where warmd sim exists).
# Morning report: five lines, also in .warmd/nightly.txt; the numbers go to warmd-quality.tsv for report and gain.
# Not installed as a scheduled task by itself: warmd nightly --schedule prints the one-liner for schtasks and cron.
reg nightly "warmd nightly [--schedule|--report] [--no-mutate]  all once without cache: cache key, graph and mutation check" nightly_main

nightly_common() { git -C "$PROJECT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null; }
# Extra edges the engine proved and the static graph missed, in the format of the graph: E<TAB>from<TAB>to
nightly_edges_file() { local d; d="$(nightly_common)" || return 1; echo "$d/warmd-edges.tsv"; }

nightly_schedule() {
  local p b w=""; p="$PROJECT"; b="$(command -v bash)"
  command -v cygpath >/dev/null 2>&1 && { w="$(cygpath -w "$p")"; b="$(cygpath -w "$b")"; }
  echo "warmd nightly is not installed as a task by itself. One line, once, in a shell you trust:"
  if [ -n "$w" ]; then
    echo "  schtasks /Create /SC DAILY /ST 03:00 /TN \"warmd nightly ${p##*/}\" /TR \"\\\"$b\\\" -lc \\\"cd '$p' && warmd nightly >> .warmd/nightly.log 2>&1\\\"\""
  fi
  echo "  cron: 0 3 * * * cd '$p' && warmd nightly >> .warmd/nightly.log 2>&1"
  echo "The morning report: warmd nightly --report"
}

# nightly_run <args...>: one warmd command in a process of its own, output in NR_OUT, exit code returned
nightly_run() { NR_OUT="$( cd "$PROJECT" && bash "$WARMD_HOME/bin/warmd" "$@" 2>&1 )"; }

# nightly_cmp <name> <fresh rc> <fresh output>: compares with the cached verdict of the same command (NC_RC, NC_STATE).
# A cached verdict that a fresh run contradicts is confirmed by a second fresh run before it counts as a cache key error.
nightly_cmp() {
  local name="$1" frc="$2" fout="$3" fgreen cgreen rc2
  [ "$NC_STATE" = none ] && return 0
  N_COMPARED=$((N_COMPARED + 1))
  fgreen=0; [ "$frc" = 0 ] && fgreen=1
  cgreen=0; [ "$NC_STATE" = green ] && cgreen=1
  [ $fgreen = $cgreen ] && return 0
  # Not a verdict: a timeout, a missing engine, a full RAM. The cache never keeps those either
  if [ $fgreen = 0 ] && { [ "$frc" -ge 124 ] 2>/dev/null || echo "$fout" | grep -qiE "$RED_ENV"; }; then
    echo "WARN $name: the fresh run did not finish as a verdict (exit $frc), no comparison: $(echo "$fout" | grep -iE "$RED_ENV" | head -1 | cut -c1-120)"
    return 0
  fi
  if [ -n "${NC_SECOND:-}" ]; then $NC_SECOND; rc2=$?; else WARMD_NOCACHE=1 nightly_run "$name"; rc2=$?; fi
  if { [ $rc2 = 0 ] && [ $fgreen = 1 ]; } || { [ $rc2 != 0 ] && [ $fgreen = 0 ]; }; then
    N_MISMATCH=$((N_MISMATCH + 1)); MISMATCH_OF="${MISMATCH_OF:+$MISMATCH_OF }$name"
    echo "MISMATCH $name: the cache says $([ $cgreen = 1 ] && echo green || echo red), two fresh runs say $([ $fgreen = 1 ] && echo green || echo red). The cache key misses an input of $name (lib/core.sh code_key, engine_key)"
    echo "$fout" | grep -E '^(FAIL|RED)' | head -3 | sed 's/^/  /' | cut -c1-200
  elif [ "${NC_SECOND:-}" = nightly_run_shared ]; then
    N_FLAKY=$((N_FLAKY + 1))
    echo "ISOLATION $name: the runners each in an engine of their own say $([ $fgreen = 1 ] && echo green || echo red), in one shared engine $([ $rc2 = 0 ] && echo green || echo red) like the cache: a runner depends on what another one left behind"
  else
    N_FLAKY=$((N_FLAKY + 1))
    echo "FLAKY $name: the cache says $([ $cgreen = 1 ] && echo green || echo red), the first fresh run differs, the second agrees with the cache: the result changes without a code change"
  fi
}

# nightly_cached <command>: the verdict the cache gives for a command now, NC_STATE green, red or none (it really ran)
nightly_cached() {
  nightly_run "$1"; NC_RC=$?
  if echo "$NR_OUT" | grep -q '^OK cached, code unchanged'; then NC_STATE=green
  elif echo "$NR_OUT" | grep -q '^RED cached, code unchanged'; then NC_STATE=red
  else NC_STATE=none; fi
}

# nightly_closure <edges> <runner>: every file the static graph lets the runner reach, the runner included.
# Prints UNSURE when one of them loads something the graph cannot see (a dynamic load): that runner is always selected.
nightly_closure() {
  awk -F'\t' -v S="$2" '$1 == "E" { n[$2]++; to[$2, n[$2]] = $3 } $1 == "U" { u[$2] = 1 }
    END { q[1] = S; v[S] = 1; k = 1
      for (h = 1; h <= k; h++) { x = q[h]; if (x in u) { print "UNSURE"; exit } for (i = 1; i <= n[x]; i++) { y = to[x, i]; if (!(y in v)) { v[y] = 1; q[++k] = y } } }
      for (x in v) print x }' "$1"
}

# nightly_loads <engine log>: project files the engine loaded (scripts, scenes, resources), one per line
nightly_loads() {
  tr -d '\r' < "$1" | grep -iE 'load' | grep -oE 'res://[^ "'"'"'),]+\.(gd|tscn|tres|scn|res)' | sed 's#^res://##' | awk '!seen[$0]++' | while IFS= read -r f; do
    case "$f" in .godot/*|addons/warmd/*) continue;; esac
    [ -f "$PROJECT/$f" ] && echo "$f"
  done
}

# nightly_gaps <edges> <runner rel> <engine log>: GAP lines, new extra edges appended to warmd-edges.tsv. Sets GAPS_NEW.
nightly_gaps() {
  local edges="$1" rel="$2" log="$3" ef c f
  GAPS_NEW=0
  ef="$(nightly_edges_file)" || return 0
  c="$(nightly_closure "$edges" "$rel")"
  [ "$c" = UNSURE ] && return 0
  c=$'\n'"$c"$'\n'
  while IFS= read -r f; do
    [ "$f" = "$rel" ] && continue
    case "$c" in *$'\n'"$f"$'\n'*) continue;; esac
    GAPS_NEW=$((GAPS_NEW + 1))
    [ $GAPS_NEW -le 10 ] && echo "GAP $rel loads $f, the static graph has no path to it: a change there would not select $rel (edge kept in warmd-edges.tsv)"
    printf 'E\t%s\t%s\n' "$rel" "$f" >> "$ef"
  done < <(nightly_loads "$log")
  [ $GAPS_NEW -gt 10 ] && echo "GAP (+$((GAPS_NEW - 10)) more for $rel)"
  return 0
}

# The static graph of the project plus the extra edges of earlier nights
nightly_graph() { # out file
  [ -n "$(type -t aff_list)" ] || . "$WARMD_HOME/lib/affected.sh"
  local tmp ef; tmp="$(mktemp -d)"
  aff_list > "$tmp/list"
  awk -v ROOT="$PROJECT" -v LIST="$tmp/list" "$AFF_AWK_COMMON
$AFF_AWK_GD" < /dev/null > "$1"
  ef="$(nightly_edges_file)" && [ -f "$ef" ] && cat "$ef" >> "$1"
  rm -rf "$tmp"
}

# Godot runners, one engine each with --verbose: the verdict of each and the files it loads. Sets N_RUNNERS, N_GAPS, RUN_RC.
nightly_godot() {
  local exe f rel t out r bad load edges
  local -a runners=()
  N_RUNNERS=0; RUN_RC=0
  mapfile -t runners < <(godot_runners)
  [ ${#runners[@]} -gt 0 ] || return 1
  exe="$(godot_exe)" || { echo "WARN nightly: Godot not found, no load log (set WARMD_GODOT)"; return 1; }
  out="$(mktemp -d)"; edges="$out/edges"
  nightly_graph "$edges"
  slot_now
  for f in "${runners[@]}"; do
    rel="${f#"$PROJECT"/}"; t="$(runner_timeout "$f")"
    timeout "$t" "$exe" --headless --verbose --path "$(native_path "$PROJECT")" --script "res://$rel" > "$out/log" 2>&1; r=$?
    N_RUNNERS=$((N_RUNNERS + 1))
    bad="$(godot_errors "$out/log" | head -1 | cut -c1-160)"
    load="$(tr -d '\r' < "$out/log" | grep -E "$GODOT_LOAD_ERR" | head -1 | cut -c1-160)"
    if [ $r != 0 ] || [ -n "$load" ] || [ -n "$bad" ]; then
      RUN_RC=1; echo "FAIL runner $rel in its own engine ($(runner_why "$r" "$out/log" "$t"))${load:+: $load}${bad:+: $bad}"
    fi
    nightly_gaps "$edges" "$rel" "$out/log"; N_GAPS=$((N_GAPS + GAPS_NEW))
  done
  # Give the slot back: the warmd commands after this take their own
  [ -n "$SLOT" ] && rm -rf "$SLOT"; SLOT=""
  rm -rf "$out"
  return 0
}

# Determinism: warmd sim twice on the same code, outputs without times and pids must match. Hook point until warmd sim exists.
nightly_sim() {
  grep -q '^reg sim ' "$WARMD_HOME/lib/sim.sh" 2>/dev/null || { SIM_LINE="determinism: no warmd sim here"; return 0; }
  local a b ra rb norm='s/[0-9]+(\.[0-9]+)? ?(ms|s)\b/T/g; s/pid [0-9]+/pid P/g; s/seed [0-9]+/seed S/g'
  WARMD_NOCACHE=1 nightly_run sim; ra=$?; a="$(echo "$NR_OUT" | sed -E "$norm")"
  if [ $ra = 2 ]; then SIM_LINE="determinism: warmd sim has no scenario here"; return 0; fi
  WARMD_NOCACHE=1 nightly_run sim; rb=$?; b="$(echo "$NR_OUT" | sed -E "$norm")"
  if [ "$ra" = "$rb" ] && [ "$a" = "$b" ]; then SIM_LINE="determinism: two sim runs match"; return 0; fi
  SIM_DIFF=1; SIM_LINE="determinism: DIFFERS, two sim runs on the same code gave different results"
  echo "NONDETERMINISTIC warmd sim: exit $ra then $rb, first differing line: $(diff <(echo "$a") <(echo "$b") | grep -E '^[<>]' | head -2 | tr '\n' ' ' | cut -c1-200)"
}

nightly_main() {
  local mode=run nomut=0 a
  for a in "$@"; do
    case "$a" in --schedule) mode=schedule;; --report) mode=report;; --no-mutate) nomut=1;; *) echo "warmd nightly [--schedule|--report] [--no-mutate]"; return 2;; esac
  done
  detect_project
  case "$mode" in
    schedule) nightly_schedule; return 0;;
    report)
      if [ -f "$STATE/nightly.txt" ]; then cat "$STATE/nightly.txt"; else echo "no nightly run yet: warmd nightly"; fi
      quality_line; return 0;;
  esac
  [ -n "$GIT_ROOT" ] || { echo "FAIL warmd nightly needs a git repo (the cache key is git based)"; return 2; }
  # shellcheck source=/dev/null
  . "$WARMD_HOME/adapters/$ADAPTER.sh"
  export WARMD_DETACHED=1   # scheduled: nobody waits in a shell, a queued slot must not end the run
  local sha out rc=0 brc trc line1 line3 line4 last mbase
  sha="$(git -C "$PROJECT" rev-parse --short HEAD)"
  N_COMPARED=0; N_MISMATCH=0; N_FLAKY=0; N_GAPS=0; N_RUNNERS=0; MISMATCH_OF=""; SIM_DIFF=0; SIM_LINE=""
  out="$(mktemp)"
  {
    # build: the cached verdict, then a fresh one. A cache miss already was a fresh run: it is not run twice
    nightly_cached build; brc=$NC_RC
    if [ "$NC_STATE" != none ]; then WARMD_NOCACHE=1 nightly_run build; brc=$?; NC_SECOND="" nightly_cmp build "$brc" "$NR_OUT"; fi
    [ $brc = 0 ] || { echo "FAIL build without cache:"; echo "$NR_OUT" | grep -E '^(FAIL|RED|  )' | head -5 | cut -c1-200; }
    # tests: Godot runners each in an engine of their own with a load log, everything else as warmd test without cache
    nightly_cached test
    if [ "$ADAPTER" = godot ] && nightly_godot; then
      trc=$RUN_RC
      NC_SECOND="nightly_run_shared" nightly_cmp test "$trc" "$( [ $trc = 0 ] && echo OK || echo FAIL runners)"
      # No cache entry: the shared run just now was fresh, alone and shared must still agree
      if [ "$NC_STATE" = none ] && [ $(( NC_RC == 0 )) != $(( trc == 0 )) ]; then
        N_FLAKY=$((N_FLAKY + 1)); echo "ISOLATION test: the runners in one shared engine exit $NC_RC, each in an engine of its own exit $trc: a runner depends on what another one left behind"
      fi
    else
      trc=$NC_RC
      if [ "$NC_STATE" != none ]; then WARMD_NOCACHE=1 nightly_run test; trc=$?; NC_SECOND="" nightly_cmp test "$trc" "$NR_OUT"; fi
      [ $trc = 0 ] || { echo "FAIL tests without cache:"; echo "$NR_OUT" | grep -E '^(FAIL|RED)' | head -5 | cut -c1-200; }
    fi
    nightly_sim
    # export smoke (export_smoke=1 in warmd.conf): the exported build must start, a red one turns the night red
    PKG_RC=0; [ "${CFG_export_smoke:-0}" = 1 ] && { nightly_run package; PKG_RC=$?; [ $PKG_RC = 0 ] || { echo "FAIL export smoke:"; echo "$NR_OUT" | grep -E '^(FAIL|RED|  )' | head -5 | cut -c1-200; }; }
    # mutate: the lines changed since the last nightly run, else since the commit before
    line4="mutate: off (mutate=off in warmd.conf)"
    if [ $nomut = 1 ]; then line4="mutate: skipped (--no-mutate)"
    elif [ "${CFG_mutate:-}" != off ]; then
      last="$(cat "$STATE/nightly.last" 2>/dev/null)"
      if [ -n "$last" ] && git -C "$PROJECT" rev-parse -q --verify "$last^{commit}" >/dev/null 2>&1; then mbase="$last"
      else mbase="$(git -C "$PROJECT" rev-parse -q --verify HEAD~1 2>/dev/null)"; fi
      if [ -z "$mbase" ] || [ "$(git -C "$PROJECT" rev-parse "$mbase")" = "$(git -C "$PROJECT" rev-parse HEAD)" ]; then
        line4="mutate: no commit since the last nightly run"
      elif [ $trc != 0 ]; then line4="mutate: not run, the tests are red"
      else
        MUT_CMD="${CFG_mutate_cmd:-}"
        mutate_run "$mbase" "${CFG_mutate_limit:-900}"
        if [ "$MUT_TOTAL" -gt 0 ]; then
          line4="mutate: score $(( 100 * MUT_KILLED / MUT_TOTAL ))% ($MUT_KILLED of $MUT_TOTAL killed, $MUT_SURVIVED survived$([ "$MUT_SKIPPED" -gt 0 ] && echo ", $MUT_SKIPPED not run: time limit"))"
        elif [ "$MUT_SKIPPED" -gt 0 ]; then line4="mutate: time limit before the first of $MUT_SKIPPED mutants"
        else line4="mutate: nothing to mutate since ${mbase:0:7}"; fi
      fi
    fi
  } > "$out" 2>&1
  cat "$out"
  line1="nightly $(date '+%F %H:%M') $sha: build $([ $brc = 0 ] && echo OK || echo RED), tests $([ $trc = 0 ] && echo OK || echo RED) (fresh, no cache$([ $N_RUNNERS -gt 0 ] && echo ", $N_RUNNERS runners one engine each"))$([ "${CFG_export_smoke:-0}" = 1 ] && echo ", export $([ $PKG_RC = 0 ] && echo OK || echo RED)")"
  line3="graph: no load log (Godot runners only)"
  [ $N_RUNNERS -gt 0 ] && line3="graph: $N_RUNNERS runners load-logged, $N_GAPS gaps$([ $N_GAPS -gt 0 ] && echo ' (selection errors, extra edges kept in warmd-edges.tsv)')"
  {
    echo "$line1"
    echo "cache: $N_COMPARED compared, $N_MISMATCH mismatches$([ -n "$MISMATCH_OF" ] && echo " (cache key wrong: $MISMATCH_OF)")$([ $N_FLAKY -gt 0 ] && echo ", $N_FLAKY flaky")"
    echo "$line3"
    echo "$line4"
    echo "$SIM_LINE"
  } | tee "$STATE/nightly.txt"
  rm -f "$out"
  quality_record nightly "$N_COMPARED" "$N_MISMATCH" "$N_GAPS" "$N_FLAKY"
  git -C "$PROJECT" rev-parse HEAD > "$STATE/nightly.last"
  [ $brc = 0 ] && [ $trc = 0 ] && [ $N_MISMATCH = 0 ] && [ "$SIM_DIFF" = 0 ] && [ "$PKG_RC" = 0 ] || rc=1
  return $rc
}

# The second fresh opinion for Godot runners: warmd test without cache, the runners shared in one engine as by day
nightly_run_shared() { WARMD_NOCACHE=1 nightly_run test; }
