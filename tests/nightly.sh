#!/usr/bin/env bash
# warmd nightly: fresh runs against the cache, the engine's load log against the static graph, mutation, morning report.
# The Godot part runs where an engine is found (WARMD_GODOT or on PATH): the CI job godot.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
TMP="$(mktemp -d)"
export XDG_CACHE_HOME="$TMP/cache"
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails+1)); }
expect() { if echo "$3" | grep -qE -- "$2"; then ok "$1"; else no "$1: wanted /$2/, got: $(echo "$3" | head -8)"; fi; }
refuse() { if echo "$3" | grep -qE -- "$2"; then no "$1: $(echo "$3" | grep -E -- "$2" | head -1)"; else ok "$1"; fi; }

mkdir -p "$TMP/app" && cd "$TMP/app" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
printf '.warmd\ncache\ncfg.txt\ncnt.txt\n' > .gitignore
mkdir tests
printf '#!/usr/bin/env bash\nbig() { [ "$1" -gt 10 ]; }\n' > calc.sh
# cfg.txt is git-ignored: the code key cannot see it, the perfect cache key error
cat > tests/t.sh <<'EOF'
. ./calc.sh
big 11 && ! big 10 || exit 1
c="$(cat cfg.txt 2>/dev/null)"
if [ "$c" = flip ]; then n=$(( $(cat cnt.txt 2>/dev/null || echo 0) + 1 )); echo "$n" > cnt.txt; [ $((n % 2)) = 0 ] || { echo "FAIL flip $n"; exit 1; }; fi
[ "$c" = bad ] && { echo "FAIL cfg is bad"; exit 1; }
exit 0
EOF
printf 'test=bash tests/t.sh\nmutate_cmd=bash tests/t.sh\n' > warmd.conf
echo ok > cfg.txt
git add -A; git commit -qm init

expect "the schedule is a printed one-liner, not installed" '^  cron: 0 3 \* \* \* cd .* && warmd nightly >> \.warmd/nightly\.log 2>&1$' "$("$WARMD" nightly --schedule)"
expect "the schedule says it installs nothing" 'not installed as a task by itself' "$("$WARMD" nightly --schedule)"
case "${OSTYPE:-}" in msys*|cygwin*) expect "Windows gets the schtasks line" '^  schtasks /Create /SC DAILY /ST 03:00 /TN ' "$("$WARMD" nightly --schedule)";; esac
expect "no report before the first night" '^no nightly run yet' "$("$WARMD" nightly --report)"

"$WARMD" test > /dev/null
out="$("$WARMD" nightly --no-mutate)"; rc=$?
expect "cached green and fresh green agree" '^cache: 1 compared, 0 mismatches$' "$out"
expect "the first line has the fresh verdicts" '^nightly [0-9-]+ [0-9:]+ [0-9a-f]+: build OK, tests OK \(fresh, no cache\)$' "$out"
expect "a project without Godot runners says so" '^graph: no load log \(Godot runners only\)$' "$out"
expect "mutate skipped on request" '^mutate: skipped \(--no-mutate\)$' "$out"
expect "no sim, no determinism check" '^determinism: no warmd sim here$' "$out"
[ $rc = 0 ] && ok "a clean night is exit 0" || no "a clean night gave exit $rc"
[ "$(wc -l < .warmd/nightly.txt | tr -d ' ')" = 5 ] && ok "the morning report is five lines" || no "nightly.txt has $(wc -l < .warmd/nightly.txt) lines"

# An input the key cannot see changes the result: the cache still says green, two fresh runs say red
echo bad > cfg.txt
out="$("$WARMD" nightly --no-mutate)"; rc=$?
expect "a wrong cache key is printed loudly" '^MISMATCH test: the cache says green, two fresh runs say red\. The cache key misses an input of test' "$out"
expect "the report counts it" '^cache: 1 compared, 1 mismatches \(cache key wrong: test\)$' "$out"
[ $rc = 1 ] && ok "a mismatch is exit 1" || no "a mismatch gave exit $rc"

# A test that changes its mind is flaky, not a key error: the second fresh run agrees with the cache
# The fresh red runs replaced the wrong green: a fresh green puts it back
echo ok > cfg.txt; WARMD_NOCACHE=1 "$WARMD" test > /dev/null; echo flip > cfg.txt; echo 0 > cnt.txt
out="$("$WARMD" nightly --no-mutate)"
expect "a flaky test is no mismatch" '^FLAKY test: the cache says green, the first fresh run differs, the second agrees' "$out"
expect "flaky is counted apart" '^cache: 1 compared, 0 mismatches, 1 flaky$' "$out"
echo ok > cfg.txt

expect "the numbers land in the quality file" '	nightly	[0-9a-f]+	1	0	0	1$' "$(tail -1 .git/warmd-quality.tsv)"
out="$("$WARMD" nightly --report)"
expect "report shows the last morning report" '^cache: 1 compared, 0 mismatches, 1 flaky$' "$out"
expect "report has the quality line" '^nightly cache mismatches: 0 last run, 1 in 3 runs \(target 0\)' "$out"

