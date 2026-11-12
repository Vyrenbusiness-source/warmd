# warmd drop: one task of a running batch is not wanted any more. It leaves the batch (watch, status, the batch guard and the
# automatic merge no longer see it), its files are free again, and it is recorded as dropped, not failed.
reg drop "warmd drop <task> [reason] [--delete] [--force]  cancel one task of the batch; --delete also removes its worktree and branch" drop_main

drop_main() {
  detect_project; need_git
  local name="" reason="" del=0 force=0 a n=0
  for a in "$@"; do
    case "$a" in
      --delete) del=1;;
      --force) force=1;;
      *) n=$((n+1)); if [ $n = 1 ]; then name="$a"; else reason="${reason:+$reason }$a"; fi;;
    esac
  done
  [ -n "$name" ] || { echo "warmd drop <task> [reason] [--delete] [--force]"; return 2; }
  local common batch base br wt="" p keep="" found=0 tf
  common="$(git -C "$PROJECT" rev-parse --path-format=absolute --git-common-dir)"; batch="$common/warmd-batch"
  base="$(base_branch)"; br="warmd/$name"
  # The task's worktree: the batch line whose task it is, else the cd line of its task file
  if [ -f "$batch" ]; then
    while IFS= read -r p || [ -n "$p" ]; do
      p="${p%$'\r'}"; [ -n "$p" ] || continue
      if [ -d "$p" ] && [ "$(wt_task "$p")" = "$name" ]; then wt="$p"; found=1; fi
    done < "$batch"
  fi
  tf="$STATE/tasks/$name.md"
  if [ -z "$wt" ] && [ -f "$tf" ]; then wt="$(sed -n '1s/.*cd "\([^"]*\)".*/\1/p' "$tf")"; [ -d "$wt" ] || wt=""; fi
  if [ $found = 0 ] && [ -z "$wt" ] && ! git -C "$GIT_ROOT" rev-parse -q --verify "refs/heads/$br" >/dev/null 2>&1; then
    echo "FAIL no task $name in this batch (no worktree, no task file, no branch $br)"; return 1
  fi
  # --delete checks first: nothing is changed when it refuses
  if [ $del = 1 ] && [ $force = 0 ]; then
    local ahead=0 dirty=0
    git -C "$GIT_ROOT" rev-parse -q --verify "refs/heads/$br" >/dev/null 2>&1 && ahead="$(git -C "$GIT_ROOT" rev-list --count "$base..$br" 2>/dev/null || echo 1)"
    # commits ahead whose content is not in the base: merged by squash or rebase shows no diff
    if [ "$ahead" != 0 ] && [ -z "$(git -C "$GIT_ROOT" diff "$base...$br" 2>/dev/null | head -c 1)" ]; then ahead=0; fi
    [ -n "$wt" ] && dirty="$(wt_work "$wt" | wc -l | tr -d ' ')"
    if [ "$ahead" != 0 ]; then
      echo "FAIL $name has $ahead commit(s) not in $base. Nothing was dropped. Review: git log $base..$br. Drop and keep the branch: warmd drop $name; throw the work away: warmd drop $name --delete --force"; return 1
    fi
    if [ "$dirty" != 0 ]; then
      echo "FAIL $name has $dirty uncommitted file(s) in $(native_path "$wt"). Nothing was dropped. Commit them, or throw them away: warmd drop $name --delete --force"; return 1
    fi
  fi
  # Out of the batch: watch, status, the batch guard and the automatic merge read this file
  if [ -f "$batch" ] && [ -n "$wt" ]; then
    wt_norm_r "$wt"; local w="$REPLY"
    while IFS= read -r p || [ -n "$p" ]; do
      p="${p%$'\r'}"; [ -n "$p" ] || continue
      wt_norm_r "$p"; [ "$REPLY" = "$w" ] || keep="$keep$p"$'\n'
    done < "$batch"
    cp -p "$batch" "$batch.drop" && printf '%s' "$keep" > "$batch" && touch -r "$batch.drop" "$batch"; rm -f "$batch.drop"
    batch_done_forget "$common" "$wt"
  fi
  # No pause marker, no queued ESCALATE/AGENT line, no dead mark, no owner in the shared brief
  rm -f "$(auto_dir "$common")/paused/$name"
  local q="$(auto_dir "$common")/queue" ql qk=""
  if [ -s "$q" ]; then
    while IFS= read -r ql || [ -n "$ql" ]; do case "$ql" in "ESCALATE $name:"*|"AGENT $name:"*) ;; *) qk="$qk$ql"$'\n';; esac; done < "$q"
    printf '%s' "$qk" > "$q"
  fi
  [ -f "$batch-dead" ] && { grep -vxF "$name" "$batch-dead" > "$batch-dead.t"; mv -f "$batch-dead.t" "$batch-dead"; }
  local sf="$common/warmd-shared.md"
  [ -f "$sf" ] && { grep -v "^- $name: " "$sf" > "$sf.t"; mv -f "$sf.t" "$sf"; }
  # The record: dropped is a state of its own, the ledger never counts it as a failed task
  { [ -f "$common/warmd-batch-dropped" ] && grep -v "^$name	" "$common/warmd-batch-dropped"; printf '%s\t%s\t%s\n' "$name" "$(date '+%F %T')" "${reason:-no reason given}"; } > "$common/warmd-batch-dropped.t"
  mv -f "$common/warmd-batch-dropped.t" "$common/warmd-batch-dropped"
  printf 'dropped\t%s\n' "$(area_of "$(sed -n 's/^Files you own: //p' "$tf" 2>/dev/null)")" >> "$STATE/history.tsv" 2>/dev/null
  local what="branch $br kept"
  if [ $del = 1 ]; then
    if [ -n "$wt" ] && [ "$wt" != "$GIT_ROOT" ]; then git -C "$GIT_ROOT" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"; git -C "$GIT_ROOT" worktree prune 2>/dev/null; fi
    git -C "$GIT_ROOT" branch -D "$br" >/dev/null 2>&1
    git -C "$GIT_ROOT" push -q origin --delete "$br" >/dev/null 2>&1
    rm -f "$tf" "$STATE/tasks/$name.tier"
    what="worktree and branch $br removed"
  fi
  # An emptied batch ends; the others all finished: the automatic merge may go now
  local rest=""; [ -f "$batch" ] && rest="$(tr -d '\r\n' < "$batch")"
  if [ -f "$batch" ] && [ -z "$rest" ]; then rm -f "$batch"; what="$what, batch ended"
  elif [ -n "$rest" ]; then ( nohup bash "$WARMD_HOME/bin/warmd" hook-merge >/dev/null 2>&1 & ) 2>/dev/null; fi
  echo "OK $name dropped${reason:+ ($reason)}: $what, watch and automerge ignore it"
}
