# Automatics nobody has to type. Called from the hooks in lib/hook.sh and from warmd watch.
#   Failed or red stop  the task goes to the next model tier with its earlier commits as context (warmd escalate),
#                       the AGENT line waits in a queue that warmd watch prints, so the session starts the next attempt
#   Context full        past 70% of the budget, 60 tool calls or a compaction: work committed, warmd handoff written,
#                       the agent's next Bash call is denied with the AGENT line it has to end with
#   Paused              an agent that stopped leaves a marker, warmd watch skips its worktree until it moves again
# State lives in the common git dir (warmd-auto), so every worktree and the shared checkout see the same files.
# Per-transcript stamps live in the cache: the PreToolUse fast path needs no git and no python.
AUTO_PCT="${AUTO_PCT:-70}"         # handoff past this share of the task's token budget
AUTO_CALLS="${AUTO_CALLS:-60}"     # or past this many tool calls
AUTO_EVERY="${AUTO_EVERY:-60}"     # seconds between two context checks of one agent
AUTO_DUP="${AUTO_DUP:-1}"          # minutes: a second stop of the same task within this time is the same stop

auto_dir() { echo "$1/warmd-auto"; }   # common dir
auto_cache() { echo "${CACHE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/warmd}/auto"; }

# ---- paused tasks ----
auto_pause() { mkdir -p "$(auto_dir "$1")/paused" && : > "$(auto_dir "$1")/paused/$2"; }   # common name
# Paused: the marker exists and nothing in the worktree changed after it. Movement means a new agent works there: marker gone.
auto_paused() { # common name worktree
  local m; m="$(auto_dir "$1")/paused/$2"
  [ -f "$m" ] || return 1
  local mt ct; mt="$(date -r "$m" +%s 2>/dev/null || echo 0)"; ct="$(git -C "$3" log -1 --format=%ct 2>/dev/null || echo 0)"
  if [ "$ct" -gt "$mt" ] || [ -n "$(find "$3" -type f -newer "$m" -not -path "$3/.git/*" -not -path "$3/*/.git/*" -not -path "$3/.warmd/*" -not -path "$3/*/.warmd/*" -not -path "$3/Library/*" -not -path "$3/*/Library/*" -not -path "$3/Temp/*" -not -path "$3/*/Temp/*" -not -path "$3/Logs/*" -not -path "$3/*/Logs/*" -not -path "$3/obj/*" -not -path "$3/*/obj/*" -not -path "$3/node_modules/*" -not -path "$3/*/node_modules/*" 2>/dev/null | head -1)" ]; then
    rm -f "$m"; return 1
  fi
  return 0
}

# An Agent call whose prompt names .warmd/tasks/<name>.md starts a new agent on that task: its pause marker goes now.
# Waiting for the worktree to move is not enough, a fresh agent that still reads counts as paused and warmd watch ends.
auto_agent_start() { # hook JSON -> 0 when it was an Agent call
  [[ $1 =~ \"tool_name\"[[:space:]]*:[[:space:]]*\"(Agent|Task)\" ]] || return 1
  local p name root common
  while IFS= read -r p; do
    p="$(printf '%s' "$p" | tr -s '\\' '/')"
    name="${p##*/}"; name="${name%.md}"; root="${p%/.warmd/tasks/*}"
    common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || continue
    rm -f "$(auto_dir "$common")/paused/$name"
  done < <(printf '%s' "$1" | grep -oE '[^" ]*\.warmd[\\/]+tasks[\\/]+[A-Za-z0-9_.-]+\.md')
  return 0
}

# ---- queue: lines for the session, printed by warmd watch ----
auto_queue() { mkdir -p "$(auto_dir "$1")" && printf '%s\n' "$2" >> "$(auto_dir "$1")/queue"; }   # common line
auto_drain() { # common -> prints and empties the queue, 1 when it was empty
  local q; q="$(auto_dir "$1")/queue"
  [ -s "$q" ] || return 1
  cat "$q"; : > "$q"
}

# ---- stop: called from hook-job with the outcome the transcript gave ----
# A red last run turns ok into failed. failed and escalated go one tier up; at the top tier a human gets the task.
# Prints the outcome for the ledger and the batch: escalated while a next attempt is queued, failed at the top.
# Was the last run in this worktree red? The newer of two records decides: last.rc (exit code of the last warmd test or check,
# every adapter) and result.txt (the daemon's last job). Refusals (2 usage, 3 caller gone, 4 merge, 5 batch, 130 cut off) are not red.
auto_red() { # worktree
  local r="$1/.warmd/run" rc
  if [ -f "$r/last.rc" ] && ! [ "$r/result.txt" -nt "$r/last.rc" ]; then
    read -r rc _ < "$r/last.rc" 2>/dev/null; rc="${rc%$'\r'}"
    case "$rc" in ''|0|2|3|4|5|130) return 1;; *) return 0;; esac
  fi
  [ "$(head -1 "$r/result.txt" 2>/dev/null | cut -d' ' -f2 | tr -d '\r')" = FAIL ]
}

auto_stop() { # common name worktree outcome
  local common="$1" name="$2" wt="$3" outcome="$4" m tf proj out
  m="$(auto_dir "$common")/paused/$name"
  [ "$outcome" = ok ] && auto_red "$wt" && outcome=failed
  case "$outcome" in failed|escalated) ;; *) auto_pause "$common" "$name"; echo "$outcome"; return 0;; esac
  # The same stop twice (hook fired twice): no second escalation
  if [ -n "$(find "$m" -maxdepth 0 -mmin "-$AUTO_DUP" 2>/dev/null)" ]; then echo escalated; return 0; fi
  auto_pause "$common" "$name"
  tf="$(sed -n 1p "$common/warmd-handoff/$name.task" 2>/dev/null | tr -d '\r')"
  [ -f "$tf" ] || { echo "$outcome"; return 0; }
  proj="${tf%/.warmd/tasks/*}"
  out="$(cd "$proj" && bash "$WARMD_HOME/bin/warmd" escalate "$name" 2>&1)"
  case "$out" in
    *"AGENT $name:"*) auto_queue "$common" "$(printf '%s\n' "$out" | grep "^AGENT $name:" | tail -1)"; echo escalated;;
    *) auto_queue "$common" "ESCALATE $name: failed at the top tier, a human has to look at $(git -C "$wt" branch --show-current 2>/dev/null)"; echo failed;;
  esac
}

# ---- context: past the budget share or at a compaction, save and hand off ----
auto_json_tp() { # hook JSON -> REPLY = the agent's own transcript (subagent file when the hook names one)
  REPLY=""; local in="$1" tp re='"(agent_transcript_path|transcript_path)" *: *"([^"]+)"' id='"agent_id" *: *"([A-Za-z0-9_-]+)"'
  [[ $in =~ $re ]] || return 1
  tp="${BASH_REMATCH[2]//\\\\//}"
  if [ "${BASH_REMATCH[1]}" = transcript_path ] && [[ $in =~ $id ]] && [ -f "${tp%.jsonl}/subagents/agent-${BASH_REMATCH[1]}.jsonl" ]; then
    tp="${tp%.jsonl}/subagents/agent-${BASH_REMATCH[1]}.jsonl"
  fi
  [ -f "$tp" ] || return 1
  REPLY="$tp"
}
auto_esc() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "${s//$'\n'/ }"; }
auto_deny() { printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$(auto_esc "$1")"; }

# PreToolUse fast path: a builtin time check, python at most once a minute per agent. Prints the deny and returns 0 when the agent must end.
auto_pre() { # hook JSON
  local in="$1" tp key d now last=0 r name tf tok calls budget pct
  auto_json_tp "$in" || return 1; tp="$REPLY"
  d="$(auto_cache)"; key="${tp##*/}"; key="${key%.jsonl}"
  [ -f "$d/$key.pending" ] && { auto_deny "$(cat "$d/$key.pending")"; return 0; }
  [ -f "$d/$key.done" ] && return 1
  printf -v now '%(%s)T' -1
  [ -f "$d/$key.t" ] && read -r last < "$d/$key.t"
  [ $(( now - ${last:-0} )) -ge "$AUTO_EVERY" ] || return 1
  mkdir -p "$d" && echo "$now" > "$d/$key.t"
  r="$(printf '{"agent_transcript_path":"%s"}' "$(auto_esc "$tp")" | "$(hook_py)" -c "$HOOK_PY_TRANSCRIPT" 2>/dev/null)" || return 1
  IFS='	' read -r name tf _ calls _ tok <<< "$r"   # tok: context fill of the last turn, not the cost over all turns
  [ -f "$tf" ] || return 1
  budget="$(sed -n 's/^Budget: under \([0-9]*\)k.*/\1/p' "$tf")"; budget=$(( ${budget:-0} * 1000 ))
  [ "$budget" -gt 0 ] && [ "$tok" != - ] && pct=$(( tok * 100 / budget )) || pct=0
  if [ "$pct" -ge "$AUTO_PCT" ]; then auto_save "$name" "$tf" "$key" "$pct% of the ${budget%000}k budget"
  elif [ "${calls:-0}" -ge "$AUTO_CALLS" ]; then auto_save "$name" "$tf" "$key" "$calls tool calls"
  else return 1; fi
  [ -f "$d/$key.pending" ] && { auto_deny "$(cat "$d/$key.pending")"; return 0; }
  return 1
}

