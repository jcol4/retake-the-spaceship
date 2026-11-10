extends SceneTree
## D–F integration: real grid/props, host commands, saved room state, seeded
## dressing, accessible keys, themed objectives, and actual insertion distances.
var _failures := 0
var _map
var _actor
var _systems
var _grid
var _turn
var _contract


func _initialize() -> void:
	await process_frame
	_grid = root.get_node("GridManager")
	_turn = root.get_node("TurnManager")
	_contract = load("res://scripts/contract.gd")
	_check_generated()
	_map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(_map)
	await process_frame
	var cfg := MapGenerator.Config.new()
	cfg.deck_source = 1 # MapGenerator.DeckSource.GENERATED: procedural regression
	cfg.width = 72
	cfg.depth = 48
	cfg.mixed_profile = true
	cfg.room_scale = 0.72
	_map.build_generated(12, cfg)
	await process_frame
	await physics_frame
	_systems = _map.get_node("RoomSystems")
	_actor = load("res://scenes/player_unit.tscn").instantiate()
	_actor.name = "RoomTestSoldier"
	_actor.stats = load("res://scripts/unit_stats.gd").new()
	_actor.stats.weapon = load("res://scripts/weapon_presets.gd").make(0)
	_actor.position = _grid.grid_to_world(_map.data.insertion_hangar().square[0])
	root.add_child(_actor)
	await process_frame
	_turn.mode = 1 # TURN; commands must pay real AP, not exploration clock time.
	_check_commands()
	_check_inventory()
	await _check_merc_pack()
	await _check_hazards_and_darkness()
	_actor.queue_free()
	_map.queue_free()
	print("room gameplay: %s" % ["ALL CHECKS PASSED" if _failures == 0 else "%d CHECK(S) FAILED" % _failures])
	quit(0 if _failures == 0 else 1)


func _check_generated() -> void:
	var kinds := {}
	var conditions := [0, 0, 0, 0]
	var objective_ok := true
	var rng := RandomNumberGenerator.new()
	for seed_value in range(1, 41):
		var cfg := MapGenerator.Config.new()
		cfg.deck_source = 1 # MapGenerator.DeckSource.GENERATED: procedural regression
		cfg.profile_primary = seed_value % 4
		cfg.objective_kind = seed_value % 4
		var data := MapGenerator.generate(seed_value, cfg)
		var decoded := MapAscii.parse(MapAscii.to_text(data).split("\n"))
		_check(decoded.zone_power == data.zone_power and decoded.zone_bands == data.zone_bands and decoded.profile_name() == data.profile_name(), "seed %d: power/profile roundtrip" % seed_value)
		for entry: Array in data.obstacles:
			if entry.size() > 2:
				kinds[entry[2]] = true
		for room in data.rooms.size():
			if room not in data.corridors and data.room_type(room) != RoomTypes.HANGAR:
				conditions[data.room_condition(room)] += 1
		_check_keys(data, seed_value)
		rng.seed = seed_value
		var c = _contract.make(cfg.objective_kind, data, rng)
		objective_ok = objective_ok and c != null
		if c != null:
			objective_ok = objective_ok and data.room_type_at(c.target_tile) in RoomTypes.OBJECTIVE_ROOMS[cfg.objective_kind] if data.objective_room_hint >= 0 else objective_ok
			data.select_objective_insertion(c.target_tile, rng)
			var distances := _flood(data, c.target_tile, {}, true)
			var ranked: Array[int] = []
			for h in data.hangars:
				ranked.append(distances.get(h.square[4], -1))
			ranked.sort()
			_check(distances.get(data.insertion_hangar().square[4], -1) >= ranked[ranked.size() / 2], "seed %d: insertion in farthest half" % seed_value)
	_check(kinds.size() >= 10, "room layouts draw at least ten furniture/hazard kinds (%d)" % kinds.size())
	_check(conditions.all(func(n: int) -> bool: return n > 0), "all four room conditions occur: %s" % [conditions])
	_check(objective_ok, "objectives use their themed rooms when the profile provides them")
	for table in ItemPresets.ROOM_TABLES:
		for code in ItemPresets.ROOM_TABLES[table]:
			_check(ItemPresets.from_code(code) != null, "themed loot code %s parses" % code)


func _check_keys(data: MapData, seed_value: int) -> void:
	var blocked := {}
	for pos: Vector3i in data.cells:
		if data.terrain_at(pos) != MapData.Terrain.DOOR:
			continue
		for step: Vector3i in MapData.SIDE_STEP:
			if RoomTypes.is_locked(data.room_type_at(pos + step)):
				blocked[pos] = true
	var seen := _flood(data, data.insertion_hangar().square[0], blocked)
	for room in data.rooms.size():
		var type := data.room_type(room)
		if not RoomTypes.is_locked(type):
			continue
		var found := false
		for crate: MapData.LootSpot in data.containers:
			if not ("keycard:" + String(type)) in crate.items:
				continue
			for step: Vector3i in MapData.SIDE_STEP:
				found = found or seen.has(crate.pos + step)
		_check(found, "seed %d: %s card reachable with every lock closed" % [seed_value, type])


