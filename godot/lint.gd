extends SceneTree
## warmd lint for Godot: confirms string lint candidates against the running engine, prints a verdict per candidate, quits.
## Reads WARMD_LINT_IN, one candidate per line: "<kind>\t<value>". Kinds: action (InputMap), autoload (ProjectSettings),
## tr (the project's translations), res (ResourceLoader, FileAccess, DirAccess).
## Prints "LINT <kind>\t<value>\t<ok|missing|unknown>" per candidate, then "LINT END". unknown: the engine cannot decide.
## Never saves: no ResourceSaver, no project settings, no editor.

var _translations: Array = []
var _translations_read := false


func _init() -> void:
	var path := OS.get_environment("WARMD_LINT_IN")
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		print("LINT FAIL cannot read %s" % path)
		quit(1)
		return
	while not f.eof_reached():
		var line := f.get_line().strip_edges(false, true)
		if line == "":
			continue
		var parts := line.split("\t")
		if parts.size() < 2:
			continue
		print("LINT %s\t%s\t%s" % [parts[0], parts[1], _verdict(parts[0], parts[1])])
	print("LINT END")
	quit(0)


func _verdict(kind: String, value: String) -> String:
	match kind:
		"action":
			if InputMap.has_action(StringName(value)) or ProjectSettings.has_setting("input/" + value):
				return "ok"
			return "missing"
		"autoload":
			return "ok" if ProjectSettings.has_setting("autoload/" + value) else "missing"
		"tr":
			return _tr_verdict(value)
		"res":
			if ResourceLoader.exists(value) or FileAccess.file_exists(value) or DirAccess.dir_exists_absolute(value):
				return "ok"
			return "missing"
	return "unknown"


# A key is missing only when at least one translation loads and none of them knows it.
func _tr_verdict(key: String) -> String:
	if not _translations_read:
		_translations_read = true
		var paths = ProjectSettings.get_setting("internationalization/locale/translations", PackedStringArray())
		for p in paths:
			if not ResourceLoader.exists(p):
				continue
			var t = ResourceLoader.load(p)
			if t is Translation:
				_translations.append(t)
	if _translations.is_empty():
		return "unknown"
	for t in _translations:
		if String(t.get_message(StringName(key))) != "":
			return "ok"
	return "missing"
