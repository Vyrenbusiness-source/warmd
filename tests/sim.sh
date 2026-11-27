#!/usr/bin/env bash
# warmd sim: scenarios under a fixed tick, metrics against limits, input replay. The engine part needs Godot 4.3 or newer
# in WARMD_GODOT or on PATH (CI job godot); without one only the checks that need no engine run.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
TMP="$(mktemp -d)"
export XDG_CACHE_HOME="$TMP/cache"
fails=0
expect() { if echo "$3" | grep -qE "$2"; then echo "ok   $1"; else echo "FAIL $1: wanted /$2/, got: $(echo "$3" | head -12)"; fails=$((fails+1)); fi; }
refuse() { if echo "$3" | grep -qE "$2"; then echo "FAIL $1: $(echo "$3" | grep -E "$2" | head -1)"; fails=$((fails+1)); else echo "ok   $1"; fi; }

mkdir -p "$TMP/web"; echo '{}' > "$TMP/web/package.json"
expect "sim is for Godot projects" 'FAIL warmd sim is for Godot projects' "$(cd "$TMP/web" && "$WARMD" sim 2>&1)"

mkdir -p "$TMP/g"; cd "$TMP/g" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
cat > project.godot <<'EOF'
config_version=5

[application]
config/name="t"

[input]
jump={
"deadzone": 0.2,
"events": []
}
EOF
printf '.warmd\n.godot\ncache\n' > .gitignore
# Hero: rises while jump is held, sinks otherwise. SIM_FEED=1 presses jump itself (scripted input for the record test).
cat > hero.gd <<'EOF'
extends Node2D

var height := 0.0
var wobble := 0.0
var ticks := 0


func _ready() -> void:
	wobble = randf()


func _physics_process(_delta: float) -> void:
	if OS.get_environment("SIM_FEED") == "1":
		if ticks == 5:
			Input.action_press("jump")
		elif ticks == 15:
			Input.action_release("jump")
	height = height + 1.0 if Input.is_action_pressed("jump") else maxf(0.0, height - 0.5)
	ticks += 1
EOF
cat > main.tscn <<'EOF'
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://hero.gd" id="1"]

[node name="Main" type="Node2D"]

[node name="Hero" type="Node2D" parent="."]
script = ExtResource("1")
EOF
printf 'extends Node\n\nvar t := 0\n\n\nfunc _physics_process(_d: float) -> void:\n\tt += 1\n\tif t == 3:\n\t\tvar n: Object = null\n\t\tn.free()\n' > boom.gd
printf '[gd_scene load_steps=2 format=3]\n\n[ext_resource type="Script" path="res://boom.gd" id="1"]\n\n[node name="Boom" type="Node"]\nscript = ExtResource("1")\n' > boom.tscn
printf 'extends Node\n\n\nfunc _ready() -> void:\n\twhile true:\n\t\tpass\n' > hang.gd
printf '[gd_scene load_steps=2 format=3]\n\n[ext_resource type="Script" path="res://hang.gd" id="1"]\n\n[node name="Hang" type="Node"]\nscript = ExtResource("1")\n' > hang.tscn
mkdir -p tests/sim
cat > tests/sim/calm.sim <<'EOF'
# no input: the hero stays on the ground
scene res://main.tscn
seed 7
frames 120
metric peak max <= 1 : $Hero.height
metric wob last >= 0 : $Hero.wobble * 1000
EOF
cat > tests/sim/jump.sim <<'EOF'
scene res://main.tscn
frames 200
metric peak max <= 5 : $Hero.height
10 press jump
30 release jump
EOF
cat > tests/sim/reach.sim <<'EOF'
scene res://main.tscn
frames 100000
metric peak max >= 3 : $Hero.height
1 press jump
EOF
cat > tests/sim/air.sim <<'EOF'
scene res://main.tscn
frames 1000
metric airborne pct <= 1 : $Hero.height > 0
2 press jump
EOF
cat > tests/sim/boom.sim <<'EOF'
scene res://boom.tscn
frames 20
EOF
git add -A 2>/dev/null; git commit -qm init

# ---- no engine needed ----
printf 'frames 10\n' > tests/sim/noscene.sim
expect "a scenario without a scene is red before any engine start" 'FAIL noscene: no scene line' "$("$WARMD" sim noscene 2>&1)"
printf 'scene res://gone.tscn\n' > tests/sim/gone.sim
expect "a scene that is not there is red before any engine start" 'FAIL gone: no scene res://gone.tscn' "$("$WARMD" sim tests/sim/gone.sim 2>&1)"
rm tests/sim/noscene.sim tests/sim/gone.sim
expect "an unknown scenario is named" 'FAIL no scenario nosuch' "$("$WARMD" sim nosuch 2>&1)"
expect "record wants a scene" 'warmd sim --record <scene' "$("$WARMD" sim --record 2>&1)"

GODOT="${WARMD_GODOT:-$(command -v godot 2>/dev/null || command -v godot4 2>/dev/null)}"
if [ -z "$GODOT" ]; then
  echo "skip engine part of tests/sim.sh: no Godot (CI job godot runs it)"
  rm -rf "$TMP" 2>/dev/null; exit $fails
fi

