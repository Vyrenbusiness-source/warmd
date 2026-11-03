# Agent work: model routing by tier, cheap first, worktrees for parallel tasks, one-line prompts, safe merge.
# Tiers map to model aliases. Claude Code resolves haiku, sonnet and opus to the newest release, so a new model needs no change here.

route_tier() { # goal files
  local goal="$1" files="${2:-}"
  if [ -z "$files" ] || [ "$files" = none ]; then apply_floor cheap; return; fi
  local tier=mid
  if echo "$goal" | grep -qiE "$CFG_top_words"; then tier=top; fi
  if [ -n "$CFG_top_paths" ] && echo "$files" | grep -qE "$CFG_top_paths"; then tier=top; fi
  # Learned from the ledger: an area where half of the mid attempts needed escalation (two or more tasks) starts at top. Older history.tsv counts still apply.
  if [ "$tier" = mid ]; then
    local area n e; area="$(area_of "$files")"
    read -r n e <<< "$(ledger_rate "$area" mid)"
    [ "${n:-0}" -ge 2 ] && [ $(( ${e:-0} * 2 )) -ge "$n" ] && tier=top
    if [ "$tier" = mid ] && [ -f "$STATE/history.tsv" ]; then
      n="$(grep -c "^escalated	$area$" "$STATE/history.tsv" 2>/dev/null)"
      [ "${n:-0}" -ge 2 ] && tier=top
    fi
  fi
  apply_floor "$tier"
}
# floor in warmd.conf: the lowest tier this project accepts. Quality projects set mid or top, a failed cheap attempt costs more than it saves.
apply_floor() {
  case "$CFG_floor:$1" in
    top:*) echo top;;
    mid:cheap) echo mid;;
    *) echo "$1";;
  esac
}
area_of() { echo "$1" | cut -d, -f1 | sed 's#/[^/]*$##'; }
tier_model() { case "$1" in cheap) echo "$CFG_cheap";; top) echo "$CFG_top";; *) echo "$CFG_mid";; esac; }
tier_budget() { case "$1" in cheap) echo "$CFG_budget_cheap";; top) echo "$CFG_budget_top";; *) echo "$CFG_budget_mid";; esac; }
tier_next() { case "$1" in cheap) echo mid;; mid) echo top;; *) echo "";; esac; }
tier_agent() { case "$1" in cheap) echo warmd-scout;; *) echo warmd-worker;; esac; }
# Editing never runs on the cheap tier, whatever the config says: that tier only reads

route_print() {
  local t; t="$(route_tier "${1:-}" "${2:-}")"
  echo "$t model=$(tier_model "$t") budget=$(tier_budget "$t")k agent=$(tier_agent "$t")"
}

need_git() { [ -n "$GIT_ROOT" ] || { echo "FAIL needs a git repo"; exit 2; }; }
worktree_dir() { echo "$(dirname "$GIT_ROOT")/.warmd-worktrees/$(basename "$GIT_ROOT")"; }
rel_project() { local r; r="$(git -C "$PROJECT" rev-parse --show-prefix)"; echo "${r%/}"; }   # from git: string math breaks on Windows short paths

