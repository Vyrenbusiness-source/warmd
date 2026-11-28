# Resume after a reboot. Some Windows machines lose memory with every process start until a reboot; once the free RAM
# stays below the limit warmd runs at, nothing moves until someone restarts the PC and the session by hand.
# warmd resume --arm <handoff.md> puts a one-shot .cmd into the user's Startup folder: after the next sign-in it opens a
# visible terminal in the project folder, starts Claude Code with "Lies <handoff.md> und mache dort weiter." and deletes
# itself. warmd reboot --if-starved restarts the PC only with reboot=1 in warmd.conf, resume armed and the RAM below
# ram_free_min in 3 looks over 3 minutes; without reboot=1 it only says what it would do. Windows only.
reg resume "warmd resume [--arm <handoff.md> | --disarm]  after the next sign-in, Claude Code starts once on the handoff" resume_main
reg reboot "warmd reboot --if-starved      restart the PC when RAM stays too low for any run (reboot=1, resume armed)" reboot_main

# REPLY = the Startup folder of this user (WARMD_STARTUP_DIR for tests)
resume_dir() {
  REPLY="${WARMD_STARTUP_DIR:-}"
  [ -n "$REPLY" ] && return 0
  [ -n "${APPDATA:-}" ] || return 1
  REPLY="$(cygpath -u "$APPDATA" 2>/dev/null || echo "$APPDATA")/Microsoft/Windows/Start Menu/Programs/Startup"
}
resume_file() { resume_dir || return 1; REPLY="$REPLY/warmd-resume.cmd"; }
# REPLY = Claude Code's CLI: WARMD_CLAUDE, else ~/.local/bin/claude(.exe), else claude on PATH. Never Copilot, no VS Code.
resume_claude() {
  local c
  for c in "${WARMD_CLAUDE:-}" "$HOME/.local/bin/claude.exe" "$HOME/.local/bin/claude"; do
    [ -n "$c" ] && [ -f "$c" ] && { REPLY="$c"; return 0; }
  done
  c="$(command -v claude 2>/dev/null)" && [ -n "$c" ] && { REPLY="$c"; return 0; }
  return 1
}
# Windows signs in by itself only with AutoAdminLogon=1 (Winlogon). warmd only reads it, never changes the sign-in.
# REPLY = one line about it; 0 when it is set. WARMD_AUTOLOGON=0|1 for tests.
resume_autologon() {
  local v="${WARMD_AUTOLOGON:-}"
  if [ -z "$v" ]; then
    v="$(MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' reg.exe query 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' /v AutoAdminLogon 2>/dev/null | tr -d '\r' | awk '/AutoAdminLogon/ {print $NF}')"
  fi
  if [ "$v" = 1 ]; then REPLY="ok automatic sign-in is set up (AutoAdminLogon=1): after a reboot the session resumes by itself"; return 0; fi
  REPLY="WARN automatic sign-in is not set up (AutoAdminLogon ${v:-missing}): after a reboot the PC waits at the sign-in screen, the session resumes once someone signs in"
  return 1
}
resume_main() {
  local f h d c w
  resume_file || { echo "FAIL no Startup folder (APPDATA unset): warmd resume works on Windows only"; return 2; }
  f="$REPLY"
  case "${1:-}" in
    --arm)
      h="${2:-}"; [ -n "$h" ] || { echo "warmd resume --arm <handoff.md>"; return 2; }
      [ -f "$h" ] || { echo "FAIL $h not found: write the handoff first"; return 1; }
      resume_claude || { echo "FAIL Claude Code CLI not found (~/.local/bin/claude.exe), set WARMD_CLAUDE"; return 1; }
      c="$(native_path "$REPLY")"; h="$(native_path "$(cd "$(dirname "$h")" && pwd)/${h##*/}")"; d="$(native_path "$PWD")"
      w="${c//\//\\}"; h="${h//\//\\}"; d="${d//\//\\}"
      mkdir -p "${f%/*}" || { echo "FAIL cannot write ${f%/*}"; return 1; }
      # start returns at once, so the last line can delete the file while the new window runs Claude Code
      printf '%s\r\n' '@echo off' 'chcp 65001 >nul' \
        "rem warmd resume: starts Claude Code once after sign-in, then deletes itself. Remove: warmd resume --disarm" \
        "start \"warmd resume\" /D \"$d\" cmd /k \"\"$w\" \"Lies $h und mache dort weiter.\"\"" \
        '(goto) 2>nul & del "%~f0"' > "$f" || { echo "FAIL cannot write $f"; return 1; }
      echo "OK resume armed: after the next sign-in Claude Code starts in $d on $h ($(native_path "$f"))"
      resume_autologon; echo "$REPLY";;
    --disarm)
      if [ -f "$f" ]; then rm -f "$f" && echo "OK resume disarmed"; else echo "OK resume was not armed"; fi;;
    ""|--status)
      if [ -f "$f" ]; then echo "armed: $(grep -o 'Lies .* und mache' "$f" | sed 's/^Lies //; s/ und mache$//') ($(native_path "$f"))"; else echo "not armed"; fi
      resume_autologon; echo "$REPLY";;
    *) echo "warmd resume [--arm <handoff.md> | --disarm]"; return 2;;
  esac
}

