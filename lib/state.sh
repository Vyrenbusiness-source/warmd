# warmd state: is warmd working here right now? One line for people, one JSON line for the VS Code status bar (vscode/).
# Read from the signals warmd already leaves: run marks (.warmd/run/active/<pid>), the merge lock (.warmd/merge.owner),
# the CI wait (.warmd/ci.wait), the batch marker (<git-common-dir>/warmd-batch) and the run log (.warmd/run/runs.log).
reg state "warmd state [--json]         active or idle here: run, merge, CI wait, batch with its agents, last result" state_main

state_main() {
  local json=0; [ "${1:-}" = --json ] && json=1
  detect_project
  local common=""; [ -n "$GIT_ROOT" ] && common="$(git -C "$PROJECT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  state_read "$STATE" "$common"
  if [ $json = 1 ]; then state_json; return 0; fi
  if [ "$ST_ACTIVE" = true ]; then
    echo "ACTIVE $ST_WHAT${ST_AGENTS:+, $ST_AGENTS agents}${ST_LINE:+ | last: $ST_LINE}"
  else
    echo "IDLE${ST_LINE:+ | last: $ST_LINE}"
  fi
}

# mtime in epoch seconds, GNU date first (Git Bash, Linux), BSD stat on macOS
state_mtime() { date -r "$1" +%s 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

# state_read <state dir> <git common dir or empty>: sets ST_ACTIVE (true|false), ST_WHAT, ST_AGENTS, ST_SINCE, ST_LAST, ST_LINE.
# The most specific signal wins: a run of this project, then a merge, a CI wait, the batch, idle.
state_read() {
  local st="$1" common="$2" r f pid c wt n=0 ts sha rc cmd filt last=""
  ST_ACTIVE=false; ST_WHAT=idle; ST_AGENTS=0; ST_SINCE=""; ST_LAST=""; ST_LINE=""
  # Agents of the batch: worktrees in the marker whose agent has not stopped (lib/team.sh wt_finished). A stale marker
  # (240 minutes, no sign of life from warmd watch) counts as no batch, the same rule as batch_guard.
  if [ -n "$common" ] && [ -f "$common/warmd-batch" ]; then
    f="$common/warmd-batch"
    if [ -z "$(find "$f" -mmin +240 2>/dev/null)" ] || { [ -f "$f-alive" ] && [ -z "$(find "$f-alive" -mmin +240 2>/dev/null)" ]; }; then
      while IFS= read -r wt || [ -n "$wt" ]; do
        wt="${wt%$'\r'}"; [ -n "$wt" ] && [ -d "$wt" ] || continue
        wt_finished "$common" "$wt" && continue
        n=$((n + 1))
      done < "$f"
    fi
  fi
  ST_AGENTS=$n
  if r="$(run_active "$st")"; then
    c="${r#* }"; c="${c%% *}"
    ST_ACTIVE=true; ST_WHAT="$c"
    ST_SINCE="$(state_mtime "$st/run/active/${r%% *}")"
  elif pid="$(cat "$st/merge.owner" 2>/dev/null)" && [ -n "$pid" ] && { shell_alive "$pid" || pid_alive "$(cat "$st/merge.owner.win" 2>/dev/null)"; }; then
    ST_ACTIVE=true; ST_WHAT=merge; ST_SINCE="$(state_mtime "$st/merge.owner")"
  elif f="$st/ci.wait"; [ -f "$f" ] || f="${GIT_ROOT:-$st/..}/.warmd/ci.wait"   # warmd ci marks the git root (lib/ship.sh)
       [ -f "$f" ] && read -r pid _ ts _ < "$f" && shell_alive "$pid"; then
    ST_ACTIVE=true; ST_WHAT=ci-wait; ST_SINCE="${ts:-$(state_mtime "$f")}"
  elif [ $n -gt 0 ]; then
    ST_ACTIVE=true; ST_WHAT=batch; ST_SINCE="$(state_mtime "$common/warmd-batch")"
  fi
  # Last result: the newest line of runs.log (time, commit, exit code, command, filter), written by every test and check
  if [ -f "$st/run/runs.log" ]; then
    while IFS= read -r f || [ -n "$f" ]; do [ -n "$f" ] && last="$f"; done < "$st/run/runs.log"
  fi
  if [ -n "$last" ]; then
    IFS=$'\t' read -r ts sha rc cmd filt <<< "${last%$'\r'}"
    if [ "$rc" = 0 ]; then ST_LAST=green; else ST_LAST=red; fi
    ST_LINE="$cmd ${filt:-all} $ST_LAST at $ts ($sha)"
  fi
  return 0
}

state_esc() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/ }"; printf '%s' "$s"; }
state_json() {
  printf '{"active":%s,"what":"%s","agents":%s,"since":%s,"last":"%s","line":"%s"}\n' \
    "$ST_ACTIVE" "$(state_esc "$ST_WHAT")" "${ST_AGENTS:-0}" "${ST_SINCE:-0}" "$ST_LAST" "$(state_esc "$ST_LINE")"
}
