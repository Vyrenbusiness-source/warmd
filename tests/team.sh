#!/usr/bin/env bash
# warmd watch: what counts as an active agent. No network, gh is a stub on PATH.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
export XDG_CACHE_HOME="$TMP/cache"
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails+1)); }

W="$TMP/wt"; mkdir -p "$W/.warmd"; cd "$W" || exit 1
git init -q -b warmd/ci .; git config user.name t; git config user.email t@example.com
echo a > a.txt; git add a.txt; git commit -qm init
# busy <worktree>: wt_busy from lib/team.sh, in a fresh shell like warmd watch
busy() { ( cd "$TMP" && WARMD_HOME="$HERE" && WARMD_PROCS_TTL=-1 && . "$HERE/lib/platform.sh" && . "$HERE/lib/core.sh" && detect_project >/dev/null 2>&1; . "$HERE/lib/team.sh"; wt_busy "$1" ); }

# Stub gh: a watch sleeps, the lists name PR 7 and run 4242 as this branch's
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "run watch"|"pr checks") for _ in $(seq 60); do sleep 1; done;;   # short sleeps: a kill ends it within a second
  "pr list") echo 7;;
  "run list") echo 4242;;
esac
GH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

busy "$W" && no "an idle worktree counts as busy" || ok "an idle worktree is idle"

gh run watch 4242 > /dev/null & g=$!; sleep 2
busy "$W" && ok "gh run watch for a run of the branch counts as active" || no "gh run watch of the branch's run not seen"
kill $g 2>/dev/null; wait $g 2>/dev/null
gh pr checks 7 --watch > /dev/null & g=$!; sleep 2
busy "$W" && ok "gh pr checks --watch for the branch's PR counts as active" || no "gh pr checks --watch of the branch's PR not seen"
kill $g 2>/dev/null; wait $g 2>/dev/null
gh pr checks warmd/ci --watch > /dev/null & g=$!; sleep 2
busy "$W" && ok "gh pr checks --watch naming the branch counts as active" || no "gh pr checks --watch naming the branch not seen"
kill $g 2>/dev/null; wait $g 2>/dev/null
gh run watch 999 > /dev/null & g=$!; sleep 2
busy "$W" && no "a watch on another branch's run counts as active" || ok "a watch on another branch's run does not count"
kill $g 2>/dev/null; wait $g 2>/dev/null

# warmd ci polls instead of gh run watch: its .warmd/ci.wait marker with a live pid is work, and watch gets an ETA line
eta() { ( cd "$TMP" && WARMD_HOME="$HERE" && . "$HERE/lib/platform.sh" && . "$HERE/lib/core.sh" && detect_project >/dev/null 2>&1; . "$HERE/lib/team.sh"; wt_ci_eta "$1" ); }
sleep 30 & s=$!
echo "$s 4242 $(( $(date +%s) - 125 )) 600" > "$W/.warmd/ci.wait"
busy "$W" && ok "a polling CI wait counts as active" || no "a polling CI wait counted as idle"
out="$(eta "$W")"
case "$out" in "run 4242, 2 min in, about 8 min left") ok "watch line names run, minutes and ETA";; *) no "ETA line: $out";; esac
kill $s 2>/dev/null; wait $s 2>/dev/null
busy "$W" && no "a dead CI wait still counts as active" || ok "a dead CI wait is idle"
eta "$W" >/dev/null && no "a dead CI wait still gets an ETA line" || ok "no ETA line for a dead CI wait"
rm -f "$W/.warmd/ci.wait"

