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
tier_agent() { case "$1" in cheap) echo "${AGENT_NS:-}warmd-scout";; *) echo "${AGENT_NS:-}warmd-worker";; esac; }
# Editing never runs on the cheap tier, whatever the config says: that tier only reads

route_print() {
  [ -n "${1:-}" ] || { echo "warmd route <goal> [files], e.g. warmd route 'fix the footer' src/footer.css"; return 2; }
  local t; t="$(route_tier "$1" "${2:-}")"
  echo "$t model=$(tier_model "$t") budget=$(tier_budget "$t")k agent=$(tier_agent "$t")"
}

need_git() { [ -n "$GIT_ROOT" ] || { echo "FAIL needs a git repo"; exit 2; }; }
worktree_dir() { echo "$(dirname "$GIT_ROOT")/.warmd-worktrees/$(basename "$GIT_ROOT")"; }
rel_project() { local r; r="$(git -C "$PROJECT" rev-parse --show-prefix)"; echo "${r%/}"; }   # from git: string math breaks on Windows short paths

# Work left in a worktree: tracked changes and new files, but not files the engine writes on its own (Godot .uid/.import next to every asset).
wt_work() { git -C "$1" status --porcelain 2>/dev/null | grep -vE '^\?\? .*\.(uid|import)$'; }
# A finished worktree keeps its slow caches, so reusing one beats copying gigabytes. Only when its work is merged and nothing is open or running.
wt_free() { # path
  local p="$1" rel; rel="$(rel_project)"
  [ -z "$(git -C "$p" status --porcelain -uno | grep -vE '\.sln[x]?$|Assets/Editor/Warmd/')" ] || return 1   # a daemon warmd renewed is no work
  git -C "$p" merge-base --is-ancestor HEAD "$(base_branch)" 2>/dev/null || return 1
  a_has_cache "$p${rel:+/$rel}" || return 1
  [ -z "$(procs_like "$(native_path "$p")" 'powershell|git')" ]
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
  rel="$(rel_project)"; src="$PROJECT"
  # Every worktree of a split gets the base's Library, also a reused one: a worktree never imports cold
  if [ -d "$wt" ]; then wt_fresh "$wt" "$name"; a_seed "$src" "$wt${rel:+/$rel}" >/dev/null 2>&1; seed_links "$src" "$wt${rel:+/$rel}"; echo "$wt"; return 0; fi
  if wt="$(wt_reuse "$name")"; then a_seed "$src" "$wt${rel:+/$rel}" >/dev/null 2>&1; seed_links "$src" "$wt${rel:+/$rel}"; echo "$wt"; return 0; fi
  wt="$(worktree_dir)/$name"
  mkdir -p "$(worktree_dir)"
  git -C "$GIT_ROOT" worktree add -q -b "$branch" "$wt" HEAD 2>/dev/null || git -C "$GIT_ROOT" worktree add -q "$wt" "$branch" || return 1
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
  # Only tasks still in the batch own files: a task that left it (merged, pruned) frees its files for the next split.
  local batch live=" " wt
  batch="$(git -C "$PROJECT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/warmd-batch"
  # A finished task (its agent stopped, warmd-batch-done) frees its files too: a paused task blocked the next split.
  if [ -f "$batch" ]; then while IFS= read -r wt; do [ -d "$wt" ] && ! wt_finished "${batch%/warmd-batch}" "$wt" && live="$live$(wt_task "$wt") "; done < "$batch"; fi
  sed -n '/^## Who owns what/,/^## Findings/s/^- \([^:]*\): \(.*\)$/\1 \2/p' "$(shared_file)" 2>/dev/null | while read -r o fs; do
    [ "$fs" = none ] && continue
    if [ -f "$batch" ]; then case "$live" in *" $o "*) ;; *) continue;; esac; fi
    for f in ${fs//,/ }; do printf '%s@%s ' "$f" "$o"; done
  done
}
# Is this task already part of the running batch? Then a split again reuses it and takes no new place.
batch_has() { # batchfile name
  local wt; [ -f "$1" ] || return 1
  while IFS= read -r wt; do
    [ -d "$wt" ] && [ "$(wt_task "$wt")" = "$2" ] || continue
    wt_finished "${1%/warmd-batch}" "$wt" && return 1   # stopped: a new start takes a place
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
# One spelling per folder: the Windows runner mixes 8.3 short names (RUNNER~1) with long names for the same path
wt_norm() { # path -> long, absolute form
  local p; p="$(cd "$1" 2>/dev/null && pwd -P)" || p="$1"
  if command -v cygpath >/dev/null 2>&1; then p="$(cygpath -u "$(cygpath -l -w "$p" 2>/dev/null || echo "$p")" 2>/dev/null || echo "$p")"; fi
  printf '%s\n' "$p"
}
# wt_norm_r: the same into REPLY, remembered per path for the life of this shell. warmd watch asks every 90 s for every
# worktree; three program starts per path and round add up on machines that keep kernel memory per process start.
declare -gA WT_NORM_MEMO=()
wt_norm_r() { # path -> REPLY
  if [ -n "${WT_NORM_MEMO[$1]+x}" ]; then REPLY="${WT_NORM_MEMO[$1]}"; return 0; fi
  REPLY="$(wt_norm "$1")"; WT_NORM_MEMO[$1]="$REPLY"
}

team_running() { # batchfile
  local wt n=0
  [ -f "$1" ] || { echo 0; return; }
  # wt_finished, not the path alone: the finished line of the task a reused worktree held before does not count its new task out
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    wt_finished "${1%/warmd-batch}" "$wt" && continue
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
# Every link also goes into info/exclude: git sees a junction as a plain folder, so git add -A (the handoff WIP commit) took
# thousands of package files into a task branch, and its revert deleted them from the worktree.
seed_links() { # from to
  local item ex rel; ex="$(git -C "$GIT_ROOT" rev-parse --path-format=absolute --git-common-dir)/info/exclude"; rel="$(rel_project)"
  for item in ${CFG_seed_links//,/ }; do
    mkdir -p "${ex%/*}"
    grep -qxF "/${rel:+$rel/}$item/" "$ex" 2>/dev/null || echo "/${rel:+$rel/}$item/" >> "$ex"
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
    echo "Task $name. First run: cd \"$(native_path "$wt")\". Every command of this task runs there: start each Bash call with cd \"$(native_path "$wt")\" &&, the shell goes back to the main checkout after every call. Port block: $port."
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
# On a stall: one WAKE line per idle agent with the message the session sends to it, then exit 3. Queued AGENT lines (lib/auto.sh) end it the same way;
# an ESCALATE or SHIP line only a human can act on ends it with exit 4 and an OPEN line while the batch runs. Exit 0 only when no batch runs.
# A paused task (its agent stopped, or warmd watch --pause <name>) never alarms until its worktree moves again.

# Does a warmd run or any other process work inside this worktree right now?
# warmd ci and warmd ship write .warmd/ci.wait while they poll: pid, run id, run start, median seconds
wt_ci_mark() { # worktree -> the marker line of a live CI wait
  local m; m="$(cat "$1/.warmd/ci.wait" 2>/dev/null)"; [ -n "$m" ] && shell_alive "${m%% *}" && echo "$m"
}

# One line for warmd watch: run, minutes in, ETA from the median of recent runs
wt_ci_eta() { # worktree
  local m id start med el; m="$(wt_ci_mark "$1")" || return 1
  local now; printf -v now '%(%s)T' -1
  read -r _ id start med <<< "$m"; el=$(( now - ${start:-0} ))
  if [ "${med:-0}" -gt 0 ]; then
    if [ "$med" -gt "$el" ]; then echo "run $id, $((el / 60)) min in, about $(( (med - el + 59) / 60 )) min left"
    else echo "run $id, $((el / 60)) min in, past the median of $(( (med + 30) / 60 )) min"; fi
  else echo "run $id, $((el / 60)) min in, no ETA yet"; fi
}

# A warmd test, check or build of this worktree is running: its own project or one in a subfolder (lib/core.sh run_mark)
wt_run_active() { # worktree
  local d; for d in "$1/.warmd" "$1"/*/.warmd; do [ -d "$d/run/active" ] && run_active "$d" >/dev/null && return 0; done
  return 1
}

wt_busy() { # worktree
  local wt="$1" f pid
  wt_ci_mark "$wt" >/dev/null && return 0   # polling CI is work, not idle
  wt_run_active "$wt" && return 0
  for f in "$wt/.warmd/job.lock/pid" "$wt/.warmd/merge.owner"; do
    pid="$(cat "$f" 2>/dev/null)"
    [ -n "$pid" ] && shell_alive "$pid" && return 0
  done
  # A merge started through Win32_Process.Create (hook_detach) need not share this shell's msys pid table: its Windows pid counts
  pid="$(cat "$wt/.warmd/merge.owner.win" 2>/dev/null)"
  [ -f "$wt/.warmd/merge.owner" ] && [ -n "$pid" ] && pid_alive "$pid" && return 0
  # A program that names the worktree in its command line (an editor's -projectPath, a build): one process list per round
  [ -n "$(procs_like "$(native_path "$wt")" 'powershell|git|warmd watch')" ] && return 0
  wt_ci_wait "$wt"
}

# Command lines of running gh calls that wait on remote CI: gh run watch, gh pr checks --watch
gh_watchers() {
  local c
  while IFS= read -r c; do [[ $c =~ run\ +watch|pr\ +checks.*--watch ]] && printf '%s\n' "$c"; done < <(procs_cmdlines 'gh(\.exe)?.? +(run|pr) ')
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
# wt_task_r: the same into REPLY from the worktree's .git file and HEAD with builtins, git only when they are unreadable
wt_task_r() { # worktree -> REPLY
  local g="" h=""
  { IFS= read -r g < "$1/.git"; } 2>/dev/null; g="${g%$'\r'}"; g="${g#gitdir: }"
  [ -d "$1/.git" ] && g="$1/.git"
  [ -n "$g" ] && { IFS= read -r h < "$g/HEAD"; } 2>/dev/null; h="${h%$'\r'}"
  case "$h" in
    "ref: refs/heads/warmd/"*) REPLY="${h#ref: refs/heads/warmd/}";;
    "ref: refs/heads/"*) REPLY="${1%/}"; REPLY="${REPLY##*/}";;
    *) REPLY="$(wt_task "$1")";;
  esac
}

# Minutes since the last movement in a worktree, 0 while a run or process is active.
wt_idle() { # worktree limit batchfile [task name]
  local wt="$1" limit="$2" batch="$3" last started
  if [ -n "$(find "$wt" -type f -mmin "-$limit" -not -path "$wt/.git/*" -not -path "$wt/*/.git/*" -not -path "$wt/Library/*" -not -path "$wt/*/Library/*" -not -path "$wt/.warmd/*" -not -path "$wt/*/.warmd/*" -not -path "$wt/Temp/*" -not -path "$wt/*/Temp/*" -not -path "$wt/Logs/*" -not -path "$wt/*/Logs/*" -not -path "$wt/obj/*" -not -path "$wt/*/obj/*" -not -path "$wt/node_modules/*" -not -path "$wt/*/node_modules/*" -print -quit 2>/dev/null)" ]; then echo 0; return; fi
  # The batch start counts as movement: a worktree reused with an old commit is not stalled at minute zero.
  last="$(git -C "$wt" log -1 --format=%ct 2>/dev/null || echo 0)"
  [ "$batch" = "${WATCH_BATCH_F:-}" ] || { WATCH_BATCH_F="$batch"; WATCH_BATCH_T="$(date -r "$batch" +%s 2>/dev/null || echo 0)"; }
  started="$WATCH_BATCH_T"
  [ "$started" -gt "$last" ] && last="$started"
  local now; printf -v now '%(%s)T' -1
  local age=$(( (now - last) / 60 ))
  [ "$age" -lt "$limit" ] && { echo 0; return; }
  wt_busy "$wt" && { echo 0; return; }
  # An agent that reads or thinks writes no file, but its transcript grows: that is movement too.
  [ -n "${4:-}" ] && wt_talking "$4" "$limit" && { echo 0; return; }
  echo "$age"
}

wt_talking() { # name limit -> 0 when a transcript of this task changed in the last <limit> minutes
  local root="${WARMD_TRANSCRIPTS:-$HOME/.claude/projects}"
  [ -d "$root" ] || return 1
  find "$root" -name '*.jsonl' -mmin "-$2" -exec grep -lF "tasks/$1.md" {} + 2>/dev/null | grep -q .
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

# watch_drain <common> <batch>: the queued lines for the session. 3 when one starts an agent (AGENT), 4 when only a human
# can act (ESCALATE, SHIP): the batch is not over then, and a closing line says so, because exit 0 means "batch over"
# and a watch piped through tail loses its exit code. 1 when nothing was queued.
watch_drain() {
  local out; out="$(auto_drain "$1")" || return 1
  printf '%s\n' "$out"
  case $'\n'"$out" in *$'\n'"AGENT "*) return 3;; esac
  [ -f "$2" ] && echo "OPEN batch still runs, the line above needs you; start warmd watch again"
  return 4
}

team_watch() {
  need_git
  local once=0 limit=5 batch wt age name stalled reason
  local common live paused ci ci_seen=" "
  local -A WATCH_LIVE=()
  common="$(git -C "$PROJECT" rev-parse --path-format=absolute --git-common-dir)"
  case "${1:-}" in   # a task whose agent was stopped by hand: watch leaves it alone until its worktree moves again
    --pause) [ -n "${2:-}" ] || { echo "warmd watch --pause <name>"; return 2; }; auto_pause "$common" "$2"; echo "OK $2 paused, watch skips it until its worktree moves"; return 0;;
  esac
  [ "${1:-}" = --once ] && { once=1; shift; }
  limit="${1:-5}"
  batch="$common/warmd-batch"
  watch_drain "$common" "$batch"; case $? in 3) return 3;; 4) return 4;; esac
  [ -f "$batch" ] || { echo "OK no batch running"; return 0; }
  while :; do
    watch_drain "$common" "$batch"; case $? in 3) return 3;; 4) return 4;; esac   # an automatic escalation waits for the session to start the next agent
    [ -f "$batch" ] || { echo "OK batch ended"; return 0; }
    stalled=0; live=0; paused=""
    while IFS= read -r wt; do
      [ -d "$wt" ] || continue
      wt_task_r "$wt"; name="$REPLY"
      # Its agent stopped and none started since: nothing to wake. Unless its own warmd run still works there:
      # an agent that ended its turn waiting for a background test comes back for the result, the batch is not over.
      if wt_finished "$common" "$wt"; then wt_run_active "$wt" && live=1; continue; fi
      if auto_paused "$common" "$name" "$wt"; then   # no agent runs there, nothing to wake
        if wt_run_active "$wt"; then live=1; else paused="$paused $name"; fi; continue
      fi
      grep -qxF "$name" "$batch-dead" 2>/dev/null && continue   # reported once, no further alarms for it
      if [ -z "${WATCH_LIVE[$wt]:-}" ] && reason="$(agent_dead "$wt" "$name")"; then
        echo "DEAD $name: died at start, no commit. Reason: $reason. Fix the cause, then start it again: \"Read $(native_path "$STATE/tasks/$name.md") and do it.\""
        echo "$name" >> "$batch-dead"; stalled=1; continue
      fi
      live=1; WATCH_LIVE[$wt]=1   # it got past the start once: agent_dead (git and find) is not asked again
      if ci="$(wt_ci_eta "$wt")"; then   # once per run, the line changes only with the run
        case "$ci_seen" in *" $name:${ci%%,*} "*) ;; *) echo "CI $name: $ci"; ci_seen="$ci_seen$name:${ci%%,*} ";; esac
      fi
      age="$(wt_idle "$wt" "$limit" "$batch" "$name")"
      if [ "$age" -gt 0 ]; then
        echo "WAKE $name: idle $age min in $(native_path "$wt"). Send to the $name agent: \"Idle for $age minutes. Reply in one line with your state and next step, or run: warmd handoff $name \\\"what is done\\\" \\\"what is next\\\" and end with its AGENT line.\""
        stalled=1
      fi
    done < "$batch"
    [ $stalled = 1 ] && return 3
    [ $live = 1 ] && touch "$batch-alive"   # agents work: batch_guard keeps a marker older than 240 minutes
    [ $live = 0 ] && [ -n "$paused" ] && { echo "OK no agent runs, paused:$paused"; return 0; }
    [ $once = 1 ] && { echo "OK all worktrees moved in the last $limit minutes${paused:+, paused:$paused}"; return 0; }
    nap "${WARMD_WATCH_POLL:-90}"   # one round costs about 40 process starts per worktree, idle is judged in minutes
  done
}

# Leading and trailing blanks off. Not xargs: it stops at the first apostrophe and cuts the goal.
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# Tasks file, one per line: name | goal | done check | files (comma separated, or none)
# Files may also be split by spaces: "lib bin" is two entries, not the one path "libbin".
files_norm() { printf '%s' "$1" | tr '[:blank:]' ',' | tr -s ',' | sed 's/^,//; s/,$//'; }
# A finished task: its agent stopped (the stop hook wrote warmd-batch-done) and no new agent started on it since
# (an Agent call on the task removes that line again). warmd watch never wakes such a worktree.
wt_finished() { # common worktree
  [ -f "$1/warmd-batch-done" ] || return 1
  # A line may name the branch its task held (third field): a worktree that holds another task's branch now is not
  # finished, or a split prunes it as free while the new agent works there and hands it to a second agent.
  local w d p b cur=""; wt_norm_r "$2"; w="$REPLY"
  while IFS= read -r d || [ -n "$d" ]; do
    p="${d%%$'\t'*}"; [ -n "$p" ] || continue
    wt_norm_r "$p"; [ "$REPLY" = "$w" ] || continue
    b=""; case "$d" in *$'\t'*$'\t'*) b="${d##*$'\t'}";; esac
    [ -n "$b" ] || return 0
    [ -n "$cur" ] || cur="$(git -C "$2" branch --show-current 2>/dev/null)"
    [ "$b" = "$cur" ] && return 0
  done < "$1/warmd-batch-done"
  return 1
}

batch_done_forget() { # common worktree
  [ -f "$1/warmd-batch-done" ] || return 0
  local w d keep=""; wt_norm_r "$2"; w="$REPLY"
  while IFS= read -r d || [ -n "$d" ]; do
    [ -n "$d" ] || continue
    wt_norm_r "${d%%$'\t'*}"; [ "$REPLY" = "$w" ] || keep="$keep$d"$'\n'
  done < "$1/warmd-batch-done"
  printf '%s' "$keep" > "$1/warmd-batch-done"
}

# When the next split appends to the batch, finished tasks whose work is merged (clean, nothing ahead of the base) leave it.
# A finished task with unmerged work stays: the automatic merge after the last agent still needs it.
# A worktree on another branch than its finished line names holds a new task: it stays and the stale line goes, or the
# automatic merge counts the new task as done and ends the batch while its agent still works there.
batch_prune() { # common
  local wt keep="" base batch="$1/warmd-batch"; base="$(base_branch)"
  while IFS= read -r wt; do
    [ -d "$wt" ] || continue
    if wt_finished "$1" "$wt"; then
      [ -z "$(wt_work "$wt")" ] && [ "$(git -C "$wt" rev-list --count "$base..HEAD" 2>/dev/null || echo 1)" = 0 ] && continue
    else
      batch_done_forget "$1" "$wt"
    fi
    keep="$keep$wt"$'\n'
  done < "$batch"
  printf '%s' "$keep" > "$batch"
}

# task_fields <line>: name | goal | done check | files. The goal may contain "|" itself (|x| <= y, a | b):
# name is the first field, files the last, the done check the one before it, the goal all in between.
task_fields() {
  local l="$1" rest pipes="${1//[^|]/}"
  if [ ${#pipes} -lt 3 ]; then IFS='|' read -r name goal check files <<< "$l"; return; fi
  name="${l%%|*}"; rest="${l#*|}"
  files="${rest##*|}"; rest="${rest%|*}"
  check="${rest##*|}"; goal="${rest%|*}"
}

# A new batch starts clean: no worktrees, no finished or dead marks, and no queued lines of the batch before it.
# An ESCALATE line of a task merged long ago stopped the first warmd watch of the next batch with exit 4.
# warmd-batch-start marks its start: warmd batch-resume tells the tasks of this batch from older worktrees by it.
batch_fresh() { # common
  : > "$1/warmd-batch"; rm -f "$1/warmd-batch-dead" "$1/warmd-batch-done" "$1/warmd-auto/queue"; : > "$1/warmd-batch-start"
}

team_split() {
  need_git
  local file="${1:-}" name goal check files tier wt seen="" f n=0 bad=0 batch append=0 running=0 cap own="" waited=0 rel
  rel="$(rel_project)"
  [ -f "$file" ] || { echo "warmd split <file>, lines: name | goal | done check | files"; return 2; }
  batch="$(git -C "$PROJECT" rev-parse --path-format=absolute --git-common-dir)/warmd-batch"
  # A batch already runs: append to it. Overwriting would drop its worktrees from watch and the batch guard.
  if [ -f "$batch" ]; then batch_prune "${batch%/warmd-batch}"; append=1; running="$(team_running "$batch")"; seen="$(shared_owned)"; fi
  cap="$(team_agents)"
  while IFS= read -r line <&3; do
    task_fields "$line"
    name="$(trim "$name")"; goal="$(trim "$goal")"; check="$(trim "$check")"; files="$(files_norm "$files")"
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
  [ $append = 1 ] || batch_fresh "${batch%/warmd-batch}"
  while IFS= read -r line <&3; do
    task_fields "$line"
    name="$(trim "$name")"; goal="$(trim "$goal")"; check="$(trim "$check")"; files="$(files_norm "$files")"
    case "$name" in \#*|"") continue;; esac
    if [ $append = 1 ] && batch_has "$batch" "$name"; then :
    elif [ "$running" -ge "$cap" ]; then
      echo "WAIT $name: $running of $cap agents run (agents= in warmd.conf), split it again when one is done"; waited=$((waited+1)); continue
    else running=$((running+1)); own="$own- $name: ${files:-none}"$'\n'
    fi
    tier="$(route_tier "$goal" "$files")"
    # A worktree without its engine cache gets a copy: only with room for it plus disk_min_mb, after freeing finished ones
    if [ -n "$files" ] && [ "$files" != none ] && disk_cache_name && [ ! -d "$(worktree_dir)/$name${rel:+/$rel}/$REPLY" ] && ! disk_room "$PROJECT" 1 "$(dirname "$GIT_ROOT")"; then
      disk_reclaim
      if ! disk_room "$PROJECT" 1 "$(dirname "$GIT_ROOT")"; then
        echo "WAIT $name: disk short, $REPLY. Split it again when space is free"; waited=$((waited+1)); running=$((running-1)); continue
      fi
    fi
    if [ -z "$files" ] || [ "$files" = none ]; then wt="$GIT_ROOT"; else wt="$(wt_create "$name")" || { echo "FAIL worktree $name"; return 1; }; USED_WT="${USED_WT:-} $(cd "$wt" && pwd)"; fi
    write_task "$name" "$tier" "$goal" "$check" "$files" "$wt"
    if [ -n "$files" ] && [ "$files" != none ]; then
      grep -qxF "$(cd "$wt" && pwd)" "$batch" || ( cd "$wt" && pwd ) >> "$batch"
      # A reused worktree may still carry the "finished" line of its previous task: the new task is not finished,
      # or the next split prunes it as free and hands the same worktree to a second agent.
      batch_done_forget "${batch%/warmd-batch}" "$wt"
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
  local wt; wt="$(sed -n '1s/.*cd "\([^"]*\)".*/\1/p' "$f")"
  echo "AGENT $name: subagent_type=${AGENT_NS:-}warmd-worker model=$(tier_model "$next") prompt=\"Read $(native_path "$f") and do it.$(agent_state "$wt")\""
}

# For the prompt of a next agent on a running task: where the branch stands, and that the old agent must be stopped first.
agent_state() { # worktree [base]
  local wt="$1" base="${2:-}" br sha ahead dirty
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  br="$(git -C "$wt" branch --show-current 2>/dev/null)"; [ -n "$br" ] || return 0
  [ -n "$base" ] || base="$(base_branch)"
  sha="$(git -C "$wt" rev-parse --short HEAD 2>/dev/null)"; ahead="$(git -C "$wt" rev-list --count "$base..HEAD" 2>/dev/null || echo '?')"
  dirty="$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  printf ' State: %s at %s, %s ahead of %s, %s uncommitted. Stop the previous agent of this task first, never two in one worktree.' "$br" "$sha" "$ahead" "$base" "$dirty"
}

# The last line of every agent: facts from git and the last run, not prose.
team_finish() {
  need_git
  local br sha ahead dirty up last base
  br="$(git -C "$GIT_ROOT" branch --show-current)"; base="$(base_branch)"
  # The end of a task belongs to its worktree: in the base checkout finish would record the base as the task and push it
  if [ -z "$br" ] || [ "$br" = "$base" ]; then
    echo "FAIL warmd finish runs in the base checkout (${br:-detached}), nothing recorded, nothing pushed. Run it in your task worktree: the cd in the first line of your task file"
    return 2
  fi
  shared_guard   # the main checkout during a batch: the agent's shell went back there, the end belongs to its worktree
  ledger_finish "$@" || return $?
  finish_stop_runs
  sha="$(git -C "$GIT_ROOT" rev-parse --short HEAD)"
  ahead="$(git -C "$GIT_ROOT" rev-list --count "$(base_branch)..HEAD" 2>/dev/null || echo '?')"
  dirty="$(git -C "$GIT_ROOT" status --porcelain | wc -l | tr -d ' ')"   # new files count too: work never added is lost at the merge
  if git -C "$GIT_ROOT" remote get-url origin >/dev/null 2>&1; then git -C "$GIT_ROOT" push -q -u origin "$br" 2>/dev/null && up=pushed || up=NOT_pushed; else up=local; fi
  last="$(sed -n '2p' "$RUN/result.txt" 2>/dev/null | tr -d '\r' | cut -c1-70)"
  # finish is the task's own "done": mark it finished in the batch, also when its agent was stopped and no stop hook ran,
  # so the next split frees its files once it is merged
  local common; common="$(git -C "$GIT_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [ -f "$common/warmd-batch" ] && ! wt_finished "$common" "$GIT_ROOT"; then printf '%s\t%s\t%s\n' "$GIT_ROOT" ok "$br" >> "$common/warmd-batch-done"; fi
  echo "DONE $br $sha, $ahead ahead, $dirty uncommitted, $up${last:+, last run: $last}"
}

# The agent ends: a warmd run it left in this worktree (a background test) holds a slot for nobody. It is ended, its slot
# freed at once (a killed shell may not run its exit trap), and the engine stopped so the test stops too.
finish_stop_runs() {
  local f pid w c d p n=0
  for f in "$STATE"/run/active/*; do
    [ -f "$f" ] || continue
    pid="${f##*/}"; [ "$pid" = "$$" ] && continue
    shell_alive "$pid" || { rm -f "$f"; continue; }
    w=""; c=""; read -r w c < "$f" 2>/dev/null
    kill "$pid" 2>/dev/null; rm -f "$f"; n=$((n + 1))
    for d in "$CACHE_ROOT"/slots/*/; do p=""; read -r p < "$d/pid" 2>/dev/null; [ "$p" = "$pid" ] && rm -rf "${d%/}"; done
    echo "(stopped warmd ${c:-run} pid $pid that was still running here, its slot is free)"
  done
  [ $n = 0 ] || a_stop >/dev/null 2>&1
  return 0
}

team_board() {
  need_git
  local base path br age dirty ahead ct
  base="$(base_branch)"
  printf '%-26s %-22s %6s %6s %6s\n' worktree branch age dirty ahead
  # Every worktree gets a row: a detached one shows (detached), one whose folder is gone says how to drop it.
  # dirty counts new files too, an agent that never ran git add still has work to lose.
  git -C "$GIT_ROOT" worktree list --porcelain | tr -d '\r' | awk '
    function row() { if (p != "") print p "|" b; p = "" }
    /^worktree / { row(); p = substr($0, 10); b = "(detached)" }
    /^branch / { b = $2; sub("refs/heads/", "", b) }
    /^bare$/ { p = "" }
    END { row() }' | while IFS='|' read -r path br; do
    if ! ct="$(git -C "$path" log -1 --format=%ct 2>/dev/null)" || [ -z "$ct" ]; then
      printf '%-26s %-22s %s\n' "$(basename "$path" | cut -c1-26)" "$(echo "$br" | cut -c1-22)" "folder missing, drop it: git worktree prune"; continue
    fi
    age=$(( ($(date +%s) - ct) / 60 ))
    dirty="$(git -C "$path" status --porcelain | wc -l | tr -d ' ')"
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

# The rollback of a red or conflicting merge: back to $1, the HEAD this merge started from, only while HEAD is still $2, the
# last commit this merge made. Nothing is touched (REPLY says why) when someone committed meanwhile, when the rollback
# would leave the base behind its upstream (a commit of the merge was pushed), or when a local change sits in a file the
# merge changed. reset --keep, never --hard: an edit made during the gate in any other file stays.
merge_rollback() { # start, last commit of this merge
  local head up cur
  head="$(git -C "$GIT_ROOT" rev-parse -q --verify HEAD 2>/dev/null)"; cur="$(git -C "$GIT_ROOT" branch --show-current)"
  [ "$head" = "$1" ] && return 0
  [ "$head" = "$2" ] || { REPLY="$cur moved to $(git -C "$GIT_ROOT" rev-parse --short HEAD) during the merge (a commit made meanwhile), it stays as it is: revert the merge by hand if it must go"; return 1; }
  up="$(git -C "$GIT_ROOT" rev-parse -q --verify '@{upstream}' 2>/dev/null || git -C "$GIT_ROOT" rev-parse -q --verify "refs/remotes/origin/$cur" 2>/dev/null)"
  if [ -n "$up" ] && git -C "$GIT_ROOT" merge-base --is-ancestor "$up" "$head" 2>/dev/null && ! git -C "$GIT_ROOT" merge-base --is-ancestor "$up" "$1" 2>/dev/null; then
    REPLY="its upstream already has commits of this merge, a rollback would leave $cur behind it: revert the merge by hand if it must go"; return 1
  fi
  git -C "$GIT_ROOT" reset -q --keep "$1" 2>/dev/null || { REPLY="local changes in files the merge changed, nothing reset: revert the merge by hand if it must go"; return 1; }
}

# merge <branch>: only into the base branch, only from a clean tree, then the fastest checks. Red rolls back.
# warmd merge <branch>... [--no-gate]: every branch merged one after the other (one commit each), then ONE gate over all of
# them and one player build, not one per branch. Red rolls every branch of the call back. A conflict stops at its branch:
# resolve it, warmd merge --continue merges the branches after it. --no-gate is for an integration the user released.
team_merge() {
  need_git
  local base out m br start="" mine="" nogate=0 cont=0 brs=() merged=() new=() q="$STATE/merge.queue" i rest
  for m in "$@"; do case "$m" in --no-gate) nogate=1;; --continue) cont=1;; -*) echo "FAIL unknown option $m"; return 2;; *) brs+=("$m");; esac; done
  [ $cont = 1 ] || [ ${#brs[@]} -gt 0 ] || { echo "warmd merge <branch>... [--no-gate], after a resolved conflict: warmd merge --continue"; return 2; }
  base="$(base_branch)"
  [ "$(git -C "$GIT_ROOT" branch --show-current)" = "$base" ] || { echo "FAIL merge only from a checkout of $base"; return 2; }
  if [ $cont = 1 ]; then
    br="$(git -C "$GIT_ROOT" name-rev --name-only MERGE_HEAD 2>/dev/null)" || { echo "FAIL no merge open"; return 2; }
    [ -z "$(git -C "$GIT_ROOT" diff --name-only --diff-filter=U)" ] || { echo "FAIL still unresolved:"; git -C "$GIT_ROOT" diff --name-only --diff-filter=U | head -8; return 1; }
    # A merge of several branches stopped here: its start, its gate choice and the branches after this one
    brs=(); if [ -f "$q" ]; then { read -r start; read -r m; read -r rest; read -r i; } < "$q"; [ "$m" = 1 ] && nogate=1; read -ra brs <<< "$rest"; read -ra merged <<< "$i"; fi
    [ -n "$start" ] || start="$(git -C "$GIT_ROOT" rev-parse HEAD)"
    git -C "$GIT_ROOT" add -u && git -C "$GIT_ROOT" commit -q --no-edit -m "Merge $br" ${WARMD_TRAILER:+-m "$WARMD_TRAILER"} || { echo "FAIL cannot commit the resolved merge of $br"; return 1; }
    merged+=("$br"); rm -f "$q"
  else
    for br in "${brs[@]}"; do git -C "$GIT_ROOT" rev-parse --verify -q "$br" >/dev/null || { echo "FAIL unknown branch $br, nothing done"; return 2; }; done
    # A branch already in HEAD holds nothing new: skipped before anything in the checkout is touched
    for br in "${brs[@]}"; do
      if git -C "$GIT_ROOT" merge-base --is-ancestor "$br" HEAD 2>/dev/null; then echo "SKIP $br: nothing new"; else new+=("$br"); fi
    done
    [ ${#new[@]} -gt 0 ] || { echo "OK nothing to merge"; return 0; }
    brs=("${new[@]}")
    git -C "$GIT_ROOT" status --porcelain -uno | grep -qE '\.sln[x]?$' && git -C "$GIT_ROOT" checkout -q -- '*.sln*' 2>/dev/null
    # The daemon copy warmd renewed (unity_sync) is no one's work in progress: the merge commit takes it along
    [ -z "$(git -C "$GIT_ROOT" status --porcelain -uno | grep -v 'Assets/Editor/Warmd/')" ] || { echo "FAIL uncommitted changes, nothing done"; return 2; }
    start="$(git -C "$GIT_ROOT" rev-parse HEAD)"
  fi
  mine="$(git -C "$GIT_ROOT" rev-parse HEAD)"
  for i in "${!brs[@]}"; do
    br="${brs[$i]}"
    out="$(git -C "$GIT_ROOT" merge --no-ff -m "Merge $br" ${WARMD_TRAILER:+-m "$WARMD_TRAILER"} "$br" 2>&1)" || {
      if [ "${WARMD_MERGE_ATOMIC:-0}" != 1 ] && git -C "$GIT_ROOT" rev-parse -q --verify MERGE_HEAD >/dev/null; then
        printf '%s\n%s\n%s\n%s\n' "$start" "$nogate" "${brs[*]:$((i+1))}" "${merged[*]}" > "$q"
        echo "FAIL conflict in $(echo "$out" | grep -c CONFLICT) files of $br${merged[0]:+ (merged before it: ${merged[*]})}, resolve them and run warmd merge --continue"; echo "$out" | grep CONFLICT | head -8 | cut -c1-160
      else
        # WARMD_MERGE_ATOMIC=1 (the batch merge of the hooks): a conflict rolls back all, nobody is there to resolve it
        git -C "$GIT_ROOT" rev-parse -q --verify MERGE_HEAD >/dev/null && git -C "$GIT_ROOT" merge --abort 2>/dev/null
        m="$(echo "$out" | grep -m1 -E 'CONFLICT|error|fatal' | cut -c1-160)"
        merge_rollback "$start" "$mine" || { echo "FAIL merge $br: $m, not rolled back: $REPLY"; return 3; }
        echo "FAIL merge $br: $m, nothing merged"
      fi
      return 1; }
    mine="$(git -C "$GIT_ROOT" rev-parse HEAD)"
    echo "$out" | grep -q "Already up to date" && continue
    merged+=("$br")
  done
  [ ${#merged[@]} -gt 0 ] || { echo "OK nothing to merge"; return 0; }
  MERGELOCK="$STATE/merge.owner"; echo "$$" > "$MERGELOCK"; export WARMD_IN_MERGE=1
  # Windows pid next to it: a merge launched through WMI is not always visible to kill -0 of other shells
  if [ -r "/proc/$$/winpid" ]; then cat "/proc/$$/winpid" > "$MERGELOCK.win"; else rm -f "$MERGELOCK.win"; fi
  br="${merged[*]}"; export WARMD_DIFF_BASE="$start"
  # Red rolls back to the start of this merge, never further and never over a commit made meanwhile (merge_rollback).
  # Not rolled back: exit 3, the caller stops merging on top of it.
  mfail() {
    merge_rollback "$start" "$mine" || { echo "FAIL merge $br: $*; not rolled back: $REPLY"; return 3; }
    local left; left="$(git -C "$GIT_ROOT" status --porcelain -uno | cut -c4- | head -5 | tr '\n' ' ')"
    echo "FAIL merge $br: $*${left:+; kept uncommitted (written by the gate or by someone meanwhile): ${left% }}"; return 1
  }
  m="$(git -C "$GIT_ROOT" -c core.whitespace=-trailing-space,-space-before-tab,-blank-at-eof,-blank-at-eol diff --check "$start" HEAD 2>&1 | head -3 | cut -c1-160)"; [ -z "$m" ] || { mfail "$m"; return; }
  if [ $nogate = 1 ]; then :
  elif [ -n "$CFG_gate" ]; then
    if ! m="$(cd "$PROJECT" && WARMD_BIN="bash $WARMD_HOME/bin/warmd" sh -c "$CFG_gate" 2>&1)"; then mfail "$(red_lines "$m" tail)"; return; fi
  elif ! m="$(run_check 2>&1)"; then mfail "$(red_lines "$m" head)"; return; fi
  if [ $nogate = 0 ] && [ -n "$CFG_perf" ]; then m="$(perf_run 2>&1)" || { mfail "$(echo "$m" | tail -2 | tr '\n' ' ' | cut -c1-200)"; return; }; fi
  # What the gate wrote (world outputs, the renewed daemon copy) goes into the last merge commit, only into this merge's
  # own commit: a commit made meanwhile is never amended
  if [ -n "$(git -C "$GIT_ROOT" status --porcelain -uno)" ] && [ "$(git -C "$GIT_ROOT" rev-parse HEAD)" = "$mine" ]; then
    git -C "$GIT_ROOT" add -u && git -C "$GIT_ROOT" commit -q --amend --no-edit || { mfail "cannot commit what the gate wrote"; return; }
  fi
  echo "OK $(secs)s merged $br as $(git -C "$GIT_ROOT" rev-parse --short HEAD)$([ $nogate = 1 ] && echo ", no gate (--no-gate)"), not pushed"
  rm -f "$MERGELOCK" "$MERGELOCK.win"; unset WARMD_IN_MERGE WARMD_DIFF_BASE
  merge_package
  disk_after_merge
  return 0
}

# After a merge: the one player of the project, fresh, built in the background so the merge returns at once. The batch
# merge of the hooks builds it itself after all branches (WARMD_NO_PACKAGE=1). Without package_dir it says so, loudly.
merge_package() {
  [ "${WARMD_NO_PACKAGE:-0}" = 1 ] && return 0
  package_state || { [ -z "$REPLY" ] || echo "$REPLY"; return 0; }
  local common log; common="$(git -C "$GIT_ROOT" rev-parse --path-format=absolute --git-common-dir)"; log="$common/warmd-package.log"
  . "$WARMD_HOME/lib/hook.sh"
  hook_detach "$log" "$GIT_ROOT" hook-package "$(base_branch)"
  echo "OK player build started in the background into $(native_path "$PACKAGE_DIR"), log $(native_path "$log")"
}

. "$WARMD_HOME/lib/auto.sh"
