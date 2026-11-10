extends Node
## Autoload. Owns the tile dictionary, passability, BFS range queries, LOS.
## Grid key: Vector3i(x, floor, z) — Sec 10.3. One tile = TILE_SIZE meters.

const TILE_SIZE := 1.5
const FLOOR_HEIGHT := 3.0  # world-space Y per grid floor level
## Where sight is sampled on a standing unit, above its tile: a seer looks from
## its eye, a target is seen at its chest.
const EYE_HEIGHT := 1.4
const CHEST_HEIGHT := 0.9

var tiles: Dictionary = {}  # Vector3i -> GridTileData
# Extra adjacency for stairs: Vector3i -> Array[Vector3i] (both directions added)
var stair_links: Dictionary = {}

## Fired when an edge loses a tier, INCLUDING heavy dropping to light — the
## listener that cares about "is there still cover here" has to re-ask either
## way. `now` is the MapData.Cover value the edge has after the hit.
signal cover_destroyed(pos: Vector3i, side: int, now: int)


## Deck levels that currently hold tiles, for `tile_under_ray`. Kept as a set
## rather than rescanned per call: picking runs every frame while a move mode is
## armed, and the answer only changes when a deck is built.
var _floors: Dictionary = {}
## Goal reservations (exploration plan A.2): tile -> the unit walking to it, and
## the reverse. A reserved tile is closed as a DESTINATION to every other unit
## and stays open to pass through, so two concurrent walks can never be sent to
## the same square while neither has arrived yet. Host-side, like every move.
var _reservations: Dictionary = {}
var _reserved_tile: Dictionary = {}
## The node whose world `sight_blocked_on` raycasts in. Set by MapBuilder.build:
## the question is about the map, so it is asked in the map's world rather than
## of whichever unit happened to ask.
var world_node: Node3D = null
## `sight_blocked_on` answers: Vector4i(x, deck, z, side) -> bool. Layer-1
## geometry only changes when a deck is built or a ship blocker comes and goes,
## so these are cleared then (`clear`, `invalidate_sight_cache`) and otherwise kept.
var _sight_cache: Dictionary = {}
## Physics frame the cache was last cleared on. A body added or removed reaches
## the physics space only on the next step, so an answer read before then may be
## about the old geometry and is returned but not kept.
var _sight_cache_since: int = -1


func clear() -> void:
	tiles.clear()
	stair_links.clear()
	_floors.clear()
	_reservations.clear()
	_reserved_tile.clear()
	GridTileData.topology_version += 1
	invalidate_sight_cache()


## Forgets every `sight_blocked_on` answer. Call when layer-1 geometry changes.
func invalidate_sight_cache() -> void:
	_sight_cache.clear()
	_sight_cache_since = Engine.get_physics_frames()


func add_tile(pos: Vector3i, world_pos: Vector3) -> GridTileData:
	var t := GridTileData.new()
	t.world_pos = world_pos
	tiles[pos] = t
	_floors[pos.y] = true
	GridTileData.topology_version += 1
	return t


## The tile a camera ray passes over, found by intersecting the ray with each
## deck's horizontal plane rather than by raycasting against geometry.
##
## GEOMETRY IS DELIBERATELY NOT CONSULTED, and that is the whole point. Tile
## picking used to be a physics ray against layer 1, so any wall between the
## camera and the tile ate the click — and because `_apply_wall_occlusion` hides
## the meshes of camera-near walls but keeps their collision bodies, the player
## could plainly SEE a tile they were unable to click on. At a fixed isometric
## pitch with only four yaws there is frequently no angle that clears the
## obstruction, so the tile was simply unreachable by mouse.
##
## Projection cannot be blocked by anything, which removes the whole class of
## problem. It grants no reach: the destination still has to be in the reachable
## set (`GridManager.reachable_costs`, which excludes walls and occupied tiles)
## and still has to be walkable to (`find_path`), so this changes what the cursor
## can NAME, never where a unit can go.
##
## Topmost deck first, so a platform is picked over the floor beneath it — which
## is what the eye expects when the two overlap on screen.
func tile_under_ray(from: Vector3, dir: Vector3) -> Vector3i:
	if absf(dir.y) < 0.0001:
		return Vector3i(0, -9999, 0)  # ray parallel to the decks; nothing to hit
	var levels := _floors.keys()
	levels.sort()
	levels.reverse()
	for level: int in levels:
		var distance := (level * FLOOR_HEIGHT - from.y) / dir.y
		if distance <= 0.0:
			continue  # plane is behind the camera
		var point := from + dir * distance
		var tile := Vector3i(roundi(point.x / TILE_SIZE), level, roundi(point.z / TILE_SIZE))
		if tiles.has(tile):
			return tile
	return Vector3i(0, -9999, 0)


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
	GridTileData.topology_version += 1


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


