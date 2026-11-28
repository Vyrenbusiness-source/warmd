# Agent work: model routing by tier, cheap first, worktrees for parallel tasks, one-line prompts, safe merge.
# Tiers map to model aliases. Claude Code resolves haiku, sonnet and opus to the newest release, so a new model needs no change here.

route_tier() { # goal files
  local goal="$1" files="${2:-}"
  if [ -z "$files" ] || [ "$files" = none ]; then apply_floor cheap; return; fi
  local tier=mid
  if echo "$goal" | grep -qiE "$CFG_top_words"; then tier=top; fi
  if [ -n "$CFG_top_paths" ] && echo "$files" | grep -qE "$CFG_top_paths"; then tier=top; fi
  # Learned from the ledger: an area where half of the mid attempts needed escalation (two or more tasks) starts at top. Older history.tsv counts still apply.
  if [ "$tier" = mid ]; then
    local area n e; area="$(area_of "$files")"
    read -r n e <<< "$(ledger_rate "$area" mid)"
    [ "${n:-0}" -ge 2 ] && [ $(( ${e:-0} * 2 )) -ge "$n" ] && tier=top
    if [ "$tier" = mid ] && [ -f "$STATE/history.tsv" ]; then
      n="$(grep -c "^escalated	$area$" "$STATE/history.tsv" 2>/dev/null)"
      [ "${n:-0}" -ge 2 ] && tier=top
    fi
    # Routing learns only upward: an area the ledger raised once stays raised, later successes never lower it again.
    # Only learning writes it: a goal word that asks for top raises that task, not its area.
    if [ "$tier" = top ]; then
      grep -qxF "$area" "$STATE/route-up" 2>/dev/null || { mkdir -p "$STATE"; echo "$area" >> "$STATE/route-up"; }
    elif grep -qxF "$area" "$STATE/route-up" 2>/dev/null; then tier=top
    fi
  fi
  apply_floor "$tier"
}
# floor in warmd.conf: the lowest tier this project accepts. Quality projects set mid or top, a failed cheap attempt costs more than it saves.
apply_floor() {
  case "$CFG_floor:$1" in
    top:*) echo top;;
    mid:cheap) echo mid;;
    *) echo "$1";;
  esac
}
area_of() { echo "$1" | cut -d, -f1 | sed 's#/[^/]*$##'; }
. "$WARMD_HOME/lib/models.sh"
# role_scout sets the cheap tier's model, role_worker the mid and top tiers': only when it ranks at least as high as the
# tier's own model, so an escalation always climbs (lib/models.sh).
tier_model() {
  local t m=""
  case "$1" in cheap) t="$CFG_cheap"; role_model scout && m="$REPLY";; top) t="$CFG_top"; role_model worker && m="$REPLY";; *) t="$CFG_mid"; role_model worker && m="$REPLY";; esac
  if [ -n "$m" ]; then model_rank "$m"; local a=$REPLY; model_rank "$t"; [ "$a" -ge "$REPLY" ] && t="$m"; fi
  echo "$t"
}
# task_model <tier> <role>: a qa task runs on role_qa when it ranks at least as high as the tier's model
task_model() {
  local t m; t="$(tier_model "$1")"
  [ "$2" = qa ] && role_model qa && { m="$REPLY"; model_rank "$m"; local a=$REPLY; model_rank "$t"; [ "$a" -ge "$REPLY" ] && t="$m"; }
  echo "$t"
}
tier_budget() { case "$1" in cheap) echo "$CFG_budget_cheap";; top) echo "$CFG_budget_top";; *) echo "$CFG_budget_mid";; esac; }
tier_next() { case "$1" in cheap) echo mid;; mid) echo top;; *) echo "";; esac; }
# tier_agent <tier> [text]: text that names MCP tools (mcp_words in warmd.conf) gets warmd-worker-mcp, the only agent without a tools list
tier_agent() {
  if [ -n "${2:-}" ] && [ -n "$CFG_mcp_words" ] && printf '%s' "$2" | grep -qiE "$CFG_mcp_words"; then echo "${AGENT_NS:-}warmd-worker-mcp"; return; fi
  case "$1" in cheap) echo "${AGENT_NS:-}warmd-scout";; *) echo "${AGENT_NS:-}warmd-worker";; esac
}
task_agent() { tier_agent "$1" "$(sed -n 's/^Goal: //p' "$2" 2>/dev/null)"; }
# Editing never runs on the cheap tier, whatever the config says: that tier only reads

route_print() {
  [ -n "${1:-}" ] || { echo "warmd route <goal> [files], e.g. warmd route 'fix the footer' src/footer.css"; return 2; }
  local t; t="$(route_tier "$1" "${2:-}")"
  echo "$t model=$(tier_model "$t") budget=$(tier_budget "$t")k agent=$(tier_agent "$t" "$1")"
}

need_git() { [ -n "$GIT_ROOT" ] || { echo "FAIL needs a git repo"; exit 2; }; }
worktree_dir() { echo "$(dirname "$GIT_ROOT")/.warmd-worktrees/$(basename "$GIT_ROOT")"; }
rel_project() { local r; r="$(git -C "$PROJECT" rev-parse --show-prefix)"; echo "${r%/}"; }   # from git: string math breaks on Windows short paths

