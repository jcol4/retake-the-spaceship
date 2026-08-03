extends SceneTree
## Stands one unit scene on an empty floor under the REAL isometric rig and
## screenshots it. Unlike tools/screenshot.gd's closeup, nothing here is
## approximated: same orthographic `size`, same pitch, same pixel-per-metre. It
## is the only way to judge whether sprite art is the right SCALE, because a
## perspective closeup answers a different question.
##
## Also sidesteps the room-visibility gating -- there is no map, so nothing can
## hide the unit for being in a room with no player in it.
##
##   SPRITE_SCENE=res://scenes/swarm_unit.tscn SHOT_PATH=out.png \
##     godot --path . --script res://tools/preview_sprite.gd
##
## SPRITE_YAW rotates the unit in degrees, to step through direction buckets.

const PITCH := atan(1.0 / sqrt(2.0))
## Matches camera_rig.tscn. Changing one without the other makes every
## measurement taken here a lie.
const ORTHO_SIZE := 12.0

var _elapsed := 0.0
var _ready_frames := 0
var _built := false


func _initialize() -> void:
	root.world_3d.environment = _environment()
	_build.call_deferred()


func _environment() -> Environment:
	# Flat ambient, no sun: the sprites are UNSHADED anyway, and a directional
	# light would only change how the reference floor reads.
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.09, 0.10, 0.12)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.72, 0.78)
	env.ambient_light_energy = 1.0
	return env


func _build() -> void:
	# A 1 m grid under the feet, so sprite scale is readable as "how many tiles
	# tall" rather than guessed, and any pivot offset shows as the unit standing
	# off its square.
	# SPRITE_BARE drops the grid so the sprite is the only thing in frame, which
	# is what makes the shot measurable by a script rather than only by eye.
	if not OS.has_environment("SPRITE_BARE"):
		var grid := MeshInstance3D.new()
		grid.mesh = _grid_mesh()
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(0.35, 0.38, 0.44)
		mat.vertex_color_use_as_albedo = true
		grid.material_override = mat
		root.add_child(grid)

	var scene_path := OS.get_environment("SPRITE_SCENE") if \
		OS.has_environment("SPRITE_SCENE") else "res://scenes/swarm_unit.tscn"
	var unit: Node3D = load(scene_path).instantiate()
	root.add_child(unit)
	if OS.has_environment("SPRITE_YAW"):
		unit.rotation.y = deg_to_rad(float(OS.get_environment("SPRITE_YAW")))

	var pivot := Node3D.new()
	pivot.rotation = Vector3(-PITCH, deg_to_rad(45.0), 0.0)
	root.add_child(pivot)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	# SPRITE_ZOOM tightens the framing for a detail read. It makes the shot no
	# longer representative of in-game size -- leave it unset to judge scale.
	cam.size = float(OS.get_environment("SPRITE_ZOOM")) if \
		OS.has_environment("SPRITE_ZOOM") else ORTHO_SIZE
	cam.far = 200.0
	cam.position = Vector3(0.0, 0.0, 18.0)
	pivot.add_child(cam)
	cam.make_current()

	# Sprites hide themselves when a layer has no art for the pose, so report
	# what actually resolved -- an empty screenshot and a correctly-hidden layer
	# look identical otherwise.
	var vis: Node = unit.get_node_or_null("Visual")
	if vis:
		print("[preview] variant=", vis.get("variant"), " layers=", vis.get("layers"))
		for child in vis.get_children():
			var sprite := child as AnimatedSprite3D
			if sprite:
				var tex := sprite.sprite_frames.get_frame_texture(sprite.animation, 0)
				print("[preview]   %s: '%s' visible=%s flip_h=%s tex=%s px=%.5f offset=%s" % [
					sprite.name, sprite.animation, sprite.visible, sprite.flip_h,
					tex.get_size() if tex else "none", sprite.pixel_size, sprite.offset])
	_built = true


func _grid_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_LINES)
	for i in range(-6, 7):
		# The unit's own square in red, so a pivot error is unmissable.
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
	_elapsed += delta
	if not _built or _elapsed < 1.5:
		return false
	# Two settled frames before grabbing: the sprite picks its direction bucket
	# in _process, so frame one can still be showing the wrong pose.
	_ready_frames += 1
	if _ready_frames < 3:
		return false
	var img := root.get_texture().get_image()
	var path := OS.get_environment("SHOT_PATH") if OS.has_environment("SHOT_PATH") \
		else "preview_sprite.png"
	print("[preview] wrote ", path, " err=", img.save_png(path))
	return true
