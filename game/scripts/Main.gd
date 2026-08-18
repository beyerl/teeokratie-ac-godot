extends Node2D
## Room controller: builds a room from extracted JSON data and provides the
## services the ActionRunner calls (say, walk, ref resolution, audio, ...).

const PLAYER_SPEED := 320.0

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
	Game.room_name = rname
	data = Game.load_scene_data(rname)
	refs = data.get("refs", {})
	action_lists = data.get("actionLists", {})
	scene_names = Game.load_scene_data("manifest").get("scenes", [])
	Game.current_room = self

	world = Node2D.new(); world.name = "World"; add_child(world)
	_build_sprites()
	_build_nav()
	_build_player()
	_build_hotspots()
	_build_camera()
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

func _build_hotspots() -> void:
	for h in data.get("hotspots", []):
		if h.get("buttons", []).is_empty():
			continue
		var area := Area2D.new()
		area.name = _safe("HS_" + str(h.get("name", "hs")))
		var box = h.get("box")
		var cs := CollisionShape2D.new()
		var shape := RectangleShape2D.new()
		if box:
			shape.size = Vector2(max(box["size"][0], 24), max(box["size"][1], 24))
			area.position = Vector2(box["pos"][0], box["pos"][1])
		else:
			shape.size = Vector2(120, 120)
			area.position = Vector2(h["pos"][0], h["pos"][1])
		cs.shape = shape
		area.add_child(cs)
		area.input_pickable = true
		area.set_meta("hotspot", h)
		area.input_event.connect(_on_hotspot_input.bind(area))
		add_child(area)
		name_nodes[h.get("name", "")] = area

func _build_camera() -> void:
	camera = Camera2D.new()
	camera.name = "Camera"
	# Fit the widest background sprite into the viewport (pixel art -> zoom in).
	var bg_w := 0.0
	var bg_center := Vector2.ZERO
	for s in data.get("sprites", []):
		if int(s.get("order", 0)) <= -8:
			var t = name_nodes.get(s.get("name", ""))
			if t and t is Sprite2D and t.texture:
				var w: float = t.texture.get_width() * abs(t.scale.x)
				if w > bg_w:
					bg_w = w
					bg_center = t.position
	if bg_w <= 0.0:
		bg_w = 320.0
	var vw := float(ProjectSettings.get_setting("display/window/size/viewport_width", 960))
	var z: float = clamp(vw / bg_w, 0.5, 6.0)
	camera.zoom = Vector2(z, z)
	camera.position = bg_center
	camera.enabled = true
	add_child(camera)
	camera.make_current()

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
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if verbcoin.visible:
			return
		if Game.is_gameplay():
			var wpos := get_global_mouse_position()
			walk_player_to(wpos)

func _on_hotspot_input(_viewport, event, _shape_idx, area: Area2D) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	if not Game.is_gameplay():
		return
	if not area.get_meta("hotspot_enabled", true):
		return
	_show_verbcoin(area.get_meta("hotspot"), area.global_position)

# ------------------------------------------------------------------ verb coin
func _show_verbcoin(h: Dictionary, at: Vector2) -> void:
	for c in verbcoin.get_children():
		c.queue_free()
	verbcoin.visible = true
	var screen := get_viewport().get_canvas_transform() * at
	var verbs := {}
	for b in h.get("buttons", []):
		verbs[b.get("verb", "use")] = b
	var order := ["look", "talk", "use"]
	var i := 0
	for v in order:
		if not verbs.has(v):
			continue
		var btn := Button.new()
		btn.text = {"look":"Betrachte","talk":"Sprich mit","use":"Benutze"}.get(v, v)
		btn.position = screen + Vector2(-40, -50 + i * 34)
		btn.pressed.connect(_run_interaction.bind(verbs[v], h))
		verbcoin.add_child(btn)
		i += 1
	# click elsewhere closes
	var closer := Button.new()
	closer.flat = true
	closer.text = ""
	closer.anchor_right = 1; closer.anchor_bottom = 1
	closer.z_index = -1
	closer.pressed.connect(func(): verbcoin.visible = false)
	verbcoin.add_child(closer)
	verbcoin.move_child(closer, 0)

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

func conversation_by_ref(_r) -> Dictionary:
	return {}

func run_conversation(_conv) -> void:
	return

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
