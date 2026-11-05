extends SceneTree
## Fodder dismemberment (GibPlanner, FodderGibs, Ragdoll's severed parts): the
## visual-only rules.
##
##   godot --headless --path . --script res://tools/test_gibs.gd
##
## Headless builds register no skins, so FodderGibs bakes no meshes here: the
## parts fly as mesh-less bodies, which is everything these rules are about.
## How the parts LOOK is checked windowed with
##   LAB_MODEL=zombie LAB_GIBS=1 godot --path . --script res://tools/ragdoll_lab.gd
##
## Scripts are load()ed and called dynamically where an autoload is involved: a
## --script tool is compiled before the autoloads register.

const ZOMBIE := "res://assets/models/zombie.glb"
## An open tile on maps/test_deck.txt with the x=14 bulkhead's wall end beside
## it (see test_corner_peek.gd), so its sight rays cross both open deck and wall.
const TILE := Vector3i(13, 0, 11)

var _failures := 0
var _grid: Node
var _map


func _initialize() -> void:
	await process_frame
	_grid = root.get_node_or_null("GridManager")
	_check_planner_deterministic()
	_check_planner_varies()
	_check_non_fodder()
	_check_planner_shapes()
	await _check_severed_bodies()
	await _check_heavy()
	await _check_rng_untouched()
	await _check_layers_and_sight()
	await _check_live_cap()
	_check_kept_cap()

	print("")
	if _failures == 0:
		print("gibs: ALL CHECKS PASSED")
		quit(0)
	else:
		print("gibs: %d CHECK(S) FAILED" % _failures)
		quit(1)


# --- Planner -------------------------------------------------------------------------


func _info(kind: int, part := 1, overkill := 0, fodder := true) -> Dictionary:
	return {"fodder": fodder, "kind": kind, "part": part, "from": Vector3(6, 1.4, 0),
		"at": Vector3.ZERO, "overkill": overkill}


func _check_planner_deterministic() -> void:
	var same := true
	for kind in [1, 2, 3]:
		for s in 50:
			var seed := GibPlanner.seed_for(s * 7919, "Zombie_%d" % s)
			var a := GibPlanner.plan(_info(kind, s % 6, s % 9), seed)
			var b := GibPlanner.plan(_info(kind, s % 6, s % 9), seed)
			if var_to_str(a) != var_to_str(b):
				same = false
	_check(same, "plan() is the same for the same death info and seed")


func _check_planner_varies() -> void:
	var by_seed := {}
	var by_unit := {}
	for s in 200:
		by_seed[var_to_str(GibPlanner.plan(_info(1, 2), GibPlanner.seed_for(s, "Zombie_1")))] = true
		by_unit[var_to_str(GibPlanner.plan(_info(1, 2), GibPlanner.seed_for(1234, "Zombie_%d" % s)))] = true
	_check(by_seed.size() > 10, "plan() differs across hit seeds (%d distinct of 200)" % by_seed.size())
	_check(by_unit.size() > 10, "plan() differs across units (%d distinct of 200)" % by_unit.size())
	_check(GibPlanner.seed_for(1, "Zombie_1") != GibPlanner.seed_for(1, "Zombie_2"),
		"seed_for mixes the unit in")


func _check_non_fodder() -> void:
	var any := false
	for kind in [0, 1, 2, 3]:
		for s in 300:
			var p := GibPlanner.plan(_info(kind, s % 6, 50, false), s)
			if p.mode != GibPlanner.Mode.NONE or not (p.parts as Array).is_empty():
				any = true
	_check(not any, "non-Fodder never gets parts, whatever the hit or overkill")


func _check_planner_shapes() -> void:
	var gibbed := 0
	var melee_ok := true
	var bullet_ok := true
	var heavy_ok := true
	var none_kind_ok := true
	for s in 400:
		var m := GibPlanner.plan(_info(2, 1), s)
		if m.mode != GibPlanner.Mode.NONE and (m.parts as Array).size() != 1:
			melee_ok = false
		var b := GibPlanner.plan(_info(1, 3), s)
		if b.mode != GibPlanner.Mode.NONE:
			gibbed += 1
			var n := (b.parts as Array).size()
			if n < 1 or n > 2 or GibPlanner.part_names(b)[0] != &"arm_r":
				bullet_ok = false
		var h := GibPlanner.plan(_info(1, 1, GibPlanner.HEAVY_OVERKILL), s)
		if h.mode != GibPlanner.Mode.HEAVY or (h.parts as Array).size() != GibPlanner.PARTS.size():
			heavy_ok = false
		if GibPlanner.plan(_info(0, 1, 50), s).mode != GibPlanner.Mode.NONE:
			none_kind_ok = false
	_check(melee_ok, "a swing takes a single part")
	_check(bullet_ok, "a round takes the part it struck, plus at most one more")
	_check(gibbed > 60 and gibbed < 340, "not every rifle kill gibs (%d of 400 did)" % gibbed)
	_check(heavy_ok, "overkill past HEAVY_OVERKILL takes every part")
	_check(none_kind_ok, "a death with no hit kind never gibs")
	var blast_radial := GibPlanner.plan(_info(3, -1, GibPlanner.HEAVY_OVERKILL), 5)
	_check(blast_radial.radial, "a blast pushes parts radially")


