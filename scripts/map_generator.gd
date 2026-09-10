class_name MapGenerator
extends RefCounted
## Deck generator: hull, room-first placement, corridor carving, entrances,
## and a cover pass (tile-occupying blocks, 1x1 up to 3x2 — see
## `_place_cover`; boundary edge-cover stays a hand-authored-map-only feature).
##
## Room-first rather than BSP: rooms are independently-sized rects placed by
## rejection sampling, which is what lets sizes actually vary (a tiny closet
## next to a big chamber) — a BSP split always divides a parent exactly in
## two, which caps how different two neighbouring compartments can ever be.
## Corridors are carved afterward to connect the scattered rooms and are
## appended to the same `_rooms` list as their own entries (exactly how the
## previous BSP version treated its one spine corridor as `_rooms[0]`), so
## MapData.rooms/room_of/corridors keep meaning the same thing they always
## did to every downstream consumer (occlusion, zones, alert propagation).
##
## Everything here is deterministic in `map_seed` and touches no scene tree,
## so a few hundred decks can be generated and checked per second.

class Config:
	var width := 60
	var depth := 40
	# Per-axis room size band, sampled independently per room — a wide band is
	# what gives the Dead-Space mix of tiny closets and big chambers, rather
	# than one room "type" uniformly scaled.
	var room_min := 3
	var room_max := 16
	var room_attempts := 600  # rejection-sampling budget, not a target count
	# Minimum tiles between any two rooms' interiors. Deliberately >= 2: with a
	# 1-tile gap reserved exclusively for corridor junctions (see
	# _carve_corridor), no two ordinary rooms can ever end up exactly one tile
	# apart by chance and be mistaken for a deliberate corridor junction.
	var room_gap := 2
	var corridor_width := 2  # hallways are >= 2 tiles wide per the design brief
	var entrance_width := 2  # width of the opening punched where a corridor meets a room
	var extra_link_ratio := 0.2  # corridors added back on top of the spanning tree, for loops

	# Cover placement — every piece is a tile-occupying block; see _place_cover.
	var cover_heavy_chance := 0.3  # chance any given block rolls HEAVY rather than LIGHT, independent of its size
	var cover_area_per_piece := 18  # ~one cover block per this many room tiles
	var cover_max_per_room := 5  # hard cap regardless of area, so a cargo bay doesn't fill up wall to wall

	# Spawns (minimal — enough for a playable demo, not full mission scripting).
	var player_spawn_count := 4
	var enemy_room_chance := 0.6  # per non-spawn room, chance it gets an enemy


var _cfg: Config
var _rng := RandomNumberGenerator.new()
var _rooms: Array[Rect2i] = []
var _room_is_corridor: Array[bool] = []  # parallel to _rooms
var _links: Array = []  # [a, b] index pairs into _rooms, for stats only


static func generate(map_seed: int, cfg: Config = null) -> MapData:
	var gen := MapGenerator.new()
	gen._cfg = cfg if cfg != null else Config.new()
	gen._rng.seed = map_seed
	return gen._run(map_seed)


func _run(map_seed: int) -> MapData:
	var data := MapData.new()
	data.seed = map_seed
	_fill_hull(data)
	_place_rooms()
	for i in _rooms.size():
		_carve(data, _rooms[i], i)
	_route_corridors(data)
	data.rooms = _rooms.duplicate()
	data.room_links = _links.duplicate()
	for i in _rooms.size():
		if _room_is_corridor[i]:
			data.corridors.append(i)
	_place_spawns(data)
	_place_cover(data)
	data.resolve_stairs()
	return data


func _fill_hull(data: MapData) -> void:
	# Start solid and carve out of it: anything never carved is hull structure,
	# so a bug leaves a compartment sealed rather than open to space.
	for z in _cfg.depth:
		for x in _cfg.width:
			var cell := MapData.Cell.new()
			cell.terrain = MapData.Terrain.WALL
			data.set_cell(Vector3i(x, 0, z), cell)


# --- Room placement ----------------------------------------------------------


func _place_rooms() -> void:
	_rooms.clear()
	_room_is_corridor.clear()
	var interior := Rect2i(1, 1, _cfg.width - 2, _cfg.depth - 2)
	for _i in _cfg.room_attempts:
		var w := _rng.randi_range(_cfg.room_min, _cfg.room_max)
		var h := _rng.randi_range(_cfg.room_min, _cfg.room_max)
		if w > interior.size.x or h > interior.size.y:
			continue
		var x := _rng.randi_range(interior.position.x, interior.position.x + interior.size.x - w)
		var z := _rng.randi_range(interior.position.y, interior.position.y + interior.size.y - h)
		var candidate := Rect2i(x, z, w, h)
		if _overlaps_any(candidate, _cfg.room_gap):
			continue
		_rooms.append(candidate)
		_room_is_corridor.append(false)


