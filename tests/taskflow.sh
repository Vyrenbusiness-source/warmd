#!/usr/bin/env bash
# The life of one task around the batch: split waits for a running merge and names its base commit. No engine needed.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
TMP="$(mktemp -d)"
export XDG_CACHE_HOME="$TMP/cache" WARMD_NO_PREWARM=1 WARMD_TRANSCRIPTS="$TMP/transcripts"
unset CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID
fails=0
expect() { if echo "$3" | grep -qE "$2"; then echo "ok   $1"; else echo "FAIL $1: wanted /$2/, got: $(echo "$3" | head -3)"; fails=$((fails+1)); fi; }
mkdir -p "$TMP/app"; cd "$TMP/app" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com; git config core.autocrlf false
echo '{ "name": "t" }' > package.json; printf '.warmd\n' > .gitignore
git add -A; git commit -qm init
mkdir -p .warmd

# (1) split during a merge waits for it: the worktree starts on the merged state, the task file names that commit
sleep 30 & m=$!
echo "$m" > .warmd/merge.owner
( sleep 3; echo b > b.txt; git add b.txt; git commit -qm "merged meanwhile"; kill $m ) &
printf 'mw | a goal | y | src/a.ts\n' > tasks.txt
out="$(WARMD_MERGE_POLL=1 "$WARMD" split tasks.txt 2>&1)"
wait
expect "split says it waits for the merge" 'a merge runs in this project, pid [0-9]+: split waits' "$out"
wt="$(dirname "$PWD")/.warmd-worktrees/app/mw"
expect "the worktree starts on the merged state" 'merged meanwhile' "$(git -C "$wt" log -1 --format=%s)"
expect "the task file names its base commit" "^Base: main at $(git rev-parse --short=9 main) merged meanwhile" "$(cat .warmd/tasks/mw.md)"
rm -f .warmd/merge.owner
"$WARMD" batch-done >/dev/null

cd "$HERE" || exit 1
rm -rf "$TMP" 2>/dev/null
echo; [ $fails = 0 ] && echo "taskflow: all green" || echo "taskflow: $fails failed"
exit $fails