# A finished worktree keeps its slow caches, so reusing one beats copying gigabytes. Only when its work is merged and nothing is open or running.
wt_free() { # path
  local p="$1" rel; rel="$(rel_project)"
  [ -z "$(git -C "$p" status --porcelain -uno | grep -vE '\.sln[x]?$')" ] || return 1
  git -C "$p" merge-base --is-ancestor HEAD "$(base_branch)" 2>/dev/null || return 1
  a_has_cache "$p${rel:+/$rel}" || return 1
  [ -z "$(procs "$(printf '%s' "$p" | sed 's/[]().+*?^$|\\[]/\\&/g')" 'powershell|git')" ]
}
# A branch already merged into base holds nothing new: the worktree starts again from base, so the next task never builds on a stale state.
wt_fresh() { # path name
  local p="$1" base; base="$(base_branch)"
  [ -z "$(git -C "$p" status --porcelain -uno | grep -vE '\.sln[x]?$')" ] || return 0
  git -C "$p" merge-base --is-ancestor HEAD "$base" 2>/dev/null || return 0
  [ "$(git -C "$p" rev-parse HEAD)" = "$(git -C "$p" rev-parse "$base")" ] && return 0
  git -C "$p" checkout -q -B "warmd/$2" "$base"
}
wt_reuse() { # name
  local name="$1" p br base main; base="$(base_branch)"; main="$(git -C "$GIT_ROOT" worktree list --porcelain | sed -n '1s/^worktree //p')"
  # A worktree that already holds this task's branch keeps it and its commits: earlier work is never reset.
  while IFS='|' read -r p br; do
    [ "$br" = "warmd/$name" ] && [ "$p" != "$main" ] || continue
    wt_fresh "$p" "$name"
    echo "$p"; return 0
  done < <(git -C "$GIT_ROOT" worktree list --porcelain | awk '/^worktree /{p=substr($0,10)} /^branch /{b=$2; sub("refs/heads/","",b); print p"|"b}')
  while IFS='|' read -r p br; do
    [ "$br" = "$base" ] && continue
    [ "$p" = "$main" ] && continue
    # git prints C:/x, the shell uses /c/x: compare one form, or two tasks land in one worktree
    case " ${USED_WT:-} " in *" $(cd "$p" && pwd) "*) continue;; esac
    grep -qxF "$(cd "$p" && pwd)" "$(git -C "$GIT_ROOT" rev-parse --path-format=absolute --git-common-dir)/warmd-batch" 2>/dev/null && continue   # an agent of the running batch works there
    wt_free "$p" || continue
    git -C "$p" checkout -q -- . 2>/dev/null
    if git -C "$GIT_ROOT" rev-parse -q --verify "refs/heads/warmd/$name" >/dev/null; then
      git -C "$p" checkout -q "warmd/$name" || continue   # existing branch: keep its commits
      wt_fresh "$p" "$name"
    else
      git -C "$p" checkout -q -B "warmd/$name" "$base" || continue
    fi
    echo "$p"; return 0
  done < <(git -C "$GIT_ROOT" worktree list --porcelain | awk '/^worktree /{p=substr($0,10)} /^locked/{p=""} /^branch /{b=$2; sub("refs/heads/","",b); if(p!="")print p"|"b}')
  return 1
}

# A new worktree is useless until its slow caches exist: the adapter copies or links them (Library, .godot, node_modules).
wt_create() { # name
  local name="$1" wt branch src rel
  wt="$(worktree_dir)/$name"; branch="warmd/$name"
  if [ -d "$wt" ]; then wt_fresh "$wt" "$name"; echo "$wt"; return 0; fi
  wt_reuse "$name" && return 0
  mkdir -p "$(worktree_dir)"
  git -C "$GIT_ROOT" worktree add -q -b "$branch" "$wt" HEAD 2>/dev/null || git -C "$GIT_ROOT" worktree add -q "$wt" "$branch" || return 1
  rel="$(rel_project)"; src="$PROJECT"
  a_seed "$src" "$wt${rel:+/$rel}" >/dev/null 2>&1
  seed_links "$src" "$wt${rel:+/$rel}"
  echo "$wt"
}

