extends SceneTree
## Scratch: stands one unit per facing on a BRIGHT floor, each on its own marked
## tile, so the gap (or overlap) between the drawn feet and the ground reads at a
## glance for every direction bucket at once.
##   FC_SCENE=res://scenes/player_unit.tscn FC_ANCHOR=0.9336 SHOT_PATH=out.png \
##     godot --path . --script res://tools/_foot_check.gd

const PITCH := atan(1.0 / sqrt(2.0))
const YAWS := [0.0, 45.0, 90.0, 135.0, 180.0, 225.0, 270.0, 315.0]

var _elapsed := 0.0
var _frames := 0
var _built := false


func _initialize() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.02, 0.03)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 1.0
	root.world_3d.environment = env
	_build.call_deferred()


func _plane(size: Vector2, color: Color, y: float) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := PlaneMesh.new()
	mesh.size = size
	node.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	node.material_override = mat
	node.position.y = y
	return node


func _build() -> void:
	var count := YAWS.size()
	var spacing := 2.0
	var floor_mesh := _plane(Vector2(spacing * count + 6.0, 8.0),
		Color(0.30, 0.33, 0.38), 0.0)
	root.add_child(floor_mesh)

	var scene_path := OS.get_environment("FC_SCENE") if OS.has_environment("FC_SCENE") \
		else "res://scenes/player_unit.tscn"
	var anchor := float(OS.get_environment("FC_ANCHOR")) if \
		OS.has_environment("FC_ANCHOR") else -1.0
	var scene: PackedScene = load(scene_path)

	# BEFORE the units, and the REAL rig scene rather than a hand-rolled pivot:
	# UnitVisual finds the rig by group in its own _ready and connects to its
	# yaw_changed. A stand-in added afterwards is one it never sees, _rig stays
	# null, and every camera-derived behaviour silently does nothing -- which is
	# exactly the hole that made an earlier round of these shots meaningless.
	var rig: Node3D = load("res://scenes/camera_rig.tscn").instantiate()
	var cam: Camera3D = rig.get_node("Camera3D")
	# Set BEFORE _ready, which seeds the zoom target from it -- assigning after
	# would be smoothed straight back to 10.5.
	cam.size = float(OS.get_environment("FC_ZOOM")) if OS.has_environment("FC_ZOOM") else 4.0
	root.add_child(rig)
	cam.make_current()

	# The row of units runs along the camera's screen-horizontal, so every one of
	# them is at the same screen height and the eye compares foot to floor, not
	# foot to foot.
	var along := Vector3(1.0, 0.0, -1.0).normalized()
	for i in count:
		var at := along * ((i - (count - 1) / 2.0) * spacing)
		# The unit's own 1.5 m tile, drawn just above the floor in red.
		var tile := _plane(Vector2(1.5, 1.5), Color(0.75, 0.18, 0.16), 0.005)
		tile.position += at
		root.add_child(tile)

		var unit: Node3D = scene.instantiate()
		root.add_child(unit)
		unit.position = at
		unit.rotation.y = deg_to_rad(YAWS[i])
		var vis: Node = unit.get_node_or_null("Visual")
		if vis and anchor >= 0.0:
			vis.set("foot_anchor", Vector2(0.5, anchor))
			for child in vis.get_children():
				var sprite := child as AnimatedSprite3D
				if sprite:
					var tex := sprite.sprite_frames.get_frame_texture(sprite.animation, 0)
					sprite.offset = Vector2(0.0, tex.get_size().y * (anchor - 0.5))
		# Name labels stack on top of each other at this zoom and say nothing
		# about the feet.
		var label: Node = unit.get_node_or_null("NameLabel")
		if label:
			(label as Node3D).visible = false

	print("[foot_check] %s anchor=%s" % [scene_path, anchor])
	_built = true


func _process(_delta: float) -> bool:
	_elapsed += _delta
	if not _built or _elapsed < 1.5:
		return false
	_frames += 1
	if _frames < 3:
		return false
	var img := root.get_texture().get_image()
	var path := OS.get_environment("SHOT_PATH") if OS.has_environment("SHOT_PATH") \
		else "foot_check.png"
	print("[foot_check] wrote ", path, " err=", img.save_png(path))
	return true