## Whether `rect` comes within `gap` tiles of any already-placed room —
## checked by growing `rect` and testing ordinary intersection, so a `gap` of
## zero means "may touch" and a `gap` of N means "N empty tiles clear on
## every side".
func _overlaps_any(rect: Rect2i, gap: int) -> bool:
	var grown := rect.grow(gap)
	for room in _rooms:
		if grown.intersects(room):
			return true
	return false


func _carve(data: MapData, room: Rect2i, room_index: int) -> void:
	for z in range(room.position.y, room.position.y + room.size.y):
		for x in range(room.position.x, room.position.x + room.size.x):
			var pos := Vector3i(x, 0, z)
			data.get_cell(pos).terrain = MapData.Terrain.FLOOR
			data.room_of[pos] = room_index


# --- Corridor routing ---------------------------------------------------------


## Connects the scattered rooms with carved corridors: a Euclidean minimum
## spanning tree over room centres (so the backbone favours short links, not
## whatever a shuffle happens to try first — see MST note below), plus a
## share of the shortest rejected edges added back for loops, matching the
## previous version's spanning-tree-plus-loops shape but driven by distance
## instead of shared-wall adjacency (rooms here are rarely adjacent at all).
func _route_corridors(data: MapData) -> void:
	_links.clear()
	if _rooms.size() < 2:
		return
	var real_room_count := _rooms.size()  # corridors appended below must not link to each other
	var candidates := _pairs_by_distance(real_room_count)
	var parent := range(real_room_count)
	var spare: Array = []
	var tree: Array = []
	for pair: Array in candidates:
		var ra := _find(parent, pair[0])
		var rb := _find(parent, pair[1])
		if ra == rb:
			spare.append(pair)
			continue
		parent[ra] = rb
		tree.append(pair)
	var extra := int(round(tree.size() * _cfg.extra_link_ratio))
	var chosen: Array = tree.duplicate()
	for i in mini(extra, spare.size()):
		chosen.append(spare[i])
	for pair: Array in chosen:
		_links.append(pair)
		_carve_corridor(data, pair[0], pair[1])


## All (i, j) room pairs, nearest-centre-distance first — Kruskal's algorithm
## over this order is exactly a Euclidean MST, which is what keeps the
## backbone reading as "nearby compartments linked by a short hall" rather
## than corridors crossing the whole deck for no reason.
func _pairs_by_distance(count: int) -> Array:
	var pairs: Array = []
	for i in count:
		for j in range(i + 1, count):
			var d: float = Vector2(_rooms[i].get_center()).distance_squared_to(Vector2(_rooms[j].get_center()))
			pairs.append([i, j, d])
	pairs.sort_custom(func(a: Array, b: Array) -> bool: return a[2] < b[2])
	return pairs


## Carves an L-shaped (or straight, when already aligned) corridor of
## `corridor_width` between two rooms, appended to `_rooms` as one new
## corridor entry, and punches an `entrance_width` opening where each end
## meets its room. The bend of an L-shaped corridor is never a doorway —
## it's a turn in one hallway, not a join between two — which is why both
## legs share one room entry rather than getting one each.
##
## Known limitation: a corridor leg that happens to pass through a third
## room's rect on its way is skipped there rather than routed around it (see
## `_carve_span`) — rare with `room_gap` keeping rooms apart, and safe (it
## just leaves that room's own wall intact where the corridor would have
## crossed it), but not pretty. Acceptable for a first pass; worth revisiting
## if a seed turns up a corridor that dead-ends into another room's wall.
func _carve_corridor(data: MapData, a: int, b: int) -> void:
	var ra := _rooms[a]
	var rb := _rooms[b]
	var ca := ra.get_center()
	var cb := rb.get_center()
	var idx := _rooms.size()
	var w := _cfg.corridor_width
	var bounds: Rect2i

	if ca.x == cb.x:
		bounds = _carve_straight(data, idx, ca.x, ra, rb, w, false)
	elif ca.y == cb.y:
		bounds = _carve_straight(data, idx, ca.y, ra, rb, w, true)
	else:
		bounds = _carve_bend(data, idx, ra, rb, ca, cb, w)

	_rooms.append(bounds)
	_room_is_corridor.append(true)


