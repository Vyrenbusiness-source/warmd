#!/usr/bin/env bash
# Real engine test: needs Godot 4.3 or newer in WARMD_GODOT or on PATH.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
TMP="$(mktemp -d)"
export XDG_CACHE_HOME="$TMP/cache"
cd "$TMP" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
printf 'config_version=5\n[application]\nconfig/name="t"\n' > project.godot
printf '.warmd\n.godot\ncache\n' > .gitignore   # XDG_CACHE_HOME lies inside: its files would change the code key
printf 'class_name Score\nextends RefCounted\n\nstatic func add(a: int, b: int) -> int:\n\treturn a + b\n' > score.gd
"$WARMD" init > /dev/null
mkdir test
printf 'extends WarmdTest\n\nfunc test_add() -> void:\n\tassert_eq(Score.add(2, 3), 5)\n' > test/test_score.gd
git add -A; git commit -qm init
fails=0
expect() { if echo "$3" | grep -qE "$2"; then echo "ok   $1"; else echo "FAIL $1: $3"; fails=$((fails+1)); fi; }
refuse() { if echo "$3" | grep -qE "$2"; then echo "FAIL $1: $(echo "$3" | grep -E "$2" | head -1)"; fails=$((fails+1)); else echo "ok   $1"; fi; }
expect "compile" 'scripts parse' "$("$WARMD" build)"
# The first import writes .uid files (Godot 4.4), new files change the code key once: the build after them is the cached one
"$WARMD" build > /dev/null
expect "an unchanged compile is cached" 'OK cached, code unchanged' "$("$WARMD" build)"
expect "green test" '1 passed, 0 failed, 1 asserts' "$("$WARMD" test)"
# A runtime error ends only the test method, it returns like one that passed: the engine's output makes it red
printf 'extends WarmdTest\n\nfunc test_boom() -> void:\n\tassert_true(true)\n\tvar n: Object = null\n\tn.free()\n\tassert_true(true)\n' > test/test_boom.gd
expect "a runtime error in a test is red with file:line" 'RED test_boom: script error test/test_boom.gd:6 ' "$("$WARMD" test)"
printf 'godot_allow_errors=test_boom\\.gd:6\n' > warmd.conf
expect "an allowlisted script error is noise" '2 passed, 0 failed' "$("$WARMD" test)"
rm warmd.conf test/test_boom.gd
printf 'extends WarmdTest\n\nfunc test_empty() -> void:\n\tpass\n' > test/test_empty.gd
expect "a test without an assert is red" 'RED test_empty: no assert ran' "$("$WARMD" test)"
rm test/test_empty.gd
# A node made and never freed outlives the test: red with the count (debug build), the allowlist makes it noise
printf 'extends WarmdTest\n\nfunc test_leak() -> void:\n\tvar n := Node.new()\n\tn.name = "kept"\n\tassert_true(true)\n\nfunc test_freed() -> void:\n\tvar n := Node.new()\n\tn.queue_free()\n\tassert_true(true)\n' > test/test_leak.gd
out="$("$WARMD" test)"
expect "a leaked node is red with its count" 'RED test_leak: 1 orphan nodes left' "$out"
refuse "a queue_free node is no leak" 'RED test_freed' "$out"
printf 'godot_allow_errors=test_leak\\.gd: 1 orphan\n' > warmd.conf
expect "an allowlisted leak is noise" '3 passed, 0 failed' "$("$WARMD" test)"
rm warmd.conf test/test_leak.gd
sed -i.bak 's/a + b/a - b/' score.gd; rm score.gd.bak
expect "an edit counts in one-shot mode" 'RED test_add' "$("$WARMD" test)"
git checkout -q score.gd
printf 'class_name Fresh\nextends RefCounted\n\nstatic func one() -> int:\n\treturn 1\n' > fresh.gd
printf 'extends WarmdTest\n\nfunc test_fresh() -> void:\n\tassert_eq(Fresh.one(), 1)\n' > test/test_fresh.gd
expect "a new class_name works without a manual restart" '2 passed, 0 failed' "$("$WARMD" test)"
rm fresh.gd test/test_fresh.gd
# A merged branch moved a class_name script: the class cache still names the old path until it is renewed
mkdir lib; git mv score.gd lib/score.gd; git commit -qm move
expect "a moved class_name script compiles" 'scripts parse' "$("$WARMD" build)"
expect "its tests run after the move" '1 passed, 0 failed' "$("$WARMD" test)"
git mv lib/score.gd score.gd; git commit -qm back; rmdir lib
mkdir raw; touch raw/.gdignore; printf 'func broken(:\n' > raw/vendor.gd
expect "a .gdignore folder is skipped" 'scripts parse' "$("$WARMD" build)"
rm -rf raw
printf 'func broken(:\n' > bad.gd
expect "parse error is found with file:line" 'bad.gd:1 .*Error' "$("$WARMD" build)"
rm bad.gd
# The build loads and instantiates changed scenes and resources: dead paths, missing scripts, renamed methods are red
printf 'extends Control\n\nfunc _on_go_pressed() -> void:\n\tpass\n' > hud.gd
printf '[gd_scene load_steps=2 format=3]\n\n[ext_resource type="Script" path="res://hud.gd" id="1"]\n\n[node name="Hud" type="Control"]\nscript = ExtResource("1")\n\n[node name="Go" type="Button" parent="."]\n\n[connection signal="pressed" from="Go" to="." method="_on_go_pressed"]\n' > hud.tscn
expect "a changed scene that loads is green" 'scripts parse, 1 changed scenes and resources load' "$("$WARMD" build)"
git add hud.gd hud.tscn; git commit -qm hud
refuse "an unchanged scene is not loaded again" 'changed scenes' "$(WARMD_NOCACHE=1 "$WARMD" build)"
sed -i.bak 's/method="_on_go_pressed"/method="_on_go_renamed"/' hud.tscn; rm hud.tscn.bak
expect "a signal wired to a renamed method is red" 'hud\.tscn: .*_on_go_renamed' "$("$WARMD" build)"
expect "and its red is not cached" 'hud\.tscn: .*_on_go_renamed' "$("$WARMD" build)"
git checkout -q hud.tscn
printf '[gd_scene load_steps=2 format=3]\n\n[ext_resource type="Script" path="res://gone.gd" id="1"]\n\n[node name="Main" type="Node2D"]\nscript = ExtResource("1")\n' > lost.tscn
expect "a scene with a missing script is red" 'lost\.tscn: ' "$("$WARMD" build)"
rm lost.tscn
printf '[gd_scene load_steps=2 format=3]\n\n[ext_resource type="PackedScene" path="res://base_gone.tscn" id="1"]\n\n[node name="Kid" instance=ExtResource("1")]\n' > kid.tscn
expect "an inherited scene whose base is gone is red" 'kid\.tscn: ' "$("$WARMD" build)"
rm kid.tscn
printf '[gd_resource type="Resource" load_steps=2 format=3]\n\n[ext_resource type="Script" path="res://gone_data.gd" id="1"]\n\n[resource]\nscript = ExtResource("1")\n' > data.tres
expect "a resource with a dead path is red" 'data\.tres: ' "$("$WARMD" build)"
rm data.tres
git rm -q hud.gd hud.tscn; rm -f hud.gd.uid; git commit -qm "no hud"
# Strict typing: these warnings at level 2 in project.godot. GDScript.reload() has to fail on them, warmd's own scripts
# have to load under them.
cp project.godot project.godot.orig
printf '[debug]\ngdscript/warnings/untyped_declaration=2\ngdscript/warnings/unsafe_property_access=2\ngdscript/warnings/unsafe_method_access=2\ngdscript/warnings/unsafe_cast=2\ngdscript/warnings/unsafe_call_argument=2\n' >> project.godot
expect "strict typing: typed code compiles" 'scripts parse' "$("$WARMD" build)"
expect "strict typing: warmd's daemon and test class load" '1 passed, 0 failed' "$("$WARMD" test)"
printf 'extends RefCounted\n\nfunc loose(a):\n\tvar x = a\n\treturn x\n' > loose.gd
expect "strict typing: an untyped declaration is red with file:line" 'loose.gd:[0-9]+ ' "$("$WARMD" build)"
printf 'extends RefCounted\n\nfunc size_of(a: Variant) -> int:\n\treturn a.size()\n' > loose.gd
expect "strict typing: an unsafe method access is red with file:line" 'loose.gd:[0-9]+ ' "$("$WARMD" build)"
rm loose.gd
mv project.godot.orig project.godot
echo 'warm=1' > warmd.conf
expect "warm mode" '1 passed, 0 failed' "$(WARMD_NOCACHE=1 "$WARMD" test)"
sed -i.bak 's/a + b/a - b/' score.gd; rm score.gd.bak
expect "an edit reaches the warm engine" 'RED test_add' "$("$WARMD" test)"
git checkout -q score.gd
printf 'extends WarmdTest\n\nfunc test_boom() -> void:\n\tassert_true(true)\n\tvar n: Object = null\n\tn.free()\n' > test/test_boom.gd
expect "a runtime error in the warm engine is red with file:line" 'RED test_boom: script error test/test_boom.gd:6 ' "$(WARMD_NOCACHE=1 "$WARMD" test)"
rm test/test_boom.gd
# Two callers on one daemon: both get their own result, none overwrites the other's job
WARMD_NOCACHE=1 "$WARMD" test test_add > one.out 2>&1 &
p1=$!
WARMD_NOCACHE=1 "$WARMD" test test_add > two.out 2>&1 &
p2=$!
wait "$p1" "$p2"
expect "first of two parallel callers" '1 passed, 0 failed' "$(cat one.out)"
expect "second of two parallel callers" '1 passed, 0 failed' "$(cat two.out)"
rm -f one.out two.out
expect "stop" 'OK daemon stopped' "$("$WARMD" stop)"
# A project with its own SceneTree runners (tests/run_*.gd, quit(1) on failure) and no WarmdTest
R="$TMP/runners"; mkdir -p "$R/tests"; cd "$R" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
printf 'config_version=5
[application]
config/name="r"
' > project.godot
printf '.warmd
.godot
' > .gitignore
printf 'extends SceneTree

