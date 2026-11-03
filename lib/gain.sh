# warmd gain: what your Claude Code sessions really used, read from the transcripts on disk.
# Measured values only. Dollars come from the price table below, or from a file you point at.
# No network, nothing leaves the machine.

# Price table: USD per million tokens. A row applies to every model id that contains the pattern.
# Columns: pattern, input, cache write (5 min), cache read, output. Longest pattern wins.
# Override: WARMD_PRICES=<file> or ~/.config/warmd/prices.tsv with the same columns (tab separated).
# Source: https://platform.claude.com/docs/en/about-claude/pricing (checked 2026-11-02).
gain_price_table() {
  local f="${WARMD_PRICES:-${XDG_CONFIG_HOME:-$HOME/.config}/warmd/prices.tsv}"
  if [ -f "$f" ]; then cat "$f"; return; fi
  cat <<'TABLE'
haiku-5-5	0.10	0.125	0.01	0.50
sonnet-5-5	2	2.50	0.10	10
opus-5-5	4	5	0.20	20
haiku-4-5	1	1.25	0.10	5
sonnet-4-6	3	3.75	0.30	15
opus-4-8	5	6.25	0.50	25
opus-4-7	5	6.25	0.50	25
opus-4-6	5	6.25	0.50	25
opus-4-5	5	6.25	0.50	25
TABLE
}

gain_slug() { printf '%s' "$(native_path "${GIT_ROOT:-$PROJECT}")" | sed 's/[^A-Za-z0-9]/-/g'; }

# gain_rows <file>...: one TSV row per transcript: session, model, input, cache_write, cache_read, output, messages.
# Each API message appears once per content block in the transcript, so rows are deduplicated by message id.
gain_rows() {
  local f
  for f in "$@"; do
    awk -v sess="$(basename "$f" .jsonl)" '
      function num(s, key,   m) { if (match(s, "\"" key "\":[0-9]+")) { m = substr(s, RSTART, RLENGTH); sub(/.*:/, "", m); return m + 0 } return 0 }
      /"type":"assistant"/ && /"usage":\{/ {
        id = ""; mod = "unknown"
        if (match($0, /"message":\{"model":"[^"]*"/)) { mod = substr($0, RSTART, RLENGTH); sub(/.*"model":"/, "", mod); sub(/"$/, "", mod) }
        if (match($0, /"id":"msg_[A-Za-z0-9_]*"/)) { id = substr($0, RSTART, RLENGTH); sub(/.*:"/, "", id); sub(/"$/, "", id) }
        if (id == "") id = "line" NR
        u = substr($0, index($0, "\"usage\":{"))
        M[id] = mod; I[id] = num(u, "input_tokens"); W[id] = num(u, "cache_creation_input_tokens")
        R[id] = num(u, "cache_read_input_tokens"); O[id] = num(u, "output_tokens")
      }
      END {
        for (id in M) { k = M[id]; i[k] += I[id]; w[k] += W[id]; r[k] += R[id]; o[k] += O[id]; n[k]++ }
        for (k in n) printf "%s\t%s\t%d\t%d\t%d\t%d\t%d\n", sess, k, i[k], w[k], r[k], o[k], n[k]
      }' "$f"
  done
}

# gain_report: rows on stdin; prints per session and total. Dollars use the price table.
gain_report() {
  local prices; prices="$(gain_price_table)"
  awk -F'\t' -v prices="$prices" '
    BEGIN {
      np = split(prices, L, "\n")
      for (j = 1; j <= np; j++) { if (L[j] == "" || L[j] ~ /^#/) continue; split(L[j], c, "\t"); P[c[1]] = c[2] "\t" c[3] "\t" c[4] "\t" c[5] }
    }
    {
      s = $1; m = $2; best = ""
      for (p in P) if (index(m, p) && length(p) > length(best)) best = p
      split(best == "" ? "" : P[best], q, "\t")
      usd = 0; save = 0
      if (best != "") { usd = ($3 * q[1] + $4 * q[2] + $5 * q[3] + $6 * q[4]) / 1e6; save = $5 * (q[1] - q[3]) / 1e6 } else unp[s] = 1
      if (!(s in seen)) { seen[s] = 1; order[++ns] = s }
      I[s] += $3; W[s] += $4; R[s] += $5; O[s] += $6; N[s] += $7; D[s] += usd; V[s] += save
      mt[m] += $3 + $4 + $5 + $6
      ti += $3; tw += $4; tr += $5; to += $6; tn += $7; td += usd; tv += save
      if (best == "") bad = bad (bad == "" ? "" : ", ") m
    }
    function hit(i, w, r) { return (i + w + r) > 0 ? 100 * r / (i + w + r) : 0 }
    END {
      if (ns == 0) { print "no sessions with usage data found"; exit 1 }
      printf "%-10s %5s %10s %10s %11s %9s %6s %9s\n", "session", "calls", "input", "cache-new", "cache-read", "output", "hit%", "usd"
      for (j = 1; j <= ns; j++) { s = order[j]; printf "%-10s %5d %10d %10d %11d %9d %5.1f%% %9.2f%s\n", substr(s, 1, 8), N[s], I[s], W[s], R[s], O[s], hit(I[s], W[s], R[s]), D[s], (s in unp) ? " *" : "" }
      printf "%-10s %5d %10d %10d %11d %9d %5.1f%% %9.2f\n", "total", tn, ti, tw, tr, to, hit(ti, tw, tr), td
      printf "cache saved %.2f usd versus paying the input price for every cache-read token\n", tv
      if (bad != "") printf "* no price for: %s (tokens counted, dollars not). Add a row to the price table.\n", bad
    }' 
}

# warmd gain [--all] [--last N] [file.jsonl ...]
gain_run() {
  local all=0 last=15 dir f; local -a files=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --all) all=1;;
      --last) last="${2:-15}"; shift;;
      -h|--help) echo "usage: warmd gain [--all] [--last N] [transcript.jsonl ...]"; return 0;;
      *) files+=("$1");;
    esac
    shift
  done
  if [ ${#files[@]} -eq 0 ]; then
    if [ "$all" = 1 ]; then dir="$HOME/.claude/projects"; else dir="$HOME/.claude/projects/$(gain_slug)"; fi
    [ -d "$dir" ] || { echo "no transcripts in $dir"; return 1; }
    while IFS= read -r f; do files+=("$f"); done < <(find "$dir" -name '*.jsonl' -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n "$last" | cut -d' ' -f2-)
  fi
  [ ${#files[@]} -gt 0 ] || { echo "no transcripts found"; return 1; }
  gain_rows "${files[@]}" | gain_report
}
