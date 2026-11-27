extends SceneTree
## warmd peek for Godot: loads one scene, runs it for N frames, prints the node tree with chosen properties, quits.
## Reads WARMD_SCENE (res:// path), WARMD_FRAMES (default 10), WARMD_PEEK_NODES (default 80).
## Never saves: no ResourceSaver, no project settings, no editor. Every output line starts with "PEEK " so engine noise is easy to drop.

const LINE_MAX := 160
const VALUE_MAX := 40

var _left := 0


func _init() -> void:
	var path := OS.get_environment("WARMD_SCENE")
	var frames := int(OS.get_environment("WARMD_FRAMES")) if OS.get_environment("WARMD_FRAMES") != "" else 10
	_left = int(OS.get_environment("WARMD_PEEK_NODES")) if OS.get_environment("WARMD_PEEK_NODES") != "" else 80
	if path == "":
		path = ProjectSettings.get_setting("application/run/main_scene", "")
	if path == "":
		_fail("no scene given and no main scene set")
		return
	if not ResourceLoader.exists(path):
		_fail("no scene at %s" % path)
		return
	var packed = ResourceLoader.load(path)
	if not packed is PackedScene:
		_fail("%s is not a scene" % path)
		return
	var node: Node = packed.instantiate()
	if node == null:
		_fail("%s does not instantiate" % path)
		return
	root.add_child.call_deferred(node)
	_peek.call_deferred(node, path, maxi(frames, 0))


func _fail(msg: String) -> void:
	print("PEEK FAIL ", msg)
	quit(1)


func _peek(node: Node, path: String, frames: int) -> void:
	current_scene = node
	for i in frames:
		await process_frame
	var total := _count(node)
	print("PEEK == %s after %d frames, %d nodes" % [path, frames, total])
	_dump(node, 0)
	if total > _shown:
		print("PEEK ... %d more nodes, raise WARMD_PEEK_NODES" % (total - _shown))
	quit(0)


var _shown := 0


func _count(n: Node) -> int:
	var c := 1
	for k in n.get_children():
		c += _count(k)
	return c


# o is untyped on purpose: position, visible and is_playing exist only on some node types, through a typed Node they would not parse.
func _dump(n: Node, depth: int) -> void:
	if _shown >= _left:
		return
	_shown += 1
	var o = n
	var parts: PackedStringArray = ["  ".repeat(depth) + str(n.name), n.get_class()]
	if n is Node2D or n is Control or n is Node3D:
		parts.append("pos " + _short(o.position))
	if (n is CanvasItem or n is Node3D) and not o.visible:
		parts.append("hidden")
	if n is AnimationPlayer:
		parts.append("anim " + (str(o.current_animation) if o.is_playing() else "(stopped)"))
	elif n is AnimatedSprite2D or n is AnimatedSprite3D:
		parts.append("anim " + str(o.animation) + ("" if o.is_playing() else " (stopped)"))
	var s = n.get_script()
	if s is Script:
		parts.append("script " + (s.resource_path if s.resource_path != "" else "(built-in)"))
		for p in n.get_property_list():
			var u: int = p.get("usage", 0)
			if u & PROPERTY_USAGE_SCRIPT_VARIABLE and u & PROPERTY_USAGE_EDITOR:
				parts.append("%s=%s" % [p.name, _short(n.get(p.name))])
	var line := "  ".join(parts)
	if line.length() > LINE_MAX:
		line = line.substr(0, LINE_MAX - 3) + "..."
	print("PEEK ", line)
	for k in n.get_children():
		_dump(k, depth + 1)


func _short(v) -> String:
	var t: String
	if v is Vector2 or v is Vector3:
		t = str(v.snapped(Vector2.ONE * 0.01) if v is Vector2 else v.snapped(Vector3.ONE * 0.01))
	elif v is float:
		t = str(snappedf(v, 0.01))
	elif v is Resource and v.resource_path != "":
		t = v.resource_path
	elif v is Object:
		t = v.get_class()
	else:
		t = str(v)
	t = t.replace("\n", " ")
	return t if t.length() <= VALUE_MAX else t.substr(0, VALUE_MAX - 3) + "..."
