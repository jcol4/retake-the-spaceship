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

## Which boundary of a tile an edge is. Cover lives on these rather than on the
## tile itself (see `cover_edges`), so a unit stands ON a tile and is protected
## from the directions whose boundary carries something to hide behind.
enum Side { EAST, SOUTH, WEST, NORTH }

## Indexed by Side. East is +x and south is +z, matching the grid's own axes.
const SIDE_STEP: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(0, 0, 1), Vector3i(-1, 0, 0), Vector3i(0, 0, -1),
]

const DECK_OFFSET := Vector3i(0, 1, 0)


class Cell:
	# No `cover` field: cover is a property of a tile BOUNDARY, not of a tile.
	# See `cover_edges` and Side.
	var terrain: int = Terrain.VOID
	var fixture: int = Fixture.NONE
	var spawn: int = Spawn.NONE
	var stair: bool = false  # links to the platform tile directly north (-z)

	func duplicate_cell() -> Cell:
		var c := Cell.new()
		c.terrain = terrain
		c.fixture = fixture
		c.spawn = spawn
		c.stair = stair
		return c


var size := Vector2i.ZERO  # width (x) by depth (z), in tiles
var seed: int = 0  # 0 for hand-authored maps
var cells: Dictionary = {}  # Vector3i -> Cell
var stair_links: Array = []  # [[Vector3i, Vector3i], ...], filled by resolve_stairs()

## Edge cover, keyed by `edge_key`. An edge is shared by two tiles, so it is
## stored ONCE against a canonical side (EAST or SOUTH) and both tiles resolve to
## the same entry — which is what stops a crate having two independent HP pools.
var cover_edges: Dictionary = {}  # Vector4i -> Cover

# Compartment graph. MapGenerator fills this from its own BSP rects; for
# hand-authored decks `compute_rooms` derives it from the layout. Alert
# propagation (Sec 11.2) and sprite render gating both read it.
#
# Regions are stored as their BOUNDING rects, which is exact for a BSP
# compartment and merely indicative for a flood-filled one — `room_of` is the
# authority on membership, and every consumer should use `room_index_at`.
var rooms: Array[Rect2i] = []
var room_links: Array = []  # [a, b] index pairs into `rooms`
var corridors: Array[int] = []  # indices into `rooms` that are through-routes
var room_of: Dictionary = {}  # Vector3i cell pos -> index into `rooms`


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
	# Cover no longer subtracts from this. Under the edge-cover model a unit
	# stands ON the tile a crate is bolted to the side of, so a covered tile is
	# an ordinary floor tile in every respect the grid cares about.
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


# --- Edge cover -------------------------------------------------------------
#
# Every edge has two names — the EAST side of one tile is the WEST side of its
# neighbour — so one of the two is picked as canonical and everything is stored
# and compared there. EAST and SOUTH are canonical purely because they are the
# positive-axis pair; nothing else about the choice matters.


## The canonical [pos, side] naming of the edge `side` of `pos`.
static func canonical_edge(pos: Vector3i, side: int) -> Array:
	if side == Side.WEST or side == Side.NORTH:
		return [pos + SIDE_STEP[side], Side.EAST if side == Side.WEST else Side.SOUTH]
	return [pos, side]


## Dictionary key for an edge. Packed into a Vector4i so edges are cheap to hash
## and compare, and so the key carries its own deck index like every other key
## in this file.
static func edge_key(pos: Vector3i, side: int) -> Vector4i:
	var c := canonical_edge(pos, side)
	var p: Vector3i = c[0]
	return Vector4i(p.x, p.y, p.z, c[1])


func set_cover_edge(pos: Vector3i, side: int, cover: int) -> void:
	var key := edge_key(pos, side)
	if cover == Cover.NONE:
		cover_edges.erase(key)
	else:
		cover_edges[key] = cover


func cover_edge(pos: Vector3i, side: int) -> int:
	return cover_edges.get(edge_key(pos, side), Cover.NONE)


## Every side of `pos` that carries cover, as Side values. The order is the Side
## enum's own, so it is stable regardless of dictionary iteration.
func covered_sides(pos: Vector3i) -> Array[int]:
	var out: Array[int] = []
	for side in [Side.EAST, Side.SOUTH, Side.WEST, Side.NORTH]:
		if cover_edge(pos, side) != Cover.NONE:
			out.append(side)
	return out


## Edges as [pos, side, cover] triples in a stable (z, x, side) order, so the
## text encoder and any test reading them agree run to run.
func cover_edge_list() -> Array:
	var keys: Array = cover_edges.keys()
	keys.sort_custom(func(a: Vector4i, b: Vector4i) -> bool:
		if a.z != b.z:
			return a.z < b.z
		if a.x != b.x:
			return a.x < b.x
		return a.w < b.w)
	var out: Array = []
	for k: Vector4i in keys:
		out.append([Vector3i(k.x, k.y, k.z), k.w, cover_edges[k]])
	return out


# --- Compartment graph ------------------------------------------------------


