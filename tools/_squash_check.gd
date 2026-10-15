extends SceneTree
## Scratch: measures, end to end, whether a texel lands on screen where the
## Blender render put it.
##
## The render is a projection: a point at world height h, at the unit's own
## depth, was drawn `h * cos(pitch)` of CANVAS above the origin row. So the
## canvas row of any feature already encodes its screen offset, at
## `canvas_height / texture_height` metres per row. This asks whether the game
## reproduces that offset, by comparing the topmost drawn pixel against the
## unit's own unprojected origin. Ratio 1.0 is correct; anything else is a
## rescale the billboard is applying on top of the render.

const PITCH := atan(1.0 / sqrt(2.0))
const CAM_SIZE := 4.0

var _elapsed := 0.0
var _frames := 0
var _built := false
var _cam: Camera3D
var _unit: Node3D


func _initialize() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 1.0
	root.world_3d.environment = env
	_build.call_deferred()


func _build() -> void:
	# BEFORE the unit: UnitVisual looks the rig up in its own _ready, so a rig
	# added afterwards is one it never sees. UnitVisual finds it by GROUP --
	# without that the stand-in is invisible to it, _rig stays null, and every
	# camera-derived behaviour silently does nothing.
	var rig: Node3D = load("res://scenes/camera_rig.tscn").instantiate()
	_cam = rig.get_node("Camera3D")
	# Set BEFORE _ready, which seeds the zoom target from it -- assigning after
	# would be smoothed straight back to 10.5.
	_cam.size = CAM_SIZE
	root.add_child(rig)
	_cam.make_current()

	# No floor and no lamp: the measurement finds the topmost lit pixel, and
	# either one would hand it something that is not the character.
	_unit = load("res://scenes/player_unit.tscn").instantiate()
	root.add_child(_unit)
	_unit.rotation.y = deg_to_rad(float(OS.get_environment("SQ_YAW")) if
		OS.has_environment("SQ_YAW") else 180.0)
	for name in ["NameLabel", "Visual/Flashlight", "Visual/Beam"]:
		var n: Node = _unit.get_node_or_null(name)
		if n is Node3D:
			(n as Node3D).visible = false
	if OS.has_environment("SQ_SCALE"):
		# Applied here, not in _process: awaiting inside a _process that must return
		# a bool turns it into a coroutine that never reaches the measurement.
		var v: Node = _unit.get_node_or_null("Visual")
		for c2 in v.get_children():
			if c2 is AnimatedSprite3D:
				(c2 as AnimatedSprite3D).scale.y = float(OS.get_environment("SQ_SCALE"))
	_built = true


func _process(_delta: float) -> bool:
	_elapsed += _delta
	if not _built or _elapsed < 1.5:
		return false
	_frames += 1
	if _frames < 4:
		return false

	var vis: Node = _unit.get_node_or_null("Visual")
	var sprite: AnimatedSprite3D = null
	for child in vis.get_children():
		if child is AnimatedSprite3D:
			sprite = child
			break
	# Hide the light rig's own mesh if it drew anything.
	var tex := sprite.sprite_frames.get_frame_texture(sprite.animation, sprite.frame)
	var art := tex.get_image()
	var top_row := -1
	for y in art.get_height():
		for x in art.get_width():
			if art.get_pixel(x, y).a > 0.004:
				top_row = y
				break
		if top_row >= 0:
			break

	var h: float = art.get_height()
	var anchor_row: float = h * vis.get("foot_anchor").y
	var canvas_h: float = vis.get("canvas_height")
	# What the RENDER says: rows above the anchor, in screen metres.
	var want_m := (anchor_row - top_row) * (canvas_h / h)

	var frame := root.get_texture().get_image()
	var shot_top := -1
	for y in frame.get_height():
		for x in frame.get_width():
			var c := frame.get_pixel(x, y)
			if c.r + c.g + c.b > 0.12:
				shot_top = y
				break
		if shot_top >= 0:
			break

	var origin_px := _cam.unproject_position(_unit.global_position)
	var got_px := origin_px.y - shot_top
	var m_per_px := CAM_SIZE / float(frame.get_height())
	var got_m := got_px * m_per_px

	print("[squash] anim=%s art top row %d, anchor row %.1f -> render says %.4f m of screen"
		% [sprite.animation, top_row, anchor_row, want_m])
	print("[squash] on screen: origin at y=%.1f, top pixel at y=%d -> %.1f px = %.4f m"
		% [origin_px.y, shot_top, got_px, got_m])
	print("[squash] RATIO got/want = %.4f    (cos(pitch) = %.4f, 1/cos = %.4f)"
		% [got_m / want_m, cos(PITCH), 1.0 / cos(PITCH)])
	if OS.has_environment("SHOT_PATH"):
		frame.save_png(OS.get_environment("SHOT_PATH"))
	return true
