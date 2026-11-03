extends SceneTree
## Corner peeking and corner cover (GDD §6.1, §6.1.2), checked against the real
## built deck, the same way test_edge_cover.gd checks edge cover.
##
##   godot --headless --path . --script res://tools/test_corner_peek.gd
##
## maps/test_deck.txt has a free-standing wall end at (14,11) — the bulkhead at
## x=14 stops there and the deck opens below it — so a unit on (13,11) has the
## wall flush on its EAST side and (13,12) as its lean tile. The bulkhead at x=5
## has the doorway (5,7) in it, which (4,6) leans into.
##
## The "units" are bare Node3Ds carrying just what GridManager duck-types:
## `grid_pos`, `global_position` and `can_peek()`. Scripts are load()ed and called
## dynamically: a --script tool is compiled before the autoloads register.

const CORNER := Vector3i(13, 0, 11)
const LEAN := Vector3i(13, 0, 12)
const PAST := Vector3i(17, 0, 12)
const HALFWAY := Vector3i(13, 0, 6)
const INSIDE := Vector3i(13, 0, 1)
const BESIDE_DOOR := Vector3i(4, 0, 6)
const DOOR_LEAN := Vector3i(4, 0, 7)
const THROUGH_DOOR := Vector3i(8, 0, 7)
const CRATE := Vector3i(9, 0, 6)

const STUB := """extends Node3D
var grid_pos := Vector3i.ZERO
var moving := false
func can_peek() -> bool:
	return not moving
"""

## maps/corner_peek_test.txt, for rule 3: a unit on (5,3) has the wall end (6,3)
## east of it and leans to (5,4). The pillar (3,3) blocks its straight line to
## (1,4), which the lean tile's line clears — but (1,4) is on the near side of
## the wall, so the lean must not count. (7,4), past the wall, it does.
const FIX_CORNER := Vector3i(5, 0, 3)
const FIX_LEAN := Vector3i(5, 0, 4)
const FIX_NEAR := Vector3i(1, 0, 4)
const FIX_PAST := Vector3i(7, 0, 4)

const PLAYER := "res://scenes/player_unit.tscn"
const ENEMY := "res://scenes/enemy_unit.tscn"

var _failures := 0
var _grid: Node
var _combat
var _stub: GDScript
var _md
var _map


func _initialize() -> void:
	_grid = root.get_node_or_null("GridManager")
	_combat = load("res://scripts/combat.gd")
	_md = load("res://scripts/map_data.gd")
	_stub = GDScript.new()
	_stub.source_code = STUB
	_stub.reload()
	_map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(_map)
	await process_frame
	_map.build_layout("res://maps/test_deck.txt")
	# The walls' collision reaches the physics space on the next step.
	await physics_frame
	await physics_frame
	for node in get_nodes_in_group("units"):
		_grid.set_occupant(node.grid_pos, null)
		node.remove_from_group("units")
		node.free()

	_check_peek_tiles()
	_check_wall_end()
	_check_no_lean()
	_check_doorway()
	_check_squadmate()
	_check_moving()
	_check_tiles_have_sight()
	_check_corner_cover()
	await _check_corner_shot()
	await _check_walks()
	await _check_past_corner_only()

	print("")
	if _failures == 0:
		print("corner peek: ALL CHECKS PASSED")
		quit(0)
	else:
		print("corner peek: %d CHECK(S) FAILED" % _failures)
		quit(1)


