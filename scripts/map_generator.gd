class_name MapGenerator
extends RefCounted
## Deck generator, layers 1-2 of Sec 10.4: hull, spine corridor, BSP
## compartments, doorways. No cover, lights or spawns yet — those are later
## passes over the same MapData.
##
## BSP rather than caves or drunkard's-walk because a ship deck is a grid of
## compartments sharing bulkheads, not an eroded space. The split coordinate
## *is* the bulkhead: children are the ranges either side of it, so every wall
## is exactly one tile thick and no deck area is wasted on double walls.
##
## Everything here is deterministic in `map_seed` and touches no scene tree, so
## a few hundred decks can be generated and checked per second.

class Config:
	var width := 44
	var depth := 30
	var min_room := 4  # smallest interior span of a compartment, in tiles
	var max_room := 9  # anything longer than this is always split again
	var spine_width := 2  # main corridor running the long axis of the hull
	var split_chance := 0.55  # chance to split a compartment that need not be
	var doorway_width := 2  # tiles knocked out of a shared bulkhead
	var extra_link_ratio := 0.2  # edges added back on top of the spanning tree


var _cfg: Config
var _rng := RandomNumberGenerator.new()
var _rooms: Array[Rect2i] = []  # interior rects; index 0 is the spine if present
var _links: Array = []  # [a, b] index pairs into _rooms


static func generate(map_seed: int, cfg: Config = null) -> MapData:
	var gen := MapGenerator.new()
	gen._cfg = cfg if cfg != null else Config.new()
	gen._rng.seed = map_seed
	return gen._run(map_seed)


func _run(map_seed: int) -> MapData:
	var data := MapData.new()
	data.seed = map_seed
	_fill_hull(data)
	_lay_out_rooms()
	for room in _rooms:
		_carve(data, room)
	_connect_rooms()
	for link: Array in _links:
		_punch_doorway(data, _rooms[link[0]], _rooms[link[1]])
	data.rooms = _rooms.duplicate()
	data.room_links = _links.duplicate()
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


func _lay_out_rooms() -> void:
	_rooms.clear()
	# Interior of the hull, inside the outer bulkhead.
	var interior := Rect2i(1, 1, _cfg.width - 2, _cfg.depth - 2)
	# The spine needs a wall row either side of it plus a compartment beyond
	# each; on a deck too shallow for that, drop it and partition the lot.
	var needed := 2 * _cfg.min_room + _cfg.spine_width + 4
	if _cfg.depth < needed:
		_partition(interior)
		return
	# Deliberately off-centre: a spine down the middle every time reads as a
	# generator, an asymmetric one reads as a ship.
	var z_spine := _rng.randi_range(
		_cfg.min_room + 2,
		_cfg.depth - 2 - _cfg.spine_width - _cfg.min_room
	)
	_rooms.append(Rect2i(1, z_spine, _cfg.width - 2, _cfg.spine_width))
	_partition(Rect2i(1, 1, _cfg.width - 2, z_spine - 2))
	var south_z := z_spine + _cfg.spine_width + 1
	_partition(Rect2i(1, south_z, _cfg.width - 2, _cfg.depth - 1 - south_z))


func _partition(rect: Rect2i) -> void:
	if rect.size.x < _cfg.min_room or rect.size.y < _cfg.min_room:
		return  # too thin to be a compartment; stays solid hull
	# A split at coordinate c consumes c itself as the bulkhead, so the region
	# must hold two minimum compartments plus that one tile.
	var span := 2 * _cfg.min_room + 1
	var can_x := rect.size.x >= span
	var can_z := rect.size.y >= span
	var oversized := rect.size.x > _cfg.max_room or rect.size.y > _cfg.max_room
	if not (can_x or can_z) or (not oversized and _rng.randf() > _cfg.split_chance):
		_rooms.append(rect)
		return
	var vertical := can_x and (not can_z or rect.size.x >= rect.size.y)
	if vertical:
		var c := _rng.randi_range(
			rect.position.x + _cfg.min_room,
			rect.position.x + rect.size.x - 1 - _cfg.min_room
		)
		_partition(Rect2i(rect.position.x, rect.position.y, c - rect.position.x, rect.size.y))
		_partition(Rect2i(c + 1, rect.position.y, rect.position.x + rect.size.x - 1 - c, rect.size.y))
	else:
		var c := _rng.randi_range(
			rect.position.y + _cfg.min_room,
			rect.position.y + rect.size.y - 1 - _cfg.min_room
		)
		_partition(Rect2i(rect.position.x, rect.position.y, rect.size.x, c - rect.position.y))
		_partition(Rect2i(rect.position.x, c + 1, rect.size.x, rect.position.y + rect.size.y - 1 - c))


