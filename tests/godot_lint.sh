#!/usr/bin/env bash
# warmd lint for Godot: string candidates settled by project.godot, the file system and the engine, res:// case,
# per-frame loads, physics in _process, shared resources, determinism and scene conventions.
# Without Godot the engine part runs against a stub; with WARMD_GODOT set (CI job godot) also against the real engine.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
TMP="$(mktemp -d)"
export XDG_CACHE_HOME="$TMP/cache" WARMD_LINT_WARN=50
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails+1)); }
expect() { if printf '%s\n' "$3" | grep -qE -- "$2"; then ok "$1"; else no "$1: wanted /$2/, got: $(printf '%s\n' "$3" | head -8)"; fi; }
refuse() { if printf '%s\n' "$3" | grep -qE -- "$2"; then no "$1: found $(printf '%s\n' "$3" | grep -E -- "$2" | head -1)"; else ok "$1"; fi; }
REAL="${WARMD_GODOT:-}"

G="$TMP/game"; mkdir -p "$G/tests"; cd "$G" || exit 1
git init -q -b main .; git config core.autocrlf false; git config user.name t; git config user.email t@example.com
cat > project.godot <<'EOF'
config_version=5

[application]

config/name="t"

[autoload]

Score="*res://score.gd"

[global_group]

enemies=""

[input]

jump={
"deadzone": 0.5,
"events": []
}

[internationalization]

locale/translations=PackedStringArray("res://en.tres")

[layer_names]

2d_physics/layer_1="Player"
EOF
printf 'extends Node\n' > score.gd
printf '<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"/>\n' > icon.svg
printf '[gd_resource type="Resource" format=3]\n\n[resource]\n' > stats.tres
printf '[gd_resource type="Translation" format=3]\n\n[resource]\nlocale = "en"\nmessages = {\n"MENU_START": "Start"\n}\n' > en.tres
cat > player.gd <<'EOF'
extends CharacterBody2D

var stats = preload("res://stats.tres")
var rng := RandomNumberGenerator.new()


func _process(delta: float) -> void:
	var tex = load("res://Icon.svg")
	move_and_slide()
	if Input.is_action_pressed("jump") or Input.is_action_pressed("jupm") or Input.is_action_pressed("ui_accept"):
		pass
	if is_in_group("enemies") or is_in_group("enemys"):
		pass
	get_node("/root/Score")
	var n = get_node_or_null("/root/Scroe")
	stats.speed = 3
	var r := randi()
	var t := Time.get_ticks_msec()
	print(tr("MENU_START"), tr("MENU_MISSING"), tr("Plain words stay"))
	set_collision_layer_value(33, true); var quiet = load("res://quiet.png")  # warmd: nolint
	var gone = load("res://missing.png"); var asks = FileAccess.file_exists("res://asked.cfg")
	var lvl = "res://levels/" + str(delta)


func _physics_process(delta: float) -> void:
	move_and_slide()
EOF
cat > tests/test_rand.gd <<'EOF'
extends Node

func roll() -> int:
	return randi()
EOF
{
  printf '[gd_scene load_steps=3 format=3]\n\n[ext_resource type="Script" path="res://Player.gd" id="1"]\n[ext_resource type="Texture2D" uid="uid://b1234" path="res://ICON.svg" id="2"]\n\n'
  printf '[sub_resource type="ArrayMesh" id="m"]\n_surfaces = [PackedVector3Array('
  for i in $(seq 1 300); do printf '0.0, 0.0, 0.0, '; done
  printf '0.0)]\n\n[node name="Level" type="Node2D"]\nscript = ExtResource("1")\n\n[editable path="Enemy"]\n'
} > level.tscn
printf '.warmd\n.godot\n' > .gitignore
git add -A; git commit -qm init

expect "nothing changed against the base: no lint run" '^OK lint: no Godot file changed' "$("$WARMD" lint)"
expect "a non-Godot project is refused" 'FAIL warmd lint is for Godot projects' "$(cd "$TMP" && mkdir -p plain && cd plain && "$WARMD" lint 2>&1)"