## Clears `pos` only if `unit` is the one holding it. A walker releasing the tile
## it just left must not wipe somebody who has since stepped in behind it.
func release_occupant(pos: Vector3i, unit: Node3D) -> void:
	var t: GridTileData = tiles.get(pos)
	if t and t.occupant == unit:
		t.occupant = null


## Reserves `tile` as `unit`'s destination, replacing any reservation it held.
## False (and nothing changes) if somebody else already holds it.
func reserve(tile: Vector3i, unit: Node3D) -> bool:
	var holder := reserved_by(tile)
	if holder != null and holder != unit:
		return false
	release_reservation(unit)
	_reservations[tile] = unit
	_reserved_tile[unit] = tile
	return true


## Drops whatever `unit` had reserved. Safe on a unit holding nothing.
func release_reservation(unit: Node3D) -> void:
	if not _reserved_tile.has(unit):
		return
	var tile: Vector3i = _reserved_tile[unit]
	_reserved_tile.erase(unit)
	if _reservations.get(tile) == unit:
		_reservations.erase(tile)


## Who has reserved `tile` as a destination, or null. A freed holder reads as
## nobody: a unit gone mid-walk holds no claim.
func reserved_by(tile: Vector3i) -> Node3D:
	var holder: Variant = _reservations.get(tile)
	if holder == null:
		return null
	if not is_instance_valid(holder):
		_reservations.erase(tile)
		return null
	return holder


## Whether `unit` may END a walk on `tile`: nobody else has reserved it. Passing
## through is never asked here — a reservation does not block a path.
func open_destination(tile: Vector3i, unit: Node3D) -> bool:
	var holder := reserved_by(tile)
	return holder == null or holder == unit


## The eight grid directions a unit may step along, in the order the four
## cardinals then the four diagonals. EIGHT-way: a character is drawn in eight
## directions (unit_visual.gd's DIRECTIONS), so every one of these has art to
## show, and a diagonal costs the same one tile a cardinal does — see
## `get_reachable_tiles` for why that keeps the BFS uniform-cost.
##
## This is the single source of movement adjacency — get_reachable_tiles,
## find_path and is_melee_adjacent all derive from it, so nothing can disagree
## with it about what "adjacent" means.
const STEPS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1),
	Vector3i(1, 0, 1), Vector3i(1, 0, -1), Vector3i(-1, 0, 1), Vector3i(-1, 0, -1),
]


## Whether a tile is open enough to count as a corner a diagonal may be taken
## around. Deliberately reads only the MAP — a tile with somebody standing on it
## is still a tile with no wall on it, and a squadmate should not be able to
## block a corner simply by standing beside it. `is_free` is the test for
## whether the destination itself can be entered; this is only about the two
## tiles a diagonal squeezes between.
func _corner_is_open(pos: Vector3i) -> bool:
	var t: GridTileData = tiles.get(pos)
	return t != null and t.passable


func neighbors(pos: Vector3i) -> Array[Vector3i]:
	# Eight-way same-floor neighbors (Sec 4.0) plus any pre-authored stair links
	# (elevation traversal free, Sec 4.0).
	#
	# Diagonals carry a corner-cutting guard, and it is the loose form: a
	# diagonal is blocked only when BOTH tiles it passes between are walls. So a
	# unit may slip around a single wall corner — which is what makes eight-way
	# movement feel like movement rather than like a grid — but cannot thread the
	# zero-width gap where two walls meet at a point, which is the case that
	# reads on screen as walking through solid geometry.
	var out: Array[Vector3i] = []
	for step in STEPS:
		var n := pos + step
		if not tiles.has(n):
			continue
		if step.x != 0 and step.z != 0 \
				and not _corner_is_open(pos + Vector3i(step.x, 0, 0)) \
				and not _corner_is_open(pos + Vector3i(0, 0, step.z)):
			continue
		out.append(n)
	if stair_links.has(pos):
		for n: Vector3i in stair_links[pos]:
			out.append(n)
	return out