func _check_peek_tiles() -> void:
	_check(_grid.sight_blocked_on(CORNER, _md.Side.EAST), "the wall is flush on (13,11)'s east side")
	_check(not _grid.sight_blocked_on(LEAN, _md.Side.EAST), "and stops before (13,12)")
	_check(_grid.peek_tiles(CORNER) == [[LEAN, _md.Side.EAST]],
		"(13,11) leans to (13,12) past the east wall (got %s)" % [_grid.peek_tiles(CORNER)])
	_check(_grid.peek_tiles(HALFWAY).is_empty(), "no lean halfway along a wall (%s)" % [_grid.peek_tiles(HALFWAY)])
	_check(_grid.peek_tiles(INSIDE).is_empty(), "no lean in an inside corner (%s)" % [_grid.peek_tiles(INSIDE)])
	_check(_grid.peek_tiles(BESIDE_DOOR) == [[DOOR_LEAN, _md.Side.EAST]],
		"(4,6) leans into the doorway (got %s)" % [_grid.peek_tiles(BESIDE_DOOR)])


func _check_wall_end() -> void:
	var u = _unit(CORNER)
	var e = _unit(PAST)
	var eye: Vector3 = u.global_position + Vector3(0, _grid.EYE_HEIGHT, 0)
	var chest: Vector3 = e.global_position + Vector3(0, _grid.CHEST_HEIGHT, 0)
	_check(not _grid.has_clear_line(u, eye, chest), "sanity: the straight line (13,11)->(17,12) hits the wall")
	_check(_grid.sight_line(u, e) == [LEAN, PAST], "leaning, (13,11) sees (17,12) from (13,12) (%s)" % [_grid.sight_line(u, e)])
	_check(_grid.sight_line(e, u) == [PAST, LEAN], "and (17,12) sees it on its lean tile (%s)" % [_grid.sight_line(e, u)])
	_check(_grid.has_line_of_sight(u, e) and _grid.has_line_of_sight(e, u), "has_line_of_sight agrees both ways")
	_free([u, e])


func _check_no_lean() -> void:
	var mid = _unit(HALFWAY)
	var e = _unit(PAST)
	_check(not _grid.has_line_of_sight(mid, e), "halfway along the wall, (13,6) cannot see (17,12)")
	_check(not _grid.has_line_of_sight(e, mid), "nor be seen from it")
	_free([mid, e])


func _check_doorway() -> void:
	var u = _unit(BESIDE_DOOR)
	var e = _unit(THROUGH_DOOR)
	_check(not _grid.has_clear_line(u, u.global_position + Vector3(0, _grid.EYE_HEIGHT, 0),
			e.global_position + Vector3(0, _grid.CHEST_HEIGHT, 0)),
		"sanity: the straight line (4,6)->(8,7) hits the bulkhead")
	_check(_grid.sight_line(u, e) == [DOOR_LEAN, THROUGH_DOOR], "leaning into the doorway, (4,6) sees (8,7)")
	_check(_grid.has_line_of_sight(e, u), "and (8,7) sees (4,6)")
	_free([u, e])


func _check_squadmate() -> void:
	var u = _unit(CORNER)
	var mate = _unit(LEAN)
	_grid.set_occupant(LEAN, mate)
	var e = _unit(PAST)
	_check(_grid.peek_tiles(CORNER) == [[LEAN, _md.Side.EAST]], "a squadmate on the lean tile leaves it a lean tile")
	_check(_grid.has_line_of_sight(u, e) and _grid.has_line_of_sight(e, u), "and the lean still sees both ways")
	_grid.set_occupant(LEAN, null)
	_free([u, mate, e])


func _check_moving() -> void:
	var u = _unit(CORNER)
	var e = _unit(PAST)
	u.moving = true
	_check(not _grid.has_line_of_sight(e, u), "a MOVING unit at the corner is not seen from (17,12)")
	_check(not _grid.has_line_of_sight(u, e), "and cannot see it")
	u.moving = false
	e.moving = true
	_check(_grid.has_line_of_sight(u, e), "at rest at the corner, it sees a moving target out in the open")
	_free([u, e])