# warmd watch: an agent that stopped its turn while its own warmd run goes on still counts as working, the watch does not end
R="$TMP/repo"; mkdir -p "$R"; cd "$R" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com; printf '.warmd\n' > .gitignore; git add -A; git commit -qm init
for n in menu tempo; do git worktree add -q -b "warmd/$n" "$TMP/$n"; done
C="$(git rev-parse --path-format=absolute --git-common-dir)"
printf '%s\n%s\n' "$(cd "$TMP/menu" && pwd)" "$(cd "$TMP/tempo" && pwd)" > "$C/warmd-batch"
printf '%s\tok\n' "$(cd "$TMP/tempo" && pwd)" > "$C/warmd-batch-done"
mkdir -p "$C/warmd-auto/paused"; : > "$C/warmd-auto/paused/menu"; : > "$C/warmd-auto/paused/tempo"
sleep 30 & s=$!; mkdir -p "$TMP/tempo/.warmd/run/active"; echo "- test" > "$TMP/tempo/.warmd/run/active/$s"
out="$(cd "$R" && "$HERE/bin/warmd" watch --once 5 2>&1)"
case "$out" in "OK all worktrees moved in the last 5 minutes, paused: menu") ok "a stopped agent whose warmd test still runs keeps the watch going";; *) no "watch with a background run: $out";; esac
kill $s 2>/dev/null; wait $s 2>/dev/null
out="$(cd "$R" && "$HERE/bin/warmd" watch --once 5 2>&1)"
case "$out" in "OK no agent runs, paused: menu") ok "once the run is over the stopped agent is done again";; *) no "watch after the run: $out";; esac
cd "$TMP" || exit 1

# Merge job launched through Win32_Process.Create: the msys pid in merge.owner is unknown here, the Windows pid lives
if [ -d /proc ] && sleep 30 & s=$! && [ -r "/proc/$s/winpid" ]; then
  echo 999999 > "$W/.warmd/merge.owner"; cat "/proc/$s/winpid" > "$W/.warmd/merge.owner.win"
  busy "$W" && ok "a merge job is alive by its Windows pid" || no "merge job with live Windows pid counted as dead"
  kill $s 2>/dev/null; wait $s 2>/dev/null
  busy "$W" && no "a finished merge job still counts as alive" || ok "a finished merge job is dead"
  rm -f "$W/.warmd/merge.owner"*
else
  kill "${s:-0}" 2>/dev/null; ok "Windows pid check skipped, no msys /proc/<pid>/winpid here"
fi

# warmd watch keeps a long batch alive: past 240 minutes the marker stays while agents work, its mtime stays the batch start
A="$TMP/alive"; mkdir -p "$A"; cd "$A" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com; printf '.warmd\n' > .gitignore; git add -A; git commit -qm init
git worktree add -q -b warmd/long "$TMP/long"; echo x > "$TMP/long/work.txt"
AC="$(git rev-parse --path-format=absolute --git-common-dir)"
( cd "$TMP/long" && pwd ) > "$AC/warmd-batch"; touch -d "-5 hours" "$AC/warmd-batch"; before="$(date -r "$AC/warmd-batch" +%s)"
out="$(cd "$A" && "$HERE/bin/warmd" watch --once 5 2>&1)"
[ -f "$AC/warmd-batch-alive" ] && [ "$(date -r "$AC/warmd-batch" +%s)" = "$before" ] && ok "watch with a working agent marks the batch alive, the marker's batch start stays" || no "alive mark: $out"
out="$(cd "$A" && "$HERE/bin/warmd" build 2>&1)"
[ -f "$AC/warmd-batch" ] && echo "$out" | grep -q '^FAIL a batch runs' && ok "a marker older than 240 minutes stays while watch sees agents work" || no "old marker dropped: $out"
touch -d "-5 hours" "$AC/warmd-batch-alive"
(cd "$A" && "$HERE/bin/warmd" build >/dev/null 2>&1)
[ ! -f "$AC/warmd-batch" ] && [ ! -f "$AC/warmd-batch-alive" ] && ok "without work for 240 minutes the marker is stale again" || no "stale marker kept"
cd "$TMP" || exit 1

# A worktree handed to a new task forgets the "finished" line of its previous task, or the next split hands it out twice
D="$TMP/donecase"; mkdir -p "$D/a" "$D/b"
printf '%s\tok\n%s\tok\n' "$(cd "$D/a" && pwd)" "$(cd "$D/b" && pwd)" > "$D/warmd-batch-done"
( cd "$TMP" && WARMD_HOME="$HERE" && . "$HERE/lib/platform.sh" && . "$HERE/lib/core.sh" && detect_project >/dev/null 2>&1; . "$HERE/lib/team.sh"; batch_done_forget "$D" "$D/a" )
if ! grep -q "/donecase/a" "$D/warmd-batch-done" && grep -q "/donecase/b" "$D/warmd-batch-done"; then ok "a reused worktree is no longer marked finished"; else no "batch_done_forget: $(cat "$D/warmd-batch-done")"; fi

