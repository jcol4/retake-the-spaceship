extends SceneTree
## Phase 6b of MIGRATION_PLAN.md: the edge-cover rules, checked against the real
## built deck rather than a fixture, so the map format, the builder and the
## combat maths all have to agree for this to pass.
##
##   godot --headless --path . --script res://tools/test_edge_cover.gd
##
## maps/test_deck.txt puts heavy cover on the SOUTH edge of (9,6). Every case
## below is phrased against that one edge, so a failure points at a rule rather
## than at bookkeeping.
##
## Scripts are load()ed and called dynamically rather than named: combat.gd and
## grid_manager.gd reference the GridManager autoload at COMPILE time, and a
## --script tool is compiled before autoloads register.

const COVERED := Vector3i(9, 0, 6)

var _failures := 0
var _grid: Node
var _combat


func _initialize() -> void:
	_grid = root.get_node_or_null("GridManager")
	_combat = load("res://scripts/combat.gd")
	var map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(map)
	await process_frame

	_check_geometry()
	_check_direction()
	_check_diagonals()
	_check_passability()
	# Before _check_degradation, which shoots the (9,6) south edge to pieces —
	# every posture case below is phrased against that edge being intact.
	await _check_posture()
	_check_degradation()

	print("")
	if _failures == 0:
		print("edge cover: ALL CHECKS PASSED")
		quit(0)
	else:
		print("edge cover: %d CHECK(S) FAILED" % _failures)
		quit(1)


func _check_geometry() -> void:
	var edge = _grid.cover_edge(COVERED, MapData.Side.SOUTH)
	_check(edge != null, "the builder registered the (9,6) south edge")
	_check(edge != null and edge.type == MapData.Cover.HEAVY, "as heavy cover")
	_check(edge != null and edge.node != null, "with a prop attached")

	# The one thing sharing has to guarantee: both tiles see the SAME object, so
	# there is one HP pool and one tier, not two that drift apart.
	var mirror = _grid.cover_edge(COVERED + Vector3i(0, 0, 1), MapData.Side.NORTH)
	_check(mirror == edge, "and the tile to the south sees that identical edge")

	# The prop must sit ON the boundary, not at either tile's centre — this is
	# what makes sprite depth sorting unambiguous at every camera yaw.
	if edge != null and edge.node != null:
		var boundary: Vector3 = _grid.grid_to_world(COVERED) \
			+ Vector3(0, 0, _grid.TILE_SIZE * 0.5)
		var flat := Vector2(edge.node.global_position.x - boundary.x,
			edge.node.global_position.z - boundary.z)
		_check(flat.length() < 0.01,
			"the prop straddles the boundary, not a tile centre (off by %.3f)" % flat.length())


func _check_direction() -> void:
	# A shot from the south crosses the covered edge; one from the north does not.
	# That asymmetry is the whole point of going edge-based: which side you are
	# protected from is now a fact about the map, not a guess about geometry.
	_check(_defence(COVERED + Vector3i(0, 0, 4))[0] == MapData.Cover.HEAVY,
		"a shooter to the south is stopped by the cover")
	_check(_defence(COVERED + Vector3i(0, 0, -4))[0] == MapData.Cover.NONE,
		"a shooter to the north is not")
	_check(_defence(COVERED + Vector3i(4, 0, 0))[0] == MapData.Cover.NONE,
		"nor is one due east, on an open edge")

	# And the penalty follows the tier, unchanged from the per-tile model.
	_check(_combat.cover_penalty(MapData.Cover.HEAVY) == _combat.COVER_PENALTY_HEAVY,
		"heavy still costs COVER_PENALTY_HEAVY")
	_check(_combat.cover_penalty(MapData.Cover.NONE) == 0, "no cover costs nothing")


