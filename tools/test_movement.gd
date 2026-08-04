extends SceneTree
## The eight-way movement grid: what counts as adjacent, what a diagonal costs,
## and the corner-cutting guard that decides which diagonals exist at all.
##
##   godot --headless --path . --script res://tools/test_movement.gd
##
## Built against a hand-made fixture rather than the real deck, unlike
## test_edge_cover.gd. The rules here are about the SHAPE of the local
## neighbourhood — a wall on one side of a corner but not the other — and
## hunting for a spot on the authored map that happens to have that shape would
## make every case a fact about maps/test_deck.txt instead of about the rule.
##
## Scripts are load()ed and the autoload is fetched from the tree rather than
## named, because grid_manager.gd references the GridManager autoload at COMPILE
## time and a --script tool is compiled before autoloads register.

## Half-width of the open floor the fixture lays down, so tiles from -PAD to PAD
## on both axes exist. Big enough that no case below is deciding anything at the
## edge of the world.
const PAD := 4

var _failures := 0
var _grid: Node


func _initialize() -> void:
	_grid = root.get_node_or_null("GridManager")
	if _grid == null:
		print("GridManager autoload missing")
		quit(1)
		return

	_check_adjacency()
	_check_diagonal_cost()
	_check_reachable_is_square()
	_check_corner_cutting()
	_check_occupants_do_not_block_corners()
	_check_path_is_straight()

	print("")
	if _failures == 0:
		print("movement: ALL CHECKS PASSED")
		quit(0)
	else:
		print("movement: %d CHECK(S) FAILED" % _failures)
		quit(1)


## Open floor, no walls, nobody standing anywhere. Every case starts here and
## adds only the obstruction it is about.
func _open_floor() -> void:
	_grid.clear()
	for x in range(-PAD, PAD + 1):
		for z in range(-PAD, PAD + 1):
			var pos := Vector3i(x, 0, z)
			_grid.add_tile(pos, Vector3(x, 0, z) * _grid.TILE_SIZE)


func _wall(pos: Vector3i) -> void:
	_grid.get_tile(pos).passable = false


func _check_adjacency() -> void:
	_open_floor()
	var here := Vector3i.ZERO
	var n: Array = _grid.neighbors(here)
	_check(n.size() == 8, "an open tile has 8 neighbours (got %d)" % n.size())
	_check(Vector3i(1, 0, 1) in n, "the diagonal +X+Z is a neighbour")
	# Melee reach is defined as this same adjacency, so a diagonal is contact
	# range — which is the rule that flipped back with eight-way movement.
	_check(_grid.is_melee_adjacent(here, Vector3i(1, 0, 1)),
		"a diagonally adjacent unit is in melee range")
	_check(not _grid.is_melee_adjacent(here, Vector3i(2, 0, 1)),
		"a knight's move away is NOT in melee range")


func _check_diagonal_cost() -> void:
	_open_floor()
	# Three diagonal steps, not six. This is the whole point of uniform cost: the
	# path length is max(dx, dz), so `max_tiles` stays a plain tile count and the
	# BFS stays a BFS.
	var path: Array = _grid.find_path(Vector3i.ZERO, Vector3i(3, 0, 3), 99)
	_check(path.size() == 3, "a pure diagonal of 3 costs 3 tiles (got %d)" % path.size())
	# And it is genuinely unreachable one tile short, rather than merely longer:
	# a budget cap that silently allowed the move would hide a cost bug.
	var capped: Array = _grid.find_path(Vector3i.ZERO, Vector3i(3, 0, 3), 2)
	_check(capped.is_empty(), "a 3-tile diagonal is out of reach on a 2-tile budget")
	# Mixed: 4 across and 2 down is 4 steps -- two diagonal, two straight.
	var mixed: Array = _grid.find_path(Vector3i.ZERO, Vector3i(4, 0, 2), 99)
	_check(mixed.size() == 4, "4 across and 2 down costs 4 tiles (got %d)" % mixed.size())