# Shared brief: one short file all agents of a batch read. It lives in the common git dir, so every worktree sees the same copy and it never gets committed.
# It stops parallel agents from searching for the same thing twice and shows who owns which file.
shared_file() { echo "$(git -C "$PROJECT" rev-parse --path-format=absolute --git-common-dir)/warmd-shared.md"; }
shared_start() { # owner lines
  local f; f="$(shared_file)"
  {
    echo "# Shared brief"
    echo "Read once at the start. Before searching, check Findings. Add what others need: warmd note \"one line\"."
    echo
    echo "## Who owns what"
    printf '%s' "$1"
    echo
    echo "## Findings"
  } > "$f"
}
# A split into a running batch adds its owners and keeps the findings of the agents already at work.
shared_add() { # owner lines
  local f; f="$(shared_file)"
  [ -f "$f" ] || { shared_start "$1"; return; }
  OWN="$1" awk '$0=="" {blank++; next} $0=="## Findings" && !d {printf "%s", ENVIRON["OWN"]; d=1} {while (blank>0) {print ""; blank--}; print} END {while (blank>0) {print ""; blank--}}' "$f" > "$f.$$" && mv -f "$f.$$" "$f"
}
# Files owned by the running batch, from the brief.
shared_owned() { # file@owner words
  sed -n '/^## Who owns what/,/^## Findings/s/^- \([^:]*\): \(.*\)$/\1 \2/p' "$(shared_file)" 2>/dev/null | while read -r o fs; do
    [ "$fs" = none ] && continue
    for f in ${fs//,/ }; do printf '%s@%s ' "$f" "$o"; done
  done
}
# Is this task already part of the running batch? Then a split again reuses it and takes no new place.
batch_has() { # batchfile name
  local wt; [ -f "$1" ] || return 1
  while IFS= read -r wt; do
    [ -d "$wt" ] && [ "$(wt_task "$wt")" = "$2" ] || continue
    [ -f "$1-done" ] && cut -f1 "$1-done" | grep -qxF "$wt" && return 1   # stopped: a new start takes a place
    return 0
  done < "$1"
  return 1
}

# agents= in warmd.conf caps the running tasks. Unset: one per core and one per 2 GB RAM, the smaller one, at least 1.
# Agents wait on the API most of the time, so the default is wider than tune_slots; heavy runs still queue through the slots.
team_agents() {
  if [ -n "${CFG_agents:-}" ]; then echo "$CFG_agents"; return; fi
  local v c r a b n; v="$(hw)"; c="${v% *}"; r="${v#* }"
  a=$c; b=$(( r / 2048 ))
  n=$a; [ "$b" -lt "$n" ] && n=$b; [ "$n" -lt 1 ] && n=1
  echo "$n"
}
# Worktrees of the batch whose agent has not stopped yet (the stop hook writes warmd-batch-done).
team_running() { # batchfile
  local wt n=0 done="$1-done"
  [ -f "$1" ] || { echo 0; return; }
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    [ -f "$done" ] && cut -f1 "$done" | grep -qxF "$wt" && continue
    n=$((n+1))
  done < "$1"
  echo "$n"
}
# Only the newest 40 findings stay, so the brief never grows into the next HANDOFF
team_note() {
  need_git
  local text="${1:-}" f who keep; f="$(shared_file)"
  [ -f "$f" ] || { echo "FAIL no shared brief, warmd split creates it"; return 2; }
  [ -n "$text" ] || { echo "warmd note \"one line\""; return 2; }
  [ ${#text} -le 160 ] || { echo "FAIL over 160 characters, keep it to one fact"; return 2; }
  grep -qF -- "$text" "$f" && { echo "OK already noted"; return 0; }
  who="$(git -C "$GIT_ROOT" branch --show-current)"
  echo "- ${who#warmd/}: $text" >> "$f"
  keep="$(awk '/^## Findings/{print NR}' "$f")"
  if [ "$(( $(wc -l < "$f") - keep ))" -gt 40 ]; then { head -n "$keep" "$f"; tail -n 40 "$f"; } > "$f.tmp"; mv "$f.tmp" "$f"; fi
  echo "OK noted"
}

# seed_links in warmd.conf: untracked folders a worktree needs, linked instead of copied
seed_links() { # from to
  local item
  for item in ${CFG_seed_links//,/ }; do
    [ -e "$1/$item" ] && [ ! -e "$2/$item" ] || continue
    if [ "$OS" = win ]; then powershell.exe -NoProfile -Command "New-Item -ItemType Junction -Path '$(native_path "$2/$item")' -Target '$(native_path "$1/$item")'" >/dev/null 2>&1
    else ln -s "$1/$item" "$2/$item"; fi
  done
}

write_task() { # name tier goal done files wt
  local name="$1" tier="$2" goal="$3" check="$4" files="$5" wt="$6" f port
  mkdir -p "$STATE/tasks"; f="$STATE/tasks/$name.md"
  port=$(( 7830 + $(ls "$STATE/tasks" | wc -l) * 10 ))
  {
    echo "Task $name. First run: cd \"$(native_path "$wt")\". Every command of this task runs there. Port block: $port."
    echo "Goal: $goal"
    echo "Done when: $check"
    echo "Files you own: ${files:-none, read only}"
    echo "Budget: under $(tier_budget "$tier")k tokens."
    echo "Shared brief: $(native_path "$(shared_file)")"
    echo "Handoff: past 70% of the budget or after 60 tool calls, commit, run warmd handoff $name \"what is done\" \"what is next\", end with its AGENT line. A fresh agent is cheaper than a full context."
  } > "$f"
  handoff_register "$name" "$(native_path "$f")" "$tier"
  echo "AGENT $name: subagent_type=$(tier_agent "$tier") model=$(tier_model "$tier") prompt=\"Read $(native_path "$f") and do it.\""
}

# Warm start for agents: the slow first start runs before the agent arrives, in the background and through the normal queue.
prewarm() { # worktree
  [ "$ADAPTER" = unity ] || return 0
  [ "${WARMD_NO_PREWARM:-0}" = 1 ] && return 0
  ( cd "$1" || exit 0; WARMD_BASE=1 WARMD_DETACHED=1 nohup bash "$WARMD_HOME/bin/warmd" ping > /dev/null 2>&1 < /dev/null & )
}

# A session that only waits for notifications sits idle forever when an agent hangs. Start this in the background with every batch:
# it ends, and so wakes the session, as soon as an agent has been idle for <minutes> (default 5) or the batch is over.
# An agent counts as active when a file or a commit changed, a warmd run (test, check, build, merge) holds its worktree, or a process runs inside it.
# On a stall: one WAKE line per idle agent with the message the session sends to it, then exit 3. Queued automatic lines (lib/auto.sh) end it the same way.
# A paused task (its agent stopped, or warmd watch --pause <name>) never alarms until its worktree moves again.

# Does a warmd run or any other process work inside this worktree right now?
wt_busy() { # worktree
  local wt="$1" f pid
  for f in "$wt/.warmd/job.lock/pid" "$wt/.warmd/merge.owner"; do
    pid="$(cat "$f" 2>/dev/null)"
    [ -n "$pid" ] && shell_alive "$pid" && return 0
  done
  # A merge started through Win32_Process.Create (hook_detach) need not share this shell's msys pid table: its Windows pid counts
  pid="$(cat "$wt/.warmd/merge.owner.win" 2>/dev/null)"
  [ -f "$wt/.warmd/merge.owner" ] && [ -n "$pid" ] && pid_alive "$pid" && return 0
  local pat; pat="$(native_path "$wt")"; pat="${pat//\//}"
  pat="$(printf '%s' "$pat" | sed 's/[].()+*?^$|[]/\&/g')"
  [ -n "$(procs "$pat" 'powershell|git|warmd watch')" ] && return 0
  wt_ci_wait "$wt"
}

# Command lines of running gh calls that wait on remote CI: gh run watch, gh pr checks --watch
gh_watchers() {
  if [ "$OS" = win ]; then
    powershell.exe -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { \$_.CommandLine -match 'gh(\.exe)?.? +(run|pr) ' -and \$_.CommandLine -notmatch 'Get-CimInstance' } | ForEach-Object { \$_.CommandLine }" 2>/dev/null | tr -d '\r'
  else
    ps -eo args= 2>/dev/null | grep -E '(^|[/ ])gh +(run|pr) ' | grep -v grep
  fi | grep -E 'run +watch|pr +checks.*--watch'
}

# An agent that waits on CI for its branch is working: the gh watch names the branch, a PR number or a run id of that branch.
wt_ci_wait() { # worktree
  local wt="$1" lines b tok ids want
  lines="$(gh_watchers)"; [ -n "$lines" ] || return 1
  b="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)"; [ -n "$b" ] && [ "$b" != HEAD ] || return 1
  ids=""
  for tok in $(printf '%s\n' "$lines" | tr -d "\"'"); do
    [ "$tok" = "$b" ] && return 0
    case "$tok" in */pull/*|*/runs/*) tok="${tok##*/}";; esac
    case "$tok" in ''|*[!0-9]*) ;; *) ids="$ids $tok";; esac
  done
  [ -n "$ids" ] && command -v gh >/dev/null 2>&1 || return 1
  want="$( cd "$wt" && { gh pr list --head "$b" --state all --json number -q '.[].number'; gh run list --branch "$b" --limit 30 --json databaseId -q '.[].databaseId'; } 2>/dev/null | tr -d '\r')"
  for tok in $ids; do printf '%s\n' "$want" | grep -qx "$tok" && return 0; done
  return 1
}

# Task name of a worktree: the branch warmd/<name>, else the folder name.
wt_task() { # worktree
  local b; b="$(git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  case "$b" in warmd/*) echo "${b#warmd/}";; *) basename "$1";; esac
}

# Minutes since the last movement in a worktree, 0 while a run or process is active.
wt_idle() { # worktree limit batchfile
  local wt="$1" limit="$2" batch="$3" last started
  if [ -n "$(find "$wt" -type f -mmin "-$limit" -not -path '*/.git/*' -not -path '*/Library/*' -not -path '*/.warmd/*' -not -path '*/Temp/*' -not -path '*/Logs/*' -not -path '*/obj/*' -not -path '*/node_modules/*' 2>/dev/null | head -1)" ]; then echo 0; return; fi
  # The batch start counts as movement: a worktree reused with an old commit is not stalled at minute zero.
  last="$(git -C "$wt" log -1 --format=%ct 2>/dev/null || echo 0)"; started="$(date -r "$batch" +%s 2>/dev/null || echo 0)"
  [ "$started" -gt "$last" ] && last="$started"
  local age=$(( ($(date +%s) - last) / 60 ))
  [ "$age" -lt "$limit" ] && { echo 0; return; }
  wt_busy "$wt" && { echo 0; return; }
  echo "$age"
}

# An agent that died at start (API or billing error) never commits. Its transcript names the reason. Transcripts: WARMD_TRANSCRIPTS, default ~/.claude/projects.
agent_dead() { # worktree name -> reason
  local wt="$1" name="$2" root="${WARMD_TRANSCRIPTS:-$HOME/.claude/projects}" f
  [ "$(git -C "$wt" rev-list --count "$(base_branch)..HEAD" 2>/dev/null || echo 1)" = 0 ] || return 1
  [ -d "$root" ] || return 1
  f="$(find "$root" -name '*.jsonl' -mmin -1440 -exec grep -lF "tasks/$name.md" {} + 2>/dev/null | head -1)"
  [ -n "$f" ] || return 1
  grep -oiE '(API Error|credit balance|billing|usage limit|rate.?limit|overloaded|authentication_error|invalid.?api.?key)[^"\]{0,80}' "$f" | head -1 | grep .
}

team_watch() {
  need_git
  local once=0 limit=5 batch wt age name stalled reason
  local common live paused
  common="$(git -C "$PROJECT" rev-parse --path-format=absolute --git-common-dir)"
  case "${1:-}" in   # a task whose agent was stopped by hand: watch leaves it alone until its worktree moves again
    --pause) [ -n "${2:-}" ] || { echo "warmd watch --pause <name>"; return 2; }; auto_pause "$common" "$2"; echo "OK $2 paused, watch skips it until its worktree moves"; return 0;;
  esac
  [ "${1:-}" = --once ] && { once=1; shift; }
  limit="${1:-5}"
  batch="$common/warmd-batch"
  auto_drain "$common" && return 3
  [ -f "$batch" ] || { echo "OK no batch running"; return 0; }
  while :; do
    auto_drain "$common" && return 3   # an automatic escalation waits for the session to start the next agent
    [ -f "$batch" ] || { echo "OK batch ended"; return 0; }
    stalled=0; live=0; paused=""
    while IFS= read -r wt; do
      [ -d "$wt" ] || continue
      name="$(wt_task "$wt")"
      if auto_paused "$common" "$name" "$wt"; then paused="$paused $name"; continue; fi   # no agent runs there, nothing to wake
      grep -qxF "$name" "$batch-dead" 2>/dev/null && continue   # reported once, no further alarms for it
      if reason="$(agent_dead "$wt" "$name")"; then
        echo "DEAD $name: died at start, no commit. Reason: $reason. Fix the cause, then start it again: \"Read $(native_path "$STATE/tasks/$name.md") and do it.\""
        echo "$name" >> "$batch-dead"; stalled=1; continue
      fi
      live=1
      age="$(wt_idle "$wt" "$limit" "$batch")"
      if [ "$age" -gt 0 ]; then
        echo "WAKE $name: idle $age min in $(native_path "$wt"). Send to the $name agent: \"Idle for $age minutes. Reply in one line with your state and next step, or run: warmd handoff $name \\\"what is done\\\" \\\"what is next\\\" and end with its AGENT line.\""
        stalled=1
      fi
    done < "$batch"
    [ $stalled = 1 ] && return 3
    [ $live = 0 ] && [ -n "$paused" ] && { echo "OK no agent runs, paused:$paused"; return 0; }
    [ $once = 1 ] && { echo "OK all worktrees moved in the last $limit minutes${paused:+, paused:$paused}"; return 0; }
    sleep 30
  done
}

# Leading and trailing blanks off. Not xargs: it stops at the first apostrophe and cuts the goal.
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# Tasks file, one per line: name | goal | done check | files (comma separated, or none)
team_split() {
  need_git
  local file="${1:-}" name goal check files tier wt seen="" f n=0 bad=0 batch append=0 running=0 cap own="" waited=0
  [ -f "$file" ] || { echo "warmd split <file>, lines: name | goal | done check | files"; return 2; }
  batch="$(git -C "$PROJECT" rev-parse --path-format=absolute --git-common-dir)/warmd-batch"
  # A batch already runs: append to it. Overwriting would drop its worktrees from watch and the batch guard.
  if [ -f "$batch" ]; then append=1; running="$(team_running "$batch")"; seen="$(shared_owned)"; fi
  cap="$(team_agents)"
  while IFS='|' read -r name goal check files <&3; do
    name="$(trim "$name")"; goal="$(trim "$goal")"; check="$(trim "$check")"; files="$(echo "$files" | tr -d ' ')"
    case "$name" in \#*|"") continue;; esac
    if [ -n "$files" ] && [ "$files" != none ]; then
      for f in ${files//,/ }; do
        # the same task split again owns its files already, any other owner collides
        case " $seen " in *" $f@"*) case " $seen " in *" $f@$name "*) ;; *) echo "GAP $name: $f already owned in this batch, two agents would collide"; bad=1;; esac;; esac
        seen="$seen $f@$name"
      done
    fi
    [ -n "$check" ] || { echo "GAP $name: no done check"; bad=1; }
    n=$((n+1))
  done 3< <(tr -d '\r' < "$file")
  [ $bad = 0 ] || { echo "FAIL fix the gaps, nothing was created"; return 1; }
  [ $append = 1 ] || { : > "$batch"; rm -f "$batch-dead" "$batch-done"; }
  while IFS='|' read -r name goal check files <&3; do
    name="$(trim "$name")"; goal="$(trim "$goal")"; check="$(trim "$check")"; files="$(echo "$files" | tr -d ' ')"
    case "$name" in \#*|"") continue;; esac
    if [ $append = 1 ] && batch_has "$batch" "$name"; then :
    elif [ "$running" -ge "$cap" ]; then
      echo "WAIT $name: $running of $cap agents run (agents= in warmd.conf), split it again when one is done"; waited=$((waited+1)); continue
    else running=$((running+1)); own="$own- $name: ${files:-none}"$'\n'
    fi
    tier="$(route_tier "$goal" "$files")"
    if [ -z "$files" ] || [ "$files" = none ]; then wt="$GIT_ROOT"; else wt="$(wt_create "$name")" || { echo "FAIL worktree $name"; return 1; }; USED_WT="${USED_WT:-} $(cd "$wt" && pwd)"; fi
    write_task "$name" "$tier" "$goal" "$check" "$files" "$wt"
    if [ -n "$files" ] && [ "$files" != none ]; then
      grep -qxF "$(cd "$wt" && pwd)" "$batch" || ( cd "$wt" && pwd ) >> "$batch"
      prewarm "$wt"
    fi
    printf '%s\n' "$tier" > "$STATE/tasks/$name.tier"
  done 3< <(tr -d '\r' < "$file")
  if [ $append = 1 ]; then shared_add "$own"; else shared_start "$own"; fi
  echo "OK $((n-waited)) tasks split$([ $waited = 0 ] || echo ", $waited waiting"). Start now, in the background: warmd watch"
}

