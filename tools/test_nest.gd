extends SceneTree
## Extraction plan 3.3: the finished spawn nest (GDD §11.7) — the Destroy objective.
##
##   godot --headless --path . --script res://tools/test_nest.gd
##
## Covers:
##   - cadence: one spawn every NestUnit.SPAWN_INTERVAL (3) activations, none between;
##   - the 70/20/10 table over a seeded loop, with the unbuilt Spitter's 20% folded
##     into Fodder (so ~90% Fodder, ~10% Agile Hunter, never a Spitter);
##   - spawns land on a free tile movement-adjacent to the nest, the first free one
##     in GridManager.STEPS order, and a boxed-in nest spawns nothing;
##   - its death calls AlienHivemind.report_nest_destroyed at its tile, and the
##     Destroy contract reads it as complete.

const NEST := "res://scenes/nest_unit.tscn"
const PLAYER := "res://scenes/player_unit.tscn"
const DECK := "res://maps/extraction_test.txt"
## Open floor in hangar A of extraction_test, clear of pad, square and crate.
const NEST_AT := Vector3i(4, 0, 10)

var _failures := 0
var _grid: Node
var _hive: Node
var _om: Node
var _nest_script


func _initialize() -> void:
	_grid = root.get_node_or_null("GridManager")
	_hive = root.get_node_or_null("AlienHivemind")
	_om = root.get_node_or_null("ObjectiveManager")
	_nest_script = load("res://scripts/nest_unit.gd")
	var map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(map)
	await process_frame
	map.build(load("res://scripts/map_ascii.gd").load_file(DECK))
	await process_frame
	seed(31337)

	_check_table_weights()
	await _check_cadence_and_adjacency()
	await _check_boxed_in()
	await _check_destroyed_callback()

	print("")
	if _failures == 0:
		print("nest: ALL CHECKS PASSED")
		quit(0)
	else:
		print("nest: %d CHECK(S) FAILED" % _failures)
		quit(1)


func _check_table_weights() -> void:
	var K = _nest_script.SpawnKind
	var weights := 0
	for entry in _nest_script.SPAWN_TABLE:
		weights += entry[1]
	_check(weights == 100, "the table's weights sum to 100")
	_check(_nest_script.SPAWN_TABLE[0] == [K.FODDER, 70] and _nest_script.SPAWN_TABLE[1] == [K.SPITTER, 20]
		and _nest_script.SPAWN_TABLE[2] == [K.HUNTER, 10], "it is 70 Fodder / 20 Spitter / 10 Hunter (GDD §11.7)")
	var rng := RandomNumberGenerator.new()
	rng.seed = 2024
	const N := 20000
	var counts := {K.FODDER: 0, K.SPITTER: 0, K.HUNTER: 0}
	for i in N:
		counts[_nest_script.roll_spawn_kind(rng)] += 1
	var fodder := float(counts[K.FODDER]) / N
	var hunter := float(counts[K.HUNTER]) / N
	_check(counts[K.SPITTER] == 0, "no Spitter ever spawns (it is not built)")
	_check(absf(fodder - 0.9) < 0.015, "Fodder ~90%% (its 70 + the Spitter's 20): %.3f" % fodder)
	_check(absf(hunter - 0.1) < 0.015, "Agile Hunter ~10%%: %.3f" % hunter)
	# The global-RNG path is the one the game uses; seeded, it repeats.
	seed(99)
	var a: Array = []
	for i in 50:
		a.append(_nest_script.roll_spawn_kind())
	seed(99)
	var b: Array = []
	for i in 50:
		b.append(_nest_script.roll_spawn_kind())
	_check(a == b, "the global-RNG roll is repeatable under a seed")


