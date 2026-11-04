# Cost ledger: what each task really cost, per tier and outcome. Rows are measured values only, never estimates.
# One row per task and tier: time, task, tier, area, tokens, calls, seconds, outcome. Tokens and calls are "-" when nobody passed them.
# The file lives in the common git dir, so every worktree writes to the same one and it is never committed.

ledger_file() { echo "$(git -C "$PROJECT" rev-parse --path-format=absolute --git-common-dir)/warmd-ledger.tsv"; }

# Task files are written by warmd split in the main checkout, not in the task's worktree
ledger_taskdir() {
  local main rel; main="$(git -C "$GIT_ROOT" worktree list --porcelain | sed -n '1s/^worktree //p')"; rel="$(rel_project)"
  if [ -d "$main${rel:+/$rel}/.warmd/tasks" ]; then echo "$main${rel:+/$rel}/.warmd/tasks"; else echo "$STATE/tasks"; fi
}

ledger_record() { # task tier area tokens calls secs outcome
  local f; f="$(ledger_file)"
  [ -f "$f" ] && { grep -v "^[^	]*	$1	$2	" "$f" > "$f.tmp" 2>/dev/null; mv "$f.tmp" "$f"; }
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$3" "$4" "$5" "$6" "$7" >> "$f"
}

# Called by warmd finish. Options: --tokens N --calls N --outcome ok|escalated|failed. Env: WARMD_TOKENS, WARMD_CALLS.
ledger_finish() {
  local tokens="${WARMD_TOKENS:--}" calls="${WARMD_CALLS:--}" outcome=ok name td tf tier area secs start
  while [ $# -gt 0 ]; do
    case "$1" in
      --tokens) tokens="${2:--}"; shift;;
      --calls) calls="${2:--}"; shift;;
      --outcome) outcome="${2:-ok}"; shift;;
    esac
    shift
  done
  case "$tokens$calls" in *[!0-9-]*) echo "FAIL tokens and calls are numbers"; return 2;; esac
  case "$outcome" in ok|escalated|failed) ;; *) echo "FAIL outcome is ok, escalated or failed"; return 2;; esac
  name="$(git -C "$GIT_ROOT" branch --show-current)"; name="${name#warmd/}"
  td="$(ledger_taskdir)"; tf="$td/$name.md"
  [ -f "$tf" ] || return 0
  tier="$(cat "$td/$name.tier" 2>/dev/null || echo mid)"
  area="$(area_of "$(sed -n 's/^Files you own: //p' "$tf")")"
  start="$(git -C "$GIT_ROOT" log -1 --format=%ct "$(base_branch)" 2>/dev/null)"
  start="$(stat -c %Y "$tf" 2>/dev/null || stat -f %m "$tf" 2>/dev/null || echo "${start:-0}")"
  secs=$(( $(date +%s) - start ))
  ledger_record "$name" "$tier" "${area:-none}" "$tokens" "$calls" "$secs" "$outcome"
}

# Per tier: tasks, outcomes, tokens (only rows that have them), seconds. Then what escalation threw away.
ledger_report() {
  local f; f="$(ledger_file)"; [ -n "${1:-}" ] && f="$1"
  [ -s "$f" ] || { echo "no ledger yet, warmd finish writes it"; return 0; }
  awk -F'\t' '
    { t=$3; n[t]++; if($8=="ok")ok[t]++; else if($8=="escalated")es[t]++; else fl[t]++
      if($5!="-"){tok[t]+=$5; nt[t]++; if($8=="escalated"){wt+=$5; wn++}}
      if($6!="-")cl[t]+=$6; sc[t]+=$7 }
    END {
      printf "%-6s %5s %4s %5s %9s %9s %6s %7s\n","tier","tasks","ok","esc","tokens","tok/task","calls","secs"
      split("cheap mid top",o," ")
      for(i=1;i<=3;i++){t=o[i]; if(!n[t])continue
        printf "%-6s %5d %4d %5d %9d %9s %6d %7d\n",t,n[t],ok[t],es[t]+fl[t],tok[t],(nt[t]?int(tok[t]/nt[t]):"-"),cl[t],sc[t]
        if(nt[t]<n[t]) gap=gap sprintf("%s%s %d of %d", (gap==""?"":", "), t, nt[t], n[t])}
      if(gap!="") printf "tokens known for %s tasks, tok/task averages only those (finish --tokens N records them)\n",gap
      printf "escalation wasted: %d tokens in %d attempts\n",wt,wn
    }' "$f"
}

# Routing input: "<tasks> <escalated>" for an area at a tier
ledger_rate() { # area tier
  local f; f="$(ledger_file)"; [ -s "$f" ] || { echo "0 0"; return; }
  awk -F'\t' -v a="$1" -v t="$2" '$4==a && $3==t {n++; if($8!="ok")e++} END{print n+0, e+0}' "$f"
}
