#!/usr/bin/env bash
# warmd where: symbol index of a Godot project, the feature map (synonyms, comment tags, notes), cache by file hash,
# and the changes an answer names (moved, changed signature, gone) since the last read or a git state.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMD="$HERE/bin/warmd"
TMP="$(mktemp -d)"
export XDG_CACHE_HOME="$TMP/cache"
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails+1)); }
expect() { if printf '%s\n' "$3" | grep -qE -- "$2"; then ok "$1"; else no "$1: wanted /$2/, got: $(printf '%s\n' "$3" | head -6)"; fi; }
refuse() { if printf '%s\n' "$3" | grep -qE -- "$2"; then no "$1: found /$2/"; else ok "$1"; fi; }

G="$TMP/game"; mkdir -p "$G/player" "$G/weapons" "$G/enemies"; cd "$G" || exit 1
git init -q -b main .; git config core.autocrlf false; git config user.name t; git config user.email t@example.com
cat > project.godot <<'EOF'
config_version=5

[autoload]

Score="*res://score.gd"

[input]

move_left={
"deadzone": 0.5
}
jump={
"deadzone": 0.5
}
EOF
cat > player/movement.gd <<'EOF'
extends CharacterBody2D
class_name Player

signal landed(height: float)

@export var speed: float = 120.0

func _physics_process(delta: float) -> void:
	walk(delta)

func walk(delta: float) -> void:
	velocity.x = Input.get_axis("move_left", "move_right") * speed
EOF
cat > weapons/gun.gd <<'EOF'
extends Node2D

func fire(direction: Vector2) -> void:
	pass

func reload() -> void:
	pass
EOF
cat > enemies/brain.gd <<'EOF'
extends Node

func _ready() -> void:
	add_to_group("mobs")

# warmd: feature=gegner,widersacher
func think() -> void:
	pass
EOF
cat > score.gd <<'EOF'
extends Node
var points := 0
EOF
cat > main.tscn <<'EOF'
[gd_scene load_steps=3 format=3 uid="uid://abc"]

[ext_resource type="Script" uid="uid://x1" path="res://player/movement.gd" id="1_mv"]
[ext_resource type="Script" path="res://weapons/gun.gd" id="2_gun"]

[node name="Main" type="Node2D"]

[node name="Hero" type="CharacterBody2D" parent="." groups=["actors"]]
script = ExtResource("1_mv")

[node name="Gun" type="Node2D" parent="Hero"]
script = ExtResource("2_gun")
EOF
cat > Health.cs <<'EOF'
using Godot;

public partial class Health : Node
{
    [Signal]
    public delegate void DiedEventHandler();

    [Export] public int MaxHealth { get; set; } = 100;

    public void TakeDamage(int amount)
    {
    }
}
EOF
git add -A; git commit -qm init

out="$("$WARMD" where laufen)"; rc=$?
expect "German term finds the movement function" '^player/movement\.gd:11  func walk\(delta: float\) -> void$' "$out"
expect "German term finds the input action" '^project\.godot:9  input move_left$' "$out"
expect "German term finds the scene node with the script" '^main\.tscn:8  node Main/Hero \(CharacterBody2D\) script player/movement\.gd$' "$out"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -le 5 ] && [ $rc = 0 ] && ok "at most five lines, exit 0" || no "lines/rc: $rc $out"
refuse "first answer names no changes" '^(moved|changed|gone|added|new):' "$out"

expect "synonym projektile finds the gun" '^weapons/gun\.gd:3  func fire\(direction: Vector2\) -> void$' "$("$WARMD" where projektile)"
expect "comment tag with its own synonym" '^enemies/brain\.gd:7  func think\(\) -> void  \[feature gegner,widersacher\]$' "$("$WARMD" where widersacher)"
expect "group from add_to_group" '^enemies/brain\.gd:4  add_to_group mobs$' "$("$WARMD" where mobs)"
expect "group from a scene node" '^main\.tscn:8  group actors on Main/Hero$' "$("$WARMD" where actors)"
expect "signal and export" 'player/movement\.gd:4  signal landed\(height: float\)' "$("$WARMD" where landed)"
expect "autoload" '^project\.godot:5  autoload Score score\.gd$' "$("$WARMD" where Score)"
out="$("$WARMD" where schaden)"
expect "C# method by German synonym" '^Health\.cs:10  public void TakeDamage\(int amount\)$' "$out"
expect "C# export and signal" 'Health\.cs:8  .*MaxHealth' "$("$WARMD" where MaxHealth)"
expect "C# signal without EventHandler" '^Health\.cs:6  public delegate void DiedEventHandler\(\);$' "$("$WARMD" where Died)"
out="$("$WARMD" where zzqx)"; rc=$?
[ $rc = 1 ] && expect "no match says so, exit 1" "^no place for 'zzqx' in 7 files" "$out" || no "no match rc $rc: $out"