func _check_cadence_and_adjacency() -> void:
	var nest = await _spawn_nest(NEST_AT)
	var spawned_after: Array[int] = []
	var before := _spawned_units().size()
	for activation in range(1, 10):
		await nest.take_turn()
		spawned_after.append(_spawned_units().size() - before)
	var expected: Array[int] = [0, 0, 1, 1, 1, 2, 2, 2, 3]
	_check(spawned_after == expected,
		"one spawn every 3rd activation, none between (%s)" % [spawned_after])
	var units := _spawned_units()
	var adjacent := true
	var distinct := {}
	for u in units:
		adjacent = adjacent and _grid.is_melee_adjacent(NEST_AT, u.grid_pos)
		distinct[u.grid_pos] = true
		var path: String = u.get_script().resource_path
		_check(path.ends_with("swarm_unit.gd") or path.ends_with("agile_hunter_unit.gd"), "%s is Fodder or an Agile Hunter" % u.name)
	_check(adjacent, "every spawn is movement-adjacent to the nest")
	_check(distinct.size() == units.size(), "each on its own tile")
	_check(units[0].grid_pos == _grid.neighbors(NEST_AT)[0], "the first spawn takes the first free neighbour")
	for u in units:
		_check(_grid.get_tile(u.grid_pos).occupant == u, "%s holds its tile" % u.name)
	_check(String(units[0].name) == "%s_spawn_1" % nest.name, "spawns are named after the nest, in order (co-op paths)")
	await _free(units + [nest])


func _check_boxed_in() -> void:
	var nest = await _spawn_nest(NEST_AT)
	var blockers: Array = []
	for n in _grid.neighbors(NEST_AT):
		if _grid.is_free(n):
			blockers.append(await _spawn(PLAYER, n))
	_check(nest.free_spawn_tile() == _nest_script.NO_SPAWN_TILE, "a boxed-in nest has no free tile")
	var before := _spawned_units().size()
	for i in 3:
		await nest.take_turn()
	_check(_spawned_units().size() == before, "and spawns nothing on its spawn activation")
	await _free(blockers + [nest])


func _check_destroyed_callback() -> void:
	_hive.reset()
	var nest = await _spawn_nest(NEST_AT)
	var c = load("res://scripts/contract.gd").new()
	c.type = c.Type.DESTROY
	c.target_tile = NEST_AT
	c.payout = 600
	_om.begin_mission(c)
	_check(_om.target_nest() == nest, "the Destroy contract finds its nest")
	_check(not _om.is_complete([]) and _om.status_text().contains("alive"), "alive: not complete (%s)" % _om.status_text())
	var died := [false]
	nest.died.connect(func(_u) -> void: died[0] = true)
	_check(not _hive.is_escalated, "the deck is quiet before")
	nest.take_damage(9999)
	_check(nest.life_state == load("res://scripts/unit.gd").LifeState.DEAD and died[0], "the nest dies at 0 HP")
	_check(_hive.is_escalated and _hive.last_trigger == NEST_AT,
		"its death reports to AlienHivemind at its tile (%s)" % _hive.last_trigger)
	_check(_om.is_complete([]) and _om.status_text().contains("destroyed"),
		"the Destroy objective is complete, extraction or not (%s)" % _om.status_text())
	var before := _spawned_units().size()
	_check(nest.is_downed, "a dead nest is out of the pool")
	_om.reset()
	_hive.reset()
	await _free([nest])
	_check(_spawned_units().size() == before, "and spawns nothing more")


func _spawn_nest(at: Vector3i):
	var nest = load(NEST).instantiate()
	nest.stats = load("res://scripts/alien_presets.gd").nest("Nest_T")
	nest.name = "Nest_T"
	nest.position = _grid.grid_to_world(at)
	root.add_child(nest)
	await process_frame
	return nest


func _spawned_units() -> Array:
	var out: Array = []
	for node in root.get_children():
		if String(node.name).contains("_spawn_") and is_instance_valid(node) and not node.is_queued_for_deletion():
			out.append(node)
	return out


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
			unit.remove_from_group("enemy_units")
			unit.queue_free()
	await process_frame


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
