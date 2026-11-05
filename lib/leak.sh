# warmd leak [N]: does this machine lose kernel memory per process start? Kernel pool (nonpaged and paged) and free RAM
# before and after N short process starts, as KB per start. A driver that leaks there makes every build slower until a reboot.
reg leak "warmd leak [N]               kernel pool and free RAM before and after N process starts (Windows)" leak_main

leak_mem() { # -> "<nonpaged bytes> <paged bytes> <available bytes>", language neutral raw counters
  powershell.exe -NoProfile -NonInteractive -Command '$m = Get-CimInstance Win32_PerfRawData_PerfOS_Memory; "{0} {1} {2}" -f $m.PoolNonpagedBytes, $m.PoolPagedBytes, $m.AvailableBytes' 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+ [0-9]+ [0-9]+$'
}

leak_main() {
  local n="${1:-500}" exe i t0 a b np0 p0 f0 np1 p1 f1
  case "$n" in ''|*[!0-9]*|0) echo "warmd leak [N], N process starts, default 500"; return 2;; esac
  [ "$OS" = win ] || { echo "FAIL warmd leak measures the Windows kernel pool, this is $OS"; return 2; }
  exe="${WARMD_LEAK_CMD:-/usr/bin/true}"; [ -x "$exe" ] || exe="$(cygpath -u "${WINDIR:-C:/Windows}")/System32/hostname.exe"
  # A heavy run of its own: a free slot and enough free RAM first, other runs would blur the numbers
  slot_take_now
  a="$(leak_mem)" || { echo "FAIL cannot read the kernel pool counters (Win32_PerfRawData_PerfOS_Memory)"; return 1; }
  read -r np0 p0 f0 <<< "$a"
  t0="$(date +%s)"
  for (( i = 0; i < n; i++ )); do "$exe" >/dev/null 2>&1; done
  sleep 2   # the system frees what it frees right after a process ends
  b="$(leak_mem)" || { echo "FAIL cannot read the kernel pool counters after the run"; return 1; }
  read -r np1 p1 f1 <<< "$b"
  echo "warmd leak: $n starts of ${exe##*/} in $(( $(date +%s) - t0 ))s"
  awk -v n="$n" -v a="$np0" -v b="$np1" -v c="$p0" -v d="$p1" -v e="$f0" -v f="$f1" 'BEGIN {
    printf "nonpaged pool %+d KB (%+.2f KB per start), now %d MB\n", (b-a)/1024, (b-a)/1024/n, b/1048576
    printf "paged pool    %+d KB (%+.2f KB per start), now %d MB\n", (d-c)/1024, (d-c)/1024/n, d/1048576
    printf "free RAM      %+d MB, now %d MB\n", (f-e)/1048576, f/1048576 }'
  if [ $(( (np1 - np0 + p1 - p0) / 1024 / n )) -ge "${WARMD_LEAK_WARN_KB:-4}" ]; then
    echo "LEAK kernel pool grows by about $(( (np1 - np0 + p1 - p0) / 1024 / n )) KB per process start: a driver keeps memory until reboot (poolmon shows which tag)"
  else echo "OK no kernel pool growth worth naming per process start"; fi
}
