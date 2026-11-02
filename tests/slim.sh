#!/usr/bin/env bash
# Tests for warmd init --slim. Offline by default. SLIM_LIVE=1 adds real claude -p runs (costs tokens) and prints the table.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
TMP="$(mktemp -d)"
export XDG_CACHE_HOME="$TMP/cache"
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails+1)); }
expect() { if echo "$3" | grep -qE "$2"; then ok "$1"; else no "$1: wanted /$2/, got: $(echo "$3" | head -3)"; fi; }

mkdir -p "$TMP/p/.claude/agents"; cd "$TMP/p" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
echo x > index.html
printf -- '---\nname: free\ndescription: No tools line.\nmodel: haiku\n---\nBody stays.\n' > .claude/agents/free.md
printf -- '---\nname: fixed\ndescription: Has tools.\ntools: Bash, Read\n---\nBody.\n' > .claude/agents/fixed.md
printf 'no frontmatter\n' > .claude/agents/plain.md
cp .claude/agents/fixed.md "$TMP/fixed.before"; cp .claude/agents/plain.md "$TMP/plain.before"

out="$("$WARMD" init --slim 2>&1)"
expect "init --slim reports" "OK slim: 1 agent" "$out"
expect "free agent got tools" "^tools: Read, Grep, Glob, Edit, Write" "$(cat .claude/agents/free.md)"
[ "$(awk '/^---/{n++} /^tools:/{print n; exit}' .claude/agents/free.md)" = 1 ] && ok "tools line inside the frontmatter" || no "tools line outside the frontmatter"
expect "body kept" "Body stays" "$(cat .claude/agents/free.md)"
cmp -s .claude/agents/fixed.md "$TMP/fixed.before" && ok "agent with tools untouched" || no "agent with tools changed"
cmp -s .claude/agents/plain.md "$TMP/plain.before" && ok "file without frontmatter untouched" || no "file without frontmatter changed"
expect "warmd agents keep their own tools" "^tools: Bash, Read, Edit, Write" "$(cat .claude/agents/warmd-worker.md)"
out="$("$WARMD" init --slim 2>&1)"
expect "second run changes nothing" "OK slim: 0 agent" "$out"
[ "$(grep -c '^tools:' .claude/agents/free.md)" = 1 ] && ok "exactly one tools line" || no "tools line repeated"
WARMD_SLIM_TOOLS="Read" "$WARMD" init --slim >/dev/null 2>&1
[ ! -d "$TMP/p/.claude/settings.json" ] && ok "settings untouched" || no "settings written"
out="$("$WARMD" init 2>&1)"; expect "plain init still works" "^OK agent definitions" "$out"

if [ "${SLIM_LIVE:-0}" = 1 ]; then
  export WARMD_HOME="$HERE"; . "$HERE/lib/platform.sh"; . "$HERE/lib/slim.sh"
  tab="$(slim_matrix)"; echo "$tab"
  min="$(echo "$tab" | awk '/^tools: Read, Grep, Glob, Edit, Write/{print $(NF-1)}')"; base="$(echo "$tab" | awk '/^tools: Read, Grep, Glob, Edit, Write/{print $(NF-2)}')"
  if [ -n "$min" ] && [ -n "$base" ] && [ "$min" -lt "$base" ]; then ok "slim tool set starts cheaper than all tools ($base -> $min)"; else no "slim set not cheaper (base=$base slim=$min)"; fi
fi

cd /; rm -rf "$TMP"
echo "-- $fails failed"; [ "$fails" = 0 ]
