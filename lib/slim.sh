# What fills a subagent's startup, measured per source with real `claude -p` runs, and `warmd init --slim`.
# Needs lib/context.sh for ctx_first_call. Every live run uses a throwaway project; nothing outside it is touched.

# Tool sets tried for one agent, cheapest first. Measured by `slim_matrix`.
SLIM_TOOLS_DEFAULT="Read, Grep, Glob, Edit, Write"

# slim_fixture <dir> <source...>   sources: claude_md skills agents mcp
slim_fixture() {
  local d="$1" s i; shift
  mkdir -p "$d/.claude/agents"
  git -C "$d" init -q . 2>/dev/null
  printf -- '---\nname: probe\ndescription: Probe agent, answers ok.\nmodel: haiku\n---\nReply with the single word ok.\n' > "$d/.claude/agents/probe.md"
  for s in "$@"; do
    case "$s" in
      claude_md) for i in $(seq 1 40); do printf '## Rule %s\nKeep module %s small, test it with the shared runner, never edit generated output by hand, and record the decision before the next change to module %s.\n\n' "$i" "$i" "$i"; done > "$d/CLAUDE.md";;
      skills) for i in $(seq 1 30); do mkdir -p "$d/.claude/skills/skill$i"; printf -- '---\nname: skill%s\ndescription: Use when working on area %s of the project: covers build steps, review checklists, naming rules and release notes for area %s so the work stays consistent.\n---\nBody %s\n' "$i" "$i" "$i" "$i" > "$d/.claude/skills/skill$i/SKILL.md"; done;;
      agents) for i in $(seq 1 15); do printf -- '---\nname: helper%s\ndescription: Helper %s handles one narrow job in area %s, such as reviewing changes, searching code, writing tests or preparing release notes.\n---\nDo job %s.\n' "$i" "$i" "$i" "$i" > "$d/.claude/agents/helper$i.md"; done;;
      mcp) slim_mcp_stub "$d";;
    esac
  done
}

# A stdio MCP server with 25 small tools, python only.
slim_mcp_stub() {
  cat > "$1/mcp_stub.py" <<'EOF'
import sys, json
tools = [{"name": "tool_%d" % i, "description": "Stub tool %d that reads or changes item %d and returns a short report." % (i, i), "inputSchema": {"type": "object", "properties": {"id": {"type": "string", "description": "item id"}, "mode": {"type": "string", "description": "read or write"}}, "required": ["id"]}} for i in range(1, 26)]
for line in sys.stdin:
    try: m = json.loads(line)
    except Exception: continue
    if "id" not in m: continue
    me = m.get("method")
    if me == "initialize": r = {"protocolVersion": m["params"]["protocolVersion"], "capabilities": {"tools": {}}, "serverInfo": {"name": "stub", "version": "1"}}
    elif me == "tools/list": r = {"tools": tools}
    elif me == "tools/call": r = {"content": [{"type": "text", "text": "ok"}]}
    else: r = {}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": r}) + "\n"); sys.stdout.flush()
EOF
  printf '{"mcpServers":{"stub":{"command":"python","args":["%s/mcp_stub.py"]}}}\n' "$(cd "$1" && { pwd -W 2>/dev/null || pwd; })" > "$1/.mcp.json"
}

# slim_probe <dir> <agent> [claude args...]  prints the first-call tokens of the agent's transcript, or NA
slim_probe() {
  local d="$1" agent="$2" out sid slug f; shift 2
  . "${WARMD_HOME:?}/lib/context.sh"
  out="$(cd "$d" && timeout 240 claude -p "Use the $agent agent once via the Agent tool, then say done." --output-format json --permission-mode bypassPermissions --model haiku "$@" </dev/null 2>&1)"
  sid="$(printf '%s' "$out" | grep -o '"session_id":"[^"]*"' | head -1 | cut -d'"' -f4)"
  slug="$(printf '%s' "$(native_path "$d")" | sed 's/[^A-Za-z0-9]/-/g')"
  f="$(ls "$HOME/.claude/projects/$slug/$sid/subagents/"*.jsonl 2>/dev/null | head -1)"
  [ -n "$sid" ] && [ -n "$f" ] && ctx_first_call "$f" || echo NA
}

# slim_agent <dir> <name> <tools-or-empty>   one-off probe agent with a given tools line
slim_agent() {
  { printf -- '---\nname: %s\ndescription: Probe %s.\nmodel: haiku\n' "$2" "$2"; [ -n "$3" ] && printf 'tools: %s\n' "$3"; printf -- '---\nReply ok.\n'; } > "$1/.claude/agents/$2.md"
}

# slim_matrix  live table: every source on and off. Prints "name before after delta".
# SLIM_USER=1 also counts the user's own plugins and hooks (read only, as claude loads them).
slim_matrix() {
  local tmp ss="--setting-sources project,local" base row
  tmp="$(mktemp -d)"
  row() { printf '%-34s %7s %7s %+7d\n' "$1" "$2" "$3" "$(( $3 - $2 ))"; }
  slim_fixture "$tmp/base"
  base="$(slim_probe "$tmp/base" probe $ss)"
  echo "source                             before   after   delta  (tokens before the first step)"
  local s v
  for s in claude_md skills agents mcp; do
    slim_fixture "$tmp/$s" "$s"
    if [ "$s" = mcp ]; then v="$(slim_probe "$tmp/$s" probe $ss --mcp-config "$(cat "$tmp/$s/.mcp.json")")"; else v="$(slim_probe "$tmp/$s" probe $ss)"; fi
    row "$s" "$base" "$v"
  done
  v="$(slim_probe "$tmp/base" probe)"; row "user plugins and hooks" "$base" "$v"
  local set
  for set in "Read" "Read, Grep, Glob" "$SLIM_TOOLS_DEFAULT" "Bash, Read, Edit, Write"; do
    slim_agent "$tmp/base" tl "$set"; v="$(slim_probe "$tmp/base" tl $ss)"; row "tools: $set" "$base" "$v"
  done
  rm -rf "$tmp"
}

# warmd init --slim: give every project agent without a tools line the cheapest useful set.
# Agents that already name tools stay as they are. The main session and settings stay untouched.
slim_init() {
  local root="${GIT_ROOT:-$PROJECT}" f n=0 s=0 line tools="${WARMD_SLIM_TOOLS:-$SLIM_TOOLS_DEFAULT}" tmp
  for f in "$root"/.claude/agents/*.md; do
    [ -f "$f" ] || continue
    if awk 'NR==1&&$0!~/^---/{exit 1} NR>1&&/^---/{exit} /^tools:/{found=1} END{exit !found}' "$f"; then s=$((s + 1)); continue; fi
    [ "$(head -1 "$f" | tr -d '')" = "---" ] || continue
    tmp="$f.slim.$$"
    awk -v t="$tools" 'NR==1{print; inh=1; next} inh&&/^---/{print "tools: " t; inh=0} {print}' "$f" > "$tmp" && mv "$tmp" "$f"
    n=$((n + 1))
  done
  echo "OK slim: $n agent(s) now list tools ($tools), $s already did"
  echo "   add Bash to an agent that needs it: the tool schema costs about 2800 tokens per start"
}