## Cover POSTURE — which cover a unit turns to use and whether it is posed as
## using it. Separate from everything above because it is the one part of the
## cover system that is not purely a fact about the map: it depends on where the
## unit is looking, and (via snap_to_cover) it changes where the unit looks.
##
## `&"low"` rather than `UnitVisual.COVER_LOW`: naming UnitVisual here would
## compile unit_visual.gd, which reads the LightingManager and GridManager
## autoloads at compile time, and a --script tool runs before those register.
func _check_posture() -> void:
	var unit = load("res://scenes/player_unit.tscn").instantiate()
	unit.position = _grid.grid_to_world(COVERED)
	root.add_child(unit)
	await process_frame

	# The tile's only cover is on its south edge, so that is the side to turn out
	# over — from any starting facing, including directly away from it.
	unit.rotation.y = 0.0  # facing north, straight away from the crate
	_check(unit._cover_side_to_face() == MapData.Side.SOUTH,
		"a unit facing away from its cover still snaps to the covered side")
	# ...and while it faces that way it is NOT using the cover, which is what the
	# facing gate exists to say.
	_check(unit.cover_pose() == &"",
		"and is not posed as using cover until it has turned")

	# Godot forward is -Z and south is +Z, so PI is looking out over the crate.
	unit.rotation.y = PI
	_check(unit.cover_pose() == &"low", "facing out over the cover poses it low")
	# A diagonal either side of due south is still using that cover: facing is
	# quantised to eight and the crate is one of four, so demanding an exact match
	# would drop the unit out of cover on half its reachable facings.
	unit.rotation.y = PI - PI / 4.0
	_check(unit.cover_pose() == &"low", "as does a diagonal adjacent to it")
	# One more step round is 90 degrees off, running along the crate rather than
	# looking over it.
	unit.rotation.y = PI - PI / 2.0
	_check(unit.cover_pose() == &"",
		"but looking along the crate rather than over it does not")

	# Hunkering must NOT suppress the cover pose: the hunker settles into the
	# cover art, so a unit reporting no pose here would drop to the generic
	# standing-in-the-open crouch instead.
	unit.rotation.y = PI
	unit.hunkered = true
	_check(unit.cover_pose() == &"low", "a hunkered unit in cover keeps the cover pose")
	unit.hunkered = false
	# Being downed does suppress it — a body on the deck is its own read.
	unit.is_downed = true
	_check(unit.cover_pose() == &"", "a downed unit has no cover pose")
	unit.is_downed = false

	# An open tile leaves facing alone, so a unit that runs into the middle of a
	# room keeps looking the way it was going.
	unit.grid_pos = COVERED + Vector3i(0, 0, -1)
	_check(unit._cover_side_to_face() == -1, "an uncovered tile is nothing to turn toward")
	_check(unit.cover_pose() == &"", "and poses plain")

	# The unit registered itself as the occupant of COVERED in _ready, and the
	# tile has to be clear again before _check_degradation asks whether it is
	# passable — so the occupant is released HERE rather than left to the free.
	# `grid_pos` is put back first because it is the key that entry was written
	# under, and the line above moved it.
	unit.grid_pos = COVERED
	_grid.set_occupant(COVERED, null)
	# Freed the ordinary way and then given the frame it needs to happen, rather
	# than `free()`d out from under the tree: a Unit builds a light rig and a
	# label in _ready, and tearing it down mid-frame strands them.
	unit.queue_free()
	await process_frame


func _check_diagonals() -> void:
	# A diagonal shot crosses a CORNER, not an edge. Both adjacent sides are
	# tested and the stronger applies, so tucking into the corner still works.
	var se := _defence(COVERED + Vector3i(3, 0, 3))
	_check(se[0] == MapData.Cover.HEAVY, "a diagonal from the south-east finds the south edge")
	_check(se[1] == MapData.Side.SOUTH, "and names that edge, not the open east one")
	_check(_defence(COVERED + Vector3i(3, 0, -3))[0] == MapData.Cover.NONE,
		"a diagonal from the north-east crosses two open edges")


func _check_passability() -> void:
	# The balance-relevant half of the change: cover used to claim its own
	# impassable tile, so this tile is new floor area and a new legal destination.
	_check(_grid.is_free(COVERED), "a covered tile is free to stand on")
	var reachable: Array = _grid.get_reachable_tiles(COVERED + Vector3i(0, 0, 3), 4)
	_check(COVERED in reachable, "and is reachable by an ordinary move")


func _check_degradation() -> void:
	var edge = _grid.cover_edge(COVERED, MapData.Side.SOUTH)
	var full: int = edge.hp
	_check(_grid.damage_cover_edge(COVERED, MapData.Side.SOUTH, 1) == MapData.Cover.HEAVY,
		"a scratch leaves heavy cover heavy")
	_check(edge.hp == full - 1, "and takes the HP off it")

	# Heavy does not vanish: it drops a tier. There is no tile left to turn into
	# impassable rubble the way the per-tile model did, and a wrecked crate is
	# still something to crouch behind.
	_check(_grid.damage_cover_edge(COVERED, MapData.Side.SOUTH, 999) == MapData.Cover.LIGHT,
		"destroying heavy cover degrades it to light")
	_check(edge.hp > 0, "and gives it the light tier's HP back (%d)" % edge.hp)
	_check(_defence(COVERED + Vector3i(0, 0, 4))[0] == MapData.Cover.LIGHT,
		"so the shooter to the south now faces light cover")

	_check(_grid.damage_cover_edge(COVERED, MapData.Side.SOUTH, 999) == MapData.Cover.NONE,
		"destroying light cover leaves nothing")
	_check(_defence(COVERED + Vector3i(0, 0, 4))[0] == MapData.Cover.NONE,
		"and the tile is exposed from the south")
	_check(_grid.is_free(COVERED), "the tile stays passable through all of that")


func _defence(shooter: Vector3i) -> Array:
	return _combat.defending_cover(shooter, COVERED)


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