# A new batch drops the queued lines of the batch before it (a stale ESCALATE stopped the first watch with exit 4)
F="$TMP/freshcase"; mkdir -p "$F/warmd-auto"
echo "ESCALATE old: failed at the top tier" > "$F/warmd-auto/queue"; echo x > "$F/warmd-batch-done"; echo y > "$F/warmd-batch"
( cd "$TMP" && WARMD_HOME="$HERE" && . "$HERE/lib/platform.sh" && . "$HERE/lib/core.sh" && detect_project >/dev/null 2>&1; . "$HERE/lib/team.sh"; batch_fresh "$F" )
if [ ! -e "$F/warmd-auto/queue" ] && [ ! -e "$F/warmd-batch-done" ] && [ -f "$F/warmd-batch" ] && [ ! -s "$F/warmd-batch" ]; then ok "a new batch starts without old queue lines"; else no "batch_fresh left: $(ls "$F" "$F/warmd-auto")"; fi

# A finished task frees its files: a paused task must not block the next split on the same files
O="$TMP/ownrepo"; mkdir -p "$O"; ( cd "$O" && git init -q -b main . && git config user.name t && git config user.email t@example.com && echo a > a && git add a && git commit -qm i && git worktree add -q -b warmd/paused "$TMP/own-paused" && git worktree add -q -b warmd/busy "$TMP/own-busy" )
OC="$(git -C "$O" rev-parse --path-format=absolute --git-common-dir)"
printf '%s
%s
' "$(cd "$TMP/own-paused" && pwd)" "$(cd "$TMP/own-busy" && pwd)" > "$OC/warmd-batch"
printf '%s	ok	warmd/paused
' "$(cd "$TMP/own-paused" && pwd)" > "$OC/warmd-batch-done"
printf '## Who owns what
- paused: song.gd
- busy: lobby.gd
## Findings
' > "$OC/warmd-shared.md"
own="$( cd "$O" && WARMD_HOME="$HERE" && . "$HERE/lib/platform.sh" && . "$HERE/lib/core.sh" && detect_project >/dev/null 2>&1; . "$HERE/lib/team.sh"; shared_owned )"
case "$own" in *"lobby.gd@busy"*) case "$own" in *"song.gd@paused"*) no "finished task still owns its files: $own";; *) ok "a finished task frees its files";; esac;; *) no "running task lost its files: $own";; esac

# A goal may contain "|" itself: name first, files last, done check before it, the goal keeps the rest
out="$( ( cd "$TMP" && WARMD_HOME="$HERE" && . "$HERE/lib/platform.sh" && . "$HERE/lib/core.sh" && detect_project >/dev/null 2>&1; . "$HERE/lib/team.sh"; task_fields "t | keep |x| <= 49 | it works | a.gd, b.gd"; printf '%s;%s;%s' "$goal" "$check" "$files" ) )"
case "$out" in *"keep |x| <= 49"*";"*"it works"*";"*"a.gd, b.gd"*) ok "a pipe inside the goal stays in the goal";; *) no "task_fields: $out";; esac

# A reused worktree holds a new task while the done file still has the line of its previous one (other branch):
# it stays in the batch, the stale line goes, and the automatic merge does not count it as done and end the batch
P="$TMP/prunecase"; mkdir -p "$P"; ( cd "$P" && git init -q -b main . && git config user.name t && git config user.email t@example.com && printf '.warmd\n' > .gitignore && echo a > a && git add -A && git commit -qm i \
  && git worktree add -q -b warmd/orbit-bahnen "$TMP/audio-map" && git worktree add -q -b warmd/other "$TMP/other-wt" && (cd "$TMP/other-wt" && echo o > o && git add o && git commit -qm o) )