## Derives rooms, corridors and links from the layout itself, for decks that did
## not come from MapGenerator (which fills the same fields from its BSP rects).
## Idempotent, and a no-op if `rooms` is already populated.
##
## The rule is the one a ship deck is actually built to: compartments are
## separated by full-width BULKHEADS, and a bulkhead with a hole in it is a
## doorway. So rather than flood-filling walkable space — which on any deck with
## a doorway merges every compartment into one region — this first finds the
## bulkhead lines, then floods between them.
##
## Walkable cells that sit ON a bulkhead line are the doorways. They flood into
## regions of their own and become `corridors`, linked to every region they
## touch. That falls out the same way for a one-tile doorway and for a spine
## corridor running the length of the hull, which is why it is worth doing this
## way rather than special-casing doorways.
func compute_rooms() -> void:
	if not rooms.is_empty():
		return
	rooms.clear()
	room_links.clear()
	corridors.clear()
	room_of.clear()
	var passage := _bulkhead_cells()
	# Rooms first so their indices are the low ones, then corridors — matching
	# MapGenerator's convention of putting structure before through-routes.
	_flood_regions(func(pos: Vector3i) -> bool: return is_walkable(pos) and not passage.has(pos))
	var first_corridor := rooms.size()
	_flood_regions(func(pos: Vector3i) -> bool: return passage.has(pos))
	for i in range(first_corridor, rooms.size()):
		corridors.append(i)
	_link_regions()


## Fraction of a row's or column's built cells that must be WALL for the line to
## count as a bulkhead. Well below 1.0 because a bulkhead with a doorway in it is
## still a bulkhead — that is the entire point — and well above 0.5 so a room
## whose far edge happens to line up with a wall is not mistaken for one.
const BULKHEAD_RATIO := 0.6
const BULKHEAD_MIN_WALLS := 2


func _bulkhead_cells() -> Dictionary:
	var out: Dictionary = {}
	var decks: Dictionary = {}
	for pos: Vector3i in cells:
		decks[pos.y] = true
	for deck: int in decks:
		var cols := _bulkhead_lines(deck, true)
		var rows := _bulkhead_lines(deck, false)
		for pos: Vector3i in cells:
			if pos.y != deck or not is_walkable(pos):
				continue
			if cols.has(pos.x) or rows.has(pos.z):
				out[pos] = true
	return out


func _bulkhead_lines(deck: int, vertical: bool) -> Dictionary:
	var walls: Dictionary = {}
	var built: Dictionary = {}
	for pos: Vector3i in cells:
		if pos.y != deck:
			continue
		var t := terrain_at(pos)
		if t == Terrain.VOID:
			continue  # outside the hull; says nothing about the line
		var line: int = pos.x if vertical else pos.z
		built[line] = built.get(line, 0) + 1
		if t == Terrain.WALL:
			walls[line] = walls.get(line, 0) + 1
	var out: Dictionary = {}
	for line: int in walls:
		var w: int = walls[line]
		if w >= BULKHEAD_MIN_WALLS and float(w) / float(built[line]) >= BULKHEAD_RATIO:
			out[line] = true
	return out


func _flood_regions(accepts: Callable) -> void:
	# Four-way, deliberately: an eight-way flood leaks diagonally through the
	# corner where two bulkheads meet and merges compartments that share only
	# that point.
	var ordered: Array[Vector3i] = []
	for pos: Vector3i in cells:
		ordered.append(pos)
	ordered.sort()  # region indices stable regardless of dictionary iteration
	for start: Vector3i in ordered:
		if room_of.has(start) or not accepts.call(start):
			continue
		var index := rooms.size()
		var lo := Vector2i(start.x, start.z)
		var hi := lo
		var frontier: Array[Vector3i] = [start]
		room_of[start] = index
		while not frontier.is_empty():
			var cur: Vector3i = frontier.pop_back()
			lo = Vector2i(mini(lo.x, cur.x), mini(lo.y, cur.z))
			hi = Vector2i(maxi(hi.x, cur.x), maxi(hi.y, cur.z))
			for side in [Side.EAST, Side.SOUTH, Side.WEST, Side.NORTH]:
				var n: Vector3i = cur + SIDE_STEP[side]
				if room_of.has(n) or not accepts.call(n):
					continue
				room_of[n] = index
				frontier.append(n)
		rooms.append(Rect2i(lo, hi - lo + Vector2i.ONE))


func _link_regions() -> void:
	var seen: Dictionary = {}
	for pos: Vector3i in room_of:
		var a: int = room_of[pos]
		for side in [Side.EAST, Side.SOUTH]:  # each pair visited once
			var n: Vector3i = pos + SIDE_STEP[side]
			var b: int = room_of.get(n, -1)
			if b < 0 or b == a:
				continue
			var pair := Vector2i(mini(a, b), maxi(a, b))
			if seen.has(pair):
				continue
			seen[pair] = true
			room_links.append([pair.x, pair.y])
	room_links.sort_custom(func(l: Array, r: Array) -> bool:
		return l[0] < r[0] if l[0] != r[0] else l[1] < r[1])


## Which region a GRID position belongs to, or -1. Takes grid keys rather than
## cell keys, so a unit standing on a platform top resolves to the region the
## platform's base cell is in — the two differ by DECK_OFFSET and only this
## function should have to know that.
func room_index_at(grid_pos: Vector3i) -> int:
	if room_of.has(grid_pos):
		return room_of[grid_pos]
	return room_of.get(grid_pos - DECK_OFFSET, -1)


## Regions reachable from `index` in one step, plus `index` itself.
func linked_rooms(index: int) -> Array[int]:
	var out: Array[int] = []
	if index < 0:
		return out
	out.append(index)
	for link: Array in room_links:
		if link[0] == index:
			out.append(link[1])
		elif link[1] == index:
			out.append(link[0])
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
