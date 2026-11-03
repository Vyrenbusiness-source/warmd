#!/usr/bin/env bash
# A/B per area: the same work without and with warmd, on two sample projects.
#   web  tests/ab/web  Vite + Vitest + jsdom, 6 components, 6 test files, one real bug (price cents)
#   py   tests/ab/py   Python + pytest, 5 modules, 5 test files, one real bug (money split)
#
# Usage
#   tests/ab/run.sh measure <web|py>                 output size, cached repeat time, affected tests. No tokens spent
#   tests/ab/run.sh tokens <web|py>                  real token count of each captured output (claude -p, haiku, 5 one-turn calls)
#   tests/ab/run.sh agent <web|py> [runs=5] [model=haiku]   full agent A/B: fix the bug, plain vs warmd, runs one after another
#
# Needs bash (Git Bash on Windows), node + npm, python + pytest, git, claude. Results go to $AB_OUT (default: a temp dir),
# one TSV per step, plus a printed table. Nothing is estimated: tokens come from the API usage of real calls.
# Every run waits until at least $AB_FREE_PCT % RAM is free (default 15) before it starts.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WARMD="$ROOT/bin/warmd"
OUT="${AB_OUT:-$(mktemp -d)}"; mkdir -p "$OUT"
FREE_PCT="${AB_FREE_PCT:-15}"

die() { echo "FAIL $*" >&2; exit 1; }
now_ms() { local t; t="$(date +%s%N)"; echo $(( t / 1000000 )); }

free_pct() {
  if [ -r /proc/meminfo ] && ! grep -qi microsoft /proc/version 2>/dev/null && [ "$(uname -o 2>/dev/null)" != Msys ]; then
    awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {print int(a*100/t)}' /proc/meminfo
  else
    powershell.exe -NoProfile -Command '$o = Get-CimInstance Win32_OperatingSystem; [int]($o.FreePhysicalMemory * 100 / $o.TotalVisibleMemorySize)' 2>/dev/null | tr -d '\r'
  fi
}
ram_wait() {
  local p; p="$(free_pct)"
  while [ -n "$p" ] && [ "$p" -lt "$FREE_PCT" ]; do echo "(waiting for RAM: $p % free, need $FREE_PCT %)" >&2; sleep 20; p="$(free_pct)"; done
}

# Per project: the plain test command, the fix, two one-file changes (a leaf and a shared module).
setup_area() {
  AREA="$1"
  case "$AREA" in
    web) SRC="$HERE/web"; RAW_TEST='npm test'
         FIX_FILE=src/components/price.js; FIX_FROM='${rest}`'; FIX_TO="\${String(rest).padStart(2, '0')}\`"
         LEAF=src/components/badge.js; SHARED=src/components/price.js; CMT='//';;
    py)  SRC="$HERE/py"; RAW_TEST='python -m pytest'
         FIX_FILE=shop/money.py; FIX_FROM='return [base] * parts'; FIX_TO='return [base + (1 if i < total % parts else 0) for i in range(parts)]'
         LEAF=shop/parse.py; SHARED=shop/stock.py; CMT='#';;
    *) die "area is web or py";;
  esac
}

# The plain run as an agent would read it: no colour codes, so the byte count is a lower bound for the plain side.
raw_run() { ( cd "$1" && NO_COLOR=1 FORCE_COLOR=0 sh -c "$RAW_TEST" 2>&1 ) | sed 's/\x1b\[[0-9;]*[A-Za-z]//g'; return "${PIPESTATUS[0]}"; }