## `neighbors` written into a caller's array, cleared first — the same tiles in
## the same order, for the searches that ask it once per tile they visit and
## would otherwise allocate an array each time.
func _neighbors_into(pos: Vector3i, out: Array[Vector3i]) -> void:
	out.clear()
	for step in STEPS:
		var n := pos + step
		if not tiles.has(n):
			continue
		if step.x != 0 and step.z != 0 \
				and not _corner_is_open(pos + Vector3i(step.x, 0, 0)) \
				and not _corner_is_open(pos + Vector3i(0, 0, step.z)):
			continue
		out.append(n)
	if stair_links.has(pos):
		for n: Vector3i in stair_links[pos]:
			out.append(n)


## `neighbors(pos)` from a cache, for the searches that ask it of every tile they
## visit. The list depends only on which tiles exist, which are passable and the
## stair links, so it is rebuilt whenever GridTileData.topology_version moves.
## SHARED — callers read it and must never modify it.
var _adjacency: Dictionary = {}
var _adjacency_version := -1


func _adjacent(pos: Vector3i) -> Array[Vector3i]:
	if _adjacency_version != GridTileData.topology_version:
		_adjacency.clear()
		_adjacency_version = GridTileData.topology_version
	var cached: Variant = _adjacency.get(pos)
	if cached != null:
		return cached
	var out: Array[Vector3i] = []
	_neighbors_into(pos, out)
	_adjacency[pos] = out
	return out


## Every tile within `max_tiles` steps, mapped to the number of steps it takes to
## get there. Excludes `from` itself.
##
## BFS, uniform cost 1, excluding impassable/occupied tiles. Sec 4.0.
##
# A diagonal costs the same one tile a cardinal does, which is what keeps
# this a BFS rather than a Dijkstra: the moment a diagonal costs 1.5 the
# frontier stops popping in non-decreasing depth and every caller that treats
# `max_tiles` as a whole number of AP-worth of movement needs rewriting too.
# The price is the familiar one — N tiles reaches a SQUARE of side 2N+1, so
# the diagonals reach ~1.41x further in world distance than the cardinals.
#
# The DEPTHS are what the movement preview needs, not just the set: movement is
# 1 AP per tile now (Unit.MOVE_AP_PER_TILE), so a tile's depth here IS its price,
# and the overlay can price every candidate destination without pathing to each
# one separately.
##
## `through` is find_path's: tiles (Vector3i -> anything) walked through even
## while somebody holds them — a zombie squeezing past its own kind
## (SwarmUnit). They are reached and priced like any other, so a caller that
## must END on a tile of its own checks `is_free` on what it picks.
func reachable_costs(from: Vector3i, max_tiles: int, through: Dictionary = {}) -> Dictionary:
	var costs := {}
	var visited := {from: 0}
	var frontier: Array[Vector3i] = [from]
	var head := 0  # by index: pop_front shifts the whole queue on every pop
	while head < frontier.size():
		var cur: Vector3i = frontier[head]
		head += 1
		var depth: int = visited[cur]
		if depth >= max_tiles:
			continue
		for n in _adjacent(cur):
			if visited.has(n):
				continue
			if not is_free(n) and not (through.has(n) and _corner_is_open(n)):
				continue
			visited[n] = depth + 1
			costs[n] = depth + 1
			frontier.append(n)
	return costs


func get_reachable_tiles(from: Vector3i, max_tiles: int) -> Array[Vector3i]:
	var reached: Array[Vector3i] = []
	for tile: Vector3i in reachable_costs(from, max_tiles):
		reached.append(tile)
	return reached


## Whether the path may step onto `n`.
##
## Three answers, and the third is the worm mass's (see `find_path`):
##   free                 anybody may walk there
##   the occupied GOAL    for pathing *toward* another unit, stopping short
##   a hostile of `trample_for`  a unit that does not go around
##
## `trample_for` deliberately opens ONLY tiles held by something that unit would
## engage. An ally's tile stays closed at every step including the goal, so a
## mass still routes around its own kind rather than pathing through the pile it
## is walking toward — merging is a thing that happens on ARRIVAL, not a way to
## pass through a friend.
func _path_open(n: Vector3i, goal: Vector3i, allow_occupied_goal: bool, trample_for: Unit,
		through: Dictionary = {}) -> bool:
	if is_free(n):
		return true
	if allow_occupied_goal and n == goal:
		return true
	if through.has(n):
		var held: GridTileData = tiles.get(n)
		return held != null and held.passable
	if trample_for == null:
		return false
	var t: GridTileData = tiles.get(n)
	if t == null or not t.passable:
		return false  # a wall is a wall; nothing tramples geometry
	var occupant := t.occupant as Unit
	return occupant != null and not occupant.is_downed and trample_for.is_hostile_to(occupant)


