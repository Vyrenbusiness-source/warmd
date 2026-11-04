#!/usr/bin/env bash
# warmd ship and warmd ci against a local bare remote and a fake gh. No network.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
TMP="$(mktemp -d)"
export XDG_CACHE_HOME="$TMP/cache" XDG_CONFIG_HOME="$TMP/config" WARMD_CI_POLL=0 WARMD_CI_TRIES=2 WARMD_UPDATE_CHECK=0 WARMD_INSTALL="$TMP/install"
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails+1)); }
expect() { if echo "$3" | grep -qE "$2"; then ok "$1"; else no "$1: wanted /$2/, got: $(echo "$3" | head -6)"; fi; }

# Fake gh: logs every call, answers from files in $FAKE.
FAKE="$TMP/fake"; mkdir -p "$FAKE/bin"
export FAKE
cat > "$FAKE/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$FAKE/log"
case "$1 $2" in
  "run list") cat "$FAKE/run_id" 2>/dev/null;;
  "run watch") echo "blocking gh run watch used" >&2; exit 9;;
  "run view") case "$*" in *--log-failed*) cat "$FAKE/failed_log" 2>/dev/null;;
    *) n=$(( $(cat "$FAKE/n" 2>/dev/null || echo 0) + 1 )); echo $n > "$FAKE/n"   # jobs.N answers poll N, jobs every later one
       if [ -f "$FAKE/jobs.$n" ]; then cat "$FAKE/jobs.$n"; else cat "$FAKE/jobs"; fi;; esac;;
  "pr list") cat "$FAKE/pr" 2>/dev/null;;
  "pr create") echo 7 > "$FAKE/pr"; echo "https://github.com/o/r/pull/7";;
  "pr merge") git push -q origin warmd-ship:main;;
  "release create") ;;
esac
EOF
chmod +x "$FAKE/bin/gh"
export PATH="$FAKE/bin:$PATH"
# Poll answers as ci_poll prints them: run|status|conclusion|createdAt, then name|status|conclusion|open|failed|step|steps
iso() { date -u -d "@$(( $(date +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ; }
run_done() { # conclusion of self-test
  printf 'run|completed|%s|%s\nself-test (windows-latest)|completed|%s|0|%s||5\nshellcheck|completed|success|0|0||3\n' "$1" "$(iso 60)" "$1" "$([ "$1" = failure ] && echo 1 || echo 0)"
}
polls() { rm -f "$FAKE"/jobs.* "$FAKE/n"; }
running() { # seconds since start, file: one job in progress at step Run tests
  printf 'run|in_progress||%s\nself-test (windows-latest)|in_progress||2|0|Run tests|5\n' "$(iso "$1")" > "$2"
}

git init -q --bare -b main "$TMP/remote.git"
git clone -q "$TMP/remote.git" "$TMP/w" 2>/dev/null
cd "$TMP/w" || exit 1
git config user.name t; git config user.email t@example.com
mkdir bin
cat > bin/warmd <<'EOF'
WARMD_VERSION=0.1.0
case "${1:-}" in --version) echo "warmd $WARMD_VERSION"; exit 0;; esac
usage() {
  cat <<'X'
  warmd status                 what is warm
X
}
case "$CMD" in
  status)  a_status;;
esac
EOF
printf '# Changelog\n\n## [Unreleased]\n\n### Added\n- alpha and beta\n\n## [0.1.0] - 2026-11-01\n\n[Unreleased]: https://github.com/o/r/compare/v0.1.0...HEAD\n[0.1.0]: https://github.com/o/r/releases/tag/v0.1.0\n' > CHANGELOG.md
echo base > README; git add -A; git commit -qm base; git tag v0.1.0; git push -q origin main --tags

# Two branches that both add a command at the same place: usage/dispatch conflict only.
for c in alpha beta; do
  git checkout -q -b "$c" main
  sed -i "s/^  warmd status .*/&\n  warmd $c                  $c line/; s/^  status)  a_status;;/&\n  $c)  run_$c;;/" bin/warmd
  echo "$c" > "$c.txt"; git add -A; git commit -qm "add $c"; git push -q origin "$c"
done
# A branch that conflicts in real code.
git checkout -q -b bad main; echo other > README; git commit -qam "bad change"; git push -q origin bad
git checkout -q main; echo base2 > README; git commit -qam "base moves"; git push -q origin main

