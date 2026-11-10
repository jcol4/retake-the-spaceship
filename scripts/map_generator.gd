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

enum DeckSource { PLOT, GENERATED }

class Config:
	var deck_source: int = DeckSource.PLOT
	var enemy_faction: StringName = &"aliens"
	# 84x56: the Medium contract (CampaignEconomy.DECK_DIMENSIONS), one step up
	# from 72x48 when rooms got types (ROOM_THEMES_PLAN.md B.2) — a themed deck
	# lays its hangars along both flanks and two passageways the length of the
	# hull before the first room goes in.
	var width := 84
	var depth := 56
	# ROOM_THEMES_PLAN.md: typed rooms in zone bands off two spines (DeckLayout).
	# False gives back the untyped generator below — scattered rooms, an MST of
	# corridors — kept for comparison and for tests written against it.
	var themed_rooms := true
	# Deck profile (plan B.1). -1 rolls it from the seed (`DeckLayout.PRIMARY_ODDS`);
	# a contract names it so the board can show it (plan F.6). RoomTypes.Zone values.
	var profile_primary := -1
	var profile_secondary := -1
	# One band of each zone and no suite larger than two rooms: every Small deck
	# (plan "Deck profiles").
	var mixed_profile := false
	# Every room size range is multiplied by this (rounded, never under 3). A
	# Small deck's middle band is too shallow for the plan's full-size engine
	# room, so its contracts shrink the rooms rather than the hangars.
	var room_scale := 1.0
	var objective_kind := -1
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
	# Per non-spawn room, chance it gets an enemy. Lower under the fodder-only
	# roster, where an enemy room means a whole horde (main.gd `_spawn_hordes`):
	# fewer, bigger encounters, with empty rooms between to fall back through.
	var enemy_room_chance := 0.35 if AlienPresets.FODDER_ONLY else 0.6

	# Hangars (GDD §7.2): 3–4 per deck, scaled by deck area — see `_hangar_count`.
	# Zero for both turns hangars off entirely, which gives back the old
	# clear-out deck (main.gd keys `clear_out_mode` on whether any hangar exists).
	var hangar_count_min := 3
	var hangar_count_max := 4
	# Deck areas (width x depth) between which the chance of the extra hangar
	# rises from 0 to 1. Small (72x48, 3456) gets three; the default/Medium 84x56
	# (4704) sits about halfway, so three or four; Large (96x64, 6144) always four.
	var hangar_area_small := 3456
	var hangar_area_large := 6144
	# Per-axis hangar size band, and on top of it the AREA rule (GDD §7.2): a bay
	# is 3–4x its landing zone (MapData.HANGAR_BAY_AREA_MIN/MAX of
	# `hangar_landing_zone_area` — the 5x5 ship space plus the 3x3 square, with a
	# tile of apron: 7x10 = 70, so 210–280 tiles). 12 is the floor along the ramp
	# axis: one tile behind the pad, the 5-tile pad, the 3-tile square, and three
	# rows in front of it to fight from. 22 lets a long, narrow bay pass the area
	# rule as well as a squarish one.
	var hangar_min_size := 12
	var hangar_max_size := 22
	# The bay's own dressing (GDD §7.2): wrecked ships — full-height, sight- and
	# light-blocking, indestructible heavy cover (MapData.wrecks) — and then more
	# ordinary cover than an ordinary room gets, all of it kept off the ship's
	# space and the square. A bay is the place the squad holds while the ship
	# comes in, so it must never be a bare floor.
	var hangar_wrecks_min := 1
	var hangar_wrecks_max := 2
	var hangar_cover_min := 4
	var hangar_cover_max := 7
	# Candidate rects tried per hangar during farthest-point sampling: more is a
	# better spread for a few microseconds more.
	var hangar_candidates := 40
	# Whole-deck rerolls allowed when the reachability check fails (see
	# `generate`). Generous because a reroll costs a millisecond.
	var max_rerolls := 32

	# Loot containers (extraction plan 3.2). Ordinary rooms only — never a hangar
	# bay, never a corridor. Each eligible room gets crates with this chance, 1 to
	# `loot_per_room_max` of them, contents rolled by ItemPresets.roll_container.
	# PLACEHOLDER density (decisions log): about one room in two holds something
	# (~7 crates on the default deck), which is enough that "is it worth checking
	# that room" is a real question without every room being a stop.
	var loot_room_chance := 0.5
	var loot_per_room_max := 2

	# Rival merc crew (extraction plan Phase 8, GDD §11.10). With this chance a
	# deck carries one squad of `merc_squad_size`, spawned together in one
	# ordinary room away from the insertion (same safe-room rule as the aliens)
	# and from any alien spawn, so the crew starts on its job rather than in a
	# firefight. PLACEHOLDER: a little under half the decks — often enough that a
	# rival crew is a thing a run plans around, not so often that every deck is
	# a merc deck. 0 turns them off (every pre-Phase-8 deck, bar the crew).
	var merc_squad_chance := 0.4
	var merc_squad_size := 3