## One straight leg directly joining two real rooms — both ends get an
## entrance. `horizontal` picks whether `band_coord` is the shared Z (a row)
## or the shared X (a column) the two room centres already agree on.
func _carve_straight(data: MapData, idx: int, band_coord: int, room_a: Rect2i, room_b: Rect2i, w: int, horizontal: bool) -> Rect2i:
	var lo := band_coord - w / 2
	var first := room_a if (room_a.position.x < room_b.position.x if horizontal else room_a.position.y < room_b.position.y) else room_b
	var second := room_b if first == room_a else room_a
	var span: Rect2i
	if horizontal:
		var x0 := first.position.x + first.size.x  # ring cell just outside `first`; span's own first column
		var x1 := second.position.x - 1  # ring cell just outside `second`; span's own last column
		span = Rect2i(x0, lo, x1 - x0 + 1, w)
		_punch_entrance_at(data, x0, true, lo, lo + w - 1)
		_punch_entrance_at(data, x1, true, lo, lo + w - 1)
	else:
		var z0 := first.position.y + first.size.y
		var z1 := second.position.y - 1
		span = Rect2i(lo, z0, w, z1 - z0 + 1)
		_punch_entrance_at(data, z0, false, lo, lo + w - 1)
		_punch_entrance_at(data, z1, false, lo, lo + w - 1)
	_carve_span(data, span, idx)
	return span


## An L-shaped corridor: a horizontal leg at A's row out to B's column, then
## a vertical leg up/down to B. The two legs are built to overlap by a full
## `w`x`w` block at the bend (each leg's band deliberately reaches INTO the
## other leg's band, not just up to it), so the join can never leave a gap
## regardless of which quadrant B sits in relative to A.
func _carve_bend(data: MapData, idx: int, ra: Rect2i, rb: Rect2i, ca: Vector2i, cb: Vector2i, w: int) -> Rect2i:
	var half := w / 2
	var hz0 := ca.y - half
	var hz1 := hz0 + w - 1
	var vx0 := cb.x - half
	var vx1 := vx0 + w - 1

	# Which wall of A the horizontal leg reaches out from, and which wall of B
	# the vertical leg reaches into — by EDGE, not by comparing centres: a
	# wide room can straddle the other band's coordinate even when its centre
	# compares the "wrong" way, and getting this wrong produces a negative-
	# size span. `_leg_range` also guarantees a non-degenerate result in that
	# straddling case rather than crashing.
	var h := _leg_range(ra.position.x, ra.position.x + ra.size.x, vx0, vx1, ca.x < cb.x)
	var hx0: int = h.x
	var hx1: int = h.y
	var horiz_span := Rect2i(hx0, hz0, hx1 - hx0 + 1, w)
	_carve_span(data, horiz_span, idx)
	_punch_entrance_at(data, hx0 if ca.x < cb.x else hx1, true, hz0, hz1)

	var v := _leg_range(rb.position.y, rb.position.y + rb.size.y, hz0, hz1, cb.y < ca.y)
	var vz0: int = v.x
	var vz1: int = v.y
	var vert_span := Rect2i(vx0, vz0, w, vz1 - vz0 + 1)
	_carve_span(data, vert_span, idx)
	_punch_entrance_at(data, vz0 if cb.y < ca.y else vz1, false, vx0, vx1)

	return horiz_span.merge(vert_span)


## The [lo, hi] a corridor leg should carve along the axis it travels, given
## the room it starts from (`room_lo`/`room_hi`, that room's own extent on
## this axis) and the perpendicular leg's band (`band_lo`/`band_hi`, which
## this leg must reach fully into so the bend has no gap). `toward_hi` says
## the leg travels from the room toward higher coordinates.
##
## Ordinarily this is just "from the room's facing wall to the far edge of
## the band". When the room's own extent already covers part of the band's
## range (a wide room straddling where the bend falls), reaching from the
## room's wall would land past the band and produce a negative-size span;
## `maxi`/`mini` below clamp to a minimal (but always valid) overlap instead.
func _leg_range(room_lo: int, room_hi: int, band_lo: int, band_hi: int, toward_hi: bool) -> Vector2i:
	if toward_hi:
		return Vector2i(room_hi, maxi(band_hi, room_hi))
	return Vector2i(mini(band_lo, room_lo - 1), room_lo - 1)


