extends Node
class_name ActionRunner
## Interprets an AdventureCreator ActionList (data extracted from Unity).
##
## Flow model (AC): each action returns how to proceed via endAction:
##   0 = Continue  -> next action (index+1)
##   1 = Stop      -> end the list
##   2 = Skip      -> jump to action index `skipAction`
## Check actions branch instead via resultActionTrue/Fail + skipActionTrue/Fail.
##
## Runs as a coroutine: blocking actions (speech, pause, walk) `await`.

var room: Node2D                      # the active Room (for node lookups + services)
var _stop := false

func _init(room_node: Node2D) -> void:
	room = room_node

# Run a list of action dicts. `pause_gameplay` sets CUTSCENE state.
func run(actions: Array, pause_gameplay: bool = true) -> void:
	if actions.is_empty():
		return
	var prev_state := Game.state
	if pause_gameplay:
		Game.set_state(Game.State.CUTSCENE)
	_stop = false
	var i := 0
	var guard := 0
	while i >= 0 and i < actions.size() and not _stop:
		guard += 1
		if guard > 2000:
			push_warning("ActionRunner: flow guard tripped")
			break
		var a: Dictionary = actions[i]
		var nxt := await _exec(a, i, actions)
		i = nxt
	if pause_gameplay and Game.state == Game.State.CUTSCENE:
		Game.set_state(prev_state)

func stop() -> void:
	_stop = true

# Returns the next action index (-1 to stop).
func _exec(a: Dictionary, idx: int, actions: Array) -> int:
	var t := str(a.get("type", ""))
	match t:
		"ActionSpeech":
			await _speech(a)
		"ActionPause":
			var secs := float(a.get("timeToPause", 0))
			if secs > 0.0:
				await room.get_tree().create_timer(secs).timeout
		"ActionCharPathFind", "ActionCharMove":
			await _pathfind(a)
		"ActionTeleport":
			_teleport(a)
		"ActionCharFaceDirection":
			_face(a)
		"ActionVisible":
			_set_visible(a)
		"ActionSpriteFade":
			_sprite_fade(a)
		"ActionVarSet":
			_var_set(a)
		"ActionVarPopup":
			return _var_popup(a, idx)
		"ActionInventorySet":
			_inventory_set(a)
		"ActionObjectiveSet":
			Game.objectives[int(a.get("objectiveID", 0))] = int(a.get("newStateID", 0))
		"ActionHotspotEnable":
			_hotspot_enable(a)
		"ActionMusic":
			room.audio_music(a)
		"ActionAmbience":
			room.audio_ambience(a)
		"ActionScene":
			_change_scene(a)
			return -1
		"ActionRunActionList":
			await _run_sublist(a)
		"ActionConversation":
			await _conversation(a)
		"ActionDialogOption":
			_dialog_option(a)
		# --- checks (branch) ---
		"ActionVarCheck":
			return _branch(a, _eval_var_check(a), actions, idx)
		"ActionInventoryCheck":
			return _branch(a, Game.has_item(int(a.get("invID", -1))), actions, idx)
		"ActionSceneCheck":
			return _branch(a, _eval_scene_check(a), actions, idx)
		"ActionMenuCheck", "ActionVisibleCheck":
			return _branch(a, false, actions, idx)
		"ActionParallel":
			return _parallel(a, actions, idx)
		_:
			# ActionMenuState, ActionAnim, ActionInstantiate, ActionMixerSnapshot,
			# ActionDialogOption, ActionEvent, ... : safe no-op for now.
			pass
	return _next(a, idx)

# ---------- flow helpers ----------
func _next(a: Dictionary, idx: int) -> int:
	var end := int(a.get("endAction", 0))
	match end:
		0: return idx + 1                        # Continue
		1: return -1                              # Stop
		2: return int(a.get("skipAction", -1))    # Skip
		_: return idx + 1

func _branch(a: Dictionary, cond: bool, _actions: Array, idx: int) -> int:
	var res := int(a.get("resultActionTrue", 0)) if cond else int(a.get("resultActionFail", 0))
	var skip := int(a.get("skipActionTrue", -1)) if cond else int(a.get("skipActionFail", -1))
	match res:
		0: return idx + 1
		1: return -1
		2: return skip
		_: return idx + 1

# ActionVarPopup is a multi-socket switch on a popup variable. The game uses it to
# pick a RANDOM branch (e.g. a random book title when looking at the bookshelf), so
# route through a random socket. Each socket carries a resultAction + skip target.
func _var_popup(a: Dictionary, idx: int) -> int:
	var endings: Array = a.get("endings", [])
	if endings.is_empty():
		return _next(a, idx)
	var e = endings[randi() % endings.size()]
	match int(e.get("resultAction", 0)):
		0: return idx + 1
		1: return -1
		2: return int(e.get("skipAction", -1))
	return idx + 1

func _parallel(a: Dictionary, actions: Array, idx: int) -> int:
	# Approximation: launch every ending branch concurrently, then stop this thread.
	var endings: Array = a.get("endings", [])
	for e in endings:
		if int(e.get("resultAction", 0)) == 2:
			var start := int(e.get("skipAction", -1))
			if start >= 0 and start < actions.size():
				var sub := ActionRunner.new(room)
				room.add_child(sub)
				sub.run(actions.slice(start), false)
	return -1

