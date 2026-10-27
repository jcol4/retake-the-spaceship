extends SceneTree
## Extraction plan Phase 1.2: hangar placement in MapGenerator, fuzzed over a few
## hundred seeds.
##
##   godot --headless --path . --script res://tools/test_hangar_gen.gd
##
## Per seed:
##   - 3–4 hangars (GDD §7.2), exactly one of them the insertion hangar;
##   - every hangar's square reachable on foot from the insertion square — checked
##     here with an 8-way flood of this test's own, independent of the
##     generator's 4-way reroll check, so a bug in that check cannot hide itself;
##   - no enemy spawn in the insertion bay, and the squad spawned on its square;
##   - every square tile walkable and inside its own bay, pads clear of cover.
##
## Engine-free (MapGenerator/MapData only), so hundreds of decks run in seconds.

const SEEDS := 300
const FIRST_SEED := 1

var _failures := 0
## Per-property failure counts, so a regression reads as "reachability broke on
## 12 seeds" rather than 3600 individual lines.
var _tally: Dictionary = {}
var _first_bad: Dictionary = {}


func _initialize() -> void:
	var gen = load("res://scripts/map_generator.gd")
	var MD = load("res://scripts/map_data.gd")
	var rerolled := 0
	var crates := 0
	var counts := {}
	var started := Time.get_ticks_msec()
	for s in range(FIRST_SEED, FIRST_SEED + SEEDS):
		var data = gen.generate(s)
		if data.generation_attempt > 0:
			rerolled += 1
		var n: int = data.hangars.size()
		counts[n] = counts.get(n, 0) + 1
		_expect(s, n >= 3 and n <= 4, "hangar count in 3-4")
		var insertions := 0
		for h in data.hangars:
			if h.is_insertion:
				insertions += 1
		_expect(s, insertions == 1, "exactly one insertion hangar")
		var insertion = data.insertion_hangar()
		if insertion == null:
			continue
		_expect(s, _all_reachable(data, insertion), "every hangar square reachable from insertion")
		_expect(s, _insertion_enemy_free(data, insertion, MD), "insertion bay enemy-free")
		_expect(s, _squad_on_square(data, insertion, MD), "squad spawns on the insertion square")
		for h in data.hangars:
			_expect(s, h.square.size() == 9, "square is 3x3")
			var walkable := true
			var in_bay := true
			for pos in h.square:
				walkable = walkable and data.is_walkable(pos)
				in_bay = in_bay and h.in_bay(pos)
			_expect(s, walkable, "square fully walkable")
			_expect(s, in_bay, "square inside its own bay")
			var pad_clear := true
			for pos in MD.hangar_pad_cells(h.pad_center):
				pad_clear = pad_clear and data.is_walkable(pos)
			_expect(s, pad_clear, "pad clear of cover and walls")
			_expect(s, h.bay_cells.has(h.pad_center), "pad sits in the bay")
			_check_bay(s, data, h, MD, gen)
		# Extraction plan 3.2: loot crates.
		crates += data.containers.size()
		_check_crates(s, data, insertion)
	var ms := Time.get_ticks_msec() - started

	print("%d seeds in %d ms; hangar counts %s; %d seed(s) needed a reroll; %.1f crates/deck" % [
		SEEDS, ms, counts, rerolled, float(crates) / SEEDS])
	print("bays: %.2f wrecks and %.2f cover blocks each" % [
		float(_bay_totals[0]) / maxi(1, _bay_totals[2]), float(_bay_totals[1]) / maxi(1, _bay_totals[2])])
	_check(crates > SEEDS, "generated decks carry loot crates (%d over %d seeds)" % [crates, SEEDS])
	for label in _tally:
		print("  FAIL  %s: %d seed(s), first seed %d" % [label, _tally[label], _first_bad[label]])
	_check(_tally.is_empty(), "every seed satisfies every hangar property")
	# A deck generated before hangars existed must still be expressible: zero
	# hangars gives back a clear-out deck with the old spawn rule.
	var cfg = gen.Config.new()
	cfg.hangar_count_min = 0
	cfg.hangar_count_max = 0
	var legacy = gen.generate(7, cfg)
	_check(legacy.hangars.is_empty() and not legacy.spawns(MD.Spawn.PLAYER).is_empty(),
		"hangar_count 0 gives a hangar-free deck that still spawns a squad")
	# The reroll predicate itself. The fuzz above may never need a reroll (it did
	# not when this was written), so the check that triggers one is pinned here on
	# two hand-drawn bays: sealed apart, then joined by a door.
	var ascii_script = load("res://scripts/map_ascii.gd")
	var sealed = ascii_script.parse(_two_bays("#"))
	var joined = ascii_script.parse(_two_bays("D"))
	_check(sealed.hangars.size() == 2 and not gen.new()._hangars_reachable(sealed),
		"the reroll check rejects a deck with a sealed-off hangar")
	_check(gen.new()._hangars_reachable(joined), "and accepts the same deck with a door in the bulkhead")
	# Determinism, rerolls included — co-op sends only the seed.
	var a = gen.generate(42)
	var b = gen.generate(42)
	var ascii = load("res://scripts/map_ascii.gd")
	_check(ascii.to_text(a) == ascii.to_text(b), "the same seed generates the same deck, hangars included")

	print("")
	if _failures == 0:
		print("hangar gen: ALL CHECKS PASSED")
		quit(0)
	else:
		print("hangar gen: %d CHECK(S) FAILED" % _failures)
		quit(1)


