#!/usr/bin/env bash
# Affected tests: dependency graph per language. No engine needed.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FX="$HERE/tests/fixtures/affected"
WARMD="$HERE/bin/warmd"
TMP="$(mktemp -d)"
export XDG_CACHE_HOME="$TMP/cache" WARMD_SELECT=1   # selection under test, never the full-suite shortcut
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails+1)); }
expect() { if echo "$3" | grep -qE "$2"; then ok "$1"; else no "$1: wanted /$2/, got: $(echo "$3" | head -3)"; fi; }
refuse() { if echo "$3" | grep -qE "$2"; then no "$1: found /$2/ in: $(echo "$3" | head -3)"; else ok "$1"; fi; }

# fixture <lang> <name>: fresh committed repo in $TMP/<name>
fixture() {
  local d="$TMP/$2"; rm -rf "$d"; mkdir -p "$d"; cp -R "$FX/$1/." "$d/"
  ( cd "$d" && git init -q -b main . && git config core.autocrlf false && git config user.name t && git config user.email t@example.com && git add -A && git commit -qm init )
  echo "$d"
}
# sel <dir> <lang> [scope]: mode|files|reason|classes
sel() {
  ( cd "$1" && WARMD_HOME="$HERE" && . "$HERE/lib/platform.sh" && . "$HERE/lib/core.sh" && detect_project && . "$HERE/lib/affected.sh" \
    && affected_select "${@:2}" && echo "$AFF_MODE|$AFF_FILES|$AFF_REASON|$AFF_CLASSES" )
}

# ---- git noise: with core.autocrlf=true git warns on stderr about LF files, the selection must stay quiet ----
d="$(fixture js crlf)"; git -C "$d" config core.autocrlf true
echo '// edit' >> "$d/src/leaf.ts"
refuse "crlf: the git LF/CRLF warning does not leak" 'CRLF|warning:' "$(sel "$d" js 2>&1 >/dev/null)"
expect "crlf: the selection still works" '^SOME\|test/top\.test\.ts\|' "$(sel "$d" js 2>/dev/null)"

# ---- JS and TS ----
d="$(fixture js js)"
echo '// edit' >> "$d/src/leaf.ts"
expect "js: a transitive change selects the test that reaches it" '^SOME\|test/top\.test\.ts\|' "$(sel "$d" js)"
git -C "$d" checkout -q src/leaf.ts
echo '// edit' >> "$d/src/other.ts"
expect "js: the other change selects the other test" '^SOME\|test/other\.test\.ts\|' "$(sel "$d" js)"
git -C "$d" checkout -q src/other.ts
echo 'notes' > "$d/NOTES.md"
expect "js: docs only changes nothing" '^CLEAN' "$(sel "$d" js)"
rm "$d/NOTES.md"
echo '// edit' >> "$d/src/leaf.ts"
echo "export const lazy = (n: string) => import(n)" > "$d/test/dyn.test.ts"
out="$(sel "$d" js)"
expect "js: a dynamic import is always selected" 'dyn\.test\.ts' "$out"
expect "js: the dynamic import does not hide the real hit" 'top\.test\.ts' "$out"
refuse "js: an unrelated test stays out next to a dynamic one" 'other\.test' "$out"
rm "$d/test/dyn.test.ts"
echo "import x from '@/lib/x'" >> "$d/test/other.test.ts"
expect "js: an unresolved alias is selected" 'other\.test\.ts' "$(sel "$d" js)"
git -C "$d" checkout -q test/other.test.ts
git -C "$d" checkout -q src/leaf.ts
echo '{}' > "$d/package.json"
expect "js: a changed file nobody imports selects all" '^ALL\|\|package\.json' "$(sel "$d" js)"
git -C "$d" checkout -q package.json
git -C "$d" rm -q src/mid.ts
expect "js: a deleted source selects all" '^ALL\|\|src/mid\.ts' "$(sel "$d" js)"
git -C "$d" reset -q --hard
git -C "$d" mv test/top.test.ts test/top2.test.ts
echo '// edit' >> "$d/src/leaf.ts"
expect "js: a renamed test still runs under its new name" 'top2\.test\.ts' "$(sel "$d" js)"

# ---- through warmd check ----
d="$(fixture js jscheck)"
echo '// edit' >> "$d/src/leaf.ts"
out="$(cd "$d" && "$WARMD" check)"
expect "check: names the affected test count" 'affected: 1 test files' "$out"
expect "check: the runner got the affected file" 'top\.test\.ts' "$(cat "$d/ran.log" 2>/dev/null)"
refuse "check: the runner did not get the unrelated file" 'other\.test' "$(cat "$d/ran.log" 2>/dev/null)"
git -C "$d" checkout -q src/leaf.ts
out="$(cd "$d" && "$WARMD" check)"
expect "check: nothing changed, nothing to run" '^OK no code changed' "$out"

