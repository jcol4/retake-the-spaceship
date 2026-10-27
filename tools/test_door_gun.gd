extends SceneTree
## Extraction plan Phase 5: the landed ship's door gun (GDD §7.4).
##
##   godot --headless --path . --script res://tools/test_door_gun.gd
##
## Covers:
##   - geometry: the gunner's tile is on the pad, off the square, next to it,
##     and directly under the Dropship's door_gun_mount for every ramp side;
##   - it spawns when the ship lands (not while it is inbound), joins the pool
##     that round, is the calling crew's faction and never a squad member;
##   - its stats (HP 30, armored, plating, 2 shots, belt-fed) and its field of
##     fire: range from the square, line of sight, best target, never a friend;
##   - the light modifier applies to its shots (extraction plan A9);
##   - hostile AI sees it as a target; the Dropship is never one;
##   - it is excluded from crews, departures, results and the wipe check, and it
##     is not a body (no loot, carry or revive);
##   - at 0 HP it is DISABLED and stays so for the rest of the landing;
##   - takeoff frees it; a re-called ship brings a fresh one;
##   - a merc crew's ship gets a gunner on the merc side (the Phase 8 seam).
##
## Runs on the real extraction test deck (maps/extraction_test.txt) through the
## real ExtractionManager, driving its turn hooks by hand rather than running the
## TurnManager draw loop, so every step is deterministic.

const PLAYER := "res://scenes/player_unit.tscn"
const MERC := "res://scenes/merc_unit.tscn"
const DECK := "res://maps/extraction_test.txt"

## Hangar A of the test deck: pad (3,6), ramp east, square centred on (6,6).
const A := 0
const B := 1
const SQUARE_CENTRE := Vector3i(7, 0, 6)
const IN_BAY_OFF_SQUARE := Vector3i(2, 0, 2)
## UnitStats.Action.SHOOT by value (see test_suppression.gd).
const ACTION_SHOOT := 1

var _failures := 0
var _grid: Node
var _em: Node
var _tm: Node
var _map: Node
var _data
var LIFE
var DG  # DoorGunUnit script
var R  # ExtractionRules script
var MD  # MapData script
var F  # Faction script
var _combat
var _ended: Array = []


func _initialize() -> void:
	_grid = root.get_node_or_null("GridManager")
	_em = root.get_node_or_null("ExtractionManager")
	_tm = root.get_node_or_null("TurnManager")
	LIFE = load("res://scripts/unit.gd").LifeState
	DG = load("res://scripts/door_gun_unit.gd")
	R = load("res://scripts/extraction_rules.gd")
	MD = load("res://scripts/map_data.gd")
	F = load("res://scripts/faction.gd")
	_combat = load("res://scripts/combat.gd")
	_map = load("res://scenes/test_map.tscn").instantiate()
	_map.layout_path = DECK
	root.add_child(_map)
	await process_frame
	await physics_frame
	await physics_frame
	_data = _map.data
	seed(5150)
	_tm.clear_out_mode = false
	_tm.mission_over = false
	_tm.mission_ended.connect(func(result) -> void: _ended.append(result))

	_check_geometry()
	await _check_mount_matches_cell()
	await _check_landing_cycle()
	await _check_merc_crew_gun()

	_em.reset()
	_tm.pool.clear()
	print("")
	if _failures == 0:
		print("door_gun: ALL CHECKS PASSED")
		quit(0)
	else:
		print("door_gun: %d CHECK(S) FAILED" % _failures)
		quit(1)


func _check_geometry() -> void:
	print("-- geometry")
	var h = _data.hangars[A]
	var cell: Vector3i = MD.hangar_gun_cell(h.pad_center, h.ramp_side)
	_check(cell == Vector3i(5, 0, 4), "hangar A's gun cell is the pad's ramp-side right corner (%s)" % cell)
	var all_ok := true
	var pad := Vector3i(20, 0, 20)
	for side in MD.SIDE_STEP.size():
		var c: Vector3i = MD.hangar_gun_cell(pad, side)
		var square: Array = MD.hangar_square_cells(pad, side)
		if not MD.hangar_pad_cells(pad).has(c) or square.has(c) or DG.distance_to_square(c, square) != 1:
			all_ok = false
	_check(all_ok, "for every ramp side: on the pad, off the square, adjacent to it")
	var sq: Array = h.square
	_check(DG.distance_to_square(SQUARE_CENTRE, sq) == 0, "distance 0 inside the square")
	_check(DG.distance_to_square(Vector3i(9 + DG.RANGE_FROM_SQUARE - 1, 0, 6), sq) == DG.RANGE_FROM_SQUARE,
		"distance is Chebyshev to the NEAREST square cell")


