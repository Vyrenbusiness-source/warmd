extends SceneTree
## warmd daemon for Godot 4: takes jobs from job.txt, writes a short result.txt.
## Scripts load with the cache ignored on every job, so edits count without a restart.

const MAX_LINES := 14
var dir := OS.get_environment("WARMD_DIR")
var idle_ms := float(OS.get_environment("WARMD_IDLE_MIN") if OS.has_environment("WARMD_IDLE_MIN") else "30") * 60000.0
var last_job := Time.get_ticks_msec()
var next_beat := 0
var busy := false
var seen := {}


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	_write("pid.txt", str(OS.get_process_id()))
	if not FileAccess.get_file_as_string(dir.path_join("job.txt")).contains("quit_after"):
		_remove("job.txt")
	_write("state.txt", "phase=idle\n")
	_refresh()


func _process(_delta: float) -> bool:
	var now := Time.get_ticks_msec()
	if now >= next_beat:
		next_beat = now + 1000
		_write("alive.txt", str(int(Time.get_unix_time_from_system() * 1000.0)))
	if busy:
		return false
	if FileAccess.file_exists(dir.path_join("job.txt")):
		_take()
	elif now - last_job > idle_ms:
		_remove("alive.txt")
		_remove("pid.txt")
		return true
	return false


func _take() -> void:
	var job := _read_job()
	_remove("job.txt")
	var id: String = job.get("id", "")
	if id == "":
		return
	busy = true
	var start := Time.get_ticks_msec()
	_write("state.txt", "phase=%s\nid=%s\n" % [job.get("kind", ""), id])
	var out: Array = await _run(job)
	var seconds := (Time.get_ticks_msec() - start) / 1000
	var lines: PackedStringArray = ["%s %s %ds %s" % [id, "OK" if out[0] else "FAIL", seconds, job.get("kind", "")]]
	for line in out[1]:
		if lines.size() > MAX_LINES:
			break
		lines.append(line)
	_write("result.tmp", "\n".join(lines) + "\n")
	DirAccess.rename_absolute(dir.path_join("result.tmp"), dir.path_join("result.txt"))
	_write("state.txt", "phase=idle\nid=%s\n" % id)
	last_job = Time.get_ticks_msec()
	busy = false
	if job.get("kind", "") == "quit" or job.has("quit_after"):
		quit(0)


func _run(job: Dictionary) -> Array:
	match job.get("kind", ""):
		"ping":
			return [true, ["daemon alive, Godot %s" % Engine.get_version_info().string]]
		"quit":
			return [true, ["daemon stops"]]
		"compile":
			return _compile()
		"test":
			return await _test(job.get("filter", ""))
		"call":
			return await _call_script(job.get("script", ""))
	return [false, ["unknown job"]]


func _compile() -> Array:
	var bad: PackedStringArray = []
	var files := _scripts("res://")
	for path in files:
		var script := GDScript.new()
		script.source_code = FileAccess.get_file_as_string(path)
		script.resource_path = path
		if script.reload() != OK:
			bad.append("%s does not parse" % path.trim_prefix("res://"))
	if bad.is_empty():
		return [true, ["%d scripts parse" % files.size()]]
	return [false, bad]


## class_name scripts resolve to the cached instance, so a changed one has to reload in place.
func _refresh() -> void:
	for path in _scripts("res://"):
		var stamp := FileAccess.get_md5(path)   # file times have one-second steps, two quick edits look like none
		if seen.get(path, stamp) != stamp:
			var script: GDScript = load(path)
			script.source_code = FileAccess.get_file_as_string(path)
			script.reload(true)
		seen[path] = stamp


func _test(filter: String) -> Array:
	_refresh()
	var rx := RegEx.new()
	if filter != "" and rx.compile(filter) != OK:
		return [false, ["bad filter: %s" % filter]]
	var passed := 0
	var red: PackedStringArray = []
	for path in _scripts("res://"):
		if not path.get_file().begins_with("test_"):
			continue
		var script: GDScript = ResourceLoader.load(path, "GDScript", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
		if script == null or not script.can_instantiate():
			red.append("RED %s does not load" % path.get_file())
			continue
		for m in script.get_script_method_list():
			var name: String = m["name"]
			if not name.begins_with("test_"):
				continue
			if filter != "" and rx.search(path.get_file().get_basename() + "." + name) == null:
				continue
			var t: Object = script.new()
			_write("current.txt", name)
			if t is Node:
				root.add_child(t)
			var failed := ""
			var result: Variant = await t.call(name)
			if t.get("failures") != null and not t.get("failures").is_empty():
				failed = str(t.get("failures")[0])
			elif result is String:
				failed = result
			elif result is bool and not result:
				failed = "returned false"
			if failed == "":
				passed += 1
			else:
				red.append("RED %s: %s" % [name, failed])
			if t is Node:
				t.queue_free()
			elif not (t is RefCounted):
				t.free()
	if passed == 0 and red.is_empty():
		return [false, ["0 tests ran (filter matches nothing?)"]]
	var lines: PackedStringArray = ["%d passed, %d failed" % [passed, red.size()]]
	lines.append_array(red)
	return [red.is_empty(), lines]


func _call_script(path: String) -> Array:
	var script: GDScript = ResourceLoader.load(path, "GDScript", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
	if script == null:
		return [false, ["cannot load %s" % path]]
	var result: Variant = await script.new().call("run")
	return [true, ["%s" % result]]


func _scripts(from: String) -> PackedStringArray:
	var found: PackedStringArray = []
	var d := DirAccess.open(from)
	if d == null:
		return found
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		var path := from.path_join(name)
		if d.current_is_dir():
			if not name.begins_with(".") and name != "addons":
				found.append_array(_scripts(path))
		elif name.ends_with(".gd"):
			found.append(path)
		name = d.get_next()
	return found


func _read_job() -> Dictionary:
	var job := {}
	for line in FileAccess.get_file_as_string(dir.path_join("job.txt")).split("\n"):
		var at := line.find("=")
		if at > 0:
			job[line.substr(0, at)] = line.substr(at + 1).strip_edges()
	return job


func _write(file: String, text: String) -> void:
	var f := FileAccess.open(dir.path_join(file), FileAccess.WRITE)
	if f != null:
		f.store_string(text)


func _remove(file: String) -> void:
	DirAccess.remove_absolute(dir.path_join(file))
