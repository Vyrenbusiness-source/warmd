# Rust, Go, Python, .NET and anything set in warmd.conf. Nothing to keep warm, the value is the bounded output, the cache and the queue.
in_project() { ( cd "$PROJECT" && $(tune_prefix) "$@" ); }

a_build() {
  if [ -n "$CFG_build" ]; then run_bounded build in_project sh -c "$CFG_build"; return; fi
  case "$KIND" in
    rust) run_bounded check in_project cargo check -j "$(tune_threads)" --quiet --all-targets;;
    go) run_bounded build in_project go build ./...;;
    python) if command -v ruff >/dev/null 2>&1; then run_bounded ruff in_project ruff check .; else run_bounded compile in_project python -m compileall -q .; fi;;
    dotnet) run_bounded build in_project dotnet build -m:"$(tune_threads)" --nologo -v q;;
    *) echo "OK nothing to compile, set build= in warmd.conf";;
  esac
}

test_cmd() {
  if [ -n "$CFG_test" ]; then run_bounded test in_project sh -c "$CFG_test ${1:-}"; return; fi
  case "$KIND" in
    rust) run_bounded test in_project cargo test -j "$(tune_threads)" --quiet ${1:-};;
    go) run_bounded test in_project go test ./... ${1:+-run "$1"};;
    python) run_bounded test in_project python -m pytest -q ${1:--x};;
    dotnet) run_bounded test in_project dotnet test -m:"$(tune_threads)" --nologo -v q ${1:+--filter "$1"};;
    *) echo "OK no tests configured, set test= in warmd.conf";;
  esac
}
a_test() { slot_take; cached "test|${1:-}" test_cmd "${1:-}"; }

a_check() {
  local names hits flt
  if [ "$KIND" = python ] || [ "$KIND" = dotnet ]; then
    . "$WARMD_HOME/lib/affected.sh"
    affected_select "$([ "$KIND" = python ] && echo py || echo cs)"
    case "$AFF_MODE" in
      CLEAN) echo "OK no code changed against $(base_branch)"; return 0;;
      NONE) echo "OK no test depends on this change"; return 0;;
      ALL) echo "(running all tests: $AFF_REASON)"; a_test; return;;
    esac
    if [ "$KIND" = python ]; then
      echo "(affected: $(echo "$AFF_FILES" | wc -w | tr -d ' ') test files)"; a_test "$AFF_FILES"; return
    fi
    flt="FullyQualifiedName~$(echo "$AFF_CLASSES" | sed 's/ /|FullyQualifiedName~/g')"
    echo "(affected: $AFF_CLASSES)"
    # a test= command runs through sh, the | of the filter needs quotes there
    if [ -n "$CFG_test" ]; then a_test "'$flt'"; else a_test "$flt"; fi
    return
  fi
  if [ "$KIND" = none ] && [ -f "$PROJECT/tests/run.sh" ]; then shell_check; return; fi
  # With your own test= command warmd cannot know which files matter, so any change counts.
  if [ -n "$CFG_test" ]; then names="$(changed_names '.')"; else names="$(changed_names '\.(py|rs|go|cs)$')"; fi
  [ -n "$names" ] || { echo "OK no code changed against $(base_branch)"; return 0; }
  a_test
}

# Shell projects (warmd itself): tests/<name>.sh is the test of lib/<name>.sh and adapters/<name>.sh, tests/<dir>/ belongs
# to tests/<dir>.sh, docs to tests/docs.sh. The full suite (test= or tests/run.sh) runs only when bin/ or tests/run.sh changed,
# or a lib or adapter file has no test of its own: tests/run.sh is its test then.
shell_affected() { # sets SH_MODE (CLEAN, NONE, ALL) and SH_TESTS
  local f n t
  SH_MODE=NONE; SH_TESTS=""; SH_REASON=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "$SH_MODE" = NONE ] && SH_MODE=LIST
    t=""
    case "$f" in
      bin/*|tests/run.sh) SH_MODE=ALL; SH_REASON="$f changed"; return;;
      lib/*.sh|adapters/*.sh)
        n="${f##*/}"; n="${n%.sh}"
        [ -f "$PROJECT/tests/$n.sh" ] || { SH_MODE=ALL; SH_REASON="$f has no tests/$n.sh"; return; }
        t="$n";;
      tests/*.sh) n="${f#tests/}"; n="${n%.sh}"; case "$n" in */*) ;; *) t="$n";; esac;;
      tests/*/*) n="${f#tests/}"; n="${n%%/*}"; t="$n";;
      docs/*|README.md|CONTRIBUTING.md) t=docs;;
    esac
    [ -n "$t" ] && [ -f "$PROJECT/tests/$t.sh" ] && case " $SH_TESTS " in *" $t "*) ;; *) SH_TESTS="${SH_TESTS:+$SH_TESTS }$t";; esac
  done < <(changed_files)
  [ "$SH_MODE" = NONE ] && SH_MODE=CLEAN
  [ "$SH_MODE" = LIST ] && [ -z "$SH_TESTS" ] && SH_MODE=NONE
  return 0
}

shell_check() {
  shell_affected
  case "$SH_MODE" in
    CLEAN) echo "OK no code changed against $(base_branch)"; return 0;;
    NONE) echo "OK no test depends on this change"; return 0;;
    ALL) echo "(running all tests: $SH_REASON)"
      if [ -n "$CFG_test" ]; then a_test; else slot_take; cached "test|" run_bounded test in_project bash tests/run.sh; fi; return;;
  esac
  local t list=""; for t in $SH_TESTS; do list="${list:+$list }tests/$t.sh"; done
  echo "(affected: $list)"
  slot_take
  # every file runs, the exit code counts the red ones
  cached "test|sh:$SH_TESTS" run_bounded test in_project bash -c 'f=0; for t in "$@"; do bash "tests/$t.sh" || f=$((f+1)); done; exit $f' _ $SH_TESTS
}

a_shot() { echo "warmd shot needs a web, Unity or Godot project"; return 2; }
a_stop() { echo "OK nothing warm"; }
a_status() { :; }
a_call() { echo "warmd call is for engines"; return 2; }
a_seed() { :; }
a_has_cache() { return 0; }
a_package() { echo "warmd package is for Unity"; return 2; }
a_init() { :; }
a_doctor() {
  [ "$KIND" = none ] && echo "note: no known project type, set build= and test= in warmd.conf"
  return 0
}
