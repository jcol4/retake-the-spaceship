extends Node
## Autoload. Owns the tile dictionary, passability, BFS range queries, LOS.
## Grid key: Vector3i(x, floor, z) — Sec 10.3. One tile = TILE_SIZE meters.

const TILE_SIZE := 1.5
const FLOOR_HEIGHT := 3.0  # world-space Y per grid floor level

var tiles: Dictionary = {}  # Vector3i -> GridTileData
# Extra adjacency for stairs: Vector3i -> Array[Vector3i] (both directions added)
var stair_links: Dictionary = {}

signal cover_destroyed(pos: Vector3i)


func clear() -> void:
	tiles.clear()
	stair_links.clear()


func add_tile(pos: Vector3i, world_pos: Vector3) -> GridTileData:
	var t := GridTileData.new()
	t.world_pos = world_pos
	tiles[pos] = t
	return t


func get_tile(pos: Vector3i) -> GridTileData:
	return tiles.get(pos)


func has_tile(pos: Vector3i) -> bool:
	return tiles.has(pos)


func add_stair_link(a: Vector3i, b: Vector3i) -> void:
	if not stair_links.has(a):
		stair_links[a] = []
	if not stair_links.has(b):
		stair_links[b] = []
	stair_links[a].append(b)
	stair_links[b].append(a)


func world_to_grid(world: Vector3) -> Vector3i:
	var floor_level := int(round(world.y / FLOOR_HEIGHT))
	return Vector3i(int(round(world.x / TILE_SIZE)), floor_level, int(round(world.z / TILE_SIZE)))


func grid_to_world(pos: Vector3i) -> Vector3:
	var t: GridTileData = tiles.get(pos)
	if t:
		return t.world_pos
	return Vector3(pos.x * TILE_SIZE, pos.y * FLOOR_HEIGHT, pos.z * TILE_SIZE)


func is_free(pos: Vector3i) -> bool:
	var t: GridTileData = tiles.get(pos)
	return t != null and t.passable and t.occupant == null


func set_occupant(pos: Vector3i, unit: Node3D) -> void:
	var t: GridTileData = tiles.get(pos)
	if t:
		t.occupant = unit


func neighbors(pos: Vector3i) -> Array[Vector3i]:
	# 8-way same-floor neighbors (diagonal cost == orthogonal, Sec 4.0)
	# plus any pre-authored stair links (elevation traversal free, Sec 4.0).
	var out: Array[Vector3i] = []
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			if dx == 0 and dz == 0:
				continue
			var n := pos + Vector3i(dx, 0, dz)
			if not tiles.has(n):
				continue
			# No cutting wall corners: a diagonal needs both orthogonal tiles
			# flanking it to be open. Otherwise a unit could slip around a
			# corner that has_line_of_sight still treats as solid, and end up
			# adjacent to an enemy it cannot see.
			if dx != 0 and dz != 0:
				if not _is_open(pos + Vector3i(dx, 0, 0)) or not _is_open(pos + Vector3i(0, 0, dz)):
					continue
			out.append(n)
	if stair_links.has(pos):
		for n: Vector3i in stair_links[pos]:
			out.append(n)
	return out


func _is_open(pos: Vector3i) -> bool:
	# Static geometry only. Occupants deliberately don't block a corner: they
	# don't block line of sight either, so including them would desync the two.
	var t: GridTileData = tiles.get(pos)
	return t != null and t.passable


func get_reachable_tiles(from: Vector3i, max_tiles: int) -> Array[Vector3i]:
	# BFS, uniform cost 1, excluding impassable/occupied tiles. Sec 4.0.
	var reached: Array[Vector3i] = []
	var visited := {from: 0}
	var frontier: Array[Vector3i] = [from]
	while not frontier.is_empty():
		var cur: Vector3i = frontier.pop_front()
		var depth: int = visited[cur]
		if depth >= max_tiles:
			continue
		for n in neighbors(cur):
			if visited.has(n) or not is_free(n):
				continue
			visited[n] = depth + 1
			reached.append(n)
			frontier.append(n)
	return reached