## Carves every cell of `span` as FLOOR and records it against `idx` — except
## a cell already claimed by another room (`data.room_of.has(pos)`), which is
## left as hull wall. See `_carve_corridor`'s docstring for why this is an
## accepted rough edge rather than a routed-around case.
func _carve_span(data: MapData, span: Rect2i, idx: int) -> void:
	for z in range(span.position.y, span.position.y + span.size.y):
		for x in range(span.position.x, span.position.x + span.size.x):
			var pos := Vector3i(x, 0, z)
			if data.room_of.has(pos):
				continue
			data.get_cell(pos).terrain = MapData.Terrain.FLOOR
			data.room_of[pos] = idx


## Opens an `entrance_width`-wide gap (marked DOOR — a walkable, distinctly
## terrained opening, not a door module; see MapBuilder) at wall coordinate
## `coord`, centred in `[band_lo, band_hi]`. `coord_is_x` picks whether
## `coord` is a fixed X (opening runs along Z) or a fixed Z (opening runs
## along X) — i.e. whether this wall is one the corridor approaches
## east/west or north/south.
func _punch_entrance_at(data: MapData, coord: int, coord_is_x: bool, band_lo: int, band_hi: int) -> void:
	var span := band_hi - band_lo + 1
	var width := mini(_cfg.entrance_width, span)
	# band_lo + (span - width) / 2, NOT (band_lo + band_hi) / 2 - width / 2 —
	# the two are only equal when span and width share parity, and when they
	# don't (e.g. span == width, both even) the latter can drift the window
	# entirely outside [band_lo, band_hi], punching a DOOR cell that was
	# never actually carved (no room_of entry, a real bug this replaced).
	# This form is provably bounded: mid >= band_lo always, and
	# mid + width - 1 <= band_hi since (span - width) / 2 <= span - width.
	var mid := band_lo + (span - width) / 2
	for i in width:
		var pos := Vector3i(coord, 0, mid + i) if coord_is_x else Vector3i(mid + i, 0, coord)
		data.get_cell(pos).terrain = MapData.Terrain.DOOR


func _find(parent: Array, i: int) -> int:
	while parent[i] != i:
		parent[i] = parent[parent[i]]
		i = parent[i]
	return i


# --- Spawns --------------------------------------------------------------
#
# Minimal placement so a generated deck is actually playable end to end: the
# squad in the first real room placed, one enemy in most of the rest. Not
# mission scripting — encounter design is a later pass over the same MapData.


func _place_spawns(data: MapData) -> void:
	var real_rooms: Array[int] = []
	for i in _rooms.size():
		if not _room_is_corridor[i]:
			real_rooms.append(i)
	if real_rooms.is_empty():
		return
	var player_room := real_rooms[0]
	var cells := _room_cells(data, player_room)
	_shuffle(cells)
	for i in mini(_cfg.player_spawn_count, cells.size()):
		data.get_cell(cells[i]).spawn = MapData.Spawn.PLAYER
	for idx in range(1, real_rooms.size()):
		if _rng.randf() > _cfg.enemy_room_chance:
			continue
		var room_cells := _room_cells(data, real_rooms[idx])
		if room_cells.is_empty():
			continue
		data.get_cell(room_cells[_rng.randi_range(0, room_cells.size() - 1)]).spawn = MapData.Spawn.ENEMY


## Every cell actually carved as part of `room_index` — not just every cell
## inside its rect, since a corridor's rect is only "indicative" (see
## MapData.rooms) and a room's rect can rarely have a corner clipped by
## another room's `room_gap` padding falling just short. `room_of` is the
## membership authority per MapData's own contract.
func _room_cells(data: MapData, room_index: int) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	var rect := _rooms[room_index]
	for z in range(rect.position.y, rect.position.y + rect.size.y):
		for x in range(rect.position.x, rect.position.x + rect.size.x):
			var pos := Vector3i(x, 0, z)
			if data.room_of.get(pos, -1) == room_index:
				out.append(pos)
	return out


