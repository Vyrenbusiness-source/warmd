#!/usr/bin/env bash
# Every command in the bin/warmd usage text must have a "### warmd <name>" entry in docs/COMMANDS.md.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
for c in $("$HERE/bin/warmd" help | sed -n 's/^  warmd \([a-z][a-z-]*\).*/\1/p' | sort -u); do
  if grep -qE "^### warmd $c( |$)" "$HERE/docs/COMMANDS.md"; then echo "ok   $c documented"; else echo "FAIL $c has no entry in docs/COMMANDS.md"; fails=$((fails+1)); fi
done
# The Config line of the help names the file that documents warmd.conf, and that file has the section
cfg="$("$HERE/bin/warmd" help | sed -n 's/^Config .* \(docs\/[A-Za-z_]*\.md\).*/\1/p')"
if [ -n "$cfg" ] && grep -q '^## Configuration' "$HERE/$cfg"; then echo "ok   help points to the config docs in $cfg"
else echo "FAIL the help Config line does not name a docs file with a ## Configuration section"; fails=$((fails+1)); fi
exit $fails