func find_path(from: Vector3i, to: Vector3i, max_tiles: int, allow_occupied_goal := false,
		trample_for: Unit = null, through: Dictionary = {}) -> Array[Vector3i]:
	# BFS with parent tracking; returns path excluding `from`, empty if
	# unreachable. With allow_occupied_goal the goal tile itself may be
	# occupied (used to path *toward* another unit).
	#
	# `trample_for` is the worm mass's exception and the only one: a unit that
	# attacks BY MOVING needs hostile-held tiles traversable en route, not merely
	# as a destination, or it paths around the soldier it means to roll over.
	# Everything else on the board passes null and sees the old two-answer gate.
	# See `_path_open`, and docs/design/factions/aliens/design-choices/worm-mass.md.
	#
	# `through` is a set of tiles (Vector3i -> anything) treated as open even while
	# somebody holds them: a horde body planning its way THROUGH its own pack,
	# which is about to move on (SwarmUnit._move_toward). The path it returns may
	# cross held tiles, so the caller walks only its clear stretch.
	#
	# On an eight-way grid with uniform cost, a tile off both axes is reached in
	# max(dx, dz) steps by MANY routes -- the diagonal steps may be taken in any
	# order relative to the straight ones. Among those, prefer the one that
	# CHANGES DIRECTION fewest times, but never trade a turn for an extra tile,
	# since tiles are what AP and range measure.
	#
	# This tiebreak is load-bearing rather than cosmetic. Plain BFS returns
	# whichever interleaving it happened to expand first, which is typically a
	# zigzag alternating diagonal and cardinal steps -- and a unit walking that
	# turns 45 degrees on every single tile. With facing quantised to eight
	# directions that is not a subtle wobble, it is the sprite flipping between
	# two drawn poses per step. Eight-way makes this MORE valuable than four-way
	# did, not less: the tiebreak now collapses those routes into "go diagonally
	# until you are on the axis, then go straight", which is one turn for the
	# whole path.
	if from == to:
		return []
	# A goal nothing can step onto, or one whose every way in is held, is not
	# reached however far the search runs — and finding that out by search
	# floods the whole deck (tens of ms on a big one). A horde ringing its prey
	# hits exactly this for every body at the back, pass after pass. `neighbors`
	# is symmetric (the corner guard reads the same two tiles either way, stair
	# links go both ways), so the tiles a path can enter `to` FROM are its own
	# neighbours: `from` itself, or one the path may stand on.
	if not _path_open(to, to, allow_occupied_goal, trample_for, through):
		return []
	var way_in := false
	for n in neighbors(to):
		if n == from or _path_open(n, to, allow_occupied_goal, trample_for, through):
			way_in = true
			break
	if not way_in:
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
	# Read by index rather than pop_front, which shifts the whole queue down on
	# every pop and made a deck-wide search quadratic.
	var head := 0
	var probed := false
	while head < frontier.size():
		var cur: Vector3i = frontier[head]
		head += 1
		# A search this big may be filling the deck round a goal that sits in a
		# sealed pocket — prey with the pack plugging the doorway to it. Asked
		# once, only of searches already this large, so short ones pay nothing.
		if not probed and head > _SEALED_PROBE_AFTER:
			probed = true
			if _goal_sealed(from, to, allow_occupied_goal, trample_for, through):
				return []
		var cur_depth: int = depth[cur]
		if cur_depth >= max_tiles:
			continue
		# The queue pops in non-decreasing depth, so once the goal is found only
		# tiles one step shallower can still become its parent.
		if goal_depth >= 0 and cur_depth >= goal_depth:
			break
		var cur_heading: Vector3i = heading[cur]
		var cur_turns: int = turns[cur]
		for n in _adjacent(cur):
			# A tile already reached at another depth can change nothing below;
			# skipped before the open test, which is pure, so the answer is the same.
			var seen: int = depth.get(n, -1)
			if seen >= 0 and seen != cur_depth + 1:
				continue
			# `is_free` inline — the common answer — before the full gate.
			var tile: GridTileData = tiles.get(n)
			if not (tile != null and tile.passable and tile.occupant == null) \
					and not _path_open(n, to, allow_occupied_goal, trample_for, through):
				continue
			var step: Vector3i = n - cur
			# A stair link is neither a turn nor a heading: it changes floor, so
			# the step vector is not one of STEPS and carrying it forward would
			# charge a phantom turn to whatever comes next.
			var straight: bool = step.y != 0 \
				or cur_heading == Vector3i.ZERO or cur_heading == step
			var cost: int = cur_turns + (0 if straight else 1)
			if seen < 0:
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


