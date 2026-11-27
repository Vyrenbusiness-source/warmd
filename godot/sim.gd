extends SceneTree
## warmd sim for Godot: plays scenario files headless under a fixed physics tick, all of them in this one engine start.
## lib/sim.sh starts it with --headless --fixed-fps <physics ticks>, so every frame is exactly one physics tick and the
## engine runs as fast as it can: no --time-scale, the physics stays as exact as in the game.
## Env: WARMD_SIM_JOBS (file, one "name<TAB>path" per line), WARMD_SIM_REPLAY (path of godot/replay.gd),
## WARMD_SIM_SEED (overrides every scenario's seed). Record mode: WARMD_SIM_MODE=record, WARMD_SCENE, WARMD_SIM_OUT,
## WARMD_SIM_SEED, WARMD_SIM_FRAMES (0: until the window closes).
## Output: "SIM BEGIN <name>" and "SIM END <name> OK|FAIL <text>", one pair per scenario. Engine errors in between belong to it.
##
## Scenario file (tests/sim/<name>.sim), one key per line, # starts a comment:
##   scene res://levels/arena.tscn   seed 7   frames 600
##   metric <name> <max|min|last|avg|count|pct> <<=|<|>=|>|==> <limit> : <expression>
##   <frame> press|release|mouse|down|up ...   (input lines, see godot/replay.gd)
## The expression is a Godot Expression on the scene root, sampled after every tick; $Path means get_node_or_null("Path").
## A scenario ends as soon as its verdict is decided: one limit is broken for good, or every limit holds whatever comes.

const OPS := ["<=", "<", ">=", ">", "=="]
const NOT_OP := {"<=": ">", "<": ">=", ">=": "<", ">": "<=", "==": "!="}
const AGGS := ["max", "min", "last", "avg", "count", "pct"]

var _replay_script: GDScript = null
var _mode := ""
var _jobs: Array = []
var _job := -1
var _node: Node = null
var _keep: Dictionary = {}     # root children before the first scenario: autoloads, never freed
var _frame := 0
var _frames := 0
var _seed := 0
var _name := ""
var _metrics: Array = []
var _replay: RefCounted = null
var _running := false
var _started := false


func _init() -> void:
	Engine.max_fps = 0
	Input.use_accumulated_input = false   # a replayed event reaches the nodes in its own tick, not one later
	var rp := OS.get_environment("WARMD_SIM_REPLAY")
	_replay_script = GDScript.new()
	_replay_script.source_code = FileAccess.get_file_as_string(rp)
	if _replay_script.reload() != OK:
		print("SIM FATAL replay script %s does not load" % rp)
		quit(2)
		return
	_mode = OS.get_environment("WARMD_SIM_MODE")
	if _mode == "record":
		return
	var list := FileAccess.get_file_as_string(OS.get_environment("WARMD_SIM_JOBS"))
	for line in list.split("\n", false):
		var t := line.strip_edges()
		if t != "" and t.contains("\t"):
			_jobs.append(t.split("\t"))
	print("SIM START %d" % _jobs.size())


func _physics_process(_delta: float) -> bool:
	if not _started:
		_started = true
		for c in root.get_children():
			_keep[c] = true
	if _mode == "record":
		return _record_tick()
	if not _running:
		_cleanup()
		_job += 1
		if _job >= _jobs.size():
			print("SIM DONE")
			quit(0)
			return false
		if not _start(_jobs[_job][0], _jobs[_job][1]):
			return false
	else:
		if _frame > 0:
			_sample()
		var verdict := _decide(_frames - _frame)
		if verdict != "":
			_end(verdict)
			return false
	if _replay != null:
		_replay.apply(_frame)
	_frame += 1
	return false


# ---- one scenario ----

func _start(sim_name: String, path: String) -> bool:
	_name = sim_name
	_frame = 0
	_metrics = []
	_replay = null
	print("SIM BEGIN %s" % _name)
	var why := _parse(path)
	if why != "":
		print("SIM END %s FAIL %s" % [_name, why])
		return false
	Engine.time_scale = 1.0
	paused = false
	seed(_seed)
	Engine.set_meta("warmd_seed", _seed)
	var packed = ResourceLoader.load(_scene_path) if ResourceLoader.exists(_scene_path) else null
	if not packed is PackedScene:
		print("SIM END %s FAIL %s is not a scene that loads" % [_name, _scene_path])
		return false
	_node = packed.instantiate()
	if _node == null:
		print("SIM END %s FAIL %s does not instantiate" % [_name, _scene_path])
		return false
	root.add_child(_node)
	current_scene = _node
	_running = true
	return true


var _scene_path := ""


