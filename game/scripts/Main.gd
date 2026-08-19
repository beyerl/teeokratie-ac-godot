extends Node2D
## Room controller: builds a room from extracted JSON data and provides the
## services the ActionRunner calls (say, walk, ref resolution, audio, ...).

# Teesa's walk speed. The original TeesaPlayer prefab has AC walkSpeedScale = 3
# (units/sec); at 32 px/unit that is 96 px/sec.
const PLAYER_SPEED := 96.0

var data: Dictionary = {}
var refs: Dictionary = {}
var action_lists: Dictionary = {}
var scene_names: Array = []

var camera: Camera2D
var world: Node2D
var nav_region: NavigationRegion2D
var player: Node2D
var agent: NavigationAgent2D
var ui: CanvasLayer
var subtitle: Label
var verbcoin: Control
var name_nodes: Dictionary = {}   # sprite/hotspot name -> node
var fileid_nodes: Dictionary = {} # scene fileID -> node
var characters: Dictionary = {}   # name -> node
var music_player: AudioStreamPlayer
var ambience_player: AudioStreamPlayer

var _moving := false
var _move_target := Vector2.ZERO
signal _arrived

func _ready() -> void:
	var rname: String = Game.room_name if Game.room_name != "" else Game.load_scene_data("manifest").get("start", "Office")
	if rname == "":
		rname = "Office"
	# Dev override: ?room=Kitchen or #room=Kitchen in the URL loads that room (web).
	if OS.has_feature("web") and Game.room_name == "":
		var hint := _url_room_hint()
		if hint != "":
			rname = hint
	Game.room_name = rname
	data = Game.load_scene_data(rname)
	refs = data.get("refs", {})
	action_lists = data.get("actionLists", {})
	conversations = data.get("conversations", {})
	scene_names = Game.load_scene_data("manifest").get("scenes", [])
	Game.current_room = self

	world = Node2D.new(); world.name = "World"; add_child(world)
	_build_sprites()
	_build_nav()
	_build_player()
	_build_hotspots()
	_build_camera()
	_build_rain()
	_build_highlighter()
	_build_ui()
	_build_audio()

	# Run the room's OnStart cutscene, else just enter gameplay.
	await get_tree().process_frame
	var start_id = data.get("onStart")
	if start_id != null and action_lists.has(str(start_id)):
		var runner := ActionRunner.new(self)
		add_child(runner)
		await runner.run(action_lists[str(start_id)].get("actions", []), true)
	Game.set_state(Game.State.GAMEPLAY)

# ------------------------------------------------------------------ build
func _build_sprites() -> void:
	for s in data.get("sprites", []):
		var tex_path: String = s.get("texture", "")
		if not ResourceLoader.exists(tex_path):
			continue
		var spr := Sprite2D.new()
		var base_tex: Texture2D = load(tex_path)
		var region = s.get("region")
		if region != null and region.size() == 4:
			var at := AtlasTexture.new()
			at.atlas = base_tex
			at.region = Rect2(region[0], region[1], region[2], region[3])
			spr.texture = at
		else:
			spr.texture = base_tex
		spr.centered = true
		# Honor the Unity sprite pivot (py from bottom): anchor that point to the
		# transform position. Center-pivot -> offset 0; bottom-center -> shift up.
		var piv = s.get("pivot", [0.5, 0.5])
		var tw := float(spr.texture.get_width())
		var th := float(spr.texture.get_height())
		spr.offset = Vector2(tw * (0.5 - piv[0]), th * (piv[1] - 0.5))
		spr.position = Vector2(s["pos"][0], s["pos"][1])
		spr.scale = Vector2(s["scale"][0], s["scale"][1])
		spr.flip_h = int(s.get("flipX", 0)) == 1
		spr.z_index = int(s.get("order", 0))
		var c = s.get("color", [1,1,1,1])
		spr.modulate = Color(c[0], c[1], c[2], c[3])
		spr.visible = int(s.get("enabled", 1)) == 1
		spr.name = _safe(s.get("name", "sprite"))
		world.add_child(spr)
		name_nodes[s.get("name", "")] = spr

var walkable := PackedVector2Array()   # first nav outline, for clamping walk targets

func _build_nav() -> void:
	# The original Unity nav mesh self-intersects under Godot's baker, so instead
	# of a NavigationRegion we keep the outline and clamp walk targets into it.
	var polys: Array = data.get("navPolys", [])
	if polys.is_empty():
		return
	for p in polys[0]:
		walkable.append(Vector2(p[0], p[1]))

