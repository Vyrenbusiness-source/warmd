# Machine tuning: cores and RAM read once, cached, turned into heavy slots and thread counts.
# warmd.conf always wins. Free memory is never checked, so it can never block a run.

# hw_read: print "<cores> <ram_mb>" from the system, no cache. Prefers files and env over spawning anything.
hw_read() {
  local cores="" kb="" bytes=""
  case "$OS" in
    mac)
      cores="$(sysctl -n hw.ncpu 2>/dev/null)"; bytes="$(sysctl -n hw.memsize 2>/dev/null)"
      [ -n "$bytes" ] && kb=$(( bytes / 1024 ));;
    *)
      cores="${NUMBER_OF_PROCESSORS:-}"
      [ -n "$cores" ] || cores="$(nproc 2>/dev/null)"
      kb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null)";;
  esac
  [ -n "$cores" ] || cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null)"
  if [ -z "$kb" ] && [ "$OS" = win ]; then # old shells without /proc: one powershell call, the result gets cached
    bytes="$(powershell.exe -NoProfile -Command "(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory" 2>/dev/null | tr -d '\r')"
    [ -n "$bytes" ] && kb=$(( bytes / 1024 ))
  fi
  case "$cores" in ''|*[!0-9]*) cores=4;; esac
  case "$kb" in ''|*[!0-9]*) kb=8388608;; esac
  echo "$cores $(( kb / 1024 ))"
}

