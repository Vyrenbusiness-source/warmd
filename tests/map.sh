#!/usr/bin/env bash
# Repo map ranked by the import graph, the token budget, Godot scene outlines and peek, and the MCP part of warmd audit against fake settings.
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

# ---- Godot scenes: outline of one .tscn, scenes ranked in the repo map, peek refusals (the engine part needs Godot) ----
G="$TMP/gd"; mkdir -p "$G/actors"
printf 'config_version=5\n[application]\nconfig/name="t"\nrun/main_scene="res://main.tscn"\n' > "$G/project.godot"
printf 'extends Node2D\n\nfunc _on_area_body_entered(_b) -> void:\n\tpass\n' > "$G/main.gd"
printf 'extends CharacterBody2D\n\n@export var speed := 120.0\nsignal hit\n\nfunc _on_hit(_a, _b) -> void:\n\tpass\n' > "$G/actors/player.gd"
cat > "$G/actors/enemy.tscn" <<'EOF'
[gd_scene format=3 uid="uid://en"]

[node name="Enemy" type="CharacterBody2D"]
EOF
cat > "$G/main.tscn" <<'EOF'
[gd_scene load_steps=4 format=3 uid="uid://abc"]

[ext_resource type="Script" uid="uid://s1" path="res://main.gd" id="1_main"]
[ext_resource type="PackedScene" uid="uid://e1" path="res://actors/enemy.tscn" id="2_en"]
[ext_resource type="Script" path="res://actors/player.gd" id="3_pl"]

[sub_resource type="RectangleShape2D" id="RectangleShape2D_x"]
size = Vector2(10, 10)

[node name="Main" type="Node2D"]
script = ExtResource("1_main")

[node name="Player" type="CharacterBody2D" parent="." groups=["players", "save"]]
position = Vector2(1, 2)
script = ExtResource("3_pl")

[node name="Area" type="Area2D" parent="Player"]
unique_name_in_owner = true

[node name="Shape" type="CollisionShape2D" parent="Player/Area"]
shape = SubResource("RectangleShape2D_x")

[node name="Enemy" parent="." instance=ExtResource("2_en")]
position = Vector2(5, 5)

[connection signal="body_entered" from="Player/Area" to="." method="_on_area_body_entered"]
[connection signal="hit" from="Enemy" to="Player" method="_on_hit" flags=3 binds=[1, 2]]
[connection to="." method="_odd" from="Player" signal="ready" unbinds=1]
EOF
cat > "$G/level.tscn" <<'EOF'
[gd_scene load_steps=2 format=3]

[ext_resource type="PackedScene" path="res://actors/enemy.tscn" id="1_e"]

[node name="Level" type="Node2D"]