# Mutation on the lines since the last night: nothing new first, then a commit with an untested edge
out="$("$WARMD" nightly)"
expect "no commit since the last night, no mutation" '^mutate: no commit since the last nightly run$' "$out"
printf 'small() { [ "$1" -lt 3 ]; }\n' >> calc.sh; git commit -qam small
out="$("$WARMD" nightly)"
expect "a survivor of the night is listed" '^SURVIVED calc\.sh:3  -lt -> -le$' "$out"
expect "the night reports the score" '^mutate: score 0% \(0 of 1 killed, 1 survived\)$' "$out"
cmp -s calc.sh <(git show HEAD:calc.sh) && ok "the night restored calc.sh" || no "calc.sh differs after the night"

# The graph check without an engine: a load the static graph cannot reach is a gap, kept as an edge, found once
mkdir -p "$TMP/gd/tests" && cd "$TMP/gd" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
printf 'config_version=5\n[autoload]\nBoot="*res://boot.gd"\n' > project.godot
printf 'extends Node\n' > boot.gd
printf 'class_name A\nextends RefCounted\n' > a.gd
printf 'extends SceneTree\nconst H = preload("res://a.gd")\nfunc _init():\n\tquit(0)\n' > tests/run_x.gd
printf 'extends SceneTree\nfunc _init():\n\tvar s = load(name)\n\tquit(0)\n' > tests/run_dyn.gd
git add -A; git commit -qm init
printf 'Loading resource: res://tests/run_x.gd\nLoading resource: res://a.gd\nLoading resource: res://boot.gd\nLoading resource: res://.godot/x.res\n' > "$TMP/load.log"
gaps() { ( PROJECT="$TMP/gd"; WARMD_HOME="$HERE"; reg() { :; }; . "$HERE/lib/affected.sh"; . "$HERE/lib/mutate.sh"; . "$HERE/lib/nightly.sh"
  nightly_graph "$TMP/edges"; nightly_gaps "$TMP/edges" "$1" "$TMP/load.log"; echo "gaps $GAPS_NEW" ); }
out="$(gaps tests/run_x.gd)"
expect "an autoload the runner never names is a gap" '^GAP tests/run_x\.gd loads boot\.gd, the static graph has no path to it' "$out"
refuse "a preloaded script is in the graph" 'loads a\.gd' "$out"
expect "one gap" '^gaps 1$' "$out"
expect "the gap is kept as an extra edge" '^E	tests/run_x\.gd	boot\.gd$' "$(cat .git/warmd-edges.tsv)"
expect "the next night knows the edge" '^gaps 0$' "$(gaps tests/run_x.gd)"
expect "a runner with a dynamic load is always selected, no gap" '^gaps 0$' "$(gaps tests/run_dyn.gd)"

# ---- Godot: real engine, runners one engine each with --verbose ----
exe="${WARMD_GODOT:-$(command -v godot 2>/dev/null || command -v godot4 2>/dev/null)}"
if [ -n "$exe" ] && [ -x "$exe" ]; then
  mkdir -p "$TMP/g/tests" && cd "$TMP/g" || exit 1
  git init -q -b main .; git config user.name t; git config user.email t@example.com
  printf 'config_version=5\n[application]\nconfig/name="t"\n[autoload]\nBoot="*res://boot.gd"\n' > project.godot
  printf '.warmd\n.godot\ncache\n' > .gitignore
  printf 'extends Node\nvar ready_flag := 1\n' > boot.gd
  printf 'class_name Score\nextends RefCounted\n\nstatic func add(a: int, b: int) -> int:\n\treturn a + b\n' > score.gd
  printf 'extends SceneTree\n\nfunc _init() -> void:\n\tif Score.add(2, 3) != 5:\n\t\tquit(1)\n\t\treturn\n\tprint("ALL OK")\n\tquit(0)\n' > tests/run_a.gd
  printf 'extends SceneTree\n\nfunc _init() -> void:\n\tprint("ALL OK")\n\tquit(0)\n' > tests/run_b.gd
  git add -A; git commit -qm init
  "$WARMD" build > /dev/null; "$WARMD" build > /dev/null; git add -A; git commit -qm uid -q 2>/dev/null
  "$WARMD" build > /dev/null; "$WARMD" test > /dev/null
  out="$("$WARMD" nightly --no-mutate)"; rc=$?
  echo "$out" | sed 's/^/     | /'
  expect "godot: runners run one engine each" 'tests OK \(fresh, no cache, 2 runners one engine each\)$' "$out"
  expect "godot: the cache agrees with the fresh runs" '^cache: [12] compared, 0 mismatches' "$out"
  expect "godot: the engine's load log finds the autoload gap" '^GAP tests/run_a\.gd loads boot\.gd' "$out"
  expect "godot: the graph line counts runners and gaps" '^graph: 2 runners load-logged, [1-9][0-9]* gaps' "$out"
  [ $rc = 0 ] && ok "godot: a night with gaps but no mismatch is exit 0" || no "godot: exit $rc"
  out="$("$WARMD" nightly --no-mutate)"
  expect "godot: the second night knows the edges" '^graph: 2 runners load-logged, 0 gaps$' "$out"
  printf 'extends SceneTree\n\nfunc _init() -> void:\n\tquit(1)\n' > tests/run_b.gd
  out="$("$WARMD" nightly --no-mutate)"
  expect "godot: a red runner alone is named" '^FAIL runner tests/run_b\.gd in its own engine \(exit 1\)' "$out"
else
  echo "skip Godot part: no engine (WARMD_GODOT), the CI job godot runs it"
fi

cd / && rm -rf "$TMP"
[ $fails = 0 ] && echo "nightly: all ok" || echo "nightly: $fails failed"
exit $fails
