class_name Contract
extends RefCounted
## One mission's objective (GDD §7.5, extraction plan 3.3): what it is, where its
## target is, what it pays. Optional — a squad can extract without it — and the
## payout only counts if someone extracts.
##
## Engine-free (MapData in, Contract out), so placement is testable from a
## --script tool and is a pure function of the deck and the RNG. That purity is
## what co-op relies on: every peer builds the same deck and seeds the global RNG
## the same way before spawning (main.gd), so every peer chooses the same contract
## and plants it identically, with nothing sent.
##
## The campaign (Phase 4) offers contracts as ContractOffers and builds the Contract
## with `ContractOffer.build_contract` -> `make`; `choose` is the no-offer fallback.

## APPEND-ONLY: Phase 4 saves hold these as ints. HOLD (hold a terminal) and
## RECOVER (carry out a downed VIP) are extraction plan Phase 6.
enum Type { RETRIEVE, DESTROY, HOLD, RECOVER }

const TYPE_NAME := {
	Type.RETRIEVE: "Retrieve", Type.DESTROY: "Destroy", Type.HOLD: "Hold", Type.RECOVER: "Recover",
}

## Default payouts, overwritten by the campaign (CampaignEconomy.payout_for). Destroy pays
## more because the nest keeps spawning and its death wakes the deck
## (AlienHivemind.report_nest_destroyed); Retrieve's cost is the walk and a slot.
## Hold sits between them: four loud rounds pinned to one console (TerminalRules)
## bring the deck to you, but there is nothing to carry home. Recover pays most:
## the walk back is made one-handed (the carrier has only the pistol, GDD §4.4),
## and every hit on the carrier risks the VIP (the 25% redirect) — the contract
## can die in the carrier's arms. Kept equal to CampaignEconomy.BASE_PAYOUT.
const PLACEHOLDER_PAYOUT := {Type.RETRIEVE: 500, Type.DESTROY: 600, Type.HOLD: 550, Type.RECOVER: 650}

## "The farthest third by path distance" (plan 3.3): the candidate rooms are ranked
## by distance from insertion and the target goes in one of the top 1/N of them
## (at least one room).
const FAR_FRACTION := 3

## Who a Recover client wants back. Flavour only; drawn with the placement (`make`)
## so every peer names the VIP the same. Here rather than on VipUnit so this class
## stays engine-free.
const VIP_NAMES: Array[String] = [
	"Dr. Halvorsen", "Director Mbeki", "Chief Engineer Sato", "Envoy Castellanos",
	"Dr. Ilyushina", "Captain Abernathy",
]

var type: Type = Type.RETRIEVE
## RETRIEVE: the crate the item is planted in. DESTROY: the nest's tile. HOLD: the
## terminal's tile (ObjectiveManager builds the console there and blocks the
## tile). RECOVER: the tile the VIP lies on (main.gd spawns them there).
var target_tile := Vector3i.ZERO
## RETRIEVE: the ItemPresets code of the objective item.
var item_code := ""
var payout := 0
## DESTROY: true when the deck had no nest and this contract places one at
## `target_tile` (main.gd spawns it). False when it names a nest the deck has.
var place_nest := false
## RECOVER: who the VIP is (VIP_NAMES), drawn with the placement so every
## peer names them the same.
var vip_name := ""


func title() -> String:
	match type:
		Type.RETRIEVE:
			var item := ItemPresets.from_code(item_code)
			return "Retrieve: %s" % (item.display_name if item else item_code)
		Type.DESTROY:
			return "Destroy: Nest"
		Type.HOLD:
			return "Hold: Terminal"
		Type.RECOVER:
			return "Recover: %s" % (vip_name if vip_name != "" else "VIP")
	return "Objective"


## Wire- and save-safe form (MissionResult carries it for Phase 4).
func to_dict() -> Dictionary:
	return {
		"type": int(type), "target": target_tile, "item": item_code,
		"payout": payout, "place_nest": place_nest, "vip": vip_name,
	}


static func from_dict(d: Dictionary) -> Contract:
	var c := Contract.new()
	c.type = d.get("type", Type.RETRIEVE)
	c.target_tile = d.get("target", Vector3i.ZERO)
	c.item_code = d.get("item", "")
	c.payout = d.get("payout", 0)
	c.place_nest = d.get("place_nest", false)
	c.vip_name = d.get("vip", "")
	return c


