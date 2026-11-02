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
    awk -v s="${sizes[$i]}" -v t="$total" -v n="${names[$i]}" 'BEGIN{printf "  ~%d tokens  %2d%%  %s\n", s, 100*s/t, n}'
  done
  awk -v s="$rest" -v t="$total" 'BEGIN{printf "  ~%d tokens  %2d%%  rest: system prompt, tool schemas, skill and MCP lists (not in files)\n", s, 100*s/t}'
  echo "tool schemas are the biggest fixed part. Measured by warmd on one machine, cost of one extra tool: Bash ~2800, Grep ~800, Read ~500, Edit ~300, Write ~200, Glob ~100. warmd init writes agents with the fewest tools that still work."
}