func _initialize() -> void:
	quit(0 if 2 + 3 == 5 else 1)
' > tests/run_math.gd
"$WARMD" init > /dev/null; git add -A; git commit -qm init
expect "own runners are found and run" 'OK .*test' "$(WARMD_NOCACHE=1 "$WARMD" test)"
sed -i.bak 's/== 5/== 6/' tests/run_math.gd; rm tests/run_math.gd.bak
expect "a failing runner is red" 'FAIL runner tests/run_math.gd' "$(WARMD_NOCACHE=1 "$WARMD" test)"
expect "a failing runner says its exit code" 'FAIL runner tests/run_math.gd \(exit 1\)' "$(WARMD_NOCACHE=1 "$WARMD" test)"
printf 'extends SceneTree

func _initialize() -> void:
	print("ALL OK")
	quit(1)
' > tests/run_late.gd
expect "a runner failing after ALL OK says so" 'run_late.gd \(exit 1 after success output\)' "$(WARMD_NOCACHE=1 "$WARMD" test)"
rm tests/run_late.gd
git checkout -q tests/run_math.gd
printf 'extends SceneTree\n\nfunc _initialize() -> void:\n\tvar x := \n\tquit(0)\n' > tests/run_broken.gd
expect "a runner that does not parse is red" 'FAIL runner tests/run_broken.gd' "$("$WARMD" test)"
expect "and its red is not cached as green" 'FAIL runner tests/run_broken.gd' "$("$WARMD" test)"
rm tests/run_broken.gd
# A runtime error ends only the function it happens in: the runner still quits with 0, its output makes it red
printf 'extends SceneTree\n\nfunc _initialize() -> void:\n\tboom()\n\tquit(0)\n\nfunc boom() -> void:\n\tvar n: Object = null\n\tn.free()\n' > tests/run_err.gd
expect "a runner with a script error and exit 0 is red with file:line" 'FAIL runner tests/run_err.gd script error tests/run_err.gd:9 ' "$(WARMD_NOCACHE=1 "$WARMD" test)"
cp warmd.conf warmd.conf.orig 2>/dev/null; printf 'godot_allow_errors=run_err\\.gd\n' >> warmd.conf
expect "an allowlisted runner error passes" '2 runners passed|OK .*test' "$(WARMD_NOCACHE=1 "$WARMD" test)"
if [ -f warmd.conf.orig ]; then mv warmd.conf.orig warmd.conf; else rm warmd.conf; fi
rm tests/run_err.gd
# All runners in one engine start: awaits, timers and nodes work as a guest, the order comes from a printed seed
printf 'extends SceneTree\n\nfunc _initialize() -> void:\n\tawait create_timer(0.2).timeout\n\tawait process_frame\n\troot.add_child(Node.new())\n\tquit(0)\n' > tests/run_wait.gd
printf 'extends SceneTree\n\nvar frames := 0\n\nfunc _process(_delta: float) -> bool:\n\tframes += 1\n\treturn frames >= 3\n' > tests/run_frames.gd
WARMD_NOCACHE=1 "$WARMD" test > /dev/null; log="$(tr -d '\r' < .warmd/run/last.log)"
expect "three runners share one engine" '3 runners passed \(3 in one engine, 0 alone\)' "$log"
expect "one engine start for all of them" '^1$' "$(printf '%s\n' "$log" | grep -c '^Godot Engine v')"
expect "the order's seed is printed" 'runner order from seed [0-9]+, WARMD_SEED=[0-9]+ replays it' "$log"
WARMD_SEED=4 "$WARMD" test > /dev/null; one="$(tr -d '\r' < .warmd/run/last.log | grep '^== ')"
WARMD_SEED=4 "$WARMD" test > /dev/null; two="$(tr -d '\r' < .warmd/run/last.log | grep '^== ')"
expect "WARMD_SEED replays the order" '^same$' "$([ -n "$one" ] && [ "$one" = "$two" ] && echo same || printf 'differs: %s | %s' "$one" "$two")"
printf '# warmd: isolate\nextends SceneTree\n\nfunc _initialize() -> void:\n\tquit(0)\n' > tests/run_solo.gd
printf 'extends SceneTree\n\nfunc _initialize() -> void:\n\tprint(debug_collisions_hint)\n\tquit(0)\n' > tests/run_odd.gd
WARMD_NOCACHE=1 "$WARMD" test > /dev/null; log="$(tr -d '\r' < .warmd/run/last.log)"
expect "an isolate runner gets its own engine" '^== tests/run_solo\.gd \(own engine\)' "$log"
expect "a runner the guest host cannot compile gets its own engine" 'runner tests/run_odd\.gd gets its own engine' "$log"
expect "and every runner still counts" '5 runners passed \(3 in one engine, 2 alone\)' "$log"
rm tests/run_wait.gd tests/run_frames.gd tests/run_solo.gd tests/run_odd.gd
# A guest that never quits is timed out inside the engine, the others keep their verdicts
printf 'extends SceneTree\n# warmd: timeout=3\n\nfunc _initialize() -> void:\n\twhile true:\n\t\tawait process_frame\n' > tests/run_hang.gd
expect "a hanging guest is red with its timeout" 'FAIL runner tests/run_hang\.gd \(timeout after 3s\)' "$(WARMD_NOCACHE=1 "$WARMD" test; tr -d '\r' < .warmd/run/last.log)"
rm tests/run_hang.gd
# A crash ends the shared engine: the crashed runner is red by name, the others are judged in a new engine
printf 'extends SceneTree\n\nfunc _initialize() -> void:\n\tOS.crash("warmd test crash")\n' > tests/run_crash.gd
printf 'extends SceneTree\n\nfunc _initialize() -> void:\n\tquit(1)\n' > tests/run_bad.gd
for seed in 4 2; do   # seed 4 runs the crash first, seed 2 last
  log="$(WARMD_SEED=$seed WARMD_NOCACHE=1 "$WARMD" test; tr -d '\r' < .warmd/run/last.log)"
  expect "seed $seed: the crashed runner is named" 'FAIL runner tests/run_crash\.gd \(.*the shared engine ended in it\)' "$log"
  expect "seed $seed: a red runner beside the crash stays red" 'FAIL runner tests/run_bad\.gd \(exit 1\)' "$log"
  refuse "seed $seed: no green after a crash" 'runners passed' "$log"
