class_name DeckLayout
extends RefCounted
## A themed deck's layout (ROOM_THEMES_PLAN.md Phases B and C), run by
## MapGenerator when `Config.themed_rooms` is on. It writes straight into the
## generator's room list (`_rooms`, `_room_is_corridor`, `_room_types`, `_links`,
## the hangar arrays) and carves the MapData as it goes; everything after it —
## cover, spawns, loot, mercs — runs on its output exactly as on an untyped deck.
##
## The deck, bow (low X) to stern (high X):
##
##   hull ######################################################
##   port flank   [hangar]   rooms   [hangar]   rooms          (z low)
##   port spine   ======================================== (2 wide)
##   middle band  | rooms off the port spine    |   cross     |
##                | rooms off the starboard one |   corridors |
##   starb. spine ========================================
##   starb. flank  rooms   [hangar]    rooms   [hangar]        (z high)
##
## Every room is laid in a ROW against a spine, one wall between them, so every
## room opens straight onto a passageway and the deck is connected by
## construction: no corridor routing, and the only reroll left is a band that
## could not fit a room its zone requires (plan C.7). A room deep enough to fill
## the middle band touches both spines.
##
## Deterministic in the generator's `_rng`, like the rest of MapGenerator: co-op
## sends only the seed.


## A hangar bay's depth along its ramp axis, which runs across the flank: one
## tile behind the pad, the 5-tile pad, the 3-tile square and four rows in front
## of it (MapGenerator's `hangar_min_size` is 12). Every flank bay is this deep,
## so both spines run straight past them.
const FLANK_DEPTH := 13

## Plan "Deck profiles": primary-zone odds before an objective shifts them, and
## the secondary each primary pairs with.
const PRIMARY_ODDS := {RoomTypes.Zone.HABITATION: 35, RoomTypes.Zone.MEDICAL: 25, RoomTypes.Zone.ENGINEERING: 25, RoomTypes.Zone.COMMAND: 15}
const SECONDARY_OPTIONS := {
	RoomTypes.Zone.HABITATION: [RoomTypes.Zone.MEDICAL, RoomTypes.Zone.COMMAND],
	RoomTypes.Zone.MEDICAL: [RoomTypes.Zone.HABITATION, RoomTypes.Zone.COMMAND],
	RoomTypes.Zone.ENGINEERING: [RoomTypes.Zone.COMMAND, RoomTypes.Zone.CARGO],
	RoomTypes.Zone.COMMAND: [RoomTypes.Zone.HABITATION, RoomTypes.Zone.ENGINEERING],
}
## Bow to stern (plan B.3, decision 4). CARGO has no place in the plan's order;
## it goes aft, beside the engineering it pairs with.
const BAND_ORDER: Array[int] = [RoomTypes.Zone.COMMAND, RoomTypes.Zone.HABITATION, RoomTypes.Zone.MEDICAL, RoomTypes.Zone.ENGINEERING, RoomTypes.Zone.CARGO]
## The primary zone's share of the deck's length; the secondary has the rest.
const PRIMARY_SHARE := 0.6
## Band widths vary by up to this fraction, and each pair of neighbouring bands
## swaps with this chance (plan B.3 jitter).
const BAND_JITTER := 0.2
const BAND_SWAP_CHANCE := 0.3
## A spine segment (one per band) steps one tile inward with this chance — the
## plan's "small jogs", hidden at the cross-corridor where segments meet.
const SPINE_JOG_CHANCE := 0.35
## A room whose depth would leave less than this between it and the far spine
## takes the whole band instead: a sliver too thin for a room is wasted deck.
const STRETCH_LEFTOVER := 5
## Candidate spots tried per room or suite (plan C.3: "about 40").
const CANDIDATES := 40
## Utility filler gives up on a band after this many misses in a row (plan C.4).
const FILLER_MISSES := 12
## A neighbour within this many tiles counts toward a spot's score.
const NEAR_TILES := 4

enum Row { PORT, STAR, FULL, PORT_FLANK, STAR_FLANK }

var gen: MapGenerator
var data: MapData
var rng: RandomNumberGenerator
var cfg: MapGenerator.Config
var width := 0
var depth := 0

var primary := -1
var secondary := -1
var mixed := false
## One per band, bow to stern: {zone, role, b0, b1, x0, x1, psz, ssz, mid_z0, mid_z1}.
## b0/b1 are the boundary columns (a cross-corridor starts at each), x0/x1 the
## interior rooms may use, psz/ssz the first row of the port/starboard spine
## segment, mid_z0/mid_z1 the middle band between them (end exclusive).
var bands: Array[Dictionary] = []
## Spine segments and cross-corridors before they join the room list:
## {rect, kind: "port"|"star"|"cross"}.
var _corridor_rects: Array[Dictionary] = []
## Room index -> {row, band, suite (-1 for none), inner (no door of its own)}.
var meta: Dictionary = {}
var _counts: Dictionary = {}
var _suite_count := 0
## Indices of the port and starboard spine and of each cross-corridor, once
## appended.
var port_spine := -1
var star_spine := -1
var crosses: Array[int] = []
## Doors per room index (plan C.5 door rules are counted against this).
var doors: Dictionary = {}


