extends Node
## Autoload. Owns the tile dictionary, passability, BFS range queries, LOS.
## Grid key: Vector3i(x, floor, z) — Sec 10.3. One tile = TILE_SIZE meters.

const TILE_SIZE := 1.5
const FLOOR_HEIGHT := 3.0  # world-space Y per grid floor level

var tiles: Dictionary = {}  # Vector3i -> GridTileData
# Extra adjacency for stairs: Vector3i -> Array[Vector3i] (both directions added)
var stair_links: Dictionary = {}

## Fired when an edge loses a tier, INCLUDING heavy dropping to light — the
## listener that cares about "is there still cover here" has to re-ask either
## way. `now` is the MapData.Cover value the edge has after the hit.
signal cover_destroyed(pos: Vector3i, side: int, now: int)


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


## The four grid axes a unit may step along. FOUR-way, not eight: a character is
## drawn in four directions, and those four are exactly the world axes (see
## unit_visual.gd's DIRECTIONS). Allowing a diagonal step would face a unit at a
## yaw no art exists for.
##
## This is the single source of movement adjacency — get_reachable_tiles,
## find_path and is_melee_adjacent all derive from it, so nothing can disagree
## with it about what "adjacent" means.
const STEPS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]


func neighbors(pos: Vector3i) -> Array[Vector3i]:
	# Four-way same-floor neighbors (Sec 4.0) plus any pre-authored stair links
	# (elevation traversal free, Sec 4.0).
	#
	# The corner-cutting guard that used to live here is gone with the diagonals
	# it policed: a unit can no longer slip around a corner that
	# has_line_of_sight treats as solid, because it can no longer move around a
	# corner in one step at all.
	var out: Array[Vector3i] = []
	for step in STEPS:
		var n := pos + step
		if tiles.has(n):
			out.append(n)
	if stair_links.has(pos):
		for n: Vector3i in stair_links[pos]:
			out.append(n)
	return out


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
	# On a four-way grid every route to a tile off both axes ties on length --
	# any interleaving of the same horizontal and vertical steps costs the same.
	# Among those, prefer the one that CHANGES DIRECTION fewest times, but never
	# trade a turn for an extra tile, since tiles are what AP and range measure.
	#
	# This tiebreak is load-bearing rather than cosmetic. Plain BFS returns
	# whichever interleaving it happened to expand first, which is typically a
	# staircase -- and a unit walking a staircase turns 90 degrees on every
	# single tile. With facing quantised to four directions that is not a subtle
	# wobble, it is the sprite flipping between two drawn poses per step.
	if from == to:
		return []
	var parent := {from: from}
	var depth := {from: 0}
	var turns := {from: 0}
	# Which way the unit was already travelling when it arrived. ZERO at the
	# start, which is what makes the first step of a path free of a turn charge
	# whichever way it goes.
	var heading := {from: Vector3i.ZERO}
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
			var step: Vector3i = n - cur
			# A stair link is neither a turn nor a heading: it changes floor, so
			# the step vector is not one of STEPS and carrying it forward would
			# charge a phantom turn to whatever comes next.
			var straight: bool = step.y != 0 \
				or heading[cur] == Vector3i.ZERO or heading[cur] == step
			var cost: int = turns[cur] + (0 if straight else 1)
			if not depth.has(n):
				depth[n] = cur_depth + 1
				turns[n] = cost
				heading[n] = Vector3i.ZERO if step.y != 0 else step
				parent[n] = cur
				if n == to:
					goal_depth = cur_depth + 1
				frontier.append(n)
			elif depth[n] == cur_depth + 1 and cost < turns[n]:
				# Same-length route into `n`, but a straighter one. Rerouting is
				# safe: `cur`'s own turn count is already final.
				turns[n] = cost
				heading[n] = Vector3i.ZERO if step.y != 0 else step
				parent[n] = cur
	if not parent.has(to):
		return []
	var path: Array[Vector3i] = []
	var walk := to
	while walk != from:
		path.push_front(walk)
		walk = parent[walk]
	return path


func chebyshev_dist(a: Vector3i, b: Vector3i) -> int:
	# RANGE, not movement cost — the two deliberately stopped agreeing when
	# movement went four-way. A shot, a sensor sweep and a thrown grenade all
	# cross a corner perfectly happily; only feet are restricted to the axes. So
	# range stays square (diagonals count 1) while a diagonal STEP costs two, and
	# `is_melee_adjacent` rather than `chebyshev_dist(..) <= 1` is the test for
	# anything that has to be walked to.
	#
	# Floors ignored, as before.
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


# --- Edge cover (Sec 6.1, XCOM model) ---------------------------------------
#
# Cover sits on the boundary between two tiles rather than occupying a tile of
# its own. Units stand ON covered tiles, so nothing here touches passability.


## The side of the neighbouring tile that names the same edge.
static func opposite_side(side: int) -> int:
	return (side + 2) % 4


## Registers one prop against both tiles it separates. The neighbour may not
## exist (a crate bolted to a bulkhead), in which case only this side is written
## — which is correct: there is nobody on the far side to protect.
func add_cover_edge(pos: Vector3i, side: int, cover_type: int, node: Node3D) -> CoverEdge:
	var edge := CoverEdge.new()
	edge.type = cover_type
	edge.hp = CoverEdge.hp_for(cover_type)
	edge.node = node
	var here: GridTileData = tiles.get(pos)
	if here:
		here.cover_edges[side] = edge
	var there: GridTileData = tiles.get(pos + MapData.SIDE_STEP[side])
	if there:
		there.cover_edges[opposite_side(side)] = edge
	return edge


func cover_edge(pos: Vector3i, side: int) -> CoverEdge:
	var t: GridTileData = tiles.get(pos)
	return t.cover_edges.get(side) if t else null


## MapData.Cover value protecting `pos` from `side`, or NONE.
func cover_type_on(pos: Vector3i, side: int) -> int:
	var edge := cover_edge(pos, side)
	return edge.type if edge else MapData.Cover.NONE


func covered_sides(pos: Vector3i) -> Array[int]:
	var out: Array[int] = []
	for side in [MapData.Side.EAST, MapData.Side.SOUTH, MapData.Side.WEST, MapData.Side.NORTH]:
		if cover_type_on(pos, side) != MapData.Cover.NONE:
			out.append(side)
	return out


## Sec 6.1.1: every shot at a covered unit chews at the cover. Returns the tier
## the edge is left at.
##
## Heavy DEGRADES to light rather than disappearing: a blown-apart crate is still
## something to crouch behind, and under the edge model there is no tile left to
## turn into impassable rubble the way the old per-tile version did. Light is the
## bottom tier and does go to nothing.
func damage_cover_edge(pos: Vector3i, side: int, amount: int) -> int:
	var edge := cover_edge(pos, side)
	if edge == null or not edge.is_intact():
		return MapData.Cover.NONE
	edge.hp -= amount
	if edge.hp > 0:
		return edge.type
	if edge.type == MapData.Cover.HEAVY:
		edge.type = MapData.Cover.LIGHT
		edge.hp = CoverEdge.hp_for(MapData.Cover.LIGHT)
	else:
		edge.type = MapData.Cover.NONE
		edge.hp = 0
	if edge.node and edge.node.has_method("set_tier"):
		edge.node.set_tier(edge.type)
	cover_destroyed.emit(pos, side, edge.type)
	return edge.type
