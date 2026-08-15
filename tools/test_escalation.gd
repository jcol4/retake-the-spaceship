extends SceneTree
## Ship-wide alien escalation, and the local scoping it is an exception to.
##
##   godot --headless --path . --script res://tools/test_escalation.gd
##
## Two systems that only make sense against each other, so they are tested
## together: alerts are LOCAL by default — which is what makes shutting a door on
## a compartment mean something — and escalation is the small set of loud events
## that breaks that scoping once, ship-wide, before the deck settles again.
##
## The local half is the half that used to be wrong: propagation was a 6-tile
## radius, which leaks straight through bulkheads, so "isolating rooms via doors
## is a valid, intentional player strategy" (Sec 11.2) was not actually true.
## That is asserted here rather than assumed, because a radius and a compartment
## agree in open ground and differ only exactly where it matters.

const SWARM := "res://scenes/swarm_unit.tscn"
const PLAYER := "res://scenes/player_unit.tscn"

## Two tiles in DIFFERENT rooms of the test deck, close enough that the old
## radius (6) would have carried an alert between them and a wall now stops it.
## The deck's left room is x 1-4, the middle x 6-13.
const LEFT_ROOM := Vector3i(3, 0, 3)
const MID_ROOM := Vector3i(7, 0, 3)
## Same room as LEFT_ROOM, so this one SHOULD hear its neighbour.
const LEFT_ROOM_NEIGHBOUR := Vector3i(2, 0, 5)

var _failures := 0
var _grid: Node
var _hive: Node
var _turns: Node


func _initialize() -> void:
	_grid = root.get_node_or_null("GridManager")
	_hive = root.get_node_or_null("AlienHivemind")
	_turns = root.get_node_or_null("TurnManager")
	var map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(map)
	await process_frame

	await _check_alerts_stop_at_compartment_walls()
	await _check_escalation_wakes_the_ship()
	await _check_escalation_does_not_hand_out_targets()
	await _check_de_escalation_settles_the_uncontacted()
	await _check_aliens_do_not_trip_their_own_alarms()

	print("")
	if _failures == 0:
		print("escalation: ALL CHECKS PASSED")
		quit(0)
	else:
		print("escalation: %d CHECK(S) FAILED" % _failures)
		quit(1)


## THE LOCAL RULE. A scream carries to the room, not to a radius — so a wall
## between two aliens stops it even when they are only a few tiles apart.
func _check_alerts_stop_at_compartment_walls() -> void:
	var screamer = await _spawn(SWARM, LEFT_ROOM)
	var same_room = await _spawn(SWARM, LEFT_ROOM_NEIGHBOUR)
	var next_room = await _spawn(SWARM, MID_ROOM)
	var player = await _spawn(PLAYER, LEFT_ROOM + Vector3i(1, 0, 0))

	var gap: int = _grid.chebyshev_dist(screamer.grid_pos, next_room.grid_pos)
	_check(gap <= screamer.alert_propagation_range,
		"the alien through the wall is within the OLD radius (%d <= %d)"
		% [gap, screamer.alert_propagation_range])

	screamer._enter_combat(player, "test")
	_check(same_room.alert_state != same_room.AlertState.UNAWARE,
		"an alien in the same compartment is roused")
	_check(next_room.alert_state == next_room.AlertState.UNAWARE,
		"one through a bulkhead is NOT — the radius used to carry through it")
	_free([screamer, same_room, next_room, player])


## Escalation is the exception: it reaches the whole deck regardless of walls.
func _check_escalation_wakes_the_ship() -> void:
	_hive.reset()
	var near = await _spawn(SWARM, LEFT_ROOM)
	var far = await _spawn(SWARM, MID_ROOM)

	var woken: int = _hive.escalate(MID_ROOM, "test alarm")
	_check(woken >= 2, "escalation wakes aliens in every compartment (%d)" % woken)
	_check(near.alert_state == near.AlertState.ALERT,
		"including one behind a wall from the trigger")
	_check(_hive.is_escalated, "and the ship is flagged escalated")
	_free([near, far])


## The load-bearing restraint (Sec 6): escalated aliens investigate, they do not
## acquire. Without this, one alarm would turn every alien on the deck omniscient
## and the whole local detection system would stop mattering.
func _check_escalation_does_not_hand_out_targets() -> void:
	_hive.reset()
	var alien = await _spawn(SWARM, LEFT_ROOM)
	var player = await _spawn(PLAYER, MID_ROOM)
	_hive.escalate(MID_ROOM, "test alarm")

	_check(alien.alert_state == alien.AlertState.ALERT,
		"a roused alien is ALERT, not COMBAT")
	_check(alien.target == null, "and has been handed no target")
	_check(alien.acquire_target() == null,
		"so it still has to find somebody the ordinary way")
	_free([alien, player])


## Escalation expires. An alien that walked toward a noise and found nothing goes
## back to sleep; one that found a fight stays awake on its own account.
func _check_de_escalation_settles_the_uncontacted() -> void:
	_hive.reset()
	var quiet = await _spawn(SWARM, LEFT_ROOM)
	var engaged = await _spawn(SWARM, MID_ROOM)
	var player = await _spawn(PLAYER, MID_ROOM + Vector3i(1, 0, 0))
	var start: int = _turns.turn_number
	_hive.escalate(MID_ROOM, "test alarm")
	engaged._enter_combat(player, "test")

	# One turn short of the timer: nothing settles yet.
	_hive._on_turn_started(start + _hive.DE_ESCALATION_TURNS)
	_check(quiet.alert_state == quiet.AlertState.ALERT,
		"still searching one turn inside the window")

	_hive._on_turn_started(start + _hive.DE_ESCALATION_TURNS + 1)
	_check(quiet.alert_state == quiet.AlertState.UNAWARE,
		"and settles once the window closes")
	_check(engaged.alert_state == engaged.AlertState.COMBAT,
		"while one that found a fight is left alone")
	_check(not _hive.is_escalated, "the ship is no longer escalated")
	_free([quiet, engaged, player])


## An alarm panel is ship security. The things that live here are what it exists
## to report, so a shambler wandering over one must not call the deck in on
## itself — and must not spring the trap long before the squad arrives.
func _check_aliens_do_not_trip_their_own_alarms() -> void:
	_hive.reset()
	var alien = await _spawn(SWARM, LEFT_ROOM)
	var player = await _spawn(PLAYER, MID_ROOM)

	var tile = _grid.get_tile(alien.grid_pos)
	tile.alarm = true
	alien._trip_alarm_here()
	_check(not _hive.is_escalated, "an alien walking onto a panel does not trip it")
	_check(tile.alarm, "and leaves it armed for somebody who will")

	var player_tile = _grid.get_tile(player.grid_pos)
	player_tile.alarm = true
	player._trip_alarm_here()
	_check(_hive.is_escalated, "a soldier stepping on one sets it off")
	_check(not player_tile.alarm, "and it is spent — a panel fires once, not every pass")
	_free([alien, player])


func _spawn(scene_path: String, at: Vector3i):
	var unit = load(scene_path).instantiate()
	if scene_path == SWARM:
		unit.stats = AlienPresets.swarm("Swarm")
	else:
		unit.stats = ClassPresets.roll(UnitStats.UnitClass.ASSAULT, "Reyes")
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
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