func _init(generator: MapGenerator, map_data: MapData) -> void:
	gen = generator
	data = map_data
	rng = generator._rng
	cfg = generator._cfg
	width = cfg.width
	depth = cfg.depth


func build() -> void:
	data.explicit_doorways = true
	_roll_profile()
	_plan_bands()
	_place_hangars()
	_plan_spines()
	for i in bands.size():
		_fill_band(i)
	for i in bands.size():
		_fill_utility(i)
	gen._layout_failed = not _required_present()
	_append_corridors()
	for i in gen._rooms.size():
		if gen._room_is_corridor[i]:
			continue
		gen._carve(data, gen._rooms[i], i)
	for c in _corridor_rects:
		var idx: int = port_spine if c.kind == "port" else (star_spine if c.kind == "star" else c.index)
		gen._carve_span(data, c.rect, idx)
	_place_doors()
	data.deck_primary = primary
	data.deck_secondary = secondary
	data.deck_mixed = mixed
	for b in bands:
		data.zone_bands.append([b.zone, b.b0, b.b1 + 2])


# --- Profile and bands (plan B.1–B.3) --------------------------------------------


func _roll_profile() -> void:
	if cfg.mixed_profile:
		mixed = true
		return
	primary = cfg.profile_primary
	if primary < 0:
		var total := 0
		for z: int in PRIMARY_ODDS:
			total += PRIMARY_ODDS[z]
		var roll := rng.randi_range(0, total - 1)
		for z: int in PRIMARY_ODDS:
			roll -= PRIMARY_ODDS[z]
			if roll < 0:
				primary = z
				break
	secondary = cfg.profile_secondary
	if secondary < 0:
		var options: Array = SECONDARY_OPTIONS.get(primary, [RoomTypes.Zone.UTILITY])
		secondary = options[rng.randi_range(0, options.size() - 1)]


func _plan_bands() -> void:
	var zones: Array[int] = []
	var shares: Array[float] = []
	if mixed:
		for z in [RoomTypes.Zone.COMMAND, RoomTypes.Zone.HABITATION, RoomTypes.Zone.MEDICAL, RoomTypes.Zone.ENGINEERING]:
			zones.append(z)
			shares.append(0.25)
	else:
		zones.append(primary)
		zones.append(secondary)
		zones.sort_custom(func(a: int, b: int) -> bool: return BAND_ORDER.find(a) < BAND_ORDER.find(b))
		for z in zones:
			shares.append(PRIMARY_SHARE if z == primary else 1.0 - PRIMARY_SHARE)
	var total := 0.0
	for i in shares.size():
		shares[i] *= rng.randf_range(1.0 - BAND_JITTER, 1.0 + BAND_JITTER)
		total += shares[i]
	for i in range(zones.size() - 1):
		if rng.randf() < BAND_SWAP_CHANCE:
			var z := zones[i]
			zones[i] = zones[i + 1]
			zones[i + 1] = z
			var s := shares[i]
			shares[i] = shares[i + 1]
			shares[i + 1] = s
	# Boundary columns: a cross-corridor at each, 2 wide, from the bow (x = 1) to
	# the stern (x = width - 3).
	var first := 1
	var last := width - 3
	var length := float(last - first)
	# On Mixed decks reserve the minimum frontage for the required galley/mess
	# suite and reactor. Jitter distributes only the spare width; it cannot
	# produce a band that is geometrically unable to fit its required rooms.
	if mixed:
		var minimums: Array[float] = []
		var reserved := 0.0
		for zone in zones:
			var minimum := 18.0 if zone == RoomTypes.Zone.HABITATION else (17.0 if zone == RoomTypes.Zone.ENGINEERING else 13.0)
			minimums.append(minimum)
			reserved += minimum
		for i in shares.size():
			shares[i] = minimums[i] + maxf(0.0, length - reserved) * shares[i] / total
		total = length
	var at := float(first)
	var boundaries: Array[int] = [first]
	for i in range(zones.size() - 1):
		at += length * shares[i] / total
		boundaries.append(roundi(at))
	boundaries.append(last)
	for i in zones.size():
		var role := "mixed" if mixed else ("primary" if zones[i] == primary else "secondary")
		bands.append({"zone": zones[i], "role": role, "b0": boundaries[i], "b1": boundaries[i + 1],
			"x0": boundaries[i] + 3, "x1": boundaries[i + 1] - 1})