# --- Severing ---------------------------------------------------------------------------


## A zombie model standing at `at`, posed and paused, and its skeleton.
func _zombie(at: Vector3) -> Skeleton3D:
	var inst := (load(ZOMBIE) as PackedScene).instantiate() as Node3D
	root.add_child(inst)
	inst.global_position = at
	var ap := inst.find_children("*", "AnimationPlayer", true, false)[0] as AnimationPlayer
	ap.play("idle")
	ap.seek(0.3, true)
	ap.pause()
	return inst.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D


## A gibbing death, the way UnitVisual._start_ragdoll does it.
func _die(skel: Skeleton3D, parts: Array, at: Vector3) -> Array:
	var plan := {"mode": GibPlanner.Mode.LIMBS, "parts": [], "dir": Vector3.LEFT,
		"from": at + Vector3(6, 1.4, 0), "radial": false}
	for p: StringName in parts:
		plan.parts.append({"part": p, "speed": 3.0, "spin": 6.0})
	var gibs := FodderGibs.new()
	root.add_child(gibs)
	var severed := gibs.sever(skel, plan, at.y, 99)
	var r := Ragdoll.new()
	root.add_child(r)
	r.start(skel, {"kind": 1, "part": 1, "from": at + Vector3(6, 1.4, 0), "seed": 7}, at.y,
		null, null, severed)
	gibs.keep_apart(r.bodies())
	return [gibs, r, severed]


func _check_severed_bodies() -> void:
	var skel := _zombie(Vector3(40, 0, 40))
	var parts := Ragdoll.gib_parts(skel)
	_check(parts.size() == 5, "the Mixamo zombie rig has all five parts (%d)" % parts.size())
	var out := _die(skel, [&"arm_l", &"head"], Vector3(40, 0, 40))
	var gibs: FodderGibs = out[0]
	var r: Ragdoll = out[1]
	var severed: PackedInt32Array = out[2]
	_check(severed.size() == 2, "two parts severed")
	var gone := {}
	for root_bi in severed:
		for bi in Ragdoll.subtree(skel, root_bi):
			gone[skel.get_bone_name(bi)] = true
	var stray := false
	for b: RigidBody3D in r.bodies():
		var bone := String(b.name).trim_prefix("rb_")
		for g: String in gone:
			if g.ends_with(bone):
				stray = true
	_check(not stray, "no ragdoll body left anywhere under a severed part")
	_check(r.bodies().size() == 12 - 3, "the rest of the ragdoll is built (%d bodies)" % r.bodies().size())
	var arm := skel.find_bone("mixamorig5_LeftArm")
	_check(skel.get_bone_pose_scale(arm).is_equal_approx(Ragdoll.SEVERED_SCALE), "the severed arm is folded away")
	_check(gibs.part_bodies().size() == 2, "a body per part")
	for i in 30:
		await physics_frame
	_check(skel.get_bone_pose_scale(arm).is_equal_approx(Ragdoll.SEVERED_SCALE),
		"the fold survives the ragdoll driving the skeleton")
	gibs.clear()
	r.clear()
	await process_frame
	_check(skel.get_bone_pose_scale(arm).is_equal_approx(Vector3.ONE), "clear() (a rewind) puts the arm back")
	_check(FodderGibs.live_count == 0, "clear() hands the live budget back")
	await process_frame


func _check_heavy() -> void:
	var at := Vector3(44, 0, 40)
	var skel := _zombie(at)
	var out := _die(skel, GibPlanner.PARTS.duplicate(), at)
	var r: Ragdoll = out[1]
	_check((out[2] as PackedInt32Array).size() == 5, "a heavy death severs every part")
	_check(r.bodies().size() == 3, "only the torso falls as a ragdoll (%d bodies)" % r.bodies().size())
	(out[0] as FodderGibs).clear()
	r.clear()
	await process_frame


func _check_rng_untouched() -> void:
	seed(424242)
	var expect := [randi(), randf(), randi_range(0, 999)]
	seed(424242)
	var at := Vector3(48, 0, 40)
	var skel := _zombie(at)
	var plan := GibPlanner.plan(_info(3, -1, 20), GibPlanner.seed_for(17, "Zombie_9"))
	var out := _die(skel, GibPlanner.part_names(plan), at)
	for i in 20:
		await physics_frame
	var got := [randi(), randf(), randi_range(0, 999)]
	_check(var_to_str(expect) == var_to_str(got), "the global (gameplay) generator is untouched by a gibbing death")
	(out[0] as FodderGibs).clear()
	(out[1] as Ragdoll).clear()
	await process_frame


