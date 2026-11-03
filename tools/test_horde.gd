extends SceneTree
## Fodder hordes (docs/design/factions/aliens/units/fodder/README.md, "Horde
## rework"): the draw order, waking as one, and acting as one.
##
##   godot --headless --path . --script res://tools/test_horde.gd
##
## Headless, so the horde's playback is skipped (nothing would be drawn) — what is
## asserted is the RULES side: who is drawn, who acts in the horde's one draw, and
## the walk-phase arithmetic the playback runs on (`TickPlayback.horde_starts`).
##
## Scripts are load()ed and locals stay untyped for the reason test_cerberus.gd
## gives: a --script tool is compiled before the class registry and autoloads.

const SWARM := "res://scenes/swarm_unit.tscn"
const PLAYER := "res://scenes/player_unit.tscn"

# The test deck's middle compartment: a pack in its south-west corner, a soldier
# far enough north-east that nobody reaches him in one draw.
const PACK: Array[Vector3i] = [Vector3i(6, 0, 11), Vector3i(7, 0, 11), Vector3i(8, 0, 11)]
const SOLDIER_AT := Vector3i(12, 0, 2)

var _failures := 0
var _grid: Node
var _turns: Node
var _playback_script


func _initialize() -> void:
	_grid = root.get_node_or_null("GridManager")
	_turns = root.get_node_or_null("TurnManager")
	_playback_script = load("res://scripts/tick_playback.gd")
	var map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(map)
	await process_frame

	await _check_swarm_draws_last()
	await _check_horde_wakes_and_acts_as_one()
	await _check_the_huddle_all_moves()
	_check_walk_starts()

	print("")
	if _failures == 0:
		print("horde: ALL CHECKS PASSED")
		quit(0)
	else:
		print("horde: %d CHECK(S) FAILED" % _failures)
		quit(1)


## The shambling tier is a last TIER, not a low Initiative: whatever the wheel
## would say, a soldier still in the pool is drawn first.
func _check_swarm_draws_last() -> void:
	var swarm = await _spawn(SWARM, PACK[0], AlienPresets.swarm("Swarm"))
	var soldier = await _spawn(PLAYER, SOLDIER_AT)
	swarm.stats.base_initiative = 999  # the wheel would all but always pick it
	var both := _units([swarm, soldier])
	var eligible: Array = _turns._eligible(both)
	_check(eligible.size() == 1 and eligible[0] == soldier, "with a soldier left, only the soldier is eligible")
	var alone := _units([swarm])
	_check(_turns._eligible(alone).size() == 1, "with only the swarm left, it is")
	var order: Array = _turns._initiative_order(both)
	_check(order.size() == 2 and order[0] == soldier and order[1] == swarm, "and a tick's order puts it last too")
	_free([swarm, soldier])


## One body taking fire puts its whole horde into combat on the shooter; the draw
## that picks one of them takes the rest out of the pool and moves them all.
func _check_horde_wakes_and_acts_as_one() -> void:
	var soldier = await _spawn(PLAYER, SOLDIER_AT)
	var pack: Array = []
	for i in PACK.size():
		var swarm = load(SWARM).instantiate()
		swarm.stats = AlienPresets.swarm("Swarm_%d" % i)
		swarm.horde_id = "test_horde"
		swarm.name = "Swarm_%d" % i
		swarm.position = _grid.grid_to_world(PACK[i])
		root.add_child(swarm)
		pack.append(swarm)
	var stray = await _spawn(SWARM, Vector3i(10, 0, 11), AlienPresets.swarm("Stray"))
	await process_frame

	pack[0].come_under_fire(soldier)
	var all_in := true
	for swarm in pack:
		all_in = all_in and swarm.alert_state == swarm.AlertState.COMBAT and swarm.target == soldier
	_check(all_in, "one body taking fire puts the whole horde into combat on the shooter")
	_check(stray.alert_state != stray.AlertState.COMBAT, "a body outside the horde is not handed the target")

	_turns.pool.clear()
	_turns.pool.append_array([pack[0], pack[1], pack[2], stray, soldier])
	var mates: Array = _turns._horde_mates(pack[0])
	_check(mates.size() == 2 and pack[1] in mates and pack[2] in mates, "the draw finds the other two")
	_check(not (pack[1] in _turns.pool) and not (pack[2] in _turns.pool) and stray in _turns.pool,
		"and takes them out of the pool, leaving the stray")

	var before: Array[int] = []
	for swarm in pack:
		before.append(_grid.chebyshev_dist(swarm.grid_pos, SOLDIER_AT))
		swarm.begin_activation()
	await _turns._horde_turn(pack[0], mates)
	var closed := true
	for i in pack.size():
		closed = closed and _grid.chebyshev_dist(pack[i].grid_pos, SOLDIER_AT) < before[i]
	_check(closed, "every body in the horde closed in on that one draw")
	_check(not _turns.resolving_tick, "and the decision pass is closed again afterwards")
	_turns.pool.clear()
	_free(pack + [stray, soldier])