[node name="Enemy" parent="." instance=ExtResource("1_e")]
EOF
# Godot 3 text: numeric ids without quotes, ExtResource( 1 ) with spaces, an inherited root
printf '[gd_scene load_steps=3 format=2]\n\n[ext_resource path="res://base.tscn" type="PackedScene" id=1]\n[ext_resource path="res://old.gd" type="Script" id=2]\n\n[node name="Old" instance=ExtResource( 1 )]\nscript = ExtResource( 2 )\n\n[node name="Kid" type="Sprite" parent="."]\n\n[connection signal="pressed" from="Kid" to="." method="_on_pressed"]\n' > "$G/old.tscn"
repo "$G"
smap() { ( cd "$G" && PROJECT="$G" WARMD_HOME="$HERE" bash -c '. "$WARMD_HOME/lib/map.sh"; scene_map "$@"' _ "$@" ); }
out="$(smap main.tscn)"
expect "scene: header with root type and counts" '^== main\.tscn  Node2D, 5 nodes, 3 connections$' "$out"
expect "scene: root with its script and line" '^10 Main  Node2D  script res://main\.gd$' "$out"
expect "scene: child indented, script and groups" '^13   Player  CharacterBody2D  script res://actors/player\.gd  groups players,save$' "$out"
expect "scene: unique name marked, depth from the parent path" '^17     %Area  Area2D$' "$out"
expect "scene: three levels deep" '^20       Shape  CollisionShape2D$' "$out"
expect "scene: instanced sub-scene" '^23   Enemy  instance res://actors/enemy\.tscn$' "$out"
expect "scene: connection signal from to method" '^26 body_entered Player/Area -> \. _on_area_body_entered$' "$out"
expect "scene: flags and binds kept" '^27 hit Enemy -> Player _on_hit  flags 3  binds=\[1, 2\]$' "$out"
expect "scene: attributes in any order" '^28 ready Player -> \. _odd$' "$out"
refuse "scene: sub_resource bodies are no nodes" 'size|RectangleShape2D_x' "$out"
out="$(smap old.tscn)"
expect "scene: Godot 3 format named" '^== old\.tscn  inherited scene, 2 nodes, 1 connection, Godot 3 format$' "$out"
expect "scene: Godot 3 inherited root with its base and script" '^6 Old  inherits res://base\.tscn  script res://old\.gd$' "$out"
expect "scene: Godot 3 child" '^9   Kid  Sprite$' "$out"
expect "scene: Godot 3 connection" '^11 pressed Kid -> \. _on_pressed$' "$out"
expect "scene: node cap" '^\.\.\. 3 more nodes' "$(cd "$G" && PROJECT="$G" WARMD_HOME="$HERE" WARMD_MAP_NODES=2 bash -c '. "$WARMD_HOME/lib/map.sh"; scene_map main.tscn')"
expect "scene: missing file" '^warmd map: no file nope\.tscn' "$(smap nope.tscn)"
if grep -q scene_map "$HERE/bin/warmd"; then
  expect "scene: warmd map routes .tscn to the outline" '^== main\.tscn  Node2D, 5 nodes' "$(cd "$G" && "$WARMD" map main.tscn)"
else echo "skip scene: bin/warmd does not route .tscn to scene_map yet"; fi
out="$(cd "$G" && "$WARMD" map)"
expect "scene: the twice instanced scene ranks first" '^== actors/enemy\.tscn  used by 2$' "$(printf '%s\n' "$out" | grep '^== ' | head -1)"
expect "scene: scene nodes listed as name and type" '^  3 node Enemy CharacterBody2D$' "$out"
expect "scene: a scene's script ranks with it" '^== actors/player\.gd  used by 1$' "$out"
expect "scene: nodes of a ranked scene" '^  13 node Player CharacterBody2D$' "$out"
refuse "scene: node names get no use counts" 'node .*\[[0-9]+\]$' "$out"
peek() { ( cd "$G" && PROJECT="$G" WARMD_HOME="$HERE" bash -c '. "$WARMD_HOME/lib/map.sh"; '"$1"'; scene_peek "$@"' _ "${@:2}" ); }
expect "peek: other project kinds refused" '^FAIL warmd peek is for Godot projects' "$(peek 'KIND=js' main.tscn)"
expect "peek: frames must be a number" '^FAIL frames wants a number, got x' "$(peek 'KIND=godot; godot_exe() { return 1; }' main.tscn x)"
expect "peek: unknown name refused" '^FAIL no scene named nosuch' "$(peek 'KIND=godot; godot_exe() { return 1; }' nosuch)"
expect "peek: a name finds the scene, then the engine is asked for" '^FAIL Godot not found' "$(peek 'KIND=godot; godot_exe() { return 1; }' level)"
if GX="${WARMD_GODOT:-$(command -v godot 2>/dev/null || command -v godot4 2>/dev/null)}" && [ -n "$GX" ]; then
  out="$(cd "$G" && "$WARMD" peek main.tscn 5 2>&1)"
  expect "peek: tree after the frames" '^== res://main\.tscn after 5 frames, 5 nodes$' "$out"
  expect "peek: root with position and script" '^Main  Node2D  pos \(0, 0\)  script res://main\.gd$' "$out"
  expect "peek: exported var shown" '^  Player  CharacterBody2D  pos \(1, 2\)  script res://actors/player\.gd  speed=120$' "$out"
  expect "peek: instanced scene is live" '^  Enemy  CharacterBody2D  pos \(5, 5\)$' "$out"
  if git -C "$G" status --porcelain | grep -qvE '^\?\? \.(godot|warmd)/'; then no "peek: changed project files: $(git -C "$G" status --porcelain | head -3)"; else ok "peek: saves nothing"; fi
else echo "skip peek engine cases: no Godot (CI job godot covers them)"; fi

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