PC="$(git -C "$P" rev-parse --path-format=absolute --git-common-dir)"; PA="$(cd "$TMP/audio-map" && pwd)"; PO="$(cd "$TMP/other-wt" && pwd)"
printf '%s\n%s\n' "$PA" "$PO" > "$PC/warmd-batch"
printf '%s\tok\twarmd/orbit-career\n%s\tok\twarmd/other\n' "$PA" "$PO" > "$PC/warmd-batch-done"
(cd "$P" && "$HERE/bin/warmd" hook-merge >/dev/null 2>&1)
[ "$(cat "$PC/warmd-batch" 2>/dev/null)" = "$(printf '%s\n%s' "$PA" "$PO")" ] && [ ! -f "$PC/warmd-automerge.log" ] && ok "a stale finished line of a reused worktree does not end the batch" || no "hook-merge with a stale line: marker $(cat "$PC/warmd-batch" 2>/dev/null), log $(cat "$PC/warmd-automerge.log" 2>/dev/null | tail -2)"
run="$( cd "$P" && WARMD_HOME="$HERE" && . "$HERE/lib/platform.sh" && . "$HERE/lib/core.sh" && detect_project >/dev/null 2>&1; . "$HERE/lib/team.sh"; team_running "$PC/warmd-batch"; batch_prune "$PC" )"
[ "$run" = 1 ] && ok "the new task of a reused worktree counts as running" || no "team_running with a stale line: $run"
grep -qxF "$PA" "$PC/warmd-batch" && ok "prune keeps a reused worktree that holds a new task" || no "prune dropped the running worktree: $(cat "$PC/warmd-batch")"
! grep -qF "$PA	" "$PC/warmd-batch-done" && grep -qF "$PO	" "$PC/warmd-batch-done" && ok "prune drops the stale finished line, keeps the valid one" || no "done file after prune: $(cat "$PC/warmd-batch-done")"

# warmd batch-resume takes the tasks of the latest batch only: an old worktree with unmerged commits stays out,
# one whose agent transcript moved recently comes in
B="$TMP/resumecase"; mkdir -p "$B" "$TMP/transcripts"; cd "$B" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
echo '{ "name": "t", "scripts": { "test": "true" } }' > package.json; printf '.warmd\n' > .gitignore; git add -A; git commit -qm init
printf 'old | old work | o | old.txt\ntalk | talk work | t | talk.txt\n' > "$TMP/old.txt"
WARMD_NO_PREWARM=1 "$HERE/bin/warmd" split "$TMP/old.txt" > /dev/null 2>&1
BW="$(dirname "$B")/.warmd-worktrees/resumecase"
for n in old talk; do (cd "$BW/$n" && echo "$n" > "$n.txt" && git add -A && git commit -qm "$n"); done
"$HERE/bin/warmd" batch-done > /dev/null 2>&1
touch -d "-2 days" .warmd/tasks/old.md .warmd/tasks/talk.md
printf 'cur | current work | c | cur.txt\n' > "$TMP/cur.txt"
WARMD_NO_PREWARM=1 "$HERE/bin/warmd" split "$TMP/cur.txt" > /dev/null 2>&1
echo c > "$BW/cur/cur.txt"
printf '{"type":"user","text":"Read C:\\\\x\\\\.warmd\\\\tasks\\\\talk.md and do it."}\n' > "$TMP/transcripts/t.jsonl"
rm -f "$(git rev-parse --path-format=absolute --git-common-dir)/warmd-batch"
out="$(WARMD_TRANSCRIPTS="$TMP/transcripts" "$HERE/bin/warmd" batch-resume 2>&1)"
case "$out" in "OK batch marker rebuilt: 2 open: talk cur"|"OK batch marker rebuilt: 2 open: cur talk") ok "batch-resume takes the latest batch and a recently active task, not an old worktree";; *) no "batch-resume picked: $out";; esac
cd "$TMP" || exit 1