var _cfg: Config
var _rng := RandomNumberGenerator.new()
var _rooms: Array[Rect2i] = []
var _room_is_corridor: Array[bool] = []  # parallel to _rooms
## Parallel to _rooms: each one's RoomTypes key. The untyped path fills it with
## GENERIC, CORRIDOR and HANGAR; DeckLayout names every room.
var _room_types: Array[StringName] = []
## Set by DeckLayout when a band could not fit a room its zone requires (plan
## C.7): `generate` rerolls, like an unreachable hangar.
var _layout_failed := false
var _links: Array = []  # [a, b] index pairs into _rooms, for stats only
## Indices into `_rooms` of the hangar bays, in placement order. Hangars are
## reserved first (see `_place_hangars`), so these are always the lowest indices.
var _hangar_rooms: Array[int] = []
## Parallel to `_hangar_rooms`: [pad_center: Vector3i, ramp_side: int].
var _hangar_pads: Array = []
## Index into `_hangar_rooms` of the insertion hangar, or -1 on a deck without any.
var _insertion := -1


## Deterministic in `map_seed`: every peer generating the same seed gets the same
## deck, rerolls included, so co-op still only has to send the seed.
##
## A reroll is a fresh generation from a seed DERIVED from `map_seed` and the
## attempt number, taken when the hangars cannot all be reached from the
## insertion square (`_hangars_reachable`). It exists because corridor carving
## has a known rough edge — a leg crossing a third room is left walled there (see
## `_carve_corridor`) — which on an ordinary room only costs a loop, but on a
## hangar would strand an extraction point. The returned deck keeps the
## REQUESTED seed in `data.seed`; the attempt that produced it is
## `data.generation_attempt`.
static func generate(map_seed: int, cfg: Config = null) -> MapData:
	var config := cfg if cfg != null else Config.new()
	var data: MapData = null
	for attempt in config.max_rerolls + 1:
		var gen := MapGenerator.new()
		gen._cfg = config
		# Attempt 0 is the seed itself, so a deck that passes first time is the
		# same deck any earlier tool asking for this seed would have seen.
		gen._rng.seed = map_seed if attempt == 0 else hash([map_seed, attempt])
		data = gen._run(map_seed)
		data.generation_attempt = attempt
		if config.deck_source == DeckSource.PLOT:
			return data # Authored errors are content gaps, never procedural rerolls.
		# A deck that rolled hangars must also have FIT them: big bays on a crowded
		# deck can leave fewer than the minimum, and "3–4 per deck" (GDD §7.2) is a
		# promise, so that is a reroll like an unreachable one.
		var enough := data.hangars.size() >= config.hangar_count_min \
			or config.hangar_count_max <= 0
		if enough and not gen._layout_failed and gen._hangars_reachable(data):
			return data
	push_warning("MapGenerator: seed %d still has too few or unreachable hangars, or a missing room, after %d rerolls" % [
		map_seed, config.max_rerolls])
	return data


func _run(map_seed: int) -> MapData:
	if _cfg.deck_source == DeckSource.PLOT:
		return _run_plot(map_seed)
	var data := MapData.new()
	data.seed = map_seed
	_fill_hull(data)
	_rooms.clear()
	_room_is_corridor.clear()
	_room_types.clear()
	if _cfg.themed_rooms:
		# Hangars on the flanks, two spines, typed rooms in zone bands, doors
		# (ROOM_THEMES_PLAN.md B and C). Carves as it goes.
		DeckLayout.new(self, data).build()
	else:
		_place_hangars()
		_place_rooms()
		for i in _rooms.size():
			_carve(data, _rooms[i], i)
		_route_corridors(data)
		for i in _rooms.size():
			_room_types.append(RoomTypes.CORRIDOR if _room_is_corridor[i]
				else (RoomTypes.HANGAR if _hangar_rooms.has(i) else RoomTypes.GENERIC))
	data.rooms = _rooms.duplicate()
	data.room_links = _links.duplicate()
	for i in _rooms.size():
		if _room_is_corridor[i]:
			data.corridors.append(i)
	data.room_types = _room_types.duplicate()
	data.ensure_room_types()
	# A rejected layout is never played: avoid dressing it before the reroll.
	if _layout_failed:
		return data
	if _cfg.themed_rooms and _cfg.objective_kind >= 0:
		_choose_objective_insertion(data)
	# After `room_of` is complete, because MapData derives each bay from it.
	for i in _hangar_rooms.size():
		data.add_hangar(_hangar_pads[i][0], _hangar_pads[i][1], i == _insertion)
	_place_spawns(data)
	if _cfg.themed_rooms:
		RoomDressing.roll_conditions(data, _rng)
	_place_cover(data)
	if _cfg.themed_rooms and data.insertion_hangar() != null:
		var safe := _rooms_near_insertion(data, data.insertion_hangar())
		for pos: Vector3i in data.cells:
			var cell: MapData.Cell = data.cells[pos]
			if safe.has(data.room_index_at(pos)) and cell.spawn != MapData.Spawn.PLAYER and cell.spawn != MapData.Spawn.NONE:
				cell.spawn = MapData.Spawn.NONE
				data.worm_counts.erase(pos)
	# Last: crates go where cover and spawns did not, and each one is checked not
	# to cut its room in two (`_place_loot`). Last also keeps every deck that
	# generated before loot existed identical in all but the crates, since the
	# loot rolls come after every other draw on `_rng`.
	_place_loot(data)
	if _cfg.themed_rooms:
		_place_room_keys(data)
		if _cfg.objective_kind == 0 and data.objective_room_hint >= 0:
			var spot := _container_spot(data, data.objective_room_hint)
			if spot != NO_SPOT:
				data.add_container(spot, ItemPresets.roll_container(_rng, RoomTypes.loot_of(data.room_type(data.objective_room_hint))))
	# After the loot, for the same reason the loot comes last: every draw before
	# this one is unchanged, so a seed gives the same deck it always did, plus
	# (sometimes) a merc crew.
	_place_mercs(data)
	data.resolve_stairs()
	return data


