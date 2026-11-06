#!/usr/bin/env bash
# Real engine test: needs Godot 4.3 or newer in WARMD_GODOT or on PATH.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
TMP="$(mktemp -d)"
export XDG_CACHE_HOME="$TMP/cache"
cd "$TMP" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
printf 'config_version=5\n[application]\nconfig/name="t"\n' > project.godot
printf '.warmd\n.godot\n' > .gitignore
printf 'class_name Score\nextends RefCounted\n\nstatic func add(a: int, b: int) -> int:\n\treturn a + b\n' > score.gd
"$WARMD" init > /dev/null
mkdir test
printf 'extends WarmdTest\n\nfunc test_add() -> void:\n\tassert_eq(Score.add(2, 3), 5)\n' > test/test_score.gd
git add -A; git commit -qm init
fails=0
expect() { if echo "$3" | grep -qE "$2"; then echo "ok   $1"; else echo "FAIL $1: $3"; fails=$((fails+1)); fi; }
expect "compile" 'scripts parse' "$("$WARMD" build)"
expect "green test" '1 passed, 0 failed' "$("$WARMD" test)"
sed -i.bak 's/a + b/a - b/' score.gd; rm score.gd.bak
expect "an edit counts in one-shot mode" 'RED test_add' "$("$WARMD" test)"
git checkout -q score.gd
printf 'class_name Fresh\nextends RefCounted\n\nstatic func one() -> int:\n\treturn 1\n' > fresh.gd
printf 'extends WarmdTest\n\nfunc test_fresh() -> void:\n\tassert_eq(Fresh.one(), 1)\n' > test/test_fresh.gd
expect "a new class_name works without a manual restart" '2 passed, 0 failed' "$("$WARMD" test)"
rm fresh.gd test/test_fresh.gd
mkdir raw; touch raw/.gdignore; printf 'func broken(:\n' > raw/vendor.gd
expect "a .gdignore folder is skipped" 'scripts parse' "$("$WARMD" build)"
rm -rf raw
printf 'func broken(:\n' > bad.gd
expect "parse error is found" 'bad.gd does not parse' "$("$WARMD" build)"
rm bad.gd
echo 'warm=1' > warmd.conf
expect "warm mode" '1 passed, 0 failed' "$(WARMD_NOCACHE=1 "$WARMD" test)"
sed -i.bak 's/a + b/a - b/' score.gd; rm score.gd.bak
expect "an edit reaches the warm engine" 'RED test_add' "$("$WARMD" test)"
git checkout -q score.gd
# Two callers on one daemon: both get their own result, none overwrites the other's job
WARMD_NOCACHE=1 "$WARMD" test test_add > one.out 2>&1 &
p1=$!
WARMD_NOCACHE=1 "$WARMD" test test_add > two.out 2>&1 &
p2=$!
wait "$p1" "$p2"
expect "first of two parallel callers" '1 passed, 0 failed' "$(cat one.out)"
expect "second of two parallel callers" '1 passed, 0 failed' "$(cat two.out)"
rm -f one.out two.out
expect "stop" 'OK daemon stopped' "$("$WARMD" stop)"
# A project with its own SceneTree runners (tests/run_*.gd, quit(1) on failure) and no WarmdTest
R="$TMP/runners"; mkdir -p "$R/tests"; cd "$R" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
printf 'config_version=5
[application]
config/name="r"
' > project.godot
printf '.warmd
.godot
' > .gitignore
printf 'extends SceneTree

func _initialize() -> void:
	quit(0 if 2 + 3 == 5 else 1)
' > tests/run_math.gd
"$WARMD" init > /dev/null; git add -A; git commit -qm init
expect "own runners are found and run" 'OK .*test' "$(WARMD_NOCACHE=1 "$WARMD" test)"
sed -i.bak 's/== 5/== 6/' tests/run_math.gd; rm tests/run_math.gd.bak
expect "a failing runner is red" 'FAIL runner tests/run_math.gd' "$(WARMD_NOCACHE=1 "$WARMD" test)"
cd "$TMP" || exit 1
rm -rf "$TMP" 2>/dev/null
exit $fails
