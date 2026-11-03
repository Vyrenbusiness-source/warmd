#!/usr/bin/env bash
# Repo map ranked by the import graph, the token budget, and the MCP part of warmd audit against fake settings.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
TMP="$(mktemp -d)"
export XDG_CACHE_HOME="$TMP/cache"
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails+1)); }
expect() { if printf '%s\n' "$3" | grep -qE "$2"; then ok "$1"; else no "$1: wanted /$2/, got: $(printf '%s\n' "$3" | head -4)"; fi; }
refuse() { if printf '%s\n' "$3" | grep -qE "$2"; then no "$1: found /$2/"; else ok "$1"; fi; }
repo() { ( cd "$1" && git init -q -b main . && git config core.autocrlf false && git config user.name t && git config user.email t@example.com && git add -A && git commit -qm init ); }

# ---- JS: core is imported by three files, util by two, leaf by one, main by none ----
J="$TMP/js"; mkdir -p "$J/src" "$J/test"
echo '{"name":"m","type":"module","scripts":{"test":"vitest run"}}' > "$J/package.json"
cat > "$J/src/core.js" <<'EOF'
export function parse(s) { return s.split(',') }
export function unusedHelper() { return 1 }
export const LIMIT = 3
EOF
cat > "$J/src/util.js" <<'EOF'
import { parse } from './core.js'
export function words(s) { return parse(s).length }
EOF
cat > "$J/src/leaf.js" <<'EOF'
import { parse, LIMIT } from './core.js'
import { words } from './util.js'
export function leaf(s) { return words(s) + parse(s).length + LIMIT }
EOF
cat > "$J/src/main.js" <<'EOF'
import { parse } from './core.js'
import { words } from './util.js'
import { leaf } from './leaf.js'
export function start() { return [parse('a'), words('b'), leaf('c')] }
EOF
echo "import { leaf } from '../src/leaf.js'; test('x', () => leaf('a'))" > "$J/test/leaf.test.js"
repo "$J"

out="$(cd "$J" && "$WARMD" map)"
order="$(printf '%s\n' "$out" | grep '^== ' | awk '{print $2}' | paste -sd' ' -)"
expect "js: files ranked by importers" '^src/core\.js src/util\.js src/leaf\.js src/main\.js$' "$order"
expect "js: import counts shown" '^== src/core\.js  used by 3$' "$out"
expect "js: test importers counted apart" '^== src/leaf\.js  used by 1 \(\+1 in tests\)$' "$out"
expect "js: most used symbol first with its use count" "$(printf '== src/core.js  used by 3\n  1 export function parse')" "$(printf '%s\n' "$out" | grep -A1 '^== src/core')"
expect "js: parse used by all three importers" '1 export function parse\(s\).*\[3\]$' "$out"
expect "js: LIMIT used once" '3 export const LIMIT = 3  \[1\]$' "$out"
refuse "js: unused symbol has no count" 'unusedHelper.*\[' "$out"
refuse "js: test files are not map entries" '^== test/' "$out"
expect "js: map cost and read cost reported" '^map ~[0-9]+ tokens of 1500; reading the 4 files listed ~[0-9]+ tokens' "$out"

small="$(cd "$J" && "$WARMD" map --budget 70)"
expect "budget: the top file still fits" '^== src/core\.js' "$small"
refuse "budget: lower files are cut" '^== src/main\.js' "$small"
expect "budget: cut files are counted" '^\.\.\. [0-9]+ more files, raise --budget' "$small"
used="$(printf '%s\n' "$small" | sed -n 's/^map ~\([0-9]*\) tokens of 70;.*/\1/p')"
if [ -n "$used" ] && [ "$used" -le 70 ]; then ok "budget: map stays under 70 tokens ($used)"; else no "budget: map over budget: $used"; fi
expect "budget: a non-number is refused" '^FAIL --budget' "$(cd "$J" && "$WARMD" map --budget x)"
expect "one file still gives the outline" '^== core\.js' "$(cd "$J" && "$WARMD" map src/core.js)"

