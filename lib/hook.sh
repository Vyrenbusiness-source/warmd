# Agent hooks: warmd runs itself, nobody types a warmd command.
#   PreToolUse Bash  noisy known commands go through warmd run, short output, raw log kept
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
    init)         case " $* " in *" --no-hooks "*) hook_remove;; *) hook_install;; esac;;
  esac
}

hook_json_command() { # stdin hook JSON -> decoded command on stdout, return 1 when not decodable
  local raw
  raw="$(tr -d '\n\r' | sed -n 's/.*"tool_name" *: *"Bash".*"command" *: *"\(\([^"\\]\|\\.\)*\)".*/\1/p')"
  [ -n "$raw" ] || return 1
  raw="$(printf '%s' "$raw" | sed 's/\\\\/\x01/g; s/\\"/"/g; s/\x01/\\/g')"
  case "$raw" in *\\*) return 1;; esac   # \n, \t, \u: not touched
  printf '%s' "$raw"
}

hook_wrappable() { # command -> 0 when it is one simple known command
  local c="$1"
  case "$c" in *[\|\&\;\<\>\$\`\(\)\{\}\*\?\\\"\'~]*|*$'\n'*|warmd\ *|*/warmd\ *) return 1;; esac
  case "$c" in *--watch*|*" -w"|*" -w "*|*--serve*|*" dev"*|*" start"*) return 1;; esac
  printf '%s' "$c" | grep -qE "$HOOK_KNOWN"
}

hook_pre() {
  local in cmd self
  in="$(cat)"
  auto_pre "$in" && return 0   # context full: lib/auto.sh saved the work, the agent ends with its AGENT line
  cmd="$(printf '%s' "$in" | hook_json_command)" || return 0
  hook_wrappable "$cmd" || return 0
  self="$(hook_self)"
  # no permissionDecision on purpose: the user's own permission rules stay in charge of the rewritten command
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":{"command":"%s run -- %s"}}}\n' "$self" "$cmd"
}

hook_self() { # how the hook calls warmd: the name when it is on PATH, else the absolute path
  if command -v warmd >/dev/null 2>&1 && [ "$(command -v warmd)" = "$WARMD_HOME/bin/warmd" ]; then echo warmd; else echo "$WARMD_HOME/bin/warmd"; fi
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
  local i; REPLY=""
  for i in "${!HOOK_TW[@]}"; do [ "${HOOK_TW[$i]}" = "$1" ] && { REPLY="${HOOK_TF[$i]}"; return 0; }; done
  return 1
}
hook_agent_line() { # common dir, task file -> AGENT line to start or continue the task
  local tf="$2" name tier="" agent model note k v
  name="${tf##*/}"; name="${name%.md}"
  { read -r _; read -r tier; } < "$1/warmd-handoff/$name.task" 2>/dev/null
  [ -n "$tier" ] || read -r tier < "${tf%.md}.tier" 2>/dev/null
  tier="${tier%$'\r'}"
  case "$tier" in cheap) agent=warmd-scout; model=haiku;; top) agent=warmd-worker; model=opus;; *) tier=mid; agent=warmd-worker; model=sonnet;; esac
  if [ -f "$HOOK_PROJ/warmd.conf" ]; then
    while IFS='=' read -r k v || [ -n "$k" ]; do k="${k//[[:space:]]/}"; v="${v//[[:space:]\"]/}"; [ "$k" = "$tier" ] && [ -n "$v" ] && model="$v"; done < "$HOOK_PROJ/warmd.conf"
  fi
  note="$1/warmd-handoff/$name.md"
  if [ -f "$note" ]; then
    echo "AGENT $name: subagent_type=$agent model=$model prompt=\"Read $tf, then $(native_path "$note"), and continue from there. Do not redo finished work.\""
  else
    echo "AGENT $name: subagent_type=$agent model=$model prompt=\"Read $tf and do it.\""
  fi
}

# SessionStart (startup, resume, clear, compact): stdout becomes context. A task worktree gets its task and the brief back,
# the shared checkout gets the running batch: who is done, who is open, the AGENT line for each open one, the last merge result.
hook_session() {
  local in src="" common here tf brief main batch donef wt br ahead dirty open=0 n=0 log base l re='"source" *: *"([a-z]+)"'
  local -A state=()
  in="$(cat)"; [[ $in =~ $re ]] && src="${BASH_REMATCH[1]}"
  here="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  common="$(hook_common)" || return 0
  [ -n "$(type -t native_path)" ] || . "$WARMD_HOME/lib/platform.sh"
  main="$(hook_mainwt "$common")"
  hook_index "$common" "$main"
  hook_abs "$here"; here="$REPLY"; hook_abs "$main"; main="$REPLY"
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
    [ -f "$donef" ] && while IFS='	' read -r wt l; do [ -n "$wt" ] && state[$wt]="$l"; done < "$donef"
    base="$(git -C "$main" branch --show-current)"
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
        hook_abs "$wt" && hook_task_of "$REPLY" && echo "  $(hook_agent_line "$common" "$(native_path "$REPLY")")"
      fi
    done < "$batch"
    echo "$open of $n open. When the last one stops, warmd merges the finished branches by itself."
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
out = "escalated" if re.search(r"(?m)^\s*ESCALATE:", text) else "handoff" if re.search(r"(?m)^\s*AGENT \S+:", text) else "ok"
print("\t".join([task[0], task[1], tok, str(len(calls)), out, ctx]))
'

# SubagentStop: parse, then hand everything slow (ledger, push, merge) to a detached job and return at once.
hook_subagent() {
  local in py r name tf tokens calls outcome wt common
  in="$(cat)"
  py="$(hook_py)" || return 0
  r="$(printf '%s' "$in" | "$py" -c "$HOOK_PY_TRANSCRIPT" 2>/dev/null)" || return 0
  IFS='	' read -r name tf tokens calls outcome _ <<< "$r"
  [ -n "$name" ] || return 0
  if [ ! -f "$tf" ]; then   # path with spaces or relative in the prompt: the task index knows it
    common="$(hook_common)" && tf="$(sed -n 1p "$common/warmd-handoff/$name.task" 2>/dev/null)"
    [ -f "$tf" ] || return 0
  fi
  hook_task_wt "$tf" && wt="$REPLY" && [ -d "$wt" ] || return 0
  common="$(hook_common "$wt")" || return 0
  hook_detach "$common/warmd-hook.log" "$wt" hook-job "$name" "$wt" "$tokens" "$calls" "$outcome"
  return 0
}

# hook_detach <log> <dir> <warmd args...>: run warmd so it outlives the session that ran the hook.
# Windows: a nohup child stays in the session's process tree, job object and console, so claude -p ending can take it along.
# Win32_Process.Create starts it from the WMI service instead: no parent, no job, own hidden console. The environment does
# not come along, so a small script carries it. The launcher itself runs in the background: the hook returns at once.
hook_detach() {
  local log="$1" dir="$2" sh a v bash; shift 2
  if [ "${OS:-}" = win ] && [ -z "${WARMD_NO_CIM:-}" ] && bash="$(cygpath -w /usr/bin/bash.exe 2>/dev/null)" && [ -f "$bash" ]; then
    sh="${log%/*}/warmd-job-$$-$RANDOM.sh"
    {
      echo 'trap '"'"'rm -f "$0"'"'"' EXIT'
      for v in PATH HOME XDG_CACHE_HOME WARMD_HOME TMPDIR TEMP TMP CLAUDE_PROJECT_DIR; do [ -n "${!v+x}" ] && printf 'export %s=%q\n' "$v" "${!v}"; done
      printf 'export WARMD_DETACHED=1 WARMD_VIA=cim\ncd %q || exit 1\nbash %q' "$dir" "$WARMD_HOME/bin/warmd"
      for a in "$@"; do printf ' %q' "$a"; done
      printf ' >> %q 2>&1 < /dev/null\n' "$log"
    } > "$sh"
    # CIM refused (policy, no WMI): the old nohup path, better than nothing
    ( powershell.exe -NoProfile -NonInteractive -Command "\$s = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ShowWindow=[uint16]0}; \$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine='\"$bash\" \"$(native_path "$sh")\"'; CurrentDirectory='$(native_path "$dir")'; ProcessStartupInformation=\$s}; exit \$r.ReturnValue" > /dev/null 2>&1 < /dev/null \
        || { rm -f "$sh"; cd "$dir" && WARMD_DETACHED=1 WARMD_VIA=nohup exec nohup bash "$WARMD_HOME/bin/warmd" "$@" >> "$log" 2>&1 < /dev/null; } & )
    return 0
  fi
  ( cd "$dir" && WARMD_DETACHED=1 WARMD_VIA=nohup nohup bash "$WARMD_HOME/bin/warmd" "$@" >> "$log" 2>&1 < /dev/null & )
}

# hook-job <name> <worktree> <tokens> <calls> <outcome>: detached. Ledger and push through warmd finish, then the batch check.
hook_job() {
  local name="$1" wt="$2" tokens="${3:--}" calls="${4:--}" outcome="${5:-ok}" common here
  cd "$wt" || return 1
  here="$(pwd)"; common="$(hook_common)" || return 1
  export WARMD_DETACHED=1
  echo "$(date '+%F %T') $name stopped: $outcome, $tokens tokens, $calls calls (detached via ${WARMD_VIA:-direct})"
  outcome="$(auto_stop "$common" "$name" "$here" "$outcome")"   # failed or red: next tier queued for warmd watch
  if [ "$outcome" = handoff ]; then   # a fresh agent continues, the task is not done
    git remote get-url origin >/dev/null 2>&1 && git push -q -u origin HEAD 2>/dev/null
    return 0
  fi
  bash "$WARMD_HOME/bin/warmd" finish --tokens "$tokens" --calls "$calls" --outcome "$outcome"
  printf '%s\t%s\n' "$here" "$outcome" >> "$common/warmd-batch-done"
  hook_merge "$common"
}

# The last stopped agent of a batch merges: every ok branch one by one through warmd merge, red or conflict rolls back.
# Escalated tasks stay in the batch for the next tier, everything else leaves it. An empty batch ends.
hook_merge() { # common dir
  local common="$1" batch="$1/warmd-batch" done="$1/warmd-batch-done" lock="$1/warmd-automerge.lock" log="$1/warmd-automerge.log"
  local main wt br oc out rc pid keep="" first=1
  [ -s "$batch" ] || return 0
  while read -r wt; do [ -z "$wt" ] || grep -qF "$wt	" "$done" 2>/dev/null || return 0; done < "$batch"
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
  {
    echo "$(date '+%F %T') batch finished, merging into $(git -C "$main" branch --show-current) in $main"
    while read -r wt; do
      [ -n "$wt" ] || continue
      oc="$(grep -F "$wt	" "$done" | tail -1 | cut -f2)"; br="$(git -C "$wt" branch --show-current 2>/dev/null)"
      if [ "$oc" = escalated ]; then echo "WAIT $br escalated, stays in the batch"; keep="$keep$wt"$'\n'; continue; fi
      [ "$oc" = ok ] || { echo "SKIP $br: $oc"; continue; }
      [ "$(git -C "$main" rev-list --count "HEAD..$br" 2>/dev/null || echo 0)" = 0 ] && { echo "SKIP $br: nothing new"; continue; }
      out="$(cd "$main" && WARMD_BASE=1 bash "$WARMD_HOME/bin/warmd" merge "$br" 2>&1)"; rc=$?
      git -C "$main" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 && git -C "$main" merge --abort 2>/dev/null
      echo "$out" | grep -E '^(OK|FAIL)' | head -3
      if [ "$rc" != 0 ] && [ $first = 1 ] && echo "$out" | grep -qE 'only from a checkout|uncommitted changes'; then
        echo "STOP the shared checkout is not ready, batch stays open. Fix it, then run: warmd hook-merge"
        hook_unlock; return 0
      fi
      first=0
    done < "$batch"
    if [ -n "$keep" ]; then
      printf '%s' "$keep" > "$batch"; : > "$done"; echo "OK merged, batch waits for the escalated tasks"
    else
      rm -f "$batch" "$done"; echo "OK batch ended"
    fi
  } >> "$log" 2>&1
  hook_unlock; return 0
}

hook_settings() { echo "$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.claude/settings.local.json"; }

hook_py() { local p; for p in python3 python; do "$p" -c 'import json' >/dev/null 2>&1 && { echo "$p"; return 0; }; done; return 1; }

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
    hooks.setdefault("PreToolUse", []).append({"matcher": "Bash", "hooks": [{"type": "command", "command": self + " hook-pre"}]})
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
  hook_py >/dev/null || { echo "FAIL warmd hooks need python3 or python to edit $f"; return 1; }
  hook_edit add "$f" "$(hook_self)" || return 1
  echo "OK hooks installed in $f (noisy commands via warmd run, state back after restart or compact, agents recorded and merged on stop). Remove: warmd init --no-hooks"
}

hook_remove() {
  local f; f="$(hook_settings)"
  [ -f "$f" ] || { echo "OK no hooks installed"; return 0; }
  hook_py >/dev/null || { echo "FAIL warmd init --no-hooks needs python3 or python to edit $f"; return 1; }
  hook_edit remove "$f" "" || return 1
  echo "OK warmd hooks removed from $f"
}