func _run_plot(map_seed: int) -> MapData:
	var assembler := PlotAssembler.new()
	var plot := assembler.choose(Vector2i(_cfg.width, _cfg.depth), _cfg.profile_primary, _rng)
	if plot == null:
		var failed := MapData.new()
		failed.seed = map_seed
		failed.layout_errors = assembler.errors.duplicate()
		push_error("; ".join(failed.layout_errors))
		return failed
	var data := assembler.assemble(plot, _rng, [], -1, _cfg.enemy_faction)
	data.seed = map_seed
	data.deck_primary = _cfg.profile_primary
	if data.deck_primary < 0:
		for slot in plot.slots:
			if slot.zone != ParcelData.ZONE_HANGAR:
				data.deck_primary = slot.zone
				break
	data.deck_secondary = _cfg.profile_secondary
	data.deck_mixed = _cfg.mixed_profile
	data.layout_errors = assembler.errors.duplicate()
	if not data.layout_errors.is_empty():
		push_error("; ".join(data.layout_errors))
		return data
	_rooms = data.rooms.duplicate()
	_room_types = data.room_types.duplicate()
	_room_is_corridor.clear()
	for i in _rooms.size():
		_room_is_corridor.append(i in data.corridors)
		if data.room_type(i) == RoomTypes.HANGAR:
			_hangar_rooms.append(i)
			for h in data.hangars:
				if h.room_index == i:
					_hangar_pads.append([h.pad_center, h.ramp_side])
	_insertion = 0
	if _cfg.objective_kind >= 0:
		_choose_objective_insertion(data)
		for i in data.hangars.size(): data.hangars[i].is_insertion = i == _insertion
	var insertion := data.insertion_hangar()
	if insertion != null:
		for i in mini(_cfg.player_spawn_count, insertion.square.size()):
			data.get_cell(insertion.square[i]).spawn = MapData.Spawn.PLAYER
	# Preserve procedural overrun worms, without adding furniture or jitter.
	RoomDressing.seed_overrun(data, _rng)
	if insertion != null:
		var safe := _rooms_near_insertion(data, insertion)
		for pos: Vector3i in data.cells:
			if safe.has(data.room_index_at(pos)) and data.cells[pos].spawn != MapData.Spawn.PLAYER:
				data.cells[pos].spawn = MapData.Spawn.NONE
				data.worm_counts.erase(pos)
	_place_loot(data)
	_place_room_keys(data)
	_place_mercs(data)
	data.resolve_stairs()
	return data


func _choose_objective_insertion(data: MapData) -> void:
	var candidates: Array[int] = []
	for room in _rooms.size():
		if data.room_type(room) in RoomTypes.OBJECTIVE_ROOMS.get(_cfg.objective_kind, []):
			candidates.append(room)
	if candidates.is_empty() or _hangar_rooms.is_empty():
		return
	data.objective_room_hint = candidates[_rng.randi_range(0, candidates.size() - 1)]
	var center := _rooms[data.objective_room_hint].get_center()
	var start := Vector3i(center.x, 0, center.y)
	var distance := {start: 0}
	var queue: Array[Vector3i] = [start]
	var head := 0
	while head < queue.size():
		var at := queue[head]
		head += 1
		for step: Vector3i in MapData.SIDE_STEP:
			var next := at + step
			if not distance.has(next) and data.is_walkable(next):
				distance[next] = distance[at] + 1
				queue.append(next)
	var bays: Array[int] = []
	for i in _hangar_pads.size():
		bays.append(i)
	bays.sort_custom(func(a: int, b: int) -> bool:
		var da: int = distance.get(_hangar_pads[a][0], -1)
		var db: int = distance.get(_hangar_pads[b][0], -1)
		return da > db if da != db else a < b)
	_insertion = bays[_rng.randi_range(0, ceili(bays.size() / 2.0) - 1)]