func _check_mount_matches_cell() -> void:
	print("-- the model's mount sits over the gun's tile")
	var h = _data.hangars[A]
	var all_ok := true
	for side in MD.SIDE_STEP.size():
		var ship = load("res://scripts/dropship.gd").new()
		_map.add_child(ship)
		ship.place(_map.cell_to_world(h.pad_center), side, true)
		var under: Vector3i = _grid.world_to_grid(ship.door_gun_mount.global_position)
		var want: Vector3i = MD.hangar_gun_cell(h.pad_center, side)
		if under.x != want.x or under.z != want.z:
			all_ok = false
			print("    side %d: mount over %s, gun cell %s" % [side, under, want])
		ship.queue_free()
	await process_frame
	_check(all_ok, "Dropship.door_gun_mount is over MapData.hangar_gun_cell for every ramp side")


func _check_landing_cycle() -> void:
	print("-- landing: spawn, stats, pool")
	var soldier = await _spawn(PLAYER, SQUARE_CENTRE)
	_em.begin_mission(_data)
	_tm.turn_number = 1
	_tm.pool.clear()
	_check(_em.call_ship(soldier), "the soldier calls the ship at A on round 1")
	_check(_em.door_gun(A) == null, "no gunner while the ship is inbound")
	_check(_em.door_gun_status(R.PLAYER_CREW) == _em.DoorGunStatus.NONE, "status NONE while inbound")
	for turn in [2, 3]:
		_tm.turn_number = turn
		_em._on_turn_started(turn)
	_check(_em.door_gun(A) == null, "still none on rounds 2-3")
	_tm.turn_number = 4
	_tm.pool = _tm._all_units()
	_em._on_turn_started(4)
	var gun = _em.door_gun(A)
	_check(gun != null and gun.get_script() == DG, "the ship lands on round 4 with a DoorGunUnit aboard")
	if gun == null:
		return
	var h = _data.hangars[A]
	var cell: Vector3i = MD.hangar_gun_cell(h.pad_center, h.ramp_side)
	_check(gun.grid_pos == cell and _grid.get_tile(cell).occupant == gun, "standing on its pad tile %s" % cell)
	_check(_em.door_gun_status(R.PLAYER_CREW) == _em.DoorGunStatus.ACTIVE, "status ACTIVE")
	_check(_tm.pool.has(gun), "it joins the CURRENT round's pool on landing")
	_check(_em.spawn_door_gun(A, R.PLAYER_CREW) == null and _em.door_gun(A) == gun, "one gunner per ship")
	_check(gun.faction == F.Id.CONTRACTORS and not gun.is_hostile_to(soldier),
		"the player crew's gun is a Contractor, friendly to the squad")
	_check(not gun.is_player_controlled, "it is not a PlayerUnit")
	_check(not gun.is_in_group("player_units") and not gun.is_in_group("enemy_units"),
		"in neither the squad's nor the alien alert group")
	_check(gun.is_in_group("units") and gun.is_in_group(DG.GROUP), "in 'units' (pool, hostiles) and '%s'" % DG.GROUP)
	_check(_em.crew_of(gun) == R.NO_CREW, "it flies with no crew")
	_check(gun.current_hp == 30 and gun.stats.max_hp() == 30, "HP 30")
	_check(gun.stats.armored, "armored")
	_check(gun.damage_taken(9) == 9 - DG.ARMOR and gun.damage_taken(1) == 1,
		"plating takes %d off a hit, and a hit always does at least 1" % DG.ARMOR)
	_check(gun.stats.initiative() == 65, "hidden Initiative 65 (got %d)" % gun.stats.initiative())
	_check(gun.ap_pool() == 2 * gun.action_cost(ACTION_SHOOT), "AP for exactly two shots")
	_check(gun.reserve < 0, "belt-fed: unlimited reserve")
	_check(gun.stats.weapon.base_accuracy == 28 and gun.stats.weapon.damage == 9, "LMG accuracy and damage")
	_check(not gun.light_agnostic(), "the light modifier applies to it (A9)")
	var ship = _em._dropships.get(A)
	_check(ship != null and not ship.has_method("take_damage") and not ship.is_in_group("units"), "the Dropship is not a Unit")
	_check(ship != null and ship.find_children("*", "CollisionObject3D", true, false).is_empty(),
		"and has no collision: nothing can pick, shoot or block on it")
	var twin = DG.make("Twin", R.PLAYER_CREW, F.Id.CONTRACTORS, A, cell, h.square)
	_check(twin.stats.max_hp() == gun.stats.max_hp() and twin.stats.initiative() == gun.stats.initiative()
		and twin.name == "Twin", "make() is deterministic (co-op peers build the same gunner)")
	twin.free()

	print("-- field of fire")
	var near = await _spawn(MERC, Vector3i(11, 0, 9))   # 3 from the square
	var close = await _spawn(MERC, Vector3i(9, 0, 3))   # 2 from the square
	var far = await _spawn(MERC, Vector3i(15, 0, 6))    # 7: out of range
	_light([near.grid_pos, close.grid_pos, far.grid_pos])
	await physics_frame
	_check(gun.covers(near.grid_pos) and gun.covers(close.grid_pos), "both mercs in the bay are in range")
	_check(not gun.covers(far.grid_pos), "one %d tiles off the square is not" % (DG.RANGE_FROM_SQUARE + 1))
	var reach: Array = gun.targets_in_reach()
	_check(reach.has(near) and reach.has(close) and not reach.has(far), "targets_in_reach = in range AND in LOS")
	_check(not reach.has(soldier), "never a friendly")
	# The test deck's bay is one open room, so the blind spot is made: a tall slab
	# of map geometry (collision layer 1, what LOS rays hit) halfway between the
	# gunner and a merc well inside its range.
	var hidden_tile := Vector3i(11, 0, 11)  # 4 from the square
	var hidden = await _spawn(MERC, hidden_tile)
	_light([hidden_tile])
	_check(gun.covers(hidden_tile) and gun.targets_in_reach().has(hidden), "in range and in sight before the wall")
	var wall := _wall_between(gun, hidden)
	await physics_frame
	await physics_frame
	_check(gun.covers(hidden_tile) and not gun.targets_in_reach().has(hidden),
		"in range but out of LOS (%s): not engaged" % hidden_tile)
	wall.queue_free()
	await _free([hidden])
	await physics_frame
	var best = gun.best_target()
	var best_acc: int = _combat.compute_accuracy(gun, best, _combat.ShotAction.SHOOT) if best else -1
	var others_ok := true
	for t in reach:
		if _combat.compute_accuracy(gun, t, _combat.ShotAction.SHOOT) > best_acc:
			others_ok = false
	_check(best != null and others_ok, "best_target is the highest hit chance (%s, %d%%)" % [
		best.stats.display_name if best else "none", best_acc])
	_check(_combat.light_matters(gun, near), "and light prices its shots (A9)")
	_check(near.hostiles().has(gun), "hostile AI sees the gunner as a target")
	var ship_targetable := false
	for u in near.hostiles():
		if u == ship:
			ship_targetable = true
	_check(not ship_targetable, "and never the ship")

	print("-- an activation")
	var lines := []
	gun.action_logged.connect(func(t: String) -> void: lines.append(t))
	var hp_before: int = near.current_hp + close.current_hp
	var at: Vector3i = gun.grid_pos
	gun.begin_activation()
	await gun.take_turn()
	_check(lines.size() == DG.SHOTS_PER_ACTIVATION, "two bursts (%d)" % lines.size())
	_check(gun.ap < gun.action_cost(ACTION_SHOOT), "spending its AP")
	_check(gun.ammo == gun.stats.mag_size, "the belt tops the magazine back up")
	_check(gun.grid_pos == at, "without moving")
	_check(near.current_hp + close.current_hp <= hp_before, "at the mercs")
	await _free([near, close, far])

	# Through the real draw loop: TurnManager awaits `take_turn` on an EnemyUnit.
	# A one-unit pool, then mission_over raised so the deferred next draw (round
	# end, a new round full of AI) stops at its first line.
	var prey = await _spawn(MERC, Vector3i(10, 0, 9))
	_light([prey.grid_pos])
	var tm_lines := []
	var log_cb := func(t: String) -> void: tm_lines.append(t)
	_tm.log_message.connect(log_cb)
	lines.clear()
	_tm.pool.clear()
	_tm.pool.append(gun)
	await _tm._draw_next()
	_tm.mission_over = true
	await process_frame
	_tm.mission_over = false
	_tm.active_unit = null
	_tm.log_message.disconnect(log_cb)
	_check(tm_lines.has("%s drawn from the pool" % gun.stats.display_name), "TurnManager draws it from the pool")
	_check(lines.size() == DG.SHOTS_PER_ACTIVATION and tm_lines.has(lines[0]),
		"and its bursts land in the combat log (%d)" % lines.size())
	await _free([prey])
	lines.clear()
	gun.begin_activation()
	await gun.take_turn()
	_check(lines.is_empty() and gun.ap == gun.ap_pool(), "nothing in reach: a quiet activation, no AP spent")

	print("-- excluded from crews, departures and results")
	_check(not _em._crew_units(R.PLAYER_CREW).has(gun), "not a departure candidate")
	var split: Dictionary = _em.rules.split_passengers(A, _em._crew_units(R.PLAYER_CREW), _em.riders_of)
	_check(not split["extracted"].has(gun) and not split["lost"].has(gun) and split["extracted"].has(soldier),
		"a departure split boards the soldier and never sorts the gun either way")
	_check(_em.riders_of(gun).is_empty(), "and it carries no riders")
	var result = _em.build_result(split)
	_check(not result.extracted_units.has(gun) and not result.lost_units.has(gun),
		"never a survivor, never a loss in a MissionResult")
	_check(gun.loot_blocker(soldier) != "" and gun.loot_items().is_empty(), "never lootable")
	_check(soldier.pick_up_blocker(gun) != "", "never carriable")
	soldier.take_damage(9999)
	_check(soldier.life_state == LIFE.DOWNED, "the only soldier goes down")
	_ended.clear()
	_check(_tm._check_end_conditions(), "with the gun still firing, that is a wipe")
	var wiped = _ended[0] if _ended.size() == 1 else null
	_check(wiped != null and wiped.outcome == 1 and not wiped.lost_units.has(gun)
		and wiped.lost_units.has(soldier), "WIPED, the soldier lost, the gun in neither list")
	_tm.mission_over = false
	_ended.clear()
	await _free([soldier])

	print("-- disabled")
	var changed := []
	_em.hangar_changed.connect(func(i: int) -> void: changed.append(i))
	var raider = await _spawn(MERC, Vector3i(10, 0, 9))
	gun.take_damage(9999)
	_check(gun.life_state == LIFE.DEAD and gun.is_disabled(), "0 HP: DEAD, i.e. disabled")
	_check(_em.door_gun_status(R.PLAYER_CREW) == _em.DoorGunStatus.DISABLED, "status DISABLED")
	_check(changed.has(A), "the hangar refreshes (HUD) when it goes down")
	_check(_em.door_gun(A) == gun and gun.is_inside_tree() and gun.visible, "the model stays on the ship")
	_check(_grid.get_tile(cell).occupant == null, "and gives up its tile")
	_check(not raider.hostiles().has(gun) and not _tm._all_units().has(gun), "out of targets and the pool")
	_check(gun.bodies_on(cell, true).is_empty(), "not a body on the deck")
	var rescuer = await _spawn(PLAYER, IN_BAY_OFF_SQUARE)
	_check(rescuer.revive_blocker(gun) != "" and rescuer.pick_up_blocker(gun) != "", "nothing revives or carries it")
	await _free([raider])
	for turn in [5, 6, 7]:
		_tm.turn_number = turn
		_em._on_turn_started(turn)
	_check(_em.door_gun(A) == gun and gun.life_state == LIFE.DEAD, "still down on rounds 5-7")
	gun.begin_activation()
	lines.clear()
	await gun.take_turn()
	_check(lines.is_empty(), "and silent")

	print("-- takeoff")
	_check(_em.rules.departures_due(8) == [A], "the window ends at the end of round 8")
	await _em._on_round_ending(8)
	_check(_em.rules.state_of(A) == R.State.COOLDOWN, "an empty departure (cooldown)")
	_check(_em.door_gun(A) == null, "the gunner leaves with the ship")
	_check(not is_instance_valid(gun) or (gun.is_queued_for_deletion() and not gun.is_in_group("units")),
		"retired: out of 'units' at once, and freed")
	_check(not _tm.pool.has(gun), "and out of the pool")
	_check(_em.door_gun_status(R.PLAYER_CREW) == _em.DoorGunStatus.NONE, "status NONE")
	await process_frame
	_check(not is_instance_valid(gun), "freed by the next frame")

	print("-- re-call: a fresh gunner")
	for turn in range(9, 14):
		_tm.turn_number = turn
		_em._on_turn_started(turn)
	_check(_em.rules.can_call(A, R.PLAYER_CREW), "callable again after the cooldown")
	_check(_em.call_ship(rescuer), "re-called on round 13")
	for turn in [14, 15, 16]:
		_tm.turn_number = turn
		_em._on_turn_started(turn)
	var fresh = _em.door_gun(A)
	_check(fresh != null and fresh.life_state == LIFE.ACTIVE and fresh.current_hp == 30,
		"lands on round 16 with a fresh, full-HP gunner")
	_check(fresh != null and String(fresh.name) == "DoorGun_0_2", "under a new node name (%s)" % (fresh.name if fresh else ""))
	rescuer.relocate_to(SQUARE_CENTRE)
	_check(_em.request_dust_off(rescuer), "dust-off from the square")
	_ended.clear()
	await _em._on_round_ending(16)
	var out = _ended[0] if _ended.size() == 1 else null
	_check(out != null and out.extracted_units == [rescuer], "EXTRACTED: only the soldier rides out")
	_check(out != null and not out.lost_units.has(fresh),
		"the gunner is in no list of the result")
	_check(_em.door_gun(A) == null, "and is retired with the takeoff")
	_tm.mission_over = false
	await _free([rescuer])
	_em.reset()