func _parse(path: String) -> String:
	if not FileAccess.file_exists(path):
		return "no file %s" % path
	_scene_path = ""
	_frames = 600
	_seed = 1
	_replay = _replay_script.new()
	var n := 0
	for raw in FileAccess.get_file_as_string(path).split("\n"):
		n += 1
		var line := raw.replace("\t", " ").strip_edges()
		var hash_at := line.find("#")
		if hash_at >= 0 and not line.begins_with("metric"):
			line = line.substr(0, hash_at).strip_edges()
		if line == "":
			continue
		var words := line.split(" ", false)
		var why := ""
		match words[0]:
			"scene":
				_scene_path = words[1] if words.size() > 1 else ""
			"seed":
				if words.size() < 2 or not words[1].is_valid_int():
					why = "seed wants a whole number"
				else:
					_seed = int(words[1])
			"frames":
				if words.size() < 2 or not words[1].is_valid_int() or int(words[1]) < 1:
					why = "frames wants a number above 0"
				else:
					_frames = int(words[1])
			"isolate":
				pass
			"metric":
				why = _metric(line)
			_:
				if words[0].is_valid_int():
					why = _replay.add(words)
				else:
					why = "unknown key %s" % words[0]
		if why != "":
			return "line %d: %s" % [n, why]
	if OS.get_environment("WARMD_SIM_SEED").is_valid_int():
		_seed = int(OS.get_environment("WARMD_SIM_SEED"))
	if _scene_path == "":
		return "no scene line"
	if _replay.events == 0:
		_replay = null
	return ""


func _metric(line: String) -> String:
	var at := line.find(" : ")
	if at < 0:
		return "metric wants: metric <name> <aggregate> <op> <limit> : <expression>"
	var head := line.substr(0, at).split(" ", false)
	var src := line.substr(at + 3).strip_edges()
	if head.size() != 5:
		return "metric wants: metric <name> <aggregate> <op> <limit> : <expression>"
	if not AGGS.has(head[2]):
		return "aggregate %s, wanted one of %s" % [head[2], ", ".join(AGGS)]
	if not OPS.has(head[3]):
		return "limit op %s, wanted one of %s" % [head[3], " ".join(OPS)]
	if not head[4].is_valid_float():
		return "limit %s is no number" % head[4]
	var rx := RegEx.create_from_string("\\$(\"[^\"]+\"|[A-Za-z0-9_/]+)")
	var code := src
	for m in rx.search_all(src):
		var p := m.get_string(1).trim_prefix("\"").trim_suffix("\"")
		code = code.replace(m.get_string(0), "get_node_or_null(\"%s\")" % p)
	var e := Expression.new()
	if e.parse(code) != OK:
		return "metric %s: %s" % [head[1], e.get_error_text()]
	_metrics.append({"name": head[1], "agg": head[2], "op": head[3], "lim": float(head[4]), "e": e,
		"n": 0, "hit": 0, "sum": 0.0, "max": -INF, "min": INF, "last": 0.0, "err": ""})
	return ""


func _sample() -> void:
	var base: Node = current_scene if is_instance_valid(current_scene) else (_node if is_instance_valid(_node) else null)
	if base == null:
		return
	for m: Dictionary in _metrics:
		var e: Expression = m.e
		var v = e.execute([], base, false)
		if e.has_execute_failed():
			m.err = e.get_error_text()
			continue
		var x := 0.0
		if v is bool:
			x = 1.0 if v else 0.0
		elif v is int or v is float:
			x = float(v)
		else:
			m.err = "value is %s, not a number or bool" % type_string(typeof(v))
			continue
		m.n += 1
		m.sum += x
		m.last = x
		m.max = maxf(m.max, x)
		m.min = minf(m.min, x)
		if x != 0.0:
			m.hit += 1


# The final value of a metric lies in [lo, hi] whatever the remaining ticks bring. Empty: no sample at all and none to come.
func _bounds(m: Dictionary, rem: int) -> Array:
	var n: int = m.n
	if n == 0 and rem == 0:
		return []
	var hit: int = m.hit
	match m.agg:
		"max":
			return [m.max, INF if rem > 0 else m.max]
		"min":
			return [-INF if rem > 0 else m.min, m.min]
		"count":
			return [float(hit), float(hit + rem)]
		"pct":
			# A tick whose expression fails gives no sample: the final share is at least hit/(n+rem), at most (hit+rem)/(n+rem)
			return [100.0 * hit / (n + rem), 100.0 * (hit + rem) / (n + rem)]
		"last":
			return [m.last, m.last] if rem == 0 else [-INF, INF]
		_:
			return [m.sum / n, m.sum / n] if rem == 0 else [-INF, INF]


func _holds(op: String, x: float, lim: float) -> bool:
	match op:
		"<=": return x <= lim
		"<": return x < lim
		">=": return x >= lim
		">": return x > lim
	return is_equal_approx(x, lim)