## Tiles a `find_path` search visits before it checks for a sealed goal, and the
## most the check itself visits before giving up and letting the search run.
const _SEALED_PROBE_AFTER := 200
const _SEALED_PROBE_BUDGET := 400


## Whether `to` is provably cut off from `from`: a flood back out of the goal,
## through the same tiles `find_path` may stand on, that runs out of tiles
## without meeting `from` inside the budget. False means "reachable, or the
## goal's side is too big to tell cheaply" — the caller searches on as before,
## so the answer never changes, only how long a hopeless search takes.
func _goal_sealed(from: Vector3i, to: Vector3i, allow_occupied_goal: bool, trample_for: Unit,
		through: Dictionary) -> bool:
	var seen := {to: true}
	var frontier: Array[Vector3i] = [to]
	var head := 0
	while head < frontier.size():
		if frontier.size() > _SEALED_PROBE_BUDGET:
			return false
		var cur: Vector3i = frontier[head]
		head += 1
		for n in _adjacent(cur):
			if n == from:
				return false
			if seen.has(n):
				continue
			seen[n] = true
			if _path_open(n, to, allow_occupied_goal, trample_for, through):
				frontier.append(n)
	return true


## `find_path` with a per-tile surcharge: Dijkstra over cost 1 + `extra_cost(tile)`
## per step, so a route can swing wide of ground the caller would rather not
## cross without that ground being forbidden. Built for the rival mercs routing
## around third-party hostiles (CrossFactionRules.avoid_penalty, extraction plan
## Phase 7) and kept separate from `find_path` so the BFS every other mover uses
## — and its straight-line tiebreak — is untouched.
##
## Same gate (`_path_open`) and same return shape as `find_path`. `max_tiles`
## still caps the path's LENGTH in tiles, not its cost. No turn tiebreak: a
## caller that wants a detour has already accepted a less tidy walk. Ties break
## on discovery order, which is the fixed `neighbors` order, so the answer is
## deterministic for a given board (co-op runs this host-side only anyway).
func find_path_weighted(from: Vector3i, to: Vector3i, max_tiles: int,
		extra_cost: Callable, allow_occupied_goal := false) -> Array[Vector3i]:
	if from == to:
		return []
	var parent := {from: from}
	var cost := {from: 0}
	var depth := {from: 0}
	# Bucket queue: step costs are small positive ints, so buckets indexed by
	# total cost pop in order without a heap.
	var buckets := {0: [from]}
	var current := 0
	var max_cost := 0
	var done := {}
	while current <= max_cost:
		var bucket: Array = buckets.get(current, [])
		var i := 0
		while i < bucket.size():
			var cur: Vector3i = bucket[i]
			i += 1
			if done.has(cur) or cost[cur] != current:
				continue
			done[cur] = true
			if cur == to:
				break
			if depth[cur] >= max_tiles:
				continue
			for n in neighbors(cur):
				if done.has(n) or not _path_open(n, to, allow_occupied_goal, null):
					continue
				var step := 1 + maxi(0, int(extra_cost.call(n)))
				var c: int = current + step
				if not cost.has(n) or c < cost[n]:
					cost[n] = c
					depth[n] = depth[cur] + 1
					parent[n] = cur
					if not buckets.has(c):
						buckets[c] = []
					buckets[c].append(n)
					max_cost = maxi(max_cost, c)
		if done.has(to):
			break
		buckets.erase(current)
		current += 1
	if not done.has(to):
		return []
	var path: Array[Vector3i] = []
	var walk := to
	while walk != from:
		path.push_front(walk)
		walk = parent[walk]
	return path


func chebyshev_dist(a: Vector3i, b: Vector3i) -> int:
	# RANGE, not movement cost — and with eight-way movement at uniform cost the
	# two agree again on open ground: a diagonal counts 1 here and costs 1 to
	# walk. They still are not interchangeable, for two reasons that survive the
	# change. This ignores FLOORS, so it calls a unit under a platform distance 0
	# from one standing on it; and it ignores WALLS, which is correct for a shot
	# or a sensor sweep and wrong for feet. `is_melee_adjacent` rather than
	# `chebyshev_dist(..) <= 1` therefore remains the test for anything that has
	# to be walked to.
	return maxi(absi(a.x - b.x), absi(a.z - b.z))


func is_melee_adjacent(a: Vector3i, b: Vector3i) -> bool:
	# Contact range (Sec 11.4) — deliberately the same adjacency movement uses,
	# so a unit can only reach what it could have stepped onto. `chebyshev_dist`
	# is the wrong test here: it ignores floors, and would call a unit standing
	# under the platform distance 0 from one standing on top of it. Reusing
	# `neighbors` also inherits the corner-cutting guard, so nothing swings
	# diagonally through the point where two bulkheads meet.
	return b in neighbors(a)