# fresh copy as its own git repo on main, node_modules installed for web
copy_area() { # dir
  local d="$1"
  rm -rf "$d"; mkdir -p "$d"
  ( cd "$SRC" && git ls-files -co --exclude-standard . | tr -d '\r' | while IFS= read -r f; do mkdir -p "$d/$(dirname "$f")"; cp "$f" "$d/$f"; done )
  ( cd "$d" && git init -q -b main . && git config core.autocrlf false && git config user.name ab && git config user.email ab@example.com && git add -A && git commit -qm init )
  if [ "$AREA" = web ]; then ( cd "$d" && npm install --no-audit --no-fund --silent >/dev/null 2>&1 ) || die "npm install in $d"; fi
}
apply_fix() { # dir
  FROM="$FIX_FROM" TO="$FIX_TO" node -e 'const fs=require("fs"),f=process.argv[1],s=fs.readFileSync(f,"utf8");if(!s.includes(process.env.FROM))process.exit(3);fs.writeFileSync(f,s.replace(process.env.FROM,process.env.TO))' "$1/$FIX_FILE" || die "fix did not apply to $1/$FIX_FILE"
}
# Tests and test files the runner reported, from its full output: "<files> <tests>"
count_run() { # log
  sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$1" | awk '
    /Test Files/ { for (i = 1; i <= NF; i++) if ($i ~ /^\([0-9]+\)$/) { gsub(/[()]/, "", $i); f = $i } }
    /^ *Tests / { for (i = 1; i <= NF; i++) if ($i ~ /^\([0-9]+\)$/) { gsub(/[()]/, "", $i); t = $i } }
    / passed| failed/ && /in [0-9.]+s/ { n = 0; for (i = 1; i <= NF; i++) if ($(i+1) ~ /^(passed|failed),?$/) n += $i; t = n }
    END { print (f == "" ? "-" : f), (t == "" ? 0 : t) }'
}
pytest_files() { sed -n 's#^\(tests/test_[a-z_]*\.py\).*#\1#p' "$1" | sort -u | wc -l | tr -d ' '; }

# ---- measure: no model calls ----
measure() {
  setup_area "$1"; local d="$OUT/$AREA-measure" rows="$OUT/$AREA-measure.tsv" i t0 rms wms raw_ms=() w_ms=() f n
  export XDG_CACHE_HOME="$OUT/$AREA-cache"; rm -rf "$XDG_CACHE_HOME"
  copy_area "$d"; : > "$rows"
  # 1. what an agent reads from one red run
  raw_run "$d" > "$OUT/$AREA-raw-red.txt" 2>&1
  ( cd "$d" && "$WARMD" test ) > "$OUT/$AREA-warmd-red.txt" 2>&1
  raw_run "$d" > "$OUT/$AREA-raw-green-pre.txt" 2>&1
  printf 'red-bytes\t%s\t%s\n' "$(wc -c < "$OUT/$AREA-raw-red.txt")" "$(wc -c < "$OUT/$AREA-warmd-red.txt")" >> "$rows"
  # 2. repeat run with unchanged code, after the fix is committed: 1 warm-up, then 3 timed runs each
  apply_fix "$d"; ( cd "$d" && git commit -qam fix )
  raw_run "$d" > "$OUT/$AREA-raw-green.txt" 2>&1
  ( cd "$d" && "$WARMD" test ) > "$OUT/$AREA-warmd-green.txt" 2>&1
  printf 'green-bytes\t%s\t%s\n' "$(wc -c < "$OUT/$AREA-raw-green.txt")" "$(wc -c < "$OUT/$AREA-warmd-green.txt")" >> "$rows"
  for i in 1 2 3; do
    t0="$(now_ms)"; raw_run "$d" >/dev/null 2>&1; raw_ms+=( $(( $(now_ms) - t0 )) )
    t0="$(now_ms)"; ( cd "$d" && "$WARMD" test ) > "$OUT/$AREA-warmd-repeat.txt" 2>&1; w_ms+=( $(( $(now_ms) - t0 )) )
  done
  grep -q 'cached' "$OUT/$AREA-warmd-repeat.txt" || echo "(note: warmd repeat was not a cache hit: $(head -1 "$OUT/$AREA-warmd-repeat.txt"))"
  printf 'repeat-ms\t%s\t%s\n' "$(printf '%s\n' "${raw_ms[@]}" | sort -n | sed -n 2p)" "$(printf '%s\n' "${w_ms[@]}" | sort -n | sed -n 2p)" >> "$rows"
  # 3. one-file change: all tests (plain) vs the tests that reach the file (warmd check)
  for f in "$LEAF" "$SHARED"; do
    ( cd "$d" && git checkout -q -- . && echo "$CMT ab change" >> "$f" )
    t0="$(now_ms)"; raw_run "$d" > "$OUT/$AREA-raw-all.txt" 2>&1; rms=$(( $(now_ms) - t0 ))
    # warmd check = compile or typecheck step plus the affected tests, so its time includes the build
    t0="$(now_ms)"; ( cd "$d" && "$WARMD" check ) > "$OUT/$AREA-warmd-check.txt" 2>&1; wms=$(( $(now_ms) - t0 ))
    cp "$d/.warmd/run/last.log" "$OUT/$AREA-warmd-check-full.txt" 2>/dev/null || : > "$OUT/$AREA-warmd-check-full.txt"
    read -r rf rt < <(count_run "$OUT/$AREA-raw-all.txt")
    read -r wf wt < <(count_run "$OUT/$AREA-warmd-check-full.txt")
    if [ "$AREA" = py ]; then
      rf="$(cd "$d" && ls tests/test_*.py | wc -l | tr -d ' ')"
      wf="$(sed -n 's/.*affected: \([0-9]*\) test files.*/\1/p' "$OUT/$AREA-warmd-check.txt")"; [ -n "$wf" ] || wf="$rf"
    fi
    printf 'affected %s\t%s files, %s tests\t%s files, %s tests\n' "$f" "$rf" "$rt" "$wf" "$wt" >> "$rows"
    printf 'check-ms %s\t%s\t%s\n' "$f" "$rms" "$wms" >> "$rows"
    printf 'check-bytes %s\t%s\t%s\n' "$f" "$(wc -c < "$OUT/$AREA-raw-all.txt")" "$(wc -c < "$OUT/$AREA-warmd-check.txt")" >> "$rows"
  done
  echo "== $AREA: measure   (metric, without warmd, with warmd)"
  column -t -s $'\t' "$rows" 2>/dev/null || cat "$rows"
  echo "outputs: $OUT/$AREA-*.txt"
}

