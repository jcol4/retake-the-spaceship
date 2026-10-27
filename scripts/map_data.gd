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
	DOOR,      # walkable gap in a bulkhead line — a plain opening, no module
	OBSTACLE,  # multi-tile furniture footprint — blocks movement, not LOS. See `obstacles`.
}
enum Cover { NONE, LIGHT, HEAVY }
## The first three are light sources; ALARM is not — it emits no light and is
## grouped here only because it is, like them, a thing bolted to a tile rather
## than a property of the tile itself. See MapBuilder._build_cell, which routes
## it away from `_add_light`.
enum Fixture { NONE, OVERHEAD, MONITOR, FLICKER, ALARM }
## Spawn markers. The four Cerberus entries are per-TYPE rather than one shared
## ROBOT kind, unlike the aliens' ENEMY/SWARM split: a security roster is placed
## deliberately — this doorway gets a sentry, that hall gets the heavy — where an
## infestation is placed in bulk. Encoding the type in the map is what lets a
## level author express that at all.
enum Spawn {
	NONE, PLAYER, ENEMY, SWARM, BRAWLER,
	AUXILIUM, SAGITTARII, PROCTOR, SECURUS, LICTOR,
	MERC, HUNTER, WORM,
	# Not a unit type like the rest of this list — a destructible objective
	# (Sec 11.7) that is merely PLACED the same way. Kept in `Spawn` rather
	# than given its own field because the map format's whole contract is one
	# glyph per tile, and a nest occupies a tile exactly as a unit does.
	NEST,
}

## The Cerberus half of `Spawn`, in roster order. Iterated by MapBuilder and by
## the spawner in main.gd so adding a fifth robot is one entry here plus a glyph.
const CERBERUS_SPAWNS: Array[int] = [
	Spawn.AUXILIUM, Spawn.SAGITTARII, Spawn.PROCTOR, Spawn.SECURUS, Spawn.LICTOR,
]

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
## Which of MapGenerator's rerolls produced this deck (0 = the seed itself). See
## MapGenerator.generate. Always 0 for a hand-authored deck.
var generation_attempt: int = 0
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

## Multi-tile furniture, e.g. a 3x1 table: `[Rect2i footprint, int cover_tier]`
## entries. The footprint's cells are Terrain.OBSTACLE (not walkable — see
## `is_walkable`); MapBuilder reads the whole rect here, not just per-cell
## membership, because it builds one mesh spanning the piece and needs its
## bounds and orientation, not just "which cells are blocked". The perimeter
## cover this implies is stored as ordinary `cover_edges` like any other
## crate — there is no separate cover concept for furniture.
var obstacles: Array = []

## Wrecked ships and heavy hangar machinery (GDD §7.2): `Rect2i` footprints, cells
## Terrain.OBSTACLE like a cover block, but FULL HEIGHT and indestructible — they
## block movement, line of sight AND light like a bulkhead, and give heavy cover
## to whoever stands against them. The big set dressing that turns a hangar bay
## into terrain worth fighting over. MapBuilder builds them (layer 1, like a
## wall); MapAscii carries them as `[wrecks]`.
var wrecks: Array = []

## How many worms stand on a `Spawn.WORM` tile: `Vector3i -> int`.
##
## A worm mass is not a second unit type — it is one `WormUnit` carrying more HP
## (see docs/design/factions/aliens/design-choices/worm-mass.md) — so a map
## cannot express one with a glyph the way it expresses a Brawler. What it needs
## to name is a NUMBER attached to a tile that already has a worm on it, which is
## the same shape of problem `[cover]` and `[obstacles]` exist for: a detail the
## one-glyph-per-tile grid has no room to carry.
##
## ABSENT MEANS ONE. Every existing deck therefore reads exactly as it did, and
## `MapAscii.encode_worms` writes nothing for a count of 1, so a deck that never
## had a `[worms]` section does not grow one on the way out.
var worm_counts: Dictionary = {}


# --- Hangars (GDD §7.2) -------------------------------------------------------
#
# A hangar is a set-piece ROOM, not a tile feature: an open bay, a landing pad,
# and a fixed 3x3 extraction square in front of where the ramp comes down. All of
# that geometry is derived from two authored facts — where the pad's centre is,
# and which way the ramp faces — so a hand-authored deck names only those (see
# MapAscii's `[hangars]`) and the generator makes the same two choices. The bay
# is whatever compartment the pad sits in, read off `room_of`, so it can never
# disagree with the room graph that discovery (ExtractionManager) is keyed on.