# ---- one engine start, one line per scenario ----
out="$("$WARMD" sim 2>&1)"; rc=$?
expect "every scenario runs in one engine start" 'FAIL sim: 2 of 5 green, 1 engine start' "$out"
[ "$rc" = 1 ] && echo "ok   a red scenario exits 1" || { echo "FAIL red scenarios exited $rc"; fails=$((fails+1)); }
expect "a green scenario is one line of metrics against limits" '^OK calm: peak 0 <= 1, wob [0-9.]+ >= 0 \(120 frames, seed 7\)$' "$out"
expect "a replayed input breaks its limit, early, at the deciding frame" '^FAIL jump: peak [0-9.]+ > 5 at frame 1[5-9] of 200 \(seed 1\)$' "$out"
expect "a limit decided green ends a long scenario at once" '^OK reach: peak [0-9.]+ >= 3 \(decided at frame [0-9] of 100000, seed 1\)$' "$out"
expect "a share proven too high is red before the end" '^FAIL air: airborne at least [0-9.]+% > 1% at frame [0-9]+ of 1000' "$out"
expect "a script error in the scene is red with file:line" '^FAIL boom: script error boom\.gd:10 ' "$out"
refuse "the script error belongs to its scenario only" '^(OK|FAIL) (calm|jump|reach|air):.*script error' "$out"
calm="$(echo "$out" | grep '^OK calm')"

# ---- cache: per scenario, seed in the key ----
out="$("$WARMD" sim 2>&1)"
expect "an unchanged run comes from the cache, no engine start" 'FAIL sim: 2 of 5 green, 5 cached, 0 engine starts' "$out"
expect "a cached green says so" '^OK calm: .*\(cached\)$' "$out"
expect "a cached red says so" '^FAIL jump: .*\(cached, code unchanged\)$' "$out"
printf 'metric still max <= 1 : $Hero.height\n' >> tests/sim/calm.sim
out="$("$WARMD" sim 2>&1)"
expect "an edited scenario reruns alone" '4 cached, 1 engine start' "$out"
git checkout -q tests/sim/calm.sim
out="$(WARMD_NOCACHE=1 "$WARMD" sim calm 2>&1)"
[ "$(echo "$out" | grep '^OK calm')" = "$calm" ] && echo "ok   the same seed gives the same metrics" || { echo "FAIL seed 7 again: $out vs $calm"; fails=$((fails+1)); }
out="$("$WARMD" sim --seed 8 calm 2>&1)"
expect "another seed is another key" 'OK sim: 1 of 1 green, 1 engine start' "$out"
expect "and gives other values" 'seed 8' "$out"
refuse "seed 8 is not seed 7's run" "^$(echo "${calm% (*}" | sed 's/[.[\*^$]/\\&/g') " "$out"
printf 'scene res://main.tscn\nisolate\nframes 5\n' > tests/sim/alone.sim
printf 'scene res://main.tscn\nframes 5\n' > tests/sim/other.sim
out="$("$WARMD" sim alone other 2>&1)"
expect "an isolated scenario gets an engine of its own" 'OK sim: 2 of 2 green, 2 engine starts' "$out"
expect "a scenario without metrics runs all its frames" '^OK other: no metric, 5 frames ran' "$out"
rm tests/sim/alone.sim tests/sim/other.sim

# ---- a hang or crash is red, never cached, and the rest goes on in a new engine ----
printf 'scene res://hang.tscn\nframes 5\n' > tests/sim/a_hang.sim
printf 'scene res://main.tscn\nframes 5\n' > tests/sim/after.sim
out="$(WARMD_SIM_TIMEOUT=20 "$WARMD" sim a_hang after 2>&1)"
expect "a hanging scenario is red with its cause" '^FAIL a_hang: the engine ended in this scenario \(timeout after 20s\)' "$out"
expect "the scenario after a hang runs in a new engine" 'OK after: .*FAIL sim: 1 of 2 green, 2 engine starts' "$(echo "$out" | tr '\n' ' ')"
expect "a hang is no cached verdict" 'the engine ended' "$(WARMD_SIM_TIMEOUT=20 "$WARMD" sim a_hang 2>&1)"
rm tests/sim/a_hang.sim tests/sim/after.sim
printf 'scene res://main.tscn\nmetric peak max <= : $Hero.height\n' > tests/sim/bad.sim
expect "a broken metric line names its line" '^FAIL bad: line 2: ' "$("$WARMD" sim bad 2>&1)"
printf 'scene res://main.tscn\n3 press fly\n' > tests/sim/bad.sim
expect "a replay of an unknown action is red" '^FAIL bad: line 2: no input action fly' "$("$WARMD" sim bad 2>&1)"
rm tests/sim/bad.sim

# ---- record: input per tick into a scenario file; the replay reproduces it as a red scenario ----
out="$(SIM_FEED=1 "$WARMD" sim --record main.tscn --headless --frames 40 --seed 3 --name rec 2>&1)"
expect "record writes a scenario file" 'OK recorded 40 frames, 2 inputs, seed 3 to tests/sim/rec.sim' "$out"
rec="$(tr -d '\r' < tests/sim/rec.sim 2>/dev/null)"
expect "the recording holds the scene and seed" 'scene res://main.tscn' "$rec"
expect "the recording holds the press per tick" '^[0-9]+ press jump$' "$rec"
expect "the recording holds the release per tick" '^[0-9]+ release jump$' "$rec"
expect "the recording ends with its frame count" '^frames 40$' "$(echo "$rec" | tail -1)"
expect "an existing recording is not overwritten" 'exists' "$("$WARMD" sim --record main.tscn --headless --frames 5 --name rec 2>&1)"
echo 'metric peak max <= 3 : $Hero.height' >> tests/sim/rec.sim
out="$("$WARMD" sim rec 2>&1)"
expect "the replayed recording is a red scenario without the scripted input" '^FAIL rec: peak [0-9.]+ > 3 at frame [0-9]+ of 40 \(seed 3\)' "$out"

echo
[ $fails = 0 ] && echo "sim all green" || echo "sim: $fails failed"
cd / && rm -rf "$TMP" 2>/dev/null
exit $fails
