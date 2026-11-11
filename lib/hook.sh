# Agent hooks: warmd runs itself, nobody types a warmd command.
#   PreToolUse Bash  noisy known commands go through warmd run, short output, raw log kept
#   PreToolUse Agent a new agent on a task clears its pause marker, warmd watch waits for it again
#   SessionStart     after a restart or compaction: the task in a task worktree, the batch state in the shared checkout
#   SubagentStop     real tokens from the agent's transcript into the ledger, branch pushed; the last agent of a batch
#                    starts a detached merge of the finished branches (warmd merge, rollback on red) that ends the batch
# warmd init installs them, warmd init --no-hooks removes them, warmd init --hooks installs only the hooks.
# Written to .claude/settings.local.json (personal, not committed). Entries are recognised by their command ending in "hook-<name>".
# A hook never blocks the session for long: anything slower than reading files runs detached.
CACHE_ROOT="${CACHE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/warmd}"
HOOK_RAW_MAX="${HOOK_RAW_MAX:-20}"   # output up to this many lines passes through unchanged
HOOK_KEEP_LOGS="${HOOK_KEEP_LOGS:-30}"

# Known noisy commands: runner and subcommand, plain words only. Anything else is left alone.
HOOK_KNOWN='^(npm (test|ci|install|run (test|build|lint|typecheck))|pnpm (test|install|build|lint)|yarn (test|install|build|lint)|npx (jest|vitest|tsc|eslint)|jest|vitest|tsc|eslint|pytest|python3? -m pytest|cargo (build|test|check|clippy)|go (build|test|vet)|dotnet (build|test)|mvn (test|package|verify)|(\./)?gradlew? (build|test)|make( [a-z_.-]+)?)( [A-Za-z0-9_./=:@,+-]+)*$'

hook_main() { # command args...
  local cmd="$1"; shift
  case "$cmd" in
    run)          hook_run "$@";;
    hook-pre)     hook_pre;;
    hook-session) hook_session;;
    hook-subagent) hook_subagent;;
    hook-compact) auto_compact;;
    hook-job)     hook_job "$@";;
    hook-merge)   hook_merge "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)";;
    hook-package) hook_package "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" "$PWD" "${1:-}";;
    init)         case " $* " in *" --no-hooks "*) hook_remove;; *) hook_install;; esac;;
  esac
}