# ---- no engine: proven errors only, the rest a warning ----
if command -v godot >/dev/null 2>&1 || command -v godot4 >/dev/null 2>&1; then
  echo "skip no-engine part: a Godot is on PATH"
else
  out="$(WARMD_GODOT= WARMD_LINT_SUBRES_KB=1 "$WARMD" lint player.gd level.tscn tests/test_rand.gd)"; rc=$?
  expect "res:// case differs from the disk: error" '^ERROR player.gd:8 res://Icon.svg differs in case from res://icon.svg' "$out"
  expect "scene ext_resource case without uid: error" '^ERROR level.tscn:3 res://Player.gd differs in case from res://player.gd' "$out"
  expect "scene ext_resource case with uid: only a warning" '^WARN level.tscn:4 res://ICON.svg differs in case' "$out"
  expect "collision layer out of range: error" '^ERROR player.gd:20 collision layer 33 is out of range' "$out"
  expect "errors make the lint red" '^FAIL lint: 3 files, 3 errors' "$out"
  [ $rc = 1 ] && ok "red lint exits 1" || no "red lint exits $rc, wanted 1"
  expect "unknown action without engine: warning" '^WARN player.gd:10 input action "jupm" is not in project.godot \[input\], not confirmed: no Godot' "$out"
  refuse "a known action is no finding" '"jump"' "$out"
  expect "missing autoload without engine: warning" '^WARN player.gd:15 /root/Scroe is no autoload' "$out"
  refuse "a known autoload is no finding" '/root/Score ' "$out"
  expect "group never added: warning" '^WARN player.gd:12 group "enemys" is never added' "$out"
  refuse "a global group is known" 'group "enemies"' "$out"
  expect "missing res:// path without engine: warning" '^WARN player.gd:21 res://missing.png does not exist, not confirmed' "$out"
  refuse "a concatenated res:// path is no candidate" 'res://levels' "$out"
  expect "tr key without engine: warning" '^WARN player.gd:19 translation key "MENU_MISSING"' "$out"
  refuse "tr with plain words is no key" 'Plain words' "$out"
  expect "load() in _process: warning" '^WARN player.gd:8 load\(\) in _process runs every frame' "$out"
  expect "get_node() in _process: warning" '^WARN player.gd:14 get_node\(\) in _process runs every frame' "$out"
  expect "move_and_slide in _process: warning" '^WARN player.gd:9 move_and_slide\(\) in _process: physics belongs in _physics_process' "$out"
  refuse "move_and_slide in _physics_process is fine" 'player.gd:26' "$out"
  expect "shared resource changed without duplicate: warning" '^WARN player.gd:16 stats is a shared resource' "$out"
  expect "global randi: warning" '^WARN player.gd:17 randi\(\) uses the global unseeded generator' "$out"
  refuse "random in test code is no finding" 'test_rand.gd' "$out"
  expect "RandomNumberGenerator without a seed: warning" '^WARN player.gd:4 RandomNumberGenerator without a seed' "$out"
  expect "wall clock in gameplay code: warning" '^WARN player.gd:18 Time.get_ticks_msec\(\) in gameplay code' "$out"
  expect "editable children of a sub-scene: warning" '^WARN level.tscn:[0-9]+ editable children of the instanced sub-scene at Enemy' "$out"
  expect "big embedded sub_resource: warning" '^WARN level.tscn:6 embedded ArrayMesh of [0-9]+ KB' "$out"
  out="$(WARMD_GODOT= WARMD_LINT_WARN=3 "$WARMD" lint player.gd)"
  expect "warnings are capped" '^\([0-9]+ more warnings, WARMD_LINT_WARN=[0-9]+ shows all\)' "$out"
  [ "$(printf '%s\n' "$out" | grep -c '^WARN')" = 3 ] && ok "cap shows 3 warnings" || no "cap shows $(printf '%s\n' "$out" | grep -c '^WARN') warnings"
  # fixes: duplicate(), a seed, the right case
  sed -i 's/^var stats = preload("res:\/\/stats.tres")$/var stats = preload("res:\/\/stats.tres")\nfunc _ready() -> void:\n\tstats = stats.duplicate()\n\tseed(7)\n\trng.seed = 7\n/' player.gd
  out="$(WARMD_GODOT= "$WARMD" lint player.gd)"
  refuse "duplicate() clears the shared resource warning" 'shared resource' "$out"
  refuse "seed() clears the global random warning" 'unseeded' "$out"
  refuse "a seeded RandomNumberGenerator is fine" 'RandomNumberGenerator without' "$out"
  git checkout -q player.gd
  # only changed files in warmd check's selection
  git checkout -q -b feature; printf 'extends Node\n\nfunc _process(_d: float) -> void:\n\tget_node("Thing")\n' > fresh.gd
  out="$(WARMD_GODOT= "$WARMD" lint)"
  expect "without arguments only changed files are linted" '^OK lint: 1 files, 0 errors, 1 warnings' "$out"
  rm fresh.gd; git checkout -q main
