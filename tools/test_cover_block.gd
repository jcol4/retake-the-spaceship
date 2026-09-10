extends SceneTree
## Block cover (MapData.obstacles / GridManager.register_cover_block): a
## tile-occupying, destructible cover piece, as opposed to test_edge_cover.gd's
## boundary props. maps/cover_block_test.txt puts one 1x1 HEAVY block at
## (4,2), open floor on both the west (3,2) and east (5,2) sides, so damage
## can be driven in from either neighbour against the one shared HP pool.
##
##   godot --headless --path . --script res://tools/test_cover_block.gd
##
## Loads via test_map.tscn + build_layout(), same as test_edge_cover.gd and
## for the same reason: MapBuilder references the GridManager autoload
## throughout, and a --script tool compiles before autoloads register, so
## `map` stays untyped (dynamic dispatch) rather than a direct MapBuilder
## reference that would force eager resolution of that dependency.

const BLOCK := Vector3i(4, 0, 2)
const WEST := Vector3i(3, 0, 2)
const EAST := Vector3i(5, 0, 2)

var _failures := 0
var _grid: Node


func _initialize() -> void:
	_grid = root.get_node_or_null("GridManager")
	var map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(map)
	await process_frame
	map.build_layout("res://maps/cover_block_test.txt")
	await process_frame

	_check_blocks_movement()
	_check_shared_pool()
	_check_destruction()

	print("")
	if _failures == 0:
		print("cover block: ALL CHECKS PASSED")
		quit(0)
	else:
		print("cover block: %d CHECK(S) FAILED" % _failures)
		quit(1)


func _check_blocks_movement() -> void:
	_check(not _grid.has_tile(BLOCK), "the block's own tile is absent from GridManager (impassable)")
	_check(_grid.has_tile(WEST) and _grid.has_tile(EAST), "both flanking tiles are ordinary walkable tiles")


func _check_shared_pool() -> void:
	_check(_grid.cover_type_on(WEST, MapData.Side.EAST) == MapData.Cover.HEAVY,
		"the west neighbour sees HEAVY cover facing the block")
	_check(_grid.cover_type_on(EAST, MapData.Side.WEST) == MapData.Cover.HEAVY,
		"and so does the east neighbour, on its own opposite side")

	# Partial damage from the west: shared pool takes it, but 10 of 50 HP
	# leaves it intact and the tile still blocked either way.
	var after_partial: int = _grid.damage_cover_edge(WEST, MapData.Side.EAST, 10)
	_check(after_partial == MapData.Cover.HEAVY, "partial damage from one side doesn't destroy it")
	_check(_grid.cover_type_on(EAST, MapData.Side.WEST) == MapData.Cover.HEAVY,
		"and the OTHER side's cover reflects that same damage, not an independent pool")


func _check_destruction() -> void:
	# 10 already spent above; the rest of HEAVY_HP (50) finishes it from the
	# other side, proving damage from either side accumulates on one pool.
	var after_lethal: int = _grid.damage_cover_edge(EAST, MapData.Side.WEST, CoverEdge.HEAVY_HP - 10)
	_check(after_lethal == MapData.Cover.NONE, "the shared pool empties and the block is destroyed")
	_check(_grid.has_tile(BLOCK), "destroying it reopens the tile to movement")
	_check(_grid.is_free(BLOCK), "and the reopened tile is actually walkable, not just present")
	_check(_grid.cover_type_on(WEST, MapData.Side.EAST) == MapData.Cover.NONE,
		"the west neighbour's accuracy bonus is gone")
	_check(_grid.cover_type_on(EAST, MapData.Side.WEST) == MapData.Cover.NONE,
		"so is the east neighbour's")

	var after_destroyed: int = _grid.damage_cover_edge(WEST, MapData.Side.EAST, 999)
	_check(after_destroyed == MapData.Cover.NONE, "a shot at an already-destroyed block is a no-op, not an error")


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