func _carve(data: MapData, room: Rect2i) -> void:
	for z in range(room.position.y, room.position.y + room.size.y):
		for x in range(room.position.x, room.position.x + room.size.x):
			data.get_cell(Vector3i(x, 0, z)).terrain = MapData.Terrain.FLOOR


func _connect_rooms() -> void:
	# Spanning tree first so the deck is guaranteed traversable, then a share of
	# the rejected edges added back. A pure tree gives dead ends and forced
	# backtracking; the loops are what make flanking routes exist at all.
	_links.clear()
	var candidates := _adjacent_pairs()
	_shuffle(candidates)
	var parent := range(_rooms.size())
	var spare: Array = []
	for pair: Array in candidates:
		var ra := _find(parent, pair[0])
		var rb := _find(parent, pair[1])
		if ra == rb:
			spare.append(pair)
			continue
		parent[ra] = rb
		_links.append(pair)
	var extra := int(round(_links.size() * _cfg.extra_link_ratio))
	for i in mini(extra, spare.size()):
		_links.append(spare[i])


func _adjacent_pairs() -> Array:
	# Two compartments are neighbours when exactly one bulkhead tile separates
	# them and they overlap enough along the shared wall to hold a doorway.
	var pairs: Array = []
	for i in _rooms.size():
		for j in range(i + 1, _rooms.size()):
			if _shared_wall(_rooms[i], _rooms[j]) != Vector3i.ZERO:
				pairs.append([i, j])
	return pairs


func _shared_wall(a: Rect2i, b: Rect2i) -> Vector3i:
	# Returns (wall_coord, overlap_start, overlap_end) along the shared edge,
	# packed so the caller can tell "no shared wall" (ZERO) from a real one.
	var ax0 := a.position.x
	var ax1 := a.position.x + a.size.x - 1
	var az0 := a.position.y
	var az1 := a.position.y + a.size.y - 1
	var bx0 := b.position.x
	var bx1 := b.position.x + b.size.x - 1
	var bz0 := b.position.y
	var bz1 := b.position.y + b.size.y - 1
	if bx0 - ax1 == 2 or ax0 - bx1 == 2:
		var wall_x := ax1 + 1 if bx0 - ax1 == 2 else bx1 + 1
		var lo := maxi(az0, bz0)
		var hi := mini(az1, bz1)
		if hi - lo + 1 >= _cfg.doorway_width:
			return Vector3i(wall_x, lo, hi)
	if bz0 - az1 == 2 or az0 - bz1 == 2:
		var wall_z := az1 + 1 if bz0 - az1 == 2 else bz1 + 1
		var lo := maxi(ax0, bx0)
		var hi := mini(ax1, bx1)
		if hi - lo + 1 >= _cfg.doorway_width:
			return Vector3i(-wall_z - 1, lo, hi)  # negative tags a horizontal wall
	return Vector3i.ZERO


func _punch_doorway(data: MapData, a: Rect2i, b: Rect2i) -> void:
	var wall := _shared_wall(a, b)
	if wall == Vector3i.ZERO:
		return
	var horizontal := wall.x < 0
	var coord := -wall.x - 1 if horizontal else wall.x
	var start := _rng.randi_range(wall.y, wall.z - _cfg.doorway_width + 1)
	for i in _cfg.doorway_width:
		var pos := Vector3i(start + i, 0, coord) if horizontal else Vector3i(coord, 0, start + i)
		data.get_cell(pos).terrain = MapData.Terrain.FLOOR


func _shuffle(items: Array) -> void:
	# Not Array.shuffle(): that uses the global RNG and would make a seeded deck
	# depend on whatever else called randi() first.
	for i in range(items.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var tmp: Variant = items[i]
		items[i] = items[j]
		items[j] = tmp


func _find(parent: Array, i: int) -> int:
	while parent[i] != i:
		parent[i] = parent[parent[i]]
		i = parent[i]
	return i
