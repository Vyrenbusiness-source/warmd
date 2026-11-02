# Context handoff: a long-running agent pays for its whole history on every turn. Past 70% of the budget a fresh agent with a short note is cheaper.
# The note lives in the common git dir, so the worktree that writes it and the session that reads it see the same file.
handoff_dir() { echo "$(git -C "$PROJECT" rev-parse --path-format=absolute --git-common-dir)/warmd-handoff"; }

# Called from write_task: remembers where the task lives, a worktree has no copy of it
handoff_register() { # name taskfile tier
  mkdir -p "$(handoff_dir)"
  { echo "$2"; echo "$3"; } > "$(handoff_dir)/$1.task"
}

# warmd handoff <name> "<what is done>" "<what is next>"
team_handoff() {
  need_git
  local name="${1:-}" done_text="${2:-}" next_text="${3:-}" dir task tier note round model
  [ -n "$name" ] && [ -n "$done_text" ] && [ -n "$next_text" ] || { echo "warmd handoff <name> \"what is done\" \"what is next\""; return 2; }
  dir="$(handoff_dir)"
  [ -f "$dir/$name.task" ] || { echo "FAIL unknown task $name"; return 2; }
  [ -n "$(git -C "$GIT_ROOT" status --porcelain -uno | grep -vE '\.sln[x]?$')" ] && { echo "FAIL commit your work first, a handoff must not lose anything"; return 1; }
  task="$(sed -n 1p "$dir/$name.task")"; tier="$(sed -n 2p "$dir/$name.task")"
  note="$dir/$name.md"
  round=$(( $(grep -c '^## Handoff' "$note" 2>/dev/null || true) + 1 ))
  [ "$round" -le 3 ] || { echo "FAIL $name was handed off 3 times, split it or ask a human"; return 1; }
  git -C "$GIT_ROOT" push -q -u origin HEAD 2>/dev/null
  {
    echo "## Handoff $round, $(git -C "$GIT_ROOT" branch --show-current) at $(git -C "$GIT_ROOT" rev-parse --short HEAD)"
    echo "Done: $done_text"
    echo "Next: $next_text"
    echo "Commits since the base:"
    git -C "$GIT_ROOT" log --oneline "$(base_branch)..HEAD" 2>/dev/null | head -8 | cut -c1-72
  } >> "$note"
  model="$(tier_model "$tier")"
  echo "AGENT $name: subagent_type=$(tier_agent "$tier") model=$model prompt=\"Read $task, then $(native_path "$note"), and continue from there. Do not redo finished work.\""
}