## Hangars on the flanks (plan B.4): farthest-point sampling as before, but every
## candidate lies along the port (z = 1) or starboard hull, FLANK_DEPTH deep, its
## ramp facing inward to the spine.
func _place_hangars() -> void:
	gen._hangar_rooms.clear()
	gen._hangar_pads.clear()
	gen._insertion = -1
	var count := gen._hangar_count()
	var lz := float(MapData.hangar_landing_zone_area())
	var w_lo := maxi(cfg.hangar_min_size, ceili(lz * MapData.HANGAR_BAY_AREA_MIN / FLANK_DEPTH))
	var w_hi := mini(cfg.hangar_max_size, floori(lz * MapData.HANGAR_BAY_AREA_MAX / FLANK_DEPTH))
	if count <= 0 or w_hi < w_lo:
		return
	for _h in count:
		var best := Rect2i()
		var best_score := -1.0
		for _c in cfg.hangar_candidates:
			var w := rng.randi_range(w_lo, w_hi)
			var port := rng.randf() < 0.5
			var x := rng.randi_range(1, width - 1 - w)
			var z := 1 if port else depth - 1 - FLANK_DEPTH
			var candidate := Rect2i(x, z, w, FLANK_DEPTH)
			if gen._overlaps_any(candidate, cfg.room_gap):
				continue
			var score := 0.0 if gen._rooms.is_empty() else gen._distance_to_nearest_room(candidate)
			if score > best_score:
				best_score = score
				best = candidate
		if best_score < 0.0:
			break
		var index := gen._rooms.size()
		var port_side := best.position.y == 1
		gen._hangar_rooms.append(index)
		gen._hangar_pads.append(gen._pad_facing(best, MapData.Side.SOUTH if port_side else MapData.Side.NORTH))
		_add_room(best, RoomTypes.HANGAR, Row.PORT_FLANK if port_side else Row.STAR_FLANK, -1, -1, false)
	if not gen._hangar_rooms.is_empty():
		gen._insertion = rng.randi_range(0, gen._hangar_rooms.size() - 1)


## Two spines (plan B.5), one segment per band so each may jog a tile inward,
## and a cross-corridor at every band boundary and at both ends.
func _plan_spines() -> void:
	var port_base := 1 + FLANK_DEPTH + 1
	var star_base := depth - 1 - FLANK_DEPTH - 1 - 2
	for b in bands:
		b.psz = port_base + (1 if rng.randf() < SPINE_JOG_CHANCE and not mixed else 0)
		b.ssz = star_base - (1 if rng.randf() < SPINE_JOG_CHANCE and not mixed else 0)
		b.mid_z0 = b.psz + 3
		b.mid_z1 = b.ssz - 1
		var seg_x := int(b.b0)
		var seg_w := int(b.b1) + 2 - seg_x
		_corridor_rects.append({"rect": Rect2i(seg_x, b.psz, seg_w, 2), "kind": "port"})
		_corridor_rects.append({"rect": Rect2i(seg_x, b.ssz, seg_w, 2), "kind": "star"})
	for j in bands.size() + 1:
		var left: Dictionary = bands[maxi(0, j - 1)]
		var right: Dictionary = bands[mini(bands.size() - 1, j)]
		var x: int = right.b0 if j < bands.size() else left.b1
		var z0: int = mini(left.psz, right.psz)
		var z1: int = maxi(left.ssz, right.ssz) + 2
		_corridor_rects.append({"rect": Rect2i(x, z0, 2, z1 - z0), "kind": "cross"})


# --- Rooms (plan C.1–C.4) ------------------------------------------------------------


## What a band holds, as placement units: suites (plan C.2) and single rooms,
## in the order they are placed — anchors (C.1) first, then the other suites,
## the zone's required rooms, and its optional ones (C.3) shuffled.
func _units_for(band: Dictionary) -> Array:
	var zone: int = band.zone
	var role: String = band.role
	var small := role == "mixed"
	var units: Array = []
	var optional: Array = []
	match zone:
		RoomTypes.Zone.HABITATION:
			units.append(_suite([&"cold_store", &"galley", &"mess"] if not small else [&"galley", &"mess"],
				[&"cold_store"]))
			var berthing := 1 if role != "primary" else (3 if width * depth >= cfg.hangar_area_large else 2)
			for _i in berthing:
				var members: Array = [&"bunk_room", &"bathroom"]
				if not small:
					members.append(&"bunk_room")
					if rng.randf() < 0.5:
						members.append(&"bunk_room")
					if rng.randf() < 0.6:
						members.append(&"locker_room" if rng.randf() < 0.6 else &"laundry")
				units.append(_suite(members, [], {&"bunk_room": 1 if small else 2, &"bathroom": 1}))
			optional = [&"lounge", &"gym", &"cabin", &"cabin", &"cabin", &"captains_quarters", &"laundry",
				&"locker_room"]
		RoomTypes.Zone.MEDICAL:
			var care: Array = [&"surgery" if rng.randf() < 0.6 else &"icu", &"medbay"]
			if not small and rng.randf() < 0.6:
				care.append(&"morgue" if rng.randf() < 0.6 else &"cryo")
			units.append(_suite(care if not small else [&"medbay", care[0]], []))
			units.append(_suite([&"clean_room", &"lab", &"specimen_hold"] if not small else [&"lab", &"clean_room"],
				[]))
			optional = [&"surgery", &"icu", &"morgue", &"cryo", &"imaging", &"data_storage"]
		RoomTypes.Zone.ENGINEERING:
			units.append(_suite([&"engine_room"], []))
			units.append(_suite([&"engineering_control"], []))
			optional = [&"fuel_storage", &"life_support", &"fabrication", &"maintenance", &"maintenance"]
		RoomTypes.Zone.COMMAND:
			var aux: StringName = &"comms" if rng.randf() < 0.5 else &"navigation"
			var bridge: Array = [aux, &"bridge"]
			if not small and rng.randf() < 0.6:
				bridge.append(&"captains_quarters")
			units.append(_suite(bridge, []))
			units.append(_suite([&"security_station"], []))
			optional = [&"armory", &"brig", &"server_room", &"comms", &"navigation"]
		RoomTypes.Zone.CARGO:
			units.append(_suite([&"cargo_hold"], []))
			optional = [&"cargo_hold", &"storage_closet", &"storage_closet"]
	_shuffle(optional)
	for t: StringName in optional:
		units.append(_suite([t], []))
	return units