git clone -q "$TMP/remote.git" "$TMP/install" 2>/dev/null   # the installed copy, a clean clone of the same repo
echo 41 > "$FAKE/run_id"; run_done success > "$FAKE/jobs"
out="$("$WARMD" ship --release v0.2.0 alpha beta 2>&1)"
expect "first branch merges clean" 'ok   merged alpha$' "$out"
expect "usage/dispatch conflict resolved" 'merged beta, usage/dispatch conflict resolved' "$out"
expect "opens a PR" 'opened PR #7' "$out"
expect "one line per job" 'ok   shellcheck' "$out"
expect "merges on green" 'merged PR #7 into main' "$out"
expect "release made" 'ok   release v0.2.0' "$out"
expect "ends shipped" 'SHIPPED PR #7' "$out"
pushed="$(git --git-dir="$TMP/remote.git" show warmd-ship:bin/warmd)"
expect "both usage lines kept" 'warmd alpha' "$pushed"
expect "both usage lines kept 2" 'warmd beta' "$pushed"
expect "both dispatch lines kept" 'beta\)  run_beta' "$pushed"
expect "no conflict markers" '^[^<]*$' "$(echo "$pushed" | grep -c '<<<<<<<' | sed 's/^0$/clean/')"
expect "release notes from git log" 'release create v0.2.0 .*add alpha' "$(tr '\n' ' ' < "$FAKE/log")"
expect "pr merge called" 'gh pr merge 7 --merge' "$(cat "$FAKE/log")"
expect "no blocking gh run watch" '^$' "$(grep 'run watch' "$FAKE/log")"
main_warmd="$(git --git-dir="$TMP/remote.git" show main:bin/warmd)"
expect "release bumps bin/warmd" '^WARMD_VERSION=0.2.0$' "$main_warmd"
echo "$main_warmd" > "$TMP/released"
expect "warmd --version after a fake release" '^warmd 0.2.0$' "$(bash "$TMP/released" --version)"
cl="$(git --git-dir="$TMP/remote.git" show main:CHANGELOG.md)"
expect "changelog section moved" "^## \[0.2.0\] - $(date +%Y-%m-%d)$" "$cl"
expect "changelog keeps an empty Unreleased" '^## \[Unreleased\]$' "$cl"
expect "changelog link to the new version" '^\[0.2.0\]: https://github.com/o/r/compare/v0.1.0...v0.2.0$' "$cl"
expect "changelog Unreleased link moves" '^\[Unreleased\]: https://github.com/o/r/compare/v0.2.0...HEAD$' "$cl"
expect "merged branches deleted on origin" 'deleted origin/beta' "$out"
expect "origin has no task branches" '^$' "$(git --git-dir="$TMP/remote.git" branch --list alpha beta)"
expect "installed copy updated" 'ok   installed copy ' "$out"
[ "$(git -C "$TMP/install" rev-parse HEAD)" = "$(git --git-dir="$TMP/remote.git" rev-parse main)" ] && ok "installed copy at origin main" || no "installed copy left behind"
ci_hist="$(git rev-parse --path-format=absolute --git-common-dir)/warmd-ci.tsv"
expect "run duration recorded" '	41	warmd-ship	[0-9]+	success$' "$(cat "$ci_hist")"

# Second ship updates the same PR. CI red: names failing tests, no merge.
: > "$FAKE/log"; polls; run_done failure > "$FAKE/jobs"
printf 'self-test\tRun\tFAIL detect godot from a subfolder: wanted x\nself-test\tRun\tok   other\n' > "$FAKE/failed_log"
out="$("$WARMD" ship alpha 2>&1)"; rc=$?
expect "updates the open PR" 'updated PR #7' "$out"
expect "red job line" 'FAIL self-test \(windows-latest\)' "$out"
expect "failing test named" 'test FAIL detect godot from a subfolder' "$out"
expect "no merge on red" 'CI red, PR #7 not merged' "$out"
[ $rc -ne 0 ] && ok "red exit code" || no "red exit code"
expect "no pr merge on red" '^$' "$(grep 'pr merge' "$FAKE/log")"