func _check_layers_and_sight() -> void:
	_map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(_map)
	await process_frame
	_map.build_layout("res://maps/test_deck.txt")
	await physics_frame
	await physics_frame
	for node in get_nodes_in_group("units"):
		_grid.set_occupant(node.grid_pos, null)
		node.remove_from_group("units")
		node.free()
	var tiles: Array[Vector3i] = []
	for dx in range(-2, 3):
		for dz in range(-2, 3):
			tiles.append(TILE + Vector3i(dx, 0, dz))
	var before := _sight(tiles)
	var occ_before := _occupants(tiles)

	var at: Vector3 = _grid.grid_to_world(TILE)
	var skel := _zombie(at)
	var out := _die(skel, GibPlanner.PARTS.duplicate(), at)
	var gibs: FodderGibs = out[0]
	var bodies := gibs.part_bodies()
	var layers_ok := true
	for b: RigidBody3D in bodies:
		if b.collision_layer != Ragdoll.LAYER or (b.collision_layer & (1 | 2 | 4)) != 0:
			layers_ok = false
	_check(not bodies.is_empty() and layers_ok,
		"every part is on Ragdoll.LAYER only — never layer 1 (sight), 2 (picking) or 3 (cover)")
	var mask_ok := true
	for b: RigidBody3D in bodies:
		if b.collision_mask != FodderGibs.MASK:
			mask_ok = false
	_check(mask_ok, "parts collide only with deck/walls, cover, ragdolls and catch floors")
	# The worst case: park every part right across the tile's eye-height sight
	# lines, freeze them there, and ask again.
	var sides := [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]
	for i in bodies.size():
		var b := bodies[i] as RigidBody3D
		b.freeze = true
		b.global_position = at + Vector3(0, _grid.EYE_HEIGHT, 0) + sides[i % 4] * 0.5
	for i in 3:
		await physics_frame
	_grid.invalidate_sight_cache()
	await physics_frame
	var after := _sight(tiles)
	_check(var_to_str(before) == var_to_str(after), "parts across the sight lines change no sight_blocked_on answer")
	_check(var_to_str(occ_before) == var_to_str(_occupants(tiles)), "parts change no tile occupancy")
	gibs.clear()
	(out[1] as Ragdoll).clear()
	await process_frame


func _sight(tiles: Array[Vector3i]) -> Array:
	var out := []
	for t in tiles:
		for side in 4:
			out.append(_grid.sight_blocked_on(t, side))
	return out


func _occupants(tiles: Array[Vector3i]) -> Array:
	var out := []
	for t in tiles:
		var tile = _grid.get_tile(t)
		out.append(tile.occupant.get_instance_id() if tile != null and tile.occupant != null else 0)
	return out


func _check_live_cap() -> void:
	var all: Array = []
	var total := 0
	for i in 5:
		var at := Vector3(60 + i * 3, 0, 60)
		var out := _die(_zombie(at), GibPlanner.PARTS.duplicate(), at)
		all.append(out)
		total += (out[2] as PackedInt32Array).size()
	_check(total == FodderGibs.MAX_LIVE and FodderGibs.live_count == FodderGibs.MAX_LIVE,
		"live parts stop at MAX_LIVE (%d severed over 5 heavy deaths)" % total)
	_check((all[4][2] as PackedInt32Array).is_empty(), "a death past the budget falls whole")
	# Settling hands the budget back.
	for i in int((FodderGibs.MAX_TIME + 0.5) * Engine.physics_ticks_per_second):
		await physics_frame
	_check(FodderGibs.live_count == 0, "every part settles by MAX_TIME and frees its body")
	var bodies_left := 0
	for out: Array in all:
		bodies_left += (out[0] as FodderGibs).part_bodies().size()
	_check(bodies_left == 0, "no part body outlives its settle")
	for out: Array in all:
		(out[0] as FodderGibs).clear()
		(out[1] as Ragdoll).clear()
	await process_frame


func _check_kept_cap() -> void:
	var made: Array[Node3D] = []
	for i in FodderGibs.MAX_KEPT + 7:
		var n := Node3D.new()
		root.add_child(n)
		made.append(n)
		FodderGibs._kept.append([n, null])
		FodderGibs._trim_kept()
	_check(FodderGibs.kept_count() == FodderGibs.MAX_KEPT, "settled parts stop at MAX_KEPT")
	_check(made[0].is_queued_for_deletion() and not made[made.size() - 1].is_queued_for_deletion(),
		"the oldest settled part is the one freed")


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