# ---- tokens: the real input-token count of each output, as the model sees it ----
# One call with only a fixed frame, then one per output with the output inside the frame; the difference is the output's tokens.
tok_call() { # file|- model
  local body="" f="$1" r
  [ "$f" = - ] || body="$(cat "$f")"
  ram_wait
  r="$(claude -p "Reply with the single word ok.
<<<
$body
>>>" --model "$2" --output-format json --tools "" --setting-sources project --strict-mcp-config --no-session-persistence --max-turns 1 2>/dev/null)"
  printf '%s' "$r" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let r=JSON.parse(s);if(Array.isArray(r))r=r.filter(x=>x.type==="result").pop()||{};const u=r.usage||{};console.log((u.input_tokens||0)+(u.cache_creation_input_tokens||0)+(u.cache_read_input_tokens||0))})'
}
tokens() {
  setup_area "$1"; local model="${2:-haiku}" base f t rows="$OUT/$AREA-tokens.tsv"
  [ -f "$OUT/$AREA-raw-red.txt" ] || measure "$AREA" >/dev/null
  base="$(tok_call - "$model")"; [ -n "$base" ] && [ "$base" -gt 0 ] || die "token baseline call failed"
  : > "$rows"
  for f in raw-red warmd-red raw-green warmd-green; do
    t="$(tok_call "$OUT/$AREA-$f.txt" "$model")"
    printf '%s\t%s\t%s\n' "$f" "$(wc -c < "$OUT/$AREA-$f.txt")" "$(( t - base ))" >> "$rows"
  done
  echo "== $AREA: tokens of one test run as the agent reads it   (output, bytes, tokens; baseline frame $base tokens)"
  column -t -s $'\t' "$rows" 2>/dev/null || cat "$rows"
}

