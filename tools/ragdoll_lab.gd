extends SceneTree
## A row of mercs, each killed a different way, captured as the ragdolls fall.
##
##   godot --path . --script res://tools/ragdoll_lab.gd
##
## MUST RUN WINDOWED (no --headless): headless builds no models. Writes PNGs to
## user://ragdoll_lab/ (side view through the fall, then the game's iso view of
## the settled bodies) and prints per-body settle diagnostics.
##
##   LAB_OUT=<dir>     write the frames somewhere else
##   LAB_POSE=idle     the pose each one is killed in
##   LAB_MODEL=merc    which model (assets/models/<name>.glb): merc, zombie (Fodder), zombie_2, securus
##   LAB_ROUNDS=3      follow-up rounds after the one that drops a shot case
##   LAB_GIBS=1        Fodder dismemberment (FodderGibs): every case comes apart —
##                     the struck part, both arms for melee, everything for the
##                     blast, nothing for "none". Use with LAB_MODEL=zombie.

## Which way each model faces at rest, so every case is turned to face +X.
const FACING_YAW := {"merc": 0.0, "zombie": -90.0, "zombie_2": -90.0, "securus": -90.0}
const GUN := "res://assets/models/guns/rifle.glb"
const SPACING := 2.6
const SHOTS := [0.0, 0.2, 0.4, 0.6, 0.9, 1.3, 2.0, 3.5]

## [label, kind, part, shooter offset from the merc] — the merc faces +X.
const CASES := [
	["chest_front", 1, 1, Vector3(6, 1.4, 0)],
	["head_front", 1, 0, Vector3(6, 1.4, 0)],
	["chest_back", 1, 1, Vector3(-6, 1.4, 0)],
	["leg_side", 1, 4, Vector3(0, 1.0, 6)],
	["arm_side", 1, 3, Vector3(0.5, 1.4, -6)],
	["melee", 2, 1, Vector3(1.2, 1.4, 0.3)],
	["blast", 3, -1, Vector3(1.0, 0.0, 0.6)],
	["none", 0, -1, Vector3.ZERO],
]

var _out := "user://ragdoll_lab"
var _cam: Camera3D
var _ragdolls: Array = []
var _starts: Array[Vector3] = []


func _init() -> void:
	if OS.has_environment("LAB_OUT"):
		_out = OS.get_environment("LAB_OUT")
	DirAccess.make_dir_recursive_absolute(_out)
	if OS.has_environment("LAB_TONE"):
		Ragdoll.tone_scale = float(OS.get_environment("LAB_TONE"))
	root.size = Vector2i(1800, 640)
	_run.call_deferred()