# warmd merge: untracked Godot byproducts (.uid/.import) the branch tracks are cleared, any other untracked file blocks and is named
MG="$TMP/mg"; mkdir -p "$MG"; cd "$MG" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
echo a > a.txt; git add a.txt; git commit -qm init
git checkout -q -b warmd/imp; mkdir -p tests; echo 'uid://x' > tests/t.gd.uid; echo imp > tests/t.import; echo n > new.txt
git add -A; git commit -qm imp; git checkout -q main
echo 'uid://local' > tests/t.gd.uid 2>/dev/null || { mkdir -p tests; echo 'uid://local' > tests/t.gd.uid; }; echo local > tests/t.import
out="$(WARMD_BASE=1 WARMD_BASE_BRANCH=main "$HERE/bin/warmd" merge --no-gate warmd/imp 2>&1)"; rc=$?
[ $rc = 0 ] && [ "$(cat tests/t.gd.uid)" = 'uid://x' ] && [ -f new.txt ] && ok "untracked .uid/.import the branch tracks do not block the merge" || no "byproduct merge rc=$rc: $out"
git reset -q --hard HEAD~1 2>/dev/null; git reset -q --hard main 2>/dev/null
git checkout -q -b warmd/oth main; echo b > other.txt; git add other.txt; git commit -qm oth; git checkout -q main
git reset -q --hard "$(git merge-base main warmd/oth)"; echo mine > other.txt
out="$(WARMD_BASE=1 WARMD_BASE_BRANCH=main "$HERE/bin/warmd" merge --no-gate warmd/oth 2>&1)"; rc=$?
[ $rc != 0 ] && [ "$(cat other.txt)" = mine ] && echo "$out" | grep -q 'other.txt' && ok "another untracked file still blocks, FAIL line names it" || no "other file: rc=$rc $out"
cd "$TMP" || exit 1

# warmd merge: a change made in the checkout while the gate runs is not taken into the merge commit (a .uid the gate wrote is)
MF="$TMP/mf"; mkdir -p "$MF"; cd "$MF" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
echo a > a.txt; echo orig > foreign.txt; git add -A; git commit -qm init
git checkout -q -b warmd/f; echo f > f.txt; git add f.txt; git commit -qm f; git checkout -q main
printf 'gate=sh gate.sh\n' > warmd.conf; printf 'echo edited > foreign.txt\n' > gate.sh; git add warmd.conf gate.sh; git commit -qm conf
out="$(WARMD_BASE=1 WARMD_BASE_BRANCH=main "$HERE/bin/warmd" merge warmd/f 2>&1)"; rc=$?
[ $rc = 0 ] && ! git show --stat --format= HEAD | grep -q foreign.txt && [ "$(cat foreign.txt)" = edited ] && echo "$out" | grep -q 'WARN.*foreign.txt' && ok "an edit made during the gate stays out of the merge commit and is named" || no "foreign edit: rc=$rc $out; $(git show --stat --format= HEAD)"
cd "$TMP" || exit 1