done
expect "after a crash first, the rest run in a new engine" '^2$' "$(WARMD_SEED=4 WARMD_NOCACHE=1 "$WARMD" test > /dev/null; tr -d '\r' < .warmd/run/last.log | grep -c '^Godot Engine v')"
rm tests/run_crash.gd tests/run_bad.gd
# A runner that keeps a node out of the tree leaks it: in the shared engine red with the count, alone red at exit
printf 'extends SceneTree\n\nvar keep: Node\n\nfunc _initialize() -> void:\n\tkeep = Node.new()\n\tquit(0)\n' > tests/run_leak.gd
expect "a runner leaking a node in the shared engine is red with its count" 'FAIL runner tests/run_leak\.gd 1 orphan nodes left' "$(WARMD_NOCACHE=1 "$WARMD" test)"
printf '# warmd: isolate\nextends SceneTree\n\nvar keep: Node\n\nfunc _initialize() -> void:\n\tkeep = Node.new()\n\tquit(0)\n' > tests/run_leak.gd
expect "a runner leaking a node in its own engine is red at exit" 'FAIL runner tests/run_leak\.gd leaks at exit' "$(WARMD_NOCACHE=1 "$WARMD" test)"
rm tests/run_leak.gd
# A runner whose extends line carries class_name is found too; no test of any kind is a WARN, never a silent green
printf 'class_name RunnerB extends SceneTree\n\nfunc _initialize() -> void:\n\tquit(1)\n' > tests/run_cn.gd
expect "a runner with class_name before extends is found" 'FAIL runner tests/run_cn.gd' "$(WARMD_NOCACHE=1 "$WARMD" test)"
rm tests/run_cn.gd tests/run_math.gd
expect "no test of any kind is a WARN, not green" 'WARN no tests found' "$(WARMD_NOCACHE=1 "$WARMD" test)"
# warmd peek: the scene runs N frames headless, its node tree comes back as text, nothing is saved
P="$TMP/peek"; mkdir -p "$P"; cd "$P" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
printf 'config_version=5\n[application]\nconfig/name="p"\n' > project.godot
printf '.warmd\n.godot\n' > .gitignore
printf 'extends Node2D\n' > main.gd
printf 'extends Node2D\n\n@export var speed := 120.0\n' > mover.gd
printf '[gd_scene load_steps=3 format=3]\n\n[ext_resource type="Script" path="res://main.gd" id="1"]\n[ext_resource type="Script" path="res://mover.gd" id="2"]\n\n[node name="Main" type="Node2D"]\nscript = ExtResource("1")\n\n[node name="Mover" type="Node2D" parent="."]\nscript = ExtResource("2")\n' > main.tscn
"$WARMD" init > /dev/null; "$WARMD" build > /dev/null   # the import writes .uid files: they are committed, peek must add none
git add -A; git commit -qm init
out="$("$WARMD" peek main.tscn 5 2>&1)"
expect "peek" '^== res://main\.tscn after 5 frames' "$out"
expect "peek shows the exported var" 'speed=120' "$out"
expect "peek saves nothing" '^clean$' "$(s="$(git status --porcelain | grep -vE '^\?\? \.(godot|warmd)/')"; [ -z "$s" ] && echo clean || echo "$s")"
# Ship checks: warmd doctor, export smoke (warmd package), golden shots, budgets at merge
G="${WARMD_GODOT:-godot}"
S="$TMP/ship"; mkdir -p "$S"; cd "$S" || exit 1
git init -q -b main .; git config user.name t; git config user.email t@example.com
printf 'config_version=5\n[application]\nconfig/name="s"\nrun/main_scene="res://main.tscn"\nconfig/features=PackedStringArray("4.4")\n' > project.godot
printf '.warmd\n.godot\n' > .gitignore
printf 'extends Node2D\n\nfunc _ready() -> void:\n\tprint("main ready")\n' > main.gd
printf '[gd_scene load_steps=2 format=3]\n\n[ext_resource type="Script" path="res://main.gd" id="1"]\n\n[node name="Main" type="Node2D"]\nscript = ExtResource("1")\n\n[node name="Box" type="ColorRect" parent="."]\noffset_right = 200.0\noffset_bottom = 120.0\ncolor = Color(1, 0, 0, 1)\n' > main.tscn
printf '[preset.0]\n\nname="Windows Desktop"\nplatform="Windows Desktop"\nrunnable=true\nexport_filter="all_resources"\ninclude_filter=""\nexclude_filter=""\nexport_path=""\n\n[preset.0.options]\n' > export_presets.cfg
# Images for golden and budget checks, made by the engine: a.png, b.png (an 8x4 patch differs), big.png 600x300
printf 'extends SceneTree\n\nfunc _init() -> void:\n\tvar a := Image.create(64, 64, false, Image.FORMAT_RGBA8)\n\ta.fill(Color.RED)\n\ta.save_png("res://.warmd/a.png")\n\ta.fill_rect(Rect2i(10, 20, 8, 4), Color.BLUE)\n\ta.save_png("res://.warmd/b.png")\n\tvar big := Image.create(600, 300, false, Image.FORMAT_RGBA8)\n\tbig.fill(Color.GREEN)\n\tbig.save_png("res://.warmd/big.png")\n\tquit(0)\n' > .warmd_mk.gd
mkdir -p .warmd; "$G" --headless --path "$S" --script res://.warmd_mk.gd > /dev/null 2>&1; rm -f .warmd_mk.gd
"$WARMD" init > /dev/null; "$WARMD" build > /dev/null   # the import writes .uid files: they are committed
git add -A; git commit -qm init
out="$("$WARMD" doctor)"
expect "doctor: .godot ignored" '^ok \.godot/ ignored' "$out"
expect "doctor: .uid and .import versioned" '^ok \.uid and \.import files versioned' "$out"
expect "doctor: the engine matches the pinned version" '^ok Godot 4\.4[^ ]* matches the pin 4\.4 \(config/features' "$out"
touch extra.gd.uid
expect "doctor: an unversioned .uid is an error" '^ERROR 1 \.uid/\.import files not versioned \(extra\.gd\.uid\)' "$("$WARMD" doctor)"
rm extra.gd.uid
printf '.warmd\n' > .gitignore
expect "doctor: .godot not ignored is an error" '^ERROR \.godot/ is not ignored' "$("$WARMD" doctor)"
git checkout -q .gitignore
echo 'godot_version=3.5' > warmd.conf
expect "doctor: another engine than the pin is an error" '^ERROR Godot 4\.4[^ ]* is not the pinned 3\.5 \(godot_version' "$("$WARMD" doctor)"
rm warmd.conf; cp project.godot project.godot.orig; sed -i.bak '/config\/features/d' project.godot; rm project.godot.bak
expect "doctor: no pin is an error" '^ERROR Godot version not pinned' "$("$WARMD" doctor)"
mv project.godot.orig project.godot
out="$("$WARMD" package)"; echo "info: $(echo "$out" | tail -1)"
expect "export smoke: the exported build starts" '^OK export smoke: "Windows Desktop" exported' "$out"
printf 'extends Node2D\n\nfunc _ready() -> void:\n\tvar n: Object = null\n\tn.free()\n' > main.gd
expect "export smoke: a script error in the exported build is red" '^FAIL export smoke: the exported build .* has errors' "$("$WARMD" package)"
git checkout -q main.gd
# Golden: the comparison as text, never a silent new reference
expect "golden: no reference is red, never made by itself" 'FAIL golden: no reference for main' "$("$WARMD" shot main.tscn --golden --from .warmd/a.png)"
expect "golden: --golden-update makes the reference" '^OK golden reference for main' "$("$WARMD" shot main.tscn --golden-update --from .warmd/a.png)"
expect "golden: the same image is SAME" '^SAME$' "$("$WARMD" shot main.tscn --golden --from .warmd/a.png)"
expect "golden: a changed patch is a DIFF with its region" '^DIFF 0\.8% in region 10,20,8,4$' "$("$WARMD" shot main.tscn --golden --from .warmd/b.png)"
expect "golden: a DIFF does not renew the reference" '^DIFF 0\.8%' "$("$WARMD" shot main.tscn --golden --from .warmd/b.png)"
echo 'golden_tolerance=1' > warmd.conf
expect "golden: within the tolerance is SAME with the share" '^SAME \(0\.8% differs in region 10,20,8,4' "$("$WARMD" shot main.tscn --golden --from .warmd/b.png)"
rm warmd.conf
# A real shot: rendered where the machine has graphics, else a red that says what it needs
out="$("$WARMD" shot --golden-update 2>&1)"; echo "info: rendered shot: $(echo "$out" | tail -1)"
if echo "$out" | grep -q '^OK golden reference'; then
  expect "golden: a rendered shot matches its own reference" '^SAME' "$("$WARMD" shot --golden)"
  rendered=1
