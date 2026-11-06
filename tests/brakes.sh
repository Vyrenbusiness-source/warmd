#!/usr/bin/env bash
# Batch brakes: split appends to a running batch, merged worktrees start from base, dead agents get reported once, agents= and floor=. No engine needed.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
TMP="$(mktemp -d)"
export XDG_CACHE_HOME="$TMP/cache" WARMD_NO_PREWARM=1 WARMD_TRANSCRIPTS="$TMP/transcripts"
unset WARMD_CORES WARMD_RAM_MB
fails=0
expect() { if echo "$3" | grep -qE "$2"; then echo "ok   $1"; else echo "FAIL $1: wanted /$2/, got: $(echo "$3" | head -3)"; fails=$((fails+1)); fi; }
mkdir -p "$TMP/app"; cd "$TMP/app" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
echo '{ "name": "t" }' > package.json; printf '.warmd\n' > .gitignore; printf 'agents=3\n' > warmd.conf
git add -A; git commit -qm init
common="$(git rev-parse --path-format=absolute --git-common-dir)"
wts="$(dirname "$PWD")/.warmd-worktrees/app"

# (1) a second split joins the running batch
printf 'a | first | y | src/a.ts\n' > one.txt
printf 'b | second | y | src/b.ts\n' > two.txt
"$WARMD" split one.txt > /dev/null
"$WARMD" note 'a fact from the first agent' > /dev/null
out="$("$WARMD" split two.txt)"
expect "a second split succeeds" 'OK 1 tasks split' "$out"
expect "the batch keeps the first worktree" '/a$' "$(cat "$common/warmd-batch")"
expect "the batch gains the second worktree" '/b$' "$(cat "$common/warmd-batch")"
expect "the brief keeps the first owner" '^- a: src/a.ts' "$(cat "$common/warmd-shared.md")"
expect "the brief adds the second owner" '^- b: src/b.ts' "$(cat "$common/warmd-shared.md")"
expect "the brief keeps its findings" 'a fact from the first agent' "$(cat "$common/warmd-shared.md")"
"$WARMD" split two.txt > /dev/null 2>&1
# A finished task with merged work leaves the batch at the next split; a finished task with work left stays for the merge.
printf 'z | old | y | src/z.ts\n' > old.txt; "$WARMD" split old.txt > /dev/null
printf '%s\tok\n' "$(cd "$wts/z" && pwd)" >> "$common/warmd-batch-done"
printf 'y | kept | y | src/y.ts\n' > kept.txt; "$WARMD" split kept.txt > /dev/null
(cd "$wts/y" && mkdir -p src && echo y > src/y.ts && git add -A && git commit -qm y)
printf '%s\tok\n' "$(cd "$wts/y" && pwd)" >> "$common/warmd-batch-done"
printf 'x | next | y | src/x.ts\n' > next.txt; "$WARMD" split next.txt > /dev/null
if grep -q '/z$' "$common/warmd-batch"; then echo "FAIL a finished, merged task stays in the batch"; fails=$((fails+1)); else echo "ok   a finished, merged task leaves the batch"; fi
expect "a finished task with unmerged work stays" '/y$' "$(cat "$common/warmd-batch")"
expect "a running task stays" '/a$' "$(cat "$common/warmd-batch")"
"$WARMD" batch-done > /dev/null; "$WARMD" split one.txt > /dev/null; "$WARMD" split two.txt > /dev/null
printf 'c | clash | y | src/a.ts\n' > clash.txt
expect "a file owned by the running batch is refused" 'GAP c: src/a.ts already owned' "$("$WARMD" split clash.txt)"

# (4) agents= caps the running tasks
printf 'c | third | y | src/c.ts\nd | fourth | y | src/d.ts\n' > more.txt
out="$("$WARMD" split more.txt)"
expect "split fills up to agents=" 'OK 1 tasks split, 1 waiting' "$out"
expect "the task over the cap waits" 'WAIT d: 3 of 3 agents run' "$out"
[ ! -d "$wts/d" ] && echo "ok   a waiting task gets no worktree" || { echo "FAIL a waiting task got a worktree"; fails=$((fails+1)); }
expect "a waiting task is not an owner" '^- c: src/c.ts' "$(cat "$common/warmd-shared.md")"
if grep -q '^- d:' "$common/warmd-shared.md"; then echo "FAIL a waiting task owns files"; fails=$((fails+1)); else echo "ok   a waiting task owns nothing"; fi
printf '%s\tok\n' "$(cd "$wts/c" && pwd)" >> "$common/warmd-batch-done"
printf 'd | fourth | y | src/d.ts\n' > last.txt
expect "a stopped agent frees its place" 'OK 1 tasks split\. Start' "$("$WARMD" split last.txt)"
"$WARMD" batch-done > /dev/null
: > warmd.conf
out="$(WARMD_CORES=1 WARMD_RAM_MB=65536 "$WARMD" split more.txt)"
expect "unset agents= follows the cores" 'WAIT d: 1 of 1' "$out"
"$WARMD" batch-done > /dev/null
out="$(WARMD_CORES=16 WARMD_RAM_MB=3000 "$WARMD" split more.txt)"
expect "unset agents= follows the RAM" 'WAIT d: 1 of 1' "$out"
"$WARMD" batch-done > /dev/null
expect "unset agents= gives room on a normal machine" 'OK 2 tasks split\. Start' "$(WARMD_CORES=8 WARMD_RAM_MB=32768 "$WARMD" split more.txt)"
"$WARMD" batch-done > /dev/null

