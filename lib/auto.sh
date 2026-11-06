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
  # Every Agent call passes here: the task paths are cut out with builtins (grep -o and tr were two process starts each call).
  # Only a call that names a task file asks git for its common dir.
  local p name root common rest="$1" bs='\' first line re='[^" '$'\n'']*\.warmd[\\/]+tasks[\\/]+[A-Za-z0-9_.-]+\.md' cdre='.*cd "([^"]*)"'
  while [[ $rest =~ $re ]]; do
    p="${BASH_REMATCH[0]}"; rest="${rest#*"$p"}"
    p="${p//"$bs"//}"; while [[ $p == *//* ]]; do p="${p//\/\//\/}"; done
    name="${p##*/}"; name="${name%.md}"; root="${p%/.warmd/tasks/*}"
    common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || continue
    [ -e "$common/warmd-auto/paused/$name" ] && rm -f "$common/warmd-auto/paused/$name"   # auto_dir without a subshell
    # a fresh agent on a task that went to a human: the old ESCALATE line no longer stands
    if [ -s "$common/warmd-auto/queue" ]; then
      local ql qk=""; while IFS= read -r ql || [ -n "$ql" ]; do [[ $ql == "ESCALATE $name:"* ]] || qk="$qk$ql"$'\n'; done < "$common/warmd-auto/queue"
      printf '%s' "$qk" > "$common/warmd-auto/queue"
    fi
    # the task runs again (escalation, handoff, restart): its worktree is no longer finished for warmd watch
    local wt=""; first=""; { IFS= read -r first < "$p"; } 2>/dev/null; [[ $first =~ $cdre ]] && wt="${BASH_REMATCH[1]}"
    if [ -n "$wt" ] && [ -f "$common/warmd-batch-done" ]; then
      declare -F wt_norm >/dev/null || . "$WARMD_HOME/lib/team.sh"
      local w d keep=""; w="$(wt_norm "$wt")"
      while IFS= read -r d; do [ "$(wt_norm "${d%%$'\t'*}")" = "$w" ] || keep="$keep$d"$'\n'; done < "$common/warmd-batch-done"
      printf '%s' "$keep" > "$common/warmd-batch-done"
    fi
  done
  return 0
}

# ---- queue: lines for the session, printed by warmd watch ----
auto_queue() { mkdir -p "$(auto_dir "$1")" && printf '%s\n' "$2" >> "$(auto_dir "$1")/queue"; }   # common line
# An AGENT line for a task whose old agent still works stays queued: its warmd run is active or waits, or its own
# transcript grew in the last AUTO_HOLD minutes (an agent that ended its turn for a background run continues by itself).
# Two agents in one worktree cost more than a late line.
auto_drain() { # common -> prints the lines that may go and keeps the held ones, 1 when nothing goes
  local q line name out="" keep=""; q="$(auto_dir "$1")/queue"
  [ -s "$q" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "AGENT "*:*) name="${line#AGENT }"; name="${name%%:*}"; auto_busy "$1" "$name" && { keep="$keep$line"$'\n'; continue; };; esac
    out="$out$line"$'\n'
  done < "$q"
  printf '%s' "$keep" > "$q"
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}
auto_busy() { # common name
  local tf wt root="${WARMD_TRANSCRIPTS:-$HOME/.claude/projects}"
  tf="$(sed -n 1p "$1/warmd-handoff/$2.task" 2>/dev/null | tr -d '\r')"
  wt="$(sed -n '1s/.*cd "\([^"]*\)".*/\1/p' "$tf" 2>/dev/null)"
  [ -n "$wt" ] && [ -d "$wt" ] && wt_run_active "$wt" && return 0
  [ -d "$root" ] && find "$root" -path '*/subagents/*' -name '*.jsonl' -mmin "-${AUTO_HOLD:-2}" -exec grep -lF "tasks/$2.md" {} + 2>/dev/null | grep -q .
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

# Did the last run in this worktree end while it waited in a queue? Then a failed or escalated stop is no failure of the model.
auto_queued() { # worktree
  local d; for d in "$1/.warmd/run" "$1"/*/.warmd/run; do [ -f "$d/queued" ] && return 0; done
  return 1
}

auto_stop() { # common name worktree outcome
  local common="$1" name="$2" wt="$3" outcome="$4" m tf proj out
  m="$(auto_dir "$common")/paused/$name"
  # Waiting for a slot is no failure: the task stays open like a handoff, the same tier continues
  case "$outcome" in failed|escalated) auto_queued "$wt" && { auto_pause "$common" "$name"; echo handoff; return 0; };; esac
  [ "$outcome" = ok ] && auto_red "$wt" && outcome=failed
  [ "$outcome" = failed ] && auto_queued "$wt" && { auto_pause "$common" "$name"; echo handoff; return 0; }
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
auto_esc() { auto_esc_r "$1"; printf '%s' "$REPLY"; }
auto_esc_r() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; REPLY="${s//$'\n'/ }"; }
auto_deny() { auto_esc_r "$1"; printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$REPLY"; }
# REPLY = the file's text without its trailing newlines, like "$(cat file)" but without a process start
auto_slurp() { REPLY=""; { IFS= read -r -d '' REPLY < "$1"; } 2>/dev/null; while [[ $REPLY == *$'\n' ]]; do REPLY="${REPLY%$'\n'}"; done; }
# The context check every AUTO_EVERY seconds: the transcript goes to python, one subshell and one python start
auto_transcript() { # transcript -> REPLY = the TSV line of HOOK_PY_TRANSCRIPT, 1 when it found no warmd task
  local py r; hook_py_r || return 1; py="$REPLY"; auto_esc_r "$1"
  r="$("$py" -c "$HOOK_PY_TRANSCRIPT" 2>/dev/null <<< "{\"agent_transcript_path\":\"$REPLY\"}")" || { REPLY=""; return 1; }
  REPLY="$r"
}

# PreToolUse fast path: a builtin time check, python at most once a minute per agent. Prints the deny and returns 0 when the agent must end.
# After the limit an agent may still save and hand over what it found and record its end: warmd handoff, note and finish,
# git add, commit and push pass, also after a cd and with tail or head behind a pipe. Every part of the command has to be
# one of these: "git commit -m x && warmd test" stays blocked. Builtins only, the command is split outside of quotes.
auto_allowed() { # hook JSON
  local re='"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"' cmd seg="" c q="" i n bs='\'
  [[ $1 =~ $re ]] || return 1
  cmd="${BASH_REMATCH[1]}"; cmd="${cmd//"$bs"n/;}"; cmd="${cmd//"$bs$bs"/$bs}"; cmd="${cmd//"$bs"\"/\"}"
  n=${#cmd}
  for (( i = 0; i <= n; i++ )); do
    c="${cmd:i:1}"
    if [ $i -lt $n ] && { [ -n "$q" ] || [[ $c != [\;\&\|] ]] || { [ "$c" = '&' ] && [[ ${cmd:i-1:1} == '>' || ${cmd:i+1:1} == '>' ]]; }; }; then   # 2>&1 and &> are no separators
      if [ -z "$q" ] && [[ $c == [\"\'] ]]; then q="$c"; elif [ "$c" = "$q" ]; then q=""; fi
      seg="$seg$c"; continue
    fi
    auto_allowed_part "$seg" || return 1; seg=""
  done
  return 0
}
auto_allowed_part() { # one command of a chain
  local s="$1" w='[^[:space:]]+'
  while [[ $s == [[:space:]]* ]]; do s="${s#?}"; done
  while [[ $s =~ ^[A-Za-z_][A-Za-z0-9_]*=$w[[:space:]]+(.*)$ ]]; do s="${BASH_REMATCH[1]}"; done   # VAR=x before the command
  [ -z "${s//[[:space:]]/}" ] && return 0   # the empty part between && or after the last ;
  [[ $s =~ ^([^[:space:]]*[/\\])?warmd(\.cmd)?[[:space:]]+(handoff|finish|note)([[:space:]]|$) ]] && return 0
  [[ $s =~ ^git([[:space:]]+-C[[:space:]]+$w)?[[:space:]]+(add|commit|push)([[:space:]]|$) ]] && return 0
  [[ $s =~ ^(cd|tail|head|echo|true)([[:space:]]|$) ]]
}
auto_pre() { # hook JSON
  local in="$1" tp key d now last=0 r name tf tok calls budget="" pct line bre='^Budget: under ([0-9]*)k'
  auto_json_tp "$in" || return 1; tp="$REPLY"
  d="${CACHE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/warmd}/auto"; key="${tp##*/}"; key="${key%.jsonl}"   # auto_cache without a subshell
  [ -f "$d/$key.pending" ] && { auto_allowed "$in" && return 1; auto_slurp "$d/$key.pending"; auto_deny "$REPLY"; return 0; }
  [ -f "$d/$key.done" ] && return 1
  printf -v now '%(%s)T' -1
  [ -f "$d/$key.t" ] && read -r last < "$d/$key.t"
  [ $(( now - ${last:-0} )) -ge "$AUTO_EVERY" ] || return 1
  { [ -d "$d" ] || mkdir -p "$d"; } && echo "$now" > "$d/$key.t"
  auto_transcript "$tp" || return 1; r="$REPLY"
  IFS='	' read -r name tf _ calls _ tok <<< "$r"   # tok: context fill of the last turn, not the cost over all turns
  [ -f "$tf" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do [[ $line =~ $bre ]] && { budget="${BASH_REMATCH[1]}"; break; }; done < "$tf"
  budget=$(( ${budget:-0} * 1000 ))
  [ "$budget" -gt 0 ] && [ "$tok" != - ] && pct=$(( tok * 100 / budget )) || pct=0
  if [ "$pct" -ge "$AUTO_PCT" ]; then auto_save "$name" "$tf" "$key" "$pct% of the ${budget%000}k budget"
  elif [ "${calls:-0}" -ge "$AUTO_CALLS" ]; then auto_save "$name" "$tf" "$key" "$calls tool calls"
  else return 1; fi
  [ -f "$d/$key.pending" ] && { auto_allowed "$in" && return 1; auto_slurp "$d/$key.pending"; auto_deny "$REPLY"; return 0; }
  return 1
}

# PreCompact: the context is full. Save now, the agent's next Bash call gets the deny.
auto_compact() { # hook JSON on stdin
  local in="" r name tf key; IFS= read -r -d '' in || true
  auto_json_tp "$in" || return 0
  key="${REPLY##*/}"; key="${key%.jsonl}"
  [ -f "${CACHE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/warmd}/auto/$key.done" ] && return 0
  auto_transcript "$REPLY" || return 0; r="$REPLY"
  IFS='	' read -r name tf _ <<< "$r"
  [ -f "$tf" ] || return 0
  auto_save "$name" "$tf" "$key" "compaction" >/dev/null
  return 0
}

# Engine leftovers never ride along in an automatic commit: Unity's InitTestScene of a run that died, a new test result XML
# next to ProjectSettings, packages-lock.json without a change to its manifest.json, warmd's own Assets/Editor/Warmd and the
# .sln, .slnx and .csproj files Unity writes into a project root. They leave the index, the files stay.
auto_unjunk() { # worktree
  local f dir c k v o outs=""
  # world_outputs in the project's warmd.conf: generated parts go in with the merge gate only, never in a WIP commit
  for c in "$1/warmd.conf" "$1"/*/warmd.conf; do
    [ -f "$c" ] || continue; dir="${c%/warmd.conf}"; dir="${dir#"$1"}"; dir="${dir#/}"
    while IFS='=' read -r k v || [ -n "$k" ]; do
      [ "${k//[[:space:]]/}" = world_outputs ] || continue
      v="${v%$'\r'}"; for o in ${v//,/ }; do outs="$outs ${dir:+$dir/}${o%/}"; done
    done < "$c"
  done
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    for o in $outs; do case "$f" in "$o"|"$o"/*) git -C "$1" reset -q -- "$f" 2>/dev/null; continue 2;; esac; done
    case "$f" in
      *InitTestScene*.unity|*InitTestScene*.unity.meta) ;;
      *.xml) dir="${f%/*}"; [ "$dir" = "$f" ] && dir=.
        [ -f "$1/$dir/ProjectSettings/ProjectVersion.txt" ] || continue
        git -C "$1" cat-file -e "HEAD:$f" 2>/dev/null && continue;;   # tracked before: real content
      *packages-lock.json) git -C "$1" diff --cached --quiet -- "${f%packages-lock.json}manifest.json" 2>/dev/null || continue;;
      # warmd's own daemon (warmd init and every run copy it) and the solution files Unity writes: never a task's work
      Assets/Editor/Warmd/*|*/Assets/Editor/Warmd/*) dir="${f%Assets/Editor/Warmd/*}"; [ -f "$1/${dir}ProjectSettings/ProjectVersion.txt" ] || continue;;
      *.sln|*.slnx|*.csproj) dir="${f%/*}"; [ "$dir" = "$f" ] && dir=.
        [ -f "$1/$dir/ProjectSettings/ProjectVersion.txt" ] || continue;;
      *) continue;;
    esac
    git -C "$1" reset -q -- "$f" 2>/dev/null
  done < <(git -C "$1" diff --cached --name-only 2>/dev/null | tr -d '\r')
}

# Commit what is there, write the handoff note, keep the deny message for this transcript. Once per transcript.
auto_save() { # name taskfile key reason
  local name="$1" tf="$2" key="$3" why="$4" wt d out line
  d="${CACHE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/warmd}/auto"; [ -d "$d" ] || mkdir -p "$d"; : > "$d/$key.done"
  hook_task_wt "$tf" && wt="$REPLY" && [ -d "$wt" ] || return 1
  # -A: a new file the agent never added belongs to the work too; .gitignore keeps build output out
  git -C "$wt" add -A 2>/dev/null
  auto_unjunk "$wt"
  git -C "$wt" diff --cached --quiet 2>/dev/null || git -C "$wt" commit -qm "WIP $name: automatic handoff at $why" ${WARMD_TRAILER:+-m "$WARMD_TRAILER"} 2>/dev/null
  out="$(cd "$wt" && bash "$WARMD_HOME/bin/warmd" handoff "$name" "Automatic handoff at $why. The work so far is in the commits below." "Check the commits against Done when and finish what is left." 2>&1)"
  line="$(printf '%s\n' "$out" | grep "^AGENT $name:" | tail -1)"
  if [ -n "$line" ]; then
    echo "Context at $why: warmd saved your work and wrote the handoff. Only these still run: git add, commit and push, warmd handoff $name \"what you found\" \"what is next\" and warmd finish. Then stop and end your answer with this line: $line" > "$d/$key.pending"
  else
    echo "Context at $why and the automatic handoff failed: $(printf '%s' "$out" | tail -1 | cut -c1-160). Commit, then end with ESCALATE: context full" > "$d/$key.pending"
  fi
  echo "$line"
}
