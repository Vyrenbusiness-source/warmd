#!/usr/bin/env bash
# warmd merge: parallel branches that each add an entry to a one-line list of project.godot (locale/translations,
# editor_plugins/enabled) are joined instead of stopping at the conflict. Any other conflict still stops. No engine.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
export XDG_CACHE_HOME="$TMP/cache"
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails+1)); }
merge() { WARMD_BASE=1 WARMD_BASE_BRANCH=main "$HERE/bin/warmd" merge --no-gate "$@" 2>&1; }

# repo <name> <translations> <plugins>: a Godot project with both lists in project.godot, committed on main
repo() {
  mkdir -p "$TMP/$1"; cd "$TMP/$1" || exit 1
  git init -q -b main .; git config user.name t; git config user.email t@example.com; git config core.autocrlf false
  printf '.warmd\n.godot\n' > .gitignore
  cat > project.godot <<EOF
config_version=5

[application]

config/name="T"

[editor_plugins]

enabled=PackedStringArray($3)

[internationalization]

locale/translations=PackedStringArray($2)
EOF
  git add -A; git commit -qm init
}
# branch <name> <sed expression on project.godot> [file to add]: a branch from main changing project.godot
branch() {
  git checkout -q -b "$1" main; sed -b -i "$2" project.godot
  [ -z "${3:-}" ] || echo x > "$3"
  git add -A; git commit -qm "$1"; git checkout -q main
}
tr_line() { grep '^locale/translations=' project.godot; }

# Two branches each append a translation: the second one conflicts with the first, joined in order, then committed
repo two '"res://a.po"' ''
branch warmd/de 's|"res://a.po")|"res://a.po", "res://de.po")|' de.po
branch warmd/fr 's|"res://a.po")|"res://a.po", "res://fr.po")|' fr.po
out="$(merge warmd/de warmd/fr)"; rc=$?
[ $rc = 0 ] && [ "$(tr_line)" = 'locale/translations=PackedStringArray("res://a.po", "res://de.po", "res://fr.po")' ] \
  && ! git rev-parse -q --verify MERGE_HEAD >/dev/null && [ -f fr.po ] && [ "$(git log -1 --format=%s)" = "Merge warmd/fr" ] \
  && [ "$(git rev-list --parents -1 HEAD | wc -w)" = 3 ] \
  && ok "two branches adding to locale/translations merge, HEAD order kept, new entry appended" || no "translations join rc=$rc: $out; $(tr_line)"
echo "$out" | grep -qx 'resolved project.godot list locale/translations: +1 entries' && ok "the join is reported in one line" || no "report line: $out"
! grep -q '^<<<<<<<\|^=======\|^>>>>>>>' project.godot && [ -z "$(git status --porcelain -uno)" ] && ok "no conflict markers and a clean tree after the join" || no "left: $(git status --porcelain -uno)"

# Both lists conflict at once, an entry the branch removed from the base stays out, an empty list joins too
repo both '"res://a.po", "res://old.po"' ''
branch warmd/x 's|"res://a.po", "res://old.po")|"res://a.po", "res://old.po", "res://x.po")|; s|enabled=PackedStringArray()|enabled=PackedStringArray("res://addons/x/plugin.cfg")|'
branch warmd/y 's|"res://a.po", "res://old.po")|"res://a.po", "res://y.po")|; s|enabled=PackedStringArray()|enabled=PackedStringArray("res://addons/y/plugin.cfg")|'
out="$(merge warmd/x warmd/y)"; rc=$?
[ $rc = 0 ] && [ "$(tr_line)" = 'locale/translations=PackedStringArray("res://a.po", "res://x.po", "res://y.po")' ] \
  && grep -qx 'enabled=PackedStringArray("res://addons/x/plugin.cfg", "res://addons/y/plugin.cfg")' project.godot \
  && ok "two lists joined in one merge, an entry removed by one side stays out" || no "two lists rc=$rc: $out; $(cat project.godot)"