func _run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	_build_stage(world)
	var pose := OS.get_environment("LAB_POSE") if OS.has_environment("LAB_POSE") else "idle"
	var model := OS.get_environment("LAB_MODEL") if OS.has_environment("LAB_MODEL") else "merc"
	var skels: Array[Skeleton3D] = []
	var mounts: Array[Node3D] = []
	for i in CASES.size():
		var inst := (load("res://assets/models/%s.glb" % model) as PackedScene).instantiate() as Node3D
		world.add_child(inst)
		inst.position = Vector3(i * SPACING, 0, 0)
		inst.rotation_degrees.y = FACING_YAW.get(model, 0.0)
		var mount := inst.find_child("weapon_mount", true, false) as Node3D
		if mount:
			mount.add_child((load(GUN) as PackedScene).instantiate())
		var flash := inst.find_child("muzzle_flash", true, false) as Node3D
		if flash:
			flash.visible = false  # the game hides it between shots too
		var ap := inst.find_children("*", "AnimationPlayer", true, false)[0] as AnimationPlayer
		ap.play(pose)
		ap.seek(0.3, true)
		skels.append(inst.find_children("*", "Skeleton3D", true, false)[0])
		mounts.append(mount)
	for i in 10:
		await process_frame
	for i in CASES.size():
		var c: Array = CASES[i]
		var ap := skels[i].get_parent().get_parent().find_children("*", "AnimationPlayer", true, false)[0] as AnimationPlayer
		ap.pause()
		var base := Vector3(i * SPACING, 0, 0)
		var r := Ragdoll.new()
		world.add_child(r)
		var hit := {"kind": c[1], "part": c[2], "from": base + Vector3(c[3]), "seed": i * 7919}
		var severed := PackedInt32Array()
		var gibs: FodderGibs = null
		if OS.has_environment("LAB_GIBS"):
			gibs = FodderGibs.new()
			world.add_child(gibs)
			var t_cut := Time.get_ticks_usec()
			severed = gibs.sever(skels[i], _lab_plan(c, base), 0.0, i * 31)
			print("%s: cut %d part(s) in %.1f ms" % [c[0], severed.size(),
				(Time.get_ticks_usec() - t_cut) / 1000.0])
		r.start(skels[i], hit, 0.0, mounts[i], skels[i].get_parent().get_parent(), severed)
		if gibs != null:
			gibs.keep_apart(r.bodies())
		_ragdolls.append(r)
		# A burst: the round that dropped it, then LAB_ROUNDS more at the game's
		# cadence (Unit.BURST_CADENCE / UnitVisual.take_round).
		if c[1] == 1:
			var more := int(OS.get_environment("LAB_ROUNDS")) if OS.has_environment("LAB_ROUNDS") else 3
			for k in more:
				create_timer(0.11 * (k + 1)).timeout.connect(r.add_round.bind(base + Vector3(c[3])))
		if i == 0:
			print("start angles (%s pose):
%s" % [pose, r.debug_joint_angles()])
		_starts.append(base)
		var label: String = c[0]
		var t0 := Time.get_ticks_msec()
		r.settled.connect(func() -> void:
			print("%s settled at %.2fs" % [label, (Time.get_ticks_msec() - t0) / 1000.0]))
	if OS.has_environment("LAB_TRACE"):
		var k := int(OS.get_environment("LAB_TRACE"))
		var r: Ragdoll = _ragdolls[k]
		for f in 45:
			await physics_frame
			var line := "f%02d" % f
			for b in r.get_children():
				if b is RigidBody3D:
					line += " %s:%.1f/%.0f" % [b.name.substr(3), b.linear_velocity.length(), b.angular_velocity.length()]
			print(line)
	var t_start := Time.get_ticks_msec()
	for at: float in SHOTS:
		while (Time.get_ticks_msec() - t_start) / 1000.0 < at:
			await process_frame
		_report(at, skels)
		await _snap("side_%04d" % int(at * 1000))
	# Wait for every body to settle, then the game's view.
	while _ragdolls.any(func(r: Ragdoll) -> bool: return r.is_simulating()):
		await process_frame
	_report(-1.0, skels)
	await _snap("side_final")
	_save_sheet()
	_iso()
	await _snap("iso_final")
	quit()


## A forced gib plan per case (GibPlanner's own rolls would skip some).
func _lab_plan(c: Array, base: Vector3) -> Dictionary:
	var parts: Array = []
	match int(c[1]):
		0:
			parts = []
		2:
			parts = [&"arm_l", &"arm_r"]
		3:
			parts = GibPlanner.PARTS.duplicate()
		_:
			parts = [GibPlanner.FROM_BODY_PART.get(int(c[2]), &"head")]
	var from := base + Vector3(c[3])
	var dir := base - from
	dir.y = 0.0
	var plan := {"mode": GibPlanner.Mode.LIMBS if parts.size() < 5 else GibPlanner.Mode.HEAVY,
		"parts": [], "dir": dir.normalized() if dir.length() > 0.01 else Vector3.RIGHT,
		"from": from, "radial": int(c[1]) == 3}
	for p: StringName in parts:
		plan.parts.append({"part": p, "speed": 3.5, "spin": 8.0})
	return plan


func _report(at: float, skels: Array[Skeleton3D]) -> void:
	var line := "t=%.1f" % at
	for i in skels.size():
		var sk := skels[i]
		var hip := (sk.global_transform * sk.get_bone_global_pose(_find(sk, ["hip", "Hips"]))).origin
		var head := (sk.global_transform * sk.get_bone_global_pose(_find(sk, ["head", "Head"]))).origin
		line += "  %s hip(%.2f,%.2f,%.2f) head_y=%.2f" % [CASES[i][0], hip.x - _starts[i].x if i < _starts.size() else hip.x,
			hip.y, hip.z, head.y]
	print(line)


var _sheet: Array[Image] = []


func _snap(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	img.save_png(_out.path_join(name + ".png"))
	if name.begins_with("side"):
		_sheet.append(img)


## Every side frame's middle band, stacked top to bottom: the whole fall at a
## glance (sheet.png).
func _save_sheet() -> void:
	if _sheet.is_empty():
		return
	var w := _sheet[0].get_width()
	var h := _sheet[0].get_height()
	var band := Rect2i(0, int(h * 0.33), w, int(h * 0.32))
	var out := Image.create(w, band.size.y * _sheet.size(), false, _sheet[0].get_format())
	for i in _sheet.size():
		out.blit_rect(_sheet[i], band, Vector2i(0, band.size.y * i))
	out.resize(w / 2, out.get_height() / 2)
	out.save_png(_out.path_join("sheet.png"))


func _build_stage(world: Node3D) -> void:
	var ground := StaticBody3D.new()
	ground.collision_layer = 1
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(60, 0.2, 20)
	cs.shape = box
	ground.add_child(cs)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = box.size
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.32, 0.33, 0.36)
	mi.material_override = mat
	ground.add_child(mi)
	ground.position = Vector3(10, -0.1, 0)
	world.add_child(ground)
	# One tile grid line per merc, to judge how far each body ends from its tile.
	for i in CASES.size():
		var tile := MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = Vector2(1.5, 1.5)
		tile.mesh = pm
		var tm := StandardMaterial3D.new()
		tm.albedo_color = Color(0.45, 0.5, 0.42)
		tile.material_override = tm
		tile.position = Vector3(i * SPACING, 0.002, 0)
		world.add_child(tile)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.shadow_enabled = true
	world.add_child(sun)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.12, 0.13, 0.16)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.6, 0.65)
	env.environment = e
	world.add_child(env)
	_cam = Camera3D.new()
	world.add_child(_cam)
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.size = 6.5
	_cam.position = Vector3((CASES.size() - 1) * SPACING * 0.5, 1.6, 12)
	_cam.look_at(Vector3((CASES.size() - 1) * SPACING * 0.5, 0.7, 0))
	_cam.make_current()


## The game camera: orthographic, 45° yaw, pitched down atan(1/sqrt 2).
func _iso() -> void:
	var mid := Vector3((CASES.size() - 1) * SPACING * 0.5, 0, 0)
	_cam.size = 12.0
	var pitch := atan(1.0 / sqrt(2.0))
	var back := Vector3(sin(PI / 4), 0, cos(PI / 4)) * cos(pitch) + Vector3.UP * sin(pitch)
	_cam.position = mid + back * 30.0
	_cam.look_at(mid)


## The first bone whose name ends with one of `names` (Mixamo prefixes vary).
func _find(sk: Skeleton3D, names: Array) -> int:
	for i in sk.get_bone_count():
		for n: String in names:
			if sk.get_bone_name(i).ends_with(n):
				return i
	return 0
