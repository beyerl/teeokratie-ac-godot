extends Node
## Global service locator (the Godot analogue of AC's KickStarter + managers).
## Holds game state, variables, inventory, the speech table, and scene switching.

enum State { GAMEPLAY, CUTSCENE, DIALOG, PAUSED }

var state: int = State.GAMEPLAY
var globals: Dictionary = {}
var speech: Dictionary = {}            # lineID(str) -> {text, speaker, type}
var vars: Dictionary = {}              # var id(int) -> value
var var_by_name: Dictionary = {}       # label -> id
var inventory: Array = []              # array of item ids the player carries
var items_by_id: Dictionary = {}       # id -> item dict
var objectives: Dictionary = {}        # id -> state
var conv_states: Dictionary = {}       # convFileID -> {optionNum(int): bool enabled}

var current_room: Node = null
var room_name: String = ""
var pending_marker: String = ""        # spawn marker for next room

signal state_changed(new_state)

const DATA := "res://data/"

func _ready() -> void:
	_load_globals()

func _load_globals() -> void:
	globals = _read_json(DATA + "globals.json")
	speech = globals.get("speech", {})
	for v in globals.get("variables", []):
		var id := int(v.get("id", 0))
		vars[id] = _default_var_value(v)
		if v.get("label"):
			var_by_name[v["label"]] = id
	for it in globals.get("items", []):
		items_by_id[int(it.get("id", 0))] = it
		if int(it.get("carryOnStart", 0)) == 1:
			inventory.append(int(it.get("id", 0)))

func _default_var_value(v: Dictionary):
	var t := int(v.get("type", 0))
	match t:
		0: return int(v.get("val", 0)) != 0   # boolean
		1: return int(v.get("val", 0))         # integer
		2: return float(v.get("floatVal", 0)) # float
		3: return str(v.get("textVal", ""))    # string
		_: return int(v.get("val", 0))         # popup -> index
	return 0

func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("missing data: " + path)
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	var txt := f.get_as_text()
	var parsed = JSON.parse_string(txt)
	return parsed if parsed is Dictionary else {}

func load_scene_data(name: String) -> Dictionary:
	return _read_json(DATA + name + ".json")

# ------------------------------------------------------------------ state
func set_state(s: int) -> void:
	state = s
	emit_signal("state_changed", s)

func is_gameplay() -> bool:
	return state == State.GAMEPLAY

# ------------------------------------------------------------------ vars
func get_var(id: int):
	return vars.get(id, 0)

func set_var(id: int, value) -> void:
	vars[id] = value

# ------------------------------------------------------------------ conversations
func option_enabled(conv_id: String, num: int, default_on: bool) -> bool:
	var st: Dictionary = conv_states.get(conv_id, {})
	return st.get(num, default_on)

func set_option_enabled(conv_id: String, num: int, on: bool) -> void:
	if not conv_states.has(conv_id):
		conv_states[conv_id] = {}
	conv_states[conv_id][num] = on

func line_text(line_id) -> String:
	var e = speech.get(str(line_id))
	if e == null:
		return ""
	return str(e.get("text", ""))

# ------------------------------------------------------------------ inventory
func has_item(id: int) -> bool:
	return inventory.has(id)

func add_item(id: int) -> void:
	if not inventory.has(id):
		inventory.append(id)

func remove_item(id: int) -> void:
	inventory.erase(id)

# ------------------------------------------------------------------ scene switch
func change_room(name: String, marker: String = "") -> void:
	pending_marker = marker
	room_name = name
	get_tree().call_deferred("change_scene_to_file", "res://scenes/Main.tscn")