func has_line_of_sight(shooter: Node3D, target: Node3D) -> bool:
	return not sight_line(shooter, target).is_empty()


## The line `seer` sees `target` along, as [seer_tile, target_tile] — the tiles
## the two ends are sampled from, either of which may be a lean tile rather than
## the unit's own (GDD §6.1.2) — or [] when there is none.
##
## Rays run eye (EYE_HEIGHT) to chest (CHEST_HEIGHT), blocked only by map
## geometry (collision layer 1). The straight line is tried first, from where the
## two units actually are; then the seer leaning, then the target leaning, then
## both. A lean is only ever a way PAST its corner (`_leans_toward`), and only a
## unit at rest leans (`can_peek`), so this is symmetric: whatever a unit sees by
## leaning sees it back along the same line.
##
## Duck-typed on `grid_pos` and `can_peek()`, so a headless tool's stand-in node
## works, and so does any non-Unit: it has no lean.
func sight_line(seer: Node3D, target: Node3D) -> Array:
	var systems := RoomSystems.current()
	if seer is CerberusUnit and systems != null and not systems.robots_enabled:
		return []
	# Either end may be standing ON a piece of geometry that must not block its
	# own sightlines — a door gun on its landed ship's hull (extraction plan
	# Phase 5, GDD §7.2): the hull blocks sight for everyone else in the bay, but
	# the gun sits on top of it. `los_exclusions` is a Unit virtual, [] for almost
	# everything.
	var exclude: Array[RID] = []
	if seer.has_method("los_exclusions"):
		exclude.append_array(seer.los_exclusions())
	if target.has_method("los_exclusions"):
		exclude.append_array(target.los_exclusions())
	return _sight_between(seer, _tile_of(seer), _tile_of(target),
		seer.global_position + Vector3(0, EYE_HEIGHT, 0),
		target.global_position + Vector3(0, CHEST_HEIGHT, 0),
		_peeks(seer), _peeks(target), exclude)


## `sight_line` for tiles nobody need be standing on yet — the AI asking whether
## a CANDIDATE tile would see, or be seen from, somewhere. `from_peeks` and
## `to_peeks` say whether each end may lean. `ref` is any node in the world.
func tiles_have_sight(ref: Node3D, from_tile: Vector3i, to_tile: Vector3i,
		from_peeks := false, to_peeks := false) -> bool:
	return not _sight_between(ref, from_tile, to_tile,
		grid_to_world(from_tile) + Vector3(0, EYE_HEIGHT, 0),
		grid_to_world(to_tile) + Vector3(0, CHEST_HEIGHT, 0),
		from_peeks, to_peeks).is_empty()


func _sight_between(ref: Node3D, from_tile: Vector3i, to_tile: Vector3i, eye: Vector3,
		chest: Vector3, from_peeks: bool, to_peeks: bool, exclude: Array[RID] = []) -> Array:
	if world_node != null and world_node.get("data") != null:
		var deck: MapData = world_node.data
		if (deck.is_dark_at(from_tile) or deck.is_dark_at(to_tile)) and chebyshev_dist(from_tile, to_tile) > RoomSystems.DARK_RANGE:
			return []
	if has_clear_line(ref, eye, chest, exclude):
		return [from_tile, to_tile]
	var from_leans := _leans_toward(from_tile, to_tile) if from_peeks else []
	var to_leans := _leans_toward(to_tile, from_tile) if to_peeks else []
	var lean_eye := Vector3(0, EYE_HEIGHT, 0)
	var lean_chest := Vector3(0, CHEST_HEIGHT, 0)
	for lean: Vector3i in from_leans:
		if has_clear_line(ref, grid_to_world(lean) + lean_eye, chest, exclude):
			return [lean, to_tile]
	for lean: Vector3i in to_leans:
		if has_clear_line(ref, eye, grid_to_world(lean) + lean_chest, exclude):
			return [from_tile, lean]
	for a: Vector3i in from_leans:
		for b: Vector3i in to_leans:
			if has_clear_line(ref, grid_to_world(a) + lean_eye, grid_to_world(b) + lean_chest, exclude):
				return [a, b]
	return []


func _tile_of(node: Node3D) -> Vector3i:
	return node.grid_pos if "grid_pos" in node else world_to_grid(node.global_position)


func _peeks(node: Node3D) -> bool:
	return node.has_method("can_peek") and node.can_peek()


