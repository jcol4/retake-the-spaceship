extends SceneTree
## Renders a contact sheet of the weapon across many poses, in one run.
##
## Two modes, because both questions are "does this read right across a RANGE"
## and a single screenshot cannot answer either.
##
##   SHEET_MODE=clips  (default) one panel per weapon-holding clip. The grip is
##       a single fixed offset shared by every clip, so the only honest test is
##       all of them side by side rather than the one that was tuned.
##
##   SHEET_MODE=aim    one panel per target height, on aim_hold. This is the ONLY
##       way to judge AimPitch: it holds _has_target = false until something
##       calls aim_at() at runtime, so scrubbing the AnimationPlayer in the
##       editor shows a node that does nothing at all.
##
## Panels are captured from the live viewport, so this must run WINDOWED --
## headless has no framebuffer to read back.
##
##   SHOT_PATH=out/sheet.png SHEET_MODE=clips \
##     godot --path . --script res://tools/shot_sheet.gd
##
## Optional: SHEET_COLS (default 3), SHEET_SIDE=1 for the off-shoulder camera,
## SHEET_SCALE (default 0.42 of viewport per panel).

const CLIPS := ["idle", "run", "aim_hold", "crouch_idle", "run_stop",
	"stand_to_crouch", "crouch_to_stand", "shoot_recoil", "overwatch_hold"]

# Metres above/below the shooter's own chest, at 3 m range. Spans the realistic
# extremes: a target prone on the deck, level, and up a full storey.
const AIM_HEIGHTS := [-1.6, -0.8, 0.0, 0.8, 1.6, 2.6]

const SETTLE := 3  # frames between posing and reading the framebuffer

var _elapsed := 0.0
var _ready_done := false
var _stage := 0
var _substage := 0
var _shots: Array[Image] = []
var _labels: Array[String] = []
var _unit: Node3D = null
var _vis: Node = null
var _ap: AnimationPlayer = null
var _mode := "clips"


func _initialize() -> void:
	_mode = OS.get_environment("SHEET_MODE") if OS.has_environment("SHEET_MODE") \
		else "clips"
	change_scene_to_file.call_deferred("res://scenes/main.tscn")


func _count() -> int:
	return AIM_HEIGHTS.size() if _mode == "aim" else CLIPS.size()


func _setup() -> bool:
	var units := root.get_tree().get_nodes_in_group("player_units")
	if units.is_empty():
		print("[sheet] no player units")
		return false
	_unit = units[0]
	_vis = _unit.get_node_or_null("Visual")
	_ap = _unit.get_node_or_null("Visual/soldier/AnimationPlayer") as AnimationPlayer
	if _vis == null or _ap == null:
		print("[sheet] visual=%s anim=%s" % [_vis, _ap])
		return false

	for n in root.find_children("*", "CanvasLayer", true, false):
		(n as CanvasLayer).visible = false

	var focus: Vector3 = _unit.global_position + Vector3(0.0, 0.95, 0.0)
	var cam := Camera3D.new()
	root.add_child(cam)
	var off := Vector3(1.5, 0.9, -2.3)
	if OS.has_environment("SHEET_SIDE"):
		off = Vector3(3.0, 0.85, 0.0)
	cam.global_position = focus + off
	cam.look_at(focus)
	cam.fov = 45.0
	cam.make_current()
	var light := DirectionalLight3D.new()
	root.add_child(light)
	light.global_position = focus + Vector3(2.0, 3.0, -2.0)
	light.look_at(focus)
	light.light_energy = 0.55
	return true


func _refresh() -> void:
	## Both AimPitch and WeaponMount recompute on skeleton_updated, which a PAUSED
	## AnimationPlayer does not emit. Without this the panel shows the new body
	## pose with the weapon still placed from the previous one.
	var skel_path := "Visual/soldier/Rig/Skeleton3D/"
	for n in ["AimPitch", "RifleMount"]:
		var node := _unit.get_node_or_null(skel_path + n)
		if node and node.has_method("_follow"):
			node.call("_follow")


func _pose(i: int) -> void:
	if _mode == "aim":
		if _ap.has_animation("aim_hold"):
			_ap.play("aim_hold")
			_ap.advance(_ap.get_animation("aim_hold").length * 0.5)
			_ap.pause()
		var h: float = AIM_HEIGHTS[i]
		# 3 m straight ahead of the unit, offset vertically. -Z is Godot forward.
		var target: Vector3 = _unit.global_position \
			+ (-_unit.global_transform.basis.z.normalized() * 3.0) \
			+ Vector3(0.0, 1.2 + h, 0.0)
		if _vis.has_method("set_aim_pitch"):
			_vis.call("set_aim_pitch", target)
		# AimPitch recomputes on skeleton_updated, which a paused player does not
		# emit on its own -- without this the target is set and never applied.
		_ap.advance(0.0)
		_labels.append("aim %+.1f m" % h)
	else:
		var clip: String = CLIPS[i]
		if not _ap.has_animation(clip):
			_labels.append(clip + " (absent)")
			return
		_ap.play(clip)
		_ap.advance(_ap.get_animation(clip).length * 0.5)
		_ap.pause()
		_labels.append(clip)


func _compose(path: String) -> void:
	if _shots.is_empty():
		print("[sheet] nothing captured")
		return
	var scale := 0.42
	if OS.has_environment("SHEET_SCALE"):
		scale = float(OS.get_environment("SHEET_SCALE"))
	var cols := 3
	if OS.has_environment("SHEET_COLS"):
		cols = int(OS.get_environment("SHEET_COLS"))
	var pw := int(_shots[0].get_width() * scale)
	var ph := int(_shots[0].get_height() * scale)
	var rows := int(ceil(float(_shots.size()) / float(cols)))
	var sheet := Image.create(pw * cols, ph * rows, false, _shots[0].get_format())
	sheet.fill(Color(0.06, 0.06, 0.07))
	for i in _shots.size():
		var im: Image = _shots[i]
		im.resize(pw, ph, Image.INTERPOLATE_BILINEAR)
		sheet.blit_rect(im, Rect2i(0, 0, pw, ph),
			Vector2i((i % cols) * pw, (i / cols) * ph))
	var err := sheet.save_png(path)
	print("[sheet] wrote %s (%dx%d) err=%d" % [path, sheet.get_width(),
		sheet.get_height(), err])
	print("[sheet] panel order, left to right then down, %d per row:" % cols)
	for i in _labels.size():
		print("  %d. %s" % [i + 1, _labels[i]])


func _process(delta: float) -> bool:
	_elapsed += delta
	if _elapsed < 2.0:
		return false
	if not _ready_done:
		_ready_done = true
		if not _setup():
			quit()
			return true
		return false

	if _stage >= _count():
		var path := OS.get_environment("SHOT_PATH")
		if path == "":
			path = "out/sheet.png"
		_compose(path)
		quit()
		return true

	if _substage == 0:
		_pose(_stage)
		_refresh()
		_substage += 1
		return false
	if _substage <= SETTLE:
		_substage += 1
		return false
	_shots.append(root.get_texture().get_image())
	_stage += 1
	_substage = 0
	return false
