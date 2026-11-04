# What a subagent pays before its first useful step, split by source. Used by `warmd audit`.

# First-call input tokens of one subagent transcript (input + cache write + cache read).
ctx_first_call() {
  local line n=0 k v
  line="$(grep -m1 '"usage":{' "$1" 2>/dev/null)" || return 1
  for k in input_tokens cache_creation_input_tokens cache_read_input_tokens; do
    v="$(printf '%s' "$line" | grep -o "\"$k\":[0-9]*" | head -1 | cut -d: -f2)"
    n=$((n + ${v:-0}))
  done
  echo "$n"
}

ctx_tokens() { [ -f "$1" ] && echo $(( $(wc -c < "$1" | tr -d ' ') / 4 )) || echo 0; }

context_audit() {
  local root="${GIT_ROOT:-$PROJECT}" slug dir f t total=0 n=0 sum=0 rest line
  local -a seen=()
  slug="$(printf '%s' "$(native_path "$root")" | sed 's/[^A-Za-z0-9]/-/g')"
  dir="$HOME/.claude/projects/$slug"
  for f in "$dir"/*/subagents/*.jsonl; do
    [ -f "$f" ] || continue
    t="$(ctx_first_call "$f")" || continue
    seen+=("$t")
  done
  echo "subagent startup (tokens before the first step):"
  if [ "${#seen[@]}" = 0 ]; then echo "  no subagent run found under $dir"; return 0; fi
  n=${#seen[@]}; sorted="$(printf '%s\n' "${seen[@]}" | sort -n)"
  total="$(echo "$sorted" | sed -n "$(( (n + 1) / 2 ))p")"
  echo "  $total tokens  first call, median of $n real runs"
  local -a names=() sizes=()
  add() { names+=("$1"); sizes+=("$2"); sum=$((sum + $2)); }
  for f in CLAUDE.md AGENTS.md; do [ -f "$root/$f" ] && add "$f (read by every agent)" "$(ctx_tokens "$root/$f")"; done
  [ -f "$dir/memory/MEMORY.md" ] && add "memory index MEMORY.md" "$(ctx_tokens "$dir/memory/MEMORY.md")"
  for f in "$root"/.claude/agents/*.md; do
    [ -f "$f" ] || continue
    [ "$(ctx_tokens "$f")" -gt 0 ] && add "agent list entry $(basename "$f" .md)" "$(( $(grep -m1 '^description:' "$f" | wc -c | tr -d ' ') / 4 ))"
  done
  rest=$((total - sum)); [ $rest -lt 0 ] && rest=0
  local i
  for i in "${!names[@]}"; do
    awk -v s="${sizes[$i]}" -v t="$total" -v n="${names[$i]}" 'BEGIN{printf "  ~%d tokens  %2d%%  %s\n", s, int(100*s/t+0.5), n}'
  done
  awk -v s="$rest" -v t="$total" 'BEGIN{printf "  ~%d tokens  %2d%%  rest: system prompt, tool schemas, skill and MCP lists (not in files)\n", s, int(100*s/t+0.5)}'
  echo "tool schemas are the biggest fixed part. Measured by warmd on one machine, cost of one extra tool: Bash ~2800, Grep ~800, Read ~500, Edit ~300, Write ~200, Glob ~100. warmd init writes agents with the fewest tools that still work."
}

# MCP servers whose tool lists load on every start. Setting names from code.claude.com/docs/en/mcp.md (tool search):
# ENABLE_TOOL_SEARCH unset or true defers every MCP tool, false loads all upfront, auto or auto:N loads them upfront below N% of the context.
# A server entry with "alwaysLoad": true loads upfront anyway; "alwaysLoad": false defers it (Claude Code v2.1.287 or later).
# Denying ToolSearch in permissions or setting CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS loads everything upfront.
read -r -d '' MCP_AWK <<'EOK' || true
function nrm(p) { gsub(/[\\]+/, "/", p); sub(/\/+$/, "", p); return tolower(p) }
function unq(v) { if (v ~ /^"/) { v = substr(v, 2, length(v) - 2); gsub(/\\"/, "\"", v) } return v }
function at(i) { return el[i] }
# one value at depth d: el[1..d] is its path
function val(v,   scope, n) {
  if (L == "settings") {
    if (d == 2 && el[1] == "env" && (el[2] == "ENABLE_TOOL_SEARCH" || el[2] == "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS")) print "V\t" F "\t" el[2] "\t" unq(v)
    if (d == 3 && el[1] == "permissions" && el[2] == "deny" && unq(v) ~ /^ToolSearch/) print "D\t" F
    if (d == 2 && el[1] == "disabledMcpjsonServers") print "X\t" unq(v)
    return
  }
  # server entries: mcpServers.<name> at the top, or projects.<this project>.mcpServers.<name> in ~/.claude.json
  if (d == 2 && el[1] == "mcpServers") { n = el[2]; scope = F }
  else if (d == 4 && el[1] == "projects" && nrm(el[2]) == ROOT && el[3] == "mcpServers") { n = el[4]; scope = F " (this project)" }
  else if (d == 3 && el[1] == "mcpServers" && el[3] == "alwaysLoad") { print "A\t" el[2] "\t" v; return }
  else if (d == 5 && el[1] == "projects" && nrm(el[2]) == ROOT && el[3] == "mcpServers" && el[5] == "alwaysLoad") { print "A\t" el[4] "\t" v; return }
  else return
  if (v == "{") print "S\t" n "\t" scope
}
# Records split at every quote: text outside strings and string bodies alternate, so a large ~/.claude.json stays linear.
BEGIN { RS = "\""; d = 0; wk[0] = 0; ins = 0 }
ins {
  buf = buf $0
  if (match($0, /\\+$/) && RLENGTH % 2) { buf = buf "\""; next }
  tok = "\"" buf "\""; buf = ""; ins = 0
  if (d > 0 && ty[d] == "o" && wk[d]) el[d] = unq(tok); else val(tok)
  next
}
{
  s = $0; n = length(s); i = 1
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == ":") { wk[d] = 0; i++; continue }
    if (c == ",") { if (ty[d] == "o") wk[d] = 1; else el[d] = ++ix[d]; i++; continue }
    if (c == "}" || c == "]") { d--; i++; continue }
    if (c == "{" || c == "[") { val("{"); d++; ty[d] = (c == "{" ? "o" : "a"); wk[d] = (c == "{"); ix[d] = 0; el[d] = 0; i++; continue }
    if (c ~ /[ \t\r\n]/) { i++; continue }
    j = i; while (j <= n && substr(s, j, 1) !~ /[ \t\r\n,:}\]]/) j++
    val(substr(s, i, j - i)); i = j
  }
  ins = 1
}
EOK

mcp_audit() {
  local root="${GIT_ROOT:-$PROJECT}" f tmp out ts="" tsf="" up=0 n=0 name scope al line
  tmp="$(mktemp -d)"
  for f in "$root/.claude/settings.local.json" "$root/.claude/settings.json" "$HOME/.claude/settings.json"; do
    [ -f "$f" ] && awk -v L=settings -v F="${f#"$root/"}" "$MCP_AWK" "$f" >> "$tmp/set"
  done
  for f in "$HOME/.claude.json" "$root/.mcp.json"; do
    [ -f "$f" ] && awk -v L=servers -v F="$( [ "$f" = "$root/.mcp.json" ] && echo .mcp.json || echo '~/.claude.json')" -v ROOT="$(native_path "$root" | sed 's#\\#/#g; s#/*$##' | tr 'A-Z' 'a-z')" "$MCP_AWK" "$f" >> "$tmp/srv"
  done
  touch "$tmp/set" "$tmp/srv"
  echo "MCP servers (a tool list loaded upfront is paid on every turn):"
  if ! grep -q '^S' "$tmp/srv"; then echo "  none configured"; rm -rf "$tmp"; return 0; fi
  # first match wins: the shell, then settings.local.json, settings.json, ~/.claude/settings.json
  if [ -n "${ENABLE_TOOL_SEARCH+x}" ]; then ts="$ENABLE_TOOL_SEARCH"; tsf="your shell"
  else line="$(awk -F'\t' '$1 == "V" && $3 == "ENABLE_TOOL_SEARCH" { print $2 "\t" $4; exit }' "$tmp/set")"; [ -n "$line" ] && { tsf="${line%%	*}"; ts="${line#*	}"; }; fi
  case "$ts" in
    false) echo "  ENABLE_TOOL_SEARCH=false ($tsf): every MCP tool loads upfront. Fix: remove it, or set \"ENABLE_TOOL_SEARCH\": \"true\" in the env block of .claude/settings.json"; up=1;;
    auto*) echo "  ENABLE_TOOL_SEARCH=$ts ($tsf): MCP tools load upfront while they stay under the threshold. Fix: set \"ENABLE_TOOL_SEARCH\": \"true\" in the env block of .claude/settings.json"; up=1;;
  esac
  if [ -n "${CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS:-}" ] || grep -q '^V	[^	]*	CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS	.' "$tmp/set"; then
    echo "  CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS is set: tool search stays off, every MCP tool loads upfront. Fix: unset it"; up=1; fi
  if grep -q '^D' "$tmp/set"; then
    echo "  permissions deny ToolSearch ($(grep '^D' "$tmp/set" | cut -f2 | head -1)): every MCP tool loads upfront. Fix: remove \"ToolSearch\" from permissions.deny"; up=1; fi
  while IFS="$(printf '\t')" read -r _ name scope; do
    [ "$scope" = .mcp.json ] && grep -qxF "X	$name" "$tmp/set" && continue
    n=$((n + 1))
    al="$(awk -F'\t' -v n="$name" '$1 == "A" && $2 == n { v = $3 } END { print v }' "$tmp/srv")"
    if [ "$al" = true ]; then echo "  upfront   $name  ($scope, \"alwaysLoad\": true). Fix: set \"alwaysLoad\": false in that entry (Claude Code v2.1.287+)"
    elif [ $up = 1 ]; then echo "  upfront   $name  ($scope)"
    else echo "  deferred  $name  ($scope)"; fi
  done < <(grep '^S' "$tmp/srv")
  echo "  $n servers. A deferred server costs its tool names only (measured: one server with 25 tools, +244 start tokens); an upfront one costs its full tool schemas on every turn."
  rm -rf "$tmp"
}