# --- Choosing and placing -----------------------------------------------------------


## The types this deck can host. Retrieve needs a crate somewhere other than the
## insertion bay to plant the item in; Destroy needs a nest — or a room to put one
## in, which every deck with a second room has. Hold needs a wall tile a console
## can stand against without cutting a room in two (`_terminal_candidates`);
## Recover needs open floor in a room to lay the VIP on (the nest's rules).
static func supported_types(data: MapData) -> Array[int]:
	var out: Array[int] = []
	if data == null:
		return out
	var dist := path_distances(data)
	if not _retrieve_candidates(data, dist).is_empty():
		out.append(Type.RETRIEVE)
	var nest_cells := _nest_candidates(data, dist)
	if not data.spawns(MapData.Spawn.NEST).is_empty() or not nest_cells.is_empty():
		out.append(Type.DESTROY)
	if not _terminal_candidates(data, dist).is_empty():
		out.append(Type.HOLD)
	if not nest_cells.is_empty():
		out.append(Type.RECOVER)
	return out


## A random supported contract for `data`, or null if it supports none.
static func choose(data: MapData, rng: RandomNumberGenerator = null) -> Contract:
	var types := supported_types(data)
	if types.is_empty():
		return null
	return make(types[_pick(types.size(), rng)], data, rng)


## A contract of `type` placed on `data`, or null if the deck cannot host it.
static func make(type: Type, data: MapData, rng: RandomNumberGenerator = null) -> Contract:
	var dist := path_distances(data)
	var c := Contract.new()
	c.type = type
	c.payout = PLACEHOLDER_PAYOUT[type]
	match type:
		Type.RETRIEVE:
			var spots := _retrieve_candidates(data, dist)
			if spots.is_empty():
				return null
			c.target_tile = _pick_far(data, spots, dist, rng)
			var ids := ItemPresets.objective_ids()
			c.item_code = ids[_pick(ids.size(), rng)]
		Type.DESTROY:
			var nests := data.spawns(MapData.Spawn.NEST)
			if not nests.is_empty():
				# The deck's own nest; the farthest one if it has several.
				nests.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
					return _tile_dist(data, a, dist) > _tile_dist(data, b, dist))
				c.target_tile = nests[0]
			else:
				var cells := _nest_candidates(data, dist)
				if cells.is_empty():
					return null
				c.target_tile = _pick_far(data, cells, dist, rng)
				c.place_nest = true
		Type.HOLD:
			var spots := _terminal_candidates(data, dist)
			if spots.is_empty():
				return null
			c.target_tile = _pick_far(data, spots, dist, rng)
		Type.RECOVER:
			# "A VIP spawned DOWNED in a far room" (plan Phase 6). The nest's
			# floor rules suit a body too: open floor in a room, nothing spawning
			# on or beside it, off every pad and square, room to stand around it.
			var cells := _nest_candidates(data, dist)
			if cells.is_empty():
				return null
			c.target_tile = _pick_far(data, cells, dist, rng)
			c.vip_name = VIP_NAMES[_pick(VIP_NAMES.size(), rng)]
	return c


## Path distance (steps) from the insertion square — or the squad's spawns on a
## deck without one — to every passable tile: 8-way, with the grid's corner rule
## (a diagonal between two impassable tiles is closed).
static func path_distances(data: MapData) -> Dictionary:
	var dist: Dictionary = {}
	var frontier: Array[Vector3i] = []
	var insertion := data.insertion_hangar()
	var starts: Array[Vector3i] = insertion.square if insertion != null else data.spawns(MapData.Spawn.PLAYER)
	for pos in starts:
		if data.is_passable(pos):
			dist[pos] = 0
			frontier.append(pos)
	var head := 0
	while head < frontier.size():
		var cur: Vector3i = frontier[head]
		head += 1
		for dz in [-1, 0, 1]:
			for dx in [-1, 0, 1]:
				if dx == 0 and dz == 0:
					continue
				var n: Vector3i = cur + Vector3i(dx, 0, dz)
				if dist.has(n) or not data.is_passable(n):
					continue
				if dx != 0 and dz != 0 and not data.is_passable(cur + Vector3i(dx, 0, 0)) \
						and not data.is_passable(cur + Vector3i(0, 0, dz)):
					continue
				dist[n] = dist[cur] + 1
				frontier.append(n)
	return dist


