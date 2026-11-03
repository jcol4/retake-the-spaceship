extends SceneTree
## Fog of war over the layout, and XCOM-style pick-then-confirm targeting.
##
##   godot --headless --path . --script res://tools/test_fog_and_targeting.gd
##
## Fog: a region's floor, walls and props are drawn only once a soldier has
## stood in it or seen into it, and stay drawn after the squad leaves.
## Targeting: in a shot mode a hostile is PICKED first (skull or map click) and
## the shot only goes off on Confirm.

const LEFT_ROOM := Vector3i(2, 0, 7)
const DOOR_MOUTH := Vector3i(4, 0, 7)
const MIDDLE_ROOM := Vector3i(11, 0, 7)
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
	_map = load("res://scenes/test_map.tscn").instantiate()
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

	await _check_fog()
	await _check_targeting()

	print("")
	if _failures == 0:
		print("fog and targeting: ALL CHECKS PASSED")
		quit(0)
	else:
		print("fog and targeting: %d CHECK(S) FAILED" % _failures)
		quit(1)


func _check_fog() -> void:
	var data = _map.data
	var left: int = data.room_index_at(LEFT_ROOM)
	var middle: int = data.room_index_at(MIDDLE_ROOM)
	var right: int = data.room_index_at(RIGHT_ROOM)

	_check(_map.is_explored_tile(LEFT_ROOM), "the squad's own room is explored")
	_check(not _map.squad_sees_tile(MIDDLE_ROOM) or _map.is_explored_tile(MIDDLE_ROOM),
		"a room the squad can see into is explored")
	_check(not _map.is_explored_tile(RIGHT_ROOM), "a room nobody has seen is not")
	_check(_group(str(left)) != null and _group(str(left)).visible, "the squad's room's floor is drawn")
	_check(_group(str(right)) != null and not _group(str(right)).visible,
		"the unexplored room's floor is not")
	_check(_any_visual_under(_group(str(right))), "and that group really holds its art")

	# Walls are drawn with every room they bound: a group naming the left room is
	# drawn even when it also names an unexplored one.
	var shared_drawn := true
	var foreign_hidden := true
	for key: String in _map._fog_groups:
		var regions: Array = _map._fog_group_regions[_map._fog_groups[key]]
		var any: bool = regions.any(func(r: int) -> bool: return _map._explored.has(r))
		if any and not _map._fog_groups[key].visible:
			shared_drawn = false
		if not any and _map._fog_groups[key].visible:
			foreign_hidden = false
	_check(shared_drawn, "every group touching explored ground is drawn")
	_check(foreign_hidden, "every group touching none of it is hidden")

	# Collision is untouched: the unexplored room's walls still block a ray.
	_check(_grid.has_tile(RIGHT_ROOM), "an unexplored room's tiles still exist")

	# Seeing into a room explores it, without walking in.
	_move_to(_player, DOOR_MOUTH)
	await process_frame
	_check(_map.squad_sees_tile(MIDDLE_ROOM), "from the door mouth the middle room is in sight")
	_check(_map._explored.has(middle), "so it is explored")
	_check(not _map._revealed.has(middle), "though nobody stands in it")

	# Standing in a room explores it; leaving does not un-explore it.
	_move_to(_player, RIGHT_ROOM)
	await process_frame
	_check(_map._explored.has(right) and _group(str(right)).visible, "walking in explores the far room")
	_move_to(_player, LEFT_ROOM)
	await process_frame
	_check(_map._explored.has(right) and _group(str(right)).visible, "and it stays drawn after leaving")

	# The tools' escape hatch.
	_map.fog_of_war = false
	_map._apply_fog()
	var all_shown := true
	for key: String in _map._fog_groups:
		all_shown = all_shown and _map._fog_groups[key].visible
	_check(all_shown, "fog_of_war = false draws the whole deck")
	_map.fog_of_war = true
	_map._apply_fog()


func _check_targeting() -> void:
	_move_to(_player, DOOR_MOUTH)
	_move_to(_enemy, MIDDLE_ROOM)
	_player.ap = 99
	_player.ammo = maxi(_player.ammo, 3)
	await process_frame
	_player.set_mode(_player.Mode.SHOOT)
	var targets: Array = _player.shot_targets()
	_check(targets.has(_enemy), "the alien in sight is a target (one skull)")
	var chance: int = _player.target_hit_chance(_enemy)
	_check(chance >= 0 and chance <= 100, "with a hit chance to show on hover (%d%%)" % chance)

	var picks: Array = []
	_player.target_picked.connect(func(t) -> void: picks.append(t))
	var ammo_before: int = _player.ammo
	_player.pick_target(_enemy)
	_check(_player.picked_target == _enemy and picks == [_enemy], "picking marks the target")
	_check(_player.ammo == ammo_before, "and does NOT fire")

	_player.set_mode(_player.Mode.SUPPRESS)
	_check(_player.picked_target == null and picks[-1] == null, "changing mode drops the pick")

	# Aimed Shot: Confirm opens the zone menu rather than firing.
	_player.set_mode(_player.Mode.AIMED_SHOT)
	var zone_menu: Array = []
	_player.aimed_shot_target_picked.connect(func(t) -> void: zone_menu.append(t))
	_player.pick_target(_enemy)
	_player.confirm_target()
	_check(zone_menu == [_enemy], "Aimed Shot's Confirm opens the zone menu for the target")
	_check(_player.ammo == ammo_before, "without firing yet")

	# Shoot: Confirm fires.
	_player.set_mode(_player.Mode.SHOOT)
	var log: Array = []
	_player.action_logged.connect(func(t: String) -> void: log.append(t))
	_player.pick_target(_enemy)
	_player.confirm_target()
	for i in 600:
		if log.any(func(t: String) -> bool: return "fired at" in t):
			break
		await process_frame
	_check(log.any(func(t: String) -> bool: return "fired at" in t), "Shoot's Confirm fires the shot")
	_check(_player.ammo < ammo_before, "spending ammo")
	_check(_player.picked_target == null, "and clears the pick")


func _group(key: String) -> Node3D:
	return _map._fog_groups.get(key)


func _any_visual_under(node: Node) -> bool:
	return node != null and not node.find_children("*", "VisualInstance3D", true, false).is_empty()


func _move_to(unit, pos: Vector3i) -> void:
	_grid.set_occupant(unit.grid_pos, null)
	unit.grid_pos = pos
	unit.global_position = _grid.grid_to_world(pos)
	_grid.set_occupant(pos, unit)


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
