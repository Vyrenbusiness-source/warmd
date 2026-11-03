#!/usr/bin/env bash
# Every command in the bin/warmd usage text must have a "### warmd <name>" entry in docs/COMMANDS.md.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
for c in $("$HERE/bin/warmd" help | sed -n 's/^  warmd \([a-z][a-z-]*\).*/\1/p' | sort -u); do
  if grep -qE "^### warmd $c( |$)" "$HERE/docs/COMMANDS.md"; then echo "ok   $c documented"; else echo "FAIL $c has no entry in docs/COMMANDS.md"; fails=$((fails+1)); fi
done
exit $fails
