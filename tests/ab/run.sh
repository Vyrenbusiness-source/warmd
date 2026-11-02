#!/usr/bin/env bash
# A/B: the same bug-fix task through `claude -p`, once plain and once with warmd on the PATH.
# Usage: tests/ab/run.sh [runs-per-side=3] [model=haiku]   Spends real tokens: about 30k or less per run on haiku.
# Needs: claude, node, git. Prints one row per run and a mean per side. Nothing is estimated.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RUNS="${1:-3}"; MODEL="${2:-haiku}"
OUT="${AB_OUT:-$(mktemp -d)}"
TASK='The test suite of this small Node project has one failing test. Find the cause in the source, fix the source (not the test), and confirm the tests pass. Answer in one line.'
HINT=' Use `warmd test` to run the tests and `warmd map <file>` to see a file outline before you read lines.'

one() { # side n
  local side="$1" n="$2" d="$OUT/$1$2" prompt="$TASK" path="$PATH"
  rm -rf "$d"; mkdir -p "$d"; cp -R "$HERE/sample/." "$d/"
  ( cd "$d" && git init -q -b main . && git config user.name t && git config user.email t@example.com && git add -A && git commit -qm init )
  if [ "$side" = with ]; then prompt="$TASK$HINT"; path="$ROOT/bin:$PATH"; fi
  ( cd "$d" && PATH="$path" claude -p "$prompt" --model "$MODEL" --output-format json --tools "Bash,Read,Edit" \
      --permission-mode bypassPermissions --setting-sources project --disable-slash-commands --strict-mcp-config \
      --no-session-persistence --max-turns 15 > "$d/result.json" 2> "$d/err.txt" )
  local pass=no; ( cd "$d" && npm test >/dev/null 2>&1 ) && pass=yes
  node -e '
    const fs = require("fs"); let r = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); if (Array.isArray(r)) r = r.filter(x => x.type === "result").pop() || {};
    const u = r.usage || {};
    // side, run, input, cache-new, cache-read, output, seconds, turns, usd, fixed
    console.log([process.argv[2], process.argv[3], u.input_tokens || 0, u.cache_creation_input_tokens || 0, u.cache_read_input_tokens || 0, u.output_tokens || 0,
      ((r.duration_ms || 0) / 1000).toFixed(1), r.num_turns || 0, (r.total_cost_usd || 0).toFixed(4), process.argv[4]].join("\t"));
  ' "$d/result.json" "$side" "$n" "$pass" >> "$OUT/rows.tsv" 2>/dev/null || echo "$side	$n	0	0	0	0	0	0	0	$pass	(no result: see $d/err.txt)" >> "$OUT/rows.tsv"
}

: > "$OUT/rows.tsv"
for n in $(seq 1 "$RUNS"); do one without "$n"; one with "$n"; done

printf '%-8s %3s %7s %10s %11s %7s %8s %5s %8s %5s\n' side run input cache-new cache-read output seconds turns usd fixed
awk -F'\t' '{ printf "%-8s %3s %7s %10s %11s %7s %8s %5s %8s %5s\n", $1,$2,$3,$4,$5,$6,$7,$8,$9,$10 }' "$OUT/rows.tsv"
echo "--- mean per run (tokens = input + cache-new + cache-read + output)"
awk -F'\t' '{ n[$1]++; t[$1] += $3+$4+$5+$6; o[$1] += $6; s[$1] += $7; u[$1] += $9; if ($10 == "yes") f[$1]++ }
  END { printf "%-8s %5s %10s %8s %8s %8s %6s\n", "side", "runs", "tokens", "output", "seconds", "usd", "fixed"
        for (k in n) printf "%-8s %5d %10.0f %8.0f %8.1f %8.4f %3d/%d\n", k, n[k], t[k]/n[k], o[k]/n[k], s[k]/n[k], u[k]/n[k], f[k], n[k] }' "$OUT/rows.tsv"
echo "raw: $OUT"