# Studio rules (Godot plan section 5 and 7)
S="$TMP/studio"; mkdir -p "$S/scenes" "$S/scripts"; cd "$S" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
printf '[application]\nconfig/name="s"\n' > project.godot
printf '[gd_scene format=3]\n[ext_resource type="Script" path="res://scripts/player.gd" id="1"]\n[node name="P" type="Node2D"]\nscript = ExtResource("1")\n' > scenes/level.tscn
printf '[gd_scene format=3]\n[node name="M" type="Control"]\n' > scenes/menu.tscn
echo 'extends Node2D' > scripts/player.gd; echo 'extends Node' > scripts/enemy.gd
printf '.warmd\n' > .gitignore; git add -A; git commit -qm init
printf 'a | move the player | y | scripts/player.gd\nb | redo the level | y | scenes/level.tscn\nc | menu | y | scenes/menu.tscn\n' > "$TMP/scn.txt"
out="$(WARMD_NO_PREWARM=1 "$HERE/bin/warmd" split "$TMP/scn.txt" 2>&1)"
echo "$out" | grep -q '^WAIT b: scene scenes/level.tscn is held by a' && ok "two tasks on one scene never run in parallel: the script's scene holds it" || no "scene wait: $out"
echo "$out" | grep -q '^WAIT b: .*(warmd merge warmd/a) or dropped (warmd drop a)$' && ok "the scene WAIT line names the way out" || no "scene wait way out: $out"
# a parked holder: its agent finished and nothing moved for scene_rest_hours, the scene is free
out0="$out"SC="$(git rev-parse --path-format=absolute --git-common-dir)"; AW="$(sed -n 1p "$SC/warmd-batch")"
printf '%s\tok\twarmd/a\n' "$AW" >> "$SC/warmd-batch-done"
printf 'b | redo the level | y | scenes/level.tscn\n' > "$TMP/scn2.txt"
out="$(WARMD_NO_PREWARM=1 "$HERE/bin/warmd" split "$TMP/scn2.txt" 2>&1)"
echo "$out" | grep -q '^WAIT b: scene' && ok "a finished holder that moved lately still holds its scene" || no "fresh parked holder freed the scene: $out"
printf 'scene_rest_hours=0\n' > warmd.conf; out="$(WARMD_NO_PREWARM=1 "$HERE/bin/warmd" split "$TMP/scn2.txt" 2>&1)"; : > warmd.conf
echo "$out" | grep -q '^WAIT b: scene' && ok "scene_rest_hours=0: a parked holder holds until merge or drop" || no "rest 0: $out"
GIT_COMMITTER_DATE="$(date -d '-5 hours' '+%F %T')" git -C "$AW" commit -q --amend --no-edit --date="$(date -d '-5 hours' '+%F %T')"
out="$(WARMD_NO_PREWARM=1 "$HERE/bin/warmd" split "$TMP/scn2.txt" 2>&1)"
echo "$out" | grep -q '^AGENT b:' && ok "a holder parked for 4 hours holds no scene" || no "parked holder still holds: $out"
out="$out0"
echo "$out" | grep -q '^AGENT c:' && ok "a task on another scene runs in parallel" || no "other scene: $out"
grep -q '^Review: .*reviewer agent on opus. Never sonnet (the author)' .warmd/tasks/a.md && ok "the reviewer model is never the author model" || no "review line: $(grep Review .warmd/tasks/a.md)"
grep -q '^Time budget: 60 min' .warmd/tasks/a.md && ok "the task file states its time budget" || no "time budget line: $(cat .warmd/tasks/a.md)"
grep -q '^Heavy runs: .*warmd run --heavy -- <command>' .warmd/tasks/a.md && ok "the task file sends own engine runs through the heavy queue" || no "heavy line: $(cat .warmd/tasks/a.md)"
echo "$out" | grep -q '^FALLBACK a (no warmd-worker agent in .*): subagent_type=general-purpose model=sonnet prompt="You are a warmd worker\. .*Read .*a\.md and do it\."' && ok "without the agent file split prints a general-purpose fallback with the rules inline" || no "fallback: $out"
grep -q 'gameplay\|worker' .warmd/tasks/a.role && [ -f ".warmd/roles/$(cat .warmd/tasks/a.role).md" ] && ok "a worker task gets its role file" || no "role file: $(ls .warmd/roles 2>&1)"
mkdir -p .claude/agents; cp "$HERE/agents/warmd-worker.md" .claude/agents/
printf 'd | enemy | y | scripts/enemy.gd\n' > "$TMP/d.txt"
out="$(WARMD_NO_PREWARM=1 "$HERE/bin/warmd" split "$TMP/d.txt" 2>&1)"
echo "$out" | grep -q '^FALLBACK' && no "fallback printed although the agent file is there: $out" || ok "no fallback when the agent file is registered"
printf 'floor=top\n' > warmd.conf
printf 'e | edit | y | scripts/e.gd\n' > "$TMP/e.txt"; out="$(WARMD_NO_PREWARM=1 "$HERE/bin/warmd" split "$TMP/e.txt" 2>&1)"
grep -q '^Review: the done check only' .warmd/tasks/e.md && ok "floor=top with an opus author: only the criteria script reviews" || no "floor review: $(grep Review .warmd/tasks/e.md)"
: > warmd.conf
# time budget: watch escalates a task past it
echo $(( $(date +%s) - 3700 )) > .warmd/tasks/c.start
out="$(WARMD_WATCH_POLL=1 timeout 60 "$HERE/bin/warmd" watch --once 2>&1)"; rc=$?
echo "$out" | grep -q '^OVER c: 6[0-9] min, time budget 60 min (mid)' && echo "$out" | grep -q '^AGENT c: subagent_type=warmd-worker model=opus' && [ $rc = 3 ] && ok "watch escalates a task past its time budget" || no "over budget rc=$rc: $out"
[ "$(cat .warmd/tasks/c.tier)" = top ] && grep -q '^Time budget: 120 min' .warmd/tasks/c.md && ok "the next tier gets its own time budget and clock" || no "after over: $(cat .warmd/tasks/c.tier)"
"$HERE/bin/warmd" batch-done > /dev/null 2>&1
cd "$TMP" || exit 1

