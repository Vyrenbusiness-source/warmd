#!/usr/bin/env bash
# Digest self-test: one fixture per runner. Checks the cause survives and measures bytes before and after.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WARMD_HOME="$HERE"
. "$HERE/lib/digest.sh"
FIX="$HERE/tests/fixtures/digest"
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails+1)); }
# old filter, kept here only to measure what the digest replaces
old_filter() { sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$1" | grep -iE 'error|fail|panic|traceback|assert|expected|✗|×|exception' | awk '!seen[$0]++' | cut -c1-200 | head -13 | grep . || tail -13 "$1" | cut -c1-200; }

# runner | must appear in the digest (each is a fixed string)
check() {
  local r="$1"; shift
  local f="$FIX/$r.log" out raw new old
  out="$(digest_log "$f")" || { no "$r: digest returned nothing"; return; }
  for want in "$@"; do
    printf '%s' "$out" | grep -qF -- "$want" || no "$r: lost cause '$want'"
  done
  raw=$(wc -c < "$f"); new=$(printf '%s\n' "$out" | wc -c); old=$(old_filter "$f" | wc -c)
  local pct=$(( (raw - new) * 100 / raw )) oldpct=$(( (raw - old) * 100 / raw ))
  printf '     %-7s raw %5d B  old filter %4d B (%2d%%)  digest %4d B (%2d%%)\n' "$r" "$raw" "$old" "$oldpct" "$new" "$pct"
  [ "$pct" -ge 80 ] && ok "$r saves at least 80%" || no "$r saves only $pct%"
  [ "$r" = "$(digest_runner "$f")" ] && ok "$r detected" || no "$r detected as '$(digest_runner "$f")'"
}

check vitest "applies discount" "src/total.test.ts:14" "95" "90"
check jest   "applies discount" "Expected: 95" "Received: 90" "src/total.test.js:14"
check pytest "test_applies_discount" "assert 90 == 95" "tests/test_total.py:14"
check cargo  "total::tests::applies_discount" "src/total.rs:31" "left: 90" "right: 95"
check go     "TestAppliesDiscount" "total_test.go:14" "= 90, want 95"
check dotnet "Shop.Tests.TotalTests.AppliesDiscount" "Expected: 95" "Actual:   90" "TotalTests.cs:line 14"

# unknown log: no digest, caller falls back
printf 'some build said boom\n' > "$FIX/../.unknown.tmp"
digest_log "$FIX/../.unknown.tmp" >/dev/null && no "unknown log was digested" || ok "unknown log falls back"
rm -f "$FIX/../.unknown.tmp"

# more failures than the cap are counted, not dropped silently
cap_log="$(mktemp)"; for i in 1 2 3 4 5 6 7; do printf -- '--- FAIL: TestN%s (0.00s)\n' "$i"; done > "$cap_log"
digest_log "$cap_log" | grep -qF '(+2 more failures)' && ok "cap counts the rest" || no "cap line missing"
rm -f "$cap_log"

[ $fails = 0 ] && echo "digest green" || echo "digest: $fails failed"
exit $fails