# warmd reboot --if-starved: 3 looks at the free RAM, WARMD_REBOOT_POLL seconds apart (90: 3 looks in 3 minutes). All
# below ram_free_min (the limit an engine run waits at) means no run gets through until a reboot.
reboot_main() {
  [ "${1:-}" = --if-starved ] || { echo "warmd reboot --if-starved"; return 2; }
  detect_project
  local min="${CFG_ram_free_min:-15}" poll="${WARMD_REBOOT_POLL:-90}" i p seen="" low=1 armed=0 log="$CACHE_ROOT/reboot.log" h=""
  [ "$min" -gt 0 ] 2>/dev/null || { echo "OK ram_free_min=0: warmd never waits for RAM, no reboot"; return 0; }
  for i in 1 2 3; do
    [ $i = 1 ] || nap "$poll"
    p="$(tune_free_pct)"; seen="$seen${seen:+, }$p%"
    [ "$p" -lt "$min" ] 2>/dev/null || { low=0; break; }
  done
  if [ $low = 0 ]; then echo "OK RAM free ($seen), not below ram_free_min $min%: no reboot"; return 0; fi
  resume_file && [ -f "$REPLY" ] && { armed=1; h="$(grep -o 'Lies .* und mache' "$REPLY" | sed 's/^Lies //; s/ und mache$//')"; }
  if [ "${CFG_reboot:-0}" != 1 ]; then
    echo "DRY RAM stayed below ram_free_min $min% ($seen over $(( 2 * poll ))s). With reboot=1 in warmd.conf$([ $armed = 1 ] || echo " and warmd resume --arm <handoff.md>") warmd would log it and run: shutdown /r /t 120"
    resume_autologon; echo "$REPLY"; return 0
  fi
  [ $armed = 1 ] || { echo "FAIL RAM starved ($seen) but resume is not armed: warmd resume --arm <handoff.md> first, no reboot"; return 1; }
  mkdir -p "$CACHE_ROOT"
  printf '%(%Y-%m-%d %H:%M:%S)T\treboot\tRAM %s free, below %s%%\t%s\t%s\n' -1 "$seen" "$min" "$(native_path "$PROJECT")" "$h" >> "$log"
  resume_autologon || echo "$REPLY"
  echo "REBOOT in 120 s: RAM stayed below $min% free ($seen). After sign-in Claude Code resumes on $h. Abort: shutdown /a"
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' shutdown.exe /r /t 120 /c "warmd: free RAM stayed below $min% ($seen). Restart in 120 s, work resumes after sign-in. Abort: shutdown /a"
}