# Conflict outside the usage block stops and leaves no half merge.
out="$("$WARMD" ship bad 2>&1)"; rc=$?
expect "real conflict refused" 'FAIL bad conflicts outside the usage/dispatch block: README' "$out"
[ $rc -ne 0 ] && ok "refused exit code" || no "refused exit code"
expect "merge aborted" '^$' "$(git status --porcelain | grep -v '^??')"

# warmd ci on its own: polls until done.
polls; run_done success > "$FAKE/jobs"; running 30 "$FAKE/jobs.1"
: > "$FAKE/log"; out="$("$WARMD" ci 2>&1)"
expect "ci green" 'GREEN run 41' "$out"
expect "ci polls until done" '^2$' "$(grep -c 'run view' "$FAKE/log")"

# GitHub keeps the job in_progress after its last step: the steps decide.
polls; printf 'run|in_progress||%s\nself-test (windows-latest)|in_progress||0|0||6\nshellcheck|completed|success|0|0||3\n' "$(iso 60)" > "$FAKE/jobs"
out="$(WARMD_CI_MAX=0 "$WARMD" ci 2>&1)"
expect "job with all steps done counts green" 'GREEN run 41' "$out"
expect "its job line is ok" 'ok   self-test \(windows-latest\)' "$out"
polls; printf 'run|in_progress||%s\nself-test (windows-latest)|in_progress||0|1||6\n' "$(iso 60)" > "$FAKE/jobs"
out="$(WARMD_CI_MAX=0 "$WARMD" ci 2>&1)"
expect "job with a failed step counts red" 'RED run 41' "$out"

# Hard cap: a run that never ends stops the wait.
polls; running 60 "$FAKE/jobs"
out="$(WARMD_CI_MAX=0 "$WARMD" ci 2>&1)"; rc=$?
expect "cap ends the wait" 'FAIL CI run 41 not done after 0 min, self-test \(windows-latest\) at step Run tests' "$out"
[ $rc -ne 0 ] && ok "cap exit code" || no "cap exit code"

# ETA from the median of recent green runs, SLOW past 1.5 times it, naming job and step.
printf '1\t1\tmain\t600\tsuccess\n2\t2\tmain\t540\tsuccess\n3\t3\tmain\t60\tfailure\n4\t4\tmain\t660\tsuccess\n' > "$ci_hist"
polls; run_done success > "$FAKE/jobs"; running 120 "$FAKE/jobs.1"
out="$("$WARMD" ci 2>&1)"
expect "ETA line from the median" '^ETA run 41: about 8 min left, median 10 min of 3 runs$' "$out"
expect "no SLOW below 1.5x" '^$' "$(echo "$out" | grep SLOW)"
polls; running 1000 "$FAKE/jobs.1"
out="$("$WARMD" ci 2>&1)"
expect "SLOW names job and step" '^SLOW run 41: 16 min, median 10 min, self-test \(windows-latest\) at step Run tests$' "$out"
expect "slow run still ends green" 'GREEN run 41' "$out"
[ ! -e .warmd/ci.wait ] && ok "wait marker removed after the run" || no "wait marker left behind"
rm -f "$FAKE/run_id"
out="$("$WARMD" ci 2>&1)"
expect "ci without a run" 'no CI run for' "$out"

expect "help lists registered commands" 'warmd ship .*warmd ci' "$("$WARMD" --help | tr '\n' ' ')"
out="$("$WARMD" ship --release 1.0 alpha 2>&1)"
expect "bad release name" 'release must look like v1.2.3' "$out"

# The installed copy behind its origin: one UPDATE line from local refs, none when current.
behind() { ( WARMD_UPDATE_CHECK=0; reg() { :; }; . "$HERE/lib/ship.sh"; install_behind "$1" ); }
expect "current install is quiet" '^$' "$(behind "$TMP/install")"
git checkout -q main; git pull -q origin main 2>/dev/null; echo more >> README; git commit -qam more; git push -q origin main
git -C "$TMP/install" fetch -q origin
expect "behind install named" '^UPDATE installed [0-9a-f]+ behind origin [0-9a-f]+ by 1 commits, run: warmd update$' "$(behind "$TMP/install")"

rm -rf "$TMP"
[ "$fails" = 0 ] && echo "ALL GREEN" || { echo "$fails FAILED"; exit 1; }