func _flood(data: MapData, start: Vector3i, blocked: Dictionary, diagonal := false) -> Dictionary:
	var seen := {start: 0}
	var queue: Array[Vector3i] = [start]
	var head := 0
	while head < queue.size():
		var at := queue[head]
		head += 1
		for dz in [-1, 0, 1]:
			for dx in [-1, 0, 1]:
				if not diagonal and dx != 0 and dz != 0:
					continue
				var next := at + Vector3i(dx, 0, dz)
				if seen.has(next) or blocked.has(next) or not data.is_passable(next):
					continue
				if dx != 0 and dz != 0 and not data.is_passable(at + Vector3i(dx, 0, 0)) and not data.is_passable(at + Vector3i(0, 0, dz)):
					continue
				seen[next] = seen[at] + 1
				queue.append(next)
	return seen


func _move(at: Vector3i) -> void:
	_grid.release_occupant(_actor.grid_pos, _actor)
	_actor.grid_pos = at
	_actor.global_position = _grid.grid_to_world(at)
	_grid.set_occupant(at, _actor)
	_actor.ap = _actor.stats.ap_pool()


func _check_commands() -> void:
	var bridge: int = _map.data.rooms_of_type(&"bridge")[0]
	var near := Vector3i.ZERO
	for tile: Vector3i in _systems.doors[bridge].cells:
		for step: Vector3i in MapData.SIDE_STEP:
			if _grid.is_free(tile + step):
				near = tile + step
	_move(near)
	var closed: Dictionary = _systems.capture()
	_check(not _systems.act(_actor, "key", bridge), "unlock refused without a keycard")
	_actor.add_item(ItemPresets.from_code("keycard:bridge"))
	var ap: int = _actor.ap
	_check(_systems.act(_actor, "key", bridge) and _systems.doors[bridge].open and _actor.ap == ap, "keycard opens a real blocked doorway for zero AP")
	_systems.restore(closed)
	_check(_systems.act(_actor, "breach", bridge) and not _systems.doors[bridge].open and _actor.ap == 0, "first full turn breaches halfway")
	_actor.ap = _actor.stats.ap_pool()
	_check(_systems.act(_actor, "breach", bridge) and _systems.doors[bridge].open, "second full turn opens the doorway")
	var control: int = _map.data.rooms_of_type(&"engineering_control")[0]
	_move(_systems.stations[control])
	_map.data.zone_power[RoomTypes.Zone.HABITATION] = false
	_check(_systems.act(_actor, "power", control) and _map.data.zone_power[RoomTypes.Zone.HABITATION], "engineering switch restores one dark zone")
	var medbay: int = _map.data.rooms_of_type(&"medbay")[0]
	_move(_systems.stations[medbay])
	_actor.current_hp -= 5
	_check(_systems.act(_actor, "heal", medbay) and _actor.current_hp == _actor.stats.max_hp() and _actor.ap == 0, "medbay heals for a full turn")
	_actor.ap = _actor.stats.ap_pool()
	_check(not _systems.act(_actor, "heal", medbay), "room service cannot be used twice")
	var patient = load("res://scenes/player_unit.tscn").instantiate()
	patient.name = "RoomTestPatient"
	for pos in _map.data.room_of:
		if _map.data.room_of[pos] == medbay and _grid.is_free(pos):
			patient.position = _grid.grid_to_world(pos)
			break
	root.add_child(patient)
	patient.take_damage(patient.current_hp)
	_systems.used.erase(medbay)
	_actor.ap = _actor.stats.ap_pool()
	_check(_systems.act(_actor, "heal", medbay) and not patient.is_downed and patient.current_hp == patient.stats.max_hp(), "medbay revives a downed soldier in the room")
	patient.queue_free()
	_systems.used.erase(medbay)
	_map.data.set_room_type(medbay, &"armory")
	_actor.ap = _actor.stats.ap_pool()
	_actor.ammo = 0
	_actor.reserve = 0
	var grenades: int = _actor.grenade_charges
	_check(_systems.act(_actor, "ammo", medbay) and _actor.ammo == _actor.stats.mag_size and _actor.grenade_charges == grenades + 1, "armory refills ammunition and grants a grenade")
	_systems.used.erase(medbay)
	_map.data.set_room_type(medbay, &"fabrication")
	var campaign = root.get_node("Campaign")
	var before: Dictionary = campaign.deployment.duplicate(true)
	campaign.deployment = {"attachments": {0: 1}}
	_actor.ap = _actor.stats.ap_pool()
	_check(_systems.act(_actor, "fit", medbay, 0) and _actor.stats.weapon.underbarrel.id == 0, "fabrication fits an attachment from the squad stash")
	_check(not (0 in _systems._spare_attachments(_actor)), "fabrication cannot duplicate an already fitted stash copy")
	campaign.deployment = before
	_map.data.set_room_type(medbay, &"medbay")
	_move(_systems.stations[bridge])
	_check(_systems.act(_actor, "reveal", bridge) and _systems.revealed, "terminal reveals the room map")
	_actor.ap = _actor.stats.ap_pool()
	_check(_systems.act(_actor, "robots", bridge) and not _systems.robots_enabled, "terminal disables security robots")
	_actor.ap = _actor.stats.ap_pool()
	_check(_systems.act(_actor, "hack", bridge) and _actor.ap == 0, "terminal hack costs a full turn")
	var saved: Dictionary = _systems.capture()
	_systems.restore(closed)
	_systems.restore(saved)
	_check(_systems.capture() == saved, "door/power/service/terminal state roundtrips for co-op and checkpoints")
	_systems._process(1.0)
	_check(_systems.labels[bridge].visible and _systems.labels[bridge].text.contains("Bridge"), "explored rooms have hangar-style world labels")
	_check(_systems.room_text(_actor.grid_pos).contains("Bridge"), "selected soldier's room name is available to the HUD")