## Half-width of the landing pad, in tiles: the pad is (2r+1)^2 centred on
## `pad_center`, i.e. 5x5 — the space RESERVED for the ship (Dropship.HULL_SIZE
## is derived from it). Sized for the real dropship model rather than the box
## placeholder, so the ship asset can grow into it without moving a single
## hangar: 5 tiles = 7.5 m a side. While a ship is down the pad blocks movement,
## line of sight and light (ExtractionManager._block_pad, Dropship collision).
## Change it here and every hangar, the bay sizing (`hangar_landing_zone`), the
## door-gun corner and the hull follow.
const HANGAR_PAD_RADIUS := 2
## Half-width of the extraction square: 3x3 per GDD §7.2.
const HANGAR_SQUARE_RADIUS := 1
## Pad centre to square centre, along the ramp side. Pad radius + square radius
## + 1, so the square's first row sits directly against the pad's ramp edge —
## the tiles the ramp actually comes down onto — with no gap a soldier could
## mistake for "in front of the ship".
const HANGAR_SQUARE_OFFSET := HANGAR_PAD_RADIUS + HANGAR_SQUARE_RADIUS + 1
## Tiles of clear floor kept round the pad + square when the bay is SIZED (not
## when cover is placed — that keeps its own one-tile walkway): the landing
## zone a bay is measured against is the ship and the square grown by this.
const HANGAR_LZ_APRON := 1
## A generated bay is this many times the landing zone's area (GDD §7.2:
## "3–4x the size of the hangar" — the ship's space plus the square). The rest
## is the room the squad fights in while the ship comes in: cover, wrecks,
## approaches.
const HANGAR_BAY_AREA_MIN := 3.0
const HANGAR_BAY_AREA_MAX := 4.0


class Hangar:
	## Index into MapData.rooms of the bay this hangar's pad sits in.
	var room_index: int = -1
	## Every walkable GRID position of the bay, sorted. "Anywhere in the bay" is
	## where a call-in may be made from (GDD §7.3).
	var bay_cells: Array[Vector3i] = []
	## The 3x3 extraction square in front of the ramp, as grid positions. Who is
	## standing here when the ship leaves is who extracts (GDD §7.4).
	var square: Array[Vector3i] = []
	var pad_center := Vector3i.ZERO
	## Which way the ramp faces, as a MapData.Side: the square lies on this side
	## of the pad.
	var ramp_side: int = Side.SOUTH
	## The hangar the squad inserts at. Starts discovered (GDD §7.2), and the
	## generator keeps it free of enemy spawns.
	var is_insertion: bool = false

	func in_bay(grid_pos: Vector3i) -> bool:
		return bay_cells.has(grid_pos)

	func in_square(grid_pos: Vector3i) -> bool:
		return square.has(grid_pos)


var hangars: Array[Hangar] = []


# --- Loot containers (GDD §7.5, extraction plan 3.2) --------------------------
#
# A crate or locker standing on one tile, with what is in it. The tile keeps its
# own terrain (FLOOR) so the room graph, bays and every existing walkability
# reader are unchanged; the container makes it impassable on top of that — at
# build time (LootManager.build_from) and, engine-free, through `is_passable`,
# which is what anything asking "can a unit walk here" of a MapData must use.
# No glyph: contents are a list, and the one-glyph grid cannot carry one, so it is
# MapAscii's `[loot]` section, like `[hangars]`.


class LootSpot:
	var pos := Vector3i.ZERO
	## ItemPresets codes, in panel order.
	var items := PackedStringArray()


var containers: Array[LootSpot] = []


func add_container(pos: Vector3i, items: PackedStringArray = PackedStringArray()) -> LootSpot:
	var spot := LootSpot.new()
	spot.pos = pos
	spot.items = items
	containers.append(spot)
	return spot


func container_at(pos: Vector3i) -> LootSpot:
	for spot in containers:
		if spot.pos == pos:
			return spot
	return null


func has_container(pos: Vector3i) -> bool:
	return container_at(pos) != null


## Walkable AND not under a container: whether a unit can actually stand here.
## `is_walkable` stays the terrain question (a crate does not change what the
## floor IS), so the room graph and hangar bays are built the same with or
## without loot on the deck.
func is_passable(pos: Vector3i) -> bool:
	return is_walkable(pos) and not has_container(pos)


## Builds a Hangar from its two authored facts and appends it. The bay and the
## square are derived, so this must run AFTER the room graph exists
## (`compute_rooms` for a text deck, the generator's own `room_of` for a
## generated one) — which is why neither MapAscii nor MapGenerator writes the
## derived fields itself.
func add_hangar(pad_center: Vector3i, ramp_side: int, is_insertion: bool) -> Hangar:
	var h := Hangar.new()
	h.pad_center = pad_center
	h.ramp_side = ramp_side
	h.is_insertion = is_insertion
	h.room_index = room_index_at(pad_center)
	h.square = hangar_square_cells(pad_center, ramp_side)
	if h.room_index >= 0:
		for pos: Vector3i in room_of:
			if room_of[pos] == h.room_index and is_walkable(pos):
				h.bay_cells.append(walkable_pos(pos))
		h.bay_cells.sort()
	hangars.append(h)
	return h