[ "$(echo "$out" | grep -c '^resolved project.godot list ')" = 2 ] && ok "one report line per joined list" || no "report lines: $out"

# diff3 conflict style (a base section in the block) and CRLF line ends join the same way
repo crlf '"res://a.po"' ''
git config merge.conflictStyle diff3
sed -b -i 's/$/\r/' project.godot; git commit -qam crlf
branch warmd/c1 's|"res://a.po")|"res://a.po", "res://c1.po")|'
branch warmd/c2 's|"res://a.po")|"res://a.po", "res://c2.po")|'
out="$(merge warmd/c1 warmd/c2)"; rc=$?
# Counted with tr, not grep: grep of Git for Windows drops the CR before matching
[ $rc = 0 ] && tr -d '\r' < project.godot | grep -qx 'locale/translations=PackedStringArray("res://a.po", "res://c1.po", "res://c2.po")' \
  && [ "$(tr -cd '\r' < project.godot | wc -c)" = "$(wc -l < project.godot)" ] && ok "diff3 style and CRLF line ends join, line ends kept" || no "crlf rc=$rc: $out; $(cat -A project.godot | tail -2)"

# Any other conflict in project.godot stops as before: nothing joined, the merge stays open for warmd merge --continue
repo other '"res://a.po"' ''
branch warmd/n1 's|config/name="T"|config/name="One"|; s|"res://a.po")|"res://a.po", "res://n1.po")|'
branch warmd/n2 's|config/name="T"|config/name="Two"|; s|"res://a.po")|"res://a.po", "res://n2.po")|'
out="$(merge warmd/n1 warmd/n2)"; rc=$?
[ $rc = 1 ] && echo "$out" | grep -q 'FAIL conflict in 1 files of warmd/n2' && ! echo "$out" | grep -q '^resolved' \
  && git rev-parse -q --verify MERGE_HEAD >/dev/null && grep -q '^<<<<<<<' project.godot \
  && ok "a conflict in another line of project.godot still stops, nothing joined" || no "other line rc=$rc: $out"
git merge --abort 2>/dev/null; rm -f .warmd/merge.queue

# A list conflict next to a conflict in another file stops too
repo mixed '"res://a.po"' ''
echo base > notes.txt; git add notes.txt; git commit -qm notes
branch warmd/m1 's|"res://a.po")|"res://a.po", "res://m1.po")|'
git checkout -q warmd/m1; echo m1 > notes.txt; git commit -qam m1n; git checkout -q main
branch warmd/m2 's|"res://a.po")|"res://a.po", "res://m2.po")|'
git checkout -q warmd/m2; echo m2 > notes.txt; git commit -qam m2n; git checkout -q main
out="$(WARMD_MERGE_ATOMIC=1 merge warmd/m1 warmd/m2)"; rc=$?
[ $rc = 1 ] && echo "$out" | grep -q 'FAIL merge warmd/m2' && [ "$(git rev-parse HEAD)" = "$(git rev-parse main)" ] \
  && ! git rev-parse -q --verify MERGE_HEAD >/dev/null && [ "$(cat notes.txt)" = base ] \
  && ok "a list conflict next to a conflict in another file stops, the atomic merge rolls back" || no "mixed rc=$rc: $out"

# The atomic batch merge of the hooks takes the join too
repo atomic '"res://a.po"' ''
branch warmd/a1 's|"res://a.po")|"res://a.po", "res://a1.po")|'
branch warmd/a2 's|"res://a.po")|"res://a.po", "res://a2.po")|'
out="$(WARMD_MERGE_ATOMIC=1 merge warmd/a1 warmd/a2)"; rc=$?
[ $rc = 0 ] && [ "$(tr_line)" = 'locale/translations=PackedStringArray("res://a.po", "res://a1.po", "res://a2.po")' ] \
  && ok "the atomic batch merge joins the list instead of rolling back" || no "atomic rc=$rc: $out"

echo
[ $fails = 0 ] && echo "all green" || echo "$fails failed"
cd "$HERE" || exit 1; rm -rf "$TMP" 2>/dev/null
exit $fails
