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
# The Claude Code plugin pins its users to the version in plugin.json: it has to be the version of bin/warmd
code_v="$(sed -n 's/^WARMD_VERSION=//p' "$HERE/bin/warmd")"
plug_v="$(sed -n 's/^  "version": "\([^"]*\)".*/\1/p' "$HERE/.claude-plugin/plugin.json" 2>/dev/null)"
if [ -z "$plug_v" ] || [ "$plug_v" = "$code_v" ]; then echo "ok   plugin version ${plug_v:-absent} matches bin/warmd"
else echo "FAIL .claude-plugin/plugin.json says $plug_v, bin/warmd says $code_v"; fails=$((fails+1)); fi
exit $fails
