extends RefCounted
## warmd sim input replay for Godot: plays recorded input back under the fixed tick, and records it.
## godot/sim.gd loads this file by its path (it lives outside the project). One input line per change:
##   <frame> press <action> [strength]   <frame> release <action>   <frame> mouse <x> <y>
##   <frame> down <button> <x> <y>        <frame> up <button> <x> <y>
## <frame> is the physics tick since the scene started: an input of frame f reaches the nodes in tick f, recorded or played.

var _events: Dictionary = {}       # frame -> Array of PackedStringArray
var _held: Dictionary = {}         # action -> true while the replay holds it
var _buttons: Dictionary = {}      # mouse button -> true while the replay holds it
var _mouse := Vector2.ZERO
var events := 0
var last_frame := -1


## add(words) -> "" or why the line is wrong. words[0] is the frame.
func add(words: PackedStringArray) -> String:
	if not words[0].is_valid_int() or int(words[0]) < 0:
		return "frame %s is no number" % words[0]
	var want := {"press": 3, "release": 3, "mouse": 4, "down": 5, "up": 5}
	if words.size() < 2 or not want.has(words[1]):
		return "unknown input %s, wanted press, release, mouse, down or up" % (words[1] if words.size() > 1 else "(none)")
	if words.size() < int(want[words[1]]):
		return "%s needs %d words" % [words[1], int(want[words[1]])]
	if (words[1] == "press" or words[1] == "release") and not InputMap.has_action(words[2]):
		return "no input action %s in this project" % words[2]
	var f := int(words[0])
	if not _events.has(f):
		_events[f] = []
	_events[f].append(words)
	events += 1
	last_frame = maxi(last_frame, f)
	return ""


func apply(frame: int) -> void:
	if not _events.has(frame):
		return
	for w: PackedStringArray in _events[frame]:
		match w[1]:
			"press":
				_action(w[2], true, float(w[3]) if w.size() > 3 else 1.0)
			"release":
				_action(w[2], false, 0.0)
			"mouse":
				var p := Vector2(float(w[2]), float(w[3]))
				var e := InputEventMouseMotion.new()
				e.position = p
				e.global_position = p
				e.relative = p - _mouse
				e.button_mask = _mask()
				_mouse = p
				Input.parse_input_event(e)
			"down", "up":
				_button(int(w[2]), w[1] == "down", Vector2(float(w[3]), float(w[4])))


## Everything the replay still holds is let go, so the next scenario starts with no key down.
func release_all() -> void:
	for a: String in _held.keys():
		_action(a, false, 0.0)
	for b: int in _buttons.keys():
		_button(b, false, _mouse)


# The event reaches _input and _unhandled_input, action_press sets the state Input.is_action_pressed polls.
func _action(a: String, on: bool, strength: float) -> void:
	var e := InputEventAction.new()
	e.action = a
	e.pressed = on
	e.strength = strength
	Input.parse_input_event(e)
	if on:
		Input.action_press(a, strength)
		_held[a] = true
	else:
		Input.action_release(a)
		_held.erase(a)


func _button(b: int, on: bool, p: Vector2) -> void:
	if on:
		_buttons[b] = true
	else:
		_buttons.erase(b)
	var e := InputEventMouseButton.new()
	e.button_index = b as MouseButton
	e.pressed = on
	e.position = p
	e.global_position = p
	e.button_mask = _mask()
	_mouse = p
	Input.parse_input_event(e)


func _mask() -> int:
	var m := 0
	for b: int in _buttons.keys():
		m |= 1 << (b - 1)
	return m


# ---- recording ----
var _out: FileAccess = null
var _actions: PackedStringArray = []
var _state: Dictionary = {}
var _rec_mouse := Vector2.ZERO
var _rec_buttons: Dictionary = {}
var _first := true


## record_start(path, header lines) -> "" or why the file cannot be written
func record_start(path: String, header: PackedStringArray) -> String:
	_out = FileAccess.open(path, FileAccess.WRITE)
	if _out == null:
		return "cannot write %s: %s" % [path, error_string(FileAccess.get_open_error())]
	for line in header:
		_out.store_line(line)
	_out.flush()
	for a in InputMap.get_actions():
		_actions.append(str(a))
	return ""


## record_tick(frame, viewport): one line per action, mouse position and mouse button that changed since the last tick.
## Written and flushed at once: a closed window or a crash loses nothing that was played.
func record_tick(frame: int, vp: Viewport) -> void:
	var wrote := false
	for a in _actions:
		var on := Input.is_action_pressed(a)
		if on != bool(_state.get(a, false)):
			_state[a] = on
			var s := Input.get_action_strength(a)
			if not on:
				_out.store_line("%d release %s" % [frame, a])
			elif is_equal_approx(s, 1.0) or s <= 0.0:
				_out.store_line("%d press %s" % [frame, a])
			else:
				_out.store_line("%d press %s %s" % [frame, a, str(snappedf(s, 0.001))])
			events += 1
			wrote = true
	var m := vp.get_mouse_position().round()
	if _first:
		_rec_mouse = m   # where the mouse starts is no input: a line only when it moves
		_first = false
	elif m != _rec_mouse:
		_rec_mouse = m
		_out.store_line("%d mouse %d %d" % [frame, int(m.x), int(m.y)])
		events += 1
		wrote = true
	for b in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
		var down := Input.is_mouse_button_pressed(b)
		if down != bool(_rec_buttons.get(b, false)):
			_rec_buttons[b] = down
			_out.store_line("%d %s %d %d %d" % [frame, "down" if down else "up", b, int(m.x), int(m.y)])
			events += 1
			wrote = true
	if wrote:
		_out.flush()


func record_end(frames: int) -> void:
	if _out == null:
		return
	_out.store_line("frames %d" % frames)
	_out.close()
	_out = null
