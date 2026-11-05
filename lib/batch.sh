# warmd batch-resume: the batch marker (.git/warmd-batch) lost or dropped while tasks are still open? Built again from the
# task files and their worktrees, in the path form warmd split writes (pwd form), so nobody writes the marker by hand.
reg batch-resume "warmd batch-resume           rebuild the batch marker from the open tasks and their worktrees" batch_resume

# Open: the worktree exists, is neither the shared checkout nor the base, and has uncommitted work, commits not yet in the base,
# or a task file newer than its last commit (split, the agent has not committed yet).
batch_resume() {
  detect_project; need_git
  [ -n "$(type -t hook_index)" ] || . "$WARMD_HOME/lib/hook.sh"
  local common main batch base i wt wn tf br out="" names="" n=0 ct mt gp gn
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
    if [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ] && [ "$(git -C "$wt" rev-list --count "$base..HEAD" 2>/dev/null || echo 1)" = 0 ]; then
      ct="$(git -C "$wt" log -1 --format=%ct 2>/dev/null || echo 0)"; mt="$(date -r "$tf" +%s 2>/dev/null || echo 0)"
      [ "$mt" -gt "$ct" ] || continue   # merged or never started long ago: not open
    fi
    out="$out$wt"$'\n'; n=$((n+1)); names="$names ${br#warmd/}"
  done
  if [ $n = 0 ]; then rm -f "$batch"; echo "OK no open tasks, no batch marker"; return 0; fi
  printf '%s' "$out" > "$batch"
  echo "OK batch marker rebuilt: $n open:$names"
}