# ---- index in the git dir, never in the work tree; an unchanged file is not read again ----
IDX="$(git rev-parse --absolute-git-dir)/warmd-where/index.tsv"
[ -s "$IDX" ] && [ -z "$(git status --porcelain)" ] && ok "index in the git dir, work tree clean" || no "index: $(ls "${IDX%/*}" 2>&1) $(git status --porcelain)"
sed -i 's/\tfunc\treload\t/\tfunc\tcachedreload\t/' "$IDX"
expect "unchanged file comes from the index" '^weapons/gun\.gd:6' "$("$WARMD" where cachedreload)"
printf '\n' >> weapons/gun.gd
refuse "changed file is read again" '^weapons/gun' "$("$WARMD" where cachedreload)"
git checkout -q weapons/gun.gd; "$WARMD" where gun >/dev/null

# ---- changes since the last read: moved, changed signature, gone ----
mkdir -p combat
printf 'extends Node\n\n# cooldown between shots\nvar cooldown := 0.2\n\nfunc fire(direction: Vector2, power: float) -> void:\n\tpass\n' > combat/spawner.gd
printf 'extends Node2D\n\nfunc reload(fast: bool) -> void:\n\tpass\n' > weapons/gun.gd
sed -i 's/^signal landed.*/# landed is gone/' player/movement.gd
out="$("$WARMD" where projectile)"
expect "answer finds the moved function" '^combat/spawner\.gd:6  func fire\(direction: Vector2, power: float\) -> void$' "$out"
expect "answer names the move" '^moved: func fire weapons/gun\.gd -> combat/spawner\.gd:6$' "$out"
expect "answer names a changed signature" '^changed: weapons/gun\.gd:3 func reload\(fast: bool\) -> void  was func reload\(\) -> void$' "$out"
expect "answer names a gone symbol" '^gone: signal landed \(was player/movement\.gd:4\)$' "$out"
out="$("$WARMD" where projectile)"
refuse "the next answer names them no more" '^(moved|changed|gone):' "$out"
expect "--changed since the last read" '^OK no changes since your last warmd where$' "$("$WARMD" where --changed)"
out="$("$WARMD" where --changed HEAD)"
expect "--changed <ref> names the move" '^moved: func fire weapons/gun\.gd -> combat/spawner\.gd:6$' "$out"
expect "--changed <ref> names the new file" '^new: combat/spawner\.gd \(1 symbols\)$' "$out"
expect "--changed <ref> names the signature" '^changed: weapons/gun\.gd:3' "$out"
git add -A; git commit -qm move
git mv combat/spawner.gd combat/launcher.gd; git commit -qm rename
expect "--changed names a renamed file" '^moved: combat/spawner\.gd -> combat/launcher\.gd$' "$("$WARMD" where --changed HEAD~1)"
expect "bad ref fails" '^FAIL nope is no git state' "$("$WARMD" where --changed nope)"

# ---- notes: bound to the file hash, re-resolved through their symbol, else marked stale ----
BRIEF="$(git rev-parse --path-format=absolute --git-common-dir)/warmd-shared.md"
printf '# Shared brief\n\n## Findings\n- t1: fire timing lives in combat/launcher.gd:7\n- t2: the cooldown var sits in combat/launcher.gd:4\n' > "$BRIEF"
expect "note names its place" '^combat/launcher\.gd:7  note: fire timing lives in combat/launcher\.gd:7$' "$("$WARMD" where timing)"
printf 'extends Node\n\n\n\n# cooldown between shots\nvar cooldown := 0.2\n\nfunc fire(direction: Vector2, power: float) -> void:\n\tpass\n' > combat/launcher.gd
expect "changed file: note re-resolved through its symbol" '^combat/launcher\.gd:8  note: fire timing .*\(file changed, found func fire again\)$' "$("$WARMD" where timing)"
printf 'extends Node\n\nfunc shoot() -> void:\n\tpass\n' > combat/launcher.gd
expect "symbol gone: note marked stale" '^combat/launcher\.gd:7  STALE note: fire timing .*func fire is gone' "$("$WARMD" where timing)"
git checkout -q combat/launcher.gd
git mv combat/launcher.gd weapons/launcher.gd
expect "moved file: note follows the symbol" '^weapons/launcher\.gd:6  note: fire timing .*\(moved from combat/launcher\.gd\)$' "$("$WARMD" where timing)"
FEAT="${BRIEF%/*}/warmd-where-features.tsv"
[ "$(grep -c 'fire timing' "$FEAT")" = 1 ] && ok "a note is stored once" || no "feature rows: $(cat "$FEAT")"

# ---- command wiring ----
expect "help lists where" 'warmd where <term>' "$("$WARMD" --help)"
expect "help lists peek" 'warmd peek <scene> \[frames\]' "$("$WARMD" --help)"
grep -q '^  peek)    \. "\$WARMD_HOME/lib/map\.sh"; scene_peek "\$@";;' "$WARMD" && ok "peek dispatches to scene_peek" || no "no peek dispatch in bin/warmd"

rm -rf "$TMP" 2>/dev/null
[ $fails = 0 ] && echo "where green" || echo "where: $fails failed"
exit $fails