func _place_room_keys(data: MapData) -> void:
	for room in _rooms.size():
		var type := data.room_type(room)
		if not RoomTypes.is_locked(type):
			continue
		var preferred: Array = [&"security_station"] if type in [&"armory", &"brig"] else [&"comms", &"security_station", &"navigation"]
		var choices: Array[int] = []
		for i in _rooms.size():
			if not _room_is_corridor[i] and not _hangar_rooms.has(i) and not RoomTypes.is_locked(data.room_type(i)):
				choices.append(i)
		choices.sort_custom(func(a: int, b: int) -> bool:
			var pa: int = int(data.room_type(a) in preferred)
			var pb: int = int(data.room_type(b) in preferred)
			return pa > pb if pa != pb else a < b)
		for source in choices:
			var existing: MapData.LootSpot = null
			for container: MapData.LootSpot in data.containers:
				if data.room_index_at(container.pos) == source:
					existing = container
					break
			if existing != null:
				existing.items.append("keycard:" + String(type))
				break
			var spot := _container_spot(data, source)
			if spot != NO_SPOT:
				data.add_container(spot, PackedStringArray(["keycard:" + String(type)]))
				break


func _fill_hull(data: MapData) -> void:
	# Start solid and carve out of it: anything never carved is hull structure,
	# so a bug leaves a compartment sealed rather than open to space.
	for z in _cfg.depth:
		for x in _cfg.width:
			var cell := MapData.Cell.new()
			cell.terrain = MapData.Terrain.WALL
			data.set_cell(Vector3i(x, 0, z), cell)


# --- Room placement ----------------------------------------------------------


## Hangars go in FIRST, before any ordinary room, and are spread with
## farthest-point sampling: each new hangar is the candidate rect whose nearest
## already-placed hangar is farthest away. Placed after the rooms instead, they
## would take whatever gaps rejection sampling left, which on a crowded deck is
## none, and two hangars sharing a corner of the deck would make "which one do we
## extract from" a non-question. The insertion hangar is then picked at random
## among them (GDD §7.2), and the corridor router treats the bays as ordinary
## rooms from here on.
func _place_hangars() -> void:
	_hangar_rooms.clear()
	_hangar_pads.clear()
	_insertion = -1
	var count := _hangar_count()
	var interior := Rect2i(1, 1, _cfg.width - 2, _cfg.depth - 2)
	var lo := _cfg.hangar_min_size
	var hi := mini(_cfg.hangar_max_size, mini(interior.size.x, interior.size.y))
	if count <= 0 or hi < lo:
		return
	var lz := float(MapData.hangar_landing_zone_area())
	var area_lo := ceili(lz * MapData.HANGAR_BAY_AREA_MIN)
	var area_hi := floori(lz * MapData.HANGAR_BAY_AREA_MAX)
	for _h in count:
		var best := Rect2i()
		var best_score := -1.0
		for _c in _cfg.hangar_candidates:
			var w := _rng.randi_range(lo, hi)
			# The depth is drawn from what keeps w*d inside the area band, so every
			# candidate is a legal bay size rather than most being thrown away.
			var d_lo := maxi(lo, ceili(float(area_lo) / w))
			var d_hi := mini(hi, floori(float(area_hi) / w))
			if d_hi < d_lo:
				continue
			var d := _rng.randi_range(d_lo, d_hi)
			var x := _rng.randi_range(interior.position.x, interior.position.x + interior.size.x - w)
			var z := _rng.randi_range(interior.position.y, interior.position.y + interior.size.y - d)
			var candidate := Rect2i(x, z, w, d)
			if _overlaps_any(candidate, _cfg.room_gap):
				continue
			# The first hangar has nothing to be far from; any legal rect will do.
			var score := 0.0 if _rooms.is_empty() else _distance_to_nearest_room(candidate)
			if score > best_score:
				best_score = score
				best = candidate
		if best_score < 0.0:
			break  # the deck is full; fewer hangars beats none
		_hangar_rooms.append(_rooms.size())
		_hangar_pads.append(_pad_for(best))
		_rooms.append(best)
		_room_is_corridor.append(false)
	if not _hangar_rooms.is_empty():
		_insertion = _rng.randi_range(0, _hangar_rooms.size() - 1)


## 3 or 4 (Config), the fourth more likely the bigger the deck. A roll rather
## than a threshold so two decks of the same size still differ.
func _hangar_count() -> int:
	var area := float(_cfg.width * _cfg.depth)
	var span := float(maxi(1, _cfg.hangar_area_large - _cfg.hangar_area_small))
	var t := clampf((area - _cfg.hangar_area_small) / span, 0.0, 1.0)
	var extra := _cfg.hangar_count_max - _cfg.hangar_count_min
	var count := _cfg.hangar_count_min
	for _i in extra:
		if _rng.randf() < t:
			count += 1
	return count


func _distance_to_nearest_room(rect: Rect2i) -> float:
	var centre := Vector2(rect.get_center())
	var best := INF
	for room in _rooms:
		best = minf(best, centre.distance_to(Vector2(room.get_center())))
	return best


