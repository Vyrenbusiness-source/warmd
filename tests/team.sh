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
busy() { ( cd "$TMP" && WARMD_HOME="$HERE" && . "$HERE/lib/platform.sh" && . "$HERE/lib/core.sh" && detect_project >/dev/null 2>&1; . "$HERE/lib/team.sh"; wt_busy "$1" ); }

# Stub gh: a watch sleeps, the lists name PR 7 and run 4242 as this branch's
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "run watch"|"pr checks") sleep 30;;
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

echo
[ $fails = 0 ] && echo "all green" || echo "$fails failed"
cd "$HERE"; rm -rf "$TMP" 2>/dev/null
exit $fails
