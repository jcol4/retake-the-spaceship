extends SceneTree
## Phase 6a of MIGRATION_PLAN.md: sprites are drawn only in rooms holding a
## player unit (Q12), and units that are NOT drawn fast-forward their activation
## instead of making the player wait out animations they cannot see (Q14).
##
##   godot --headless --path . --script res://tools/test_room_visibility.gd
##
## Deliberately NOT headless-only logic: this runs with a window so
## Unit.is_instant is answering the interesting question — "is this unit
## rendered" — rather than the trivial one. Run it windowed:
##
##   godot --path . --script res://tools/test_room_visibility.gd
##
## The last case is the one worth having. Fast-forwarding an unseen unit must not
## skip the per-tile work its move does — overwatch above all, because a reserved
## shot that silently fails to fire is a rule quietly not applying.

const LEFT_ROOM := Vector3i(2, 0, 7)
const DOOR := Vector3i(5, 0, 7)
const MIDDLE_ROOM := Vector3i(10, 0, 7)
const RIGHT_ROOM := Vector3i(17, 0, 3)

var _failures := 0
var _grid: Node
var _tm: Node
var _map
var _player
var _enemy


func _initialize() -> void:
	_grid = root.get_node_or_null("GridManager")
	_tm = root.get_node_or_null("TurnManager")
	_map =load("res://scenes/test_map.tscn").instantiate()
	_map.layout_path = "res://maps/test_deck.txt"
	root.add_child(_map)

	_player = load("res://scenes/player_unit.tscn").instantiate()
	_player.position = _grid.grid_to_world(LEFT_ROOM)
	root.add_child(_player)

	_enemy = load("res://scenes/enemy_unit.tscn").instantiate()
	_enemy.position = _grid.grid_to_world(RIGHT_ROOM)
	root.add_child(_enemy)
	await process_frame
	await process_frame

	_check_gating()
	_check_generated_corridors()
	await _check_sight_and_memory()
	await _check_walk_into_view()
	await _check_overwatch_survives_fast_forward()

	print("")
	if _failures == 0:
		print("room visibility: ALL CHECKS PASSED")
		quit(0)
	else:
		print("room visibility: %d CHECK(S) FAILED" % _failures)
		quit(1)


func _check_gating() -> void:
	var data = _map.data
	var left: int = data.room_index_at(LEFT_ROOM)
	var right: int = data.room_index_at(RIGHT_ROOM)
	_check(left != right, "the squad and the alien are in different rooms")

	_check(_player.get("_rendered"), "a player unit is always in a revealed room")
	_check(not _enemy.get("_rendered"), "an alien two rooms away is not drawn")
	_check(not _enemy.get_node("Visual").visible, "its sprite layers are hidden")

	# The half that matters for pacing: an undrawn unit resolves with no time on
	# the clock, so its activation does not stall the game against a static screen.
	_check(_enemy.is_instant(), "and therefore fast-forwards its activation")
	_check(not _player.is_instant() or DisplayServer.get_name() == "headless",
		"while a drawn unit animates normally")

	# A corridor is revealed by the rooms it joins, not on its own account —
	# otherwise the doorway a squad is about to walk through stays sealed.
	var door: int = _map.data.room_index_at(DOOR)
	_check(door in _map.data.corridors, "the (5,7) doorway is a corridor")
	_check(_map._revealed.has(door), "and is revealed by the squad in the room beside it")
	_check(not _map._revealed.has(_map.data.room_index_at(MIDDLE_ROOM)),
		"but the room on its far side is not")


## A generated deck's links join room to room, skipping the corridor between them,
## so revealing by `linked_rooms` never drew a corridor there: a merc in the hall
## off the squad's room fought it undrawn, and so instantly. Seed 1873861863 is
## the deck that turned it up.
func _check_generated_corridors() -> void:
	var gen = load("res://scripts/map_generator.gd")
	var cfg = load("res://scripts/campaign/contract_offer.gd").config_for(0)
	var data = gen.generate(1873861863, cfg)
	var every_corridor_touches_a_room := true
	# A corridor carved entirely over earlier ones owns no tile at all; it has no
	# floor to stand on, so nothing to reveal.
	var owned := {}
	for pos in data.room_of:
		owned[data.room_of[pos]] = true
	for corridor: int in data.corridors:
		if not owned.has(corridor):
			continue
		var rooms: Array = data.touching_regions(corridor).filter(
			func(i: int) -> bool: return not (i in data.corridors))
		if rooms.is_empty():
			every_corridor_touches_a_room = false
	_check(not data.corridors.is_empty() and every_corridor_touches_a_room,
		"every generated corridor touches a room it opens onto")
	var room: int = data.room_index_at(Vector3i(23, 0, 16))
	var hall: int = data.room_index_at(Vector3i(27, 0, 15))
	_check(hall in data.corridors and not (hall in data.linked_rooms(room)),
		"the hall off room %d is not in its links" % room)
	_check(hall in data.touching_regions(room), "but does touch it")


