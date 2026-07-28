extends SceneTree
## Renders N evenly spaced frames of one clip as a horizontal strip, so motion
## can be judged from a still image. Loads a GLB directly rather than booting the
## game, so it shows the rig and nothing else -- no map, no lighting rig, no
## gameplay state to get in the way.
##
## Must run WINDOWED, not headless: headless has no renderer to capture.
##   godot --path . --script res://tools/preview_anim.gd
##
## Environment:
##   PREVIEW_GLB     asset to load        (default res://assets/soldier_mixamo.glb)
##   PREVIEW_CLIP    animation name       (default run)
##   PREVIEW_FRAMES  frames in the strip  (default 6)
##   PREVIEW_ANGLE   side | front         (default side)
##   SHOT_PATH       output png           (default out/preview.png)

const SETTLE_FRAMES := 2

var _clip := "run"
var _frames := 6
var _out := "out/preview.png"
var _shots: Array[Image] = []
var _anim: AnimationPlayer = null
var _index := 0
var _settle := 0
var _ready := false
var _done := false


func _env(key: String, fallback: String) -> String:
	return OS.get_environment(key) if OS.has_environment(key) else fallback


func _initialize() -> void:
	_clip = _env("PREVIEW_CLIP", "run")
	_frames = maxi(1, int(_env("PREVIEW_FRAMES", "6")))
	_out = _env("SHOT_PATH", "out/preview.png")
	var glb := _env("PREVIEW_GLB", "res://assets/soldier_mixamo.glb")

	DisplayServer.window_set_size(Vector2i(360, 540))

	var packed: PackedScene = load(glb)
	if packed == null:
		print("[preview] FAILED TO LOAD ", glb)
		quit()
		return
	var model: Node3D = packed.instantiate()
	root.add_child(model)

	# A static model is a legitimate thing to preview -- rifle.glb has no
	# AnimationPlayer, and looking at a weapon on its own is exactly how you
	# check its proportions before blaming the mount for how it sits.
	_anim = _find_player(model)
	if _anim == null:
		print("[preview] no AnimationPlayer in ", glb, " -- static render")
		_frames = 1
	elif not _anim.has_animation(_clip):
		print("[preview] no clip '", _clip, "'; have: ", _anim.get_animation_list())
		quit()
		return
	else:
		# The strip is built by seeking, not by playing: a played clip advances
		# by real delta, so the sampled times would drift with frame rate.
		_anim.play(_clip)
		_anim.pause()

	# PREVIEW_FOCUS/PREVIEW_DIST exist to frame the weapon rather than the whole
	# body: at full-figure framing a rifle is a hundred pixels and its grip is
	# about four, which is not enough to judge whether a hand is on it.
	var focus := Vector3(0.0, float(_env("PREVIEW_FOCUS", "0.95")), 0.0)
	var dist := float(_env("PREVIEW_DIST", "1.0"))
	var off := Vector3(3.1, 0.25, 0.0) * dist
	if _env("PREVIEW_ANGLE", "side") == "front":
		off = Vector3(0.9, 0.25, 2.9) * dist
	# look_at_from_position, not add_child + look_at: a node added during
	# _initialize is not inside the tree yet, so global_position and look_at
	# both no-op and leave the camera at the origin looking down -Z.
	var cam := Camera3D.new()
	cam.look_at_from_position(focus + off, focus)
	cam.fov = 40.0
	root.add_child(cam)
	cam.make_current()

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.13, 0.14, 0.16)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.54, 0.6)
	env.ambient_light_energy = 0.9
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)

	var key := DirectionalLight3D.new()
	key.look_at_from_position(focus + Vector3(2.5, 3.0, 2.0), focus)
	key.light_energy = 1.5
	root.add_child(key)

	print("[preview] clip='", _clip, "' length=", _anim.get_animation(_clip).length,
		"s frames=", _frames)
	_ready = true


func _find_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var found := _find_player(child)
		if found:
			return found
	return null


func _process(_delta: float) -> bool:
	if _done or not _ready:
		return false
	if _index >= _frames:
		_save()
		return true

	if _settle == 0 and _anim:
		# Sample across one loop: the last frame of a cycle duplicates the first,
		# so divide by _frames rather than _frames - 1.
		var length := _anim.get_animation(_clip).length
		_anim.seek(length * float(_index) / float(_frames), true)
	_settle += 1
	if _settle <= SETTLE_FRAMES:
		return false

	_shots.append(root.get_texture().get_image())
	_settle = 0
	_index += 1
	return false


func _save() -> void:
	_done = true
	var w := _shots[0].get_width()
	var h := _shots[0].get_height()
	var strip := Image.create(w * _shots.size(), h, false, _shots[0].get_format())
	for i in _shots.size():
		strip.blit_rect(_shots[i], Rect2i(0, 0, w, h), Vector2i(w * i, 0))
	var err := strip.save_png(_out)
	print("[preview] ", _out, " err=", err, " size=", strip.get_size())
	quit()