## Crates a Retrieve item may go in: reachable, and not in the insertion bay (the
## item would be in the squad's hands before the first shot). Crates in ordinary
## rooms are preferred; another hangar's bay is used only when there is no such
## crate (a hand-authored deck whose rooms are all hangars, like extraction_test).
static func _retrieve_candidates(data: MapData, dist: Dictionary) -> Array[Vector3i]:
	var ordinary: Array[Vector3i] = []
	var bays: Array[Vector3i] = []
	var insertion_room := _insertion_room(data)
	for spot: MapData.LootSpot in data.containers:
		if _tile_dist(data, spot.pos, dist) < 0:
			continue
		var room := data.room_index_at(spot.pos)
		if room == insertion_room:
			continue
		if data.hangar_index_at(spot.pos) >= 0:
			bays.append(spot.pos)
		else:
			ordinary.append(spot.pos)
	return ordinary if not ordinary.is_empty() else bays


## Tiles a nest may be planted on: reachable plain floor in a room (not a corridor,
## not the insertion bay), with no spawn or crate on or beside it, off every
## hangar's pad and square, and with at least NEST_MIN_OPEN free neighbours for it
## to spawn into. Ordinary rooms first, other hangar bays only as a fallback.
## Also where a Recover VIP may lie.
const NEST_MIN_OPEN := 3


static func _nest_candidates(data: MapData, dist: Dictionary) -> Array[Vector3i]:
	var ordinary: Array[Vector3i] = []
	var bays: Array[Vector3i] = []
	var insertion_room := _insertion_room(data)
	var keep_clear := _pads_and_squares(data)
	for pos: Vector3i in dist:
		var room := data.room_index_at(pos)
		if room < 0 or room == insertion_room or data.corridors.has(room) or keep_clear.has(pos):
			continue
		var cell := data.get_cell(pos)
		if cell == null or cell.terrain != MapData.Terrain.FLOOR or cell.spawn != MapData.Spawn.NONE:
			continue
		var open := 0
		var crowded := false
		for dz in [-1, 0, 1]:
			for dx in [-1, 0, 1]:
				var n: Vector3i = pos + Vector3i(dx, 0, dz)
				if n == pos:
					continue
				if data.has_container(n) or data.terrain_at(n) == MapData.Terrain.DOOR:
					crowded = true
				var nc := data.get_cell(n)
				if data.is_passable(n) and nc != null and nc.spawn == MapData.Spawn.NONE:
					open += 1
		if crowded or open < NEST_MIN_OPEN:
			continue
		if data.hangar_index_at(pos) >= 0:
			bays.append(pos)
		else:
			ordinary.append(pos)
	ordinary.sort()
	bays.sort()
	return ordinary if not ordinary.is_empty() else bays


## The eight neighbours of a tile in RING order (each one 4-adjacent to the next,
## wrapping round) — what `_terminal_candidates` walks to prove a console cannot
## cut a path.
const RING: Array[Vector3i] = [
	Vector3i(0, 0, -1), Vector3i(1, 0, -1), Vector3i(1, 0, 0), Vector3i(1, 0, 1),
	Vector3i(0, 0, 1), Vector3i(-1, 0, 1), Vector3i(-1, 0, 0), Vector3i(-1, 0, -1),
]
## Open neighbours a console needs: somewhere to stand to operate it, and room
## for a second soldier to hold it alongside.
const TERMINAL_MIN_OPEN := 3