func _decide(rem: int) -> String:
	var bad: PackedStringArray = []
	var good: PackedStringArray = []
	var open := false
	for m: Dictionary in _metrics:
		var b := _bounds(m, rem)
		if b.is_empty():
			bad.append("%s never evaluated%s" % [m.name, (": " + m.err) if m.err != "" else ""])
			continue
		var lo: float = b[0]
		var hi: float = b[1]
		var all_hold: bool = _holds(m.op, lo, m.lim) and _holds(m.op, hi, m.lim) and (m.op != "==" or lo == hi)
		var none_hold: bool = (not _holds(m.op, lo, m.lim) and not _holds(m.op, hi, m.lim)) and (m.op != "==" or lo > m.lim or hi < m.lim)
		# <= and < hold for a whole interval when they hold at hi, >= and > when they hold at lo: checking both ends is exact
		if all_hold:
			good.append("%s %s %s %s" % [m.name, _shown(m, lo, hi, rem, true), m.op, _num(m, m.lim)])
		elif none_hold:
			bad.append("%s %s %s %s" % [m.name, _shown(m, lo, hi, rem, false), NOT_OP[m.op], _num(m, m.lim)])
		else:
			open = true
	if not bad.is_empty():
		var at := " at frame %d of %d" % [_frame, _frames] if rem > 0 else ""
		return "FAIL %s%s (seed %d)" % [", ".join(bad), at, _seed]
	if rem > 0 and (open or _metrics.is_empty()):
		return ""
	var how := "%d frames" % _frames if rem == 0 else "decided at frame %d of %d" % [_frame, _frames]
	if _metrics.is_empty():
		return "OK no metric, %s ran (seed %d)" % [how, _seed]
	return "OK %s (%s, seed %d)" % [", ".join(good), how, _seed]


# The value a verdict rests on: the exact one at the end, else the proven bound ("at least 14%").
func _shown(m: Dictionary, lo: float, hi: float, rem: int, holds: bool) -> String:
	if rem == 0 or lo == hi:
		return _num(m, lo)
	match m.agg:
		"max":
			return _num(m, lo)
		"min":
			return _num(m, hi)
	var want_low: bool = (m.op == "<=" or m.op == "<") != holds
	return ("at least " + _num(m, lo)) if want_low else ("at most " + _num(m, hi))


func _num(m: Dictionary, x: float) -> String:
	if m.agg == "pct":
		return _plain(snappedf(x, 0.1)) + "%"
	if m.agg == "count":
		return str(int(x))
	return _plain(snappedf(x, 0.01))


# 2.0 prints as 2, 2.5 as 2.5
func _plain(x: float) -> String:
	if is_finite(x) and x == floorf(x) and absf(x) < 1e15:
		return str(int(x))
	return str(x)


func _end(verdict: String) -> void:
	print("SIM END %s %s" % [_name, verdict])
	_running = false


# Frees what the scenario left: its scene, scenes it changed to, nodes it put under root. Input the replay holds is let go.
func _cleanup() -> void:
	if _replay != null:
		_replay.release_all()
		_replay = null
	for a in InputMap.get_actions():
		Input.action_release(a)
	for c in root.get_children():
		if not _keep.has(c):
			root.remove_child(c)
			c.free()
	_node = null
	current_scene = null


# ---- record ----
var _rec: RefCounted = null
var _rec_frames := 0


func _record_tick() -> bool:
	if _frame == 0:
		var path := OS.get_environment("WARMD_SCENE")
		_seed = int(OS.get_environment("WARMD_SIM_SEED"))
		_rec_frames = int(OS.get_environment("WARMD_SIM_FRAMES"))
		seed(_seed)
		Engine.set_meta("warmd_seed", _seed)
		var packed = ResourceLoader.load(path) if ResourceLoader.exists(path) else null
		if not packed is PackedScene:
			print("SIM FATAL %s is not a scene that loads" % path)
			quit(1)
			return false
		_node = packed.instantiate()
		root.add_child(_node)
		current_scene = _node
		_rec = _replay_script.new()
		var head := PackedStringArray([
			"# warmd sim scenario, recorded input. Add a metric line that is red for the bug, then: warmd sim <this file>",
			"# metric <name> <max|min|last|avg|count|pct> <<=|<|>=|>|==> <limit> : <expression>   e.g. metric fell max <= 900 : $Player.position.y",
			"scene %s" % path, "seed %d" % _seed])
		var why: String = _rec.record_start(OS.get_environment("WARMD_SIM_OUT"), head)
		if why != "":
			print("SIM FATAL %s" % why)
			quit(1)
			return false
		print("SIM RECORD %s seed %d" % [path, _seed])
	_rec.record_tick(_frame, root)
	_frame += 1
	if _rec_frames > 0 and _frame >= _rec_frames:
		quit(0)
	return false


func _finalize() -> void:
	if _rec != null:
		_rec.record_end(_frame)
		print("SIM RECORDED %d frames %d inputs" % [_frame, _rec.events])