# --- Cover placement -------------------------------------------------------
#
# Every piece of cover is a tile-occupying block (MapData.OBSTACLE + one
# `data.obstacles` entry) — XCOM-style furniture/crates a unit can't walk
# through until it's destroyed, not a boundary decal. Sizes 1x1 up to 3x2,
# tier rolled independently of size. The perimeter accuracy bonus and the
# destructible-reopens-the-tile behaviour both live at build/runtime
# (MapBuilder._add_cover_block, GridManager.register_cover_block) — this pass
# only decides where a footprint goes and how big/tough it is.
##
## Boundary edge-cover (data.cover_edges/set_cover_edge) is deliberately never
## touched here any more — it stays a hand-authored-map-only feature (see
## MapAscii's [cover] section).


## Weighted by repetition, not a separate weight table: small pieces are meant
## to be far more common than a big 3x2 barricade. 1x1 covers the "even a
## single tile" case from the design brief; the rest give size variety.
const COVER_SHAPES: Array[Vector2i] = [
	Vector2i(1, 1), Vector2i(1, 1), Vector2i(1, 1), Vector2i(1, 1),
	Vector2i(1, 2), Vector2i(2, 1),
	Vector2i(1, 3), Vector2i(3, 1),
	Vector2i(2, 2),
	Vector2i(2, 3), Vector2i(3, 2),
]
const COVER_ATTEMPTS := 8  # a piece competing for space with earlier ones gets a few tries to clear them


func _place_cover(data: MapData) -> void:
	for i in _rooms.size():
		if _room_is_corridor[i]:
			continue  # cover belongs in rooms, not in the halls between them
		_place_room_cover(data, _rooms[i])


## Count scales with room area — a small closet gets at most one crate, a
## cargo bay gets several — rather than the old flat 1-2 pieces, since blocks
## are now the only source of cover in a room rather than a garnish on top of
## dense edge cover. `cover_area_per_piece` is the knob to retune density with
## after playtesting; there's no principled "right" number here.
func _place_room_cover(data: MapData, room: Rect2i) -> void:
	var area := room.size.x * room.size.y
	var count := clampi(roundi(area / float(_cfg.cover_area_per_piece)), 0, _cfg.cover_max_per_room)
	var placed: Array[Rect2i] = []
	for _i in count:
		var footprint: Variant = _place_one_cover_block(data, room, placed)
		if footprint != null:
			placed.append(footprint)


## Places one cover block, rejection-sampled against `existing` pieces already
## placed in this room (plus a 1-tile gap, same reasoning as `_overlaps_any`
## for rooms) so two pieces never end up overlapping or flush against each
## other. Tries a few random shapes/orientations per attempt — a room too
## small for a 3x2 might still fit a 1x1 — rather than committing to one shape
## up front and giving up if it doesn't fit. Every shape keeps at least one
## tile of clearance to every room wall, which is what guarantees a flanking
## path around it: it can never span from one wall to the opposite one, so a
## route around always exists without a full connectivity re-check. Returns
## the placed footprint, or null if nothing fit within budget.
func _place_one_cover_block(data: MapData, room: Rect2i, existing: Array[Rect2i]) -> Variant:
	for _attempt in COVER_ATTEMPTS:
		var shape: Vector2i = COVER_SHAPES[_rng.randi_range(0, COVER_SHAPES.size() - 1)]
		if _rng.randf() < 0.5:
			shape = Vector2i(shape.y, shape.x)  # orientation isn't part of the weighting
		var max_x := room.size.x - 2 - shape.x
		var max_z := room.size.y - 2 - shape.y
		if max_x < 0 or max_z < 0:
			continue  # doesn't fit this room with clearance; try another shape
		var x := room.position.x + 1 + _rng.randi_range(0, max_x)
		var z := room.position.y + 1 + _rng.randi_range(0, max_z)
		var footprint := Rect2i(x, z, shape.x, shape.y)
		var clear := true
		for other in existing:
			if footprint.grow(1).intersects(other):
				clear = false
				break
		if not clear:
			continue
		var tier := MapData.Cover.HEAVY if _rng.randf() < _cfg.cover_heavy_chance else MapData.Cover.LIGHT
		for cz in range(footprint.position.y, footprint.position.y + footprint.size.y):
			for cx in range(footprint.position.x, footprint.position.x + footprint.size.x):
				data.get_cell(Vector3i(cx, 0, cz)).terrain = MapData.Terrain.OBSTACLE
		data.obstacles.append([footprint, tier])
		return footprint
	return null


func _shuffle(items: Array) -> void:
	# Not Array.shuffle(): that uses the global RNG and would make a seeded deck
	# depend on whatever else called randi() first.
	for i in range(items.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var tmp: Variant = items[i]
		items[i] = items[j]
		items[j] = tmp