## The 3x3 square for a pad at `pad_center` with its ramp facing `ramp_side`.
## Static so the generator can test a candidate placement before committing it.
static func hangar_square_cells(pad_center: Vector3i, ramp_side: int) -> Array[Vector3i]:
	var centre := pad_center + SIDE_STEP[ramp_side] * HANGAR_SQUARE_OFFSET
	return _block(centre, HANGAR_SQUARE_RADIUS)


static func hangar_pad_cells(pad_center: Vector3i) -> Array[Vector3i]:
	return _block(pad_center, HANGAR_PAD_RADIUS)


## The pad and the square together as one (x, z) rect: everything the ship and
## the boarding squad need, which no cover, wreck, crate or spawn may touch.
static func hangar_reserved_rect(pad_center: Vector3i, ramp_side: int) -> Rect2i:
	var cells := hangar_pad_cells(pad_center)
	cells.append_array(hangar_square_cells(pad_center, ramp_side))
	var rect := Rect2i(cells[0].x, cells[0].z, 1, 1)
	for c: Vector3i in cells:
		rect = rect.expand(Vector2i(c.x, c.z)).expand(Vector2i(c.x + 1, c.z + 1))
	return rect


## The landing zone a bay is sized against: the reserved rect grown by
## HANGAR_LZ_APRON on every side. Only its AREA matters to the generator, so
## where it sits is irrelevant; (0,0) pad facing south is as good as any.
static func hangar_landing_zone_area() -> int:
	var rect := hangar_reserved_rect(Vector3i.ZERO, Side.SOUTH).grow(HANGAR_LZ_APRON)
	return rect.size.x * rect.size.y


## Why hangar `h` is not a usable extraction point on this deck, or "". Every
## tile of the pad and the square must be open floor in the bay — no wall, no
## cover block, no wreck, no crate — so there is always somewhere for the ship
## to set down and nine tiles to board from. Generated decks are built to pass
## (tools/test_hangar_gen.gd fuzzes it); hand-authored ones are checked by
## MapAscii on load.
func hangar_problem(h: Hangar) -> String:
	for pos in hangar_pad_cells(h.pad_center):
		if not is_passable(pos) or room_index_at(pos) != h.room_index:
			return "pad tile %s is blocked or outside the bay" % pos
	for pos in h.square:
		if not is_passable(pos) or room_index_at(pos) != h.room_index:
			return "square tile %s is blocked or outside the bay" % pos
	return ""


## The tile a landed ship's door gun stands on (extraction plan Phase 5): the
## pad's ramp-side corner on the ship's own right hand, which is the cell
## directly under `Dropship.door_gun_mount` (the mount sits on that corner of the
## hull roof; tools/test_door_gun.gd checks the two agree).
##
## ON the pad on purpose. The pad is impassable while the ship is down
## (ExtractionManager._block_pad), so the gunner takes no tile anybody could have
## walked on — in particular none of the square's nine, which the squad needs
## every one of — and it is still movement-adjacent to the square's corner, so a
## clawing alien can reach it from the square like it reaches anything else (an
## occupied goal may be pathed TO, GridManager._path_open). Static and
## engine-free, so both co-op peers derive the same tile from their own MapData.
##
## "Right" of the ramp direction (x, z) is (z, -x): the Dropship is built facing
## local +Z and turned by atan2(x, z), which carries local +X onto exactly that.
static func hangar_gun_cell(pad_center: Vector3i, ramp_side: int) -> Vector3i:
	var step: Vector3i = SIDE_STEP[ramp_side]
	var right := Vector3i(step.z, 0, -step.x)
	return pad_center + step * HANGAR_PAD_RADIUS + right * HANGAR_PAD_RADIUS


static func _block(centre: Vector3i, radius: int) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			out.append(centre + Vector3i(dx, 0, dz))
	return out


## The hangar whose bay contains `grid_pos`, or -1.
func hangar_index_at(grid_pos: Vector3i) -> int:
	var room := room_index_at(grid_pos)
	if room < 0:
		return -1
	for i in hangars.size():
		if hangars[i].room_index == room:
			return i
	return -1


func insertion_hangar() -> Hangar:
	for h in hangars:
		if h.is_insertion:
			return h
	return null


## Worms standing on `pos`. The single place the "absent means one" rule is
## spelled out, so no caller has to remember it.
func worms_at(pos: Vector3i) -> int:
	return maxi(1, worm_counts.get(pos, 1))


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
	return terrain_at(pos) in [Terrain.FLOOR, Terrain.PLATFORM, Terrain.DOOR]


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