var player_sprite: AnimatedSprite2D
var _facing := "down"
var _talking := false

func _build_player() -> void:
	player = Node2D.new(); player.name = "Player"; player.z_index = -3
	player_sprite = _build_teesa_sprite()
	if player_sprite:
		player.add_child(player_sprite)
	else:
		# fallback placeholder if the sheet data is unavailable
		var body := Polygon2D.new()
		body.polygon = PackedVector2Array([
			Vector2(-16, -70), Vector2(16, -70), Vector2(20, 0), Vector2(-20, 0)])
		body.color = Color(0.75, 0.28, 0.30)
		player.add_child(body)
	# spawn at first playerStart or first marker or origin
	var start := Vector2.ZERO
	var ps: Array = data.get("playerStarts", [])
	if not ps.is_empty():
		start = Vector2(ps[0]["pos"][0], ps[0]["pos"][1])
	elif not data.get("markers", []).is_empty():
		var m0 = data["markers"][0]
		start = Vector2(m0["pos"][0], m0["pos"][1])
	if Game.pending_marker != "":
		for m in data.get("markers", []):
			if m.get("name") == Game.pending_marker:
				start = Vector2(m["pos"][0], m["pos"][1])
	player.position = start
	add_child(player)
	characters["Teesa"] = player
	_play_anim("idle")

# Build Teesa's AnimatedSprite2D from the extracted sprite-sheet data (teesa.json).
func _build_teesa_sprite() -> AnimatedSprite2D:
	var td := Game.load_scene_data("teesa")
	if td.is_empty() or not ResourceLoader.exists(td.get("texture", "")):
		return null
	var tex: Texture2D = load(td["texture"])
	var fsz = td.get("frameSize", [40, 80])
	var frames := SpriteFrames.new()
	frames.remove_animation("default")
	for anim_name in td.get("anims", {}).keys():
		var rects: Array = td["anims"][anim_name]
		if rects.is_empty():
			continue
		frames.add_animation(anim_name)
		frames.set_animation_loop(anim_name, true)
		var fps: float = float(td.get("fps", {}).get(anim_name, 8.0))
		if anim_name.begins_with("idle"):
			fps = min(fps, 2.5)   # idle should breathe, not flicker
		frames.set_animation_speed(anim_name, fps)
		for r in rects:
			var at := AtlasTexture.new()
			at.atlas = tex
			at.region = Rect2(r[0], r[1], r[2], r[3])
			frames.add_frame(anim_name, at)
	var spr := AnimatedSprite2D.new()
	spr.sprite_frames = frames
	spr.centered = true
	spr.offset = Vector2(0, -float(fsz[1]) / 2.0)  # feet at the node origin
	return spr

func _play_anim(state: String) -> void:
	if player_sprite == null:
		return
	var key := state + "_" + _facing
	if not player_sprite.sprite_frames.has_animation(key):
		key = state + "_down"
	if player_sprite.sprite_frames.has_animation(key):
		if player_sprite.animation != key or not player_sprite.is_playing():
			player_sprite.play(key)

var _hotspots: Array = []   # [{rect: Rect2 (world), data: h, enabled: bool}]

func _build_hotspots() -> void:
	for h in data.get("hotspots", []):
		if h.get("buttons", []).is_empty():
			continue
		var box = h.get("box")
		var size: Vector2; var center: Vector2
		if box:
			size = Vector2(max(box["size"][0], 24), max(box["size"][1], 24))
			center = Vector2(box["pos"][0], box["pos"][1])
		else:
			size = Vector2(120, 120)
			center = Vector2(h["pos"][0], h["pos"][1])
		_hotspots.append({
			"rect": Rect2(center - size / 2.0, size),
			"data": h, "enabled": true, "area": size.x * size.y,
		})

# Pick the smallest hotspot whose rect contains the world point (so a big scenery
# hotspot never swallows a click meant for a character standing in front of it).
func _hotspot_at(world: Vector2) -> Dictionary:
	var best := {}
	var best_area := INF
	for hs in _hotspots:
		if hs["enabled"] and hs["rect"].has_point(world) and hs["area"] < best_area:
			best = hs; best_area = hs["area"]
	return best