## [pad centre, side] for a hangar whose ramp must face `side` — a themed deck's
## flank bays face inward, whatever their offset from the middle. The pad sits
## one tile off the back wall, centred across the bay, as in `_pad_for`.
func _pad_facing(rect: Rect2i, side: int) -> Array:
	var cross_x := rect.position.x + rect.size.x / 2
	var cross_z := rect.position.y + rect.size.y / 2
	var back_gap := 1 + MapData.HANGAR_PAD_RADIUS
	var pad: Vector3i
	match side:
		MapData.Side.EAST: pad = Vector3i(rect.position.x + back_gap, 0, cross_z)
		MapData.Side.WEST: pad = Vector3i(rect.position.x + rect.size.x - 1 - back_gap, 0, cross_z)
		MapData.Side.SOUTH: pad = Vector3i(cross_x, 0, rect.position.y + back_gap)
		_: pad = Vector3i(cross_x, 0, rect.position.y + rect.size.y - 1 - back_gap)
	return [pad, side]


## Where the pad goes in a hangar rect, and which way its ramp faces: [pad
## centre, MapData.Side].
##
## The ramp faces the deck's middle, along whichever axis the bay is offset
## from it most — the square then opens toward where the rest of the ship is,
## which is where the corridors come from, rather than into a back corner. The
## pad sits one tile off the back wall, centred across the bay. A bay too
## shallow along the chosen axis for pad + square (6 tiles) plus that tile is
## impossible at `hangar_min_size` >= 7, so there is no fallback.
func _pad_for(rect: Rect2i) -> Array:
	var deck_mid := Vector2(_cfg.width, _cfg.depth) / 2.0
	var offset := Vector2(rect.get_center()) - deck_mid
	var side: int
	if absf(offset.x) >= absf(offset.y):
		side = MapData.Side.WEST if offset.x > 0.0 else MapData.Side.EAST
	else:
		side = MapData.Side.NORTH if offset.y > 0.0 else MapData.Side.SOUTH
	var cross_x := rect.position.x + rect.size.x / 2
	var cross_z := rect.position.y + rect.size.y / 2
	# Back row of the pad one tile clear of the wall, so it can be walked round.
	var back_gap := 1 + MapData.HANGAR_PAD_RADIUS
	var pad: Vector3i
	match side:
		MapData.Side.EAST: pad = Vector3i(rect.position.x + back_gap, 0, cross_z)
		MapData.Side.WEST: pad = Vector3i(rect.position.x + rect.size.x - 1 - back_gap, 0, cross_z)
		MapData.Side.SOUTH: pad = Vector3i(cross_x, 0, rect.position.y + back_gap)
		_: pad = Vector3i(cross_x, 0, rect.position.y + rect.size.y - 1 - back_gap)
	return [pad, side]


## The generation check `generate` rerolls on: a 4-way flood from the insertion
## square over PASSABLE tiles (walkable and not under a loot crate) must reach
## every tile of every other hangar's square. 4-way is stricter than the game's
## 8-way movement, so a pass here is a pass in play. A deck with no hangars passes
## trivially. Crates are placed so they cannot cut a path (`_place_loot`); this
## counting them as walls is the belt to that's braces.
func _hangars_reachable(data: MapData) -> bool:
	var start := data.insertion_hangar()
	if start == null:
		return data.hangars.is_empty()
	var seen: Dictionary = {}
	var frontier: Array[Vector3i] = []
	for pos in start.square:
		if data.is_passable(pos):
			seen[pos] = true
			frontier.append(pos)
	while not frontier.is_empty():
		var cur: Vector3i = frontier.pop_back()
		for step: Vector3i in MapData.SIDE_STEP:
			var n := cur + step
			if not seen.has(n) and data.is_passable(n):
				seen[n] = true
				frontier.append(n)
	for h in data.hangars:
		for pos in h.square:
			if not seen.has(pos):
				return false
	return true


func _place_rooms() -> void:
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
	# The squad deploys onto the insertion square (GDD §7.1 step 2), the tiles the
	# dropship's ramp comes down on. A deck generated with hangars switched off
	# falls back to the old rule: the first real room placed.
	var player_room := real_rooms[0]
	var cells := _room_cells(data, player_room)
	var safe_rooms: Dictionary = {}
	var insertion := data.insertion_hangar()
	if insertion != null:
		player_room = insertion.room_index
		cells = insertion.square.duplicate()
		safe_rooms = _rooms_near_insertion(data, insertion)
	else:
		safe_rooms[player_room] = true
	_shuffle(cells)
	for i in mini(_cfg.player_spawn_count, cells.size()):
		data.get_cell(cells[i]).spawn = MapData.Spawn.PLAYER
	if _cfg.themed_rooms:
		_place_faction_enemies(data, real_rooms, safe_rooms)
		return
	for idx in real_rooms:
		if safe_rooms.has(idx):
			continue
		if _rng.randf() > _cfg.enemy_room_chance:
			continue
		var room_cells := _room_cells(data, idx)
		if room_cells.is_empty():
			continue
		data.get_cell(room_cells[_rng.randi_range(0, room_cells.size() - 1)]).spawn = MapData.Spawn.ENEMY