func _check_tiles_have_sight() -> void:
	var ref = _unit(CORNER)
	_check(not _grid.tiles_have_sight(ref, CORNER, PAST, false, false), "tiles: (13,11)->(17,12) with no lean is blocked")
	_check(_grid.tiles_have_sight(ref, CORNER, PAST, true, false), "tiles: the seer leaning sees it")
	_check(_grid.tiles_have_sight(ref, PAST, CORNER, false, true), "tiles: the target leaning is seen")
	_check(not _grid.tiles_have_sight(ref, PAST, CORNER, true, false), "tiles: only the corner's own lean counts")
	_check(not _grid.tiles_have_sight(ref, HALFWAY, PAST, true, true), "tiles: halfway along the wall, nothing")
	_check(_grid.tiles_have_sight(ref, BESIDE_DOOR, THROUGH_DOOR, true, false), "tiles: leaning into the doorway")
	_check(_grid.tiles_have_sight(ref, THROUGH_DOOR, BESIDE_DOOR, false, true), "tiles: seen leaning into the doorway")
	_check(not _grid.tiles_have_sight(ref, THROUGH_DOOR, BESIDE_DOOR, false, false), "tiles: and not without the lean")
	_free([ref])


func _check_corner_cover() -> void:
	var d = _combat.defending_cover(PAST, CORNER)
	_check(d == [_md.Cover.HEAVY, _md.Side.EAST, true], "(17,12) -> (13,11): heavy, east, structural (%s)" % [d])
	d = _combat.defending_cover(Vector3i(9, 0, 11), CORNER)
	_check(d[0] == _md.Cover.NONE, "from (9,11), the open side: none (%s)" % [d])
	d = _combat.defending_cover(PAST + Vector3i(0, 1, 0), CORNER)
	_check(d[0] == _md.Cover.NONE, "from a deck up, looking over the wall: none (%s)" % [d])
	d = _combat.defending_cover(Vector3i(9, 0, 10), CRATE)
	_check(d == [_md.Cover.HEAVY, _md.Side.SOUTH, false], "the (9,6) crate edge: heavy, not structural (%s)" % [d])
	_check(_grid.cover_edge(CRATE, _md.Side.SOUTH) != null, "and the crate edge is still registered")
	_check(_grid.cover_edge(CORNER, _md.Side.EAST) == null, "the wall itself is never a CoverEdge")


## A real shot into corner cover: the -40 applies, and the wall takes no damage.
func _check_corner_shot() -> void:
	var shooter = await _spawn(ENEMY, PAST)
	var target = await _spawn(PLAYER, CORNER)
	var result = _combat.resolve_shot(shooter, target, _combat.ShotAction.SHOOT)
	_check(result.had_cover and result.cover_type == _md.Cover.HEAVY, "a shot into corner cover meets heavy cover")
	_check(result.cover_structural and not result.cover_broken, "structural, and nothing is broken")
	_check(_grid.cover_edge(CORNER, _md.Side.EAST) == null, "and no edge was made to damage")
	_check(shooter.cover_penalty_for(result.cover_type) == _combat.COVER_PENALTY_HEAVY,
		"the shooter pays the heavy-cover penalty")
	_free_units([shooter, target])


