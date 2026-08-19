extends Node2D
class_name RainLayer
## A small pixel-art rain effect confined to a rectangle (the office window glass).
## Our own solution: light diagonal streaks falling and wrapping within the rect,
## plus occasional splashes at the bottom. Not a port of the Unity particle system.

var rect: Rect2
var _drops: Array = []            # each: {p: Vector2, len: float, spd: float}
var _splashes: Array = []         # each: {p: Vector2, t: float}
const DRIFT := -0.28              # horizontal lean (px per px fallen)
const COLOR := Color(0.78, 0.88, 1.0, 0.55)

func setup(r: Rect2, count: int = 26) -> void:
	rect = r
	_drops.clear()
	for i in count:
		_drops.append(_new_drop(true))

func _new_drop(anywhere: bool) -> Dictionary:
	var len := randf_range(3.0, 7.0)
	var x := randf_range(rect.position.x, rect.end.x)
	var y := randf_range(rect.position.y, rect.end.y - len) if anywhere else rect.position.y - len
	return {"p": Vector2(x, y), "len": len, "spd": randf_range(90.0, 190.0)}

func _process(delta: float) -> void:
	for d in _drops:
		d.p.y += d.spd * delta
		d.p.x += d.spd * delta * DRIFT
		if d.p.y > rect.end.y or d.p.x < rect.position.x:
			# splash at the foot of the pane, then respawn at the top
			if d.p.y > rect.end.y and randf() < 0.5:
				_splashes.append({"p": Vector2(clamp(d.p.x, rect.position.x, rect.end.x), rect.end.y), "t": 0.0})
			var nd := _new_drop(false)
			d.p = nd.p; d.len = nd.len; d.spd = nd.spd
	for s in _splashes:
		s.t += delta
	_splashes = _splashes.filter(func(s): return s.t < 0.35)
	queue_redraw()

func _draw() -> void:
	for d in _drops:
		var tail := Vector2(d.p.x - d.len * DRIFT, d.p.y - d.len)
		# keep rain inside the pane so it never spills onto the frame/wall
		if tail.y < rect.position.y or d.p.x < rect.position.x or d.p.x > rect.end.x:
			continue
		draw_line(tail, d.p, COLOR, 1.0)
	for s in _splashes:
		var a: float = (1.0 - float(s.t) / 0.35) * 0.5
		var r: float = 1.0 + float(s.t) * 6.0
		draw_arc(s.p, r, PI, TAU, 6, Color(0.85, 0.92, 1.0, a), 1.0)
