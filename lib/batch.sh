# warmd batch-resume: the batch marker (.git/warmd-batch) lost or dropped while tasks are still open? Built again from the
# task files and their worktrees, in the path form warmd split writes (pwd form), so nobody writes the marker by hand.
reg batch-resume "warmd batch-resume           rebuild the batch marker from the open tasks and their worktrees" batch_resume

# Open: the worktree exists, is neither the shared checkout nor the base, and has uncommitted work, commits not yet in the base,
# or a task file newer than its last commit (split, the agent has not committed yet).
# And it belongs to the latest batch (batch_recent): worktrees of earlier days keep unmerged commits too, they are no open task.
batch_resume() {
  detect_project; need_git
  [ -n "$(type -t hook_index)" ] || . "$WARMD_HOME/lib/hook.sh"
  local common main batch base i wt wn tf br out="" names="" n=0 ct mt gp gn
  BR_OWNERS=""; BR_TALK="-"
  gp="$(dirname "$GIT_ROOT")"; gn="$(native_path "$gp")"
  common="$(git -C "$PROJECT" rev-parse --path-format=absolute --git-common-dir)"; batch="$common/warmd-batch"
  main="$(hook_mainwt "$common")"; base="$(base_branch)"
  hook_index "$common" "$main"
  hook_abs "$main"; main="$REPLY"
  for i in "${!HOOK_TF[@]}"; do
    tf="${HOOK_TF[$i]}"; wt="${HOOK_TW[$i]}"
    [ -d "$wt" ] && [ "$wt" != "$main" ] || continue
    # split writes the folder next to its git root in that root's spelling (/tmp/x and /c/Users/../Temp/x are one folder)
    wt="$(cd "$wt" && pwd)"; wn="$(native_path "$wt")"
    case "$wn" in "$gn"/*) wt="$gp${wn#"$gn"}";; esac
    br="$(git -C "$wt" branch --show-current 2>/dev/null)"; [ -n "$br" ] && [ "$br" != "$base" ] || continue
    case "$out" in *"$wt"$'\n'*) continue;; esac
    # A reused worktree keeps the task files of every task it held: its branch names the task it holds now
    [ -f "${tf%/*}/${br#warmd/}.md" ] && tf="${tf%/*}/${br#warmd/}.md"
    batch_recent "$common" "${br#warmd/}" "$tf" || continue
    if [ -z "$(wt_work "$wt")" ] && [ "$(git -C "$wt" rev-list --count "$base..HEAD" 2>/dev/null || echo 1)" = 0 ]; then
      ct="$(git -C "$wt" log -1 --format=%ct 2>/dev/null || echo 0)"; mt="$(date -r "$tf" +%s 2>/dev/null || echo 0)"
      [ "$mt" -gt "$ct" ] || continue   # merged or never started long ago: not open
    fi
    out="$out$wt"$'\n'; n=$((n+1)); names="$names ${br#warmd/}"
  done
  if [ $n = 0 ]; then rm -f "$batch"; echo "OK no open tasks, no batch marker"; return 0; fi
  printf '%s' "$out" > "$batch"
  echo "OK batch marker rebuilt: $n open:$names"
}

# A task of the latest batch: named in its shared brief (warmd split starts it new with every batch), its task file not
# older than the batch start (warmd-batch-start), or its agent's transcript moved in the last 120 minutes.
# Without brief and start mark (a batch from before both): a task file of the last 24 hours.
batch_recent() { # common name taskfile
  local common="$1" name="$2" tf="$3" start="$1/warmd-batch-start" root="${WARMD_TRANSCRIPTS:-$HOME/.claude/projects}"
  [ -n "$BR_OWNERS" ] || BR_OWNERS=" $(sed -n '/^## Who owns what/,/^## Findings/s/^- \([^:]*\):.*$/\1/p' "$common/warmd-shared.md" 2>/dev/null | tr -d '\r' | tr '\n' ' ')"
  case "$BR_OWNERS" in *" $name "*) return 0;; esac
  [ -f "$start" ] && ! [ "$start" -nt "$tf" ] && return 0
  # One find and one grep for all tasks: the names every recent transcript mentions as tasks/<name>.md
  if [ "$BR_TALK" = - ]; then
    BR_TALK=" "
    [ -d "$root" ] && BR_TALK=" $(find "$root" -name '*.jsonl' -mmin -120 -exec grep -ohE 'tasks[/\\]+[A-Za-z0-9._-]+\.md' {} + 2>/dev/null | sed 's/.*[/\\]//; s/\.md$//' | sort -u | tr '\n' ' ')"
  fi
  case "$BR_TALK" in *" $name "*) return 0;; esac
  [ "$BR_OWNERS" = " " ] && [ ! -f "$start" ] && [ -n "$(find "$tf" -mmin -1440 2>/dev/null)" ] && return 0
  return 1
}