## The rival merc crew (Phase 8): with `merc_squad_chance`, one squad in one
## ordinary room — not a hangar, not the insertion's neighbourhood (the alien
## rule in `_place_spawns`), not a room holding an alien spawn — on free floor
## (no crate, cover, fixture, stair or other spawn). One draw for the chance, one
## for the room, then the tiles shuffled: all on `_rng`, so the crew is the same
## on every peer. main.gd makes one squad per room, so they are one crew.
func _place_mercs(data: MapData) -> void:
	if _cfg.merc_squad_chance <= 0.0 or _cfg.merc_squad_size <= 0:
		return
	if _rng.randf() >= _cfg.merc_squad_chance:
		return
	var insertion := data.insertion_hangar()
	var unsafe := {}
	if insertion != null:
		unsafe = _rooms_near_insertion(data, insertion)
	var rooms: Array = []
	var room_spots: Dictionary = {}
	for i in _rooms.size():
		if _room_is_corridor[i] or _hangar_rooms.has(i) or unsafe.has(i):
			continue
		var spots: Array = []
		var has_spawn := false
		for pos in _room_cells(data, i):
			var cell := data.get_cell(pos)
			if cell.spawn != MapData.Spawn.NONE:
				has_spawn = true
				break
			if cell.terrain == MapData.Terrain.FLOOR and cell.fixture == MapData.Fixture.NONE \
					and not cell.stair and data.is_passable(pos):
				spots.append(pos)
		if has_spawn or spots.size() < _cfg.merc_squad_size * 2:
			continue
		rooms.append(i)
		room_spots[i] = spots
	if rooms.is_empty():
		return
	var pool: Array = rooms
	if _cfg.themed_rooms and _rng.randf() < 0.6:
		var homes: Array = rooms.filter(func(i: int) -> bool: return RoomTypes.is_home_of(data.room_type(i), RoomTypes.MERCS))
		if not homes.is_empty():
			pool = homes
	var room: int = pool[_rng.randi_range(0, pool.size() - 1)]
	var spots: Array = room_spots[room]
	_shuffle(spots)
	for n in mini(_cfg.merc_squad_size, spots.size()):
		data.get_cell(spots[n]).spawn = MapData.Spawn.MERC


func _place_faction_enemies(data: MapData, real_rooms: Array[int], safe: Dictionary) -> void:
	var eligible: Array[int] = []
	for room in real_rooms:
		if not safe.has(room):
			eligible.append(room)
	if _cfg.enemy_room_chance <= 0.0:
		return
	for faction: StringName in [RoomTypes.ALIENS, RoomTypes.ROBOTS]:
		var count := roundi(eligible.size() * _cfg.enemy_room_chance) if faction == RoomTypes.ALIENS else clampi(eligible.size() / 10, 1, 4)
		for _n in count:
			var homes: Array[int] = []
			for room in eligible:
				if RoomTypes.is_home_of(data.room_type(room), faction):
					homes.append(room)
			var pool: Array[int] = homes if not homes.is_empty() and _rng.randf() < 0.6 else eligible
			if pool.is_empty():
				break
			var room := pool[_rng.randi_range(0, pool.size() - 1)]
			var spots := _room_cells(data, room).filter(func(pos: Vector3i) -> bool:
				return data.is_walkable(pos) and data.get_cell(pos).spawn == MapData.Spawn.NONE)
			if spots.is_empty():
				eligible.erase(room)
				continue
			var at: Vector3i = spots[_rng.randi_range(0, spots.size() - 1)]
			data.get_cell(at).spawn = MapData.Spawn.ENEMY if faction == RoomTypes.ALIENS else MapData.Spawn.SAGITTARII


## Tiles walked from the insertion square within which a themed deck keeps rooms
## enemy-free: about one room's depth off the spine either side of the bay door.
const SAFE_WALK := 14


## The insertion bay and the rooms around it that start enemy-free (and hold no
## merc crew), as {room index: true}. The plan asks for the bay and "its
## corridor neighbours", so a squad does not step off the ramp straight into the
## next room's line of fire.
##
## On the untyped deck that is the rooms one corridor link away. A themed deck
## joins every room to a spine that runs the length of the hull, so "one
## corridor away" would be the whole deck: there it is every room with a tile
## within SAFE_WALK steps of the square.
func _rooms_near_insertion(data: MapData, insertion: MapData.Hangar) -> Dictionary:
	var safe := {insertion.room_index: true}
	if not _cfg.themed_rooms:
		for link: Array in _links:
			if link[0] == insertion.room_index:
				safe[link[1]] = true
			elif link[1] == insertion.room_index:
				safe[link[0]] = true
		return safe
	var dist := {}
	var frontier: Array[Vector3i] = []
	for pos in insertion.square:
		dist[pos] = 0
		frontier.append(pos)
	var head := 0
	while head < frontier.size():
		var cur: Vector3i = frontier[head]
		head += 1
		var room := data.room_index_at(cur)
		if room >= 0 and not _room_is_corridor[room]:
			safe[room] = true
		if dist[cur] >= SAFE_WALK:
			continue
		for step: Vector3i in MapData.SIDE_STEP:
			var n := cur + step
			if not dist.has(n) and data.is_walkable(n):
				dist[n] = dist[cur] + 1
				frontier.append(n)
	return safe


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
		if _hangar_rooms.has(i):
			_place_hangar_cover(data, i)
		else:
			if not _cfg.themed_rooms or not RoomDressing.place(data, i, _rng, _cfg.cover_max_per_room):
				_place_room_cover(data, _rooms[i])