func _suite(members: Array, inner: Array, minimum: Dictionary = {}) -> Dictionary:
	return {"members": members, "inner": inner, "minimum": minimum}


## Anchors (plan C.1): placed near the middle of their band.
const ANCHORS: Array[StringName] = [&"mess", &"engine_room", &"bridge", &"medbay", &"security_station"]


func _fill_band(band_index: int) -> void:
	var band: Dictionary = bands[band_index]
	for unit: Dictionary in _units_for(band):
		var members: Array = unit.members.duplicate()
		var inner: Array = unit.inner
		# Caps first: a member the deck already has enough of is dropped.
		members = members.filter(func(t: StringName) -> bool:
			var cap := RoomTypes.cap_of(t)
			return cap <= 0 or _counts.get(t, 0) < cap)
		if members.is_empty():
			continue
		# A suite that will not fit sheds its optional members from the far end
		# until it does, keeping the zone's required rooms as long as it can.
		while not members.is_empty():
			if _place_unit(band_index, members, inner):
				break
			var drop := _droppable(band.zone, members, unit.minimum)
			if drop < 0:
				break
			members.remove_at(drop)


## The member to shed from a suite that will not fit: the last that is not one
## of its zone's required rooms, or -1.
func _droppable(zone: int, members: Array, minimum: Dictionary) -> int:
	var required: Array = RoomTypes.ZONE_REQUIRED.get(zone, [])
	for i in range(members.size() - 1, -1, -1):
		if members.count(members[i]) <= minimum.get(members[i], 0):
			continue
		if not (members[i] in required and _counts.get(members[i], 0) == 0):
			return i
	return -1


## Tries CANDIDATES spots for one unit (a suite laid along a row, members one
## wall apart) and keeps the best-scoring legal one. False if none fit.
func _place_unit(band_index: int, members: Array, inner: Array) -> bool:
	var band: Dictionary = bands[band_index]
	var anchor := members.any(func(t: StringName) -> bool: return t in ANCHORS)
	var best_rects: Array = []
	var best_row := -1
	var best_score := -INF
	var rows: Array = [Row.PORT, Row.STAR, Row.PORT_FLANK, Row.STAR_FLANK]
	for _c in CANDIDATES:
		var row: int = rows[rng.randi_range(0, rows.size() - 1)]
		var x := _candidate_x(band, row)
		var rects := _lay(band, row, x, members)
		if rects.is_empty():
			continue
		var score := _score(band, row, rects, members, anchor)
		if score > best_score:
			best_score = score
			best_rects = rects
			best_row = row
	if best_rects.is_empty():
		return false
	var suite := -1
	if members.size() > 1:
		suite = _suite_count
		_suite_count += 1
	for i in members.size():
		var rect: Rect2i = best_rects[i]
		var row := best_row
		if row in [Row.PORT, Row.STAR] and rect.position.y == band.mid_z0 and rect.end.y == band.mid_z1:
			row = Row.FULL
		_add_room(rect, members[i], row, band_index, suite, members[i] in inner)
	return true


## A starting column for a candidate: hard against the band's bow end or the
## previous room in that row (tight packing leaves the most deck for the rest),
## or now and then anywhere.
func _candidate_x(band: Dictionary, row: int) -> int:
	var starts: Array[int] = [band.x0]
	for i in gen._rooms.size():
		var m: Dictionary = meta.get(i, {})
		if m.is_empty() or gen._room_is_corridor[i]:
			continue
		if _same_side(m.row, row):
			var r := gen._rooms[i]
			if r.end.x + cfg.room_gap >= band.x0 and r.end.x + cfg.room_gap < band.x1:
				starts.append(r.end.x + cfg.room_gap)
	if rng.randf() < 0.25:
		return rng.randi_range(band.x0, maxi(band.x0, band.x1 - 3))
	return starts[rng.randi_range(0, starts.size() - 1)]


