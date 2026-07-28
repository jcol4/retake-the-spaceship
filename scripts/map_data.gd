class_name MapData
extends RefCounted
## Engine-free description of a deck: what is on each tile, and nothing about
## how it is drawn. Generators produce one of these, MapBuilder turns it into
## nodes, and validators measure it — none of which needs a running scene tree,
## so generation can be fuzzed headlessly in milliseconds (Sec 10.4).
##
## Cell key is Vector3i(x, deck, z), matching GridManager's tile key so no
## translation layer is needed. Everything today lives on deck 0; multi-deck
## ships just add cells at other deck indices.
##
## Terrain and the feature fields are deliberately independent: a generator
## wants to place a light in a room that also holds cover, which the ASCII
## legend (one glyph per tile) cannot express. See MapAscii for that limit.

enum Terrain {
	VOID,      # outside the hull — nothing built, not walkable
	FLOOR,     # plain walkable deck plating
	WALL,      # full-height bulkhead, blocks movement and LOS
	PLATFORM,  # solid block; its *top* is the walkable tile, one deck up
}
enum Cover { NONE, LIGHT, HEAVY }
enum Fixture { NONE, OVERHEAD, MONITOR, FLICKER }
enum Spawn { NONE, PLAYER, ENEMY, SWARM }

const DECK_OFFSET := Vector3i(0, 1, 0)


class Cell:
	var terrain: int = Terrain.VOID
	var cover: int = Cover.NONE
	var fixture: int = Fixture.NONE
	var spawn: int = Spawn.NONE
	var stair: bool = false  # links to the platform tile directly north (-z)

	func duplicate_cell() -> Cell:
		var c := Cell.new()
		c.terrain = terrain
		c.cover = cover
		c.fixture = fixture
		c.spawn = spawn
		c.stair = stair
		return c


var size := Vector2i.ZERO  # width (x) by depth (z), in tiles
var seed: int = 0  # 0 for hand-authored maps
var cells: Dictionary = {}  # Vector3i -> Cell
var stair_links: Array = []  # [[Vector3i, Vector3i], ...], filled by resolve_stairs()

# Compartment graph, filled by MapGenerator and empty for hand-authored decks.
# Rooms are interior rects in cell space (the bulkheads between them are not
# part of either). Alert propagation (Sec 11.2) wants this same graph.
var rooms: Array[Rect2i] = []
var room_links: Array = []  # [a, b] index pairs into `rooms`
var corridors: Array[int] = []  # indices into `rooms` that are through-routes


func set_cell(pos: Vector3i, cell: Cell) -> void:
	cells[pos] = cell
	size.x = maxi(size.x, pos.x + 1)
	size.y = maxi(size.y, pos.z + 1)


func get_cell(pos: Vector3i) -> Cell:
	return cells.get(pos)


func has_cell(pos: Vector3i) -> bool:
	return cells.has(pos)


func terrain_at(pos: Vector3i) -> int:
	var c: Cell = cells.get(pos)
	return c.terrain if c else Terrain.VOID


func walkable_pos(pos: Vector3i) -> Vector3i:
	# Where a unit actually stands for the cell authored at `pos`. A platform is
	# a solid block whose top surface is the tile, one deck above the block.
	return pos + DECK_OFFSET if terrain_at(pos) == Terrain.PLATFORM else pos


func is_walkable(pos: Vector3i) -> bool:
	# Cover tiles count: they get a grid tile, and CoverObject marks it
	# impassable at build time (Sec 6.1). Passability is the grid's business.
	return terrain_at(pos) in [Terrain.FLOOR, Terrain.PLATFORM]


func walkable_positions() -> Array[Vector3i]:
	# Grid keys, not cell keys — platform tops appear at their raised deck.
	var out: Array[Vector3i] = []
	for pos: Vector3i in cells:
		if is_walkable(pos):
			out.append(walkable_pos(pos))
	return out


func spawns(kind: int) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for pos: Vector3i in cells:
		if cells[pos].spawn == kind:
			out.append(walkable_pos(pos))
	out.sort()  # stable order regardless of dictionary iteration
	return out


func resolve_stairs() -> void:
	# A stair tile links to the platform top directly north (-z) of it. Kept out
	# of set_cell because a generator places stairs and platforms in either
	# order; call once the layout is final.
	stair_links.clear()
	for pos: Vector3i in cells:
		if not cells[pos].stair:
			continue
		var north := pos + Vector3i(0, 0, -1)
		if terrain_at(north) == Terrain.PLATFORM:
			stair_links.append([pos, walkable_pos(north)])
