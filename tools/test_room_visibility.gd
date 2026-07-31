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
var _map
var _player
var _enemy


func _initialize() -> void:
	_grid = root.get_node_or_null("GridManager")
	_map = load("res://scenes/test_map.tscn").instantiate()
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


func _check_overwatch_survives_fast_forward() -> void:
	# Squad member at the doorway mouth, holding Overwatch, with a clear line down
	# the row into the middle room. The alien walks that row while UNDRAWN, so its
	# move is fast-forwarded — and the reserved shot must still go off.
	_move_to(_player, Vector3i(4, 0, 7))
	_move_to(_enemy, Vector3i(11, 0, 7))
	await process_frame

	_check(not _enemy.get("_rendered"), "the alien in the middle room is undrawn")
	_check(_enemy.is_instant(), "so its move will be fast-forwarded")
	_check(_grid.has_line_of_sight(_player, _enemy),
		"but the squad member at the door can see down the row")

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
