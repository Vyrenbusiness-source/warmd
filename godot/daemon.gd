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
var engine_rx := RegEx.create_from_string("^(USER )?ERROR:")
# A runner (extends SceneTree) becomes a guest of this engine: its extends line names RefCounted, GUEST_HOST adds the
# SceneTree members it uses at the end. One that uses a member the host lacks does not compile as a guest and gets an
# engine of its own, so a gap costs time, never a verdict. The extends line keeps its place: error lines stay true.
var guest_rx := RegEx.create_from_string("(?m)^((?:@tool[ \\t]+)?)(?:class_name[ \\t]+\\w+[ \\t]+)?extends[ \\t]+SceneTree\\b")
var class_rx := RegEx.create_from_string("(?m)^class_name[ \\t]+\\w+[ \\t]*$")
var indent_rx := RegEx.create_from_string("(?m)^([ \\t]+)\\S")
var success_rx := RegEx.create_from_string("(?m)^(ALL OK|=== .* 0 fehlgeschlagen ===|FAILED: 0)")
const GUEST_HOST: Array[String] = [
	"",
	"# ---- warmd: SceneTree members for a runner that shares one engine with other runners ----",
	"var __warmd_quit: bool = false",
	"var __warmd_code: int = 0",
	"func __warmd_tree() -> SceneTree:",
	"\treturn Engine.get_main_loop() as SceneTree",
	"func quit(exit_code: int = 0) -> void:",
	"\t__warmd_code = exit_code",
	"\t__warmd_quit = true",
	"var root: Window:",
	"\tget:",
	"\t\treturn __warmd_tree().root",
	"func get_root() -> Window:",
	"\treturn __warmd_tree().root",
	"var current_scene: Node:",
	"\tget:",
	"\t\treturn __warmd_tree().current_scene",
	"\tset(value):",
	"\t\t__warmd_tree().current_scene = value",
	"var paused: bool:",
	"\tget:",
	"\t\treturn __warmd_tree().paused",
	"\tset(value):",
	"\t\t__warmd_tree().paused = value",
	"var auto_accept_quit: bool:",
	"\tget:",
	"\t\treturn __warmd_tree().auto_accept_quit",
	"\tset(value):",
	"\t\t__warmd_tree().auto_accept_quit = value",
	"var process_frame: Signal:",
	"\tget:",
	"\t\treturn __warmd_tree().process_frame",
	"var physics_frame: Signal:",
	"\tget:",
	"\t\treturn __warmd_tree().physics_frame",
	"var node_added: Signal:",
	"\tget:",
	"\t\treturn __warmd_tree().node_added",
	"var node_removed: Signal:",
	"\tget:",
	"\t\treturn __warmd_tree().node_removed",
	"var tree_changed: Signal:",
	"\tget:",
	"\t\treturn __warmd_tree().tree_changed",
	"func create_timer(time_sec: float, process_always: bool = true, process_in_physics: bool = false, ignore_time_scale: bool = false) -> SceneTreeTimer:",
	"\treturn __warmd_tree().create_timer(time_sec, process_always, process_in_physics, ignore_time_scale)",
	"func create_tween() -> Tween:",
	"\treturn __warmd_tree().create_tween()",
	"func get_frame() -> int:",
	"\treturn __warmd_tree().get_frame()",
	"func get_node_count() -> int:",
	"\treturn __warmd_tree().get_node_count()",
	"func get_nodes_in_group(group: StringName) -> Array[Node]:",
	"\treturn __warmd_tree().get_nodes_in_group(group)",
	"func get_first_node_in_group(group: StringName) -> Node:",
	"\treturn __warmd_tree().get_first_node_in_group(group)",
	"func get_node_count_in_group(group: StringName) -> int:",
	"\treturn __warmd_tree().get_node_count_in_group(group)",
	"func has_group(group: StringName) -> bool:",
	"\treturn __warmd_tree().has_group(group)",
	"func change_scene_to_file(path: String) -> Error:",
	"\treturn __warmd_tree().change_scene_to_file(path)",
	"func change_scene_to_packed(packed_scene: PackedScene) -> Error:",
	"\treturn __warmd_tree().change_scene_to_packed(packed_scene)",
	"func reload_current_scene() -> Error:",
	"\treturn __warmd_tree().reload_current_scene()",
	"func unload_current_scene() -> void:",
	"\t__warmd_tree().unload_current_scene()",
	"func get_processed_tweens() -> Array[Tween]:",
	"\treturn __warmd_tree().get_processed_tweens()",
	"func queue_delete(obj: Object) -> void:",
	"\t__warmd_tree().queue_delete(obj)",
]


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
			return _compile(str(job.get("scenes", "")).split(",", false))
		"test":
			return await _test(str(job.get("filter", "")))
		"call":
			return await _call_script(str(job.get("script", "")))
		"runners":
			return await _runners(str(job.get("list", "")))
		"golden":
			return _golden(str(job.get("shot", "")), str(job.get("ref", "")), float(str(job.get("tol", "0.5"))))
		"budget":
			return await _budget(str(job.get("textures", "")).split(",", false), str(job.get("scenes", "")).split(",", false), int(str(job.get("frames", "60"))))
	return [false, ["unknown job"]]


