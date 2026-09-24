extends SceneTree
## Freezes a unit on the muzzle-flash frame under the real iso rig and the REAL
## glow environment, and screenshots it.
##
## Exists because the flash is the one thing in the game that CANNOT be judged
## from a still of the art: it is on screen for 55 ms (one frame of `fire_shoot`
## at 0.11 s), so watching for it in anim_gym.gd is a coin toss, and it is drawn
## additively over the body, so the PNG on its own says nothing about what lands.
## This pins the frame instead of waiting for it.
##
## The glow is the other half of the point. `main.tscn` sets
## `glow_hdr_threshold = 1.1`, so the flash blooms only because
## `unit_visual.gd ADDITIVE_GAIN` pushes it past 1.0. preview_sprite.gd builds
## its own environment with no glow at all, and would show a pass that does not
## bloom exactly as if it did.
##
## Tune `ADDITIVE_GAIN` and render_sprites.py `FLASH_EXPOSURE` against this.
##
##   SHOT_PATH=out.png SPRITE_YAW=135 SPRITE_ZOOM=5 \
##     godot --path . --script res://tools/_flash_check.gd
##
## MUST RUN WINDOWED -- headless builds no sprite layers at all
## (`unit_visual.gd _build_layers` returns early), so there is nothing to grab.

const PITCH := atan(1.0 / sqrt(2.0))
const ORTHO_SIZE := 12.0

var _elapsed := 0.0
var _ready_frames := 0
var _unit: Node3D = null
var _visual: Node = null


func _initialize() -> void:
	root.world_3d.environment = _environment()
	_build.call_deferred()


func _environment() -> Environment:
	# Copied from scenes/main.tscn, glow settings included.
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.06, 0.07, 0.09)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.52, 0.58)
	env.ambient_light_energy = 0.2
	env.glow_enabled = true
	env.set("glow_levels/2", 0.7)
	env.glow_intensity = 0.5
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	env.glow_hdr_threshold = 1.1
	return env


func _build() -> void:
	var scene_path := OS.get_environment("SPRITE_SCENE") if \
		OS.has_environment("SPRITE_SCENE") else "res://scenes/player_unit.tscn"
	var unit: Node3D = load(scene_path).instantiate()
	root.add_child(unit)
	if OS.has_environment("SPRITE_YAW"):
		unit.rotation.y = deg_to_rad(float(OS.get_environment("SPRITE_YAW")))

	var pivot := Node3D.new()
	pivot.rotation = Vector3(-PITCH, deg_to_rad(45.0), 0.0)
	root.add_child(pivot)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = float(OS.get_environment("SPRITE_ZOOM")) if \
		OS.has_environment("SPRITE_ZOOM") else ORTHO_SIZE
	cam.far = 200.0
	cam.position = Vector3(0.0, 0.0, 18.0)
	pivot.add_child(cam)
	cam.make_current()
	_unit = unit
	_visual = unit.get_node_or_null("Visual")


func _freeze_on_flash() -> void:
	# play_action picks the pose and the facing; the frame is then PINNED rather
	# than waited for, because frame 0 of fire_shoot lasts 55 ms and a timed grab
	# would be a coin toss.
	if _visual == null:
		return
	_visual.call("play_action", &"fire_shoot")
	for child in _visual.get_children():
		var sprite := child as AnimatedSprite3D
		if sprite == null:
			continue
		sprite.pause()
		sprite.frame = 0
		var tex := sprite.sprite_frames.get_frame_texture(sprite.animation, 0) \
			if sprite.sprite_frames.has_animation(sprite.animation) else null
		print("[flash_check]   %s: anim='%s' visible=%s tex=%s override=%s" % [
			sprite.name, sprite.animation, sprite.visible,
			tex.get_size() if tex else "none",
			sprite.material_override])


func _process(delta: float) -> bool:
	_elapsed += delta
	if _visual == null or _elapsed < 1.0:
		return false
	_ready_frames += 1
	# The unit's own _process drops it straight back to idle, so pinning the
	# frame while it still runs is a race the grab loses. Stop the unit FIRST,
	# then pose it by direct call -- which still works on a disabled node -- and
	# nothing can revert it before the screenshot.
	if _ready_frames == 1:
		_unit.process_mode = Node.PROCESS_MODE_DISABLED
		return false
	if _ready_frames == 2:
		_freeze_on_flash()
		return false
	if _ready_frames < 5:
		return false
	var img := root.get_texture().get_image()
	var path := OS.get_environment("SHOT_PATH") if OS.has_environment("SHOT_PATH") \
		else "flash_check.png"
	print("[flash_check] wrote ", path, " err=", img.save_png(path))
	return true