func _url_room_hint() -> String:
	if not OS.has_feature("web"):
		return ""
	var js = JavaScriptBridge.eval("(location.hash+location.search).match(/room=([A-Za-z]+)/)?.[1]||''", true)
	return str(js) if js != null else ""

var _bg_rect := Rect2()          # background bounds in world space (for camera clamp)

func _build_camera() -> void:
	camera = Camera2D.new()
	camera.name = "Camera"
	# Find the background (widest sprite behind everything) and its world rect.
	var bg_w := 0.0
	var bg_h := 180.0
	var bg_center := Vector2.ZERO
	for s in data.get("sprites", []):
		if int(s.get("order", 0)) <= -8:
			var t = name_nodes.get(s.get("name", ""))
			if t and t is Sprite2D and t.texture:
				var w: float = t.texture.get_width() * abs(t.scale.x)
				if w > bg_w:
					bg_w = w
					bg_h = t.texture.get_height() * abs(t.scale.y)
					# visual centre = transform pos + pivot offset (offset is unscaled)
					bg_center = t.position + t.offset * t.scale
	if bg_w <= 0.0:
		bg_w = 320.0
	_bg_rect = Rect2(bg_center - Vector2(bg_w, bg_h) / 2.0, Vector2(bg_w, bg_h))
	camera.position = bg_center
	camera.enabled = true
	add_child(camera)
	camera.make_current()
	_update_camera()

# "Cover" the viewport with the background: scale so it fills both axes (no bars),
# then follow the player within the background bounds (side-scrolling). Recomputed
# each frame so it adapts to the window/canvas size.
func _update_camera() -> void:
	if camera == null or _bg_rect.size.x <= 0.0:
		return
	var vp := get_viewport_rect().size
	var z: float = max(vp.x / _bg_rect.size.x, vp.y / _bg_rect.size.y)
	camera.zoom = Vector2(z, z)
	var half := vp / (2.0 * z)                  # half the visible world extent
	var c := _bg_rect.get_center()
	var target := Vector2(player.global_position.x if player != null else c.x, c.y)
	# Clamp so we never show past the background edges.
	var min_x := _bg_rect.position.x + half.x
	var max_x := _bg_rect.end.x - half.x
	var min_y := _bg_rect.position.y + half.y
	var max_y := _bg_rect.end.y - half.y
	target.x = clamp(target.x, min_x, max_x) if min_x <= max_x else c.x
	target.y = clamp(target.y, min_y, max_y) if min_y <= max_y else c.y
	camera.position = target

# Pixel-art rain confined to the office window glass (the Window-Outside sprite).
func _build_rain() -> void:
	var win = name_nodes.get("Window-Outside")
	if win == null or not (win is Sprite2D) or win.texture == null:
		return
	var w: float = win.texture.get_width() * abs(win.scale.x)
	var h: float = win.texture.get_height() * abs(win.scale.y)
	var center: Vector2 = win.position + win.offset * win.scale
	var glass := Rect2(center - Vector2(w, h) / 2.0, Vector2(w, h)).grow(-3.0)
	var rain := RainLayer.new()
	rain.z_index = int(win.z_index) + 1     # in front of the mountain, behind gameplay
	world.add_child(rain)
	rain.setup(glass)

var _highlighter: Node2D
var _highlight_on := false
var _verbcoin_menu: Control     # the open interaction menu, for cancel-on-leave

# SPACE = "show all usable objects" (the original's hotspot highlight). Draws an
# outline + marker over every enabled hotspot while held.
func _build_highlighter() -> void:
	_highlighter = Node2D.new()
	_highlighter.name = "Highlights"
	_highlighter.z_index = 60
	add_child(_highlighter)
	_highlighter.draw.connect(_draw_highlights)

func _draw_highlights() -> void:
	if not _highlight_on:
		return
	var col := Color(1.0, 0.95, 0.4, 0.9)
	for hs in _hotspots:
		if not hs["enabled"]:
			continue
		var r: Rect2 = hs["rect"]
		_highlighter.draw_rect(r, Color(1, 0.95, 0.4, 0.12), true)
		_highlighter.draw_rect(r, col, false, 1.5)
		_highlighter.draw_circle(r.get_center(), 2.0, col)