else
  expect "golden: no image says it needs graphics" 'FAIL golden: the engine gave no image.*WARMD_GFX=1' "$out"
  rendered=0
fi
# Budgets at merge (WARMD_BUDGET=1 here): changed textures and per-scene numbers against warmd.conf
git checkout -q -b feat; cp .warmd/big.png big.png; "$G" --headless --path "$S" --import > /dev/null 2>&1
git add -A; git commit -qm big
expect "a texture import was written" '^yes$' "$([ -f big.png.import ] && echo yes || echo no)"
echo 'budget_texture_px=256' > warmd.conf
expect "budget: a texture over budget_texture_px is red" 'FAIL budget: texture big\.png 600x300 \(lossless\) is over budget_texture_px=256' "$(WARMD_BUDGET=1 WARMD_NOCACHE=1 "$WARMD" check)"
printf 'budget_texture_px=1024\nbudget_texture_raw_px=256\n' > warmd.conf
expect "budget: a big texture stored lossless is red" 'FAIL budget: texture big\.png 600x300 is stored lossless' "$(WARMD_BUDGET=1 WARMD_NOCACHE=1 "$WARMD" check)"
printf 'budget_texture_px=1024\nbudget_main=nodes=1,memory_mb=4000\n' > warmd.conf
expect "budget: a scene over its node budget is red" 'FAIL budget_main: nodes 2 is over 1' "$(WARMD_BUDGET=1 WARMD_NOCACHE=1 "$WARMD" check)"
printf 'budget_texture_px=1024\nbudget_main=nodes=10,memory_mb=4000\n' > warmd.conf
expect "budget: kept budgets are green" 'OK budgets kept' "$(WARMD_BUDGET=1 WARMD_NOCACHE=1 "$WARMD" check)"
refuse "budget: only with WARMD_BUDGET or in a merge" 'budgets kept|FAIL budget' "$(WARMD_NOCACHE=1 "$WARMD" check)"
if [ $rendered = 1 ]; then
  printf 'budget_main=draw_calls=1000\nrendered_smoke=1\n' > warmd.conf
  expect "budget: a rendered run measures draw calls" 'OK budgets kept' "$(WARMD_BUDGET=1 WARMD_NOCACHE=1 "$WARMD" check)"
fi
rm -f warmd.conf
cd "$TMP" || exit 1
rm -rf "$TMP" 2>/dev/null
exit $fails