## The lean tiles of `pos` that count toward `other` — rule 3 of §6.1.2: a lean
## is a look PAST its corner, so it only helps toward a tile strictly beyond the
## blocker's near face, never as an extra tile of vision in every direction.
func _leans_toward(pos: Vector3i, other: Vector3i) -> Array:
	var out: Array = []
	for peek: Array in peek_tiles(pos):
		var step: Vector3i = MapData.SIDE_STEP[peek[1]]
		var past := (other.x - pos.x) * step.x + (other.z - pos.z) * step.z
		if past > 0:
			out.append(peek[0])
	return out


## Where a unit on `pos` can lean out to see round a corner (GDD §6.1.2), as
## [lean_tile, side] pairs, `side` being the side of `pos` the blocker is on.
## All three must hold:
##   - something that blocks sight sits flush against that side of `pos`;
##   - the tile beside `pos` along the blocker is open floor — the MAP only, as
##     `_corner_is_open` reads it, so a squadmate standing there doesn't stop it;
##   - the blocker does not carry on past that tile: the wall ends at the unit.
## So there is no lean halfway along a wall and none in an inside corner, and a
## unit beside a doorway leans into the doorway.
func peek_tiles(pos: Vector3i) -> Array:
	var out: Array = []
	# Leaning is something done from open floor. A unit placed inside a wall
	# cell (tests do this) would otherwise "lean" out of solid geometry.
	if not _corner_is_open(pos):
		return out
	for side: int in [MapData.Side.EAST, MapData.Side.SOUTH, MapData.Side.WEST, MapData.Side.NORTH]:
		if not sight_blocked_on(pos, side):
			continue
		for along: int in [(side + 1) % 4, (side + 3) % 4]:
			var lean: Vector3i = pos + MapData.SIDE_STEP[along]
			if _corner_is_open(lean) and not sight_blocked_on(lean, side):
				out.append([lean, side])
	return out


## Whether something that blocks sight sits flush against `side` of `pos`: an
## eye-height ray from the tile's centre one tile toward that neighbour hits
## layer 1 — walls, wrecks and a landed ship's blocker, everything line of sight
## treats as solid. Read by corner peeking and by corner cover (Combat.defending_cover).
func sight_blocked_on(pos: Vector3i, side: int) -> bool:
	var key := Vector4i(pos.x, pos.y, pos.z, side)
	if _sight_cache.has(key):
		return _sight_cache[key]
	if world_node == null or not is_instance_valid(world_node) or not world_node.is_inside_tree():
		return false
	var from := grid_to_world(pos) + Vector3(0, EYE_HEIGHT, 0)
	var to := from + Vector3(MapData.SIDE_STEP[side]) * TILE_SIZE
	var blocked := not has_clear_line(world_node, from, to)
	if Engine.get_physics_frames() > _sight_cache_since:
		_sight_cache[key] = blocked
	return blocked


func has_clear_line(from_node: Node3D, from: Vector3, to: Vector3, exclude: Array[RID] = []) -> bool:
	# Generic raycast against map geometry (collision layer 1), given explicit
	# world points rather than unit eye/chest heights. Used for LOS above and
	# for lighting occlusion (Sec 5) — anything needing "can X see point Y".
	var space := from_node.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to, 1, exclude)
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


## Registers one block-cover piece (MapBuilder.CoverBlock, backing a
## MapData.obstacles entry) against every tile bordering its footprint — the
## same shared CoverEdge at each, exactly how add_cover_edge already shares
## one edge between the two tiles a single boundary separates, just spread
## across a whole perimeter instead of one side. A neighbour that has no
## GridTileData is either inside the footprint itself or another obstacle
## (WALL/VOID/OBSTACLE cells never get one — see MapBuilder._build_cell), so
## checking `tiles.has(n)` alone is enough to skip those without knowing the
## footprint's own shape.
func register_cover_block(footprint: Rect2i, deck: int, tier: int, node: Node3D) -> CoverEdge:
	var edge := CoverEdge.new()
	edge.type = tier
	edge.hp = CoverEdge.hp_for(tier)
	edge.node = node
	edge.is_block = true
	edge.footprint = footprint
	edge.deck = deck
	for z in range(footprint.position.y, footprint.position.y + footprint.size.y):
		for x in range(footprint.position.x, footprint.position.x + footprint.size.x):
			var pos := Vector3i(x, deck, z)
			for side in [MapData.Side.EAST, MapData.Side.SOUTH, MapData.Side.WEST, MapData.Side.NORTH]:
				var n := pos + MapData.SIDE_STEP[side]
				var t: GridTileData = tiles.get(n)
				if t == null:
					continue
				var facing := opposite_side(side)
				t.cover_edges[facing] = edge
				edge.registrations.append([n, facing])
	return edge