func _build_ui() -> void:
	ui = CanvasLayer.new(); ui.name = "UI"; add_child(ui)
	subtitle = Label.new()
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	subtitle.anchor_left = 0.1; subtitle.anchor_right = 0.9
	subtitle.anchor_top = 0.02; subtitle.anchor_bottom = 0.18
	subtitle.offset_left = 0; subtitle.offset_right = 0
	subtitle.add_theme_font_size_override("font_size", 24)
	subtitle.add_theme_color_override("font_outline_color", Color.BLACK)
	subtitle.add_theme_constant_override("outline_size", 6)
	subtitle.visible = false
	ui.add_child(subtitle)
	verbcoin = Control.new()
	verbcoin.visible = false
	ui.add_child(verbcoin)

func _build_audio() -> void:
	music_player = AudioStreamPlayer.new(); add_child(music_player)
	ambience_player = AudioStreamPlayer.new(); add_child(ambience_player)

# ------------------------------------------------------------------ input
func _unhandled_input(event: InputEvent) -> void:
	# Dev shortcut: press C to start the room's first conversation (deterministic
	# test hook; harmless in play). Useful because character positions vary at boot.
	if event is InputEventKey and event.pressed and event.keycode == KEY_C:
		if Game.is_gameplay() and not conversations.is_empty():
			var first_id = conversations.keys()[0]
			var runner := ActionRunner.new(self)
			add_child(runner)
			runner.run([{ "type": "ActionConversation",
				"conversation": {"fileID": first_id}, "endAction": 1 }], true)
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if verbcoin.visible:
			return
		if not Game.is_gameplay():
			return
		var wpos := get_global_mouse_position()
		var hs := _hotspot_at(wpos)
		if not hs.is_empty():
			var r: Rect2 = hs["rect"]
			_show_verbcoin(hs["data"], r.position + r.size / 2.0)
		else:
			walk_player_to(wpos)

# ------------------------------------------------------------------ verb coin
func _show_verbcoin(h: Dictionary, at: Vector2) -> void:
	for c in verbcoin.get_children():
		c.queue_free()
	verbcoin.set_anchors_preset(Control.PRESET_FULL_RECT)
	verbcoin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	verbcoin.visible = true
	# full-screen closer behind the menu
	var closer := Button.new()
	closer.flat = true
	closer.set_anchors_preset(Control.PRESET_FULL_RECT)
	closer.pressed.connect(func(): verbcoin.visible = false)
	verbcoin.add_child(closer)
	# The interaction "coin": the original's cursor icons in a row near the hotspot
	# (Betrachte / Sprich mit / Benutze), falling back to text if an icon is missing.
	var menu := HBoxContainer.new()
	menu.add_theme_constant_override("separation", 4)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.6); sb.set_content_margin_all(4)
	sb.set_corner_radius_all(4)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", sb)
	panel.add_child(menu)
	var verbs := {}
	for b in h.get("buttons", []):
		verbs[b.get("verb", "use")] = b
	var labels := {"look": "Betrachte", "talk": "Sprich mit", "use": "Benutze"}
	for v in ["look", "talk", "use"]:
		if not verbs.has(v):
			continue
		var b: Dictionary = verbs[v]
		var icon_path := str(Game.icon_by_id.get(int(b.get("iconID", -1)), ""))
		var btn := Button.new()
		btn.tooltip_text = labels.get(v, v)
		if icon_path != "" and ResourceLoader.exists(icon_path):
			btn.icon = load(icon_path)
			btn.expand_icon = true
			btn.custom_minimum_size = Vector2(40, 40)
			btn.add_theme_constant_override("icon_max_width", 34)
		else:
			btn.text = labels.get(v, v)
			btn.custom_minimum_size = Vector2(110, 34)
		btn.pressed.connect(_run_interaction.bind(b, h))
		menu.add_child(btn)
	verbcoin.add_child(panel)
	# position the coin near the hotspot, clamped on-screen
	var screen := get_viewport().get_canvas_transform() * at
	var vp := get_viewport_rect().size
	panel.reset_size()
	panel.position = Vector2(
		clamp(screen.x - 60, 4, vp.x - 150),
		clamp(screen.y - 55, 4, vp.y - 60))
	_verbcoin_menu = panel

func _run_interaction(btn: Dictionary, h: Dictionary) -> void:
	verbcoin.visible = false
	var fid := str(btn.get("interaction", ""))
	if not action_lists.has(fid):
		return
	# Walk near the hotspot first (AC playerAction "WalkTo").
	if h.get("box"):
		var near := Vector2(h["box"]["pos"][0], h["box"]["pos"][1] + h["box"]["size"][1] * 0.5)
		await walk_player_to(near)
	var runner := ActionRunner.new(self)
	add_child(runner)
	await runner.run(action_lists[fid].get("actions", []), true)

