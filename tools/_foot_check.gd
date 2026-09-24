extends SceneTree
## Scratch: stands one unit per facing on a BRIGHT floor, each on its own marked
## tile, so any gap (or overlap) between the model's feet and the ground reads at
## a glance for all eight yaws at once.
##   FC_SCENE=res://scenes/player_unit.tscn FC_POSE=run SHOT_PATH=out.png \
##     godot --path . --script res://tools/_foot_check.gd
## FC_POSE is any UnitVisual stance (idle, run, walk, overwatch_hold, dead);
## FC_ZOOM is the ortho size (default 4).

const ALL_YAWS := [0.0, 45.0, 90.0, 135.0, 180.0, 225.0, 270.0, 315.0]
## FC_YAWS="0,90" narrows the row.
var YAWS: Array = ALL_YAWS if not OS.has_environment("FC_YAWS") \
	else Array(OS.get_environment("FC_YAWS").split(",")).map(func(s: String) -> float: return float(s))

var _elapsed := 0.0
var _frames := 0
var _built := false
var _units: Array[Node3D] = []


func _initialize() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.02, 0.03)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 0.6
	root.world_3d.environment = env
	_build.call_deferred()


func _plane(size: Vector2, color: Color, y: float) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := PlaneMesh.new()
	mesh.size = size
	node.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	node.material_override = mat
	node.position.y = y
	return node


func _build() -> void:
	var count := YAWS.size()
	var spacing := 2.0
	root.add_child(_plane(Vector2(spacing * count + 6.0, 8.0), Color(0.30, 0.33, 0.38), 0.0))
	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	root.add_child(sun)
	sun.rotation_degrees = Vector3(-55.0, 30.0, 0.0)

	var scene_path := OS.get_environment("FC_SCENE") if OS.has_environment("FC_SCENE") \
		else "res://scenes/player_unit.tscn"
	var scene: PackedScene = load(scene_path)

	# The REAL rig scene, before the units, so anything that looks it up by group
	# finds it.
	var rig: Node3D = load("res://scenes/camera_rig.tscn").instantiate()
	var cam: Camera3D = rig.get_node("Camera3D")
	# Set BEFORE _ready, which seeds the zoom target from it.
	cam.size = float(OS.get_environment("FC_ZOOM")) if OS.has_environment("FC_ZOOM") else 4.0
	root.add_child(rig)
	cam.make_current()

	# The row runs along the camera's screen-horizontal, so every unit is at the
	# same screen height and the eye compares foot to floor, not foot to foot.
	var along := Vector3(1.0, 0.0, -1.0).normalized()
	for i in count:
		var at := along * ((i - (count - 1) / 2.0) * spacing)
		var tile := _plane(Vector2(1.5, 1.5), Color(0.75, 0.18, 0.16), 0.005)
		tile.position += at
		root.add_child(tile)
		var unit: Node3D = scene.instantiate()
		root.add_child(unit)
		unit.position = at
		unit.rotation.y = deg_to_rad(YAWS[i])
		# Forward marker: a yellow bar along the unit's -Z, so a model facing
		# anywhere else is caught in the shot.
		var bar := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.06, 0.02, 0.9)
		bar.mesh = box
		var bar_mat := StandardMaterial3D.new()
		bar_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		bar_mat.albedo_color = Color(1.0, 0.9, 0.1)
		bar.material_override = bar_mat
		bar.position = Vector3(0.0, 0.02, -0.75)
		unit.add_child(bar)
		var label: Node = unit.get_node_or_null("NameLabel")
		if label:
			(label as Node3D).visible = false
		_units.append(unit)
	print("[foot_check] %s" % scene_path)
	_built = true


func _process(_delta: float) -> bool:
	_elapsed += _delta
	if not _built or _elapsed < 0.5:
		return false
	if _frames == 0:
		for unit in _units:
			var vis: Node = unit.get_node_or_null("Visual")
			if vis == null:
				continue
			# FC_VARIANT swaps the model after spawn — the worm piles are only
			# reachable this way (WormUnit swaps them in as a mass grows).
			if OS.has_environment("FC_VARIANT"):
				vis.call("set_variant", StringName(OS.get_environment("FC_VARIANT")))
			if OS.has_environment("FC_POSE"):
				vis.call("set_stance", StringName(OS.get_environment("FC_POSE")))
	_frames += 1
	if _elapsed < 2.0:
		return false
	var img := root.get_texture().get_image()
	var path := OS.get_environment("SHOT_PATH") if OS.has_environment("SHOT_PATH") \
		else "foot_check.png"
	print("[foot_check] wrote ", path, " err=", img.save_png(path))
	return true