## 8-way flood over walkable tiles, with the game's corner rule left out (it can
## only make movement STRICTER than this, and the generator's own check is
## 4-way, which is stricter still — so the two together bracket the real grid).
func _all_reachable(data, insertion) -> bool:
	var seen := {}
	var frontier: Array[Vector3i] = []
	for pos in insertion.square:
		seen[pos] = true
		frontier.append(pos)
	while not frontier.is_empty():
		var cur: Vector3i = frontier.pop_back()
		for dz in [-1, 0, 1]:
			for dx in [-1, 0, 1]:
				var n := cur + Vector3i(dx, 0, dz)
				if not seen.has(n) and data.is_walkable(n):
					seen[n] = true
					frontier.append(n)
	for h in data.hangars:
		for pos in h.square:
			if not seen.has(pos):
				return false
	return true


## Per seed: every crate in an ordinary room (never a hangar bay, never a corridor),
## on plain floor with no spawn, with contents that parse; every hangar square
## still reachable when crates count as walls (8-way flood over `is_passable`);
## and every crate lootable — some neighbouring tile of it reachable on foot.
func _check_crates(s: int, data, insertion) -> void:
	var MD = load("res://scripts/map_data.gd")
	var items = load("res://scripts/item_presets.gd")
	var hangar_rooms := {}
	for h in data.hangars:
		hangar_rooms[h.room_index] = true
	for spot in data.containers:
		var room: int = data.room_index_at(spot.pos)
		_expect(s, room >= 0 and not hangar_rooms.has(room), "no crate in a hangar bay")
		_expect(s, not data.corridors.has(room), "no crate in a corridor")
		var cell = data.get_cell(spot.pos)
		_expect(s, cell != null and cell.terrain == MD.Terrain.FLOOR and cell.spawn == MD.Spawn.NONE,
			"crates stand on plain floor with no spawn")
		_expect(s, not spot.items.is_empty(), "generated crates are never empty")
		var parsed := true
		for code in spot.items:
			parsed = parsed and items.from_code(code) != null
		_expect(s, parsed, "crate contents are valid item codes")
		for h in data.hangars:
			_expect(s, not h.in_square(spot.pos), "no crate on an extraction square")
	var seen := _passable_flood(data, insertion)
	var squares_ok := true
	for h in data.hangars:
		for pos in h.square:
			squares_ok = squares_ok and seen.has(pos)
	_expect(s, squares_ok, "every square reachable with crates counted as walls")
	for spot in data.containers:
		var reachable := false
		for dz in [-1, 0, 1]:
			for dx in [-1, 0, 1]:
				reachable = reachable or seen.has(spot.pos + Vector3i(dx, 0, dz))
		_expect(s, reachable, "every crate has a reachable neighbour to loot it from")