func find_path(from: Vector3i, to: Vector3i, max_tiles: int, allow_occupied_goal := false) -> Array[Vector3i]:
	# BFS with parent tracking; returns path excluding `from`, empty if
	# unreachable. With allow_occupied_goal the goal tile itself may be
	# occupied (used to path *toward* another unit).
	#
	# Diagonals cost the same tile as orthogonals (Sec 4.0), so many routes tie
	# on length. Among those, prefer the one taking the fewest diagonal steps —
	# units walk straight lines instead of zig-zagging — but never trade a
	# diagonal for an extra tile, since tiles are what AP and range measure.
	if from == to:
		return []
	var parent := {from: from}
	var depth := {from: 0}
	var diagonals := {from: 0}
	var goal_depth := -1
	var frontier: Array[Vector3i] = [from]
	while not frontier.is_empty():
		var cur: Vector3i = frontier.pop_front()
		var cur_depth: int = depth[cur]
		if cur_depth >= max_tiles:
			continue
		# The queue pops in non-decreasing depth, so once the goal is found only
		# tiles one step shallower can still become its parent.
		if goal_depth >= 0 and cur_depth >= goal_depth:
			break
		for n in neighbors(cur):
			if not is_free(n) and not (allow_occupied_goal and n == to):
				continue
			var turns: int = diagonals[cur] + (1 if _is_diagonal(cur, n) else 0)
			if not depth.has(n):
				depth[n] = cur_depth + 1
				diagonals[n] = turns
				parent[n] = cur
				if n == to:
					goal_depth = cur_depth + 1
				frontier.append(n)
			elif depth[n] == cur_depth + 1 and turns < diagonals[n]:
				# Same-length route into `n`, but a straighter one. Rerouting is
				# safe: `cur`'s own diagonal count is already final.
				diagonals[n] = turns
				parent[n] = cur
	if not parent.has(to):
		return []
	var path: Array[Vector3i] = []
	var walk := to
	while walk != from:
		path.push_front(walk)
		walk = parent[walk]
	return path


func _is_diagonal(a: Vector3i, b: Vector3i) -> bool:
	# Stair links change floor and are never treated as diagonal.
	return a.y == b.y and absi(a.x - b.x) == 1 and absi(a.z - b.z) == 1


func chebyshev_dist(a: Vector3i, b: Vector3i) -> int:
	# Matches movement cost: diagonals count 1. Floors ignored for range checks.
	return maxi(absi(a.x - b.x), absi(a.z - b.z))


func is_melee_adjacent(a: Vector3i, b: Vector3i) -> bool:
	# Contact range (Sec 11.4) — deliberately the same adjacency movement uses,
	# so a unit can only reach what it could have stepped onto. `chebyshev_dist`
	# is the wrong test here: it ignores floors, and would call a unit standing
	# under the platform distance 0 from one standing on top of it. Reusing
	# `neighbors` also inherits the no-corner-cutting rule, so nothing swings
	# diagonally around a wall it can't see past.
	return b in neighbors(a)


func has_line_of_sight(shooter: Node3D, target: Node3D) -> bool:
	# Single ray shooter-eye -> target-center, blocked only by map geometry
	# (collision layer 1). Multi-sample LOS (Sec 10.6) deferred.
	var from := shooter.global_position + Vector3(0, 1.4, 0)
	var to := target.global_position + Vector3(0, 0.9, 0)
	return has_clear_line(shooter, from, to)


func has_clear_line(from_node: Node3D, from: Vector3, to: Vector3) -> bool:
	# Generic raycast against map geometry (collision layer 1), given explicit
	# world points rather than unit eye/chest heights. Used for LOS above and
	# for lighting occlusion (Sec 5) — anything needing "can X see point Y".
	var space := from_node.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to, 1)
	var hit := space.intersect_ray(query)
	return hit.is_empty()


func damage_cover(pos: Vector3i, amount: int) -> void:
	# Sec 6.1.1: at 0 HP cover becomes impassable rubble, grants no bonus.
	var t: GridTileData = tiles.get(pos)
	if t == null or t.cover_type == GridTileData.CoverType.NONE:
		return
	t.cover_hp -= amount
	if t.cover_hp <= 0:
		t.cover_hp = 0
		t.cover_type = GridTileData.CoverType.NONE
		t.passable = false
		if t.cover_node and t.cover_node.has_method("become_rubble"):
			t.cover_node.become_rubble()
		cover_destroyed.emit(pos)


func adjacent_cover_tiles(unit_pos: Vector3i) -> Array[Vector3i]:
	# Tiles orthogonally adjacent to the unit that hold intact cover.
	var out: Array[Vector3i] = []
	for offset in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
		var n: Vector3i = unit_pos + offset
		var t: GridTileData = tiles.get(n)
		if t and t.cover_type != GridTileData.CoverType.NONE:
			out.append(n)
	return out