# (4) floor= in split and escalate
printf 'floor=top\n' > warmd.conf
printf 'e | edit | y | src/e.ts\n' > floor.txt
expect "floor=top lifts split to the top model" 'AGENT e: subagent_type=warmd-worker model=opus' "$("$WARMD" split floor.txt)"
echo mid > .warmd/tasks/e.tier
expect "floor=top: escalate from below the floor still ends at top" 'needs a human' "$("$WARMD" escalate e)"
"$WARMD" batch-done > /dev/null
printf 'floor=mid\n' > warmd.conf
printf 's | look up | y | none\n' > scout.txt
expect "floor=mid lifts a scout to mid" 'AGENT s: .*model=sonnet' "$("$WARMD" split scout.txt)"
echo cheap > .warmd/tasks/s.tier
expect "floor=mid: escalate from cheap goes past mid" 'AGENT s: .*model=opus' "$("$WARMD" escalate s)"
"$WARMD" batch-done > /dev/null; : > warmd.conf

# (2) a reused worktree whose branch is merged starts from base
echo a > "$wts/a/a.ts"; git -C "$wts/a" add a.ts; git -C "$wts/a" commit -qm "a done"
git merge -q --no-ff -m "merge a" warmd/a; echo later > later.txt; git add later.txt; git commit -qm later
"$WARMD" split one.txt > /dev/null
expect "a merged branch is reset to base" "^$(git rev-parse HEAD)$" "$(git -C "$wts/a" rev-parse HEAD)"
echo open > "$wts/b/b.ts"; git -C "$wts/b" add b.ts; git -C "$wts/b" commit -qm "b open"
keep="$(git -C "$wts/b" rev-parse HEAD)"
"$WARMD" split two.txt > /dev/null
expect "an unmerged branch keeps its commits" "^$keep$" "$(git -C "$wts/b" rev-parse HEAD)"
"$WARMD" batch-done > /dev/null

# (3) watch reports an agent that died at start, once, with the reason
"$WARMD" split one.txt > /dev/null
mkdir -p "$WARMD_TRANSCRIPTS/p"
printf '{"type":"user","message":"Read C:/x/.warmd/tasks/a.md and do it."}\n{"type":"assistant","message":"API Error: 400 Your credit balance is too low to access the Anthropic API."}\n' > "$WARMD_TRANSCRIPTS/p/s1.jsonl"
out="$("$WARMD" watch --once)"; rc=$?
expect "watch reports the dead agent" 'DEAD a: died at start, no commit' "$out"
expect "the report names the reason" 'Reason: .*credit balance is too low' "$out"
[ "$rc" = 3 ] && echo "ok   a dead agent wakes the session" || { echo "FAIL dead agent exited $rc"; fails=$((fails+1)); }
expect "the dead agent is reported once" '^OK all worktrees moved' "$("$WARMD" watch --once)"
echo b > "$wts/b/b2.ts"; git -C "$wts/b" add b2.ts; git -C "$wts/b" commit -qm "b work"
printf '{"type":"user","message":"Read C:/x/.warmd/tasks/b.md"}\n{"message":"API Error: overloaded"}\n' > "$WARMD_TRANSCRIPTS/p/s2.jsonl"
"$WARMD" split two.txt > /dev/null
if "$WARMD" watch --once | grep -q 'DEAD b'; then echo "FAIL an agent with commits counts as dead"; fails=$((fails+1)); else echo "ok   an agent with commits is not dead"; fi
"$WARMD" batch-done > /dev/null

# (n) waiting starts no process: a queued run polls for hours, and under Git Bash every sleep is a new process that some
# Windows machines never give back (64 starts a second ate 40 GB in 40 minutes). Wait loops use nap, nap uses no program.
out="$(grep -nE '(^|[;{ ]|then |else |do )sleep [0-9."$]' "$HERE"/lib/core.sh "$HERE"/lib/daemon.sh "$HERE"/lib/tune.sh "$HERE"/lib/team.sh "$HERE"/lib/platform.sh "$HERE"/adapters/unity.sh "$HERE"/adapters/web.sh | grep -v 'sleep "\$1"$')"
expect "wait loops use nap, not sleep" '^$' "${out:-}"
out="$(bash -c '. "$1/lib/platform.sh"; nap_init || exit 9; t0=$SECONDS; PATH=/nonexistent; nap 1 || echo rc; nap 1; echo "waited $((SECONDS - t0))"' _ "$HERE" 2>&1)"
expect "nap waits without any program on PATH" '^waited [12]$' "$out"

# (q) a queued run judges the places with builtins: while every place has a live owner it starts no program
mkdir -p "$TMP/held/1" "$TMP/held/2" "$TMP/half/1"; echo $$ > "$TMP/held/1/pid"; echo $$ > "$TMP/held/2/pid"; echo $$ > "$TMP/half/1/pid"
out="$(bash -c '. "$1/lib/platform.sh"; . "$1/lib/core.sh" 2>/dev/null; . "$1/lib/tune.sh" 2>/dev/null; PATH=/nonexistent; for d in held half; do slot_maybe_free "$2/$d" 2 && echo "$d free" || echo "$d held"; done' _ "$HERE" "$TMP" 2>&1)"
expect "a queued run sees held places without starting a program" '^held held$' "$(echo "$out" | head -1)"
expect "a queued run sees a free place without starting a program" '^half free$' "$(echo "$out" | tail -1)"

rm -rf "$TMP"
[ "$fails" = 0 ] && echo "OK brakes" || { echo "FAIL brakes: $fails"; exit 1; }
