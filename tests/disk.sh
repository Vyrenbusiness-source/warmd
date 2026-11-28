#!/usr/bin/env bash
# warmd disk --free: merged worktrees without work of their own are removed, every other worktree outside the running
# batch gives its caches back (engine cache, ignored target/ node_modules/ dist/). No engine.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
TMP="$(mktemp -d)"
export XDG_CACHE_HOME="$TMP/cache" WARMD_BASE=1 WARMD_RECLAIM_IDLE_MIN=0
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails+1)); }
expect() { if echo "$3" | grep -qE "$2"; then ok "$1"; else no "$1: wanted /$2/, got: $(echo "$3" | head -3)"; fi; }

U="$TMP/u"; mkdir -p "$U/ProjectSettings" "$U/Assets"; cd "$U" || exit 1
printf 'm_EditorVersion: 6000.0.0f1\n' > ProjectSettings/ProjectVersion.txt
git init -q -b main .; git config core.autocrlf false; git config user.name t; git config user.email t@example.com
printf '.warmd\nLibrary\ntarget/\n' > .gitignore; git add -A; git commit -qm init
common="$(git rev-parse --path-format=absolute --git-common-dir)"
wt() { git worktree add -q -b "warmd/$1" "$TMP/w-$1"; }
work() { (cd "$TMP/w-$1" && echo "$1" > "$1.txt" && git add "$1.txt" && git commit -qm "$1"); }
merged() { work "$1"; git merge -q --no-ff -m "Merge warmd/$1" "warmd/$1"; }
wt done; merged done
wt gen; merged gen; touch "$TMP/w-gen/hero.gd.uid" "$TMP/w-gen/override.cfg"            # only files the engine writes
wt dirty; merged dirty; echo mine > "$TMP/w-dirty/notes.txt"                             # an own file, never committed
wt open; work open; mkdir -p "$TMP/w-open/app/target" "$TMP/w-open/dist"; echo x > "$TMP/w-open/app/target/big"
(cd "$TMP/w-open" && echo js > dist/a.js && git add dist && git commit -qm dist)          # dist/ tracked here: no cache
wt batch; merged batch; (cd "$TMP/w-batch" && pwd) > "$common/warmd-batch"
wt locked; merged locked; git worktree lock "$TMP/w-locked"
wt recent; merged recent                                                               # merged a minute ago, its agent may go on
wt fresh
for w in done gen dirty open batch locked recent fresh; do mkdir -p "$TMP/w-$w/Library"; echo x > "$TMP/w-$w/Library/ArtifactDB"; done
for w in fresh recent; do touch -d "+10 min" "$common/worktrees/w-$w/logs/HEAD"; done              # someone just checked out or committed

expect "warmd disk still lists what a merge would free" 'note: 5 finished worktrees hold a Library' "$("$WARMD" disk 2>&1)"
out="$("$WARMD" disk --free 2>&1)"
expect "disk --free names removed and freed worktrees and the GB" '^OK removed 2 merged worktrees, freed the caches of 3 others: [0-9]+\.[0-9] GB freed, [0-9]+\.[0-9] GB free$' "$out"
[ ! -e "$TMP/w-done" ] && [ ! -e "$TMP/w-gen" ] && ok "merged worktrees without own work are removed, generated files are no work" || no "not removed: $(ls "$TMP")"
git worktree list | grep -q 'w-done' && no "git still lists w-done" || ok "git forgets the removed worktree"
[ -f "$TMP/w-dirty/notes.txt" ] && [ ! -e "$TMP/w-dirty/Library" ] && ok "a merged worktree with an own file stays, its Library goes" || no "dirty: $(ls -A "$TMP/w-dirty")"
[ -d "$TMP/w-open" ] && [ ! -e "$TMP/w-open/Library" ] && [ ! -e "$TMP/w-open/app/target" ] && ok "an unmerged worktree gives Library and the ignored target/ back" || no "open: $(ls -A "$TMP/w-open" "$TMP/w-open/app" 2>&1)"
[ -f "$TMP/w-open/dist/a.js" ] && ok "a tracked dist/ is no cache" || no "tracked dist/ deleted"
[ -d "$TMP/w-recent" ] && [ ! -e "$TMP/w-recent/Library" ] && ok "a worktree merged a minute ago stays, its Library goes" || no "recent: $(ls -A "$TMP/w-recent" 2>&1)"
[ -d "$TMP/w-batch/Library" ] && [ -d "$TMP/w-locked/Library" ] && [ -d "$TMP/w-fresh/Library" ] && ok "the running batch, a locked and a just used worktree keep everything" || no "batch/locked/fresh touched"
out="$("$WARMD" disk --free 2>&1)"
expect "a second run finds nothing left" '^OK removed 0 merged worktrees, freed the caches of 0 others' "$out"

rm -f "$common/warmd-batch"; git worktree unlock "$TMP/w-locked"
cd "$HERE" || exit 1
rm -rf "$TMP" 2>/dev/null
echo; [ $fails = 0 ] && echo "disk: all green" || echo "disk: $fails failed"
exit $fails