static func _same_side(a: int, b: int) -> bool:
	if a == Row.FULL or b == Row.FULL:
		return a in [Row.PORT, Row.STAR, Row.FULL] and b in [Row.PORT, Row.STAR, Row.FULL]
	return a == b


## The member rects of a unit laid from column `x` along `row`, or [] if any is
## out of the band or touches what is already there.
func _lay(band: Dictionary, row: int, x: int, members: Array) -> Array:
	var rects: Array = []
	var at := x
	for t: StringName in members:
		var size := _size_for(t, band, row, at)
		if size == Vector2i.ZERO:
			return []
		var z0: int
		match row:
			Row.PORT: z0 = band.mid_z0
			Row.STAR: z0 = band.mid_z1 - size.y
			Row.PORT_FLANK: z0 = band.psz - 1 - size.y
			_: z0 = band.ssz + 3
		var rect := Rect2i(at, z0, size.x, size.y)
		if rect.position.x < band.x0 or rect.end.x > band.x1 or not _free(rect):
			return []
		rects.append(rect)
		at = rect.end.x + 1  # suite members share a one-tile wall
	return rects


## [width along the row, depth away from the spine] for one room of `type` laid
## in `row` from column `x`, or ZERO if it cannot fit there. The long side goes
## into the depth when it fits (row length is what runs out first), and a room
## that would leave less than STRETCH_LEFTOVER of the middle band takes all of it.
func _size_for(type: StringName, band: Dictionary, row: int, x: int) -> Vector2i:
	var info := RoomTypes.info(type)
	var short := _scaled(info.short)
	var long := _scaled(info.long)
	var room_depth := _row_depth(band, row)
	var w := 0
	var d := 0
	if long[0] <= room_depth:
		d = rng.randi_range(long[0], mini(long[1], room_depth))
		w = rng.randi_range(short[0], short[1])
	elif short[0] <= room_depth:
		d = rng.randi_range(short[0], mini(short[1], room_depth))
		w = rng.randi_range(long[0], long[1])
	else:
		return Vector2i.ZERO
	if row in [Row.PORT, Row.STAR] and d > room_depth - STRETCH_LEFTOVER:
		d = room_depth
	return Vector2i(w, d)


func _scaled(range_pair: Array) -> Array:
	return [maxi(3, roundi(range_pair[0] * cfg.room_scale)), maxi(3, roundi(range_pair[1] * cfg.room_scale))]


func _row_depth(band: Dictionary, row: int) -> int:
	match row:
		Row.PORT, Row.STAR:
			return band.mid_z1 - band.mid_z0
		Row.PORT_FLANK:
			return band.psz - 2
		_:
			return depth - 1 - (band.ssz + 3)


## Whether `rect` keeps its distance: `room_gap` from every room (a suite's own
## members are laid one wall apart by `_lay`, not checked against each other),
## one wall from every spine and cross-corridor.
func _free(rect: Rect2i) -> bool:
	if rect.position.x < 1 or rect.position.y < 1 or rect.end.x > width - 1 or rect.end.y > depth - 1:
		return false
	var grown := rect.grow(cfg.room_gap)
	for i in gen._rooms.size():
		if grown.intersects(gen._rooms[i]):
			return false
	var near := rect.grow(1)
	for c in _corridor_rects:
		if near.intersects(c.rect):
			return false
	return true


## A spot's score (plan C.3): neighbour weights to rooms already placed, an
## anchor's pull to the middle of its band, and a little for packing tight.
func _score(band: Dictionary, row: int, rects: Array, members: Array, anchor: bool) -> float:
	var score := 0.0
	for k in rects.size():
		var rect: Rect2i = rects[k]
		for i in gen._rooms.size():
			if gen._room_is_corridor[i]:
				continue
			var gap := _gap(rect, gen._rooms[i])
			if gap <= NEAR_TILES:
				score += RoomTypes.neighbour_weight(members[k], gen._room_types[i]) * (1.0 if gap <= 2 else 0.5)
	var first: Rect2i = rects[0]
	var last: Rect2i = rects[rects.size() - 1]
	if anchor:
		var mid: float = (band.x0 + band.x1) * 0.5
		var centre: float = (first.position.x + last.end.x) * 0.5
		score -= absf(centre - mid) / maxf(1.0, band.x1 - band.x0) * 6.0
	score -= _left_gap(band, row, first) * 0.15
	return score + rng.randf() * 0.05


