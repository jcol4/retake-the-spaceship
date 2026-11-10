extends SceneTree
## Fodder hordes (docs/design/factions/aliens/units/fodder/README.md, "Horde
## rework"): the draw order, waking as one, and acting as one.
##
##   godot --headless --path . --script res://tools/test_horde.gd
##
## Headless, so the horde's playback is skipped (nothing would be drawn) — what is
## asserted is the RULES side: who is drawn, who acts in the horde's one draw, how
## the zombie tier squeezes past other aliens, and the corner-cut route the crowd
## playback steers along (`TickPlayback.crowd_route`).
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
	await _check_label_follows_the_model()
	await _check_squeezes_down_a_corridor()
	await _check_pack_wraps_its_prey()
	await _check_shot_carries_into_a_shared_tile()
	_check_crowd_route()

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
	var held := true
	for swarm in pack:
		held = held and _grid.get_tile(swarm.grid_pos).occupant == swarm
	_check(held, "and every body holds the tile it ended on")
	_turns.pool.clear()
	_free(pack + [soldier])


## A unit fog of war keeps off the screen must not give itself away by name. The
## label is drawn by its own camera, so hiding the model used to leave it up — a
## room of horde labels with no bodies under them.
func _check_label_follows_the_model() -> void:
	var swarm = await _spawn(SWARM, PACK[0], AlienPresets.swarm("Swarm"))
	var label = swarm.get_node("NameLabel")
	swarm.set_rendered(false)
	_check(not swarm.visual.visible and not label.visible, "an undrawn body's label is hidden with it")
	swarm.set_rendered(true)
	_check(swarm.visual.visible and label.visible, "and comes back when it is drawn again")
	swarm.begin_display()
	swarm.set_display_visible(false)
	_check(not label.visible, "playback hiding the model hides the label too")
	swarm.end_display()
	_check(label.visible, "and the label follows it back when playback ends")
	_free([swarm])


## A zombie walks THROUGH another alien in a one-wide corridor — here a
## sleeping mate not in its horde — and ends on a tile of its own beyond it,
## without taking the tile from the one it passed.
func _check_squeezes_down_a_corridor() -> void:
	var soldier = await _spawn(PLAYER, Vector3i(23, 0, 14))
	var sleeper = await _spawn(SWARM, Vector3i(20, 0, 14), AlienPresets.swarm("Sleeper"))
	var runner = await _spawn(SWARM, Vector3i(17, 0, 14), AlienPresets.swarm("Runner"))
	runner.come_under_fire(soldier)
	runner.begin_activation()
	await runner.take_turn()
	_check(runner.grid_pos.x > 20, "the zombie got past the alien in the corridor (at %s)" % [runner.grid_pos])
	_check(runner.grid_pos != sleeper.grid_pos, "and did not end on its tile")
	_check(_grid.get_tile(sleeper.grid_pos).occupant == sleeper, "which the one it passed still holds")
	_check(_grid.get_tile(runner.grid_pos).occupant == runner, "and it holds the tile it ended on")
	_free([soldier, sleeper, runner])


## A pack closing on its prey spreads round it — each body takes a free tile
## beside the soldier rather than all queueing for the nearest one.
func _check_pack_wraps_its_prey() -> void:
	var soldier = await _spawn(PLAYER, Vector3i(5, 0, 10))
	var pack: Array = []
	for at in [Vector3i(8, 0, 11), Vector3i(9, 0, 11), Vector3i(10, 0, 11),
			Vector3i(8, 0, 12), Vector3i(9, 0, 12), Vector3i(10, 0, 12)]:
		var swarm = load(SWARM).instantiate()
		swarm.stats = AlienPresets.swarm("Wrap_%d" % pack.size())
		swarm.horde_id = "wrap"
		swarm.name = "Wrap_%d" % pack.size()
		swarm.position = _grid.grid_to_world(at)
		root.add_child(swarm)
		pack.append(swarm)
	await process_frame
	pack[0].come_under_fire(soldier)
	_turns.pool.clear()
	_turns.pool.append_array(pack)
	_turns.pool.erase(pack[0])
	var mates: Array = _turns._horde_mates(pack[0])
	pack[0].begin_activation()
	await _turns._horde_turn(pack[0], mates)
	var beside := 0
	var tiles := {}
	for swarm in pack:
		if _grid.is_melee_adjacent(swarm.grid_pos, soldier.grid_pos):
			beside += 1
		tiles[swarm.grid_pos] = true
	_check(beside == pack.size(), "every body of the pack ends beside its prey (%d of %d)" % [beside, pack.size()])
	_check(tiles.size() == pack.size(), "each on a tile of its own")
	_turns.pool.clear()
	_free(pack + [soldier])


## A round into a zombie that is squeezing past another alien carries on into
## that one: it is the first body behind the target (Penetration.trace).
func _check_shot_carries_into_a_shared_tile() -> void:
	var soldier = await _spawn(PLAYER, Vector3i(15, 0, 14))
	var mate = await _spawn(SWARM, Vector3i(19, 0, 14), AlienPresets.swarm("Pressed"))
	var runner = await _spawn(SWARM, Vector3i(18, 0, 14), AlienPresets.swarm("Squeezer"))
	runner.grid_pos = mate.grid_pos  # mid-walk, on the tile it is passing through
	runner.global_position = mate.global_position
	var line: Array = load("res://scripts/penetration.gd").trace(soldier, runner, true)
	var order: Array = []
	for entry in line:
		if entry.has("unit"):
			order.append(entry["unit"])
	var at := order.find(runner)
	_check(at >= 0 and at + 1 < order.size() and order[at + 1] == mate,
		"the shot at the squeezer has the alien sharing its tile next behind it")
	runner.grid_pos = Vector3i(18, 0, 14)
	_free([soldier, mate, runner])


## The crowd playback's route: corners cut across open floor, never across a wall.
func _check_crowd_route() -> void:
	var open: Array[Vector3] = []
	for at in [Vector3i(1, 0, 9), Vector3i(2, 0, 9), Vector3i(3, 0, 9), Vector3i(3, 0, 10), Vector3i(3, 0, 11)]:
		open.append(_grid.grid_to_world(at))
	var cut: Array = _playback_script.crowd_route(open)
	_check(cut.size() < open.size() and cut[0] == open[0] and cut[-1] == open[-1],
		"across open floor the route cuts its corner (%d points from %d)" % [cut.size(), open.size()])
	# Down through the doorway at (5, 13) and along the corridor: the wall either
	# side of the door must not be cut across.
	var door: Array[Vector3] = []
	for at in [Vector3i(4, 0, 11), Vector3i(5, 0, 12), Vector3i(5, 0, 13), Vector3i(5, 0, 14),
			Vector3i(6, 0, 14), Vector3i(7, 0, 14)]:
		door.append(_grid.grid_to_world(at))
	var through: Array = _playback_script.crowd_route(door)
	var clear := true
	for k in range(1, through.size()):
		clear = clear and _playback_script._walkable_line(through[k - 1], through[k])
	_check(clear and through[-1] == door[-1], "through a doorway every leg stays on walkable floor (%d legs)" % (through.size() - 1))


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