# Godot import byproducts (.uid/.import) untracked in the base checkout that the incoming branch tracks would block
# the merge. Godot regenerates them, so they are removed first. Any other untracked file is left alone.
merge_clear_byproducts() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    git -C "$GIT_ROOT" ls-files --error-unmatch -- "$f" >/dev/null 2>&1 && continue
    rm -f -- "$GIT_ROOT/$f"
  done < <(git -C "$GIT_ROOT" ls-tree -r --name-only "$1" 2>/dev/null | grep -E '\.(uid|import)$')
}
# A merge stopped by a conflict: when every conflicted file is a Godot project.godot and every conflict block in it is one
# single-line list on both sides (key=PackedStringArray(...), the same key, e.g. locale/translations or
# editor_plugins/enabled), the lists are joined three-way: HEAD's order stays, an entry the branch added is appended, an
# entry one side removed from the common base stays out. The file is staged and the merge committed. REPLY holds one
# "resolved <file> list <key>: +n entries" line per block. Any other conflict (other files, other lines, a block of
# more than one line, a value that is no plain string list) returns 1 and touches nothing.
merge_godot_lists() { # branch
  local f files out rep="" tmp i k n
  files="$(git -C "$GIT_ROOT" diff --name-only --diff-filter=U)"
  [ -n "$files" ] || return 1
  while IFS= read -r f; do
    case "$f" in project.godot|*/project.godot) ;; *) return 1;; esac
    # A content conflict only: ours and theirs both exist (modify/delete is no list to join)
    git -C "$GIT_ROOT" ls-files -u -- "$f" | awk '{print $3}' | sort -u | tr -d '\n' | grep -qE '^1?23$' || return 1
  done <<< "$files"
  tmp="$(mktemp -d)" || return 1
  # Every file is joined into $tmp first: one block that is no list leaves all of them as git left them
  i=0
  while IFS= read -r f; do
    i=$((i+1))
    git -C "$GIT_ROOT" show ":1:$f" > "$tmp/base" 2>/dev/null || : > "$tmp/base"
    # BINMODE=3: gawk of Git for Windows drops the CR of a CRLF file on read otherwise
    out="$(awk -v BINMODE=3 -v res="$tmp/res.$i" "$(cat <<'AWK'
function plist(v, arr,   n, s) {   # PackedStringArray("a", "b") -> arr[1..n] (quoted tokens), -1 when it is no plain string list
  if (v !~ /^PackedStringArray\(.*\)$/) return -1
  s = substr(v, 19, length(v) - 19); n = 0
  while (s != "") {
    if (!match(s, /^"([^"\\]|\\.)*"/)) return -1
    arr[++n] = substr(s, 1, RLENGTH); s = substr(s, RLENGTH + 1)
    if (s == "") break
    if (!match(s, /^[ ]*,[ ]*/)) return -1
    s = substr(s, RLENGTH + 1)
  }
  return n
}
function keyof(l) { return (l ~ /^[A-Za-z0-9_\/.-]+=PackedStringArray\(/) ? substr(l, 1, index(l, "=") - 1) : "" }
function has(arr, n, t,   i) { for (i = 1; i <= n; i++) if (arr[i] == t) return 1; return 0 }
function bad(why) { print "NO " why; failed = 1; exit 1 }
{ file = (FILENAME == ARGV[1]) ? 1 : 2; cr = sub(/\r$/, "") ? "\r" : "" }
file == 1 { if ($0 ~ /^\[.*\]$/) bsec = $0; else if (index($0, "=")) bval[bsec SUBSEP substr($0, 1, index($0, "=") - 1)] = substr($0, index($0, "=") + 1); next }
st == 0 && /^<<<<<<< / { st = 1; no = 0; nt = 0; next }
st == 0 { if ($0 ~ /^\[.*\]$/) sec = $0; out[++nl] = $0 cr; next }
st == 1 && /^\|\|\|\|\|\|\| / { st = 2; next }
st != 0 && st != 3 && /^=======$/ { st = 3; next }
st == 1 { OL[++no] = $0; OC[no] = cr; next }
st == 2 { next }
# A block: both sides line by line, the same line count. An equal line stays, a differing pair must be one list of the
# same key; git folds nearby changes into one block, so a block may hold both lists and the lines between them.
st == 3 && /^>>>>>>> / {
  st = 0; joined = 0
  if (no != nt) bad("sides of a different line count")
  for (j = 1; j <= no; j++) {
    if (OL[j] == TL[j]) { if (OL[j] ~ /^\[.*\]$/) sec = OL[j]; out[++nl] = OL[j] OC[j]; continue }
    k = keyof(OL[j])
    if (k == "" || k != keyof(TL[j])) bad("no list of the same key on both sides")
    split("", A); split("", B); split("", O)
    na = plist(substr(OL[j], length(k) + 2), A); nb = plist(substr(TL[j], length(k) + 2), B)
    if (na < 0 || nb < 0) bad(k " is no plain string list")
    no2 = 0; if ((sec SUBSEP k) in bval) { no2 = plist(bval[sec SUBSEP k], O); if (no2 < 0) bad(k " in the base is no plain string list") }
    v = ""; n = 0; add = 0
    for (i = 1; i <= na; i++) if (!(has(O, no2, A[i]) && !has(B, nb, A[i]))) { v = v (n++ ? ", " : "") A[i] }
    for (i = 1; i <= nb; i++) if (!has(A, na, B[i]) && !has(O, no2, B[i])) { v = v (n++ ? ", " : "") B[i]; add++ }
    out[++nl] = k "=PackedStringArray(" v ")" OC[j]
    print k " " add; joined++
  }
  if (!joined) bad("a block without a list")
  next
}
st == 3 { TL[++nt] = $0; next }
END {
  if (failed) exit 1
  if (st != 0) { print "NO an unclosed conflict block"; exit 1 }
  for (i = 1; i <= nl; i++) print out[i] > res
}
AWK
)" "$tmp/base" "$GIT_ROOT/$f")" || { rm -rf "$tmp"; return 1; }
    [ -n "$out" ] && [ -f "$tmp/res.$i" ] || { rm -rf "$tmp"; return 1; }
    while read -r k n; do rep+="resolved $f list $k: +$n entries"$'\n'; done <<< "$out"
  done <<< "$files"
  i=0
  while IFS= read -r f; do
    i=$((i+1))
    cp "$tmp/res.$i" "$GIT_ROOT/$f" && git -C "$GIT_ROOT" add -- "$f" || { rm -rf "$tmp"; return 1; }
  done <<< "$files"
  rm -rf "$tmp"
  [ -z "$(git -C "$GIT_ROOT" diff --name-only --diff-filter=U)" ] || return 1
  git -C "$GIT_ROOT" commit -q --no-edit -m "Merge $1" ${WARMD_TRAILER:+-m "$WARMD_TRAILER"} >/dev/null 2>&1 || return 1
  REPLY="${rep%$'\n'}"
}
# Work left in a worktree: tracked changes and new files, but not files the engine writes on its own (Godot .uid/.import next to every asset).
wt_work() { git -C "$1" status --porcelain 2>/dev/null | grep -vE '^(\?\?| M) .*\.(uid|import)$|^\?\? \.?godot/|^\?\? .*/\.godot/'; }   # also a tracked .uid Godot rewrote
# A finished worktree keeps its slow caches, so reusing one beats copying gigabytes. Only when its work is merged and nothing is open or running.
wt_free() { # path
  local p="$1" rel; rel="$(rel_project)"
  [ -z "$(git -C "$p" status --porcelain -uno | grep -vE '\.sln[x]?$|Assets/Editor/Warmd/')" ] || return 1   # a daemon warmd renewed is no work
  git -C "$p" merge-base --is-ancestor HEAD "$(base_branch)" 2>/dev/null || return 1
  a_has_cache "$p${rel:+/$rel}" || return 1
  [ -z "$(procs_like "$(native_path "$p")" 'powershell|git')" ]
}
# A branch already merged into base holds nothing new: the worktree starts again from base, so the next task never builds on a stale state.
wt_fresh() { # path name
  local p="$1" base; base="$(base_branch)"
  [ -z "$(git -C "$p" status --porcelain -uno | grep -vE '\.sln[x]?$')" ] || return 0
  git -C "$p" merge-base --is-ancestor HEAD "$base" 2>/dev/null || return 0
  [ "$(git -C "$p" rev-parse HEAD)" = "$(git -C "$p" rev-parse "$base")" ] && return 0
  git -C "$p" checkout -q -B "warmd/$2" "$base"
}
# A task name that was used before must never silently reuse its old branch: work not in base is refused, a merged or stale branch starts again at base.
wt_old_gap() { # name: prints a GAP line and returns 1 when the old branch/worktree of this name holds work base does not have
  local name="$1" br="warmd/$1" base ahead wt dirty=""; base="$(base_branch)"
  git -C "$GIT_ROOT" rev-parse -q --verify "refs/heads/$br" >/dev/null || return 0
  ahead="$(git -C "$GIT_ROOT" rev-list --count "$base..$br" 2>/dev/null || echo 0)"
  wt="$(git -C "$GIT_ROOT" worktree list --porcelain | awk -v b="refs/heads/$br" '/^worktree /{p=substr($0,10)} $0=="branch " b{print p; exit}')"
  [ -n "$wt" ] && [ -d "$wt" ] && dirty="$(git -C "$wt" status --porcelain -uno | grep -vE '\.sln[x]?$|Assets/Editor/Warmd/|\.(uid|import)$')"
  if [ "${ahead:-0}" -gt 0 ] || [ -n "$dirty" ]; then
    echo "GAP $name: branch $br already exists with ${ahead:-0} commit(s) not in $base${dirty:+ and uncommitted changes}. Use a new task name or: warmd drop $name --delete"
    return 1
  fi
}
# The branch of an earlier task has nothing base lacks: it is deleted or moved to base, so the new task starts on current code.
wt_old_renew() { # name
  local name="$1" br="warmd/$1" base wt; base="$(base_branch)"
  wt="$(worktree_dir)/$name"
  # The folder of this name may hold another task's branch (split reuses folders): switching it took a running task's
  # worktree away. Such a folder is left alone, wt_create gives this task a folder of its own.
  local cur; cur="$(git -C "$wt" branch --show-current 2>/dev/null)"
  if [ -d "$wt" ] && [ -n "$cur" ] && [ "$cur" != "$br" ] && { wt_taken "$wt" "$cur" || ! git -C "$wt" merge-base --is-ancestor HEAD "$base" 2>/dev/null; }; then wt=/nonexistent/warmd; fi
  if git -C "$GIT_ROOT" rev-parse -q --verify "refs/heads/$br" >/dev/null; then
    local at; at="$(git -C "$GIT_ROOT" worktree list --porcelain | awk -v b="refs/heads/$br" '/^worktree /{p=substr($0,10)} $0=="branch " b{print p; exit}')"
    if [ -n "$at" ] && [ -d "$at" ]; then git -C "$at" checkout -q -B "$br" "$base" 2>/dev/null || return 1
    elif [ -d "$wt" ]; then git -C "$wt" checkout -q -B "$br" "$base" 2>/dev/null || return 1
    else git -C "$GIT_ROOT" branch -q -D "$br" 2>/dev/null; fi
  elif [ -d "$wt" ]; then git -C "$wt" checkout -q -B "$br" "$base" 2>/dev/null || return 1
  fi
  return 0
}
# A worktree whose branch belongs to an unfinished task is never handed to another one: split switched the worktree of
# a running task (warmd/godot-sim, its work still untracked) to a new task's branch. Unfinished = a task file of that
# name and no warmd finish marker; new files count as work too.
wt_taken() { # path branch -> 0 when another task still owns it
  local p="$1" t="${2#warmd/}" common
  [ "$2" != "$t" ] || return 1
  [ -n "$(wt_work "$p")" ] && return 0
  common="$(git -C "$GIT_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  [ -f "$(ledger_taskdir)/$t.md" ] && [ ! -f "$common/warmd-auto/done/$t" ] && return 0
  return 1
}
wt_reuse() { # name
  local name="$1" p br base main; base="$(base_branch)"; main="$(git -C "$GIT_ROOT" worktree list --porcelain | sed -n '1s/^worktree //p')"
  # A worktree that already holds this task's branch keeps it and its commits: earlier work is never reset.
  while IFS='|' read -r p br; do
    [ "$br" = "warmd/$name" ] && [ "$p" != "$main" ] || continue
    wt_fresh "$p" "$name"
    echo "$p"; return 0
  done < <(git -C "$GIT_ROOT" worktree list --porcelain | awk '/^worktree /{p=substr($0,10)} /^branch /{b=$2; sub("refs/heads/","",b); print p"|"b}')
  while IFS='|' read -r p br; do
    [ "$br" = "$base" ] && continue
    [ "$p" = "$main" ] && continue
    # git prints C:/x, the shell uses /c/x: compare one form, or two tasks land in one worktree
    case " ${USED_WT:-} " in *" $(cd "$p" && pwd) "*) continue;; esac
    grep -qxF "$(cd "$p" && pwd)" "$(git -C "$GIT_ROOT" rev-parse --path-format=absolute --git-common-dir)/warmd-batch" 2>/dev/null && continue   # an agent of the running batch works there
    wt_taken "$p" "$br" && continue
    wt_free "$p" || continue
    git -C "$p" checkout -q -- . 2>/dev/null
    if git -C "$GIT_ROOT" rev-parse -q --verify "refs/heads/warmd/$name" >/dev/null; then
      git -C "$p" checkout -q "warmd/$name" || continue   # existing branch: keep its commits
      wt_fresh "$p" "$name"
    else
      git -C "$p" checkout -q -B "warmd/$name" "$base" || continue
    fi
    echo "$p"; return 0
  done < <(git -C "$GIT_ROOT" worktree list --porcelain | awk '/^worktree /{p=substr($0,10)} /^locked/{p=""} /^branch /{b=$2; sub("refs/heads/","",b); if(p!="")print p"|"b}')
  return 1
}

# A new worktree is useless until its slow caches exist: the adapter copies or links them (Library, .godot, node_modules).
wt_create() { # name
  local name="$1" wt branch src rel
  wt="$(worktree_dir)/$name"; branch="warmd/$name"
  rel="$(rel_project)"; src="$PROJECT"
  # The folder of this name holds another task's branch that is still owned: that task keeps it, this one gets a new folder
  if [ -d "$wt" ]; then
    local cur; cur="$(git -C "$wt" branch --show-current 2>/dev/null)"
    if [ -n "$cur" ] && [ "$cur" != "$branch" ] && { wt_taken "$wt" "$cur" || ! git -C "$wt" merge-base --is-ancestor HEAD "$(base_branch)" 2>/dev/null; }; then
      wt="$wt-$(date +%s)"; echo "(worktree folder $name holds $cur, still owned: using ${wt##*/})" >&2
      mkdir -p "$(worktree_dir)"
      git -C "$GIT_ROOT" worktree add -q -b "$branch" "$wt" HEAD 2>/dev/null || git -C "$GIT_ROOT" worktree add -q "$wt" "$branch" || return 1
      wt_seed "$src" "$wt${rel:+/$rel}"
      echo "$wt"; return 0
    fi
  fi
  # Every worktree of a split gets the base's Library, also a reused one: a worktree never imports cold
  if [ -d "$wt" ]; then wt_fresh "$wt" "$name"; wt_seed "$src" "$wt${rel:+/$rel}"; echo "$wt"; return 0; fi
  if wt="$(wt_reuse "$name")"; then wt_seed "$src" "$wt${rel:+/$rel}"; echo "$wt"; return 0; fi
  wt="$(worktree_dir)/$name"
  mkdir -p "$(worktree_dir)"
  git -C "$GIT_ROOT" worktree add -q -b "$branch" "$wt" HEAD 2>/dev/null || git -C "$GIT_ROOT" worktree add -q "$wt" "$branch" || return 1
  wt_seed "$src" "$wt${rel:+/$rel}"
  echo "$wt"
}
# The caches of a new or reused worktree, then what the adapter needs to run there at once (Godot: ignored .import
# files, a current class cache). stdout is the worktree path of wt_create: anything said goes to stderr.
wt_seed() { # base project, worktree project
  a_seed "$1" "$2" >/dev/null 2>&1; seed_links "$1" "$2"; worktree_links "$1" "$2"
  [ "$(type -t a_wt_ready)" = function ] && a_wt_ready "$1" "$2" >&2
  return 0
}