## The rect a hangar's cover must stay out of: the pad (the ship's whole reserved
## space) and the square, as one bounding rect (they are adjacent along the ramp
## axis), so nothing ever sits where the ship lands or where a soldier must stand
## to extract. Empty for an ordinary room. The placement rule additionally keeps
## a tile of gap to it, as it does between pieces, so the square can always be
## walked onto from any side.
func _hangar_keep_clear(room_index: int) -> Rect2i:
	var at := _hangar_rooms.find(room_index)
	if at < 0:
		return Rect2i()
	return MapData.hangar_reserved_rect(_hangar_pads[at][0], _hangar_pads[at][1])


## Wrecked ships: a hull section or an engine block, 2–3 tiles by 3–4.
const WRECK_SHAPES: Array[Vector2i] = [
	Vector2i(2, 3), Vector2i(3, 3), Vector2i(2, 4), Vector2i(3, 4),
]
## A hangar's pieces are worth more tries than an ordinary room's: the bay is
## big, but it is also the one room whose cover is guaranteed (GDD §7.2), so a
## piece that collides with an earlier one should look harder for a spot.
const HANGAR_COVER_ATTEMPTS := 24


## A hangar bay's dressing (GDD §7.2): `hangar_wrecks_min..max` wrecks first (the
## big shapes need the open floor), then `hangar_cover_min..max` ordinary cover
## blocks, every piece kept off the ship's space and the square
## (`_hangar_keep_clear`, plus the usual tile of walkway) and off any spawn.
## The same spacing rule as everywhere — a tile of gap to the walls and between
## pieces — is what keeps the bay connected without a flood check: no piece can
## ever close the gap between two others or between itself and a wall.
func _place_hangar_cover(data: MapData, room_index: int) -> void:
	var room := _rooms[room_index]
	var placed: Array[Rect2i] = [_hangar_keep_clear(room_index)]
	var wrecks := _rng.randi_range(_cfg.hangar_wrecks_min, _cfg.hangar_wrecks_max)
	for _i in wrecks:
		var footprint: Variant = _place_piece(data, room, placed, WRECK_SHAPES, true,
			HANGAR_COVER_ATTEMPTS)
		if footprint != null:
			placed.append(footprint)
	var blocks := _rng.randi_range(_cfg.hangar_cover_min, _cfg.hangar_cover_max)
	for _i in blocks:
		var footprint: Variant = _place_piece(data, room, placed, COVER_SHAPES, false,
			HANGAR_COVER_ATTEMPTS)
		if footprint != null:
			placed.append(footprint)


## One piece in `room`: a wreck (MapData.wrecks) when `wreck`, else an ordinary
## cover block (MapData.obstacles). The rules are `_place_one_cover_block`'s, plus
## one it never needed: no spawn under the footprint, since a hangar bay can roll
## an enemy spawn and a wreck dropped on it would bury the unit in the hull.
func _place_piece(data: MapData, room: Rect2i, existing: Array[Rect2i], shapes: Array[Vector2i],
		wreck: bool, attempts: int) -> Variant:
	for _attempt in attempts:
		var shape: Vector2i = shapes[_rng.randi_range(0, shapes.size() - 1)]
		if _rng.randf() < 0.5:
			shape = Vector2i(shape.y, shape.x)
		var max_x := room.size.x - 2 - shape.x
		var max_z := room.size.y - 2 - shape.y
		if max_x < 0 or max_z < 0:
			continue
		var x := room.position.x + 1 + _rng.randi_range(0, max_x)
		var z := room.position.y + 1 + _rng.randi_range(0, max_z)
		var footprint := Rect2i(x, z, shape.x, shape.y)
		var clear := true
		for other in existing:
			if footprint.grow(1).intersects(other):
				clear = false
				break
		if clear:
			for cz in range(footprint.position.y, footprint.end.y):
				for cx in range(footprint.position.x, footprint.end.x):
					var cell := data.get_cell(Vector3i(cx, 0, cz))
					if cell == null or cell.terrain != MapData.Terrain.FLOOR \
							or cell.spawn != MapData.Spawn.NONE or cell.stair:
						clear = false
		if not clear:
			continue
		var tier := MapData.Cover.HEAVY if _rng.randf() < _cfg.cover_heavy_chance else MapData.Cover.LIGHT
		for cz in range(footprint.position.y, footprint.end.y):
			for cx in range(footprint.position.x, footprint.end.x):
				data.get_cell(Vector3i(cx, 0, cz)).terrain = MapData.Terrain.OBSTACLE
		if wreck:
			data.wrecks.append(footprint)
		else:
			data.obstacles.append([footprint, tier])
		return footprint
	return null


