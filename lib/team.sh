# Agent work: model routing by tier, cheap first, worktrees for parallel tasks, one-line prompts, safe merge.
# Tiers map to model aliases. Claude Code resolves haiku, sonnet and opus to the newest release, so a new model needs no change here.

route_tier() { # goal files
  local goal="$1" files="${2:-}"
  if [ -z "$files" ] || [ "$files" = none ]; then echo cheap; return; fi
  local tier=mid
  if echo "$goal" | grep -qiE "$CFG_top_words"; then tier=top; fi
  if [ -n "$CFG_top_paths" ] && echo "$files" | grep -qE "$CFG_top_paths"; then tier=top; fi
  # Learned: an area that needed escalation twice starts one tier higher
  if [ "$tier" = mid ] && [ -f "$STATE/history.tsv" ]; then
    local area n; area="$(area_of "$files")"
    n="$(grep -c "^escalated	$area$" "$STATE/history.tsv" 2>/dev/null)"
    [ "${n:-0}" -ge 2 ] && tier=top
  fi
  echo "$tier"
}
area_of() { echo "$1" | cut -d, -f1 | sed 's#/[^/]*$##'; }
tier_model() { case "$1" in cheap) echo "$CFG_cheap";; top) echo "$CFG_top";; *) echo "$CFG_mid";; esac; }
tier_budget() { case "$1" in cheap) echo "$CFG_budget_cheap";; top) echo "$CFG_budget_top";; *) echo "$CFG_budget_mid";; esac; }
tier_next() { case "$1" in cheap) echo mid;; mid) echo top;; *) echo "";; esac; }
tier_agent() { case "$1" in cheap) echo warmd-scout;; *) echo warmd-worker;; esac; }

route_print() {
  local t; t="$(route_tier "${1:-}" "${2:-}")"
  echo "$t model=$(tier_model "$t") budget=$(tier_budget "$t")k agent=$(tier_agent "$t")"
}

need_git() { [ -n "$GIT_ROOT" ] || { echo "FAIL needs a git repo"; exit 2; }; }
worktree_dir() { echo "$(dirname "$GIT_ROOT")/.warmd-worktrees/$(basename "$GIT_ROOT")"; }
rel_project() { local r="${PROJECT#"$GIT_ROOT"}"; echo "${r#/}"; }

# A new worktree is useless until its slow caches exist: the adapter copies or links them (Library, .godot, node_modules).
wt_create() { # name
  local name="$1" wt branch src rel
  wt="$(worktree_dir)/$name"; branch="warmd/$name"
  if [ -d "$wt" ]; then echo "$wt"; return 0; fi
  mkdir -p "$(worktree_dir)"
  git -C "$GIT_ROOT" worktree add -q -b "$branch" "$wt" HEAD 2>/dev/null || git -C "$GIT_ROOT" worktree add -q "$wt" "$branch" || return 1
  rel="$(rel_project)"; src="$PROJECT"
  a_seed "$src" "$wt${rel:+/$rel}" >/dev/null 2>&1
  echo "$wt"
}