## Tiles of row left unused just before `rect` — waste the packing score charges.
func _left_gap(band: Dictionary, row: int, rect: Rect2i) -> int:
	var edge: int = band.x0
	for i in gen._rooms.size():
		var m: Dictionary = meta.get(i, {})
		if m.is_empty() or gen._room_is_corridor[i] or not _same_side(m.row, row):
			continue
		var r := gen._rooms[i]
		if r.end.x <= rect.position.x:
			edge = maxi(edge, r.end.x + cfg.room_gap)
	return maxi(0, rect.position.x - edge)


## Edge-to-edge tiles between two rects (0 when they touch or overlap).
static func _gap(a: Rect2i, b: Rect2i) -> int:
	var dx := maxi(0, maxi(b.position.x - a.end.x, a.position.x - b.end.x))
	var dz := maxi(0, maxi(b.position.y - a.end.y, a.position.y - b.end.y))
	return maxi(dx, dz)


## Filler (plan C.4): storage closets and elevator lobbies in whatever the band
## has left, until it misses FILLER_MISSES times running.
func _fill_utility(band_index: int) -> void:
	var misses := 0
	while misses < FILLER_MISSES:
		var type: StringName = &"storage_closet" if rng.randf() < 0.75 else &"elevator_lobby"
		if _place_unit(band_index, [type], []):
			misses = 0
		else:
			misses += 1


func _add_room(rect: Rect2i, type: StringName, row: int, band_index: int, suite: int, inner: bool) -> void:
	var index := gen._rooms.size()
	gen._rooms.append(rect)
	gen._room_is_corridor.append(false)
	gen._room_types.append(type)
	meta[index] = {"row": row, "band": band_index, "suite": suite, "inner": inner}
	_counts[type] = _counts.get(type, 0) + 1


## Plan C.7: every band holds every room its zone requires.
func _required_present() -> bool:
	if _counts.get(&"bunk_room", 0) > 0:
		var berthing := 1 if mixed or primary != RoomTypes.Zone.HABITATION else (3 if width * depth >= cfg.hangar_area_large else 2)
		if _counts.get(&"bathroom", 0) < berthing or _counts.get(&"bunk_room", 0) < berthing * (1 if mixed else 2):
			return false
	for i in bands.size():
		var have := {}
		for idx: int in meta:
			if meta[idx].band == i:
				have[gen._room_types[idx]] = true
		for t: StringName in RoomTypes.ZONE_REQUIRED.get(bands[i].zone, []):
			if not have.has(t):
				return false
	return true


func _append_corridors() -> void:
	port_spine = _append_corridor(_merged("port"), RoomTypes.SPINE)
	star_spine = _append_corridor(_merged("star"), RoomTypes.SPINE)
	for c in _corridor_rects:
		if c.kind == "cross":
			c.index = _append_corridor(c.rect, RoomTypes.CORRIDOR)
			crosses.append(c.index)
			gen._links.append([port_spine, c.index])
			gen._links.append([star_spine, c.index])


func _merged(kind: String) -> Rect2i:
	var out := Rect2i()
	for c in _corridor_rects:
		if c.kind == kind:
			out = c.rect if out.size == Vector2i.ZERO else out.merge(c.rect)
	return out


func _append_corridor(rect: Rect2i, type: StringName) -> int:
	var index := gen._rooms.size()
	gen._rooms.append(rect)
	gen._room_is_corridor.append(true)
	gen._room_types.append(type)
	return index


# --- Doors (plan C.5, C.6) ---------------------------------------------------------
#
# A door is an opening punched through the wall between two spaces, its cells
# Terrain.DOOR like every generated entrance. One onto a spine or a
# cross-corridor belongs to that corridor (as a corridor's entrances always
# have); one between two rooms — a suite's internal door, or a loop between
# neighbours — is a little corridor region of its own, the same shape
# MapData.compute_rooms gives a doorway in a hand-authored deck.