# ---- PreToolUse: every tool call of every agent runs this. Builtins only: no subshell, no pipe, no program. Some Windows
# machines keep kernel memory for every process start until reboot, and a fork costs 10 to 30 ms there. ----
hook_json_command() { # hook JSON -> REPLY = decoded command, return 1 when not decodable
  REPLY=""; local s="${1//[$'\n\r']/}" raw o1=$'\001' bs='\' q='"' re='"tool_name" *: *"Bash".*"command" *: *"(([^"\\]|\\.)*)"'
  [[ $s =~ $re ]] || return 1
  raw="${BASH_REMATCH[1]}"
  [ -n "$raw" ] || return 1
  raw=${raw//"$bs$bs"/$o1}; raw=${raw//"$bs$q"/$q}; raw=${raw//$o1/$bs}
  case "$raw" in *\\*) return 1;; esac   # \n, \t, \u: not touched
  REPLY="$raw"
}

hook_wrappable() { # command -> 0 when it is one simple known command
  local c="$1"
  case "$c" in *[\|\&\;\<\>\$\`\(\)\{\}\*\?\\\"\'~]*|*$'\n'*|warmd\ *|*/warmd\ *) return 1;; esac
  case "$c" in *--watch*|*" -w"|*" -w "*|*--serve*|*" dev"*|*" start"*) return 1;; esac
  [[ $c =~ $HOOK_KNOWN ]]
}

hook_pre() {
  local in="" cmd re='(^|[;&|( ])find[[:space:]]+(/|/proc)([[:space:]]|$)'
  IFS= read -r -d '' in || true
  auto_agent_start "$in" && return 0   # a new agent on a task: its pause marker goes
  auto_pre "$in" && return 0   # context full: lib/auto.sh saved the work, the agent ends with its AGENT line
  hook_json_command "$in" || return 0; cmd="$REPLY"
  # find from / under Git Bash walks /proc and holds a handle to every process it passes: hundreds of thousands of
  # zombie processes, gigabytes of kernel memory until reboot. Search a project folder instead.
  if [ "${OS:-}" = win ] || [ "${WARMD_TEST_WIN:-0}" = 1 ]; then
    if [[ $cmd =~ $re ]]; then
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"warmd: find / walks /proc under Git Bash and leaks a handle per process until reboot. Search the project or worktree folder instead."}}
'
      return 0
    fi
  fi
  hook_engine_timeout "$cmd" && return 0
  hook_repeat_guard "$in" "$cmd" && return 0
  hook_import_seed "$cmd"
  hook_wrappable "$cmd" || return 0
  hook_self_r
  # no permissionDecision on purpose: the user's own permission rules stay in charge of the rewritten command
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":{"command":"%s run -- %s"}}}\n' "$REPLY" "$cmd"
}

# Agents ran the same slow check ten times in a row without touching a file. A heavy run (engine, test, generator)
# with the same command on the same tree state runs at most HOOK_REPEAT_MAX times, the next one is denied with the reason.
# Tree state = HEAD + tracked/new files, without the .uid/.import an engine writes on its own. Entries expire after 2 hours.
# A Godot run with a window and no end stays open when its scene never quits: agents left test windows behind.
# A windowed run needs a time limit (timeout N, --quit-after N, or a --shot/--bench that quits on its own is not trusted).
# A project script run (bash/sh <file>): read it and look at its Godot calls.
# Returns 0 when every Godot call in it names --audio-driver, 1 when one does not, 2 when it calls no Godot,
# 3 when the command is no readable script run (the caller then judges the command text alone).
hook_script_quiet() { # command -> status as above
  local c="$1" re='(^|[;&| ])(bash|sh)( +-[A-Za-z-]+)* +([^ -][^ ]*)' re_cd='(^|[;&] *)cd +"?([^"&;]+)"? *&&'
  local godot='[Gg]odot[^ ]*\.(exe|x86_64)|[ /"]godot[0-9.]* ' dir="$PWD" f line cur="" vars=" " n=0 bad=0 v name
  [[ $c =~ $re ]] || return 3
  f="${BASH_REMATCH[4]}"; f="${f%\"}"; f="${f#\"}"
  if [[ $c =~ $re_cd ]]; then dir="${BASH_REMATCH[2]}"; dir="${dir%"${dir##*[! ]}"}"; fi
  case "$f" in /*|[A-Za-z]:*) ;; *) f="$dir/$f";; esac
  [ -f "$f" ] && [ -r "$f" ] || return 3
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in "#"*|"") continue;; esac
    cur="$cur $line"
    case "$line" in *\) cur="${cur%\}"; continue;; esac
    line="$cur"; cur=""
    if [[ $line =~ ^([A-Za-z_][A-Za-z_0-9]*)= ]]; then   # a variable that holds a Godot path
      name="${BASH_REMATCH[1]}"
      [[ " $line " =~ $godot ]] && vars="$vars$name "
      continue
    fi
    v=0
    [[ " $line " =~ $godot ]] && v=1
    for name in $vars; do case "$line" in *"\$$name"*|*"\${$name}"*) v=1;; esac; done
    [ "$v" = 1 ] || continue
    case " $line " in *" --headless "*|*" --import "*|*"--export"*|*" --version "*|*" --help "*) continue;; esac
    n=$((n + 1))
    case "$line" in *"--audio-driver"*) ;; *) bad=1;; esac
  done < "$f"
  [ "$n" = 0 ] && return 2
  return "$bad"
}

hook_engine_timeout() { # command -> 0 when denied (decision printed)
  local c=" $1 " godot='[Gg]odot[^ ]*\.(exe|x86_64)|[ /]godot[0-9.]* '
  [[ $c =~ $godot ]] || return 1
  case "$c" in *" --headless "*|*" --import "*|*"--export"*|*" --version "*|*" --help "*) return 1;; esac
  # a test window plays the game's sound through the user's speakers: a windowed run states its audio driver
  local drv=0 sq=3
  case "$c" in *"--audio-driver"*) drv=1;; esac
  hook_script_quiet "$c"; sq=$?
  [ "$sq" = 2 ] && return 1   # a script without a Godot call: nothing to judge
  [ "$sq" = 0 ] && drv=1
  [ "$drv" = 1 ] || {
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"warmd: a Godot run with a window plays sound on the speakers of the user. Add --audio-driver Dummy (a run that must be heard names its driver)."}}
'
    return 0
  }
  case "$c" in *"timeout "*|*"--quit-after"*|*" --quit "*) return 1;; esac
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"warmd: a Godot run with a window needs an end, or the window stays open when the scene does not quit. Put timeout 180 in front of it (or add --quit-after <frames>)."}}\n'
  return 0
}

HOOK_REPEAT_MAX="${WARMD_REPEAT_MAX:-3}"
hook_repeat_guard() { # hook json, command -> 0 when denied (decision printed)
  local cmd="$2" dir="" re_cd='^cd +"?([^"&]+)"? *&&' heavy key fp f now n=0 t=0 old=""
  heavy='([Gg]odot[^ ]*|warmd +(test|check|build|shot|bench)|gen_theme|beat_sync_check|--bench|--shot|--script +res://tests)'
  [[ $cmd =~ $heavy ]] || return 1
  if [[ $cmd =~ $re_cd ]]; then dir="${BASH_REMATCH[1]}"; dir="${dir%"${dir##*[! ]}"}"
  else dir="$PWD"; fi
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  fp="$( { git -C "$dir" rev-parse HEAD 2>/dev/null; git -C "$dir" status --porcelain 2>/dev/null | grep -vE '\.(uid|import)$'; git -C "$dir" diff 2>/dev/null; } | cksum)"
  fp="${fp%% *}"
  key="$(printf '%s|%s' "$dir" "$cmd" | cksum)"; key="${key%% *}"
  f="$CACHE_ROOT/repeat/$key"; now="$(date +%s)"
  mkdir -p "$CACHE_ROOT/repeat" 2>/dev/null || return 1
  [ -f "$f" ] && read -r old n t < "$f"
  if [ "$old" = "$fp" ] && [ $((now - ${t:-0})) -lt 7200 ]; then n=$((n + 1)); else n=1; fi
  if [ "$n" -gt "$HOOK_REPEAT_MAX" ]; then
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"warmd: this exact run already ran %s times and nothing changed since (same commit, no file edit). Its result will not differ: read the last output, change the code, or run something else."}}\n' "$HOOK_REPEAT_MAX"
    return 0
  fi
  printf '%s %s %s\n' "$fp" "$n" "$now" > "$f"
  return 1
}

# Before a Godot import: copy imports another checkout already made (lib/godot_seed.sh), so a worktree does not
# compress the same big textures again after a merge. Silent, never blocks the command.
hook_import_seed() { # command
  local c="$1" dir="" re_cd='^cd +"?([^"&]+)"? *&&' re_path='--path +"?([^" ]+)"?'
  case "$c" in *[Gg]odot*--import*|*--import*[Gg]odot*) ;; *) return 0;; esac
  if [[ $c =~ $re_cd ]]; then dir="${BASH_REMATCH[1]}"; dir="${dir%"${dir##*[! ]}"}"; else dir="$PWD"; fi
  if [[ $c =~ $re_path ]] && [ "${BASH_REMATCH[1]}" != . ]; then dir="${BASH_REMATCH[1]}"; fi
  [ -f "$dir/project.godot" ] || return 0
  . "$WARMD_HOME/lib/godot_seed.sh" 2>/dev/null || return 0
  godot_seed_imports "$dir" >/dev/null 2>&1 || true
  return 0
}

hook_self() { hook_self_r; echo "$REPLY"; }
hook_self_r() { # REPLY = how the hook calls warmd: the name when PATH finds this warmd first, else the absolute path. command -v by hand, no subshell
  local d dirs f=""; REPLY="$WARMD_HOME/bin/warmd"
  IFS=: read -r -a dirs <<< "$PATH"
  for d in "${dirs[@]}"; do
    [ -n "$d" ] || d=.
    if [ -f "$d/warmd" ] && [ -x "$d/warmd" ]; then f="$d/warmd"; break; fi
    if [ "${OS:-}" = win ] && [ -f "$d/warmd.exe" ] && [ -x "$d/warmd.exe" ]; then f="$d/warmd.exe"; break; fi
  done
  [ "$f" = "$WARMD_HOME/bin/warmd" ] && REPLY=warmd
  return 0
}

# warmd run -- <cmd>: run anything, print a short result, keep the raw log
hook_run() {
  [ "${1:-}" = "--" ] && shift
  [ $# -gt 0 ] || { echo "warmd run -- <command>"; return 2; }
  local dir="$CACHE_ROOT/runs" log rc lines bytes t0=$SECONDS out old
  mkdir -p "$dir"
  log="$dir/$(date +%Y%m%d-%H%M%S)-$$.log"
  "$@" > "$log" 2>&1 < /dev/null; rc=$?
  lines=$(wc -l < "$log"); bytes=$(wc -c < "$log")
  ls -1t "$dir"/*.log 2>/dev/null | tail -n +$((HOOK_KEEP_LOGS + 1)) | while read -r old; do rm -f "$old"; done
  if [ "$lines" -le "$HOOK_RAW_MAX" ]; then
    cat "$log"
    [ "$rc" = 0 ] || echo "FAIL exit $rc"
    return $rc
  fi
  [ -n "$(type -t digest_log)" ] || . "$WARMD_HOME/lib/digest.sh"
  if [ "$rc" = 0 ]; then
    echo "OK exit 0, $lines lines, $bytes B, $((SECONDS - t0))s, raw log $log"
    sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$log" | tr -d '\r' | grep . | tail -n 3 | cut -c1-160
  else
    echo "FAIL exit $rc, $lines lines, $bytes B, $((SECONDS - t0))s, raw log $log"
    out="$(digest_log "$log" 2>/dev/null)" || out="$(sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$log" | tr -d '\r' | grep -iE 'error|fail|panic|traceback|assert|expected|exception' | awk '!s[$0]++' | cut -c1-160 | head -12)"
    [ -n "$out" ] || out="$(tail -n 12 "$log" | cut -c1-160)"
    printf '%s\n' "$out"
  fi
  return $rc
}

# ---- shared lookups: builtins where they can, every fork costs 10 to 30 ms on Windows and a hook gets 2 s ----
hook_common() { git ${1:+-C "$1"} rev-parse --path-format=absolute --git-common-dir 2>/dev/null; }
hook_mainwt() { local l; l="$(git --git-dir="$1" worktree list --porcelain 2>/dev/null)"; l="${l%%$'\n'*}"; echo "${l#worktree }"; }   # common dir -> shared checkout
# C:/x and /c/x become one form. A short 8.3 name (RUNNER~1) or a mount (/tmp on a short TEMP) is not the long form git reports:
# cygpath -l makes it long, the fork only happens for those paths.
hook_abs() {
  REPLY=""; local o="$PWD"; CDPATH='' cd "$1" 2>/dev/null || return 1; REPLY="$PWD"; cd "$o" || return 1
  if [ "${OS:-}" = win ] && { [[ $REPLY == *'~'* ]] || [[ $REPLY != /?/* ]]; }; then
    local w; w="$(cygpath -l -m "$REPLY" 2>/dev/null)" || return 0; [[ $w == ?:/* ]] || return 0
    local d="${w:0:1}"; REPLY="/${d,,}${w:2}"
  fi
}
hook_task_wt() { # task file -> REPLY = its worktree as written in the task
  REPLY=""; local line re='First run: cd "([^"]*)"'
  while IFS= read -r line || [ -n "$line" ]; do [[ $line =~ $re ]] && { REPLY="${BASH_REMATCH[1]}"; return 0; }; done < "$1"
  return 1
}
# Index of every task of this repo: HOOK_TF task files, HOOK_TW their worktrees (absolute). Handoff index first, task dirs as fallback.
hook_index() { # common dir, shared checkout
  HOOK_TF=(); HOOK_TW=(); local f tf seen=" "
  for f in "$1"/warmd-handoff/*.task "$2"/.warmd/tasks/*.md "$2"/*/.warmd/tasks/*.md; do
    [ -f "$f" ] || continue
    if [ "${f%.task}" != "$f" ]; then IFS= read -r tf < "$f" || continue; tf="${tf%$'\r'}"; else tf="$f"; fi
    case "$seen" in *" ${tf##*/} "*) continue;; esac
    [ -f "$tf" ] && hook_task_wt "$tf" && hook_abs "$REPLY" || continue
    HOOK_TF+=("$tf"); HOOK_TW+=("$REPLY"); seen="$seen${tf##*/} "
  done
}
hook_task_of() { # absolute worktree -> REPLY = its task file
  # A reused worktree is named for its first task and keeps every old task file pointing at it: the branch names the task it holds now.
  local i first="" g="" h=""
  { IFS= read -r g < "$1/.git"; } 2>/dev/null; g="${g%$'
'}"; g="${g#gitdir: }"; [ -d "$1/.git" ] && g="$1/.git"
  [ -n "$g" ] && { IFS= read -r h < "$g/HEAD"; } 2>/dev/null; h="${h%$'
'}"; h="${h#ref: refs/heads/warmd/}"
  for i in "${!HOOK_TW[@]}"; do
    [ "${HOOK_TW[$i]}" = "$1" ] || continue
    REPLY="${HOOK_TF[$i]##*/}"; [ "${REPLY%.md}" = "$h" ] && { REPLY="${HOOK_TF[$i]}"; return 0; }
    [ -n "$first" ] || first="${HOOK_TF[$i]}"
  done
  REPLY="$first"; [ -n "$first" ]
}
hook_agent_line() { # common dir, task file [, state text for the prompt] -> AGENT line to start or continue the task
  local tf="$2" st="${3:-}" name tier="" agent model note k v
  name="${tf##*/}"; name="${name%.md}"
  { read -r _; read -r tier; } < "$1/warmd-handoff/$name.task" 2>/dev/null
  [ -n "$tier" ] || read -r tier < "${tf%.md}.tier" 2>/dev/null
  tier="${tier%$'\r'}"
  case "$tier" in cheap) agent=warmd-scout; model=haiku;; top) agent=warmd-worker; model=opus;; *) tier=mid; agent=warmd-worker; model=sonnet;; esac
  agent="${AGENT_NS:-}$agent"
  if [ -f "$HOOK_PROJ/warmd.conf" ]; then
    while IFS='=' read -r k v || [ -n "$k" ]; do k="${k//[[:space:]]/}"; v="${v//[[:space:]\"]/}"; [ "$k" = "$tier" ] && [ -n "$v" ] && model="$v"; done < "$HOOK_PROJ/warmd.conf"
  fi
  note="$1/warmd-handoff/$name.md"
  if [ -f "$note" ]; then
    echo "AGENT $name: subagent_type=$agent model=$model prompt=\"Read $tf, then $(native_path "$note"), and continue from there. Do not redo finished work.$st\""
  else
    echo "AGENT $name: subagent_type=$agent model=$model prompt=\"Read $tf and do it.$st\""
  fi
}

# Instructions and agent definitions written by an older warmd are renewed in the shared checkout, like the hooks themselves.
hook_instr() { # shared checkout
  local f a d x y said=""
  for f in CLAUDE.md AGENTS.md; do
    [ -f "$1/$f" ] && instr_sync "$1/$f" && echo "warmd: the warmd block in $f renewed to the current version, commit it."
  done
  for a in "$WARMD_HOME"/agents/warmd-*.md; do
    d="$1/.claude/agents/${a##*/}"; [ -f "$d" ] || continue
    x=""; y=""; IFS= read -r -d '' x < "$a"; IFS= read -r -d '' y < "$d"
    [ "$x" = "$y" ] && continue
    cp "$a" "$d" && said="$said ${a##*/}"
  done
  [ -z "$said" ] || echo "warmd: agent definitions renewed:$said"
  return 0
}

# SessionStart (startup, resume, clear, compact): stdout becomes context. A task worktree gets its task and the brief back,
# the shared checkout gets the running batch: who is done, who is open, the AGENT line for each open one, the last merge result.
# Warm start at session start: the engine of an open task worktree starts now, in the background and through the normal
# queue (slots, RAM wait), so the agent's first warmd check finds a warm editor. Unity projects only; a live one is kept.
hook_prewarm() { # worktree
  [ "${WARMD_NO_PREWARM:-0}" = 1 ] && return 0
  local v; for v in "$1"/ProjectSettings/ProjectVersion.txt "$1"/*/ProjectSettings/ProjectVersion.txt; do
    [ -f "$v" ] || continue
    ( cd "${v%/ProjectSettings/ProjectVersion.txt}" || exit 0; WARMD_BASE=1 WARMD_DETACHED=1 nohup bash "$WARMD_HOME/bin/warmd" ping > /dev/null 2>&1 < /dev/null & )
    return 0
  done
  return 0
}
# Plugin install without warmd init: the instructions block arrives as session context instead of a CLAUDE.md edit.
hook_plugin_instr() { # project dir
  local f x
  for f in "$1/CLAUDE.md" "$1/AGENTS.md"; do
    [ -f "$f" ] || continue; x=""; IFS= read -r -d '' x < "$f"
    [[ $x == *'Use `warmd` for every build'* ]] && return 0
  done
  [ -f "$WARMD_HOME/agents/INSTRUCTIONS.md" ] || return 0
  cat "$WARMD_HOME/agents/INSTRUCTIONS.md"
  echo "- The warmd command is on the PATH of your Bash tool. Its agents are warmd:warmd-worker, warmd:warmd-scout and warmd:warmd-merge."
}
hook_session() {
  local in src="" common here tf brief main batch donef wt br ahead dirty open=0 n=0 log base l re='"source" *: *"([a-z]+)"'
  local -A state=()
  in="$(cat)"; [[ $in =~ $re ]] && src="${BASH_REMATCH[1]}"
  [ "${WARMD_PLUGIN:-0}" = 1 ] && hook_plugin_instr "${CLAUDE_PROJECT_DIR:-$PWD}"
  here="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  hook_refresh
  common="$(hook_common)" || return 0
  [ -n "$(type -t native_path)" ] || . "$WARMD_HOME/lib/platform.sh"
  main="$(hook_mainwt "$common")"
  hook_index "$common" "$main"
  hook_abs "$here"; here="$REPLY"; hook_abs "$main"; main="$REPLY"
  [ "$here" = "$main" ] && hook_instr "$main"
  if [ "$here" != "$main" ] && hook_task_of "$here"; then
    tf="$REPLY"
    echo "warmd: session ${src:-restarted}. Your task and the shared brief again, continue the task."
    cat "$tf"
    l="$common/warmd-handoff/${tf##*/}"; [ -f "$l" ] && { echo; cat "$l"; }
    brief="$common/warmd-shared.md"
    [ -f "$brief" ] && { echo; cat "$brief"; }
    return 0
  fi
  batch="$common/warmd-batch"; donef="$common/warmd-batch-done"; log="$common/warmd-automerge.log"
  if [ -s "$batch" ]; then
    [ -f "$donef" ] && while IFS='	' read -r wt l _; do [ -n "$wt" ] && state[$wt]="$l"; done < "$donef"
    base="$(hook_base "$main")"; base="${base%%|*}"; [ -n "$base" ] || base="$(git -C "$main" branch --show-current)"
    HOOK_PROJ="${HOOK_TF[0]%/.warmd/tasks/*}"
    if [ "$src" = compact ]; then echo "warmd: a batch runs (context compacted, agents may still run, start only the ones you do not see)."
    else echo "warmd: a batch runs (session ${src:-restarted}, agents of the old session are gone, start the open ones)."; fi
    while IFS= read -r wt; do
      wt="${wt%$'\r'}"; [ -n "$wt" ] || continue; n=$((n+1))
      br=""; dirty=0
      while IFS= read -r l; do case "$l" in "# branch.head "*) br="${l#\# branch.head }";; \#*) ;; ?*) dirty=$((dirty+1));; esac; done < <(git -C "$wt" status --porcelain=v2 --branch 2>/dev/null)
      ahead="$(git -C "$wt" rev-list --count "$base..HEAD" 2>/dev/null)" || ahead='?'
      if [ -n "${state[$wt]:-}" ]; then echo "- ${br:-$wt}: done (${state[$wt]}), $ahead ahead, $dirty uncommitted"
      else
        open=$((open+1)); echo "- ${br:-$wt}: open, $ahead ahead, $dirty uncommitted"
        hook_prewarm "$wt"
        # The old session's agents are gone after a restart, after a compaction they may still run: the line says to stop them first
        hook_abs "$wt" && hook_task_of "$REPLY" && echo "  $(hook_agent_line "$common" "$(native_path "$REPLY")" " State: ${br:-$wt} at $(git -C "$wt" rev-parse --short HEAD 2>/dev/null), $ahead ahead of $base, $dirty uncommitted. Stop the previous agent of this task first, never two in one worktree.")"
      fi
    done < "$batch"
    echo "$open of $n open. When the last one stops, warmd merges the finished branches by itself."
    # The open agents start again now: a batch from before a reboot must not count as stale (batch_guard drops markers older than 240 min).
    [ "$open" -gt 0 ] && [ "$src" != compact ] && touch "$batch"
  fi
  if [ -s "$log" ]; then
    echo "warmd: last automatic merge:"; tail -n 12 "$log"; mv -f "$log" "$log.seen"
  fi
  return 0
}

# Reads the hook JSON on stdin and the agent's transcript. Prints: task name, task path, tokens, tool calls, outcome.
# Tokens: input, cache write, cache read and output summed over every turn of the agent. A turn is written as one line per
# content block, all with the same message id and usage: each id counts once.
# Outcome from the agent's last text: ESCALATE: line -> escalated, AGENT line -> handoff, else ok.
HOOK_PY_TRANSCRIPT='
import json, re, sys
h = json.load(sys.stdin)
p = h.get("agent_transcript_path") or h.get("transcript_path") or ""
pat = re.compile(r"((?:[A-Za-z]:)?[^\s\"<>|]*[\/]\.warmd[\/]tasks[\/]([A-Za-z0-9_.-]+)\.md)")
task = None; usage = {}; calls = set(); text = ""; seen_assistant = False
for line in open(p, encoding="utf-8", errors="replace"):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    m = e.get("message") or {}
    c = m.get("content")
    if e.get("type") == "user" and not seen_assistant and task is None:
        s = c if isinstance(c, str) else " ".join(b.get("text", "") for b in (c or []) if isinstance(b, dict) and b.get("type") == "text")
        r = pat.search(s)
        if r:
            task = (r.group(2), r.group(1).replace("\\", "/"))
    if e.get("type") == "assistant":
        seen_assistant = True
        if m.get("usage"):
            usage[m.get("id") or len(usage)] = m["usage"]
        for b in c if isinstance(c, list) else []:
            if b.get("type") == "tool_use":
                calls.add(b.get("id"))
            elif b.get("type") == "text" and b.get("text", "").strip():
                text = b["text"]
if not task:
    sys.exit(1)
tok = "-"
if usage:
    tok = str(sum(int(u.get(k) or 0) for u in usage.values() for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens")))
# ctx: how full the context is now, the last turn only. tok above is the cost over all turns.
ctx = "-"
if usage:
    last = list(usage.values())[-1]
    ctx = str(sum(int(last.get(k) or 0) for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens")))
import os
if os.environ.get("WARMD_LASTMSG") and text.strip():
    open(os.environ["WARMD_LASTMSG"], "w", encoding="utf-8").write(text.strip() + "\n")
out = "escalated" if re.search(r"(?m)^\s*ESCALATE:", text) else "handoff" if re.search(r"(?m)^\s*AGENT \S+:", text) else "ok"
print("\t".join([task[0], task[1], tok, str(len(calls)), out, ctx]))
'

# SubagentStop: parse, then hand everything slow (ledger, push, merge) to a detached job and return at once.
hook_subagent() {
  local in="" py r name tf tokens calls outcome wt common
  IFS= read -r -d '' in || true
  hook_py_r || return 0; py="$REPLY"
  local last="${CACHE_ROOT}/lastmsg-$$-$RANDOM.txt"; [ -d "$CACHE_ROOT" ] || mkdir -p "$CACHE_ROOT"
  r="$(WARMD_LASTMSG="$last" "$py" -c "$HOOK_PY_TRANSCRIPT" 2>/dev/null <<< "$in")" || { [ -e "$last" ] && rm -f "$last"; return 0; }
  IFS='	' read -r name tf tokens calls outcome _ <<< "$r"
  [ -n "$name" ] || return 0
  if [ ! -f "$tf" ]; then   # path with spaces or relative in the prompt: the task index knows it
    tf=""; common="$(hook_common)" && { IFS= read -r tf < "$common/warmd-handoff/$name.task"; } 2>/dev/null
    [ -f "$tf" ] || return 0
  fi
  hook_task_wt "$tf" && wt="$REPLY" && [ -d "$wt" ] || return 0
  common="$(hook_common "$wt")" || return 0
  hook_lastmsg "$common" "$name" "$last"
  hook_detach "$common/warmd-hook.log" "$wt" hook-job "$name" "$wt" "$tokens" "$calls" "$outcome"
  return 0
}

# The agent's last message goes into its handoff note: findings it could only write into its answer are not lost
# with the session. At most 40 lines, the newest message last.
hook_lastmsg() { # common name file
  [ -s "$3" ] || { [ -e "$3" ] && rm -f "$3"; return 0; }
  [ -d "$1/warmd-handoff" ] || mkdir -p "$1/warmd-handoff"
  local now l n=0; printf -v now '%(%F %T)T' -1
  { echo "## Last message of the agent, $now"
    while [ $n -lt 40 ] && IFS= read -r l; do printf '%s\n' "$l"; n=$((n+1)); done < "$3"
  } >> "$1/warmd-handoff/$2.md"
  rm -f "$3"
}

# hook_detach <log> <dir> <warmd args...>: run warmd so it outlives the session that ran the hook.
# Windows: a nohup child stays in the session's process tree, job object and console, so claude -p ending can take it along.
# Win32_Process.Create starts it from the WMI service instead: no parent, no job, own hidden console. The environment does
# not come along, so a small script carries it. The launcher itself runs in the background: the hook returns at once.
hook_detach() {
  local log="$1" dir="$2" sh a v bash nsh ndir; shift 2
  if [ "${OS:-}" = win ] && [ -z "${WARMD_NO_CIM:-}" ] && hook_winbash && bash="$REPLY"; then
    sh="${log%/*}/warmd-job-$$-$RANDOM.sh"
    hook_native "$sh"; nsh="$REPLY"; hook_native "$dir"; ndir="$REPLY"
    {
      echo 'trap '"'"'rm -f "$0"'"'"' EXIT'
      for v in PATH HOME XDG_CACHE_HOME WARMD_HOME TMPDIR TEMP TMP CLAUDE_PROJECT_DIR; do [ -n "${!v+x}" ] && printf 'export %s=%q\n' "$v" "${!v}"; done
      printf 'export WARMD_DETACHED=1 WARMD_VIA=cim\ncd %q || exit 1\nbash %q' "$dir" "$WARMD_HOME/bin/warmd"
      for a in "$@"; do printf ' %q' "$a"; done
      printf ' >> %q 2>&1 < /dev/null\n' "$log"
    } > "$sh"
    # CIM refused (policy, no WMI): the old nohup path, better than nothing
    ( powershell.exe -NoProfile -NonInteractive -Command "\$s = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ShowWindow=[uint16]0}; \$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine='\"$bash\" \"$nsh\"'; CurrentDirectory='$ndir'; ProcessStartupInformation=\$s}; exit \$r.ReturnValue" > /dev/null 2>&1 < /dev/null \
        || { rm -f "$sh"; cd "$dir" && WARMD_DETACHED=1 WARMD_VIA=nohup exec nohup bash "$WARMD_HOME/bin/warmd" "$@" >> "$log" 2>&1 < /dev/null; } & )
    return 0
  fi
  ( cd "$dir" && WARMD_DETACHED=1 WARMD_VIA=nohup nohup bash "$WARMD_HOME/bin/warmd" "$@" >> "$log" 2>&1 < /dev/null & )
}
# native_path into REPLY, no subshell; only a path outside a drive (/tmp, /usr) still asks cygpath
hook_native() {
  case "$1" in
    /[a-zA-Z]/*) local d="${1:1:1}"; REPLY="${d^^}:${1:2}";;
    [a-zA-Z]:*) local b='\'; REPLY="${1//"$b"//}";;
    *) REPLY="$(native_path "$1")";;
  esac
}
# REPLY = Windows path of the bash that runs the detached job. cygpath once, then from the cache while the file is there.
hook_winbash() {
  REPLY=""; local f="$CACHE_ROOT/winbash" b=""
  { read -r b < "$f"; } 2>/dev/null
  if [ -z "$b" ] || [ ! -f "$b" ]; then
    b="$(cygpath -w /usr/bin/bash.exe 2>/dev/null)" && [ -f "$b" ] || return 1
    { [ -d "$CACHE_ROOT" ] || mkdir -p "$CACHE_ROOT"; printf '%s\n' "$b" > "$f"; } 2>/dev/null
  fi
  REPLY="$b"
}

# hook-job <name> <worktree> <tokens> <calls> <outcome>: detached. Ledger and push through warmd finish, then the batch check.
hook_job() {
  local name="$1" wt="$2" tokens="${3:--}" calls="${4:--}" outcome="${5:-ok}" common here
  cd "$wt" || return 1
  here="$(pwd)"; common="$(hook_common)" || return 1
  export WARMD_DETACHED=1
  echo "$(date '+%F %T') $name stopped: $outcome, $tokens tokens, $calls calls (detached via ${WARMD_VIA:-direct})"
  # An agent ends its turn to wait for its own background run (a Bash call may take 600 s, a queued Unity run longer).
  # While that run works or waits in a queue, nothing is recorded: no stop, no escalation, the engine stays; the agent comes back.
  if wt_run_active "$here"; then echo "$(date '+%F %T') $name: its warmd run still works or waits here, no stop recorded"; return 0; fi
  outcome="$(auto_stop "$common" "$name" "$here" "$outcome")"   # failed or red: next tier queued for warmd watch
  if [ "$outcome" = handoff ]; then   # a fresh agent continues, the task is not done
    git remote get-url origin >/dev/null 2>&1 && git push -q -u origin HEAD 2>/dev/null
    hook_cool; return 0
  fi
  bash "$WARMD_HOME/bin/warmd" finish --tokens "$tokens" --calls "$calls" --outcome "$outcome"
  hook_cool
  printf '%s\t%s\t%s\n' "$here" "$outcome" "$(git -C "$here" branch --show-current 2>/dev/null)" >> "$common/warmd-batch-done"
  hook_merge "$common"
}

# The agent is gone, its warm engine is not: an idle editor holds gigabytes for 30 minutes while the next agents wait for RAM.
# A fresh agent on the same task starts it again in a minute; a stuck machine costs far more.
# --idle: an agent that ended its turn while its own warmd test runs in the background keeps the engine, the test goes on.
hook_cool() { echo "$(date '+%F %T') $(bash "$WARMD_HOME/bin/warmd" stop --idle 2>&1 | tail -1)"; }

# Base branch, full= and project of the shared checkout, the way warmd itself sees them there: base|full|project
hook_base() { # shared checkout
  ( unset WARMD_PROJECT; cd "$1" 2>/dev/null && detect_project >/dev/null 2>&1 && printf '%s|%s|%s\n' "$(base_branch)" "${CFG_full:-}" "$PROJECT" )
}
# REPLY = the worktree that has <base> checked out. None has it: a clean one is made next to the task worktrees,
# with the slow caches of the shared checkout's project and its warmd.conf when the branch does not carry one.
hook_base_wt() { # common dir, shared checkout, base, project of the shared checkout
  REPLY=""; local p b rel
  while IFS='|' read -r p b; do [ "$b" = "$3" ] && [ -d "$p" ] && { REPLY="$p"; return 0; }; done \
    < <(git --git-dir="$1" worktree list --porcelain 2>/dev/null | tr -d '\r' | awk '/^worktree /{p=substr($0,10)} /^branch /{b=$2; sub("refs/heads/","",b); print p"|"b}')
  p="$(dirname "$2")/.warmd-worktrees/$(basename "$2")/base-${3//\//-}"
  [ -e "$p" ] && return 1   # a folder there that is no checkout of the base: never overwritten
  mkdir -p "${p%/*}" && git -C "$2" worktree add -q "$p" "$3" >/dev/null 2>&1 || return 1
  rel="$(git -C "$4" rev-parse --show-prefix 2>/dev/null)"; rel="${rel%/}"
  [ -f "$4/warmd.conf" ] && [ ! -f "$p${rel:+/$rel}/warmd.conf" ] && cp "$4/warmd.conf" "$p${rel:+/$rel}/warmd.conf"
  ( cd "$p" && unset WARMD_PROJECT && detect_project >/dev/null 2>&1 && . "$WARMD_HOME/adapters/$ADAPTER.sh" && { a_seed "$4" "$PROJECT"; seed_links "$4" "$PROJECT"; } ) >/dev/null 2>&1
  echo "$(date '+%F %T') made $p for $3, no worktree had it checked out"
  REPLY="$p"
}

# The last stopped agent of a batch merges: every ok branch one by one through warmd merge, red or conflict rolls back.
# Escalated tasks stay in the batch for the next tier, everything else leaves it. An empty batch ends.
hook_merge() { # common dir
  local common="$1" batch="$1/warmd-batch" done="$1/warmd-batch-done" lock="$1/warmd-automerge.lock" log="$1/warmd-automerge.log"
  local main wt br oc out rc pid keep="" first=1 merged=0 todo=()
  [ -s "$batch" ] || return 0
  # Finished by wt_finished, not by the path alone: a reused worktree whose line names the branch of its previous task
  # holds a new task that still runs, the batch is not over (it ended and dropped the running worktree from the marker).
  declare -F wt_finished >/dev/null || . "$WARMD_HOME/lib/team.sh"
  while read -r wt; do [ -z "$wt" ] || wt_finished "$common" "$wt" || return 0; done < "$batch"
  # One merge at a time: the lock holds the system pid of its merge (a job started through CIM lives in another session,
  # its shell pid means nothing here). A dead pid or a lock older than 60 minutes is stale.
  if [ -d "$lock" ]; then
    pid=""; read -r pid 2>/dev/null < "$lock/pid"
    { [ -n "$pid" ] && ! pid_alive "$pid"; } || [ -n "$(find "$lock" -maxdepth 0 -mmin +60 2>/dev/null)" ] && rm -rf "$lock"
  fi
  mkdir "$lock" 2>/dev/null || return 0
  pid=$$; [ -r "/proc/$$/winpid" ] && read -r pid < "/proc/$$/winpid"
  echo "$pid" > "$lock/pid"; local me="$pid"
  hook_unlock() { local p=""; read -r p 2>/dev/null < "$lock/pid"; [ "$p" = "$me" ] && rm -rf "$lock"; }   # never someone else's lock
  main="$(hook_mainwt "$common")"
  # The target is the base branch as base_branch sees it, never whatever branch the shared checkout stands on.
  # A base checked out in another worktree is merged there; without one a clean worktree for it is made.
  local base full=0 ship="" ob proj tgt="" cfgfull pre="" dirty
  IFS='|' read -r base cfgfull proj <<< "$(hook_base "$main")"
  [ -n "$base" ] || { echo "$(date '+%F %T') STOP no base branch found from $main, batch stays open" >> "$log"; hook_unlock; return 0; }
  # full=ci: this machine never runs the full suite, so no local merge gate either; warmd ship merges through CI.
  # Compared with origin too: a stale local base would count work already shipped as new and merge it again.
  [ "$cfgfull" = ci ] && full=1
  git -C "$main" fetch -q origin 2>/dev/null; ob="origin/$base"
  # Sorted against the base branch itself before any checkout is made or touched: a branch already in it is nothing new
  while read -r wt; do
    [ -n "$wt" ] || continue
    oc="$(grep -F "$wt	" "$done" | tail -1 | cut -f2)"; br="$(git -C "$wt" branch --show-current 2>/dev/null)"
    if [ "$oc" = escalated ]; then pre+="WAIT $br escalated, stays in the batch"$'\n'; keep="$keep$wt"$'\n'; continue; fi
    [ "$oc" = ok ] || { pre+="SKIP $br: $oc"$'\n'; continue; }
    { [ -z "$br" ] || git -C "$main" merge-base --is-ancestor "$br" "refs/heads/$base" 2>/dev/null; } && { pre+="SKIP $br: nothing new"$'\n'; continue; }
    git -C "$main" rev-parse -q --verify "$ob" >/dev/null && git -C "$main" merge-base --is-ancestor "$br" "$ob" 2>/dev/null && { pre+="SKIP $br: already on $ob"$'\n'; continue; }
    [ $full = 1 ] && { ship="$ship $br"; continue; }
    todo+=("$br")
  done < "$batch"
  if [ ${#todo[@]} -gt 0 ]; then
    if ! hook_base_wt "$common" "$main" "$base" "$proj" >> "$log" 2>&1; then
      echo "$(date '+%F %T') STOP no checkout of $base and none could be made, batch stays open. Fix it, then run: warmd hook-merge" >> "$log"; hook_unlock; return 0
    fi
    tgt="$REPLY"
    # Someone's work in progress in the base checkout: nothing merged, nothing touched (only the copies warmd itself
    # renews, the daemon copy and Unity's .sln, are no one's work). An open merge there counts too.
    dirty="$(git -C "$tgt" status --porcelain -uno 2>/dev/null | cut -c4- | grep -vE 'Assets/Editor/Warmd/|\.slnx?$' | head -5 | tr '\n' ' ')"
    git -C "$tgt" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 && dirty="${dirty}(an open merge) "
    if [ -n "$dirty" ]; then
      { echo "$(date '+%F %T') batch finished, merging into $base in $tgt"; printf '%s' "$pre"
        echo "STOP the checkout of $base in $tgt is not ready: uncommitted changes in ${dirty% }, nothing merged and nothing touched, batch stays open. Commit them, then run: warmd hook-merge"; } >> "$log"
      hook_unlock; return 0
    fi
  fi
  {
    if [ -n "$tgt" ]; then echo "$(date '+%F %T') batch finished, merging into $base in $tgt"; else echo "$(date '+%F %T') batch finished, nothing to merge into $base here"; fi
    printf '%s' "$pre"
    # Several green branches: one warmd merge, one gate for all of them. Red or a conflict rolls all of them back, then
    # they go one by one, so only the bad one stays out. One branch goes the single way at once.
    # Exit 3: red but not rolled back (a commit made meanwhile): nothing more is merged on top of it.
    if [ ${#todo[@]} -gt 1 ]; then
      out="$(cd "$tgt" && WARMD_BASE=1 WARMD_BASE_BRANCH="$base" WARMD_NO_PACKAGE=1 WARMD_MERGE_ATOMIC=1 bash "$WARMD_HOME/bin/warmd" merge "${todo[@]}" 2>&1)"; rc=$?
      echo "$out" | grep -E '^(OK|FAIL)' | head -3
      if [ "$rc" = 0 ]; then merged=1; todo=()
      elif [ "$rc" = 3 ]; then
        echo "STOP a red merge into $base in $tgt was not rolled back (FAIL line above says why), nothing more merged, batch stays open. Check it, then run: warmd hook-merge"
        hook_unlock; return 0
      elif echo "$out" | grep -qE 'only from a checkout|uncommitted changes'; then
        echo "STOP the checkout of $base in $tgt is not ready, batch stays open. Fix it, then run: warmd hook-merge"
        hook_unlock; return 0
      else echo "together red or in conflict: one by one"; fi
    fi
    for br in "${todo[@]}"; do
      out="$(cd "$tgt" && WARMD_BASE=1 WARMD_BASE_BRANCH="$base" WARMD_NO_PACKAGE=1 bash "$WARMD_HOME/bin/warmd" merge "$br" 2>&1)"; rc=$?
      git -C "$tgt" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 && git -C "$tgt" merge --abort 2>/dev/null
      echo "$out" | grep -E '^(OK|FAIL)' | head -3
      [ "$rc" = 0 ] && merged=1
      if [ "$rc" = 3 ]; then
        echo "STOP a red merge into $base in $tgt was not rolled back (FAIL line above says why), nothing more merged, batch stays open. Check it, then run: warmd hook-merge"
        hook_unlock; return 0
      fi
      if [ "$rc" != 0 ] && [ $first = 1 ] && echo "$out" | grep -qE 'only from a checkout|uncommitted changes'; then
        echo "STOP the checkout of $base in $tgt is not ready, batch stays open. Fix it, then run: warmd hook-merge"
        hook_unlock; return 0
      fi
      first=0
    done
    if [ -n "$ship" ]; then
      echo "SHIP full=ci, no local merge:$ship"
      auto_queue "$common" "SHIP batch done, full=ci merges through CI: warmd ship$ship"
    fi
    # The merge gate warmed an engine in the base checkout: it would hold gigabytes and a slot for nobody
    [ $full = 1 ] || [ -z "$tgt" ] || echo "$(date '+%F %T') base checkout: $(cd "$tgt" && bash "$WARMD_HOME/bin/warmd" stop --idle 2>&1 | tail -1)"
    if [ -n "$keep" ]; then
      printf '%s' "$keep" > "$batch"; : > "$done"; echo "OK merged, batch waits for the escalated tasks"
    else
      rm -f "$batch" "$done"; echo "OK batch ended"
      # The finished worktrees left the batch: their engine caches go back to the disk
      (cd "${tgt:-$main}" && WARMD_BASE=1 bash "$WARMD_HOME/bin/warmd" disk --free 2>&1 | tail -1)
    fi
  } >> "$log" 2>&1
  hook_unlock
  # One player for the user, fresh after every batch: world step and warmd package into package_dir, after the lock,
  # so a player that still runs and is waited for never holds up the next batch's merge.
  [ $merged = 1 ] && hook_package "$common" "$tgt" "$base" >> "$log" 2>&1
  return 0
}
# hook_package <common dir> <base checkout> <base>: only with package_dir in the project's warmd.conf. One at a time:
# a second request while one waits for the player to close is that one's job, it builds the newest base anyway.
hook_package() {
  local lock="$1/warmd-package.lock" pid="" out rc
  ( cd "$2" 2>/dev/null && unset WARMD_PROJECT && detect_project >/dev/null 2>&1 && [ -n "${CFG_package_dir:-}" ] ) || return 0
  if [ -d "$lock" ]; then
    read -r pid 2>/dev/null < "$lock/pid"
    { [ -n "$pid" ] && pid_alive "$pid"; } && { echo "$(date '+%F %T') package: one waits or builds already (pid $pid), it takes this merge along"; return 0; }
    rm -rf "$lock"
  fi
  mkdir "$lock" 2>/dev/null || return 0
  pid=$$; [ -r "/proc/$$/winpid" ] && read -r pid < "/proc/$$/winpid"; echo "$pid" > "$lock/pid"
  echo "$(date '+%F %T') package: world step and player for the merged $3"
  out="$(cd "$2" && WARMD_BASE=1 WARMD_BASE_BRANCH="$3" WARMD_DETACHED=1 bash "$WARMD_HOME/bin/warmd" package 2>&1)"; rc=$?
  echo "$out" | grep -E '^(OK|FAIL|WAIT)' | head -4
  echo "$(date '+%F %T') base checkout: $(cd "$2" && bash "$WARMD_HOME/bin/warmd" stop --idle 2>&1 | tail -1)"
  rm -rf "$lock"; return $rc
}

hook_settings() { echo "$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.claude/settings.local.json"; }

hook_py() { hook_py_r || return 1; echo "$REPLY"; }
# REPLY = a python that imports json. The name that worked stays in the cache: the probe starts python, the hooks need it
# at every agent stop and every minute per agent, and a python start is several process objects on Windows.
hook_py_r() {
  REPLY=""; local p="" f="$CACHE_ROOT/python"
  { read -r p < "$f"; } 2>/dev/null
  [ -n "$p" ] && hash "$p" 2>/dev/null && { REPLY="$p"; return 0; }
  for p in python3 python; do
    "$p" -c 'import json' >/dev/null 2>&1 || continue
    REPLY="$p"; { [ -d "$CACHE_ROOT" ] || mkdir -p "$CACHE_ROOT"; echo "$p" > "$f"; } 2>/dev/null; return 0
  done
  return 1
}

# mode add|remove, settings file, hook command prefix
hook_edit() {
  "$(hook_py)" -c '
import json, os, re, sys
mode, path, self = sys.argv[1:4]
ours = re.compile(r"warmd.* hook-(pre|session|subagent|compact)$")
try:
    data = json.load(open(path))
except FileNotFoundError:
    data = {}
hooks = data.setdefault("hooks", {})
def strip(groups):
    out = []
    for g in groups:
        g["hooks"] = [h for h in g.get("hooks", []) if not ours.search(h.get("command", ""))]
        if g["hooks"]:
            out.append(g)
    return out
for ev in list(hooks):
    hooks[ev] = strip(hooks[ev])
    if not hooks[ev]:
        del hooks[ev]
if mode == "add":
    hooks.setdefault("PreToolUse", []).append({"matcher": "Bash|Agent|Task", "hooks": [{"type": "command", "command": self + " hook-pre"}]})
    hooks.setdefault("SessionStart", []).append({"hooks": [{"type": "command", "command": self + " hook-session"}]})
    hooks.setdefault("SubagentStop", []).append({"hooks": [{"type": "command", "command": self + " hook-subagent"}]})
    hooks.setdefault("PreCompact", []).append({"hooks": [{"type": "command", "command": self + " hook-compact"}]})
if not hooks:
    del data["hooks"]
if not data:
    if os.path.exists(path):
        os.remove(path)
else:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")
' "$1" "$2" "$3"
}

hook_install() {
  local f; f="$(hook_settings)"
  [ "${WARMD_PLUGIN:-0}" = 1 ] && { echo "OK hooks come from the warmd plugin, nothing written to $f"; return 0; }
  hook_py >/dev/null || { echo "FAIL warmd hooks need python3 or python to edit $f"; return 1; }
  hook_edit add "$f" "$(hook_self)" || return 1
  echo "OK hooks installed in $f (noisy commands via warmd run, state back after restart or compact, agents recorded and merged on stop). Remove: warmd init --no-hooks"
}

# Hooks written by an older warmd (PreToolUse only on Bash: Agent calls never cleared pause markers) get the current
# form at the next session start. Settings without warmd hooks (init --no-hooks) stay untouched.
hook_refresh() {
  local f self; f="$(hook_settings)"
  [ "${WARMD_PLUGIN:-0}" = 1 ] && return 0   # the plugin cache path changes with every update, settings never point there
  [ -f "$f" ] && grep -q ' hook-pre"' "$f" || return 0
  self="$(hook_self)"
  [ -n "$(type -t native_path)" ] || . "$WARMD_HOME/lib/platform.sh"
  # MSYS hands python C:/... for /c/...: either spelling is the current warmd
  grep -q '"matcher": *"Bash|Agent|Task"' "$f" && grep -qF -e "\"$self hook-pre\"" -e "\"$(native_path "$self") hook-pre\"" "$f" \
    && [ "$(grep -cE ' hook-(pre|session|subagent|compact)"' "$f")" = 4 ] && return 0
  hook_py >/dev/null && hook_edit add "$f" "$self" >/dev/null 2>&1 && echo "warmd: hooks in $f renewed to the current form."
  return 0
}

hook_remove() {
  local f; f="$(hook_settings)"
  [ -f "$f" ] || { echo "OK no hooks installed"; return 0; }
  hook_py >/dev/null || { echo "FAIL warmd init --no-hooks needs python3 or python to edit $f"; return 1; }
  hook_edit remove "$f" "" || return 1
  echo "OK warmd hooks removed from $f"
}