## Orphan nodes (debug builds only): nodes out of the tree that nobody frees. A test or runner that leaves some is red.
func _orphans() -> int:
	return int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)) if OS.is_debug_build() else 0


## The leak verdict for <where>: "" when none was left or godot_allow_errors matches "<where>: N orphan nodes"
func _leak(where: String, n: int) -> String:
	if n <= 0:
		return ""
	if allow_on and allow.search("%s: %d orphan nodes" % [where, n]) != null:
		return ""
	return "%d orphan nodes left (leak, Node.print_orphan_nodes() lists them)" % n


## Golden shot: the shot against the reference of this machine. Channels within 8 of each other count as equal (driver
## noise), a share of differing pixels up to tol percent is SAME. The answer is text: SAME, or DIFF p% in region x,y,w,h.
func _golden(shot: String, ref: String, tol: float) -> Array:
	var a := Image.load_from_file(shot)
	var b := Image.load_from_file(ref)
	if a == null or a.is_empty():
		return [false, ["DIFF no image at %s" % shot]]
	if b == null or b.is_empty():
		return [false, ["DIFF the reference %s does not load" % ref]]
	if a.get_size() != b.get_size():
		return [false, ["DIFF size %dx%d, reference %dx%d" % [a.get_width(), a.get_height(), b.get_width(), b.get_height()]]]
	a.convert(Image.FORMAT_RGBA8)
	b.convert(Image.FORMAT_RGBA8)
	var da := a.get_data()
	var db := b.get_data()
	var w := a.get_width()
	var h := a.get_height()
	var row := w * 4
	var n := 0
	var x0 := w
	var y0 := h
	var x1 := -1
	var y1 := -1
	for y: int in h:
		var s := y * row
		if da.slice(s, s + row) == db.slice(s, s + row):
			continue
		for x: int in w:
			var i := s + x * 4
			if absi(da[i] - db[i]) > 8 or absi(da[i + 1] - db[i + 1]) > 8 or absi(da[i + 2] - db[i + 2]) > 8 or absi(da[i + 3] - db[i + 3]) > 8:
				n += 1
				x0 = mini(x0, x)
				y0 = mini(y0, y)
				x1 = maxi(x1, x)
				y1 = maxi(y1, y)
	if n == 0:
		return [true, ["SAME"]]
	var pct := 100.0 * n / float(w * h)
	var region := "in region %d,%d,%d,%d" % [x0, y0, x1 - x0 + 1, y1 - y0 + 1]
	if pct <= tol:
		return [true, ["SAME (%.1f%% differs %s, within the tolerance of %.1f%%)" % [pct, region, tol]]]
	return [false, ["DIFF %.1f%% %s" % [pct, region]]]