# ------------------------------------------------------------------ services
func _physics_process(_delta: float) -> void:
	_update_camera()
	# SPACE highlights all hotspots (only during gameplay).
	var want_hl := Game.is_gameplay() and Input.is_physical_key_pressed(KEY_SPACE)
	if want_hl != _highlight_on and _highlighter != null:
		_highlight_on = want_hl
		_highlighter.queue_redraw()
	# #4: the interaction menu cancels when the cursor moves away from it.
	if verbcoin != null and verbcoin.visible and _verbcoin_menu != null:
		var box := Rect2(_verbcoin_menu.global_position, _verbcoin_menu.size).grow(44.0)
		if not box.has_point(_verbcoin_menu.get_global_mouse_position()):
			verbcoin.visible = false
	if not _moving:
		return
	var dir := _move_target - player.global_position
	var dist := dir.length()
	if dist <= 4.0:
		_moving = false
		if not _talking:
			_play_anim("idle")
		emit_signal("_arrived")
		return
	player.global_position += dir.normalized() * PLAYER_SPEED * _delta
	_facing = _dir_to_facing(dir)
	_play_anim("walk")

func _dir_to_facing(v: Vector2) -> String:
	if abs(v.x) >= abs(v.y):
		return "left" if v.x < 0 else "right"
	return "up" if v.y < 0 else "down"

func walk_player_to(target: Vector2) -> void:
	_move_target = _clamp_walk(target)
	_moving = true
	await _arrived

func _clamp_walk(target: Vector2) -> Vector2:
	if walkable.size() < 3:
		return target
	if Geometry2D.is_point_in_polygon(target, walkable):
		return target
	# snap to nearest point on the polygon boundary
	var best := target
	var best_d := INF
	for i in walkable.size():
		var a := walkable[i]
		var b := walkable[(i + 1) % walkable.size()]
		var c := Geometry2D.get_closest_point_to_segment(target, a, b)
		var d := target.distance_squared_to(c)
		if d < best_d:
			best_d = d; best = c
	return best

func walk_char_to(c: Node, target: Vector2) -> void:
	# NPCs teleport-glide for the slice.
	var tw := create_tween()
	tw.tween_property(c, "position", target, max(0.2, c.position.distance_to(target) / PLAYER_SPEED))
	await tw.finished

func set_player_position(p: Vector2) -> void:
	player.global_position = p

func player_position() -> Vector2:
	return player.global_position

func face_player(dir: int) -> void:
	_facing = _ac_dir_to_facing(dir)
	if not _moving and not _talking:
		_play_anim("idle")

func _ac_dir_to_facing(dir: int) -> String:
	# AC _Direction: 0 Down,1 Left,2 Right,3 Up,4 DownLeft,5 DownRight,6 UpLeft,7 UpRight
	match dir:
		1, 6: return "left"
		2, 5: return "right"
		3: return "up"
		_: return "down"

func say(speaker: String, text: String, at: Vector2, background: bool, is_player: bool = false) -> void:
	if text.strip_edges() == "":
		return
	subtitle.text = (speaker + ": " + text) if speaker != "" else text
	subtitle.visible = true
	if is_player:
		_talking = true
		_play_anim("talk")
	var dur: float = clamp(text.length() * 0.055, 1.2, 6.0)
	if background:
		get_tree().create_timer(dur).timeout.connect(func():
			if subtitle.text.ends_with(text): subtitle.visible = false)
		if is_player:
			_talking = false
			_play_anim("idle")
		return
	# advance on timer or click
	var t := 0.0
	while t < dur:
		if Input.is_action_just_pressed("ui_accept") or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			await get_tree().create_timer(0.15).timeout
			break
		await get_tree().process_frame
		t += get_process_delta_time()
	subtitle.visible = false
	if is_player:
		_talking = false
		_play_anim("idle")

func ref(r) -> Dictionary:
	if r == null: return {}
	var fid := str(r.get("fileID", "")) if r is Dictionary else str(r)
	return refs.get(fid, {})

func node_for(r) -> Node:
	if r == null: return null
	var fid := str(r.get("fileID", "")) if r is Dictionary else str(r)
	if fileid_nodes.has(fid): return fileid_nodes[fid]
	var info = refs.get(fid, {})
	var nm = info.get("name", "")
	return name_nodes.get(nm)