# Routing learns only upward: an area raised once stays raised when later tasks succeed
U="$TMP/up"; mkdir -p "$U/.warmd/tasks"; cd "$U" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
echo '{ "name": "t", "scripts": { "test": "true" } }' > package.json; printf '.warmd\n' > .gitignore; git add -A; git commit -qm init
L="$(git rev-parse --path-format=absolute --git-common-dir)/warmd-ledger.tsv"
printf '1\tx\tmid\tsrc\t-\t-\t1\tescalated\n2\ty\tmid\tsrc\t-\t-\t1\tescalated\n' > "$L"
"$HERE/bin/warmd" route 'fix a bug' src/a.js | grep -q '^top' && ok "two escalations raise the area" || no "not raised"
for i in 3 4 5 6 7; do printf '%s\tz%s\tmid\tsrc\t-\t-\t1\tok\n' "$i" "$i" >> "$L"; done
"$HERE/bin/warmd" route 'fix a bug' src/a.js | grep -q '^top' && ok "later successes never lower a raised area" || no "area went back down"
"$HERE/bin/warmd" route 'fix the crash' lib/a.js > /dev/null
"$HERE/bin/warmd" route 'fix a bug' lib/a.js | grep -q '^mid' && ok "a goal word raises the task, not its area" || no "goal word made the area sticky"
# A read-only task that names a top word is top work too, umlauts in either spelling and case
printf 'top_words=crash|Strenge Prüfung\n' > warmd.conf
"$HERE/bin/warmd" route 'Strenge Prüfung des Spiels' | grep -q '^top' && ok "a top word routes a read-only task to top" || no "files none top word: $("$HERE/bin/warmd" route 'Strenge Prüfung des Spiels')"
"$HERE/bin/warmd" route 'STRENGE PRUEFUNG der KI' none | grep -q '^top' && ok "an umlaut matches in ue spelling and upper case" || no "umlaut fold: $("$HERE/bin/warmd" route 'STRENGE PRUEFUNG der KI' none)"
"$HERE/bin/warmd" route 'read the docs' | grep -q '^cheap' && ok "a plain read-only task stays cheap" || no "read-only not cheap"
printf 'r1 | read the code | y | none | tier=top\nr2 | fix a | b | y | src/a.js | tier=cheap\n' > "$TMP/tier.txt"
out="$(WARMD_NO_PREWARM=1 "$HERE/bin/warmd" split "$TMP/tier.txt" 2>&1)"
[ "$(cat .warmd/tasks/r1.tier 2>/dev/null)" = top ] && grep -q '^Goal: read the code$' .warmd/tasks/r1.md && ok "tier=top in the task line fixes the tier" || no "tier field: $out; $(cat .warmd/tasks/r1.tier 2>&1)"
[ "$(cat .warmd/tasks/r2.tier 2>/dev/null)" = mid ] && grep -q '^Goal: fix a | b$' .warmd/tasks/r2.md && ok "tier=cheap never sends an editing task to the read-only tier, a | in the goal stays" || no "tier cheap edit: $(cat .warmd/tasks/r2.tier 2>&1); $(grep Goal .warmd/tasks/r2.md 2>&1)"
"$HERE/bin/warmd" batch-done > /dev/null 2>&1; : > warmd.conf

# A rolled-back merge leaves one rule line in the role file of its task
printf 'gate=false\n' > warmd.conf; git add warmd.conf; git commit -qm conf
git checkout -qb warmd/r; echo r > r.txt; git add r.txt; git commit -qm r; git checkout -q main
echo gameplay > .warmd/tasks/r.role
out="$(WARMD_BASE=1 WARMD_BASE_BRANCH=main "$HERE/bin/warmd" merge warmd/r 2>&1)"
[ "$(grep -c ' r rolled back: ' .warmd/roles/gameplay.md 2>/dev/null)" = 1 ] && ! [ -f r.txt ] && ok "a rolled-back merge leaves one rule line in the role file" || no "rule line: $out; $(cat .warmd/roles/gameplay.md 2>&1)"
cd "$TMP" || exit 1

echo
[ $fails = 0 ] && echo "all green" || echo "$fails failed"
cd "$HERE" || exit 1; rm -rf "$TMP" 2>/dev/null
exit $fails