## Beyond the revealed rooms, what a soldier can see is drawn (GDD Sec 10.6), and
## stays drawn for the rest of the round once seen.
func _check_sight_and_memory() -> void:
	_move_to(_player, Vector3i(4, 0, 7))
	_move_to(_enemy, Vector3i(11, 0, 7))
	await process_frame
	_check(not _map._revealed.has(_map.data.room_index_at(Vector3i(11, 0, 7))),
		"the middle room is not revealed")
	_check(_grid.has_line_of_sight(_player, _enemy), "but the soldier at the door sees down the row")
	_check(_enemy.get("_rendered"), "so the alien there is drawn")

	# Out of sight in the right room, but seen this round: still drawn...
	_move_to(_enemy, RIGHT_ROOM)
	await process_frame
	_check(not _map.squad_sees_tile(RIGHT_ROOM), "the right room is out of sight")
	_check(_enemy.get("_rendered"), "a unit spotted this round stays drawn out of sight")
	# ...until the round ends with nobody seeing it.
	_tm.turn_ending.emit(_tm.turn_number)
	await process_frame
	_check(not _enemy.get("_rendered"), "and is forgotten at the round's end")


## B1: visibility is asked per step, not per frame. An undrawn walk takes no
## frames, so before that a unit walking into sight crossed the whole way undrawn
## and appeared at the end of it.
func _check_walk_into_view() -> void:
	_move_to(_player, Vector3i(4, 0, 7))
	var start := Vector3i(7, 0, 2)
	var path: Array[Vector3i] = []
	for z in range(3, 8):
		path.append(Vector3i(7, 0, z))
	_move_to(_enemy, start)
	_tm.turn_ending.emit(_tm.turn_number)  # forget the last check's sighting
	await process_frame
	_check(not _map.squad_sees_tile(start) and _map.squad_sees_tile(path[-1]),
		"the walk starts out of sight and ends in it")
	_check(not _enemy.get("_rendered"), "the alien starts undrawn")
	var drawn_at: Array = []
	var record := func(_u) -> void: drawn_at.append(_enemy.get("_rendered"))
	_enemy.stepped.connect(record)
	await _enemy.move_along(path)
	_enemy.stepped.disconnect(record)
	_check(not drawn_at[0], "its first step, out of sight, stays undrawn")
	_check(drawn_at[-1], "it is drawn from the step that brings it into sight")


func _check_overwatch_survives_fast_forward() -> void:
	# Squad member at the doorway mouth, holding Overwatch, with a clear line down
	# the row into the middle room. The alien walks that row — drawn, now that
	# sight draws it, so the move only fast-forwards headless — and the reserved
	# shot must go off either way.
	_move_to(_player, Vector3i(4, 0, 7))
	_move_to(_enemy, Vector3i(11, 0, 7))
	await process_frame
	_check(_grid.has_line_of_sight(_player, _enemy),
		"the squad member at the door can see down the row")

	_player.on_overwatch = true
	_player.ammo = maxi(_player.ammo, 1)
	var path: Array[Vector3i] = []
	for x in [10, 9, 8, 7]:
		path.append(Vector3i(x, 0, 7))
	await _enemy.move_along(path)

	_check(not _player.on_overwatch, "OVERWATCH FIRED during the fast-forwarded move")
	_check(_enemy.grid_pos == Vector3i(7, 0, 7) or _enemy.is_downed,
		"and the move still visited every tile (ended at %s)" % _enemy.grid_pos)


func _move_to(unit, pos: Vector3i) -> void:
	_grid.set_occupant(unit.grid_pos, null)
	unit.grid_pos = pos
	unit.global_position = _grid.grid_to_world(pos)
	_grid.set_occupant(pos, unit)


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