## Tiles a Hold terminal may stand on. The console BLOCKS its tile (like a crate),
## so the rules are the crate's (MapGenerator._crate_fits) — reachable plain floor
## against a wall, no spawn, fixture or stair, no door, obstacle or crate in its
## eight neighbours — in a room that is not a corridor or the insertion bay and
## off every pad and square. And it must not cut a path, proved LOCALLY: its
## passable neighbours form ONE unbroken run round the ring (RING), so any route
## that would have crossed the tile can step round it through them. Ordinary rooms
## first, other hangar bays only as a fallback.
static func _terminal_candidates(data: MapData, dist: Dictionary) -> Array[Vector3i]:
	var ordinary: Array[Vector3i] = []
	var bays: Array[Vector3i] = []
	var insertion_room := _insertion_room(data)
	var keep_clear := _pads_and_squares(data)
	for pos: Vector3i in dist:
		var room := data.room_index_at(pos)
		if room < 0 or room == insertion_room or data.corridors.has(room) or keep_clear.has(pos):
			continue
		var cell := data.get_cell(pos)
		if cell == null or cell.terrain != MapData.Terrain.FLOOR or cell.spawn != MapData.Spawn.NONE \
				or cell.fixture != MapData.Fixture.NONE or cell.stair:
			continue
		var against_wall := false
		for step: Vector3i in MapData.SIDE_STEP:
			if data.terrain_at(pos + step) == MapData.Terrain.WALL:
				against_wall = true
		if not against_wall:
			continue
		var ok := true
		var open: Array[bool] = []
		for step in RING:
			var n: Vector3i = pos + step
			var t := data.terrain_at(n)
			var nc := data.get_cell(n)
			if t == MapData.Terrain.DOOR or t == MapData.Terrain.OBSTACLE or t == MapData.Terrain.PLATFORM \
					or data.has_container(n) or (nc != null and (nc.spawn != MapData.Spawn.NONE or nc.stair)):
				ok = false
				break
			open.append(data.is_passable(n))
		if not ok:
			continue
		var runs := 0
		var count := 0
		for i in RING.size():
			if open[i]:
				count += 1
				if not open[i - 1]:  # i - 1 = -1 wraps to the last
					runs += 1
		if runs != 1 or count < TERMINAL_MIN_OPEN:
			continue
		if data.hangar_index_at(pos) >= 0:
			bays.append(pos)
		else:
			ordinary.append(pos)
	ordinary.sort()
	bays.sort()
	return ordinary if not ordinary.is_empty() else bays


## Every hangar's pad and square, as a set: nothing an objective places goes there.
static func _pads_and_squares(data: MapData) -> Dictionary:
	var keep_clear: Dictionary = {}
	for h: MapData.Hangar in data.hangars:
		for pos in MapData.hangar_pad_cells(h.pad_center):
			keep_clear[pos] = true
		for pos in h.square:
			keep_clear[pos] = true
	return keep_clear


## Picks one tile out of `tiles` in a room from the farthest third: rooms ranked by
## the distance of their nearest candidate, the top ceil(n / FAR_FRACTION) kept, one
## room drawn at random, then one of its candidates.
static func _pick_far(data: MapData, tiles: Array[Vector3i], dist: Dictionary, rng: RandomNumberGenerator) -> Vector3i:
	var by_room: Dictionary = {}
	for pos in tiles:
		var room := data.room_index_at(pos)
		if not by_room.has(room):
			by_room[room] = []
		by_room[room].append(pos)
	var rooms: Array = by_room.keys()
	var room_dist := func(room: int) -> int:
		var best := 999999
		for pos: Vector3i in by_room[room]:
			best = mini(best, _tile_dist(data, pos, dist))
		return best
	rooms.sort_custom(func(a: int, b: int) -> bool:
		var da: int = room_dist.call(a)
		var db: int = room_dist.call(b)
		return da > db if da != db else a < b)
	var keep := maxi(1, ceili(float(rooms.size()) / FAR_FRACTION))
	var room: int = rooms[_pick(keep, rng)]
	var options: Array = by_room[room]
	options.sort()
	return options[_pick(options.size(), rng)]


## Path distance to `pos`; for an impassable tile (a crate) the distance to its
## nearest reachable neighbour plus one. -1 if unreachable.
static func _tile_dist(data: MapData, pos: Vector3i, dist: Dictionary) -> int:
	if dist.has(pos):
		return dist[pos]
	var best := -1
	for dz in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			var n: Vector3i = pos + Vector3i(dx, 0, dz)
			if dist.has(n) and (best < 0 or dist[n] + 1 < best):
				best = dist[n] + 1
	return best


static func _insertion_room(data: MapData) -> int:
	var insertion := data.insertion_hangar()
	return insertion.room_index if insertion != null else -2


static func _pick(n: int, rng: RandomNumberGenerator) -> int:
	if n <= 1:
		return 0
	return rng.randi_range(0, n - 1) if rng != null else randi_range(0, n - 1)
