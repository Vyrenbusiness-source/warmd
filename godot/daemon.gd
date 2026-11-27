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
# The files the engine's own output lands in (stdout, stderr), "|" between them: script errors are read back from there
var logs := OS.get_environment("WARMD_LOG").split("|", false)
# godot_allow_errors from warmd.conf: script errors it matches (as "file:line message") are noise, every other one is red
var allow := RegEx.new()
var allow_on := OS.get_environment("WARMD_ALLOW_ERRORS") != "" and allow.compile(OS.get_environment("WARMD_ALLOW_ERRORS")) == OK
var at_rx := RegEx.create_from_string("^\\s*at: .*\\((.+:\\d+)\\)\\s*$")
var ansi_rx := RegEx.create_from_string("\u001b\\[[0-9;]*[A-Za-z]")


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
	for line: String in out[1]:
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
			return await _test(str(job.get("filter", "")))
		"call":
			return await _call_script(str(job.get("script", "")))
	return [false, ["unknown job"]]


func _compile() -> Array:
	var bad: PackedStringArray = []
	var files := _scripts("res://")
	for path: String in files:
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
	for path: String in _scripts("res://"):
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
	var asserts := 0
	var red: PackedStringArray = []
	for path: String in _scripts("res://"):
		if not path.get_file().begins_with("test_"):
			continue
		var script: GDScript = ResourceLoader.load(path, "GDScript", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
		if script == null or not script.can_instantiate():
			red.append("RED %s does not load" % path.get_file())
			continue
		for m: Dictionary in script.get_script_method_list():
			var name: String = m["name"]
			if not name.begins_with("test_"):
				continue
			if filter != "" and rx.search(path.get_file().get_basename() + "." + name) == null:
				continue
			var t: Object = script.new()
			_write("current.txt", name)
			var node := t as Node
			if node != null:
				root.add_child(node)
			var failed := ""
			var mark := _log_marks()
			var result: Variant = await t.call(name)
			# A method that stops on a script error returns nothing, like one that ended: only the engine's output tells them apart
			var errs := _log_errors(mark)
			var fails: Array = t.get("failures") if t.get("failures") is Array else []
			var count: int = t.get("asserts") if t.get("asserts") is int else -1
			if not errs.is_empty():
				failed = "script error " + errs[0]
			elif not fails.is_empty():
				failed = str(fails[0])
			elif result is String:
				failed = result
			elif result is bool and not result:
				failed = "returned false"
			elif count == 0:
				failed = "no assert ran"
			if failed == "":
				passed += 1
				asserts += maxi(count, 0)
			else:
				red.append("RED %s: %s" % [name, failed])
			if node != null:
				node.queue_free()
			elif not (t is RefCounted):
				t.free()
	if passed == 0 and red.is_empty():
		return [false, ["0 tests ran (filter matches nothing?)"]]
	var lines: PackedStringArray = ["%d passed, %d failed, %d asserts" % [passed, red.size(), asserts]]
	lines.append_array(red)
	return [red.is_empty(), lines]


func _call_script(path: String) -> Array:
	var script: GDScript = ResourceLoader.load(path, "GDScript", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
	if script == null:
		return [false, ["cannot load %s" % path]]
	var obj: Object = script.new()
	var result: Variant = await obj.call("run")
	return [true, ["%s" % result]]


func _scripts(from: String) -> PackedStringArray:
	var found: PackedStringArray = []
	var d := DirAccess.open(from)
	if d == null:
		return found
	# Godot itself skips a folder holding .gdignore (raw assets, third-party code): its scripts are not part of the project
	if d.file_exists(".gdignore"):
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
	for line: String in FileAccess.get_file_as_string(dir.path_join("job.txt")).split("\n"):
		var at := line.find("=")
		if at > 0:
			job[line.substr(0, at)] = line.substr(at + 1).strip_edges()
	return job


## Where each engine log ends now: the start of what the next step prints.
func _log_marks() -> PackedInt64Array:
	var marks: PackedInt64Array = []
	for path: String in logs:
		var f := FileAccess.open(path, FileAccess.READ)
		marks.append(f.get_length() if f != null else -1)
	return marks


## The script errors the engine printed since the marks, as "file:line message".
## An addon's error is red like any other, unless the allowlist names it.
func _log_errors(marks: PackedInt64Array) -> PackedStringArray:
	var found: PackedStringArray = []
	for i: int in logs.size():
		if marks[i] < 0:
			continue
		var f := FileAccess.open(logs[i], FileAccess.READ)
		if f == null or f.get_length() <= marks[i]:
			continue
		f.seek(marks[i])
		var text := ansi_rx.sub(f.get_buffer(f.get_length() - marks[i]).get_string_from_utf8().replace("\r", ""), "", true)
		var lines := text.split("\n")
		for n: int in lines.size():
			if not lines[n].begins_with("SCRIPT ERROR:"):
				continue
			var msg := lines[n].trim_prefix("SCRIPT ERROR:").strip_edges()
			var hit: RegExMatch = at_rx.search(lines[n + 1]) if n + 1 < lines.size() else null
			var entry := msg if hit == null else "%s %s" % [hit.get_string(1).trim_prefix("res://"), msg]
			if allow_on and allow.search(entry) != null:
				continue
			if not found.has(entry):
				found.append(entry)
	return found


func _write(file: String, text: String) -> void:
	var f := FileAccess.open(dir.path_join(file), FileAccess.WRITE)
	if f != null:
		f.store_string(text)


func _remove(file: String) -> void:
	DirAccess.remove_absolute(dir.path_join(file))