func character(r) -> Node:
	var info := ref(r)
	return characters.get(info.get("name", ""))

func actionlist_by_ref(r) -> Dictionary:
	var fid := str(r.get("fileID", "")) if r is Dictionary else str(r)
	return action_lists.get(fid, {})

var conversations: Dictionary = {}
var conv_ui: Control
var conv_list: VBoxContainer
var _conv_choice = null
signal _conv_chosen

func conversation_by_ref(r) -> Dictionary:
	var fid := str(r.get("fileID", "")) if r is Dictionary else str(r)
	var c = conversations.get(fid)
	if c == null:
		return {}
	var out: Dictionary = (c as Dictionary).duplicate(true)
	out["id"] = fid
	return out

# Present the conversation's enabled options, run the chosen one's ActionList,
# then loop (conversationAction 0 = return) or end (1). Mirrors AC's Conversation.
func run_conversation(conv: Dictionary) -> void:
	var cid := str(conv.get("id", ""))
	var guard := 0
	while guard < 100:
		guard += 1
		var opts := []
		for o in conv.get("options", []):
			if Game.option_enabled(cid, int(o.get("num", 0)), int(o.get("isOn", 1)) == 1):
				opts.append(o)
		if opts.is_empty():
			break
		var chosen = await _present_options(opts)
		if chosen == null:
			break
		var al = action_lists.get(str(chosen.get("dialogueOption", "")), {})
		if al and not al.get("actions", []).is_empty():
			var runner := ActionRunner.new(self)
			add_child(runner)
			await runner.run(al.get("actions", []), false)
		var nc := str(chosen.get("newConversation", "0"))
		if nc != "0" and conversations.has(nc):
			conv = conversation_by_ref(nc)
			cid = nc
			continue
		if int(chosen.get("conversationAction", 0)) == 1:
			break
	_hide_conv_ui()

func _present_options(opts: Array):
	if conv_ui == null:
		_build_conv_ui()
	for c in conv_list.get_children():
		c.queue_free()
	for o in opts:
		var btn := Button.new()
		btn.text = str(o.get("label", "..."))
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		btn.custom_minimum_size = Vector2(0, 34)
		btn.add_theme_font_size_override("font_size", 20)
		btn.pressed.connect(func():
			_conv_choice = o
			emit_signal("_conv_chosen"))
		conv_list.add_child(btn)
	conv_ui.visible = true
	Game.set_state(Game.State.DIALOG)
	_conv_choice = null
	await _conv_chosen
	conv_ui.visible = false
	return _conv_choice

func _build_conv_ui() -> void:
	conv_ui = PanelContainer.new()
	conv_ui.anchor_left = 0.0; conv_ui.anchor_right = 1.0
	conv_ui.anchor_top = 0.62; conv_ui.anchor_bottom = 1.0
	conv_ui.offset_left = 12; conv_ui.offset_right = -12; conv_ui.offset_bottom = -12
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.72)
	sb.set_content_margin_all(10)
	conv_ui.add_theme_stylebox_override("panel", sb)
	conv_list = VBoxContainer.new()
	conv_list.add_theme_constant_override("separation", 4)
	conv_ui.add_child(conv_list)
	conv_ui.visible = false
	ui.add_child(conv_ui)

func _hide_conv_ui() -> void:
	if conv_ui:
		conv_ui.visible = false
	if Game.state == Game.State.DIALOG:
		Game.set_state(Game.State.GAMEPLAY)

func audio_music(a: Dictionary) -> void:
	pass  # music/ambience streams not yet imported

func audio_ambience(a: Dictionary) -> void:
	pass

func map_scene_name(unity_name: String) -> String:
	var map := {"TeaistCloisterOffice":"Office","TeaistCloisterKitchen":"Kitchen",
		"TeaistCloisterAnteroom":"Anteroom","IntroCutscene":"Intro",
		"TitleScreen":"Title","Credits":"Credits"}
	if map.has(unity_name): return map[unity_name]
	if scene_names.has(unity_name): return unity_name
	return ""

# ------------------------------------------------------------------ util
func _safe(s) -> String:
	return str(s).replace("/", "_").replace(":", "_").replace(" ", "_")

func _circle(r: float, center: Vector2) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 16:
		var a := TAU * i / 16.0
		pts.append(center + Vector2(cos(a), sin(a)) * r)
	return pts