# ---- Python ----
d="$(fixture py py)"
echo '# edit' >> "$d/app/leaf.py"
expect "py: a transitive change selects the test" '^SOME\|tests/test_top\.py\|' "$(sel "$d" py)"
git -C "$d" checkout -q app/leaf.py
echo '# edit' >> "$d/other.py"
expect "py: the other module selects the other test" '^SOME\|tests/test_other\.py\|' "$(sel "$d" py)"
git -C "$d" checkout -q other.py
echo '# edit' >> "$d/app/leaf.py"
printf 'import importlib\n' >> "$d/tests/test_other.py"
out="$(sel "$d" py)"
expect "py: a dynamic import is always selected" 'test_other\.py' "$out"
expect "py: the dynamic import keeps the real hit" 'test_top\.py' "$out"
git -C "$d" checkout -q tests/test_other.py
: > "$d/conftest.py"
expect "py: conftest selects all" '^ALL\|\|conftest\.py' "$(sel "$d" py)"
rm "$d/conftest.py"
out="$(cd "$d" && "$WARMD" check)"
expect "py check: runner got the affected test only" 'affected: 1 test files' "$out"
refuse "py check: unrelated test stays out" 'test_other' "$(cat "$d/ran.log")"

# ---- C# ----
d="$(fixture cs cs)"
echo '// edit' >> "$d/src/Leaf.cs"
out="$(sel "$d" cs)"
expect "cs: a transitive change selects the test over its asmdef" '^SOME\|tests/A/TopTests\.cs\|\|TopTests$' "$out"
refuse "cs: a test in an assembly without the reference stays out" 'OtherTests' "$out"
git -C "$d" checkout -q src/Leaf.cs
find "$d" -name '*.asmdef' -delete
git -C "$d" add -A; git -C "$d" commit -qm noasm
echo '// edit' >> "$d/src/Leaf.cs"
out="$(sel "$d" cs)"
expect "cs: without asmdef the type match selects the test that mentions it" 'TopTests' "$out"
expect "cs: without asmdef a mention in a string counts too" 'OtherTests' "$out"
git -C "$d" checkout -q src/Leaf.cs
echo '// edit' >> "$d/src/Other.cs"
refuse "cs: an unrelated change leaves the top test out" 'TopTests' "$(sel "$d" cs)"
git -C "$d" checkout -q src/Other.cs
echo '// edit' >> "$d/src/Leaf.cs"
out="$(cd "$d" && "$WARMD" check)"
expect "cs check: filter holds the affected classes" 'affected: .*TopTests' "$out"

# ---- GDScript ----
d="$(fixture gd gd)"
echo '# edit' >> "$d/core/leaf.gd"
expect "gd: class_name and preload chain select the test" '^SOME\|test/test_top\.gd\|' "$(sel "$d" gd)"
git -C "$d" checkout -q core/leaf.gd
echo '# edit' >> "$d/core/other.gd"
expect "gd: the other script selects the other test" '^SOME\|test/test_other\.gd\|' "$(sel "$d" gd)"
git -C "$d" checkout -q core/other.gd
echo '# edit' >> "$d/core/leaf.gd"
printf 'func f(p):\n\treturn load(p)\n' >> "$d/test/test_other.gd"
out="$(sel "$d" gd)"
expect "gd: a dynamic load is always selected" 'test_other\.gd' "$out"
expect "gd: the dynamic load keeps the real hit" 'test_top\.gd' "$out"
git -C "$d" checkout -q test/test_other.gd
echo 'x' >> "$d/project.godot"
expect "gd: project settings select all" '^ALL\|\|project\.godot' "$(sel "$d" gd)"

# gd: runners tests/run_*.gd (extends SceneTree) are tests: a changed source selects the runner that loads it, a changed runner selects itself
d="$(fixture gd gdrun)"
mkdir -p "$d/tests"
printf 'extends SceneTree\n\nfunc _initialize() -> void:\n\tvar s = preload("res://core/leaf.gd")\n\tquit(0)\n' > "$d/tests/run_leaf_tests.gd"
printf 'extends SceneTree\n\nfunc _initialize() -> void:\n\tquit(0)\n' > "$d/tests/run_other_tests.gd"
git -C "$d" add -A; git -C "$d" commit -qm runners
echo '# edit' >> "$d/core/leaf.gd"
out="$(sel "$d" gd)"
expect "gd runner: a changed source selects the runner that loads it" 'tests/run_leaf_tests\.gd' "$out"
git -C "$d" checkout -q core/leaf.gd
printf 'extends SceneTree\n\nfunc _initialize() -> void:\n\tquit(0)\n# edit\n' > "$d/tests/run_other_tests.gd"
expect "gd runner: a changed runner selects itself" '^SOME\|tests/run_other_tests\.gd\|' "$(sel "$d" gd)"

rm -rf "$TMP" 2>/dev/null
echo
[ $fails = 0 ] && echo "affected: all green" || echo "affected: $fails failed"
exit $fails
