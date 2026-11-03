#!/usr/bin/env bash
# warmd ship and warmd ci against a local bare remote and a fake gh. No network.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
TMP="$(mktemp -d)"
export XDG_CACHE_HOME="$TMP/cache" XDG_CONFIG_HOME="$TMP/config" WARMD_CI_POLL=0 WARMD_CI_TRIES=2
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
  "run watch") exit "$(cat "$FAKE/ci_rc" 2>/dev/null || echo 0)";;
  "run view") case "$*" in *--log-failed*) cat "$FAKE/failed_log" 2>/dev/null;; *) cat "$FAKE/jobs";; esac;;
  "pr list") cat "$FAKE/pr" 2>/dev/null;;
  "pr create") echo 7 > "$FAKE/pr"; echo "https://github.com/o/r/pull/7";;
  "pr merge") git push -q origin warmd-ship:main;;
  "release create") ;;
esac
EOF
chmod +x "$FAKE/bin/gh"
export PATH="$FAKE/bin:$PATH"

git init -q --bare -b main "$TMP/remote.git"
git clone -q "$TMP/remote.git" "$TMP/w" 2>/dev/null
cd "$TMP/w" || exit 1
git config user.name t; git config user.email t@example.com
mkdir bin
cat > bin/warmd <<'EOF'
usage() {
  cat <<'X'
  warmd status                 what is warm
X
}
case "$CMD" in
  status)  a_status;;
esac
EOF
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

echo 41 > "$FAKE/run_id"; printf 'success self-test (windows-latest)\nsuccess shellcheck\n' > "$FAKE/jobs"
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

# Second ship updates the same PR. CI red: names failing tests, no merge.
: > "$FAKE/log"; echo 1 > "$FAKE/ci_rc"
printf 'failure self-test (windows-latest)\nsuccess shellcheck\n' > "$FAKE/jobs"
printf 'self-test\tRun\tFAIL detect godot from a subfolder: wanted x\nself-test\tRun\tok   other\n' > "$FAKE/failed_log"
out="$("$WARMD" ship alpha 2>&1)"; rc=$?
expect "updates the open PR" 'updated PR #7' "$out"
expect "red job line" 'FAIL self-test \(windows-latest\)' "$out"
expect "failing test named" 'test FAIL detect godot from a subfolder' "$out"
expect "no merge on red" 'CI red, PR #7 not merged' "$out"
[ $rc -ne 0 ] && ok "red exit code" || no "red exit code"
expect "no pr merge on red" '^$' "$(grep 'pr merge' "$FAKE/log")"

# Conflict outside the usage block stops and leaves no half merge.
echo 0 > "$FAKE/ci_rc"
out="$("$WARMD" ship bad 2>&1)"; rc=$?
expect "real conflict refused" 'FAIL bad conflicts outside the usage/dispatch block: README' "$out"
[ $rc -ne 0 ] && ok "refused exit code" || no "refused exit code"
expect "merge aborted" '^$' "$(git status --porcelain | grep -v '^??')"

# warmd ci on its own.
printf 'success self-test (windows-latest)\n' > "$FAKE/jobs"
out="$("$WARMD" ci 2>&1)"
expect "ci green" 'GREEN run 41' "$out"
rm -f "$FAKE/run_id"
out="$("$WARMD" ci 2>&1)"
expect "ci without a run" 'no CI run for' "$out"

expect "help lists registered commands" 'warmd ship .*warmd ci' "$("$WARMD" --help | tr '\n' ' ')"
out="$("$WARMD" ship --release 1.0 alpha 2>&1)"
expect "bad release name" 'release must look like v1.2.3' "$out"

rm -rf "$TMP"
[ "$fails" = 0 ] && echo "ALL GREEN" || { echo "$fails FAILED"; exit 1; }