func _check_reachable_is_square() -> void:
	_open_floor()
	# N tiles reaches a SQUARE of side 2N+1, less the tile stood on. The diamond
	# that four-way movement reached is what `UnitStats.move_run` was scaled up
	# against, so this is the check that says the scaling can come back down.
	var reached: Array = _grid.get_reachable_tiles(Vector3i.ZERO, 2)
	_check(reached.size() == 24, "2 tiles reaches a 5x5 square minus self (got %d)"
		% reached.size())
	_check(Vector3i(2, 0, 2) in reached, "the far CORNER of that square is reachable")


func _check_corner_cutting() -> void:
	# One wall beside the corner: the diagonal is legal. This is the loose form
	# of the guard, and it is what makes eight-way movement feel like movement
	# rather than like a grid -- a unit rounds the end of a bulkhead in one step.
	_open_floor()
	_wall(Vector3i(1, 0, 0))
	_check(Vector3i(1, 0, 1) in _grid.neighbors(Vector3i.ZERO),
		"a diagonal past ONE wall is allowed")

	# Both walls: the diagonal passes through the point where they meet, which is
	# the case that reads on screen as walking through solid geometry.
	_open_floor()
	_wall(Vector3i(1, 0, 0))
	_wall(Vector3i(0, 0, 1))
	_check(not (Vector3i(1, 0, 1) in _grid.neighbors(Vector3i.ZERO)),
		"a diagonal between TWO walls is blocked")
	# The other three diagonals from the same tile are untouched -- the guard is
	# per-diagonal, not a tile-wide "this tile is awkward" flag.
	_check(Vector3i(-1, 0, -1) in _grid.neighbors(Vector3i.ZERO),
		"the opposite diagonal is unaffected")
	# And it holds through find_path, not just through neighbors: a pathfinder
	# that re-derived adjacency of its own would route straight through the gap.
	var path: Array = _grid.find_path(Vector3i.ZERO, Vector3i(1, 0, 1), 99)
	_check(path.size() > 1, "pathing around the blocked corner takes more than one step (got %d)"
		% path.size())


func _check_occupants_do_not_block_corners() -> void:
	# A squadmate is not a wall. Two units standing either side of a corner would
	# otherwise seal a diagonal that has no geometry in it at all, which in a
	# corridor firefight means the squad blocks its own retreat by standing
	# where it was told to.
	_open_floor()
	var body := Node3D.new()
	root.add_child(body)
	var other := Node3D.new()
	root.add_child(other)
	_grid.set_occupant(Vector3i(1, 0, 0), body)
	_grid.set_occupant(Vector3i(0, 0, 1), other)
	_check(Vector3i(1, 0, 1) in _grid.neighbors(Vector3i.ZERO),
		"two occupied tiles do not seal the diagonal between them")
	# The occupied tiles themselves are still not enterable -- `is_free`, not
	# `neighbors`, is what enforces that, and this check is here to show the two
	# have not been conflated.
	_check(not _grid.is_free(Vector3i(1, 0, 0)), "an occupied tile is still not free")
	var reached: Array = _grid.get_reachable_tiles(Vector3i.ZERO, 1)
	_check(not (Vector3i(1, 0, 0) in reached), "and is not offered as a destination")
	body.queue_free()
	other.queue_free()


func _check_path_is_straight() -> void:
	_open_floor()
	# 4 across and 2 down ties at 4 steps across many interleavings, and plain
	# BFS returns whichever it expanded first -- typically a zigzag alternating
	# diagonal and cardinal steps, which on screen is the sprite flipping
	# between two drawn poses on every tile. find_path's turn tiebreak has to
	# collapse those to ONE change of direction: diagonals first, then straight.
	var path: Array = _grid.find_path(Vector3i.ZERO, Vector3i(4, 0, 2), 99)
	var turns := 0
	var heading := Vector3i.ZERO
	var prev := Vector3i.ZERO
	for step: Vector3i in path:
		var dir: Vector3i = step - prev
		if heading != Vector3i.ZERO and dir != heading:
			turns += 1
		heading = dir
		prev = step
	_check(turns <= 1, "a 4x2 path changes direction at most once (got %d)" % turns)


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