func _place_doors() -> void:
	# A suite's internal doors first: they are what a one-door member like the
	# cold store uses instead of a door of its own.
	var rooms := meta.keys()
	rooms.sort()
	for i: int in rooms:
		var m: Dictionary = meta[i]
		if m.suite < 0:
			continue
		var next := _next_in_suite(i)
		if next >= 0:
			_inner_door(i, next)
	# Then one door onto the spine for every room, bay included, except a member
	# whose only door is inside its suite, and a one-door room that already has it.
	for i: int in rooms:
		var m: Dictionary = meta[i]
		if m.inner and doors.get(i, 0) > 0:
			continue
		if RoomTypes.doors_of(gen._room_types[i]) == RoomTypes.Doors.ONE and doors.get(i, 0) > 0:
			continue
		var spine_row: int = Row.STAR if m.row == Row.STAR else (Row.STAR_FLANK if m.row == Row.STAR_FLANK else Row.PORT)
		if m.row == Row.PORT_FLANK:
			spine_row = Row.PORT_FLANK
		var hangar := gen._hangar_rooms.find(i)
		var at := -1
		if hangar >= 0:
			var pad: Vector3i = gen._hangar_pads[hangar][0]
			at = pad.x - 1
		_spine_door(i, spine_row, at)
		if m.row == Row.FULL:
			_spine_door(i, Row.STAR, -1)
	# A through-room (TWO_PLUS) with one door gets a second: onto a cross-corridor
	# it backs onto, else further along its spine.
	for i: int in rooms:
		if RoomTypes.doors_of(gen._room_types[i]) != RoomTypes.Doors.TWO_PLUS or doors.get(i, 0) >= 2:
			continue
		if not _cross_door(i):
			var m: Dictionary = meta[i]
			var row: int = Row.STAR if m.row in [Row.STAR, Row.STAR_FLANK] else Row.PORT
			if m.row == Row.PORT_FLANK:
				row = Row.PORT_FLANK
			elif m.row == Row.STAR_FLANK:
				row = Row.STAR_FLANK
			_spine_door(i, row, -2)
	# Loops (plan C.5's "side passages and loops"): neighbours one gap apart in a
	# row, now and then, where the door rules and the bans allow.
	for i: int in rooms:
		var j := _row_neighbour(i)
		if j < 0 or rng.randf() >= cfg.extra_link_ratio:
			continue
		if _loop_allowed(i, j):
			_loop_door(i, j)
	# And a second way into every hangar bay, half the time.
	for h: int in gen._hangar_rooms:
		if rng.randf() < 0.5:
			var m: Dictionary = meta[h]
			_spine_door(h, m.row, -2)


func _next_in_suite(i: int) -> int:
	var m: Dictionary = meta[i]
	var rect := gen._rooms[i]
	for j: int in meta:
		if j != i and meta[j].suite == m.suite and gen._rooms[j].position.x == rect.end.x + 1:
			return j
	return -1


## The next room along the same row, exactly `room_gap` walls away and sharing
## at least two tiles of wall height, or -1.
func _row_neighbour(i: int) -> int:
	var m: Dictionary = meta[i]
	var rect := gen._rooms[i]
	for j: int in meta:
		if j == i or not _same_side(meta[j].row, m.row) or meta[j].band != m.band:
			continue
		var other := gen._rooms[j]
		if other.position.x == rect.end.x + cfg.room_gap:
			var z0 := maxi(rect.position.y, other.position.y)
			var z1 := mini(rect.end.y, other.end.y)
			if z1 - z0 >= 2:
				return j
	return -1


## Plan C.5 and C.6 for a loop between rooms `a` and `b`: neither is a one-door
## room, fuel storage only ever opens onto engineering, bunk rooms never onto
## machinery or cargo (any pair the neighbour weights push apart), and no hangar.
func _loop_allowed(a: int, b: int) -> bool:
	var ta := gen._room_types[a]
	var tb := gen._room_types[b]
	if gen._hangar_rooms.has(a) or gen._hangar_rooms.has(b):
		return false
	for t in [ta, tb]:
		if RoomTypes.doors_of(t) == RoomTypes.Doors.ONE:
			return false
	if not fuel_link_ok(ta, tb):
		return false
	return RoomTypes.neighbour_weight(ta, tb) >= 0.0


## Plan C.6, the one hard ban: fuel storage connects only to Engineering rooms
## or a spine. Static so the test can hold the deck to it.
static func fuel_link_ok(a: StringName, b: StringName) -> bool:
	if a == &"fuel_storage" and RoomTypes.zone_of(b) != RoomTypes.Zone.ENGINEERING:
		return false
	if b == &"fuel_storage" and RoomTypes.zone_of(a) != RoomTypes.Zone.ENGINEERING:
		return false
	return true


## A door from room `i` onto the spine on `row`'s side. `at` is the door's first
## column, -1 for the middle of the shared wall, -2 for as far from the room's
## existing doors as it will go.
func _spine_door(i: int, row: int, at: int) -> void:
	var rect := gen._rooms[i]
	var span := _door_columns(rect, at)
	var cells: Array[Vector3i] = []
	for x in span:
		var band := _band_at(x)
		var z_from: int
		var z_to: int  # exclusive
		match row:
			Row.PORT, Row.FULL:
				z_from = band.psz + 2
				z_to = rect.position.y
			Row.STAR:
				z_from = rect.end.y
				z_to = band.ssz
			Row.PORT_FLANK:
				z_from = rect.end.y
				z_to = band.psz
			_:
				z_from = band.ssz + 2
				z_to = rect.position.y
		for z in range(z_from, z_to):
			cells.append(Vector3i(x, 0, z))
	var spine := star_spine if row in [Row.STAR, Row.STAR_FLANK] else port_spine
	if at == -2 and not _can_open(cells):
		# A narrow room may put the centred door against the old end heuristic.
		# Try every other opening on this wall before giving up.
		for x in range(rect.position.x, rect.end.x - cfg.entrance_width + 1):
			_spine_door(i, row, x)
			if doors.get(i, 0) >= 2:
				return
		return
	if _open(cells, spine):
		gen._links.append([i, spine])
		doors[i] = doors.get(i, 0) + 1


