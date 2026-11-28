# Disk: every worktree of a split gets its own copy of the engine cache (a Unity Library is often 4 GB). Three copies can
# fill a disk, and then merges die with "unable to write file". So warmd checks the free space before it copies a cache or
# starts a heavy run, and frees the caches of finished worktrees after a merge. The cache is only a cache: the next split
# that reuses the worktree copies it again (one robocopy), nothing of the work is lost.
# warmd.conf: disk_min_mb (default 4096) stays free; disk_reclaim=0 keeps every cache.

# REPLY = the engine cache folder of this adapter, 1 when it has none worth counting
disk_cache_name() { case "${ADAPTER:-}" in unity) REPLY=Library;; godot) REPLY=.godot;; *) REPLY=""; return 1;; esac; }
disk_min_kb() { local m="${WARMD_DISK_MIN_MB:-${CFG_disk_min_mb:-4096}}"; [ "$m" -ge 0 ] 2>/dev/null || m=4096; REPLY=$((m * 1024)); }
# REPLY = free KB on the volume of <dir>, empty when df cannot tell. One df.
disk_free_kb() {
  REPLY=""; local fs blocks used avail
  { read -r _; read -r fs blocks used avail _; } < <(df -Pk "$1" 2>/dev/null)
  [[ $avail =~ ^[0-9]+$ ]] && REPLY="$avail"
}
# DISK_GB = <KB> as GB with one decimal
disk_gb() { DISK_GB="$(( $1 / 1048576 )).$(( ($1 % 1048576) * 10 / 1048576 ))"; }
# REPLY = KB of the cache of <project>. du over 100k files takes seconds: measured once per 6 hours, kept in .warmd/cache.kb.
disk_cache_kb() {
  local c f="$1/.warmd/cache.kb" k="" t="" now
  disk_cache_name || { REPLY=0; return 1; }
  c="$1/$REPLY"; REPLY=0
  [ -d "$c" ] || return 0
  printf -v now '%(%s)T' -1
  { read -r k t < "$f"; } 2>/dev/null
  if ! [[ $k =~ ^[0-9]+$ && $t =~ ^[0-9]+$ ]] || [ $(( now - t )) -gt 21600 ]; then
    k="$(du -sk "$c" 2>/dev/null)"; k="${k%%[[:space:]]*}"; [[ $k =~ ^[0-9]+$ ]] || k=0
    { mkdir -p "$1/.warmd" && echo "$k $now" > "$f"; } 2>/dev/null
  fi
  REPLY="$k"
}
# disk_room <source project> <copies> <dir>: 0 when <dir>'s volume holds <copies> caches of the source plus disk_min_mb.
# REPLY = the shortfall as one sentence otherwise.
disk_room() {
  local min cache need have name
  disk_cache_name || return 0; name="$REPLY"
  disk_min_kb; min="$REPLY"; disk_cache_kb "$1"; cache="$REPLY"; need=$(( ${2:-0} * cache + min ))
  disk_free_kb "$3"; have="$REPLY"; [ -n "$have" ] || return 0
  [ "$have" -ge "$need" ] && return 0
  local h n c m; disk_gb "$have"; h="$DISK_GB"; disk_gb "$need"; n="$DISK_GB"; disk_gb "$cache"; c="$DISK_GB"; disk_gb "$min"; m="$DISK_GB"
  REPLY="$h GB free on $(native_path "$3"), needed $n GB (${2:-0} x $c GB $name plus $m GB disk_min_mb)"
  return 1
}