## Count scales with room area — a small closet gets at most one crate, a
## cargo bay gets several — rather than the old flat 1-2 pieces, since blocks
## are now the only source of cover in a room rather than a garnish on top of
## dense edge cover. `cover_area_per_piece` is the knob to retune density with
## after playtesting; there's no principled "right" number here.
func _place_room_cover(data: MapData, room: Rect2i, keep_clear := Rect2i()) -> void:
	var area := room.size.x * room.size.y
	var count := clampi(roundi(area / float(_cfg.cover_area_per_piece)), 0, _cfg.cover_max_per_room)
	var placed: Array[Rect2i] = []
	# Treated as one more piece already placed, so the existing spacing rule
	# keeps every crate a tile clear of the pad and square for free.
	if keep_clear.has_area():
		placed.append(keep_clear)
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


# --- Loot containers (extraction plan 3.2) ------------------------------------------
#
# One-tile crates in ordinary rooms. Two rules keep them from ever costing a path:
#   1. a crate stands AGAINST a wall, on plain floor, with no door, cover block or
#      other crate in any of its eight neighbours — so it never narrows a doorway
#      or closes the gap between a crate of cover and a wall;
#   2. it must not split its room: the room's passable tiles are counted as
#      4-connected regions before and after, and a crate that adds a region is
#      not placed there.
# Doorways are corridor tiles and are never touched, so a room that stays in one
# piece keeps every route through it — which is what lets the hangar
# reachability guarantee (`_hangars_reachable`) hold with no reroll. It is still
# rechecked, counting crates as walls.


const NO_SPOT := Vector3i(-99999, -99999, -99999)


func _place_loot(data: MapData) -> void:
	for i in _rooms.size():
		if _room_is_corridor[i] or _hangar_rooms.has(i):
			continue
		if _rng.randf() >= _cfg.loot_room_chance:
			continue
		var count := _rng.randi_range(1, maxi(1, _cfg.loot_per_room_max))
		for _n in count:
			var pos := _container_spot(data, i)
			if pos == NO_SPOT:
				break
			var items := ItemPresets.roll_container(_rng, RoomTypes.loot_of(data.room_type(i)))
			if data.room_condition(i) == RoomTypes.Condition.BARRICADED:
				items.append(ItemPresets.roll_valuable(_rng).code)
			data.add_container(pos, items)


## A legal crate tile in `room`, picked at random among the legal ones, or NO_SPOT.
func _container_spot(data: MapData, room: int) -> Vector3i:
	var cells := _room_cells(data, room)
	var candidates: Array = []
	for pos in cells:
		if _crate_fits(data, pos):
			candidates.append(pos)
	_shuffle(candidates)
	var before := _region_count(data, cells, NO_SPOT)
	for pos: Vector3i in candidates:
		if _region_count(data, cells, pos) <= before:
			return pos
	return NO_SPOT


## Rule 1 above.
func _crate_fits(data: MapData, pos: Vector3i) -> bool:
	var cell := data.get_cell(pos)
	if cell == null or cell.terrain != MapData.Terrain.FLOOR or cell.spawn != MapData.Spawn.NONE \
			or cell.fixture != MapData.Fixture.NONE or cell.stair or data.has_container(pos):
		return false
	var against_wall := false
	for step: Vector3i in MapData.SIDE_STEP:
		if data.terrain_at(pos + step) == MapData.Terrain.WALL:
			against_wall = true
	if not against_wall:
		return false
	for dz in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			var n: Vector3i = pos + Vector3i(dx, 0, dz)
			var t := data.terrain_at(n)
			if t == MapData.Terrain.DOOR or t == MapData.Terrain.OBSTACLE or (n != pos and data.has_container(n)):
				return false
	return true


## 4-connected regions among `cells` that are passable, treating `extra` as a crate
## too (NO_SPOT for none).
func _region_count(data: MapData, cells: Array[Vector3i], extra: Vector3i) -> int:
	var open: Dictionary = {}
	for pos in cells:
		if pos != extra and data.is_passable(pos):
			open[pos] = true
	var seen: Dictionary = {}
	var regions := 0
	for start: Vector3i in open:
		if seen.has(start):
			continue
		regions += 1
		var frontier: Array[Vector3i] = [start]
		seen[start] = true
		while not frontier.is_empty():
			var cur: Vector3i = frontier.pop_back()
			for step: Vector3i in MapData.SIDE_STEP:
				var n: Vector3i = cur + step
				if open.has(n) and not seen.has(n):
					seen[n] = true
					frontier.append(n)
	return regions


func _shuffle(items: Array) -> void:
	# Not Array.shuffle(): that uses the global RNG and would make a seeded deck
	# depend on whatever else called randi() first.
	for i in range(items.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var tmp: Variant = items[i]
		items[i] = items[j]
		items[j] = tmp