## The `entrance_width` columns of a door along `rect`'s long wall: from `at`,
## its middle (-1), or the end of the wall furthest from any door it has (-2).
func _door_columns(rect: Rect2i, at: int) -> Array[int]:
	var w := mini(cfg.entrance_width, rect.size.x)
	var lo := rect.position.x
	var hi := rect.end.x - w
	var start: int
	if at >= 0:
		start = clampi(at, lo, hi)
	elif at == -1:
		start = lo + (rect.size.x - w) / 2
	else:
		var left_used := false
		for z in range(rect.position.y - 2, rect.end.y + 2):
			for x in range(lo, lo + rect.size.x / 2):
				if data.terrain_at(Vector3i(x, 0, z)) == MapData.Terrain.DOOR:
					left_used = true
		start = hi - 1 if left_used else lo + 1
		start = clampi(start, lo, hi)
	var out: Array[int] = []
	for k in w:
		out.append(start + k)
	return out


func _band_at(x: int) -> Dictionary:
	for b in bands:
		if x < b.b1 + 2:
			return b
	return bands[bands.size() - 1]


## A door from a room onto the cross-corridor at either end of its band, if it
## backs onto one. True if it made one.
func _cross_door(i: int) -> bool:
	var m: Dictionary = meta[i]
	if m.band < 0 or not (m.row in [Row.PORT, Row.STAR, Row.FULL]):
		return false
	var band: Dictionary = bands[m.band]
	var rect := gen._rooms[i]
	var wall_x := -1
	if rect.position.x == band.x0:
		wall_x = band.x0 - 1
	elif rect.end.x == band.x1:
		wall_x = band.x1
	if wall_x < 0:
		return false
	var cross := -1
	for c in _corridor_rects:
		if c.kind == "cross" and (c.rect.end.x == wall_x or c.rect.position.x == wall_x + 1):
			cross = c.index
	if cross < 0:
		return false
	var z := rect.position.y + (rect.size.y - 2) / 2
	if _open([Vector3i(wall_x, 0, z), Vector3i(wall_x, 0, z + 1)], cross):
		gen._links.append([i, cross])
		doors[i] = doors.get(i, 0) + 1
		return true
	return false


## A suite's internal door: through the one-tile wall between neighbours `a` and
## `b`, its cells a corridor region of their own.
func _inner_door(a: int, b: int) -> void:
	var ra := gen._rooms[a]
	var rb := gen._rooms[b]
	var z0 := maxi(ra.position.y, rb.position.y)
	var z1 := mini(ra.end.y, rb.end.y)
	if z1 - z0 < 2:
		return
	var z := z0 + (z1 - z0 - 2) / 2
	var x := ra.end.x
	var cells: Array[Vector3i] = [Vector3i(x, 0, z), Vector3i(x, 0, z + 1)]
	_door_region(a, b, cells, Rect2i(x, z, 1, 2))


## A loop between row neighbours `a` and `b`, through both walls of the gap.
func _loop_door(a: int, b: int) -> void:
	var ra := gen._rooms[a]
	var rb := gen._rooms[b]
	var z0 := maxi(ra.position.y, rb.position.y)
	var z1 := mini(ra.end.y, rb.end.y)
	var z := z0 + rng.randi_range(0, z1 - z0 - 2)
	var cells: Array[Vector3i] = []
	for x in range(ra.end.x, rb.position.x):
		cells.append(Vector3i(x, 0, z))
		cells.append(Vector3i(x, 0, z + 1))
	_door_region(a, b, cells, Rect2i(ra.end.x, z, rb.position.x - ra.end.x, 2))


func _door_region(a: int, b: int, cells: Array[Vector3i], rect: Rect2i) -> void:
	var region := gen._rooms.size()
	if not _open(cells, region):
		return
	gen._rooms.append(rect)
	gen._room_is_corridor.append(true)
	gen._room_types.append(RoomTypes.CORRIDOR)
	gen._links.append([a, region])
	gen._links.append([region, b])
	doors[a] = doors.get(a, 0) + 1
	doors[b] = doors.get(b, 0) + 1


## Opens `cells` (all solid wall, none claimed) as DOOR terrain belonging to
## `region`. False, opening nothing, if any of them is not wall.
func _open(cells: Array[Vector3i], region: int) -> bool:
	if not _can_open(cells):
		return false
	for pos in cells:
		data.get_cell(pos).terrain = MapData.Terrain.DOOR
		data.room_of[pos] = region
	return true


func _can_open(cells: Array[Vector3i]) -> bool:
	if cells.is_empty():
		return false
	for pos in cells:
		if data.terrain_at(pos) != MapData.Terrain.WALL or data.room_of.has(pos):
			return false
	return true


func _shuffle(items: Array) -> void:
	gen._shuffle(items)