# Build folders other stacks fill in every worktree (a Rust target/ with Tauri reached 7 GB, ten worktrees filled C:).
# Freed only when git ignores them, in the worktree, the project folder and one level below either.
DISK_BUILD_DIRS="target node_modules dist"
# disk_dirs <worktree> <project folder relative to it>: REPLY = its cache folders, one per line: the engine cache and
# the ignored build folders. One check-ignore for all build folders.
disk_dirs() {
  local c x r l="" b=()
  disk_cache_name && [ -d "$1${2:+/$2}/$REPLY" ] && l="$1${2:+/$2}/$REPLY"$'\n'
  for x in ${2:+"$2/"} ""; do
    for c in $DISK_BUILD_DIRS; do
      [ -d "$1/$x$c" ] && b+=("$x$c")
      for r in "$1/$x"*/"$c"; do [ -d "$r" ] && b+=("${r#"$1/"}"); done
    done
  done
  if [ ${#b[@]} -gt 0 ]; then
    while IFS= read -r r; do r="${r%$'\r'}"; r="${r%/}"; [ -n "$r" ] && [[ $l != *"$1/$r"$'\n'* ]] && l="$l$1/$r"$'\n'; done < <(git -C "$1" check-ignore -- "${b[@]}" 2>/dev/null)
  fi
  REPLY="${l%$'\n'}"
}
# disk_clean <worktree>: 0 when it holds nothing of its own, untracked files included. Files the engine or warmd write
# by themselves are no work: *.uid, *.import, *.translation, .godot/, override.cfg, .warmd/, .sln files, Assets/Editor/Warmd/.
disk_clean() {
  [ -z "$(GIT_OPTIONAL_LOCKS=0 git -C "$1" status --porcelain -uall 2>/dev/null | tr -d '\r' |
    grep -vE '^.. (.*/)?\.(godot|warmd)/|\.(uid|import|translation)"?$|^.. (.*/)?override\.cfg"?$|\.slnx?"?$|Assets/Editor/Warmd/')" ]
}

# disk_reclaim [--list | --all]: frees the caches of every worktree whose work is done: HEAD already in the base branch,
# nothing uncommitted, not in the running batch, no engine there (Temp/UnityLockfile, the daemon's heartbeat, a warmd run).
# A worktree without work of its own (HEAD on the base's first-parent line: just made, or reset to base) also needs 30
# quiet minutes without checkout, commit, index write or import (WARMD_RECLAIM_IDLE_MIN): an agent may be about to start
# there. Never the main checkout, a checkout of the base branch or the current one. REPLY = how many were freed (--list:
# could be), DISK_FREED = their project folders.
# --all is warmd disk --free: 255 old worktrees (199 merged, 53 GB) gave nothing back, the old rule wanted each one
# finished and in the batch's sight. Now every worktree that is not an open task of the running batch, holds no engine,
# is not locked and was quiet for those 30 minutes: merged and nothing of its own (disk_clean) is removed with git
# worktree remove --force, any other gives its caches back. DISK_REMOVED and DISK_CLEARED count them, DISK_KB = KB freed.
disk_reclaim() {
  local mode=merge c="" p br h lk d base rel batch common ref main="" n=0 a g fp dirs x ok quiet fin kb0="" kb1
  case "${1:-}" in --list) mode=list;; --all) mode=all;; esac
  DISK_FREED=""; DISK_REMOVED=0; DISK_CLEARED=0; DISK_KB=0; REPLY=0
  [ -n "$GIT_ROOT" ] || return 0
  disk_cache_name && c="$REPLY"
  REPLY=0
  [ "${CFG_disk_reclaim:-1}" = 0 ] && return 0
  base="$(base_branch)"; rel="$(rel_project)"
  common="$(git -C "$GIT_ROOT" rev-parse --path-format=absolute --git-common-dir)"; batch="$common/warmd-batch"
  fp=" $(git -C "$GIT_ROOT" rev-list --first-parent --max-count=5000 "$base" 2>/dev/null | tr '\n' ' ') "
  # Every commit of the base in one call: "HEAD in base" without a merge-base process per worktree
  local -A inbase=(); while IFS= read -r x; do inbase[$x]=1; done < <(git -C "$GIT_ROOT" rev-list "$base" 2>/dev/null)
  local inbatch=(); [ -f "$batch" ] && mapfile -t inbatch < <(tr -d '\r' < "$batch")
  ref="$STATE/run/reclaim.ref"; mkdir -p "$STATE/run"; touch -d "-${WARMD_RECLAIM_IDLE_MIN:-30} min" "$ref" 2>/dev/null || return 0
  [ $mode = all ] && { disk_free_kb "$GIT_ROOT"; kb0="$REPLY"; }
  while IFS='|' read -r p br h lk; do
    [ -n "$main" ] || { main="$p"; continue; }   # git lists the main checkout first
    [ -n "$p" ] && [ "$br" != "$base" ] && [ -d "$p" ] || continue
    [ "$p" -ef "$GIT_ROOT" ] && continue
    # -ef: the marker may spell the folder as /tmp/x, /c/Users/.../x or C:/Users/.../x. --all: a finished task is no open one
    a=0; for g in "${inbatch[@]}"; do [ "$g" -ef "$p" ] && { a=1; break; }; done
    if [ $a = 1 ]; then [ $mode = all ] && declare -F wt_finished >/dev/null && wt_finished "$common" "$p" || continue; fi
    [ $mode = all ] && [ -n "$lk" ] && continue   # locked on purpose
    d="$p${rel:+/$rel}"
    [ -e "$d/Temp/UnityLockfile" ] && continue
    a=""; { read -r a < "$d/.warmd/run/alive.txt"; } 2>/dev/null; a="${a%$'\r'}"
    [ -n "$a" ] && [ $(( $(now_ms) - a )) -lt 120000 ] 2>/dev/null && continue
    run_active "$d/.warmd" >/dev/null 2>&1 && continue
    [ $mode != all ] && [ -z "${inbase[$h]:-}" ] && continue
    # Quiet: no checkout or commit (the worktree's reflog), index write or import (the asset database) for 30 minutes
    quiet=1; g=""; { read -r _ g < "$p/.git"; } 2>/dev/null; g="${g%$'\r'}"
    [ -n "$g" ] && { [ "$g/logs/HEAD" -nt "$ref" ] || [ "$g/index" -nt "$ref" ]; } && quiet=0
    [ -n "$c" ] && [ "$d/$c/ArtifactDB" -nt "$ref" ] && quiet=0
    [ $quiet = 0 ] && [[ $fp == *" $h "* ]] && continue   # no work of its own and not quiet: an agent is about to start there
    # Finished: merged, nothing uncommitted. After a merge only these give caches back, --all also every quiet one
    fin=0; [ -n "${inbase[$h]:-}" ] && [ -z "$(GIT_OPTIONAL_LOCKS=0 git -C "$p" status --porcelain -uno 2>/dev/null | grep -vE '\.sln[x]?$|Assets/Editor/Warmd/')" ] && fin=1
    [ $fin = 1 ] || { [ $mode = all ] && [ $quiet = 1 ]; } || continue
    disk_dirs "$p" "$rel"; dirs="$REPLY"
    # Removed only when quiet: an agent may still commit on a branch that was merged a minute ago
    if [ $mode = all ] && [ $quiet = 1 ] && [ $fin = 1 ] && disk_clean "$p"; then
      # Caches first: the rename fails while an engine holds files open, and then the worktree stays
      ok=1; while IFS= read -r x; do [ -n "$x" ] && { disk_rm "$x" || { ok=0; break; }; }; done <<< "$dirs"
      [ $ok = 1 ] || continue
      if git -C "$GIT_ROOT" worktree remove --force "$p" >/dev/null 2>&1; then DISK_REMOVED=$((DISK_REMOVED + 1)); n=$((n + 1)); DISK_FREED="$DISK_FREED $d"; continue; fi
      [ -n "$dirs" ] || continue
      DISK_CLEARED=$((DISK_CLEARED + 1)); n=$((n + 1)); DISK_FREED="$DISK_FREED $d"; continue
    fi
    [ -n "$dirs" ] || continue
    if [ $mode != list ]; then
      ok=0; while IFS= read -r x; do [ -n "$x" ] && disk_rm "$x" && ok=1; done <<< "$dirs"
      [ $ok = 1 ] || continue
    fi
    n=$((n + 1)); DISK_FREED="$DISK_FREED $d"; [ $mode = all ] && DISK_CLEARED=$((DISK_CLEARED + 1))
  done < <(git -C "$GIT_ROOT" worktree list --porcelain 2>/dev/null | tr -d '\r' | awk '
    function out() { if (p != "") print p "|" b "|" h "|" l; p = "" }
    /^worktree / { out(); p = substr($0, 10); b = ""; h = ""; l = "" }
    /^HEAD / { h = $2 } /^branch / { b = $2; sub("refs/heads/", "", b) } /^locked/ { l = 1 }
    END { out() }')
  if [ -n "$kb0" ]; then disk_free_kb "$GIT_ROOT"; kb1="${REPLY:-0}"; [ "$kb1" -gt "$kb0" ] 2>/dev/null && DISK_KB=$((kb1 - kb0)); fi
  REPLY=$n
}
# disk_rm <folder>: renamed first (instant, and fails while an engine holds files open), then deleted. A half deleted
# cache never looks like a cache.
disk_rm() {
  local t="$1.warmd-free-$$"
  mv "$1" "$t" 2>/dev/null || return 1
  rm -rf "$t" 2>/dev/null
  return 0
}
# After a merge or at the end of a batch: one line when caches were freed, nothing otherwise
disk_after_merge() {
  disk_reclaim || return 0
  [ "$REPLY" -gt 0 ] 2>/dev/null || return 0
  local f; disk_free_kb "$GIT_ROOT"; f="${REPLY:-0}"; disk_gb "$f"
  echo "OK freed the $(disk_cache_name && echo "$REPLY" || echo build folders) of $(echo $DISK_FREED | wc -w | tr -d ' ') finished worktrees, $DISK_GB GB free"
}
# warmd disk --free: removes merged worktrees without work of their own, frees the caches of the others. One line.
disk_free_all() {
  disk_reclaim --all
  local g f; disk_gb "$DISK_KB"; g="$DISK_GB"; disk_free_kb "$GIT_ROOT"; f="${REPLY:-0}"; disk_gb "$f"
  echo "OK removed $DISK_REMOVED merged worktrees, freed the caches of $DISK_CLEARED others: $g GB freed, $DISK_GB GB free"
}
# Before a heavy run: below disk_min_mb the finished worktrees give their caches back first, still below it the run is
# refused. An engine on a full disk breaks its cache and every merge after it.
disk_guard() {
  disk_cache_name || return 0
  [ "${WARMD_NO_DISK_CHECK:-0}" = 1 ] && return 0
  disk_room "$PROJECT" 0 "$PROJECT" && return 0
  disk_reclaim
  disk_room "$PROJECT" 0 "$PROJECT" && { echo "(disk short: freed the caches of $(echo $DISK_FREED | wc -w | tr -d ' ') finished worktrees)"; return 0; }
  echo "FAIL disk full: $REPLY. Free space, or lower disk_min_mb in warmd.conf"; exit 1
}
disk_doctor() {
  disk_cache_name || return 0
  local name="$REPLY" n; disk_reclaim --list; n="$REPLY"
  if disk_room "$PROJECT" 1 "$PROJECT"; then disk_free_kb "$PROJECT"; disk_gb "${REPLY:-0}"; echo "ok disk: $DISK_GB GB free, room for one more $name copy"
  else echo "LOW disk: $REPLY"; fi
  [ "$n" -gt 0 ] && echo "note: $n finished worktrees hold a $name, the next merge frees them:$DISK_FREED"
  return 0
}