func cover_edge(pos: Vector3i, side: int) -> CoverEdge:
	var t: GridTileData = tiles.get(pos)
	return t.cover_edges.get(side) if t else null


## MapData.Cover value protecting `pos` from `side`, or NONE.
func cover_type_on(pos: Vector3i, side: int) -> int:
	var edge := cover_edge(pos, side)
	return edge.type if edge else MapData.Cover.NONE


## Whether the cover on `pos`'s `side` is also cover for `other` — the same
## CoverEdge object registered on one of `other`'s sides. Edges are shared
## between the tiles they separate, and a block's one edge rings its whole
## perimeter, so this catches both two units either side of one crate and two
## at different faces of the same block. A shooter firing across cover it is
## itself behind does not chew at it (normal fire only — deliberate
## cover-breaking and explosives still do).
func shares_cover_edge(pos: Vector3i, side: int, other: Vector3i) -> bool:
	var edge := cover_edge(pos, side)
	if edge == null:
		return false
	var t: GridTileData = tiles.get(other)
	return t != null and t.cover_edges.values().has(edge)


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
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return cover_type_on(pos, side)
	var damaged := cover_edge(pos, side)
	var was_intact := damaged != null and damaged.is_intact()
	# Only the host resolves the fire that does this, so each ready client is
	# handed the same damage to apply to its own copy — the edge HP starts the
	# same everywhere, so the same hits leave it at the same tier.
	# The same reasoning lets a mission snapshot carry cover as the list of hits
	# (MissionSnapshot), replayed onto a freshly built board.
	MissionSnapshot.note(["cover", pos, side, amount])
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		for peer_id in SteamLobby.ready_peers:
			_rpc_damage_cover_edge.rpc_id(peer_id, pos, side, amount)
	var result := _damage_cover_edge(pos, side, amount)
	if was_intact and not damaged.is_intact() and is_instance_valid(damaged.node) and damaged.node.has_method("explode"):
		damaged.node.explode()
	return result


@rpc("authority", "call_remote", "reliable")
func _rpc_damage_cover_edge(pos: Vector3i, side: int, amount: int) -> void:
	_damage_cover_edge(pos, side, amount)


func _damage_cover_edge(pos: Vector3i, side: int, amount: int) -> int:
	var edge := cover_edge(pos, side)
	if edge == null or not edge.is_intact():
		return MapData.Cover.NONE
	if edge.indestructible:
		return edge.type
	edge.hp -= amount
	if edge.hp > 0:
		return edge.type
	if edge.is_block:
		# Straight to destroyed, no HEAVY->LIGHT ladder: that ladder models a
		# prop getting shabbier while still standing, which doesn't apply to a
		# whole tile — either it's still blocking the way or it's rubble.
		_destroy_cover_block(edge)
	elif edge.type == MapData.Cover.HEAVY:
		edge.type = MapData.Cover.LIGHT
		edge.hp = CoverEdge.hp_for(MapData.Cover.LIGHT)
		if edge.node and edge.node.has_method("set_tier"):
			edge.node.set_tier(edge.type)
	else:
		edge.type = MapData.Cover.NONE
		edge.hp = 0
		if edge.node and edge.node.has_method("set_tier"):
			edge.node.set_tier(edge.type)
	cover_destroyed.emit(pos, side, edge.type)
	return edge.type


## A block's HP hit zero: clear the accuracy bonus everywhere it was
## registered, reopen its footprint to movement, and let the visual react.
## `grid_to_world` already returns the correct fallback position for a cell
## with no tile yet (see below), so reopening needs no coordinate math of its
## own beyond that.
func _destroy_cover_block(edge: CoverEdge) -> void:
	invalidate_sight_cache()
	edge.type = MapData.Cover.NONE
	edge.hp = 0
	for reg: Array in edge.registrations:
		var t: GridTileData = tiles.get(reg[0])
		if t:
			t.cover_edges.erase(reg[1])
	for z in range(edge.footprint.position.y, edge.footprint.position.y + edge.footprint.size.y):
		for x in range(edge.footprint.position.x, edge.footprint.position.x + edge.footprint.size.x):
			var pos := Vector3i(x, edge.deck, z)
			if not tiles.has(pos):
				add_tile(pos, grid_to_world(pos))
	if edge.node and edge.node.has_method("on_destroyed"):
		edge.node.on_destroyed()