team_escalate() {
  need_git
  local name="${1:-}" f="$STATE/tasks/${1:-}.md" tier next area
  [ -f "$f" ] || { echo "warmd escalate <name>: unknown task"; return 2; }
  tier="$(apply_floor "$(cat "$STATE/tasks/$name.tier" 2>/dev/null || echo mid)")"; next="$(tier_next "$tier")"
  [ -n "$next" ] || { echo "FAIL $name is at the top tier, this one needs a human"; return 1; }
  next="$(apply_floor "$next")"
  area="$(area_of "$(sed -n 's/^Files you own: //p' "$f")")"
  printf 'escalated\t%s\n' "$area" >> "$STATE/history.tsv"
  grep -q '^Earlier attempt' "$f" || echo "Earlier attempt failed. Read its commits on this branch first, then take a different approach." >> "$f"
  # The earlier commits as context: the next tier starts from what was tried, not from zero
  local log; log="$(git -C "$GIT_ROOT" log --format='%h %s' "$(base_branch)..warmd/$name" 2>/dev/null | head -8 | cut -c1-72 | awk 'NR>1{printf "; "}{printf "%s",$0}')"
  sed -i.bak '/^Earlier commits: /d' "$f"; rm -f "$f.bak"
  [ -n "$log" ] && echo "Earlier commits: $log" >> "$f"
  echo "$next" > "$STATE/tasks/$name.tier"
  sed -i.bak "s/^Budget: .*/Budget: under $(tier_budget "$next")k tokens./" "$f"; rm -f "$f.bak"
  handoff_register "$name" "$(native_path "$f")" "$next"   # a later handoff or restart starts the new tier, not the old one
  echo "AGENT $name: subagent_type=warmd-worker model=$(tier_model "$next") prompt=\"Read $(native_path "$f") and do it.\""
}

