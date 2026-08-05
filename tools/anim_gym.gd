extends SceneTree
## Stands one unit on a grid and runs its animations on a loop, live.
##
##   godot --path . --script res://tools/anim_gym.gd
##
##   GYM_SCENE=res://scenes/player_unit.tscn   which unit
##   GYM_YAW=45                                starting facing, degrees
##   GYM_SPIN=1                                turn slowly, to see all 8 buckets
##   GYM_POSE=idle                             hold one pose instead of cycling
##
## MUST RUN WINDOWED -- no --headless. There is nothing to screenshot here; the
## point is watching a cycle play, which is the one thing tools/preview_sprite.gd
## cannot show you. That tool answers "is the art the right SCALE"; this one
## answers "does the motion read".
##
## Uses the same rig geometry as preview_sprite.gd, and for the same reason: an
## animation judged under a perspective closeup is being judged at a camera angle
## the game never uses.

const PITCH := atan(1.0 / sqrt(2.0))
## Matches camera_rig.tscn and preview_sprite.gd. Changing one without the others
## makes every judgement made here a lie.
const ORTHO_SIZE := 12.0

## Rounds per burst. The burst length is rolled per shot in game, so the gym
## rolls it too -- a fixed count would hide the thing most likely to be wrong,
## which is how the kick reads when it repeats.
const BURST_MIN := 3
const BURST_MAX := 5

## Seconds of idle either side of a burst, so the entry and exit seams are
## visible as seams rather than blurring into the next cycle.
const IDLE_BEAT := 2.0

const SPIN_RATE := 0.35  ## radians/sec when GYM_SPIN is set

var _unit: Node3D
var _visual: Node
var _spin := false
var _running := false


func _initialize() -> void:
	root.world_3d.environment = _environment()
	_build.call_deferred()


func _environment() -> Environment:
	# Flat ambient, no sun. The sprites are UNSHADED, so a directional light
	# would only change how the reference grid reads, not the character.
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.09, 0.10, 0.12)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.72, 0.78)
	env.ambient_light_energy = 1.0
	return env


func _build() -> void:
	var grid := MeshInstance3D.new()
	grid.mesh = _grid_mesh()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.35, 0.38, 0.44)
	mat.vertex_color_use_as_albedo = true
	grid.material_override = mat
	root.add_child(grid)

	var path := OS.get_environment("GYM_SCENE") if OS.has_environment("GYM_SCENE") \
		else "res://scenes/player_unit.tscn"
	_unit = load(path).instantiate()
	root.add_child(_unit)
	if OS.has_environment("GYM_YAW"):
		_unit.rotation.y = deg_to_rad(float(OS.get_environment("GYM_YAW")))
	_spin = OS.has_environment("GYM_SPIN")

	var pivot := Node3D.new()
	pivot.rotation = Vector3(-PITCH, deg_to_rad(45.0), 0.0)
	root.add_child(pivot)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = ORTHO_SIZE
	cam.far = 200.0
	cam.position = Vector3(0.0, 0.0, 18.0)
	pivot.add_child(cam)
	cam.make_current()

	_visual = _unit.get_node_or_null("Visual")
	if _visual == null:
		push_error("[gym] %s has no Visual node" % path)
		quit(1)
		return

	# Report what RESOLVED, not what was asked for. A layer with no art hides
	# itself, so a missing pose and a correct one look identical on screen --
	# this is the only place the difference is visible.
	print("[gym] %s  variant=%s  layers=%s" % [path, _visual.get("variant"), _visual.get("layers")])
	for child in _visual.get_children():
		var sprite := child as AnimatedSprite3D
		if sprite:
			print("[gym]   %s: %d animations, pixel_size=%.5f, offset=%s"
				% [sprite.name, sprite.sprite_frames.get_animation_names().size(),
				   sprite.pixel_size, sprite.offset])

	# One muzzle line per round, so the burst count is checkable from the log
	# rather than counted by eye at 0.11 s intervals.
	if _visual.has_signal("muzzle"):
		_visual.muzzle.connect(func() -> void: print("[gym]   muzzle"))
	if _visual.has_signal("footstep"):
		_visual.footstep.connect(func() -> void: print("[gym]   footstep"))

	_loop()


func _loop() -> void:
	if _running:
		return
	_running = true

	if OS.has_environment("GYM_POSE"):
		# Holding one pose is for judging a single cycle in isolation -- the
		# thing a full rotation through the chain makes hard to watch.
		var pose := StringName(OS.get_environment("GYM_POSE"))
		print("[gym] holding pose %s" % pose)
		_visual.call("set_stance", pose)
		return

	while true:
		print("[gym] idle")
		_visual.call("set_stance", &"idle")
		await create_timer(IDLE_BEAT).timeout

		print("[gym] run")
		_visual.call("set_stance", &"run")
		await create_timer(IDLE_BEAT).timeout

		_visual.call("set_stance", &"idle")
		var rounds := randi_range(BURST_MIN, BURST_MAX)
		print("[gym] burst of %d" % rounds)
		# play_burst is the real thing the game calls, not a re-implementation:
		# it plays begin_shoot, restarts fire_shoot once per round on
		# BURST_CADENCE, then end_shoot. Driving it any other way here would be
		# testing the gym rather than the game.
		await _visual.call("play_burst", rounds)


func _grid_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_LINES)
	for i in range(-6, 7):
		# The unit's own square in red, so a pivot error is unmissable: a
		# correctly anchored sprite stands ON the cross, not above or behind it.
		var axis := i == 0
		var c := Color(0.85, 0.25, 0.22) if axis else Color(0.35, 0.38, 0.44)
		st.set_color(c)
		st.add_vertex(Vector3(i, 0.01, -6.0))
		st.set_color(c)
		st.add_vertex(Vector3(i, 0.01, 6.0))
		st.set_color(c)
		st.add_vertex(Vector3(-6.0, 0.01, i))
		st.set_color(c)
		st.add_vertex(Vector3(6.0, 0.01, i))
	return st.commit()


func _process(delta: float) -> bool:
	if _spin and _unit:
		# Slow enough that each of the eight buckets is legible as it passes,
		# which is what makes a wrong-facing sprite obvious.
		_unit.rotation.y += SPIN_RATE * delta
	return false
