#!/usr/bin/env bash
# A Godot worktree runs at once: split copies the git-ignored .import files and brings the class cache up to date (an
# import, once more after a crash), merge imports before a gate= script when the merge brings a class_name the cache
# lacks. A stub engine stands in for Godot.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
TMP="$(mktemp -d)"
export XDG_CACHE_HOME="$TMP/cache" WARMD_NO_PREWARM=1 WARMD_TRANSCRIPTS="$TMP/transcripts"
fails=0
expect() { if echo "$3" | grep -qE "$2"; then echo "ok   $1"; else echo "FAIL $1: wanted /$2/, got: $(echo "$3" | head -3)"; fails=$((fails+1)); fi; }

# Stub engine: --import writes the class cache from the scripts on disk, counts itself and rewrites project.godot like
# Godot does. While $S/crash_once exists the import ends like Godot 4.7's segfault: exit 139, no cache.
S="$TMP/engine"; mkdir -p "$S"
cat > "$S/godot" <<'STUB'
#!/usr/bin/env bash
S="$(dirname "$0")"; P=""; imp=0
while [ $# -gt 0 ]; do case "$1" in --path) P="$2"; shift;; --import) imp=1;; esac; shift; done
[ $imp = 1 ] || exit 0
echo x >> "$S/imports"; echo 'config/features=PackedStringArray("4.7")' >> "$P/project.godot"
[ -f "$S/crash_once" ] && { rm -f "$S/crash_once"; exit 139; }
mkdir -p "$P/.godot"
{ echo 'list=[{'; (cd "$P" && grep -r -m1 -H --include='*.gd' --exclude-dir='.?*' '^class_name ' .) | while IFS= read -r l; do r="${l#./}"; printf '"class": &"%s",\n"path": "res://%s"\n' "${l##*class_name }" "${r%%:*}"; done; echo '}]'; } > "$P/.godot/global_script_class_cache.cfg"
STUB
chmod +x "$S/godot"
export WARMD_GODOT="$S/godot"
imports() { [ -f "$S/imports" ] && grep -c . "$S/imports" || echo 0; }

mkdir -p "$TMP/game"; cd "$TMP/game" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com; git config core.autocrlf false
printf '[application]\nconfig/name="t"\n' > project.godot
printf '.warmd\n.godot/\n*.import\n' > .gitignore
mkdir -p art; echo png > art/a.png; printf '[remap]\nimporter="texture"\n' > art/a.png.import
printf 'class_name OldOne\nextends Node\n' > old.gd
git add -A; git commit -qm init
"$S/godot" --path "$PWD" --import; git checkout -q -- project.godot; rm -f "$S/imports"
# A class_name the base's cache does not know yet (it came after the last import here)
printf 'class_name NpcCoverFloor\nextends Node\n' > cover.gd; git add cover.gd; git commit -qm cover
wts="$(dirname "$PWD")/.warmd-worktrees/game"

# (1) a new worktree: .import copied, imported once more after the crash, project.godot as committed
touch "$S/crash_once"
printf 'tex | a goal | y | art/b.gd\n' > tasks.txt
out="$("$WARMD" split tasks.txt 2>&1)"
expect "split names what it did for the worktree" 'worktree tex: copied 1 ignored \.import files, imported: class cache current' "$out"
expect "the ignored .import file is in the worktree" 'importer="texture"' "$(cat "$wts/tex/art/a.png.import" 2>&1)"
expect "the class cache knows the new class_name" 'res://cover.gd' "$(cat "$wts/tex/.godot/global_script_class_cache.cfg" 2>&1)"
expect "a crashed import ran once more" '^2$' "$(imports)"
expect "project.godot is left as committed" '^$' "$(git -C "$wts/tex" status --porcelain -- project.godot)"
expect "the slot of the import is given back" '^0$' "$(find "$TMP/cache/warmd/slots" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"

# (2) a worktree whose cache is current is not imported again
"$WARMD" batch-done >/dev/null
"$S/godot" --path "$PWD" --import; git checkout -q -- project.godot; rm -f "$S/imports"
printf 'tex2 | a goal | y | art/c.gd\n' > tasks2.txt
out="$("$WARMD" split tasks2.txt 2>&1)"
expect "a current class cache costs no import" '^0$' "$(imports)"

# (3) merge: a branch brings a class_name the base's cache lacks, the gate= script runs after an import
"$WARMD" batch-done >/dev/null
"$S/godot" --path "$PWD" --import; git checkout -q -- project.godot; rm -f "$S/imports"
printf 'gate=grep -q CityBig .godot/global_script_class_cache.cfg\n' > warmd.conf; git add warmd.conf; git commit -qm gate
git checkout -qb warmd/city; printf 'class_name CityBig\nextends Node\n' > city.gd; git add city.gd; git commit -qm city; git checkout -q main
out="$("$WARMD" merge warmd/city 2>&1)"
expect "the merge imports for a new class_name and the gate is green" '^OK .*merged warmd/city' "$out"
expect "the merge says it imported" 'class_name new to the class cache: imported before the gate' "$out"
expect "project.godot stays as merged" '^$' "$(git status --porcelain -- project.godot)"
rm -f "$S/imports"
git checkout -qb warmd/plain; echo y > plain.txt; git add plain.txt; git commit -qm plain; git checkout -q main
out="$("$WARMD" merge warmd/plain 2>&1)"
expect "a merge without a new class_name costs no import" '^0$' "$(imports)"

cd "$HERE" || exit 1
rm -rf "$TMP" 2>/dev/null
echo; [ $fails = 0 ] && echo "godot_wt: all green" || echo "godot_wt: $fails failed"
exit $fails
