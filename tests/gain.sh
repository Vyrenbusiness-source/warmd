#!/usr/bin/env bash
# warmd gain: token and dollar math on fixed transcripts. No network, no Claude call.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FX="$HERE/tests/fixtures/gain"
WARMD="$HERE/bin/warmd"
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails+1)); }
expect() { if echo "$3" | grep -qE "$2"; then ok "$1"; else no "$1: wanted /$2/, got: $(echo "$3" | head -4)"; fi; }
XDG_CONFIG_HOME="$(mktemp -d)"; export XDG_CONFIG_HOME

out="$("$WARMD" gain "$FX/session1.jsonl")"
# Two messages after dedup: input 20, cache-new 1000, cache-read 1000, output 150, calls 2
expect "dedup by message id" 'total +2 +20 +1000 +1000 +150 ' "$out"
expect "cache hit share 49.5" '49\.5%' "$out"
# usd: (20*2 + 1000*2.5 + 1000*0.1 + 150*10)/1e6 = 0.004140 -> 0.00
expect "dollars from table" 'total .* 0\.00$' "$out"
# saved: 1000 * (2 - 0.1) / 1e6 = 0.0019 -> 0.00
expect "cache saving line" 'cache saved 0\.00 usd' "$out"

out="$(WARMD_PRICES="$FX/prices.tsv" "$WARMD" gain "$FX/session1.jsonl")"
# custom table: input 1, write 0, read 0, output 1 per MTok: (20+150)/1e6; saving 1000*1/1e6
expect "price file overrides table" 'total .* 0\.00$' "$out"
big="$(mktemp)"; sed 's/"output_tokens":100/"output_tokens":1000000/' "$FX/session1.jsonl" > "$big"
out="$(WARMD_PRICES="$FX/prices.tsv" "$WARMD" gain "$big")"
expect "price file math" 'total .* 1\.00$' "$out"
rm -f "$big"

out="$("$WARMD" gain "$FX/session1.jsonl" "$FX/session2.jsonl")"
expect "unknown model counted, no dollars" 'no price for: claude-mystery-9' "$out"
expect "two sessions listed" 'session2 +1 +5 ' "$out"

out="$("$WARMD" gain /nonexistent.jsonl 2>&1)";
expect "missing file is an error" 'no sessions' "$out"

[ "$fails" = 0 ] && echo "ALL GREEN" || { echo "$fails FAILED"; exit 1; }