# Shared brief: one short file all agents of a batch read. It lives in the common git dir, so every worktree sees the same copy and it never gets committed.
# It stops parallel agents from searching for the same thing twice and shows who owns which file.
shared_file() { echo "$(git -C "$PROJECT" rev-parse --path-format=absolute --git-common-dir)/warmd-shared.md"; }
shared_start() { # tasks file
  local name goal check files f; f="$(shared_file)"
  {
    echo "# Shared brief"
    echo "Read once at the start. Before searching, check Findings. Add what others need: warmd note \"one line\"."
    echo
    echo "## Who owns what"
    while IFS='|' read -r name goal check files; do
      name="$(echo "$name" | xargs)"; files="$(echo "$files" | tr -d ' ')"
      case "$name" in \#*|"") continue;; esac
      echo "- $name: ${files:-none}"
    done < <(tr -d '\r' < "$1")
    echo
    echo "## Findings"
  } > "$f"
}
# Only the newest 40 findings stay, so the brief never grows into the next HANDOFF
team_note() {
  need_git
  local text="${1:-}" f who keep; f="$(shared_file)"
  [ -f "$f" ] || { echo "FAIL no shared brief, warmd split creates it"; return 2; }
  [ -n "$text" ] || { echo "warmd note \"one line\""; return 2; }
  [ ${#text} -le 160 ] || { echo "FAIL over 160 characters, keep it to one fact"; return 2; }
  grep -qF -- "$text" "$f" && { echo "OK already noted"; return 0; }
  who="$(git -C "$GIT_ROOT" branch --show-current)"
  echo "- ${who#warmd/}: $text" >> "$f"
  keep="$(awk '/^## Findings/{print NR}' "$f")"
  if [ "$(( $(wc -l < "$f") - keep ))" -gt 40 ]; then { head -n "$keep" "$f"; tail -n 40 "$f"; } > "$f.tmp"; mv "$f.tmp" "$f"; fi
  echo "OK noted"
}

write_task() { # name tier goal done files wt
  local name="$1" tier="$2" goal="$3" check="$4" files="$5" wt="$6" f port
  mkdir -p "$STATE/tasks"; f="$STATE/tasks/$name.md"
  port=$(( 7830 + $(ls "$STATE/tasks" | wc -l) * 10 ))
  {
    echo "Task $name. Worktree: $(native_path "$wt"). Port block: $port."
    echo "Goal: $goal"
    echo "Done when: $check"
    echo "Files you own: ${files:-none, read only}"
    echo "Budget: under $(tier_budget "$tier")k tokens."
    echo "Shared brief: $(native_path "$(shared_file)")"
  } > "$f"
  echo "AGENT $name: subagent_type=$(tier_agent "$tier") model=$(tier_model "$tier") prompt=\"Read $(native_path "$f") and do it.\""
}

# Tasks file, one per line: name | goal | done check | files (comma separated, or none)
team_split() {
  need_git
  local file="${1:-}" name goal check files tier wt seen="" f n=0 bad=0
  [ -f "$file" ] || { echo "warmd split <file>, lines: name | goal | done check | files"; return 2; }
  while IFS='|' read -r name goal check files <&3; do
    name="$(echo "$name" | xargs)"; goal="$(echo "$goal" | xargs)"; check="$(echo "$check" | xargs)"; files="$(echo "$files" | tr -d ' ')"
    case "$name" in \#*|"") continue;; esac
    if [ -n "$files" ] && [ "$files" != none ]; then
      for f in ${files//,/ }; do
        case " $seen " in *" $f "*) echo "GAP $name: $f already owned in this batch, two agents would collide"; bad=1;; esac
        seen="$seen $f"
      done
    fi
    [ -n "$check" ] || { echo "GAP $name: no done check"; bad=1; }
    n=$((n+1))
  done 3< <(tr -d '\r' < "$file")
  [ $bad = 0 ] || { echo "FAIL fix the gaps, nothing was created"; return 1; }
  shared_start "$file"
  while IFS='|' read -r name goal check files <&3; do
    name="$(echo "$name" | xargs)"; goal="$(echo "$goal" | xargs)"; check="$(echo "$check" | xargs)"; files="$(echo "$files" | tr -d ' ')"
    case "$name" in \#*|"") continue;; esac
    tier="$(route_tier "$goal" "$files")"
    if [ "$tier" = cheap ]; then wt="$GIT_ROOT"; else wt="$(wt_create "$name")" || { echo "FAIL worktree $name"; return 1; }; fi
    write_task "$name" "$tier" "$goal" "$check" "$files" "$wt"
    printf '%s\n' "$tier" > "$STATE/tasks/$name.tier"
  done 3< <(tr -d '\r' < "$file")
  echo "OK $n tasks split"
}

team_escalate() {
  need_git
  local name="${1:-}" f="$STATE/tasks/${1:-}.md" tier next area
  [ -f "$f" ] || { echo "warmd escalate <name>: unknown task"; return 2; }
  tier="$(cat "$STATE/tasks/$name.tier" 2>/dev/null || echo mid)"; next="$(tier_next "$tier")"
  [ -n "$next" ] || { echo "FAIL $name is at the top tier, this one needs a human"; return 1; }
  area="$(area_of "$(sed -n 's/^Files you own: //p' "$f")")"
  printf 'escalated\t%s\n' "$area" >> "$STATE/history.tsv"
  grep -q '^Earlier attempt' "$f" || echo "Earlier attempt failed. Read its commits on this branch first, then take a different approach." >> "$f"
  echo "$next" > "$STATE/tasks/$name.tier"
  sed -i.bak "s/^Budget: .*/Budget: under $(tier_budget "$next")k tokens./" "$f"; rm -f "$f.bak"
  echo "AGENT $name: subagent_type=warmd-worker model=$(tier_model "$next") prompt=\"Read $(native_path "$f") and do it.\""
}

# The last line of every agent: facts from git and the last run, not prose.
team_finish() {
  need_git
  local br sha ahead dirty up last
  br="$(git -C "$GIT_ROOT" branch --show-current)"; sha="$(git -C "$GIT_ROOT" rev-parse --short HEAD)"
  ahead="$(git -C "$GIT_ROOT" rev-list --count "$(base_branch)..HEAD" 2>/dev/null || echo '?')"
  dirty="$(git -C "$GIT_ROOT" status --porcelain -uno | wc -l | tr -d ' ')"
  if git -C "$GIT_ROOT" remote get-url origin >/dev/null 2>&1; then git -C "$GIT_ROOT" push -q -u origin "$br" 2>/dev/null && up=pushed || up=NOT_pushed; else up=local; fi
  last="$(sed -n '2p' "$RUN/result.txt" 2>/dev/null | tr -d '\r' | cut -c1-70)"
  echo "DONE $br $sha, $ahead ahead, $dirty uncommitted, $up${last:+, last run: $last}"
}

team_board() {
  need_git
  local base path br age dirty ahead
  base="$(base_branch)"
  printf '%-26s %-22s %6s %6s %6s\n' worktree branch age dirty ahead
  git -C "$GIT_ROOT" worktree list --porcelain | awk '/^worktree /{p=substr($0,10)} /^branch /{b=$2; sub("refs/heads/","",b); print p"|"b}' | while IFS='|' read -r path br; do
    age=$(( ($(date +%s) - $(git -C "$path" log -1 --format=%ct)) / 60 ))
    dirty="$(git -C "$path" status --porcelain -uno | wc -l | tr -d ' ')"
    ahead="$(git -C "$path" rev-list --count "$base..HEAD" 2>/dev/null || echo '?')"
    printf '%-26s %-22s %5sm %6s %6s\n' "$(basename "$path" | cut -c1-26)" "$(echo "$br" | cut -c1-22)" "$age" "$dirty" "$ahead"
  done
}

# merge <branch>: only into the base branch, only from a clean tree, then the fastest checks. Red rolls back.
team_merge() {
  need_git
  local br="${1:-}" base out m
  [ -n "$br" ] || { echo "warmd merge <branch>"; return 2; }
  base="$(base_branch)"
  [ "$(git -C "$GIT_ROOT" branch --show-current)" = "$base" ] || { echo "FAIL merge only from a checkout of $base"; return 2; }
  [ -z "$(git -C "$GIT_ROOT" status --porcelain -uno)" ] || { echo "FAIL uncommitted changes, nothing done"; return 2; }
  git -C "$GIT_ROOT" rev-parse --verify -q "$br" >/dev/null || { echo "FAIL unknown branch $br"; return 2; }
  out="$(git -C "$GIT_ROOT" merge --no-commit --no-ff "$br" 2>&1)" || {
    echo "FAIL conflict in $(echo "$out" | grep -c CONFLICT) files"; echo "$out" | grep CONFLICT | head -8 | cut -c1-160; git -C "$GIT_ROOT" merge --abort; return 1; }
  echo "$out" | grep -q "Already up to date" && { echo "OK nothing to merge"; return 0; }
  mfail() { echo "FAIL merge $br: $*"; git -C "$GIT_ROOT" reset -q --hard HEAD; return 1; }
  m="$(git -C "$GIT_ROOT" -c core.whitespace=-trailing-space,-space-before-tab,-blank-at-eof,-blank-at-eol diff --cached --check 2>&1 | head -3 | cut -c1-160)"; [ -z "$m" ] || { mfail "$m"; return 1; }
  if ! m="$(run_check 2>&1)"; then mfail "$(echo "$m" | head -3 | tr '\n' ' ' | cut -c1-200)"; return 1; fi
  git -C "$GIT_ROOT" add -u && git -C "$GIT_ROOT" commit -q -m "Merge $br" && echo "OK $(secs)s merged $br as $(git -C "$GIT_ROOT" rev-parse --short HEAD), not pushed"
}