# Shared brief: one short file all agents of a batch read. It lives in the common git dir, so every worktree sees the same copy and it never gets committed.
# It stops parallel agents from searching for the same thing twice and shows who owns which file.
shared_file() { echo "$(git -C "$PROJECT" rev-parse --path-format=absolute --git-common-dir)/warmd-shared.md"; }
shared_start() { # owner lines
  local f; f="$(shared_file)"
  {
    echo "# Shared brief"
    echo "Read once at the start. Before searching, check Findings. Add what others need: warmd note \"one line\"."
    echo
    echo "## Who owns what"
    printf '%s' "$1"
    echo
    echo "## Findings"
  } > "$f"
}
# A split into a running batch adds its owners and keeps the findings of the agents already at work.
shared_add() { # owner lines
  local f; f="$(shared_file)"
  [ -f "$f" ] || { shared_start "$1"; return; }
  OWN="$1" awk '$0=="" {blank++; next} $0=="## Findings" && !d {printf "%s", ENVIRON["OWN"]; d=1} {while (blank>0) {print ""; blank--}; print} END {while (blank>0) {print ""; blank--}}' "$f" > "$f.$$" && mv -f "$f.$$" "$f"
}
# Files owned by the running batch, from the brief.
shared_owned() { # file@owner words
  # Only tasks still in the batch own files: a task that left it (merged, pruned) frees its files for the next split.
  local batch live=" " wt
  batch="$(git -C "$PROJECT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/warmd-batch"
  # A finished task (its agent stopped, warmd-batch-done) frees its files too: a paused task blocked the next split.
  if [ -f "$batch" ]; then while IFS= read -r wt; do [ -d "$wt" ] && ! wt_finished "${batch%/warmd-batch}" "$wt" && live="$live$(wt_task "$wt") "; done < "$batch"; fi
  sed -n '/^## Who owns what/,/^## Findings/s/^- \([^:]*\): \(.*\)$/\1 \2/p' "$(shared_file)" 2>/dev/null | while read -r o fs; do
    [ "$fs" = none ] && continue
    if [ -f "$batch" ]; then case "$live" in *" $o "*) ;; *) continue;; esac; fi
    for f in ${fs//,/ }; do printf '%s@%s ' "$f" "$o"; done
  done
}
# Is this task already part of the running batch? Then a split again reuses it and takes no new place.
batch_has() { # batchfile name
  local wt; [ -f "$1" ] || return 1
  while IFS= read -r wt; do
    [ -d "$wt" ] && [ "$(wt_task "$wt")" = "$2" ] || continue
    wt_finished "${1%/warmd-batch}" "$wt" && return 1   # stopped: a new start takes a place
    return 0
  done < "$1"
  return 1
}

# agents= in warmd.conf caps the running tasks. Unset: one per core and one per 2 GB RAM, the smaller one, at least 1.
# Agents wait on the API most of the time, so the default is wider than tune_slots; heavy runs still queue through the slots.
team_agents() {
  if [ -n "${CFG_agents:-}" ]; then echo "$CFG_agents"; return; fi
  local v c r a b n; v="$(hw)"; c="${v% *}"; r="${v#* }"
  a=$c; b=$(( r / 2048 ))
  n=$a; [ "$b" -lt "$n" ] && n=$b; [ "$n" -lt 1 ] && n=1
  echo "$n"
}
# Worktrees of the batch whose agent has not stopped yet (the stop hook writes warmd-batch-done).
# One spelling per folder: the Windows runner mixes 8.3 short names (RUNNER~1) with long names for the same path
wt_norm() { # path -> long, absolute form
  local p; p="$(cd "$1" 2>/dev/null && pwd -P)" || p="$1"
  if command -v cygpath >/dev/null 2>&1; then p="$(cygpath -u "$(cygpath -l -w "$p" 2>/dev/null || echo "$p")" 2>/dev/null || echo "$p")"; fi
  printf '%s\n' "$p"
}
# wt_norm_r: the same into REPLY, remembered per path for the life of this shell. warmd watch asks every 90 s for every
# worktree; three program starts per path and round add up on machines that keep kernel memory per process start.
declare -gA WT_NORM_MEMO=()
wt_norm_r() { # path -> REPLY
  if [ -n "${WT_NORM_MEMO[$1]+x}" ]; then REPLY="${WT_NORM_MEMO[$1]}"; return 0; fi
  REPLY="$(wt_norm "$1")"; WT_NORM_MEMO[$1]="$REPLY"
}

team_running() { # batchfile
  local wt n=0
  [ -f "$1" ] || { echo 0; return; }
  # wt_finished, not the path alone: the finished line of the task a reused worktree held before does not count its new task out
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    wt_finished "${1%/warmd-batch}" "$wt" && continue
    n=$((n+1))
  done < "$1"
  echo "$n"
}
# Only the newest 40 findings stay, so the brief never grows into the next HANDOFF
team_note() {
  need_git
  local text="${1:-}" f who keep; f="$(shared_file)"
  # A BRAKE note goes to the machine-wide brake log (lib/brake.sh) too: the brief keeps 40 lines and ends with the batch
  local braked=""
  case "$text" in BRAKE:*|brake:*) [ -f "$f" ] && grep -qF -- "$text" "$f" || { type brake_from_note >/dev/null 2>&1 && brake_from_note "$text" && braked=1; };; esac
  [ -f "$f" ] || { [ -n "$braked" ] && { echo "OK brake recorded (no batch brief to note it in)"; return 0; }; echo "FAIL no shared brief, warmd split creates it"; return 2; }
  [ -n "$text" ] || { echo "warmd note \"one line\""; return 2; }
  [ ${#text} -le 160 ] || { echo "FAIL over 160 characters, keep it to one fact"; return 2; }
  grep -qF -- "$text" "$f" && { echo "OK already noted"; return 0; }
  who="$(git -C "$GIT_ROOT" branch --show-current)"
  echo "- ${who#warmd/}: $text" >> "$f"
  keep="$(awk '/^## Findings/{print NR}' "$f")"
  if [ "$(( $(wc -l < "$f") - keep ))" -gt 40 ]; then { head -n "$keep" "$f"; tail -n 40 "$f"; } > "$f.tmp"; mv "$f.tmp" "$f"; fi
  echo "OK noted"
}

# seed_links in warmd.conf: untracked folders a worktree needs, linked instead of copied
# Every link also goes into info/exclude: git sees a junction as a plain folder, so git add -A (the handoff WIP commit) took
# thousands of package files into a task branch, and its revert deleted them from the worktree.
seed_links() { # from to
  local item ex rel; ex="$(git -C "$GIT_ROOT" rev-parse --path-format=absolute --git-common-dir)/info/exclude"; rel="$(rel_project)"
  for item in ${CFG_seed_links//,/ }; do
    mkdir -p "${ex%/*}"
    grep -qxF "/${rel:+$rel/}$item/" "$ex" 2>/dev/null || echo "/${rel:+$rel/}$item/" >> "$ex"
    [ -e "$1/$item" ] && [ ! -e "$2/$item" ] || continue
    if [ "$OS" = win ]; then powershell.exe -NoProfile -Command "New-Item -ItemType Junction -Path '$(native_path "$2/$item")' -Target '$(native_path "$1/$item")'" >/dev/null 2>&1
    else ln -s "$1/$item" "$2/$item"; fi
  done
}

# worktree_links in warmd.conf: globs (relative to the project, space or comma separated) of git-ignored files a worktree needs,
# e.g. tools/luau/*.exe. Files are copied, folders linked like seed_links. Existing targets stay. Default: none.
worktree_links() { # from to
  [ -n "${CFG_worktree_links:-}" ] || return 0
  local g m rel
  for g in ${CFG_worktree_links//,/ }; do
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      rel="${m#"$1"/}"
      [ -e "$2/$rel" ] && continue
      if [ -d "$m" ]; then
        mkdir -p "$(dirname "$2/$rel")"
        if [ "$OS" = win ]; then powershell.exe -NoProfile -Command "New-Item -ItemType Junction -Path '$(native_path "$2/$rel")' -Target '$(native_path "$m")'" >/dev/null 2>&1
        else ln -s "$m" "$2/$rel"; fi
      else
        mkdir -p "$(dirname "$2/$rel")"; cp -p "$m" "$2/$rel" 2>/dev/null
      fi
    done < <(cd "$1" 2>/dev/null && compgen -G "$g" | while IFS= read -r x; do echo "$1/$x"; done)
  done
}

# Time budget per tier in minutes (time_budget_cheap/mid/top in warmd.conf). warmd watch escalates a task past it.
tier_minutes() { case "$1" in cheap) echo "${CFG_time_budget_cheap:-30}";; top) echo "${CFG_time_budget_top:-120}";; *) echo "${CFG_time_budget_mid:-60}";; esac; }
# The author never reviews itself: the reviewer is role_reviewer (default the top model), never the author's model and
# never below floor. Without such a model only the done check (a criteria script) judges.
review_model() { # author model -> REPLY, empty when no other model qualifies
  local c min; floor_rank; min=$REPLY
  role_model reviewer || REPLY="$CFG_top"
  for c in "$REPLY" "$CFG_top" "$CFG_mid" "$CFG_cheap"; do
    [ -n "$c" ] && [ "$c" != "$1" ] || continue
    model_rank "$c"; [ "$REPLY" -ge "$min" ] && { REPLY="$c"; return 0; }
  done
  REPLY=""; return 1
}
review_line() { # author model
  if review_model "$1"; then echo "Review: the done check, or a reviewer agent on $REPLY. Never $1 (the author) on its own work."
  else echo "Review: the done check only (criteria script), no model other than $1 (the author) is allowed by floor."; fi
}
# The agent file of a role is only registered in projects with warmd init. A session started elsewhere cannot spawn it:
# the FALLBACK line carries the worker rules inline for a general-purpose agent.
agent_fallback() { # name agent model taskfile
  local d="${CLAUDE_PROJECT_DIR:-$GIT_ROOT}" rules
  [ -z "${AGENT_NS:-}" ] || return 0   # the plugin registers its agents itself
  [ -f "$d/.claude/agents/${2#*:}.md" ] && return 0
  [ -f "$WARMD_HOME/agents/${2#*:}.md" ] || return 0
  rules="$(awk 'f>=2 && /^- / {sub(/^- /, ""); printf "%s ", $0} /^---$/ {f++}' "$WARMD_HOME/agents/${2#*:}.md" | tr '"' "'")"
  echo "FALLBACK $1 (no ${2#*:} agent in $(native_path "$d")/.claude/agents): subagent_type=general-purpose model=$3 prompt=\"You are a warmd worker. ${rules}Read $4 and do it.\""
}

write_task() { # name tier goal done files wt
  local name="$1" tier="$2" goal="$3" check="$4" files="$5" wt="$6" f port role model area
  mkdir -p "$STATE/tasks"; f="$STATE/tasks/$name.md"
  port=$(( 7830 + $(ls "$STATE/tasks" | wc -l) * 10 ))
  role_of "$name" "$goal" "$files"; role="$REPLY"
  model="$(task_model "$tier" "$role")"
  area="$role"; [ "$role" = worker ] && { area_role "$files"; area="$REPLY"; }
  [ "$role" = scout ] || role_file_init "$area"
  {
    echo "Task $name. First run: cd \"$(native_path "$wt")\". Every command of this task runs there: start each Bash call with cd \"$(native_path "$wt")\" &&, the shell goes back to the main checkout after every call. Port block: $port."
    echo "Goal: $goal"
    echo "Done when: $check"
    echo "Files you own: ${files:-none, read only}"
    local bs; bs="$(git -C "$wt" merge-base HEAD "$(base_branch)" 2>/dev/null)" && echo "Base: $(base_branch) at ${bs:0:9} $(git -C "$wt" log -1 --format=%s "$bs" 2>/dev/null | cut -c1-60)"
    echo "Budget: under $(tier_budget "$tier")k tokens."
    echo "Shared brief: $(native_path "$(shared_file)")"
    echo "Docs: a new command's entry (### warmd <name>) goes to docs/pending/$name.md, that file is yours; warmd ship moves it into docs/COMMANDS.md."
    echo "Handoff: past 70% of the budget or after 60 tool calls, commit, run warmd handoff $name \"what is done\" \"what is next\", end with its AGENT line. A fresh agent is cheaper than a full context."
    echo "Time budget: $(tier_minutes "$tier") min. warmd watch escalates the task past it: commit before."
    review_line "$model"
    [ "$role" = scout ] || echo "Role $area: read $(native_path "$(role_file "$area")") first, its Learned lines come from rolled-back merges."
  } > "$f"
  printf '%s\n' "$area" > "$STATE/tasks/$name.role"; printf '%s\n' "$model" > "$STATE/tasks/$name.model"; date +%s > "$STATE/tasks/$name.start"
  handoff_register "$name" "$(native_path "$f")" "$tier"
  echo "AGENT $name: subagent_type=$(task_agent "$tier" "$f") model=$model prompt=\"Read $(native_path "$f") and do it.\""
  agent_fallback "$name" "$(task_agent "$tier" "$f")" "$model" "$(native_path "$f")"
}

# Warm start for agents: the slow first start runs before the agent arrives, in the background and through the normal queue.
prewarm() { # worktree
  [ "$ADAPTER" = unity ] || return 0
  [ "${WARMD_NO_PREWARM:-0}" = 1 ] && return 0
  ( cd "$1" || exit 0; WARMD_BASE=1 WARMD_DETACHED=1 nohup bash "$WARMD_HOME/bin/warmd" ping > /dev/null 2>&1 < /dev/null & )
}

# A session that only waits for notifications sits idle forever when an agent hangs. Start this in the background with every batch:
# it ends, and so wakes the session, as soon as an agent has been idle for <minutes> (default 5) or the batch is over.
# An agent counts as active when a file or a commit changed, a warmd run (test, check, build, merge) holds its worktree, or a process runs inside it.
# On a stall: one WAKE line per idle agent with the message the session sends to it, then exit 3. Queued AGENT lines (lib/auto.sh) end it the same way;
# an ESCALATE or SHIP line only a human can act on ends it with exit 4 and an OPEN line while the batch runs. Exit 0 only when no batch runs.
# A paused task (its agent stopped, or warmd watch --pause <name>) never alarms until its worktree moves again.

# Does a warmd run or any other process work inside this worktree right now?
# warmd ci and warmd ship write .warmd/ci.wait while they poll: pid, run id, run start, median seconds
wt_ci_mark() { # worktree -> the marker line of a live CI wait
  local m; m="$(cat "$1/.warmd/ci.wait" 2>/dev/null)"; [ -n "$m" ] && shell_alive "${m%% *}" && echo "$m"
}

# One line for warmd watch: run, minutes in, ETA from the median of recent runs
wt_ci_eta() { # worktree
  local m id start med el; m="$(wt_ci_mark "$1")" || return 1
  local now; printf -v now '%(%s)T' -1
  read -r _ id start med <<< "$m"; el=$(( now - ${start:-0} ))
  if [ "${med:-0}" -gt 0 ]; then
    if [ "$med" -gt "$el" ]; then echo "run $id, $((el / 60)) min in, about $(( (med - el + 59) / 60 )) min left"
    else echo "run $id, $((el / 60)) min in, past the median of $(( (med + 30) / 60 )) min"; fi
  else echo "run $id, $((el / 60)) min in, no ETA yet"; fi
}

# A warmd test, check or build of this worktree is running: its own project or one in a subfolder (lib/core.sh run_mark)
wt_run_active() { # worktree
  local d; for d in "$1/.warmd" "$1"/*/.warmd; do [ -d "$d/run/active" ] && run_active "$d" >/dev/null && return 0; done
  return 1
}

wt_busy() { # worktree
  local wt="$1" f pid
  wt_ci_mark "$wt" >/dev/null && return 0   # polling CI is work, not idle
  wt_run_active "$wt" && return 0
  for f in "$wt/.warmd/job.lock/pid" "$wt/.warmd/merge.owner"; do
    pid="$(cat "$f" 2>/dev/null)"
    [ -n "$pid" ] && shell_alive "$pid" && return 0
  done
  # A merge started through Win32_Process.Create (hook_detach) need not share this shell's msys pid table: its Windows pid counts
  pid="$(cat "$wt/.warmd/merge.owner.win" 2>/dev/null)"
  [ -f "$wt/.warmd/merge.owner" ] && [ -n "$pid" ] && pid_alive "$pid" && return 0
  # A program that names the worktree in its command line (an editor's -projectPath, a build): one process list per round
  [ -n "$(procs_like "$(native_path "$wt")" 'powershell|git|warmd watch')" ] && return 0
  wt_ci_wait "$wt"
}

# Command lines of running gh calls that wait on remote CI: gh run watch, gh pr checks --watch
gh_watchers() {
  local c
  while IFS= read -r c; do [[ $c =~ run\ +watch|pr\ +checks.*--watch ]] && printf '%s\n' "$c"; done < <(procs_cmdlines 'gh(\.exe)?.? +(run|pr) ')
}

# An agent that waits on CI for its branch is working: the gh watch names the branch, a PR number or a run id of that branch.
wt_ci_wait() { # worktree
  local wt="$1" lines b tok ids want
  lines="$(gh_watchers)"; [ -n "$lines" ] || return 1
  b="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)"; [ -n "$b" ] && [ "$b" != HEAD ] || return 1
  ids=""
  for tok in $(printf '%s\n' "$lines" | tr -d "\"'"); do
    [ "$tok" = "$b" ] && return 0
    case "$tok" in */pull/*|*/runs/*) tok="${tok##*/}";; esac
    case "$tok" in ''|*[!0-9]*) ;; *) ids="$ids $tok";; esac
  done
  [ -n "$ids" ] && command -v gh >/dev/null 2>&1 || return 1
  want="$( cd "$wt" && { gh pr list --head "$b" --state all --json number -q '.[].number'; gh run list --branch "$b" --limit 30 --json databaseId -q '.[].databaseId'; } 2>/dev/null | tr -d '\r')"
  for tok in $ids; do printf '%s\n' "$want" | grep -qx "$tok" && return 0; done
  return 1
}