func _passable_flood(data, insertion) -> Dictionary:
	var seen := {}
	var frontier: Array[Vector3i] = []
	for pos in insertion.square:
		seen[pos] = true
		frontier.append(pos)
	while not frontier.is_empty():
		var cur: Vector3i = frontier.pop_back()
		for dz in [-1, 0, 1]:
			for dx in [-1, 0, 1]:
				var n := cur + Vector3i(dx, 0, dz)
				if not seen.has(n) and data.is_passable(n):
					seen[n] = true
					frontier.append(n)
	return seen


func _insertion_enemy_free(data, insertion, MD) -> bool:
	for pos in insertion.bay_cells:
		var cell = data.get_cell(pos)
		if cell != null and cell.spawn != MD.Spawn.NONE and cell.spawn != MD.Spawn.PLAYER:
			return false
	return true


func _squad_on_square(data, insertion, MD) -> bool:
	var squad: Array = data.spawns(MD.Spawn.PLAYER)
	if squad.is_empty():
		return false
	for pos in squad:
		if not insertion.square.has(pos):
			return false
	return true


## Two 11x5 bays either side of a bulkhead whose middle tile is `gap` — just big
## enough for the 5x5 ship space and the square in front of it.
func _two_bays(gap: String) -> PackedStringArray:
	return PackedStringArray([
		"#########################",
		"#...........#...........#",
		"#...........#...........#",
		"#...........%s...........#" % gap,
		"#...........#...........#",
		"#...........#...........#",
		"#########################",
		"",
		"[hangars]",
		"3,3 E insertion",
		"21,3 W",
	])


## GDD §7.2, the bay as a place to fight from: 3–4x its landing zone, at least
## one wreck, and the cover the generator promises — every piece of it, wrecks
## included, off the ship's space and the square (the pad/square walkability
## checks above) and off any spawn.
func _check_bay(s: int, data, h, MD, gen) -> void:
	var rect: Rect2i = data.rooms[h.room_index]
	var lz: int = MD.hangar_landing_zone_area()
	var area := rect.size.x * rect.size.y
	_expect(s, area >= ceili(lz * MD.HANGAR_BAY_AREA_MIN) and area <= floori(lz * MD.HANGAR_BAY_AREA_MAX),
		"bay area is 3-4x the landing zone")
	_expect(s, data.hangar_problem(h) == "", "pad and square clear (MapData.hangar_problem)")
	var wrecks := 0
	for footprint: Rect2i in data.wrecks:
		if rect.encloses(footprint):
			wrecks += 1
			var reserved: Rect2i = MD.hangar_reserved_rect(h.pad_center, h.ramp_side)
			_expect(s, not footprint.grow(1).intersects(reserved), "wrecks keep a walkway clear of ship and square")
	var blocks := 0
	for entry: Array in data.obstacles:
		if rect.encloses(entry[0]):
			blocks += 1
	var cfg = gen.Config.new()
	_expect(s, wrecks >= cfg.hangar_wrecks_min, "every bay has a wreck")
	_expect(s, blocks >= cfg.hangar_cover_min - 1, "every bay has its cover (at most one piece short)")
	_bay_totals[0] += wrecks
	_bay_totals[1] += blocks
	_bay_totals[2] += 1


## [wrecks, cover blocks, bays] over the fuzz, for the summary line.
var _bay_totals := [0, 0, 0]


func _expect(seed_value: int, ok: bool, label: String) -> void:
	if ok:
		return
	if not _tally.has(label):
		_first_bad[label] = seed_value
	_tally[label] = _tally.get(label, 0) + 1


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
