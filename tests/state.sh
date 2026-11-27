#!/usr/bin/env bash
# warmd state: the one-line state the VS Code status bar shows, read from fake markers (idle, batch, running check, red last)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
TMP="$(mktemp -d)"
export XDG_CACHE_HOME="$TMP/cache" XDG_CONFIG_HOME="$TMP/config" WARMD_UPDATE_CHECK=0
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails+1)); }
expect() { if printf '%s\n' "$3" | grep -qE -- "$2"; then ok "$1"; else no "$1: wanted /$2/, got: $(printf '%s\n' "$3" | head -3)"; fi; }

P="$TMP/proj"; mkdir -p "$P"; cd "$P" || exit 1
git init -q -b main .; git config core.autocrlf false; git config user.name t; git config user.email t@example.com
echo 'test=true' > warmd.conf; git add .; git commit -qm init
common="$(git rev-parse --path-format=absolute --git-common-dir)"
st() { bash "$WARMD" state --json; }

out="$(st)"
expect "idle without signals" '^\{"active":false,"what":"idle","agents":0,"since":0,"last":"","line":""\}$' "$out"
expect "plain line says IDLE" '^IDLE' "$(bash "$WARMD" state)"

# Batch: two live worktrees, a third whose agent stopped (warmd-batch-done) does not count
mkdir -p "$TMP/wt1" "$TMP/wt2" "$TMP/wt3"
printf '%s\n' "$TMP/wt1" "$TMP/wt2" "$TMP/wt3" > "$common/warmd-batch"
printf '%s\tok\n' "$TMP/wt3" > "$common/warmd-batch-done"
out="$(st)"
expect "batch with 2 agents" '"active":true,"what":"batch","agents":2,' "$out"
expect "batch since is an epoch" '"since":[0-9]{9,}' "$out"

# A running check marks .warmd/run/active/<pid>: the live pid of this shell stands in for warmd's
mkdir -p "$P/.warmd/run/active"; echo "- check" > "$P/.warmd/run/active/$$"
out="$(st)"
expect "running check wins over the batch" '"active":true,"what":"check","agents":2' "$out"
expect "plain line names the run" '^ACTIVE check, 2 agents' "$(bash "$WARMD" state)"
# A dead run's mark goes, the state falls back to the batch
rm -f "$P/.warmd/run/active/$$"; echo "- test" > "$P/.warmd/run/active/999999"
expect "dead run mark is no run" '"what":"batch"' "$(st)"
[ -f "$P/.warmd/run/active/999999" ] && no "dead run mark removed" || ok "dead run mark removed"

# CI wait: .warmd/ci.wait holds "pid run-id start median"
echo "$$ 42 1700000000 300" > "$P/.warmd/ci.wait"
expect "CI wait with its start" '"what":"ci-wait","agents":2,"since":1700000000' "$(st)"
rm -f "$P/.warmd/ci.wait" "$common/warmd-batch" "$common/warmd-batch-done"

# Last result: the newest line of runs.log decides, red when its exit code is not 0
printf '%s\t%s\t%s\t%s\t%s\n' "2026-01-01 10:00:00" abc1234 0 test all "2026-01-01 10:05:00" abc1234 1 check 'affected "x"' > "$P/.warmd/run/runs.log"
out="$(st)"
expect "red last result" '"active":false,"what":"idle","agents":0,"since":0,"last":"red"' "$out"
expect "last line names the run, quotes escaped" '"line":"check affected \\"x\\" red at 2026-01-01 10:05:00 \(abc1234\)"' "$out"
printf '%s\t%s\t%s\t%s\t%s\n' "2026-01-01 10:09:00" abc1234 0 test all >> "$P/.warmd/run/runs.log"
expect "green after a green run" '"last":"green"' "$(st)"

cd / && rm -rf "$TMP"
exit $fails