# ---- Python: models imported by two modules, the package init is not a map entry ----
P="$TMP/py"; mkdir -p "$P/app" "$P/tests"
: > "$P/app/__init__.py"
printf 'class Item:\n    def __init__(self, n):\n        self.n = n\n\n    def price(self):\n        return self.n\n\n\ndef make(n):\n    return Item(n)\n' > "$P/app/models.py"
printf 'from app.models import Item, make\n\n\ndef total(xs):\n    return sum(make(x).price() for x in xs)\n' > "$P/app/cart.py"
printf 'from app.models import Item\nfrom app.cart import total\n\n\ndef run():\n    return total([1]), Item\n' > "$P/app/cli.py"
printf 'from app.cart import total\n\n\ndef test_total():\n    assert total([1]) == 1\n' > "$P/tests/test_cart.py"
echo '[project]' > "$P/pyproject.toml"; echo 'name = "app"' >> "$P/pyproject.toml"
repo "$P"
out="$(cd "$P" && "$WARMD" map)"
order="$(printf '%s\n' "$out" | grep '^== ' | awk '{print $2}' | paste -sd' ' -)"
expect "py: files ranked by importers" '^app/models\.py app/cart\.py app/cli\.py$' "$order"
expect "py: class used by both importers" 'class Item:  \[2\]$' "$out"
expect "py: methods listed" 'def price\(self\):  \[1\]$' "$out"
refuse "py: dunder methods left out" '__init__\(self' "$out"

# ---- audit: MCP servers from fake settings ----
H="$TMP/home"; A="$TMP/aud"; mkdir -p "$H/.claude" "$A/.claude"
echo '{"name":"a"}' > "$A/package.json"; repo "$A"
AP="$(cd "$A" && { pwd -W 2>/dev/null || pwd; })"
cat > "$H/.claude.json" <<EOF
{"numStartups": 2, "mcpServers": {"github": {"type": "http", "url": "https://x.example/mcp"}, "big": {"command": "npx", "args": ["a", "b"], "alwaysLoad": true}},
 "projects": {"$AP": {"mcpServers": {"mine": {"command": "x"}}}, "C:/elsewhere": {"mcpServers": {"notmine": {"command": "y"}}}}}
EOF
printf '{"mcpServers":{"db":{"command":"db","alwaysLoad":false},"off":{"command":"o"}}}' > "$A/.mcp.json"
printf '{"env":{"FOO":"1"},"disabledMcpjsonServers":["off"]}' > "$A/.claude/settings.json"
aud() { ( cd "$A" && unset ENABLE_TOOL_SEARCH CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS && HOME="$H" "$WARMD" audit 2>&1 | sed -n '/^MCP servers/,$p' ); }
out="$(aud)"
expect "audit: user server deferred by default" '^  deferred  github  \(~/\.claude\.json\)$' "$out"
expect "audit: alwaysLoad true named with the fix" '^  upfront   big .*"alwaysLoad": true\)\. Fix: set "alwaysLoad": false' "$out"
expect "audit: local server of this project" '^  deferred  mine  \(~/\.claude\.json \(this project\)\)$' "$out"
refuse "audit: other projects left out" 'notmine' "$out"
expect "audit: project server from .mcp.json" '^  deferred  db  \(\.mcp\.json\)$' "$out"
refuse "audit: disabled .mcp.json server left out" ' off ' "$out"
expect "audit: server count" '^  4 servers\.' "$out"
printf '{"env":{"ENABLE_TOOL_SEARCH":"false"},"permissions":{"deny":["ToolSearch"]}}' > "$A/.claude/settings.local.json"
out="$(aud)"
expect "audit: ENABLE_TOOL_SEARCH=false found with its file" '^  ENABLE_TOOL_SEARCH=false \(\.claude/settings\.local\.json\): every MCP tool loads upfront\. Fix: remove it, or set "ENABLE_TOOL_SEARCH": "true"' "$out"
expect "audit: denied ToolSearch found" '^  permissions deny ToolSearch' "$out"
expect "audit: then every server is upfront" '^  upfront   github ' "$out"
printf '{"env":{"ENABLE_TOOL_SEARCH":"auto:5"}}' > "$A/.claude/settings.local.json"
expect "audit: threshold mode named" '^  ENABLE_TOOL_SEARCH=auto:5 ' "$(aud)"
rm -f "$H/.claude.json" "$A/.mcp.json"
expect "audit: nothing configured" '^  none configured$' "$(aud)"

rm -rf "$TMP"
[ $fails = 0 ] && echo "map: all green" || { echo "map: $fails failed"; exit 1; }
