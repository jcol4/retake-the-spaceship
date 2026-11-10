extends SceneTree
## B.6 / C.8: independent geometry and connectivity checks across every size
## and valid profile pairing. ROOM_THEME_SEEDS overrides the default 500 for
## a quick smoke run. No scene/autoload dependencies.

var _failures := {}
var _case := ""
var _room_starts := {}
var _cached_data_id := 0


func _initialize() -> void:
	var seeds := int(OS.get_environment("ROOM_THEME_SEEDS")) if OS.has_environment("ROOM_THEME_SEEDS") else 500
	for size in [Vector2i(72, 48), Vector2i(84, 56), Vector2i(96, 64)]:
		if OS.has_environment("ROOM_THEME_WIDTH") and size.x != int(OS.get_environment("ROOM_THEME_WIDTH")):
			continue
		var profiles: Array = [[-1, -1]]
		if size.x != 72:
			profiles.clear()
			for primary: int in DeckLayout.SECONDARY_OPTIONS:
				for secondary: int in DeckLayout.SECONDARY_OPTIONS[primary]:
					profiles.append([primary, secondary])
		for profile: Array in profiles:
			if OS.has_environment("ROOM_THEME_PROFILE") and OS.get_environment("ROOM_THEME_PROFILE") != "%d,%d" % profile:
				continue
			var cfg := MapGenerator.Config.new()
			cfg.deck_source = 1 # MapGenerator.DeckSource.GENERATED: procedural regression
			cfg.width = size.x
			cfg.depth = size.y
			cfg.mixed_profile = size.x == 72
			cfg.room_scale = 0.72 if cfg.mixed_profile else 1.0
			cfg.profile_primary = profile[0]
			cfg.profile_secondary = profile[1]
			# Optional layout-only sweep for B/C: furniture, loot and encounter
			# checks also run on fully dressed decks in test_hangar_gen.
			if OS.get_environment("ROOM_THEME_LAYOUT_ONLY") == "1":
				cfg.cover_max_per_room = 0
				cfg.hangar_cover_min = 0
				cfg.hangar_cover_max = 0
				cfg.hangar_wrecks_min = 0
				cfg.hangar_wrecks_max = 0
				cfg.loot_room_chance = 0.0
				cfg.merc_squad_chance = 0.0
			var rerolls := 0
			var attempts := 0
			var bad_bunk_neighbours := 0
			for seed_value in range(1, seeds + 1):
				_case = "%s profile %s seed %d" % [size, profile, seed_value]
				var data := MapGenerator.generate(seed_value, cfg)
				rerolls += int(data.generation_attempt > 0)
				attempts += data.generation_attempt
				_check_deck(data, cfg)
				bad_bunk_neighbours += int(_bunk_opens_onto_machinery(data))
				_expect(MapAscii.to_text(data) == MapAscii.to_text(MapGenerator.generate(seed_value, cfg)), "seed determinism")
				if seed_value <= 3:
					_check_roundtrip(data)
				if seed_value % 100 == 0:
					print("%s profile %s: %d/%d checked" % [size, profile, seed_value, seeds])
			print("%s profile %s: %d seeds, %d rerolled, %d total retries" % [size, profile, seeds, rerolls, attempts])
			print("  bunk rooms opening onto machinery/cargo: %d/%d decks" % [bad_bunk_neighbours, seeds])
	for label: String in _failures:
		print("FAIL %s: %s" % [label, _failures[label]])
	print("room themes: %s" % ["ALL CHECKS PASSED" if _failures.is_empty() else "%d properties failed" % _failures.size()])
	quit(0 if _failures.is_empty() else 1)