fi

# ---- engine stub: the verdict decides, one engine start ----
STUB="$TMP/fakegodot"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
in="$WARMD_LINT_IN"; command -v cygpath >/dev/null 2>&1 && in="$(cygpath -u "$in")"
echo "$*" >> "${in%/*}/stub.calls"
while IFS=$'\t' read -r k v; do
  case "$v" in jupm|Scroe|MENU_MISSING|res://missing.png|res://asked.cfg|res://quiet.png) r=missing;; *) r=ok;; esac
  printf 'LINT %s\t%s\t%s\n' "$k" "$v" "$r"
done < "$in"
echo "LINT END"
EOF
chmod +x "$STUB"
out="$(WARMD_GODOT="$STUB" "$WARMD" lint player.gd)"
expect "stub engine: missing action is an error" '^ERROR player.gd:10 input action "jupm" is not in project.godot \[input\] and the engine does not know it either' "$out"
expect "stub engine: missing autoload is an error" '^ERROR player.gd:15 /root/Scroe is no autoload' "$out"
expect "stub engine: missing tr key is an error" '^ERROR player.gd:19 translation key "MENU_MISSING"' "$out"
expect "stub engine: missing res:// path is an error" '^ERROR player.gd:21 res://missing.png does not exist' "$out"
refuse "a path the code only asks about (file_exists) is no finding" 'res://asked.cfg' "$out"
refuse "a line with warmd: nolint gives no res:// finding" 'res://quiet.png' "$out"
refuse "stub engine: what the engine knows is no finding" 'ui_accept' "$out"
[ "$(wc -l < .warmd/run/stub.calls)" = 1 ] && ok "one engine start for all candidates" || no "engine started $(wc -l < .warmd/run/stub.calls) times"
rm -f .warmd/run/stub.calls
printf 'extends Node\n\nfunc _ready() -> void:\n\tif Input.is_action_pressed("jump"):\n\t\tget_node("/root/Score")\n' > clean.gd
out="$(WARMD_GODOT="$STUB" "$WARMD" lint clean.gd)"
expect "all settled by project.godot: green" '^OK lint: 1 files, 0 errors, 0 warnings' "$out"
[ -f .warmd/run/stub.calls ] && no "the engine started although project.godot settled everything" || ok "no engine start when nothing is open"
rm clean.gd

# ---- real engine (CI job godot) ----
if [ -n "$REAL" ]; then
  out="$(WARMD_GODOT="$REAL" "$WARMD" lint player.gd)"
  expect "engine: unknown action is an error" '^ERROR player.gd:10 input action "jupm" .* the engine does not know it either' "$out"
  refuse "engine: built-in ui_accept is known" 'ui_accept' "$out"
  expect "engine: missing autoload is an error" '^ERROR player.gd:15 /root/Scroe is no autoload' "$out"
  expect "engine: missing translation key is an error" '^ERROR player.gd:19 translation key "MENU_MISSING"' "$out"
  refuse "engine: a known translation key is no finding" 'MENU_START' "$out"
  expect "engine: missing res:// file is an error" '^ERROR player.gd:21 res://missing.png does not exist' "$out"
  expect "engine: red with all errors" '^FAIL lint: 1 files, 6 errors' "$out"
else
  echo "skip real engine part: set WARMD_GODOT (CI job godot)"
fi

[ $fails = 0 ] && echo "godot_lint: all ok" || echo "godot_lint: $fails failed"
exit $fails