func _check_inventory() -> void:
	while not _actor.inventory.is_empty():
		_actor.remove_item(0)
	_check(_actor.add_item(ItemPresets.make("specimen")) and _actor.free_slots() == 2, "heavy specimen occupies two slots")
	_actor.add_item(ItemPresets.make("medkit"))
	_check(not _actor.add_item(ItemPresets.make("specimen")), "two-slot loot cannot overfill a pack")
	_actor.ap = _actor.stats.ap_pool()
	_actor.current_hp -= 3
	var room: int = _map.data.room_index_at(_actor.grid_pos)
	_check(_systems.act(_actor, "item", room, 1) and _actor.current_hp == _actor.stats.max_hp(), "looted medkit is usable during a mission")
	_actor.add_item(ItemPresets.make("armour_patch"))
	_actor.ap = _actor.stats.ap_pool()
	_check(_systems.act(_actor, "item", room, 1) and _actor.damage_taken(5) == 4, "armour patch reduces incoming damage")


func _check_merc_pack() -> void:
	var merc = load("res://scenes/merc_unit.tscn").instantiate()
	for at: Vector3i in _grid.tiles:
		if _grid.is_free(at):
			merc.position = _grid.grid_to_world(at)
			break
	root.add_child(merc)
	await process_frame
	merc.job = load("res://scripts/merc_job.gd").new()
	while merc.free_slots() > 1:
		merc.add_item(ItemPresets.make("sealed_rations"))
	var loot = root.get_node("LootManager")
	loot.drop_to_pile(merc.grid_pos, ItemPresets.make("specimen"))
	var pile = loot.container_at(merc.grid_pos)
	merc.ap = merc.stats.ap_pool()
	merc._loot_in_reach()
	_check(not merc.has_item_code("specimen") and pile.codes().has("specimen"), "mercs leave two-slot loot in its source when only one slot is free")
	_grid.set_occupant(merc.grid_pos, null)
	merc.queue_free()
	await process_frame


func _check_hazards_and_darkness() -> void:
	var data := MapAscii.parse(PackedStringArray(["####################", "#..................#", "#..................#", "#..................#", "#..................#", "#..................#", "####################", "", "[topology]", "doors", "", "[obstacles]", "4,3 1,1 light fuel_tank 1.0", "6,3 1,1 light gas 1.0"]))
	_actor.aboard = true
	_map.build(data)
	await process_frame
	await physics_frame
	_move(Vector3i(15, 0, 3))
	_actor.aboard = false
	var first = _grid.cover_edge(Vector3i(3, 0, 3), MapData.Side.EAST)
	var second = _grid.cover_edge(Vector3i(7, 0, 3), MapData.Side.WEST)
	_grid.damage_cover_edge(Vector3i(3, 0, 3), MapData.Side.EAST, 8)
	_check(not first.is_intact() and not second.is_intact(), "hazards chain and reopen their footprints")
	await physics_frame
	var room := data.room_index_at(Vector3i(15, 0, 3))
	data.set_room_type(room, &"medbay")
	data.zone_power[RoomTypes.Zone.MEDICAL] = false
	_check(not _grid.tiles_have_sight(_map, Vector3i(10, 0, 2), Vector3i(17, 0, 2)), "darkness reduces sight range")
	data.zone_power[RoomTypes.Zone.MEDICAL] = true
	_check(_grid.tiles_have_sight(_map, Vector3i(10, 0, 2), Vector3i(17, 0, 2)), "restoring power restores sight")
	_check(data.movement_noise_at(Vector3i(15, 0, 3)) == 1.0, "medical movement noise is neutral")
	data.set_room_type(room, &"engine_room")
	_check(data.movement_noise_at(Vector3i(15, 0, 3)) == 1.5, "engineering movement is louder")


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
