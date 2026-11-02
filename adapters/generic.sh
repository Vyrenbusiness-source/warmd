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
  local names hits
  names="$(changed_names '\.(py|rs|go|cs)$')"
  [ -n "$names" ] || { echo "OK no code changed against $(base_branch)"; return 0; }
  if [ "$KIND" = python ]; then
    hits="$(grep -rlE "\b($names)\b" "$PROJECT" --include='test_*.py' --include='*_test.py' --exclude-dir=.venv 2>/dev/null | sed "s#^$PROJECT/##" | paste -sd' ' -)"
    if [ -n "$hits" ]; then echo "(touched: $(echo "$hits" | wc -w | tr -d ' ') test files)"; a_test "$hits"; return; fi
  fi
  a_test
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