## Budgets: the size of each texture, and per scene its nodes, memory and draw calls over <frames> frames. The numbers go
## to budget.txt (one line each, tab between), warmd compares them with warmd.conf. A scene's script error is red: this
## is also the rendered smoke run when the engine has graphics.
func _budget(textures: PackedStringArray, scenes: PackedStringArray, frames: int) -> Array:
	var out: PackedStringArray = []
	var bad: PackedStringArray = []
	for path: String in textures:
		var img := Image.load_from_file(ProjectSettings.globalize_path(path))
		if img == null or img.is_empty():
			bad.append("%s does not load as an image" % path)
			continue
		out.append("texture\t%s\t%d\t%d" % [path, img.get_width(), img.get_height()])
	var rendered := DisplayServer.get_name() != "headless"
	for path: String in scenes:
		var mark := _log_marks()
		var packed := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene
		if packed == null:
			bad.append("%s does not load" % path)
			continue
		var mem0 := Performance.get_monitor(Performance.MEMORY_STATIC)
		var nodes0 := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
		var inst := packed.instantiate()
		if inst == null:
			bad.append("%s does not instantiate" % path)
			continue
		root.add_child(inst)
		var draws := 0.0
		var mem := 0.0
		var nodes := 0.0
		for i: int in maxi(frames, 1):
			await process_frame
			draws = maxf(draws, Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
			mem = maxf(mem, Performance.get_monitor(Performance.MEMORY_STATIC) - mem0)
			nodes = maxf(nodes, Performance.get_monitor(Performance.OBJECT_NODE_COUNT) - nodes0)
		var errs := _log_errors(mark)
		if is_instance_valid(inst):
			inst.queue_free()
		await process_frame
		if not errs.is_empty():
			bad.append("%s: script error %s" % [path, errs[0].left(200)])
		out.append("scene\t%s\tnodes=%d\tmemory_mb=%.1f\tdraw_calls=%d\trendered=%d" % [path, int(nodes), mem / 1048576.0, int(draws), 1 if rendered else 0])
	_write("budget.txt", "\n".join(out) + "\n")
	if not bad.is_empty():
		return [false, bad]
	return [true, ["%d textures, %d scenes measured, %s" % [textures.size(), scenes.size(), "rendered" if rendered else "headless"]]]


## A red script names the engine's own line, "file:line message", so nobody has to open a log for it.
## Changed scenes and resources (warmd passes them) load and instantiate after the scripts.
func _compile(scenes: PackedStringArray) -> Array:
	var bad: PackedStringArray = []
	var files := _scripts("res://")
	for path: String in files:
		var script := GDScript.new()
		script.source_code = FileAccess.get_file_as_string(path)
		script.resource_path = path
		var mark := _log_marks()
		if script.reload() != OK:
			var errs := _log_errors(mark)
			bad.append(errs[0] if not errs.is_empty() else "%s does not parse" % path.trim_prefix("res://"))
	bad.append_array(_check_scenes(scenes))
	if bad.is_empty():
		var also := ", %d changed scenes and resources load" % scenes.size() if not scenes.is_empty() else ""
		return [true, ["%d scripts parse%s" % [files.size(), also]]]
	return [false, bad]


## A text check misses an inherited scene's dead base, a missing script, a signal wired to a renamed method: each changed
## .tscn and .tres is loaded and a scene instantiated, never saved (scripts run their _init, @tool or not). Every engine
## error while it does is red as "file: message", a scene connection to a method its target lacks too.
func _check_scenes(scenes: PackedStringArray) -> PackedStringArray:
	var bad: PackedStringArray = []
	for path: String in scenes:
		var rel := path.trim_prefix("res://")
		var mark := _log_marks()
		var why := ""
		var res: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
		if res == null:
			why = "does not load"
		elif res is PackedScene:
			var scene := res as PackedScene
			var node: Node = scene.instantiate() if scene.can_instantiate() else null
			if node == null:
				why = "does not instantiate"
			else:
				why = _dead_connection(node)
				node.free()
		var errs: PackedStringArray = []
		for e: String in _log_errors(mark, true):
			if not (allow_on and allow.search("%s %s" % [rel, e]) != null):
				errs.append(e)
		if not errs.is_empty():
			bad.append("%s: %s" % [rel, errs[0].left(200)])
		elif why != "":
			bad.append("%s: %s" % [rel, why])
	return bad


## The first scene connection (CONNECT_PERSIST) in the tree whose target lacks the method, as text, else "".
func _dead_connection(top: Node) -> String:
	var nodes: Array[Node] = [top]
	nodes.append_array(top.find_children("*", "", true, false))
	for n: Node in nodes:
		for s: Dictionary in n.get_signal_list():
			var sig: StringName = s["name"]
			for c: Dictionary in n.get_signal_connection_list(sig):
				var cb: Callable = c["callable"]
				var flags: int = c["flags"]
				var target := cb.get_object()
				if flags & CONNECT_PERSIST and target != null and not target.has_method(cb.get_method()):
					return "signal %s of %s connects to missing method %s" % [sig, top.get_path_to(n), cb.get_method()]
	return ""


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
			var orphans0 := _orphans()
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
			# Nodes the test made and left out of the tree: a queue_free lands at the frame's end, so a count above the
			# start waits one frame before it counts
			var left := _orphans() - orphans0
			if left > 0:
				await process_frame
				left = _orphans() - orphans0
			if failed == "":
				failed = _leak(path.trim_prefix("res://"), left)
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


## Every runner of the list ("res://path|timeout", comma between) in this one engine, one after another. Each verdict lands
## in runners.txt as it is known, current.txt names the runner that runs: when a runner ends the engine, warmd knows which.
func _runners(list: String) -> Array:
	_remove("runners.txt")
	var n := 0
	for item: String in list.split(",", false):
		var parts := item.split("|")
		var limit := float(parts[1]) if parts.size() > 1 else 900.0
		_write("current.txt", parts[0])
		print("== ", parts[0].trim_prefix("res://"))
		var verdict: String = await _guest(parts[0], limit)
		_append("runners.txt", "%s\t%s\n" % [parts[0].trim_prefix("res://"), verdict])
		n += 1
	_remove("current.txt")
	return [true, ["%d runners in one engine" % n]]


## One runner as a guest: _init, _initialize, then _process and _physics_process each frame until it quits. Its verdict is
## "OK", "FAIL\t<why>" or "ALONE\t<why>" (it needs an engine of its own). What it added to the tree goes with it.
func _guest(path: String, limit: float) -> String:
	var src := FileAccess.get_file_as_string(path).replace("\r", "")
	if src == "" or guest_rx.search(src) == null:
		return "ALONE\tits extends line is not plain SceneTree"
	var unit := "\t"
	var first := indent_rx.search(src)
	if first != null and first.get_string(1).begins_with(" "):
		unit = first.get_string(1)
	var host: PackedStringArray = []
	for line: String in GUEST_HOST:
		host.append(line.replace("\t", unit))
	var script := GDScript.new()
	script.source_code = class_rx.sub(guest_rx.sub(src, "$1extends RefCounted"), "", true) + "\n" + "\n".join(host) + "\n"
	script.resource_path = path   # its errors name the runner's own file and line: the host only adds lines at the end
	if script.reload() != OK or not script.can_instantiate():
		return "ALONE\tdoes not compile as a guest of the shared engine"
	var kids := root.get_children()
	var was_paused := paused
	var mark := _log_marks()
	var start := Time.get_ticks_msec()
	var orphans0 := _orphans()
	var guest: Object = script.new()
	var physics := func() -> void:
		if guest.has_method("_physics_process") and guest.get("__warmd_quit") != true:
			guest.call("_physics_process", 1.0 / Engine.physics_ticks_per_second)
	physics_frame.connect(physics)
	if guest.has_method("_initialize"):
		guest.call("_initialize")
	var why := ""
	var last := Time.get_ticks_usec()
	while true:
		await process_frame
		var now := Time.get_ticks_usec()
		if guest.has_method("_process"):
			var ended: Variant = guest.call("_process", (now - last) / 1000000.0)
			if ended is bool and ended:
				break
		last = now
		if guest.get("__warmd_quit") == true:
			break
		if Time.get_ticks_msec() - start > limit * 1000.0:
			why = "timeout after %ds" % int(limit)
			break
	physics_frame.disconnect(physics)
	if why == "" and guest.has_method("_finalize"):
		guest.call("_finalize")
	var code: int = guest.get("__warmd_code")
	var errs := _log_errors(mark)
	var said_ok := success_rx.search(_log_text(mark)) != null
	# What the runner left behind would leak into the next one: its connections to the tree, its nodes, a paused tree
	for s: Dictionary in get_signal_list():
		var sig: StringName = s["name"]
		for c: Dictionary in get_signal_connection_list(sig):
			var cb: Callable = c["callable"]
			if cb.get_object() == guest:
				disconnect(sig, cb)
	physics = Callable()
	guest = null
	for i: int in 2:   # a scene change lands one frame later
		for node: Node in root.get_children():
			if not kids.has(node):
				node.queue_free()
		await process_frame
	paused = was_paused
	var bad := errs[0].left(200) if not errs.is_empty() else ""
	var tail := ": " + bad if bad != "" else ""
	if why != "":
		return "FAIL\t(%s)%s" % [why, tail]
	if code != 0:
		return "FAIL\t(exit %d%s)%s" % [code, " after success output" if said_ok else "", tail]
	if bad != "":
		return "FAIL\tscript error %s (exit 0)" % bad
	# Its own nodes are gone with it above: what is still out of the tree and not freed, it leaked
	var leak := _leak(path.trim_prefix("res://"), _orphans() - orphans0)
	if leak != "":
		return "FAIL\t%s" % leak
	return "OK"


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
## engine: the engine's own errors count too ("ERROR: ...", a missing file, a broken scene), without the C++ place.
func _log_errors(marks: PackedInt64Array, engine: bool = false) -> PackedStringArray:
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
			if engine and engine_rx.search(lines[n]) != null:
				var said := engine_rx.sub(lines[n], "").strip_edges()
				if not found.has(said):
					found.append(said)
				continue
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


## All the engine printed since the marks.
func _log_text(marks: PackedInt64Array) -> String:
	var text := ""
	for i: int in logs.size():
		var f := FileAccess.open(logs[i], FileAccess.READ)
		if marks[i] < 0 or f == null or f.get_length() <= marks[i]:
			continue
		f.seek(marks[i])
		text += f.get_buffer(f.get_length() - marks[i]).get_string_from_utf8().replace("\r", "") + "\n"
	return ansi_rx.sub(text, "", true)


func _append(file: String, text: String) -> void:
	var path := dir.path_join(file)
	var f := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	if f != null:
		f.seek_end()
		f.store_string(text)


func _write(file: String, text: String) -> void:
	var f := FileAccess.open(dir.path_join(file), FileAccess.WRITE)
	if f != null:
		f.store_string(text)


func _remove(file: String) -> void:
	DirAccess.remove_absolute(dir.path_join(file))
