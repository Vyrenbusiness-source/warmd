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

# disk_reclaim [--list]: frees the cache of every worktree whose work is done: HEAD already in the base branch, nothing
# uncommitted, not in the running batch, no engine there (Temp/UnityLockfile, the daemon's heartbeat, a warmd run). A
# worktree without work of its own (HEAD on the base's first-parent line: just made, or reset to base) also needs 30 quiet
# minutes without checkout, commit or import (WARMD_RECLAIM_IDLE_MIN): an agent may be about to start there. Never the
# main checkout, a checkout of the base branch or the current one. REPLY = how many were freed (--list: could be), DISK_FREED = their project folders.
disk_reclaim() {
  local list=0 c p br d base rel here batch ref main="" n=0 a g h fp;[ "${1:-}" = --list ] && list=1
  DISK_FREED=""
  [ -n "$GIT_ROOT" ] && disk_cache_name || { REPLY=0; return 0; }
  c="$REPLY"; REPLY=0
  [ "${CFG_disk_reclaim:-1}" = 0 ] && return 0
  base="$(base_branch)"; rel="$(rel_project)"; here="$(cd "$GIT_ROOT" && pwd)"
  batch="$(git -C "$GIT_ROOT" rev-parse --path-format=absolute --git-common-dir)/warmd-batch"
  fp=" $(git -C "$GIT_ROOT" rev-list --first-parent --max-count=5000 "$base" 2>/dev/null | tr '\n' ' ') "
  ref="$STATE/run/reclaim.ref"; mkdir -p "$STATE/run"; touch -d "-${WARMD_RECLAIM_IDLE_MIN:-30} min" "$ref" 2>/dev/null || return 0
  while IFS='|' read -r p br; do
    [ -n "$main" ] || { main="$p"; continue; }   # git lists the main checkout first
    [ -n "$p" ] && [ "$br" != "$base" ] || continue
    d="$p${rel:+/$rel}"
    [ -d "$d/$c" ] || continue
    [ "$(cd "$p" 2>/dev/null && pwd)" = "$here" ] && continue
    grep -qxF -e "$(cd "$p" && pwd)" -e "$p" "$batch" 2>/dev/null && continue
    [ -e "$d/Temp/UnityLockfile" ] && continue
    a=""; { read -r a < "$d/.warmd/run/alive.txt"; } 2>/dev/null; a="${a%$'\r'}"
    [ -n "$a" ] && [ $(( $(now_ms) - a )) -lt 120000 ] 2>/dev/null && continue
    run_active "$d/.warmd" >/dev/null 2>&1 && continue
    git -C "$p" merge-base --is-ancestor HEAD "$base" 2>/dev/null || continue
    h="$(git -C "$p" rev-parse HEAD 2>/dev/null)"
    if [[ $fp == *" $h "* ]]; then
      # No work of its own: a recent checkout or commit (the worktree's reflog) or import (the asset database) means someone starts there
      g=""; { read -r _ g < "$p/.git"; } 2>/dev/null; g="${g%$'\r'}"
      [ -n "$g" ] && [ "$g/logs/HEAD" -nt "$ref" ] && continue
      [ "$d/$c/ArtifactDB" -nt "$ref" ] && continue
    fi
    [ -z "$(git -C "$p" status --porcelain -uno 2>/dev/null | grep -vE '\.sln[x]?$|Assets/Editor/Warmd/')" ] || continue
    [ $list = 1 ] || disk_rm "$d/$c" || continue
    n=$((n + 1)); DISK_FREED="$DISK_FREED $d"
  done < <(git -C "$GIT_ROOT" worktree list --porcelain 2>/dev/null | tr -d '\r' | awk '/^worktree /{p=substr($0,10); b=""} /^branch /{b=$2; sub("refs/heads/","",b)} /^$/{if(p!="")print p"|"b; p=""} END{if(p!="")print p"|"b}')
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
  echo "OK freed the $(disk_cache_name; echo "$REPLY") of $(echo $DISK_FREED | wc -w | tr -d ' ') finished worktrees, $DISK_GB GB free"
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