## A horde opens its fight from the huddle it spawned in. Planned one body at a
## time against a board where every mate is a wall, the bodies inside the clump
## found no way out and stood the round out. Every body must close in — the one
## in the middle included — and no two may end on one tile.
func _check_the_huddle_all_moves() -> void:
	var soldier = await _spawn(PLAYER, SOLDIER_AT)
	var centre := Vector3i(7, 0, 10)
	var pack: Array = []
	for dz in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			var swarm = load(SWARM).instantiate()
			swarm.stats = AlienPresets.swarm("Huddle_%d" % pack.size())
			swarm.horde_id = "huddle"
			swarm.name = "Huddle_%d" % pack.size()
			swarm.position = _grid.grid_to_world(centre + Vector3i(dx, 0, dz))
			root.add_child(swarm)
			pack.append(swarm)
	await process_frame
	var middle = pack[4]
	middle.come_under_fire(soldier)
	_turns.pool.clear()
	_turns.pool.append_array(pack)
	_turns.pool.erase(middle)
	var mates: Array = _turns._horde_mates(middle)
	var before: Array[int] = []
	for swarm in pack:
		before.append(_grid.chebyshev_dist(swarm.grid_pos, SOLDIER_AT))
	middle.begin_activation()
	await _turns._horde_turn(middle, mates)
	var stuck: Array[String] = []
	var tiles := {}
	for i in pack.size():
		if _grid.chebyshev_dist(pack[i].grid_pos, SOLDIER_AT) >= before[i]:
			stuck.append(String(pack[i].name))
		tiles[pack[i].grid_pos] = true
	_check(stuck.is_empty(), "every body in the huddle closes in on its first draw (stuck: %s)" % [stuck])
	_check(tiles.size() == pack.size(), "and no two end on one tile")
	var flags_clear := true
	for swarm in pack:
		flags_clear = flags_clear and not swarm.in_horde_turn and not swarm.waiting
	_check(flags_clear, "and none is left marked as mid-horde-turn or waiting")
	_turns.pool.clear()
	_free(pack + [soldier])


## The walk phase's arithmetic: bodies start at their offsets, a body's next step
## starts when its last one ends, and a step onto a tile someone is leaving
## waits for them to be halfway off it.
func _check_walk_starts() -> void:
	var EV = load("res://scripts/exploration_rules.gd")
	var lead = load(SWARM).instantiate()
	var tail = load(SWARM).instantiate()
	var a := Vector3i(6, 0, 11)
	var b := Vector3i(7, 0, 11)
	var c := Vector3i(8, 0, 11)
	# The tail is offset EARLIER than the lead, so only the vacate rule holds it back.
	var events := [
		{"unit": lead, "kind": EV.EV_STEP, "from": b, "to": c},
		{"unit": tail, "kind": EV.EV_STEP, "from": a, "to": b},
		{"unit": lead, "kind": EV.EV_STEP, "from": c, "to": c + Vector3i(1, 0, 0)},
	]
	var offsets := {lead: 0.2, tail: 0.0}
	var starts: Dictionary = _playback_script.horde_starts(events, [0, 1, 2], offsets)
	var step: float = _grid.grid_to_world(b).distance_to(_grid.grid_to_world(c)) / lead.move_speed
	_check(is_equal_approx(starts[0], 0.2), "the lead starts at its offset (%.2f)" % starts[0])
	_check(is_equal_approx(starts[1], 0.2 + step * 0.5),
		"the tail waits until the lead is halfway off the tile (%.2f)" % starts[1])
	_check(is_equal_approx(starts[2], 0.2 + step), "the lead's next step follows its last (%.2f)" % starts[2])
	lead.free()
	tail.free()


func _spawn(scene_path: String, at: Vector3i, stats = null):
	var unit = load(scene_path).instantiate()
	if stats != null:
		unit.stats = stats
	unit.position = _grid.grid_to_world(at)
	root.add_child(unit)
	await process_frame
	return unit


func _free(units: Array) -> void:
	for unit in units:
		if is_instance_valid(unit):
			_grid.set_occupant(unit.grid_pos, null)
			unit.queue_free()


func _check(ok: bool, label: String) -> void:
	if ok:
		print("  ok    " + label)
	else:
		print("  FAIL  " + label)
		_failures += 1


## A typed Array[Unit] built at run time — the type cannot be named in a --script
## tool (see the header), and TurnManager's helpers take nothing else.
func _units(items: Array) -> Array:
	return Array(items, TYPE_OBJECT, &"Node3D", load("res://scripts/unit.gd"))