func _check_merc_crew_gun() -> void:
	print("-- a merc crew's ship (the Phase 8 seam)")
	var soldier = await _spawn(PLAYER, Vector3i(32, 0, 6))  # hangar B's square
	_em.begin_mission(_data)
	var gun = _em.spawn_door_gun(B, R.MERC_CREW_BASE)
	_check(gun != null and gun.faction == F.Id.RIVAL_MERCS, "fights for the rival mercs")
	if gun != null:
		_check(gun.is_hostile_to(soldier) and soldier.hostiles().has(gun), "hostile to the squad, and a target for it")
		_check(_em.crew_of(gun) == R.NO_CREW, "still in no crew")
		_check(_em.door_gun_status(R.PLAYER_CREW) == _em.DoorGunStatus.NONE, "not the player's ship")
	_em.reset()
	_check(_em.door_gun(B) == null, "reset retires it")
	await _free([soldier])


## A 1 x 4 x 1 m slab on collision layer 1 (map geometry) at the midpoint of
## `a` and `b`, tall enough to cut GridManager.has_line_of_sight's eye-to-chest
## ray. The caller frees it.
func _wall_between(a, b) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.0, 4.0, 1.0)
	shape.shape = box
	body.add_child(shape)
	root.add_child(body)
	body.global_position = (a.global_position + b.global_position) / 2.0 + Vector3(0, 1.0, 0)
	return body


func _light(tiles: Array) -> void:
	for t in tiles:
		var tile = _grid.get_tile(t)
		if tile:
			tile.light_value = 100.0


func _spawn(scene_path: String, at: Vector3i):
	var unit = load(scene_path).instantiate()
	unit.position = _grid.grid_to_world(at)
	root.add_child(unit)
	await process_frame
	return unit


func _free(units: Array) -> void:
	for unit in units:
		if is_instance_valid(unit):
			var t = _grid.get_tile(unit.grid_pos)
			if t and t.occupant == unit:
				_grid.set_occupant(unit.grid_pos, null)
			unit.remove_from_group("units")
			unit.remove_from_group("player_units")
			unit.queue_free()
	await process_frame


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
