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

echo
[ $fails = 0 ] && echo "all green" || echo "$fails failed"
cd "$HERE" || exit 1; rm -rf "$TMP" 2>/dev/null
exit $fails