# ---- agent: full A/B, the same task through claude -p ----
TASK='The test suite of this project has one failing test. Find the cause in the source, fix the source (not the test), and confirm the tests pass. Answer in one line.'
HINT=' Use `warmd test` to run the tests, `warmd check` after a change, and `warmd map <file>` to see a file outline before you read lines.'
agent_one() { # side n model
  local side="$1" n="$2" model="$3" d="$OUT/$AREA-$1$2" prompt="$TASK" path="$PATH" pass=no
  copy_area "$d"
  if [ "$side" = with ]; then prompt="$TASK$HINT"; path="$ROOT/bin:$PATH"; fi
  ram_wait
  ( cd "$d" && PATH="$path" XDG_CACHE_HOME="$d/.ab-cache" claude -p "$prompt" --model "$model" --output-format json --tools "Bash,Read,Edit" \
      --permission-mode bypassPermissions --setting-sources project --disable-slash-commands --strict-mcp-config \
      --no-session-persistence --max-turns 20 > "$d/.ab-result.json" 2> "$d/.ab-err.txt" )
  # fixed = the original tests are untouched and pass
  ( cd "$d" && git diff --quiet HEAD -- test tests && sh -c "$RAW_TEST" >/dev/null 2>&1 ) && pass=yes
  node -e '
    const fs = require("fs"); let r = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); if (Array.isArray(r)) r = r.filter(x => x.type === "result").pop() || {};
    const u = r.usage || {};
    // side, run, input, cache-new, cache-read, output, seconds, turns, usd, fixed
    console.log([process.argv[2], process.argv[3], u.input_tokens || 0, u.cache_creation_input_tokens || 0, u.cache_read_input_tokens || 0, u.output_tokens || 0,
      ((r.duration_ms || 0) / 1000).toFixed(1), r.num_turns || 0, (r.total_cost_usd || 0).toFixed(4), process.argv[4]].join("\t"));
  ' "$d/.ab-result.json" "$side" "$n" "$pass" 2>/dev/null || printf '%s\t%s\t0\t0\t0\t0\t0\t0\t0\t%s\n' "$side" "$n" "$pass"
}
agent() {
  setup_area "$1"; local runs="${2:-5}" model="${3:-haiku}" rows="$OUT/$AREA-agent.tsv" n
  : > "$rows"
  # alternate the arms so drift over time (API load, caches) hits both the same
  for n in $(seq 1 "$runs"); do agent_one without "$n" "$model" >> "$rows"; agent_one with "$n" "$model" >> "$rows"; done
  echo "== $AREA: agent A/B, $model, $runs runs per arm"
  printf '%-8s %3s %7s %10s %11s %7s %8s %5s %8s %5s\n' side run input cache-new cache-read output seconds turns usd fixed
  awk -F'\t' '{ printf "%-8s %3s %7s %10s %11s %7s %8s %5s %8s %5s\n", $1,$2,$3,$4,$5,$6,$7,$8,$9,$10 }' "$rows"
  agent_summary "$rows"
}
# mean and sample standard deviation per arm; tokens = input + cache-new + cache-read + output
agent_summary() {
  echo "--- mean ± sd per run"
  awk -F'\t' '{ k = $1; n[k]++; t = $3+$4+$5+$6; T[k] += t; TT[k] += t*t; O[k] += $6; OO[k] += $6*$6; S[k] += $7; SS[k] += $7*$7; U[k] += $9; UU[k] += $9*$9; R[k] += $8; if ($10 == "yes") f[k]++ }
    function sd(s, ss, m) { return m > 1 ? sqrt((ss - s*s/m) / (m - 1)) : 0 }
    END { printf "%-8s %4s %18s %14s %14s %18s %6s %6s\n", "side", "runs", "tokens", "output", "seconds", "usd", "turns", "fixed"
      for (k in n) printf "%-8s %4d %9.0f ± %6.0f %6.0f ± %5.0f %6.1f ± %5.1f %8.4f ± %7.4f %6.1f %3d/%d\n", k, n[k], T[k]/n[k], sd(T[k], TT[k], n[k]), O[k]/n[k], sd(O[k], OO[k], n[k]),
        S[k]/n[k], sd(S[k], SS[k], n[k]), U[k]/n[k], sd(U[k], UU[k], n[k]), R[k]/n[k], f[k], n[k] }' "$1"
}

case "${1:-}" in
  measure) measure "${2:?web or py}";;
  tokens) tokens "${2:?web or py}" "${3:-haiku}";;
  agent) agent "${2:?web or py}" "${3:-5}" "${4:-haiku}";;
  summary) agent_summary "${2:?agent tsv}";;
  *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2;;
esac
echo "raw: $OUT"