# The last line of every agent: facts from git and the last run, not prose.
team_finish() {
  need_git
  ledger_finish "$@" || return $?
  local br sha ahead dirty up last
  br="$(git -C "$GIT_ROOT" branch --show-current)"; sha="$(git -C "$GIT_ROOT" rev-parse --short HEAD)"
  ahead="$(git -C "$GIT_ROOT" rev-list --count "$(base_branch)..HEAD" 2>/dev/null || echo '?')"
  dirty="$(git -C "$GIT_ROOT" status --porcelain -uno | wc -l | tr -d ' ')"
  if git -C "$GIT_ROOT" remote get-url origin >/dev/null 2>&1; then git -C "$GIT_ROOT" push -q -u origin "$br" 2>/dev/null && up=pushed || up=NOT_pushed; else up=local; fi
  last="$(sed -n '2p' "$RUN/result.txt" 2>/dev/null | tr -d '\r' | cut -c1-70)"
  echo "DONE $br $sha, $ahead ahead, $dirty uncommitted, $up${last:+, last run: $last}"
}

team_board() {
  need_git
  local base path br age dirty ahead
  base="$(base_branch)"
  printf '%-26s %-22s %6s %6s %6s\n' worktree branch age dirty ahead
  git -C "$GIT_ROOT" worktree list --porcelain | awk '/^worktree /{p=substr($0,10)} /^branch /{b=$2; sub("refs/heads/","",b); print p"|"b}' | while IFS='|' read -r path br; do
    age=$(( ($(date +%s) - $(git -C "$path" log -1 --format=%ct)) / 60 ))
    dirty="$(git -C "$path" status --porcelain -uno | wc -l | tr -d ' ')"
    ahead="$(git -C "$path" rev-list --count "$base..HEAD" 2>/dev/null || echo '?')"
    printf '%-26s %-22s %5sm %6s %6s\n' "$(basename "$path" | cut -c1-26)" "$(echo "$br" | cut -c1-22)" "$age" "$dirty" "$ahead"
  done
}