## `can_peek` is false for the whole of a walk and true again once it ends —
## however it ends. Sampled on `stepped`, which fires each tile ahead of that
## tile's suppression, overwatch and after_step checks; nothing between them
## touches the walk flag.
func _check_walks() -> void:
	var path: Array[Vector3i] = [Vector3i(11, 0, 12), Vector3i(12, 0, 12), Vector3i(13, 0, 12)]
	var u = await _spawn(PLAYER, Vector3i(10, 0, 12))
	_check(u.can_peek(), "a unit at rest can peek")
	var seen: Array = []
	var on_step := func(w) -> void: seen.append(w.can_peek())
	u.stepped.connect(on_step)
	await u.move_along(path)
	_check(seen.size() == 3 and not seen.has(true), "and cannot on any tile of a walk (%s)" % [seen])
	_check(u.can_peek(), "and can once the walk ends")

	# Cancelled on its first tile.
	seen.clear()
	var cancel := func(w) -> void: w.cancel_walk()
	u.stepped.connect(cancel)
	await u.move_along([Vector3i(12, 0, 12), Vector3i(11, 0, 12)] as Array[Vector3i])
	u.stepped.disconnect(cancel)
	_check(seen == [false] and u.can_peek(), "a cancelled walk ends at rest, peeking (%s)" % [seen])

	# Redirected on its first tile.
	seen.clear()
	var redirect := func(w) -> void:
		if seen.size() == 1:
			w.redirect_walk(Vector3i(12, 0, 10))
	u.stepped.connect(redirect)
	await u.move_along([Vector3i(11, 0, 12), Vector3i(10, 0, 12)] as Array[Vector3i])
	u.stepped.disconnect(redirect)
	_check(u.grid_pos == Vector3i(12, 0, 10), "sanity: the redirect took (at %s)" % [u.grid_pos])
	_check(not seen.has(true) and u.can_peek(), "a redirected walk peeks only at its end (%s)" % [seen])

	# Downed on its first tile.
	seen.clear()
	var drop := func(w) -> void: w.take_damage(9999)
	u.stepped.connect(drop)
	await u.move_along([Vector3i(12, 0, 11), Vector3i(12, 0, 12)] as Array[Vector3i])
	u.stepped.disconnect(drop)
	_check(u.is_downed and not u.is_walking(), "sanity: downed mid-walk, and the walk is over")
	_check(seen == [false] and not u.can_peek(), "a downed unit does not peek")
	u.stepped.disconnect(on_step)
	_free_units([u])


func _check_past_corner_only() -> void:
	_map.build_layout("res://maps/corner_peek_test.txt")
	# Asked before the new walls are in the physics space: whatever this says
	# must not be kept, or every later answer is about the old deck.
	_grid.sight_blocked_on(FIX_CORNER, _md.Side.EAST)
	await physics_frame
	await physics_frame
	_check(_grid.sight_blocked_on(FIX_CORNER, _md.Side.EAST), "an answer read before the physics step was not cached")
	_check(_grid.peek_tiles(FIX_CORNER) == [[FIX_LEAN, _md.Side.EAST]],
		"fixture: (5,3) leans to (5,4) (%s)" % [_grid.peek_tiles(FIX_CORNER)])
	var u = _unit(FIX_CORNER)
	var near = _unit(FIX_NEAR)
	var past = _unit(FIX_PAST)
	var chest: Vector3 = near.global_position + Vector3(0, _grid.CHEST_HEIGHT, 0)
	_check(not _grid.has_clear_line(u, u.global_position + Vector3(0, _grid.EYE_HEIGHT, 0), chest),
		"sanity: the pillar blocks (5,3)->(1,4)")
	_check(_grid.has_clear_line(u, _grid.grid_to_world(FIX_LEAN) + Vector3(0, _grid.EYE_HEIGHT, 0), chest),
		"sanity: (5,4)->(1,4) is clear")
	_check(not _grid.has_line_of_sight(u, near), "the lean does not count toward the near side of the wall")
	_check(not _grid.has_line_of_sight(near, u), "either way")
	_check(_grid.has_line_of_sight(u, past) and _grid.has_line_of_sight(past, u), "but does past it")
	_free([u, near, past])


func _spawn(scene_path: String, at: Vector3i):
	var unit = load(scene_path).instantiate()
	unit.position = _grid.grid_to_world(at)
	root.add_child(unit)
	await process_frame
	return unit


func _free_units(units: Array) -> void:
	for unit in units:
		if is_instance_valid(unit):
			var t = _grid.get_tile(unit.grid_pos)
			if t and t.occupant == unit:
				_grid.set_occupant(unit.grid_pos, null)
			unit.remove_from_group("units")
			unit.free()


func _unit(tile: Vector3i):
	var n := Node3D.new()
	n.set_script(_stub)
	root.add_child(n)
	n.grid_pos = tile
	n.global_position = _grid.grid_to_world(tile)
	return n


func _free(nodes: Array) -> void:
	for n in nodes:
		n.free()


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