# Task name of a worktree: the branch warmd/<name>, else the folder name.
wt_task() { # worktree
  local b; b="$(git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  case "$b" in warmd/*) echo "${b#warmd/}";; *) basename "$1";; esac
}
# wt_task_r: the same into REPLY from the worktree's .git file and HEAD with builtins, git only when they are unreadable
wt_task_r() { # worktree -> REPLY
  local g="" h=""
  { IFS= read -r g < "$1/.git"; } 2>/dev/null; g="${g%$'\r'}"; g="${g#gitdir: }"
  [ -d "$1/.git" ] && g="$1/.git"
  [ -n "$g" ] && { IFS= read -r h < "$g/HEAD"; } 2>/dev/null; h="${h%$'\r'}"
  case "$h" in
    "ref: refs/heads/warmd/"*) REPLY="${h#ref: refs/heads/warmd/}";;
    "ref: refs/heads/"*) REPLY="${1%/}"; REPLY="${REPLY##*/}";;
    *) REPLY="$(wt_task "$1")";;
  esac
}

# Minutes since the last movement in a worktree, 0 while a run or process is active.
wt_idle() { # worktree limit batchfile [task name]
  local wt="$1" limit="$2" batch="$3" last started
  if [ -n "$(find "$wt" -type f -mmin "-$limit" -not -path "$wt/.git/*" -not -path "$wt/*/.git/*" -not -path "$wt/Library/*" -not -path "$wt/*/Library/*" -not -path "$wt/.warmd/*" -not -path "$wt/*/.warmd/*" -not -path "$wt/Temp/*" -not -path "$wt/*/Temp/*" -not -path "$wt/Logs/*" -not -path "$wt/*/Logs/*" -not -path "$wt/obj/*" -not -path "$wt/*/obj/*" -not -path "$wt/node_modules/*" -not -path "$wt/*/node_modules/*" -print -quit 2>/dev/null)" ]; then echo 0; return; fi
  # The batch start counts as movement: a worktree reused with an old commit is not stalled at minute zero.
  last="$(git -C "$wt" log -1 --format=%ct 2>/dev/null || echo 0)"
  [ "$batch" = "${WATCH_BATCH_F:-}" ] || { WATCH_BATCH_F="$batch"; WATCH_BATCH_T="$(date -r "$batch" +%s 2>/dev/null || echo 0)"; }
  started="$WATCH_BATCH_T"
  [ "$started" -gt "$last" ] && last="$started"
  local now; printf -v now '%(%s)T' -1
  local age=$(( (now - last) / 60 ))
  [ "$age" -lt "$limit" ] && { echo 0; return; }
  wt_busy "$wt" && { echo 0; return; }
  # An agent that reads or thinks writes no file, but its transcript grows: that is movement too.
  [ -n "${4:-}" ] && wt_talking "$4" "$limit" && { echo 0; return; }
  echo "$age"
}

wt_talking() { # name limit -> 0 when a transcript of this task changed in the last <limit> minutes
  local root="${WARMD_TRANSCRIPTS:-$HOME/.claude/projects}"
  [ -d "$root" ] || return 1
  find "$root" -name '*.jsonl' -mmin "-$2" -exec grep -lF "tasks/$1.md" {} + 2>/dev/null | grep -q .
}

# An agent that died at start (API or billing error) never commits. Its transcript names the reason. Transcripts: WARMD_TRANSCRIPTS, default ~/.claude/projects.
agent_dead() { # worktree name -> reason
  local wt="$1" name="$2" root="${WARMD_TRANSCRIPTS:-$HOME/.claude/projects}" f
  [ "$(git -C "$wt" rev-list --count "$(base_branch)..HEAD" 2>/dev/null || echo 1)" = 0 ] || return 1
  [ -d "$root" ] || return 1
  f="$(find "$root" -name '*.jsonl' -mmin -1440 -exec grep -lF "tasks/$name.md" {} + 2>/dev/null | head -1)"
  [ -n "$f" ] || return 1
  # Only a real API error counts: its text starts a JSON string ("API Error: ...", "Credit balance is too low ...").
  # Words like "rate limit" or "billing" inside files the agent read (tool results, specs) are not a death.
  grep -oE '"(API Error|Credit balance is too low|Invalid API key|Please run /login)[^"\]{0,80}' "$f" | head -1 | cut -c2- | grep .
}

# watch_drain <common> <batch>: the queued lines for the session. 3 when one starts an agent (AGENT), 4 when only a human
# can act (ESCALATE, SHIP): the batch is not over then, and a closing line says so, because exit 0 means "batch over"
# and a watch piped through tail loses its exit code. 1 when nothing was queued.
watch_drain() {
  local out; out="$(auto_drain "$1")" || return 1
  printf '%s\n' "$out"
  case $'\n'"$out" in *$'\n'"AGENT "*) return 3;; esac
  [ -f "$2" ] && echo "OPEN batch still runs, the line above needs you; start warmd watch again"
  return 4
}

# task_over <name>: past its time budget? REPLY says by how much. Builtins only, warmd watch asks this every round.
task_over() { # name [taskdir]
  local st="" tier=mid now b d="${2:-$STATE/tasks}"
  [ -f "$d/$1.start" ] && read -r st < "$d/$1.start" || return 1
  [ -f "$d/$1.tier" ] && read -r tier < "$d/$1.tier"
  printf -v now '%(%s)T' -1
  case "$tier" in cheap) b="${CFG_time_budget_cheap:-30}";; top) b="${CFG_time_budget_top:-120}";; *) b="${CFG_time_budget_mid:-60}";; esac
  [[ $st =~ ^[0-9]+$ && $b =~ ^[0-9]+$ ]] || return 1
  [ $(( now - st )) -gt $(( b * 60 )) ] || return 1
  REPLY="$(( (now - st) / 60 )) min, time budget $b min ($tier)"
}

team_watch() {
  need_git
  local once=0 limit=5 batch wt age name stalled reason over_h out
  local common live paused ci ci_seen=" "
  local -A WATCH_LIVE=()
  common="$(git -C "$PROJECT" rev-parse --path-format=absolute --git-common-dir)"
  case "${1:-}" in   # a task whose agent was stopped by hand: watch leaves it alone until its worktree moves again
    --pause) [ -n "${2:-}" ] || { echo "warmd watch --pause <name>"; return 2; }; auto_pause "$common" "$2"; echo "OK $2 paused, watch skips it until its worktree moves"; return 0;;
  esac
  [ "${1:-}" = --once ] && { once=1; shift; }
  limit="${1:-5}"
  batch="$common/warmd-batch"
  watch_drain "$common" "$batch"; case $? in 3) return 3;; 4) return 4;; esac
  [ -f "$batch" ] || { echo "OK no batch running"; return 0; }
  while :; do
    watch_drain "$common" "$batch"; case $? in 3) return 3;; 4) return 4;; esac   # an automatic escalation waits for the session to start the next agent
    [ -f "$batch" ] || { echo "OK batch ended"; return 0; }
    stalled=0; live=0; paused=""; over_h=0
    while IFS= read -r wt; do
      [ -d "$wt" ] || continue
      wt_task_r "$wt"; name="$REPLY"
      # Its agent stopped and none started since: nothing to wake. Unless its own warmd run still works there:
      # an agent that ended its turn waiting for a background test comes back for the result, the batch is not over.
      if wt_finished "$common" "$wt"; then wt_run_active "$wt" && live=1; continue; fi
      if auto_paused "$common" "$name" "$wt"; then   # no agent runs there, nothing to wake
        if wt_run_active "$wt"; then live=1; else paused="$paused $name"; fi; continue
      fi
      grep -qxF "$name" "$batch-dead" 2>/dev/null && continue   # reported once, no further alarms for it
      if [ -z "${WATCH_LIVE[$wt]:-}" ] && reason="$(agent_dead "$wt" "$name")"; then
        echo "DEAD $name: died at start, no commit. Reason: $reason. Fix the cause, then start it again: \"Read $(native_path "$STATE/tasks/$name.md") and do it.\""
        echo "$name" >> "$batch-dead"; stalled=1; continue
      fi
      live=1; WATCH_LIVE[$wt]=1   # it got past the start once: agent_dead (git and find) is not asked again
      # Past its time budget: the task goes to the next tier (its AGENT line says to stop the old agent), at the top a human decides
      if task_over "$name"; then
        echo "OVER $name: $REPLY"
        if out="$(team_escalate "$name")"; then printf '%s
' "$out"; stalled=1
        else echo "ESCALATE $name: past its time budget at the top tier, stop its agent or raise time_budget_top in warmd.conf"; echo "$name" >> "$batch-dead"; over_h=1; fi
        continue
      fi
      if ci="$(wt_ci_eta "$wt")"; then   # once per run, the line changes only with the run
        case "$ci_seen" in *" $name:${ci%%,*} "*) ;; *) echo "CI $name: $ci"; ci_seen="$ci_seen$name:${ci%%,*} ";; esac
      fi
      age="$(wt_idle "$wt" "$limit" "$batch" "$name")"
      if [ "$age" -gt 0 ]; then
        echo "WAKE $name: idle $age min in $(native_path "$wt"). Send to the $name agent: \"Idle for $age minutes. Reply in one line with your state and next step, or run: warmd handoff $name \\\"what is done\\\" \\\"what is next\\\" and end with its AGENT line.\""
        stalled=1
      fi
    done < "$batch"
    [ $stalled = 1 ] && return 3
    [ $over_h = 1 ] && { echo "OPEN batch still runs, the line above needs you; start warmd watch again"; return 4; }
    [ $live = 1 ] && touch "$batch-alive"   # agents work: batch_guard keeps a marker older than 240 minutes
    [ $live = 0 ] && [ -n "$paused" ] && { echo "OK no agent runs, paused:$paused"; return 0; }
    [ $once = 1 ] && { echo "OK all worktrees moved in the last $limit minutes${paused:+, paused:$paused}"; return 0; }
    nap "${WARMD_WATCH_POLL:-90}"   # one round costs about 40 process starts per worktree, idle is judged in minutes
  done
}

# Leading and trailing blanks off. Not xargs: it stops at the first apostrophe and cuts the goal.
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# Tasks file, one per line: name | goal | done check | files (comma separated, or none)
# Files may also be split by spaces: "lib bin" is two entries, not the one path "libbin".
files_norm() { printf '%s' "$1" | tr '[:blank:]' ',' | tr -s ',' | sed 's/^,//; s/,$//'; }
# A finished task: its agent stopped (the stop hook wrote warmd-batch-done) and no new agent started on it since
# (an Agent call on the task removes that line again). warmd watch never wakes such a worktree.
wt_finished() { # common worktree
  [ -f "$1/warmd-batch-done" ] || return 1
  # A line may name the branch its task held (third field): a worktree that holds another task's branch now is not
  # finished, or a split prunes it as free while the new agent works there and hands it to a second agent.
  local w d p b cur=""; wt_norm_r "$2"; w="$REPLY"
  while IFS= read -r d || [ -n "$d" ]; do
    p="${d%%$'\t'*}"; [ -n "$p" ] || continue
    wt_norm_r "$p"; [ "$REPLY" = "$w" ] || continue
    b=""; case "$d" in *$'\t'*$'\t'*) b="${d##*$'\t'}";; esac
    [ -n "$b" ] || return 0
    [ -n "$cur" ] || cur="$(git -C "$2" branch --show-current 2>/dev/null)"
    [ "$b" = "$cur" ] && return 0
  done < "$1/warmd-batch-done"
  return 1
}

batch_done_forget() { # common worktree
  [ -f "$1/warmd-batch-done" ] || return 0
  local w d keep=""; wt_norm_r "$2"; w="$REPLY"
  while IFS= read -r d || [ -n "$d" ]; do
    [ -n "$d" ] || continue
    wt_norm_r "${d%%$'\t'*}"; [ "$REPLY" = "$w" ] || keep="$keep$d"$'\n'
  done < "$1/warmd-batch-done"
  printf '%s' "$keep" > "$1/warmd-batch-done"
}

# When the next split appends to the batch, finished tasks whose work is merged (clean, nothing ahead of the base) leave it.
# A finished task with unmerged work stays: the automatic merge after the last agent still needs it.
# A worktree on another branch than its finished line names holds a new task: it stays and the stale line goes, or the
# automatic merge counts the new task as done and ends the batch while its agent still works there.
batch_prune() { # common
  local wt keep="" base batch="$1/warmd-batch"; base="$(base_branch)"
  while IFS= read -r wt; do
    [ -d "$wt" ] || continue
    if wt_finished "$1" "$wt"; then
      [ -z "$(wt_work "$wt")" ] && [ "$(git -C "$wt" rev-list --count "$base..HEAD" 2>/dev/null || echo 1)" = 0 ] && continue
    else
      batch_done_forget "$1" "$wt"
    fi
    keep="$keep$wt"$'\n'
  done < "$batch"
  printf '%s' "$keep" > "$batch"
}

# task_fields <line>: name | goal | done check | files. The goal may contain "|" itself (|x| <= y, a | b):
# name is the first field, files the last, the done check the one before it, the goal all in between.
task_fields() {
  local l="$1" rest pipes="${1//[^|]/}"
  if [ ${#pipes} -lt 3 ]; then IFS='|' read -r name goal check files <<< "$l"; return; fi
  name="${l%%|*}"; rest="${l#*|}"
  files="${rest##*|}"; rest="${rest%|*}"
  check="${rest##*|}"; goal="${rest%|*}"
}

# A new batch starts clean: no worktrees, no finished or dead marks, and no queued lines of the batch before it.
# An ESCALATE line of a task merged long ago stopped the first warmd watch of the next batch with exit 4.
# warmd-batch-start marks its start: warmd batch-resume tells the tasks of this batch from older worktrees by it.
# Scene ownership from the dependency graph: a task holds the scenes it owns and every scene that loads one of its files
# (ext_resource res:// paths, one level: the scenes whose text a change can break). Folders hold their scenes and the
# scenes that load anything inside them. Godot projects only; other projects have no scene graph.
task_scenes() { # files -> project-relative scene paths, one per line
  [ -f "$PROJECT/project.godot" ] || return 0
  local f p rel; rel="$(rel_project)"
  for f in ${1//,/ }; do
    f="${f#./}"; f="${f%/}"; [ -n "$rel" ] && f="${f#"$rel"/}"
    if [ -d "$PROJECT/$f" ]; then
      (cd "$PROJECT" && find "$f" -name '*.tscn' -not -path '*/.godot/*' 2>/dev/null)
      p="res://$f/"
    else
      case "$f" in *.tscn) echo "$f";; esac
      p="res://$f\""
    fi
    (cd "$PROJECT" && grep -rlF --include='*.tscn' --exclude-dir=.godot -e "$p" . 2>/dev/null | sed 's#^\./##')
  done | sort -u
}
# Is one of these scenes held by another task still in the batch (running, or finished and not merged)? REPLY names it.
scene_taken() { # common name scenes
  local wt live=" " sc t
  [ -s "$1/warmd-batch-scenes" ] || return 1
  while IFS= read -r wt; do [ -d "$wt" ] && live="$live$(wt_task "$wt") "; done < "$1/warmd-batch"
  while IFS=$'\t' read -r sc t; do
    [ "$t" != "$2" ] || continue
    case "$live" in *" $t "*) ;; *) continue;; esac
    printf '%s\n' "$3" | grep -qxF "$sc" && { REPLY="scene $sc is held by $t"; return 0; }
  done < "$1/warmd-batch-scenes"
  return 1
}
scene_hold() { # common name scenes
  local sc
  while IFS= read -r sc; do [ -n "$sc" ] && printf '%s\t%s\n' "$sc" "$2"; done <<< "$3" >> "$1/warmd-batch-scenes"
}

batch_fresh() { # common
  : > "$1/warmd-batch"; rm -f "$1/warmd-batch-scenes" "$1/warmd-batch-dead" "$1/warmd-batch-dropped" "$1/warmd-batch-done" "$1/warmd-auto/queue"; : > "$1/warmd-batch-start"
}

team_split() {
  need_git
  local file="${1:-}" name goal check files tier wt sc seen="" f n=0 bad=0 batch append=0 running=0 cap own="" waited=0 rel
  rel="$(rel_project)"
  [ -f "$file" ] || { echo "warmd split <file>, lines: name | goal | done check | files"; return 2; }
  ledger_cost_gate || return 2
  batch="$(git -C "$PROJECT" rev-parse --path-format=absolute --git-common-dir)/warmd-batch"
  # A batch already runs: append to it. Overwriting would drop its worktrees from watch and the batch guard.
  if [ -f "$batch" ]; then batch_prune "${batch%/warmd-batch}"; append=1; running="$(team_running "$batch")"; seen="$(shared_owned)"; fi
  cap="$(team_agents)"
  while IFS= read -r line <&3; do
    task_fields "$line"
    name="$(trim "$name")"; goal="$(trim "$goal")"; check="$(trim "$check")"; files="$(files_norm "$files")"
    case "$name" in \#*|"") continue;; esac
    if [ -n "$files" ] && [ "$files" != none ]; then
      for f in ${files//,/ }; do
        # the same task split again owns its files already, any other owner collides
        case " $seen " in *" $f@"*) case " $seen " in *" $f@$name "*) ;; *) echo "GAP $name: $f already owned in this batch, two agents would collide"; bad=1;; esac;; esac
        seen="$seen $f@$name"
      done
    fi
    [ -n "$check" ] || { echo "GAP $name: no done check"; bad=1; }
    if [ -n "$files" ] && [ "$files" != none ] && ! { [ $append = 1 ] && batch_has "$batch" "$name"; }; then wt_old_gap "$name" || bad=1; fi
    n=$((n+1))
  done 3< <(tr -d '\r' < "$file")
  [ $bad = 0 ] || { echo "FAIL fix the gaps, nothing was created"; return 1; }
  merge_wait
  [ $append = 1 ] || batch_fresh "${batch%/warmd-batch}"
  while IFS= read -r line <&3; do
    task_fields "$line"
    name="$(trim "$name")"; goal="$(trim "$goal")"; check="$(trim "$check")"; files="$(files_norm "$files")"
    case "$name" in \#*|"") continue;; esac
    if [ $append = 1 ] && batch_has "$batch" "$name"; then :
    elif [ "$running" -ge "$cap" ]; then
      echo "WAIT $name: $running of $cap agents run (agents= in warmd.conf), split it again when one is done"; waited=$((waited+1)); continue
    else running=$((running+1)); own="$own- $name: ${files:-none}"$'\n'
    fi
    # Two tasks on the same scene never run in parallel: the later one waits until the earlier one left the batch
    sc=""
    if [ -n "$files" ] && [ "$files" != none ] && ! { [ $append = 1 ] && batch_has "$batch" "$name"; }; then
      sc="$(task_scenes "$files")"
      if [ -n "$sc" ] && scene_taken "${batch%/warmd-batch}" "$name" "$sc"; then
        echo "WAIT $name: $REPLY, two tasks on one scene never run in parallel. Split it again when ${REPLY##* } is merged"
        waited=$((waited+1)); running=$((running-1)); continue
      fi
    fi
    tier="$(route_tier "$goal" "$files")"
    # A worktree without its engine cache gets a copy: only with room for it plus disk_min_mb, after freeing finished ones
    if [ -n "$files" ] && [ "$files" != none ] && disk_cache_name && [ ! -d "$(worktree_dir)/$name${rel:+/$rel}/$REPLY" ] && ! disk_room "$PROJECT" 1 "$(dirname "$GIT_ROOT")"; then
      disk_reclaim
      if ! disk_room "$PROJECT" 1 "$(dirname "$GIT_ROOT")"; then
        echo "WAIT $name: disk short, $REPLY. Split it again when space is free"; waited=$((waited+1)); running=$((running-1)); continue
      fi
    fi
    if [ -n "$files" ] && [ "$files" != none ] && ! { [ $append = 1 ] && batch_has "$batch" "$name"; }; then wt_old_renew "$name" || { echo "FAIL worktree $name: old branch warmd/$name could not move to $(base_branch)"; return 1; }; fi
    if [ -z "$files" ] || [ "$files" = none ]; then wt="$GIT_ROOT"; else wt="$(wt_create "$name")" || { echo "FAIL worktree $name"; return 1; }; USED_WT="${USED_WT:-} $(cd "$wt" && pwd)"; fi
    write_task "$name" "$tier" "$goal" "$check" "$files" "$wt"
    [ -z "$sc" ] || scene_hold "${batch%/warmd-batch}" "$name" "$sc"
    if [ -n "$files" ] && [ "$files" != none ]; then
      grep -qxF "$(cd "$wt" && pwd)" "$batch" || ( cd "$wt" && pwd ) >> "$batch"
      # A reused worktree may still carry the "finished" line of its previous task: the new task is not finished,
      # or the next split prunes it as free and hands the same worktree to a second agent.
      batch_done_forget "${batch%/warmd-batch}" "$wt"
      rm -f "${batch%/warmd-batch}/warmd-auto/done/$name"
      [ -f "${batch%/warmd-batch}/warmd-batch-dropped" ] && { grep -v "^$name	" "${batch%/warmd-batch}/warmd-batch-dropped" > "$batch-dropped.t"; mv -f "$batch-dropped.t" "${batch%/warmd-batch}/warmd-batch-dropped"; }   # split again: wanted again
      prewarm "$wt"
    fi
    printf '%s\n' "$tier" > "$STATE/tasks/$name.tier"
  done 3< <(tr -d '\r' < "$file")
  if [ $append = 1 ]; then shared_add "$own"; else shared_start "$own"; fi
  echo "OK $((n-waited)) tasks split$([ $waited = 0 ] || echo ", $waited waiting"). Start now, in the background: warmd watch"
}

team_escalate() {
  need_git
  local name="${1:-}" f="$STATE/tasks/${1:-}.md" tier next area
  [ -f "$f" ] || { echo "warmd escalate <name>: unknown task"; return 2; }
  tier="$(apply_floor "$(cat "$STATE/tasks/$name.tier" 2>/dev/null || echo mid)")"; next="$(tier_next "$tier")"
  [ -n "$next" ] || { echo "FAIL $name is at the top tier, this one needs a human"; return 1; }
  next="$(apply_floor "$next")"
  area="$(area_of "$(sed -n 's/^Files you own: //p' "$f")")"
  printf 'escalated\t%s\n' "$area" >> "$STATE/history.tsv"
  grep -q '^Earlier attempt' "$f" || echo "Earlier attempt failed. Read its commits on this branch first, then take a different approach." >> "$f"
  # The earlier commits as context: the next tier starts from what was tried, not from zero
  local log; log="$(git -C "$GIT_ROOT" log --format='%h %s' "$(base_branch)..warmd/$name" 2>/dev/null | head -8 | cut -c1-72 | awk 'NR>1{printf "; "}{printf "%s",$0}')"
  sed -i.bak '/^Earlier commits: /d' "$f"; rm -f "$f.bak"
  [ -n "$log" ] && echo "Earlier commits: $log" >> "$f"
  echo "$next" > "$STATE/tasks/$name.tier"
  sed -i.bak "s/^Budget: .*/Budget: under $(tier_budget "$next")k tokens./; s/^Time budget: [0-9]* min/Time budget: $(tier_minutes "$next") min/" "$f"; rm -f "$f.bak"
  local role model; role="$(cat "$STATE/tasks/$name.role" 2>/dev/null)"; [ "$role" = qa ] || role=worker
  model="$(task_model "$next" "$role")"; printf '%s\n' "$model" > "$STATE/tasks/$name.model"; date +%s > "$STATE/tasks/$name.start"   # the next tier's clock starts now
  if grep -q '^Review: ' "$f"; then
    sed -i.bak '/^Review: /d' "$f"; rm -f "$f.bak"
    review_line "$model" >> "$f"
  fi
  handoff_register "$name" "$(native_path "$f")" "$next"   # a later handoff or restart starts the new tier, not the old one
  local wt; wt="$(sed -n '1s/.*cd "\([^"]*\)".*/\1/p' "$f")"
  echo "AGENT $name: subagent_type=$(task_agent "$next" "$f") model=$model prompt=\"Read $(native_path "$f") and do it.$(agent_state "$wt")\""
}

# For the prompt of a next agent on a running task: where the branch stands, and that the old agent must be stopped first.
agent_state() { # worktree [base]
  local wt="$1" base="${2:-}" br sha ahead dirty
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  br="$(git -C "$wt" branch --show-current 2>/dev/null)"; [ -n "$br" ] || return 0
  [ -n "$base" ] || base="$(base_branch)"
  sha="$(git -C "$wt" rev-parse --short HEAD 2>/dev/null)"; ahead="$(git -C "$wt" rev-list --count "$base..HEAD" 2>/dev/null || echo '?')"
  dirty="$(wt_work "$wt" | wc -l | tr -d ' ')"
  printf ' State: %s at %s, %s ahead of %s, %s uncommitted. Stop the previous agent of this task first, never two in one worktree.' "$br" "$sha" "$ahead" "$base" "$dirty"
}

# The last line of every agent: facts from git and the last run, not prose.
team_finish() {
  need_git
  local br sha ahead dirty up last base
  br="$(git -C "$GIT_ROOT" branch --show-current)"; base="$(base_branch)"
  # The end of a task belongs to its worktree: in the base checkout finish would record the base as the task and push it
  if [ -z "$br" ] || [ "$br" = "$base" ]; then
    echo "FAIL warmd finish runs in the base checkout (${br:-detached}), nothing recorded, nothing pushed. Run it in your task worktree: the cd in the first line of your task file"
    return 2
  fi
  shared_guard   # the main checkout during a batch: the agent's shell went back there, the end belongs to its worktree
  ledger_finish "$@" || return $?
  # DONE with an outcome other than failed or escalated: the task waits for the merge. No stop may escalate or restart it.
  case " $* " in *" --outcome failed "*|*" --outcome escalated "*) ;; *) local fb; fb="$(git -C "$GIT_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/warmd-auto/done"; mkdir -p "$fb" && : > "$fb/${br#warmd/}";; esac
  finish_stop_runs
  git -C "$GIT_ROOT" remote get-url origin >/dev/null 2>&1 && finish_base_sync "$base"
  sha="$(git -C "$GIT_ROOT" rev-parse --short HEAD)"
  ahead="$(git -C "$GIT_ROOT" rev-list --count "$(base_branch)..HEAD" 2>/dev/null || echo '?')"
  dirty="$(wt_work "$GIT_ROOT" | wc -l | tr -d ' ')"   # new files count too: work never added is lost at the merge
  if git -C "$GIT_ROOT" remote get-url origin >/dev/null 2>&1; then git -C "$GIT_ROOT" push -q -u origin "$br" 2>/dev/null && up=pushed || up=NOT_pushed; else up=local; fi
  # The open PR of the branch conflicts (main moved after a ship): GitHub runs no CI for it, say so now (lib/ship.sh)
  [ "$up" = pushed ] && command -v gh >/dev/null 2>&1 && type ci_conflict >/dev/null 2>&1 && ci_conflict "$br"
  last="$(sed -n '2p' "$RUN/result.txt" 2>/dev/null | tr -d '\r' | cut -c1-70)"
  # finish is the task's own "done": mark it finished in the batch, also when its agent was stopped and no stop hook ran,
  # so the next split frees its files once it is merged
  local common; common="$(git -C "$GIT_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [ -f "$common/warmd-batch" ] && ! wt_finished "$common" "$GIT_ROOT"; then printf '%s\t%s\t%s\n' "$GIT_ROOT" ok "$br" >> "$common/warmd-batch-done"; fi
  local over=""; task_over "${br#warmd/}" "$(ledger_taskdir)" && over=", OVER time budget: $REPLY"
  type brake_batch_line >/dev/null 2>&1 && brake_batch_line "${br#warmd/}"
  echo "DONE $br $sha, $ahead ahead, $dirty uncommitted, $up${last:+, last run: $last}$over"
}


# Before the push: a PR that conflicts with its base gets no CI run at all, and agents waited minutes for checks that
# never start. A clean merge of origin/<base> is made here (clean tree only), a conflict is named at once.
finish_base_sync() { # base
  local ob="origin/$1" rc
  git -C "$GIT_ROOT" fetch -q origin "$1" 2>/dev/null || return 0
  git -C "$GIT_ROOT" rev-parse -q --verify "$ob" >/dev/null || return 0
  git -C "$GIT_ROOT" merge-base --is-ancestor "$ob" HEAD 2>/dev/null && return 0
  git -C "$GIT_ROOT" merge-tree --write-tree HEAD "$ob" >/dev/null 2>&1; rc=$?
  if [ $rc = 1 ]; then
    echo "CONFLICT with $1: CI will not run on the PR. Merge $ob, resolve, commit, then warmd finish again"
  elif [ $rc = 0 ] && [ -z "$(git -C "$GIT_ROOT" status --porcelain --untracked-files=no)" ]; then
    git -C "$GIT_ROOT" merge -q --no-edit "$ob" >/dev/null 2>&1 && echo "(merged $ob first, it merged clean: the PR stays mergeable)"
  fi
  return 0
}

# The agent ends: a warmd run it left in this worktree (a background test) holds a slot for nobody. It is ended, its slot
# freed at once (a killed shell may not run its exit trap), and the engine stopped so the test stops too.
finish_stop_runs() {
  local f pid w c d p n=0
  for f in "$STATE"/run/active/*; do
    [ -f "$f" ] || continue
    pid="${f##*/}"; [ "$pid" = "$$" ] && continue
    shell_alive "$pid" || { rm -f "$f"; continue; }
    w=""; c=""; read -r w c < "$f" 2>/dev/null
    kill "$pid" 2>/dev/null; rm -f "$f"; n=$((n + 1))
    for d in "$CACHE_ROOT"/slots/*/; do p=""; read -r p < "$d/pid" 2>/dev/null; [ "$p" = "$pid" ] && rm -rf "${d%/}"; done
    echo "(stopped warmd ${c:-run} pid $pid that was still running here, its slot is free)"
  done
  [ $n = 0 ] || a_stop >/dev/null 2>&1
  return 0
}

team_board() {
  need_git
  local base path br age dirty ahead ct
  base="$(base_branch)"
  printf '%-26s %-22s %6s %6s %6s\n' worktree branch age dirty ahead
  # Every worktree gets a row: a detached one shows (detached), one whose folder is gone says how to drop it.
  # dirty counts new files too, an agent that never ran git add still has work to lose.
  git -C "$GIT_ROOT" worktree list --porcelain | tr -d '\r' | awk '
    function row() { if (p != "") print p "|" b; p = "" }
    /^worktree / { row(); p = substr($0, 10); b = "(detached)" }
    /^branch / { b = $2; sub("refs/heads/", "", b) }
    /^bare$/ { p = "" }
    END { row() }' | while IFS='|' read -r path br; do
    if ! ct="$(git -C "$path" log -1 --format=%ct 2>/dev/null)" || [ -z "$ct" ]; then
      printf '%-26s %-22s %s\n' "$(basename "$path" | cut -c1-26)" "$(echo "$br" | cut -c1-22)" "folder missing, drop it: git worktree prune"; continue
    fi
    age=$(( ($(date +%s) - ct) / 60 ))
    dirty="$(wt_work "$path" | wc -l | tr -d ' ')"
    ahead="$(git -C "$path" rev-list --count "$base..HEAD" 2>/dev/null || echo '?')"
    printf '%-26s %-22s %5sm %6s %6s\n' "$(basename "$path" | cut -c1-26)" "$(echo "$br" | cut -c1-22)" "$age" "$dirty" "$ahead"
  done
}

# Why a run went red, in one line: the summary plus the FAIL lines that name the failing tests.
# Without such lines: the first or last 3 lines of the output.
red_lines() { # output head|tail
  local names sum
  names="$(printf '%s\n' "$1" | grep -E '^[[:space:]]*(FAIL|FAILED|not ok|Failed:?|✗|×)[[:space:]]' | sed 's/^[[:space:]]*//' | head -5 | cut -c1-120 | awk 'NR>1{printf " | "}{printf "%s",$0}')"
  sum="$(printf '%s\n' "$1" | grep -E '[0-9]+ (failed|failing|failures?)' | tail -1 | sed 's/^[[:space:]]*//' | cut -c1-60)"
  if [ -n "$names" ]; then echo "${sum:+$sum: }$names" | cut -c1-600
  else printf '%s\n' "$1" | "${2:-tail}" -3 | tr '\n' ' ' | cut -c1-200; fi
}

# The rollback of a red or conflicting merge: back to $1, the HEAD this merge started from, only while HEAD is still $2, the
# last commit this merge made. Nothing is touched (REPLY says why) when someone committed meanwhile, when the rollback
# would leave the base behind its upstream (a commit of the merge was pushed), or when a local change sits in a file the
# merge changed. reset --keep, never --hard: an edit made during the gate in any other file stays.
merge_rollback() { # start, last commit of this merge
  local head up cur
  head="$(git -C "$GIT_ROOT" rev-parse -q --verify HEAD 2>/dev/null)"; cur="$(git -C "$GIT_ROOT" branch --show-current)"
  [ "$head" = "$1" ] && return 0
  [ "$head" = "$2" ] || { REPLY="$cur moved to $(git -C "$GIT_ROOT" rev-parse --short HEAD) during the merge (a commit made meanwhile), it stays as it is: revert the merge by hand if it must go"; return 1; }
  up="$(git -C "$GIT_ROOT" rev-parse -q --verify '@{upstream}' 2>/dev/null || git -C "$GIT_ROOT" rev-parse -q --verify "refs/remotes/origin/$cur" 2>/dev/null)"
  if [ -n "$up" ] && git -C "$GIT_ROOT" merge-base --is-ancestor "$up" "$head" 2>/dev/null && ! git -C "$GIT_ROOT" merge-base --is-ancestor "$up" "$1" 2>/dev/null; then
    REPLY="its upstream already has commits of this merge, a rollback would leave $cur behind it: revert the merge by hand if it must go"; return 1
  fi
  git -C "$GIT_ROOT" reset -q --keep "$1" 2>/dev/null || { REPLY="local changes in files the merge changed, nothing reset: revert the merge by hand if it must go"; return 1; }
}

# merge <branch>: only into the base branch, only from a clean tree, then the fastest checks. Red rolls back.
# warmd merge <branch>... [--no-gate]: every branch merged one after the other (one commit each), then ONE gate over all of
# them and one player build, not one per branch. Red rolls every branch of the call back. A conflict stops at its branch:
# resolve it, warmd merge --continue merges the branches after it. --no-gate is for an integration the user released.
gate_script() { (cd "$PROJECT" && WARMD_BIN="bash $WARMD_HOME/bin/warmd" sh -c "$CFG_gate" 2>&1); }
# Wait until no other heavy warmd run on this machine holds a slot, at most gate_quiet_wait seconds (default 300).
gate_quiet() {
  local d p n t0; t0="$(date +%s)"
  while :; do
    n=0
    for d in "$CACHE_ROOT"/slots/*/; do
      [ -d "$d" ] || continue; p=""; read -r p < "$d/pid" 2>/dev/null
      [ -n "$p" ] && [ "$p" != "$$" ] && shell_alive "$p" && n=$((n + 1))
    done
    [ $n = 0 ] && return 0
    [ $(( $(date +%s) - t0 )) -ge "${CFG_gate_quiet_wait:-300}" ] && { echo "(still $n other heavy runs after ${CFG_gate_quiet_wait:-300}s, the gate runs anyway)"; return 0; }
    nap "${WARMD_QUEUE_POLL:-5}"
  done
}
merge_lock() {
  MERGELOCK="$STATE/merge.owner"; echo "$$" > "$MERGELOCK"
  # Windows pid next to it: a merge launched through WMI is not always visible to kill -0 of other shells
  if [ -r "/proc/$$/winpid" ]; then cat "/proc/$$/winpid" > "$MERGELOCK.win"; else rm -f "$MERGELOCK.win"; fi
}
# A split during a merge made its worktrees on the state before it, and agents found their predecessor "not on main".
# split waits for a running merge of this project, at most merge_wait seconds (default 900), then goes on with a WARN.
merge_wait() {
  local f="$STATE/merge.owner" owner w t0 said=0
  t0="$(date +%s)"
  while [ -f "$f" ]; do
    owner="$(cat "$f" 2>/dev/null)"; w="$(cat "$f.win" 2>/dev/null)"
    [ "$owner" = "$$" ] && return 0
    shell_alive "$owner" || { [ -n "$w" ] && pid_alive "$w"; } || return 0
    if [ $(( $(date +%s) - t0 )) -ge "${CFG_merge_wait:-900}" ]; then
      echo "WARN a merge still runs after ${CFG_merge_wait:-900}s (pid $owner): worktrees start on the state before it"; return 1
    fi
    [ $said = 1 ] || { echo "(a merge runs in this project, pid $owner: split waits for it, worktrees start on its result)"; said=1; }
    nap "${WARMD_MERGE_POLL:-5}"
  done
  [ $said = 0 ] || echo "(merge done after $(( $(date +%s) - t0 ))s)"
  return 0
}

team_merge() {
  need_git
  local base out m br start="" mine="" nogate=0 cont=0 brs=() merged=() new=() q="$STATE/merge.queue" i rest
  for m in "$@"; do case "$m" in --no-gate) nogate=1;; --continue) cont=1;; -*) echo "FAIL unknown option $m"; return 2;; *) brs+=("$m");; esac; done
  [ $cont = 1 ] || [ ${#brs[@]} -gt 0 ] || { echo "warmd merge <branch>... [--no-gate], after a resolved conflict: warmd merge --continue"; return 2; }
  base="$(base_branch)"
  [ "$(git -C "$GIT_ROOT" branch --show-current)" = "$base" ] || { echo "FAIL merge only from a checkout of $base"; return 2; }
  if [ $cont = 1 ]; then
    br="$(git -C "$GIT_ROOT" name-rev --name-only MERGE_HEAD 2>/dev/null)" || { echo "FAIL no merge open"; return 2; }
    [ -z "$(git -C "$GIT_ROOT" diff --name-only --diff-filter=U)" ] || { echo "FAIL still unresolved:"; git -C "$GIT_ROOT" diff --name-only --diff-filter=U | head -8; return 1; }
    # A merge of several branches stopped here: its start, its gate choice and the branches after this one
    brs=(); if [ -f "$q" ]; then { read -r start; read -r m; read -r rest; read -r i; } < "$q"; [ "$m" = 1 ] && nogate=1; read -ra brs <<< "$rest"; read -ra merged <<< "$i"; fi
    [ -n "$start" ] || start="$(git -C "$GIT_ROOT" rev-parse HEAD)"
    git -C "$GIT_ROOT" add -u && git -C "$GIT_ROOT" commit -q --no-edit -m "Merge $br" ${WARMD_TRAILER:+-m "$WARMD_TRAILER"} || { echo "FAIL cannot commit the resolved merge of $br"; return 1; }
    merged+=("$br"); rm -f "$q"
  else
    for br in "${brs[@]}"; do git -C "$GIT_ROOT" rev-parse --verify -q "$br" >/dev/null || { echo "FAIL unknown branch $br, nothing done"; return 2; }; done
    # A branch already in HEAD holds nothing new: skipped before anything in the checkout is touched
    for br in "${brs[@]}"; do
      if git -C "$GIT_ROOT" merge-base --is-ancestor "$br" HEAD 2>/dev/null; then echo "SKIP $br: nothing new"; else new+=("$br"); fi
    done
    [ ${#new[@]} -gt 0 ] || { echo "OK nothing to merge"; return 0; }
    brs=("${new[@]}")
    git -C "$GIT_ROOT" status --porcelain -uno | grep -qE '\.sln[x]?$' && git -C "$GIT_ROOT" checkout -q -- '*.sln*' 2>/dev/null
    # The daemon copy warmd renewed (unity_sync) is no one's work in progress: the merge commit takes it along
    [ -z "$(git -C "$GIT_ROOT" status --porcelain -uno | grep -vE 'Assets/Editor/Warmd/|^ M .*\.uid$')" ] || { echo "FAIL uncommitted changes, nothing done"; return 2; }
    start="$(git -C "$GIT_ROOT" rev-parse HEAD)"
  fi
  mine="$(git -C "$GIT_ROOT" rev-parse HEAD)"
  # The lock holds from the first git merge on: a split meanwhile waits for it (merge_wait), its worktrees start on the result
  merge_lock
  for i in "${!brs[@]}"; do
    br="${brs[$i]}"
    merge_clear_byproducts "$br"
    out="$(git -C "$GIT_ROOT" merge --no-ff -m "Merge $br" ${WARMD_TRAILER:+-m "$WARMD_TRAILER"} "$br" 2>&1)" ||
      # Parallel branches that each add an entry to the same one-line list of project.godot: joined, the merge goes on
      { git -C "$GIT_ROOT" rev-parse -q --verify MERGE_HEAD >/dev/null && merge_godot_lists "$br" && echo "$REPLY"; } || {
      if [ "${WARMD_MERGE_ATOMIC:-0}" != 1 ] && git -C "$GIT_ROOT" rev-parse -q --verify MERGE_HEAD >/dev/null; then
        printf '%s\n%s\n%s\n%s\n' "$start" "$nogate" "${brs[*]:$((i+1))}" "${merged[*]}" > "$q"
        echo "FAIL conflict in $(echo "$out" | grep -c CONFLICT) files of $br${merged[0]:+ (merged before it: ${merged[*]})}, resolve them and run warmd merge --continue"; echo "$out" | grep CONFLICT | head -8 | cut -c1-160
      else
        # WARMD_MERGE_ATOMIC=1 (the batch merge of the hooks): a conflict rolls back all, nobody is there to resolve it
        git -C "$GIT_ROOT" rev-parse -q --verify MERGE_HEAD >/dev/null && git -C "$GIT_ROOT" merge --abort 2>/dev/null
        m="$(echo "$out" | grep -m1 -E 'CONFLICT|error|fatal' | cut -c1-160)"
        # "untracked working tree files would be overwritten": the header alone says nothing, name the files
        local fl; fl="$(echo "$out" | grep -E '^[[:space:]]+[^[:space:]]' | grep -vE '^[[:space:]]*(Please|Aborting)' | sed 's/^[[:space:]]*//' | head -5 | tr '
' ' ')"
        [ -z "$fl" ] || m="${m%:}: ${fl% }"
        merge_rollback "$start" "$mine" || { echo "FAIL merge $br: $m, not rolled back: $REPLY"; return 3; }
        role_learn "$br" "$m"
        echo "FAIL merge $br: $m, nothing merged"
      fi
      return 1; }
    mine="$(git -C "$GIT_ROOT" rev-parse HEAD)"
    echo "$out" | grep -q "Already up to date" && continue
    merged+=("$br")
  done
  [ ${#merged[@]} -gt 0 ] || { echo "OK nothing to merge"; return 0; }
  export WARMD_IN_MERGE=1
  br="${merged[*]}"; export WARMD_DIFF_BASE="$start"
  # Red rolls back to the start of this merge, never further and never over a commit made meanwhile (merge_rollback).
  # Not rolled back: exit 3, the caller stops merging on top of it.
  mfail() {
    merge_rollback "$start" "$mine" || { echo "FAIL merge $br: $*; not rolled back: $REPLY"; return 3; }
    local b; for b in "${merged[@]}"; do role_learn "$b" "$*"; done   # each rolled-back task leaves one rule line in its role file
    local left; left="$(git -C "$GIT_ROOT" status --porcelain -uno | grep -vE '^ M .*\.uid$' | cut -c4- | head -5 | tr '\n' ' ')"
    echo "FAIL merge $br: $*${left:+; kept uncommitted (written by the gate or by someone meanwhile): ${left% }}"; return 1
  }
  m="$(git -C "$GIT_ROOT" -c core.whitespace=-trailing-space,-space-before-tab,-blank-at-eof,-blank-at-eol diff --check "$start" HEAD 2>&1 | head -3 | cut -c1-160)"; [ -z "$m" ] || { mfail "$m"; return; }
  # A class_name the merge brought is unknown to the checkout's class cache: every script naming it is a parse error in
  # a gate= script that starts the engine itself. The import runs first (a gate without it rolled a branch with a new class back).
  if [ $nogate = 0 ] && [ "$(type -t class_cache_drift)" = function ] && [ -n "$(class_cache_drift)" ]; then
    echo "(class_name new to the class cache: imported before the gate)"; refresh_classes force
  fi
  if [ $nogate = 1 ]; then :
  elif [ -n "$CFG_gate" ]; then
    if ! m="$(gate_script)"; then
      # warmd cannot tell which changed file a gate= script reaches: a red gate runs once more, alone (gate_retry=0: never).
      # A load-sensitive test went red while other agents loaded the machine and rolled back a merge it had nothing to do with.
      local red1; red1="$(red_lines "$m" tail)"
      # Not after a commit made during the gate: that HEAD is someone's, the rollback decides alone (merge_rollback)
      { [ "${CFG_gate_retry:-1}" -ge 1 ] 2>/dev/null && [ "$(git -C "$GIT_ROOT" rev-parse HEAD)" = "$mine" ]; } || { mfail "$red1"; return; }
      echo "(gate red: ${red1:0:160}; once more alone, warmd cannot tell what a gate= script reaches)"
      gate_quiet
      if ! m="$(gate_script)"; then mfail "$(red_lines "$m" tail)"; return; fi
      echo "WARN gate red only under load: green when run alone, red before: ${red1:0:200}"
    fi
  elif ! m="$(run_check 2>&1)"; then mfail "$(red_lines "$m" head)"; return; fi
  if [ $nogate = 0 ] && [ -n "$CFG_perf" ]; then m="$(perf_run 2>&1)" || { mfail "$(echo "$m" | tail -2 | tr '\n' ' ' | cut -c1-200)"; return; }; fi
  # mutate=merge in warmd.conf: every changed line of this merge must have a test that notices a flipped operator (lib/mutate.sh)
  if [ $nogate = 0 ] && [ "${CFG_mutate:-}" = merge ] && type mutate_gate >/dev/null 2>&1; then
    m="$(WARMD_DIFF_BASE="$start" mutate_gate 2>&1)" || { mfail "mutation gate: $(echo "$m" | tail -3 | tr '\n' ' ' | cut -c1-200)"; return; }
    echo "$m" | tail -1
  fi
  # What the gate wrote (world outputs, the renewed daemon copy, .uid) goes into the last merge commit, only into this
  # merge's own commit: a commit made meanwhile is never amended. Any other change in the checkout was made by someone
  # meanwhile: it stays uncommitted and is named, never taken into the merge commit.
  if [ -n "$(git -C "$GIT_ROOT" status --porcelain -uno)" ] && [ "$(git -C "$GIT_ROOT" rev-parse HEAD)" = "$mine" ]; then
    local f own=() foreign=() wo; wo=" ${CFG_world_outputs//,/ } "
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$f" in Assets/Editor/Warmd/*|*.uid) own+=("$f"); continue;; esac
      for m in $wo; do case "$f" in "$m"|"$m"/*) own+=("$f"); continue 2;; esac; done
      foreign+=("$f")
    done < <(git -C "$GIT_ROOT" diff --name-only HEAD)
    if [ ${#own[@]} -gt 0 ]; then
      git -C "$GIT_ROOT" add -u -- "${own[@]}" && git -C "$GIT_ROOT" commit -q --amend --no-edit || { mfail "cannot commit what the gate wrote"; return; }
    fi
    [ ${#foreign[@]} -eq 0 ] || echo "WARN not in the merge commit, changed in the checkout meanwhile and left uncommitted: ${foreign[*]:0:5}"
  fi
  echo "OK $(secs)s merged $br as $(git -C "$GIT_ROOT" rev-parse --short HEAD)$([ $nogate = 1 ] && echo ", no gate (--no-gate)"), not pushed"
  rm -f "$MERGELOCK" "$MERGELOCK.win"; unset WARMD_IN_MERGE WARMD_DIFF_BASE
  merge_package
  disk_after_merge
  return 0
}

# After a merge: the one player of the project, fresh, built in the background so the merge returns at once. The batch
# merge of the hooks builds it itself after all branches (WARMD_NO_PACKAGE=1). Without package_dir it says so, loudly.
merge_package() {
  [ "${WARMD_NO_PACKAGE:-0}" = 1 ] && return 0
  package_state || { [ -z "$REPLY" ] || echo "$REPLY"; return 0; }
  local common log; common="$(git -C "$GIT_ROOT" rev-parse --path-format=absolute --git-common-dir)"; log="$common/warmd-package.log"
  . "$WARMD_HOME/lib/hook.sh"
  hook_detach "$log" "$GIT_ROOT" hook-package "$(base_branch)"
  echo "OK player build started in the background into $(native_path "$PACKAGE_DIR"), log $(native_path "$log")"
}

. "$WARMD_HOME/lib/auto.sh"
