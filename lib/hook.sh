# Agent hooks: route noisy shell commands through warmd without the agent asking, and bring the task back after a context compaction.
# Off by default. warmd init --hooks installs, warmd init --no-hooks removes. Only commands on the known list are touched.
# Written to .claude/settings.local.json (personal, not committed). Entries are recognised by their command ending in "hook-pre" or "hook-session".
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

# SessionStart with matcher compact: stdout becomes context again after the compaction
hook_session() {
  local top common main here f brief
  cat > /dev/null
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  main="$(dirname "$common")"
  here="$(native_path "$top")"
  for f in "$main"/.warmd/tasks/*.md "$main"/*/.warmd/tasks/*.md; do
    [ -f "$f" ] || continue
    grep -qF "cd \"$here\"" "$f" || continue
    echo "warmd: context was compacted. Your task and the shared brief again, continue the task."
    cat "$f"
    brief="$common/warmd-shared.md"
    if [ -f "$brief" ]; then echo; cat "$brief"; fi
    return 0
  done
  return 0
}

hook_settings() { echo "$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.claude/settings.local.json"; }

hook_py() { local p; for p in python3 python; do "$p" -c 'import json' >/dev/null 2>&1 && { echo "$p"; return 0; }; done; return 1; }

# mode add|remove, settings file, hook command prefix
hook_edit() {
  "$(hook_py)" -c '
import json, os, re, sys
mode, path, self = sys.argv[1:4]
ours = re.compile(r"warmd.* hook-(pre|session)$")
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
    hooks.setdefault("SessionStart", []).append({"matcher": "compact", "hooks": [{"type": "command", "command": self + " hook-session"}]})
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
  hook_py >/dev/null || { echo "FAIL warmd init --hooks needs python3 or python to edit $f"; return 1; }
  hook_edit add "$f" "$(hook_self)" || return 1
  echo "OK hooks installed in $f (noisy Bash commands via warmd run, task restored after compact). Remove: warmd init --no-hooks"
}

hook_remove() {
  local f; f="$(hook_settings)"
  [ -f "$f" ] || { echo "OK no hooks installed"; return 0; }
  hook_py >/dev/null || { echo "FAIL warmd init --no-hooks needs python3 or python to edit $f"; return 1; }
  hook_edit remove "$f" "" || return 1
  echo "OK warmd hooks removed from $f"
}