# hw_gpu_read: print "<index>|<vram_mb>|<name>" of the GPU with the most VRAM, "0|0|none" without one. Real GPUs only, virtual adapters are skipped.
hw_gpu_read() {
  local best="" line idx name mem bestmem=-1 i=0 c
  case "$OS" in
    mac)
      name="$(system_profiler SPDisplaysDataType 2>/dev/null | sed -n 's/^ *Chipset Model: //p' | head -1)"
      mem="$(system_profiler SPDisplaysDataType 2>/dev/null | sed -n 's/^ *VRAM[^:]*: *\([0-9]*\) *GB.*/\1/p' | head -1)"
      if [ -n "$mem" ]; then mem=$(( mem * 1024 )); else mem=$(( $(hw_read | cut -d' ' -f2) / 2 )); fi   # Apple silicon shares RAM
      [ -n "$name" ] && best="0|$mem|$name";;
    *)
      if command -v nvidia-smi >/dev/null 2>&1; then
        while IFS=',' read -r idx name mem; do
          idx="${idx//[[:space:]]/}"; mem="${mem//[[:space:]]/}"; name="${name#"${name%%[![:space:]]*}"}"
          case "$mem" in ''|*[!0-9]*) continue;; esac
          if [ "$mem" -gt "$bestmem" ]; then bestmem=$mem; best="$idx|$mem|$name"; fi
        done < <(nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader,nounits 2>/dev/null | tr -d '\r')
      fi
      if [ -z "$best" ] && [ "$OS" = linux ]; then
        for c in /sys/class/drm/card[0-9]*/device/mem_info_vram_total; do
          [ -f "$c" ] || continue
          mem=$(( $(cat "$c") / 1048576 )); idx="${c#/sys/class/drm/card}"; idx="${idx%%/*}"
          name="$(cat "${c%/*}/product_name" 2>/dev/null)"; [ -n "$name" ] || name="AMD GPU"
          if [ "$mem" -gt "$bestmem" ]; then bestmem=$mem; best="$idx|$mem|$name"; fi
        done
      fi
      if [ -z "$best" ] && [ "$OS" = win ]; then   # wmic reports at most 4 GB per adapter
        while IFS= read -r line; do
          case "$line" in
            AdapterRAM=*) mem="${line#AdapterRAM=}"; mem=$(( ${mem:-0} / 1048576 ));;
            Name=*) name="${line#Name=}"
              case "$name" in *[Vv]irtual*|*Remote*|*Basic\ Render*) ;; *)
                if [ "$mem" -gt "$bestmem" ]; then bestmem=$mem; best="$i|$mem|$name"; fi; i=$((i+1));; esac;;
          esac
        done < <(wmic path win32_VideoController get AdapterRAM,Name //value 2>/dev/null | tr -d '\r')
      fi;;
  esac
  echo "${best:-0|0|none}"
}

# hw: cores and RAM in MB, cached for a day. WARMD_CORES and WARMD_RAM_MB override and skip the cache.
hw() {
  if [ -n "${WARMD_CORES:-}" ] && [ -n "${WARMD_RAM_MB:-}" ]; then echo "$WARMD_CORES $WARMD_RAM_MB"; return; fi
  local f="$CACHE_ROOT/hw" v c r
  if [ -f "$f" ] && [ -z "$(find "$f" -mmin +1440 2>/dev/null)" ]; then v="$(head -1 "$f")"; else
    v="$(hw_read)"; mkdir -p "$CACHE_ROOT"; { echo "$v"; hw_gpu_read; } > "$f.$$" && mv -f "$f.$$" "$f"
  fi
  c="${v% *}"; r="${v#* }"
  echo "${WARMD_CORES:-$c} ${WARMD_RAM_MB:-$r}"
}

# tune_slots: smaller of cores/4 and RAM/8GB, at least 1. warmd.conf slots= wins.
tune_slots() {
  if [ -n "${CFG_slots:-}" ]; then echo "$CFG_slots"; return; fi
  local v c r a b n; v="$(hw)"; c="${v% *}"; r="${v#* }"
  a=$(( c / 4 )); b=$(( r / 8192 ))
  n=$a; [ "$b" -lt "$n" ] && n=$b; [ "$n" -lt 1 ] && n=1
  echo "$n"
}

# tune_threads: build threads for one heavy run. At least 2 cores stay free for the user, the rest is shared by the slots. warmd.conf threads= wins.
tune_threads() {
  if [ -n "${CFG_threads:-}" ]; then echo "$CFG_threads"; return; fi
  local v c n; v="$(hw)"; c="${v% *}"
  n=$(( (c - 2) / $(tune_slots) )); [ "$n" -lt 1 ] && n=1
  echo "$n"
}

# tune_unity_workers: Unity job worker count for one run, same budget as the threads. warmd.conf unity_workers= wins.
tune_unity_workers() {
  if [ -n "${CFG_unity_workers:-}" ]; then echo "$CFG_unity_workers"; return; fi
  tune_threads
}

# tune_prefix: words to put before a heavy program so the machine stays usable. nice also sets the priority class on Windows.
tune_prefix() {
  [ -n "${CFG_nice:-}" ] && [ "$CFG_nice" = 0 ] && return 0
  command -v nice >/dev/null 2>&1 && echo "nice -n ${CFG_nice:-10}"
  return 0
}

# tune_mem: "<free bytes> <total bytes>", counting what the system can hand out at once. Nothing when unreadable.
tune_mem() {
  local total="" avail="" v
  case "$OS" in
    mac)
      total="$(sysctl -n hw.memsize 2>/dev/null)"
      avail="$(vm_stat 2>/dev/null | awk '/page size of/ {ps=$8} /Pages (free|inactive|speculative)/ {n+=$NF} END {if (ps) print n*ps}')";;
    win) # wmic is language neutral and fast. Without it /proc/meminfo MemFree is the strict fallback.
      total="$(awk '/^MemTotal:/ {print $2*1024; exit}' /proc/meminfo 2>/dev/null)"
      v="$(wmic OS get FreePhysicalMemory //value 2>/dev/null | tr -d '[:cntrl:]' | sed -n 's/^FreePhysicalMemory=//p')"
      [ -n "$v" ] && avail=$(( v * 1024 ))
      [ -n "$avail" ] || avail="$(awk '/^MemFree:/ {print $2*1024; exit}' /proc/meminfo 2>/dev/null)";;
    *)
      total="$(awk '/^MemTotal:/ {print $2*1024; exit}' /proc/meminfo 2>/dev/null)"
      avail="$(awk '/^MemAvailable:/ {print $2*1024; exit}' /proc/meminfo 2>/dev/null)";;
  esac
  case "$total$avail" in ''|*[!0-9]*) return 1;; esac
  [ "$total" -gt 0 ] 2>/dev/null || return 1
  echo "$avail $total"
}

# tune_free_pct: free RAM in percent. WARMD_FREE_PCT overrides, unreadable counts as 100 so it never blocks.
tune_free_pct() {
  if [ -n "${WARMD_FREE_PCT:-}" ]; then echo "$WARMD_FREE_PCT"; return; fi
  local m avail total; m="$(tune_mem)" || { echo 100; return; }
  read -r avail total <<< "$m"
  echo $(( avail * 100 / total ))
}

# tune_wait_ram: a start waits in the queue while too little RAM is free. An engine (Unity, Godot) needs ram_free_min percent
# (default 15); everything else is light (a web, Python or shell suite) and waits only below ram_free_min_light (default 3):
# a two second suite must not stand half an hour behind a limit made for an editor. 0 in warmd.conf switches a limit off.
# It waits at most WARMD_RAM_WAIT seconds (default 1800), then runs anyway.
tune_wait_ram() {
  local min pct said="" t0 limit="${WARMD_RAM_WAIT:-1800}" anyway=0
  [ "${TUNE_RAM_WAITED:-0}" = 1 ] && return 0   # once per run: build and test of one warmd call never wait twice
  TUNE_RAM_WAITED=1
  case "${KIND:-}" in unity|godot|'') min="${CFG_ram_free_min:-15}";; *) min="${CFG_ram_free_min_light:-3}";; esac
  [ "${WARMD_NO_RAM_WAIT:-0}" = 1 ] && return 0
  [ "${CFG_ram_wait:-1}" = 0 ] && return 0
  [ "$min" -gt 0 ] 2>/dev/null || return 0
  t0=$(date +%s)
  while :; do
    pct="$(tune_free_pct)"
    [ "$pct" -ge "$min" ] && break
    [ -n "$said" ] || { echo "(queued: only ${pct}% RAM free, waiting for ${min}%)"; said=1; }
    [ $(( $(date +%s) - t0 )) -ge "$limit" ] && { echo "(RAM still at ${pct}% free after ${limit}s, running anyway)"; anyway=1; break; }
    sleep "${WARMD_RAM_POLL:-3}"; orphan_check
  done
  [ -z "$said" ] || [ $anyway = 1 ] || echo "(RAM free again after $(( $(date +%s) - t0 ))s)"
  return 0
}

# hw_gpu: "<index>|<vram_mb>|<name>", cached as line 2 of the machine data
hw_gpu() {
  if [ -n "${WARMD_GPU:-}" ]; then echo "$WARMD_GPU"; return; fi
  hw >/dev/null
  local f="$CACHE_ROOT/hw" g=""
  [ -f "$f" ] && g="$(sed -n 2p "$f" 2>/dev/null)"
  if [ -z "$g" ]; then
    g="$(hw_gpu_read)"
    if mkdir -p "$CACHE_ROOT" 2>/dev/null && [ -f "$f" ]; then echo "$g" >> "$f" 2>/dev/null; fi
  fi
  echo "$g"
}

# tune_gfx_slots: one graphics run per 6 GB VRAM (rounded, so a 12 GB card counts twice), at least 1. warmd.conf gfx_slots= wins.
tune_gfx_slots() {
  if [ -n "${CFG_gfx_slots:-}" ]; then echo "$CFG_gfx_slots"; return; fi
  local g mem n; g="$(hw_gpu)"; mem="${g#*|}"; mem="${mem%%|*}"
  case "$mem" in ''|*[!0-9]*) mem=0;; esac
  n=$(( (mem + 512) / 6144 )); [ "$n" -lt 1 ] && n=1
  echo "$n"
}

# GPU choice per engine, only options the engine really has. Index 0 is the default, so no flag then.
tune_gpu_index() { local g; g="$(hw_gpu)"; echo "${g%%|*}"; }
tune_unity_gpu_flag() { # -force-device-index is in the Unity 6 editor binary
  local i; i="$(tune_gpu_index)"
  case "$i" in ''|0|*[!0-9]*) return 0;; esac
  echo "-force-device-index $i"
}
tune_godot_gpu_flag() { # <godot exe>: --gpu-index only when this build lists it
  local i; i="$(tune_gpu_index)"
  case "$i" in ''|0|*[!0-9]*) return 0;; esac
  "$1" --help 2>/dev/null | grep -q -- '--gpu-index' && echo "--gpu-index $i"
  return 0
}

# Graphics runs have their own queue: gfx_take waits for a free place, the place is freed when warmd ends.
GFXSLOT=""   # freed by on_exit in lib/core.sh
gfx_take() {
  [ -n "$GFXSLOT" ] && return 0
  claim_slot "$CACHE_ROOT/gfxslots" "$(tune_gfx_slots)" GFXSLOT && return 0
  echo "(queued: $(tune_gfx_slots) graphics runs active)"
  until claim_slot "$CACHE_ROOT/gfxslots" "$(tune_gfx_slots)" GFXSLOT; do sleep 3; orphan_check; done
}

tune_doctor() {
  local v c r; v="$(hw)"; c="${v% *}"; r="${v#* }"
  echo "machine: $c cores, $((r / 1024)) GB RAM"
  local g; g="$(hw_gpu)"
  echo "gpu: ${g##*|}, $(( ($(echo "${g#*|}" | cut -d'|' -f1) + 512) / 1024 )) GB VRAM, device index ${g%%|*}"
  echo "ok graphics slots: $(tune_gfx_slots) (one per 6 GB VRAM, set gfx_slots= in warmd.conf to override), CPU work never uses them"
  echo "ok heavy slots: $(tune_slots) (smaller of cores/4 and RAM/8GB, set slots= in warmd.conf to override)"
  echo "ok threads per run: $(tune_threads) (dotnet -m, cargo -j, vitest --maxWorkers), Unity job workers: $(tune_unity_workers), 2 cores stay free"
}

# doctor shows the tuning after the common checks
eval "$(declare -f common_doctor | sed '1s/common_doctor/common_doctor_base/')"
common_doctor() { common_doctor_base; tune_doctor; }

# claim_slot <dir> <count> <var>: take one of <count> places, name goes into <var>.
# Two waiters that both saw the same dead owner must not both free and retake the place, one at a time judges.
claim_slot() {
  local dir="$1" n="$2" i holder clean
  mkdir -p "$dir"
  for i in $(seq 1 "$n"); do
    if mkdir "$dir/$i" 2>/dev/null; then echo "$$" > "$dir/$i/pid"; printf -v "$3" '%s' "$dir/$i"; return 0; fi
    clean="$dir/.clean$i"
    if [ -n "$(find "$clean" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rmdir "$clean" 2>/dev/null; fi
    if mkdir "$clean" 2>/dev/null; then
      holder="$(cat "$dir/$i/pid" 2>/dev/null)"
      if [ -n "$holder" ]; then shell_alive "$holder" || rm -rf "${dir:?}/$i"
      elif [ -n "$(find "$dir/$i" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rm -rf "${dir:?}/$i"; fi
      rmdir "$clean" 2>/dev/null
    fi
  done
  return 1
}
slot_try() { [ -n "$SLOT" ] && return 0; claim_slot "$CACHE_ROOT/slots" "$(slots_max)" SLOT; }
# RAM check comes after the slot, so only slot holders wait for memory
eval "$(declare -f slot_take | sed '1s/slot_take/slot_take_base/')"
slot_take_now() { slot_take_base; tune_wait_ram; }
# A green-cache hit never waits: when the caller goes straight on to "cached", the slot and the RAM wait move behind the cache check.
SLOT_DEFER=0
slot_take() {
  if [ -z "$SLOT" ] && [ -n "${FUNCNAME[1]:-}" ] && declare -f "${FUNCNAME[1]}" | tr '\n' ' ' | grep -qE 'slot_take; +cached '; then SLOT_DEFER=1; return 0; fi
  slot_take_now
}
# Only a miss takes the slot. The key is read again after the wait, the code may change while queued.
eval "$(declare -f cached | sed '1s/cached/cached_base/')"
cached() {
  local key f
  if [ "$SLOT_DEFER" = 1 ]; then
    SLOT_DEFER=0
    if [ "${WARMD_NOCACHE:-0}" != 1 ] && key="$(code_key)"; then
      f="$CACHE_ROOT/green/${key}_$(sha_of "$KIND|$1")"
      [ -f "$f" ] && { echo "OK cached, code unchanged: $(cat "$f")"; return 0; }
    fi
    slot_take_now
  fi
  cached_base "$@"
}

# Unity import workers cost about 1 GB each and stay after the work is done. After a job on an idle daemon they are ended, Unity starts new ones on demand.
if declare -F job >/dev/null; then
  eval "$(declare -f job | sed '1s/job/job_base/')"
  job() {
    local rc; job_base "$@"; rc=$?
    if declare -F worker_procs >/dev/null && [ $(( $(date +%s) - T0 )) -ge 10 ] && grep -q '^phase=idle' "$RUN/state.txt" 2>/dev/null; then
      local pid; for pid in $(worker_procs); do kill_tree "$pid"; done
    fi
    return $rc
  }
fi