# ---------- speech ----------
func _speech(a: Dictionary) -> void:
	var txt := str(a.get("messageText", ""))
	if txt == "":
		txt = Game.line_text(a.get("lineID", -1))
	var speaker := _speaker_name(a)
	var is_player := int(a.get("isPlayer", 0)) == 1
	var pos: Vector2 = room.player_position() if is_player else _ref_pos(a.get("speaker"))
	await room.say(speaker, txt, pos, int(a.get("isBackground", 0)) == 1, is_player)

func _speaker_name(a: Dictionary) -> String:
	if int(a.get("isPlayer", 0)) == 1:
		return "Teesa"
	var r = room.ref(a.get("speaker"))
	return str(r.get("name", "")) if r else ""

# ---------- movement ----------
func _pathfind(a: Dictionary) -> void:
	var target := _ref_pos(a.get("marker"))
	if int(a.get("isPlayer", 0)) == 1:
		await room.walk_player_to(target)
	else:
		var c = room.character(a.get("charToMove"))
		if c: await room.walk_char_to(c, target)

func _teleport(a: Dictionary) -> void:
	var target := _ref_pos(a.get("teleporter"))
	if int(a.get("isPlayer", 0)) == 1:
		room.set_player_position(target)
	else:
		var c = room.character(a.get("obToMove"))
		if c: c.position = target

func _face(a: Dictionary) -> void:
	var dir := int(a.get("direction", 0))
	if int(a.get("isPlayer", 0)) == 1:
		room.face_player(dir)
	else:
		var c = room.character(a.get("charToMove"))
		if c and c.has_method("set_facing"): c.set_facing(dir)

# ---------- world ----------
func _set_visible(a: Dictionary) -> void:
	var node = room.node_for(a.get("obToAffect"))
	if node:
		node.visible = int(a.get("visState", 0)) == 1

func _sprite_fade(a: Dictionary) -> void:
	var node = room.node_for(a.get("spriteFader"))
	if node:
		node.visible = int(a.get("fadeType", 0)) == 0

func _hotspot_enable(a: Dictionary) -> void:
	# AC ChangeType: 0 = Enable (turn on), 1 = Disable (turn off).
	room.set_hotspot_enabled_by_ref(a.get("hotspot"), int(a.get("changeType", 0)) == 0)

# ---------- variables ----------
func _var_set(a: Dictionary) -> void:
	var id := int(a.get("variableID", -1))
	if id < 0: return
	var method := int(a.get("setVarMethod", 0))
	# bool/int stored in intValue/boolValue; popups in intValue
	if a.has("boolValue") and a.get("type") == "ActionVarSet":
		Game.set_var(id, int(a.get("boolValue", 0)) != 0)
	if a.has("intValue"):
		if method == 2:  # increment
			Game.set_var(id, int(Game.get_var(id)) + int(a.get("intValue", 0)))
		else:
			Game.set_var(id, int(a.get("intValue", 0)))

func _eval_var_check(a: Dictionary) -> bool:
	var id := int(a.get("variableID", -1))
	var v = Game.get_var(id)
	if a.has("boolValue"):
		var want := int(a.get("boolValue", 0)) != 0
		var cond := int(a.get("boolCondition", 0))  # 0 == EqualTo, 1 == NotEqualTo
		var eq := (bool(v) == want)
		return eq if cond == 0 else not eq
	var want_i := int(a.get("intValue", 0))
	return int(v) == want_i

func _eval_scene_check(a: Dictionary) -> bool:
	# AC's ActionSceneCheck tests the PREVIOUS scene (where the player came from),
	# used by OnStart cutscenes to place the player at the matching entrance.
	var by := int(a.get("chooseSceneBy", 0))
	if by == 1:
		return room.map_scene_name(str(a.get("sceneName", ""))) == Game.prev_room
	return false

# ---------- inventory ----------
func _inventory_set(a: Dictionary) -> void:
	var inv := int(a.get("invID", -1))
	if inv < 0: return
	var ct := int(a.get("invAction", a.get("changeType", 0)))  # 0 add, 1 remove
	if ct == 0: Game.add_item(inv)
	else: Game.remove_item(inv)

# ---------- sublists / conversation ----------
func _run_sublist(a: Dictionary) -> void:
	var ref = a.get("actionList")
	var al = room.actionlist_by_ref(ref)
	if al:
		await run(al.get("actions", []), false)

func _conversation(a: Dictionary) -> void:
	var conv = room.conversation_by_ref(a.get("conversation"))
	if conv:
		await room.run_conversation(conv)

func _dialog_option(a: Dictionary) -> void:
	# Enable/disable/toggle a conversation option (AC switchType 0=on,1=off,2=toggle).
	var conv_ref = a.get("linkedConversation")
	var cid := str(conv_ref.get("fileID", "")) if conv_ref is Dictionary else str(conv_ref)
	var num := int(a.get("optionNumber", 0))
	if cid == "" or num <= 0:
		return
	var sw := int(a.get("switchType", 0))
	match sw:
		0: Game.set_option_enabled(cid, num, true)
		1: Game.set_option_enabled(cid, num, false)
		2: Game.set_option_enabled(cid, num, not Game.option_enabled(cid, num, false))

func _change_scene(a: Dictionary) -> void:
	var name := str(a.get("sceneName", ""))
	var mapped = room.map_scene_name(name)
	if mapped != "":
		Game.change_room(mapped)

# ---------- ref resolution ----------
func _ref_pos(ref) -> Vector2:
	var r = room.ref(ref)
	if r and r.has("pos"):
		var p = r["pos"]
		return Vector2(p[0], p[1])
	return room.player_position()
