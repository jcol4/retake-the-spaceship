extends SceneTree
## Scratch: does the ground-depth offset make a unit punch through the cover in
## front of it? A 1.0 m block sits FC_GAP tiles toward the camera from each unit.
## Half a tile is the tightest legitimate case (a wall on the near edge of the
## unit's own tile), and is what GROUND_DEPTH_SAFETY is sized against.
##
## Uses the REAL camera rig scene: UnitVisual finds the rig by group in its own
## _ready, so a hand-rolled pivot leaves _rig null and the offset at zero, which
## makes this test pass for the wrong reason.

const TILE := 1.5

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


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	return m


func _build() -> void:
	var f := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(20.0, 20.0)
	f.mesh = plane
	f.material_override = _mat(Color(0.30, 0.33, 0.38))
	root.add_child(f)

	# Before the units, and the real rig — see the class comment.
	var rig: Node3D = load("res://scenes/camera_rig.tscn").instantiate()
	var cam: Camera3D = rig.get_node("Camera3D")
	cam.size = 5.5
	root.add_child(rig)
	cam.make_current()

	var gap := float(OS.get_environment("FC_GAP")) if OS.has_environment("FC_GAP") else 0.5
	var toward := rig.global_transform.basis.z
	var ground_toward := Vector3(toward.x, 0.0, toward.z).normalized()
	var along := Vector3(1.0, 0.0, -1.0).normalized()
	var yaws: Array[float] = [180.0, 135.0, 90.0]

	for i in 3:
		var at := along * ((i - 1) * 2.8)
		var unit: Node3D = load("res://scenes/player_unit.tscn").instantiate()
		root.add_child(unit)
		unit.position = at
		unit.rotation.y = deg_to_rad(yaws[i])
		var label: Node = unit.get_node_or_null("NameLabel")
		if label:
			(label as Node3D).visible = false

		var block := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(1.4, 1.0, 1.4)
		block.mesh = box
		block.material_override = _mat(Color(0.85, 0.65, 0.20))
		block.position = at + ground_toward * (TILE * gap) + Vector3(0.0, 0.5, 0.0)
		root.add_child(block)

	var vis: Node = root.find_child("Visual", true, false)
	print("[occl] gap=%.2f tiles (%.2f m of ground). rig found by unit: %s"
		% [gap, TILE * gap, vis.get("_rig") != null if vis else false])
	_built = true


func _process(_delta: float) -> bool:
	_elapsed += _delta
	if not _built or _elapsed < 1.5:
		return false
	_frames += 1
	if _frames < 3:
		return false
	var img := root.get_texture().get_image()
	print("[occl] wrote ", OS.get_environment("SHOT_PATH"), " err=",
		img.save_png(OS.get_environment("SHOT_PATH")))
	return true