# Why a run went red, in one line: the summary plus the FAIL lines that name the failing tests.
# Without such lines: the first or last 3 lines of the output.
red_lines() { # output head|tail
  local names sum
  names="$(printf '%s\n' "$1" | grep -E '^[[:space:]]*(FAIL|FAILED|not ok|Failed:?|✗|×)[[:space:]]' | sed 's/^[[:space:]]*//' | head -5 | cut -c1-120 | awk 'NR>1{printf " | "}{printf "%s",$0}')"
  sum="$(printf '%s\n' "$1" | grep -E '[0-9]+ (failed|failing|failures?)' | tail -1 | sed 's/^[[:space:]]*//' | cut -c1-60)"
  if [ -n "$names" ]; then echo "${sum:+$sum: }$names" | cut -c1-600
  else printf '%s\n' "$1" | "${2:-tail}" -3 | tr '\n' ' ' | cut -c1-200; fi
}

# merge <branch>: only into the base branch, only from a clean tree, then the fastest checks. Red rolls back.
team_merge() {
  need_git
  local br="${1:-}" base out m
  [ -n "$br" ] || { echo "warmd merge <branch>, after a resolved conflict: warmd merge --continue"; return 2; }
  base="$(base_branch)"
  [ "$(git -C "$GIT_ROOT" branch --show-current)" = "$base" ] || { echo "FAIL merge only from a checkout of $base"; return 2; }
  if [ "$br" = --continue ]; then
    br="$(git -C "$GIT_ROOT" name-rev --name-only MERGE_HEAD 2>/dev/null)" || { echo "FAIL no merge open"; return 2; }
    [ -z "$(git -C "$GIT_ROOT" diff --name-only --diff-filter=U)" ] || { echo "FAIL still unresolved:"; git -C "$GIT_ROOT" diff --name-only --diff-filter=U | head -8; return 1; }
  else
    git -C "$GIT_ROOT" status --porcelain -uno | grep -qE '\.sln[x]?$' && git -C "$GIT_ROOT" checkout -q -- '*.sln*' 2>/dev/null
    [ -z "$(git -C "$GIT_ROOT" status --porcelain -uno)" ] || { echo "FAIL uncommitted changes, nothing done"; return 2; }
    git -C "$GIT_ROOT" rev-parse --verify -q "$br" >/dev/null || { echo "FAIL unknown branch $br"; return 2; }
    out="$(git -C "$GIT_ROOT" merge --no-commit --no-ff "$br" 2>&1)" || {
      echo "FAIL conflict in $(echo "$out" | grep -c CONFLICT) files, resolve them and run warmd merge --continue"; echo "$out" | grep CONFLICT | head -8 | cut -c1-160; return 1; }
    echo "$out" | grep -q "Already up to date" && { echo "OK nothing to merge"; return 0; }
  fi
  MERGELOCK="$STATE/merge.owner"; echo "$$" > "$MERGELOCK"; export WARMD_IN_MERGE=1
  # Windows pid next to it: a merge launched through WMI is not always visible to kill -0 of other shells
  if [ -r "/proc/$$/winpid" ]; then cat "/proc/$$/winpid" > "$MERGELOCK.win"; else rm -f "$MERGELOCK.win"; fi
  mfail() { echo "FAIL merge $br: $*"; git -C "$GIT_ROOT" reset -q --hard HEAD; return 1; }
  m="$(git -C "$GIT_ROOT" -c core.whitespace=-trailing-space,-space-before-tab,-blank-at-eof,-blank-at-eol diff --cached --check 2>&1 | head -3 | cut -c1-160)"; [ -z "$m" ] || { mfail "$m"; return 1; }
  if [ -n "$CFG_gate" ]; then
    if ! m="$(cd "$PROJECT" && WARMD_BIN="bash $WARMD_HOME/bin/warmd" sh -c "$CFG_gate" 2>&1)"; then mfail "$(red_lines "$m" tail)"; return 1; fi
  elif ! m="$(run_check 2>&1)"; then mfail "$(red_lines "$m" head)"; return 1; fi
  if [ -n "$CFG_perf" ]; then m="$(perf_run 2>&1)" || { mfail "$(echo "$m" | tail -2 | tr '\n' ' ' | cut -c1-200)"; return 1; }; fi
  git -C "$GIT_ROOT" add -u && git -C "$GIT_ROOT" commit -q -m "Merge $br" ${WARMD_TRAILER:+-m "$WARMD_TRAILER"} && echo "OK $(secs)s merged $br as $(git -C "$GIT_ROOT" rev-parse --short HEAD), not pushed"
}

. "$WARMD_HOME/lib/auto.sh"
