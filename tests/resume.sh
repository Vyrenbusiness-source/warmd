#!/usr/bin/env bash
# warmd resume and warmd reboot --if-starved: the one-shot Startup entry and the dry run. Never reboots: no warmd.conf
# here sets reboot=1, and the test fails if a REBOOT line ever shows. No engine.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
TMP="$(mktemp -d)"
export XDG_CACHE_HOME="$TMP/cache" WARMD_STARTUP_DIR="$TMP/Startup" WARMD_CLAUDE="$TMP/bin/claude.exe" WARMD_AUTOLOGON=0 WARMD_REBOOT_POLL=0
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails+1)); }
expect() { if echo "$3" | grep -qE "$2"; then ok "$1"; else no "$1: wanted /$2/, got: $(echo "$3" | head -3)"; fi; }
w() { "$WARMD" "$@" 2>&1; }

mkdir -p "$TMP/bin" "$TMP/proj"; : > "$TMP/bin/claude.exe"; cd "$TMP/proj" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
printf '.warmd\n' > .gitignore; echo '# handoff' > HANDOFF.md; git add -A; git commit -qm init
F="$TMP/Startup/warmd-resume.cmd"

expect "arm without a handoff file is refused" '^FAIL nope\.md not found' "$(w resume --arm nope.md)"
[ ! -e "$F" ] && ok "nothing armed on a refusal" || no "armed without handoff"
out="$(w resume --arm HANDOFF.md)"
expect "arm names the folder and the handoff" '^OK resume armed: after the next sign-in Claude Code starts in .*proj on .*HANDOFF\.md' "$out"
expect "arm says whether Windows signs in by itself" '^WARN automatic sign-in is not set up' "$out"
c="$(tr -d '\r' < "$F" 2>/dev/null)"
expect "the entry opens a visible window in the project folder" '^start "warmd resume" /D ".*proj" cmd /k ' "$c"
expect "it starts Claude Code with the handoff sentence" 'claude\.exe" "Lies .*HANDOFF\.md und mache dort weiter\.""$' "$c"
expect "it deletes itself after one start" '^\(goto\) 2>nul & del "%~f0"$' "$c"
[ "$(tr -dc '\r' < "$F" | wc -c)" -ge 5 ] && ok "CRLF line ends for cmd" || no "no CRLF in $F"
expect "status shows the armed handoff" '^armed: .*HANDOFF\.md' "$(w resume)"
expect "an automatic sign-in is reported ok" '^ok automatic sign-in is set up' "$(WARMD_AUTOLOGON=1 w resume)"

# reboot: plenty of RAM is no reason; starved RAM without reboot=1 is a dry run that names what it would do
expect "enough RAM: no reboot" '^OK RAM free \(40%\), not below ram_free_min 15%' "$(WARMD_FREE_PCT=40 w reboot --if-starved)"
out="$(WARMD_FREE_PCT=5 w reboot --if-starved)"
expect "starved without reboot=1 is a dry run" '^DRY RAM stayed below ram_free_min 15% \(5%, 5%, 5% over 0s\)\. With reboot=1 in warmd\.conf warmd would log it and run: shutdown /r /t 120' "$out"
echo "$out" | grep -q '^REBOOT' && no "a dry run announced a reboot: $out" || ok "the dry run reboots nothing"
[ ! -e "$XDG_CACHE_HOME/warmd/reboot.log" ] && ok "a dry run writes no reboot log line" || no "reboot.log written by a dry run"
expect "reboot without --if-starved only shows its usage" '^warmd reboot --if-starved$' "$(w reboot)"

expect "disarm removes the entry" '^OK resume disarmed' "$(w resume --disarm)"
[ ! -e "$F" ] && ok "the Startup entry is gone" || no "entry left: $F"
expect "a dry run without resume names the arm step" 'and warmd resume --arm <handoff\.md> warmd would' "$(WARMD_FREE_PCT=5 w reboot --if-starved)"
expect "disarm twice is fine" '^OK resume was not armed' "$(w resume --disarm)"

cd "$HERE" || exit 1
rm -rf "$TMP" 2>/dev/null
echo; [ $fails = 0 ] && echo "resume: all green" || echo "resume: $fails failed"
exit $fails