# PreCompact: the context is full. Save now, the agent's next Bash call gets the deny.
auto_compact() { # hook JSON on stdin
  local in r name tf key; in="$(cat)"
  auto_json_tp "$in" || return 0
  key="${REPLY##*/}"; key="${key%.jsonl}"
  [ -f "$(auto_cache)/$key.done" ] && return 0
  r="$(printf '{"agent_transcript_path":"%s"}' "$(auto_esc "$REPLY")" | "$(hook_py)" -c "$HOOK_PY_TRANSCRIPT" 2>/dev/null)" || return 0
  IFS='	' read -r name tf _ <<< "$r"
  [ -f "$tf" ] || return 0
  auto_save "$name" "$tf" "$key" "compaction" >/dev/null
  return 0
}

# Commit what is there, write the handoff note, keep the deny message for this transcript. Once per transcript.
auto_save() { # name taskfile key reason
  local name="$1" tf="$2" key="$3" why="$4" wt d out line
  d="$(auto_cache)"; mkdir -p "$d"; : > "$d/$key.done"
  hook_task_wt "$tf" && wt="$REPLY" && [ -d "$wt" ] || return 1
  # -A: a new file the agent never added belongs to the work too; .gitignore keeps build output out
  git -C "$wt" add -A 2>/dev/null
  git -C "$wt" diff --cached --quiet 2>/dev/null || git -C "$wt" commit -qm "WIP $name: automatic handoff at $why" ${WARMD_TRAILER:+-m "$WARMD_TRAILER"} 2>/dev/null
  out="$(cd "$wt" && bash "$WARMD_HOME/bin/warmd" handoff "$name" "Automatic handoff at $why. The work so far is in the commits below." "Check the commits against Done when and finish what is left." 2>&1)"
  line="$(printf '%s\n' "$out" | grep "^AGENT $name:" | tail -1)"
  if [ -n "$line" ]; then
    echo "Context at $why: warmd saved your work and wrote the handoff. Stop now, run nothing else, end your answer with this line: $line" > "$d/$key.pending"
  else
    echo "Context at $why and the automatic handoff failed: $(printf '%s' "$out" | tail -1 | cut -c1-160). Commit, then end with ESCALATE: context full" > "$d/$key.pending"
  fi
  echo "$line"
}