func _check_deck(data: MapData, cfg: MapGenerator.Config) -> void:
	var counts := {}
	for type: StringName in data.room_types:
		counts[type] = counts.get(type, 0) + 1
	for type: StringName in counts:
		var cap := RoomTypes.cap_of(type)
		_expect(cap <= 0 or counts[type] <= cap, "cap %s" % type)
	for band: Array in data.zone_bands:
		for required: StringName in RoomTypes.ZONE_REQUIRED.get(band[0], []):
			_expect(counts.get(required, 0) > 0, "required %s" % required)
	if counts.has(&"bunk_room"):
		var suites := 1 if cfg.mixed_profile or data.deck_primary != RoomTypes.Zone.HABITATION else (3 if cfg.width == 96 else 2)
		_expect(counts.get(&"bathroom", 0) >= suites, "berthing suite count")
		_expect(counts.get(&"bunk_room", 0) >= suites * (1 if cfg.mixed_profile else 2), "berthing bunk count")
	var insertion := data.insertion_hangar()
	_expect(insertion != null and data.hangars.size() >= cfg.hangar_count_min, "hangar count")
	if insertion == null:
		return
	var reachable := _flood(data, insertion.square[0])
	for hangar in data.hangars:
		for pos: Vector3i in hangar.square:
			_expect(reachable.has(pos), "hangar reachable")
		var spine_link := false
		for link: Array in data.room_links:
			if hangar.room_index in link:
				spine_link = spine_link or data.room_type(link[1] if link[0] == hangar.room_index else link[0]) == RoomTypes.SPINE
		_expect(spine_link, "hangar opens onto spine")
	var spines := data.rooms_of_type(RoomTypes.SPINE)
	_expect(spines.size() == 2, "two spines")
	for spine: int in spines:
		var columns := {}
		for pos: Vector3i in data.room_of:
			if data.room_of[pos] == spine:
				columns[pos.x] = true
		for x in range(1, cfg.width - 1):
			_expect(columns.has(x), "spine spans hull")
	var habitation_reachable := {}
	for bathroom: int in data.rooms_of_type(&"bathroom"):
		var start := _room_cell(data, bathroom)
		if not habitation_reachable.has(start):
			habitation_reachable.merge(_flood(data, start, true))
	for room in data.rooms.size():
		if room in data.corridors:
			continue
		var type := data.room_type(room)
		_expect(reachable.has(_room_cell(data, room)), "room reachable %s" % type)
		var door_count := 0
		for link: Array in data.room_links:
			if room in link:
				door_count += 1
		var rule := RoomTypes.doors_of(type)
		_expect(rule != RoomTypes.Doors.ONE or door_count == 1, "one door %s" % type)
		_expect(rule != RoomTypes.Doors.TWO_PLUS or door_count >= 2, "two doors %s" % type)
		if type == &"bunk_room":
			_expect(habitation_reachable.has(_room_cell(data, room)), "bunk reaches bathroom within habitation")
		if type == &"fuel_storage":
			for link: Array in data.room_links:
				if room not in link:
					continue
				var other: int = link[1] if link[0] == room else link[0]
				if data.room_type(other) == RoomTypes.SPINE:
					continue
				for edge: Array in data.room_links:
					if other in edge:
						var neighbour: int = edge[1] if edge[0] == other else edge[0]
						_expect(neighbour == room or RoomTypes.zone_of(data.room_type(neighbour)) == RoomTypes.Zone.ENGINEERING,
							"fuel only connects to engineering")


func _flood(data: MapData, start: Vector3i, habitation_only := false) -> Dictionary:
	var seen := {start: true}
	var queue: Array[Vector3i] = [start]
	var head := 0
	while head < queue.size():
		var current := queue[head]
		head += 1
		for step: Vector3i in MapData.SIDE_STEP:
			var next := current + step
			if seen.has(next) or not data.is_passable(next):
				continue
			var room := data.room_index_at(next)
			if habitation_only and room not in data.corridors and data.room_zone(room) != RoomTypes.Zone.HABITATION:
				continue
			seen[next] = true
			queue.append(next)
	return seen


func _room_cell(data: MapData, room: int) -> Vector3i:
	if _cached_data_id != data.get_instance_id():
		_room_starts.clear()
		_cached_data_id = data.get_instance_id()
		for pos: Vector3i in data.room_of:
			var index: int = data.room_of[pos]
			if not _room_starts.has(index) and data.is_passable(pos):
				_room_starts[index] = pos
	return _room_starts.get(room, Vector3i(-1, 0, -1))


func _check_roundtrip(data: MapData) -> void:
	var decoded := MapAscii.parse(MapAscii.to_text(data).split("\n"))
	# Every authored compartment must retain its identity, even where a suite's
	# shared wall is too short to be detected by the old bulkhead heuristic.
	for room in data.rooms.size():
		if room in data.corridors:
			continue
		var pos := _room_cell(data, room)
		_expect(decoded.room_type_at(pos) == data.room_type(room), "suite roundtrip %s" % data.room_type(room))


func _expect(ok: bool, label: String) -> void:
	if not ok and not _failures.has(label):
		_failures[label] = _case


## Internal suite/loop openings count as direct neighbours; walking along a
## main spine to another room does not count as opening directly onto it.
func _bunk_opens_onto_machinery(data: MapData) -> bool:
	const MACHINERY: Array[StringName] = [&"engine_room", &"life_support", &"fuel_storage", &"cargo_hold"]
	for bunk: int in data.rooms_of_type(&"bunk_room"):
		for link: Array in data.room_links:
			if bunk not in link:
				continue
			var door: int = link[1] if link[0] == bunk else link[0]
			if data.room_type(door) == RoomTypes.SPINE:
				continue
			if data.room_type(door) in MACHINERY:
				return true
			for edge: Array in data.room_links:
				if door in edge:
					var other: int = edge[1] if edge[0] == door else edge[0]
					if data.room_type(other) in MACHINERY:
						return true
	return false
