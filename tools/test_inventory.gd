extends SceneTree
## Extraction plan Phase 3.1–3.3: items, inventory, loot sources, and the Retrieve
## objective's verdict (GDD §7.5, §4.4, §7.6, §11.9–11.10).
##
##   godot --headless --path . --script res://tools/test_inventory.gd
##
## Covers:
##   - the item codec: every item round-trips its wire code, gear included;
##   - the 4-slot cap, and equipped gear (primary, pistol, attachments, grenades)
##     taking no slot;
##   - loot costs 1 AP flat per item and needs a free slot;
##   - a corpse's gear becomes items (weapon + attachments as ONE item, each
##     grenade one item, no pistol), and is lootable;
##   - cross-owner looting of the other player's soldier's corpse (GDD §7.6), and a
##     DOWNED friendly is not lootable (decisions log);
##   - a crate blocks its tile and is looted from beside it;
##   - dropping is free and forms a pile another soldier can loot; an emptied pile
##     is gone;
##   - a robot wreck carries its Salvage as an item; a merc rolls pockets;
##   - Retrieve completes from a living carrier AND from a carried corpse, and the
##     result's loot manifest lists what came out;
##   - Contract placement on generated decks: both types supported, the Retrieve
##     crate is outside the insertion bay, in the farthest third of rooms.

const PLAYER := "res://scenes/player_unit.tscn"
const MERC := "res://scenes/merc_unit.tscn"
const SECURUS := "res://scenes/securus_unit.tscn"
const DECK := "res://maps/extraction_test.txt"

## The crate in hangar A's north-east corner of extraction_test.txt, and a tile
## beside it.
const CRATE := Vector3i(10, 0, 1)
const BESIDE_CRATE := Vector3i(11, 0, 2)
## Open floor in hangar A, clear of the pad, the square and the crate.
const ANCHOR := Vector3i(4, 0, 10)

## UnitStats.Action.LOOT by value (see test_suppression.gd for why by value).
const ACTION_LOOT := 9
const ASSAULT_RIFLE := 0
const HOLO_SIGHT := 6
const EXTENDED_MAG := 9

var _failures := 0
var _grid: Node
var _em: Node
var _loot: Node
var _om: Node
var _map: Node
var LIFE
var _items
var _contract


func _initialize() -> void:
	_grid = root.get_node_or_null("GridManager")
	_em = root.get_node_or_null("ExtractionManager")
	_loot = root.get_node_or_null("LootManager")
	_om = root.get_node_or_null("ObjectiveManager")
	LIFE = load("res://scripts/unit.gd").LifeState
	_items = load("res://scripts/item_presets.gd")
	_contract = load("res://scripts/contract.gd")
	_map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(_map)
	await process_frame
	# The extraction test deck, for its crates.
	_map.build(load("res://scripts/map_ascii.gd").load_file(DECK))
	await process_frame
	seed(777)

	_check_codec()
	await _check_slots_and_equipped_gear()
	await _check_crate_and_ap_cost()
	await _check_corpse_gear()
	await _check_cross_owner_and_downed()
	await _check_drop_pile()
	await _check_salvage_and_merc_pockets()
	await _check_retrieve_from_carried_corpse()
	_check_contract_placement()

	print("")
	if _failures == 0:
		print("inventory: ALL CHECKS PASSED")
		quit(0)
	else:
		print("inventory: %d CHECK(S) FAILED" % _failures)
		quit(1)


func _check_codec() -> void:
	var all_ok := true
	var codes: Array = []
	codes.append_array(_items.VALUABLES.keys())
	codes.append_array(_items.OBJECTIVES.keys())
	codes.append_array(["salvage:4", "grenade", "weapon:0:-:-1", "weapon:0:6.9:-1", "attachment:3", "ammo:1"])
	for code in codes:
		var item = _items.from_code(code)
		all_ok = all_ok and item != null and item.code == code
		if item == null or item.code != code:
			print("    code '%s' -> %s" % [code, item.code if item else "null"])
	_check(all_ok, "every item round-trips its wire code (%d codes)" % codes.size())
	_check(_items.VALUABLES.size() >= 6 and _items.VALUABLES.size() <= 8, "6-8 valuables")
	var tiers := {}
	for id in _items.VALUABLES:
		tiers[_items.VALUABLES[id]["tier"]] = true
	_check(tiers.size() == 3, "across three value tiers")
	_check(_items.from_code("salvage:4").value == 4 * _items.SALVAGE_CREDITS_PER_POINT, "Salvage is a valuable priced per point")
	_check(_items.from_code("bogus") == null and _items.from_code("weapon:99:-:-1") == null,
		"a code that names nothing parses to null")
	var rifle = _items.from_code("weapon:0:6.9:-1")
	var weapon = _items.weapon_from_item(rifle)
	_check(weapon != null and weapon.id == ASSAULT_RIFLE and weapon.optic != null and weapon.optic.id == HOLO_SIGHT
		and weapon.magazine != null and weapon.magazine.id == EXTENDED_MAG,
		"a weapon item rebuilds the gun with its attachments (%s)" % rifle.display_name)


func _check_slots_and_equipped_gear() -> void:
	var s = await _spawn(PLAYER, ANCHOR)
	s._equip(ASSAULT_RIFLE, PackedInt32Array([HOLO_SIGHT]), -1)
	_check(s.inventory.is_empty() and s.free_slots() == 4,
		"a soldier with a rifle, an attachment, a pistol and a grenade has all 4 slots free")
	_check(s.stats.sidearm != null and s.grenade_charges == 1, "(and does carry the pistol and grenade)")
	for i in 4:
		_check(s.add_item(_items.make("crew_tags")), "slot %d takes an item" % (i + 1))
	_check(not s.add_item(_items.make("crew_tags")), "a fifth item is refused")
	_check(s.inventory.size() == 4 and s.inventory_codes.size() == 4, "4 items, mirrored as 4 codes")
	_check(s.inventory_codes[0] == "crew_tags", "the replicated codes name the items")
	var removed = s.remove_item(0)
	_check(removed != null and s.free_slots() == 1 and s.inventory_codes.size() == 3, "removing frees the slot")
	await _free([s])


func _check_crate_and_ap_cost() -> void:
	var crate = _loot.container_at(CRATE)
	_check(crate != null and crate.items.size() == 2, "the deck's crate exists with its 2 items")
	_check(not _grid.is_free(CRATE), "and blocks its tile")
	_check(_grid.find_path(ANCHOR, CRATE, 99).is_empty(), "nothing paths onto it")
	var looter = await _spawn(PLAYER, BESIDE_CRATE)
	_check(looter.action_cost(ACTION_LOOT) == 1, "loot is 1 AP flat")
	_check(crate in looter.loot_sources(), "a soldier beside it sees it as a source")
	looter.ap = 5
	var first_code: String = crate.items[0].code
	await looter.try_loot(crate, 0, first_code)
	_check(looter.ap == 4 and looter.inventory.size() == 1 and looter.inventory[0].code == first_code,
		"taking one item costs 1 AP and puts it in the pack (%d AP left)" % looter.ap)
	_check(crate.items.size() == 1, "and leaves the crate one item lighter")
	await looter.try_loot(crate, 0, "not_what_is_there")
	_check(looter.inventory.size() == 1 and looter.ap == 4, "a stale panel row (wrong code) takes nothing, costs nothing")
	looter.ap = 0
	await looter.try_loot(crate, 0)
	_check(looter.inventory.size() == 1 and crate.items.size() == 1, "no AP, no loot")
	# Full pack.
	for i in 3:
		looter.add_item(_items.make("sealed_rations"))
	looter.ap = 5
	await looter.try_loot(crate, 0)
	_check(looter.ap == 5 and crate.items.size() == 1, "a full pack refuses, at no cost")
	var far = await _spawn(PLAYER, ANCHOR)
	_check(not (crate in far.loot_sources()) and far.take_blocker(crate, 0) == "out of reach",
		"a soldier across the room is out of reach")
	await _free([looter, far])


func _check_corpse_gear() -> void:
	var dead = await _spawn(PLAYER, ANCHOR)
	dead._equip(ASSAULT_RIFLE, PackedInt32Array([HOLO_SIGHT, EXTENDED_MAG]), -1)
	dead.add_item(_items.make("fusion_cell"))
	dead.take_damage(9999)
	_check(dead.life_state == LIFE.DOWNED and dead.inventory.size() == 1, "downed: the pack is untouched, gear still equipped")
	dead.die()
	var codes: PackedStringArray = dead.inventory_codes
	_check(dead.inventory.size() == 3, "dead: pack + rifle + grenade = 3 items (got %s)" % [codes])
	_check(codes.has("fusion_cell"), "the pack is still there")
	var rifle_code := ""
	for code in codes:
		if code.begins_with("weapon:"):
			rifle_code = code
	_check(rifle_code == "weapon:0:6.9:-1", "the rifle is ONE item with both attachments (%s)" % rifle_code)
	_check(codes.has("grenade") and dead.grenade_charges == 0, "the grenade is one item")
	var pistols := 0
	for code in codes:
		if code.begins_with("weapon:5"):
			pistols += 1
	_check(pistols == 0, "the issued pistol is not loot")
	dead.die()
	_check(dead.inventory.size() == 3, "dying twice converts nothing twice")
	var looter = await _spawn(PLAYER, ANCHOR + Vector3i(1, 0, 0))
	_check(dead in looter.loot_sources(), "the corpse is a loot source")
	looter.ap = 5
	var rifle_index: int = dead.find_item_code(rifle_code)
	await looter.try_loot(dead, rifle_index)
	_check(looter.has_item_code(rifle_code) and dead.inventory.size() == 2, "and its rifle can be taken off it")
	await _free([dead, looter])


func _check_cross_owner_and_downed() -> void:
	var mine = await _spawn(PLAYER, ANCHOR)
	var theirs = await _spawn(PLAYER, ANCHOR + Vector3i(1, 0, 1))
	var bleeding = await _spawn(PLAYER, ANCHOR + Vector3i(-1, 0, 0))
	mine.owner_peer_id = 1
	theirs.owner_peer_id = 2
	bleeding.owner_peer_id = 2
	theirs.add_item(_items.make("prototype_chip"))
	theirs.take_damage(9999)
	theirs.die()
	bleeding.add_item(_items.make("gold_chronometer"))
	bleeding.take_damage(9999)
	_check(theirs.loot_blocker(mine) == "", "peer 1's soldier may loot peer 2's corpse")
	mine.ap = 5
	var idx: int = theirs.find_item_code("prototype_chip")
	await mine.try_loot(theirs, idx)
	_check(mine.has_item_code("prototype_chip") and theirs.owner_peer_id == 2, "and does; the corpse stays peer 2's")
	_check(bleeding.life_state == LIFE.DOWNED and bleeding.loot_blocker(mine) == "not a corpse",
		"a DOWNED squadmate cannot be looted")
	_check(not (bleeding in mine.loot_sources()), "and is not offered as a source")
	await _free([mine, theirs, bleeding])


func _check_drop_pile() -> void:
	var a = await _spawn(PLAYER, ANCHOR)
	var b = await _spawn(PLAYER, ANCHOR + Vector3i(1, 0, 0))
	a.add_item(_items.make("encrypted_drive"))
	a.ap = 0
	await a.try_drop_item(0)
	var pile = _loot.container_at(ANCHOR)
	_check(a.inventory.is_empty() and pile != null and pile.is_pile, "dropping is free (at 0 AP) and forms a pile")
	_check(pile.items.size() == 1 and pile.items[0].code == "encrypted_drive", "holding the item")
	_check(_grid.get_tile(ANCHOR).occupant == a, "a pile does not block: the dropper still stands there")
	_check(pile in b.loot_sources(), "a squadmate beside it can loot it")
	b.ap = 5
	await b.try_loot(pile, 0)
	_check(b.has_item_code("encrypted_drive"), "and takes it")
	await process_frame
	_check(_loot.container_at(ANCHOR) == null, "an emptied pile is gone")
	await _free([a, b])


func _check_salvage_and_merc_pockets() -> void:
	var robot = await _spawn(SECURUS, ANCHOR + Vector3i(2, 0, 0))
	robot.salvage_value = 3
	robot.take_damage(9999)
	_check(robot.life_state == LIFE.DEAD and robot.has_item_code("salvage:3"),
		"a destroyed robot carries its Salvage as an item (%s)" % [robot.inventory_codes])
	var looter = await _spawn(PLAYER, ANCHOR + Vector3i(1, 0, 0))
	_check(robot in looter.loot_sources(), "the wreck is lootable")
	var pockets: Array = load("res://scripts/merc_presets.gd").roll_inventory()
	_check(pockets.size() >= 1 and pockets.size() <= 2, "a merc rolls 1-2 items for its pockets (%d)" % pockets.size())
	var merc = load(MERC).instantiate()
	merc.stats = load("res://scripts/merc_presets.gd").rifleman("Merc_T")  # an SMG, as main.gd spawns them
	var pocket_count := pockets.size()
	merc.inventory = pockets
	merc.position = _grid.grid_to_world(ANCHOR + Vector3i(0, 0, -1))
	root.add_child(merc)
	await process_frame
	_check(merc.inventory_codes.size() == pockets.size(), "a pack handed over before spawn is mirrored as codes")
	merc.take_damage(9999)
	_check(merc.life_state == LIFE.DEAD and merc.inventory.size() == pocket_count + 1,
		"a dead merc's corpse holds its pockets plus its gun (%s)" % [merc.inventory_codes])
	await _free([robot, looter, merc])


## Plan 3.3 "Done when": Retrieve counts from a carried corpse.
func _check_retrieve_from_carried_corpse() -> void:
	var data = load("res://scripts/map_ascii.gd").load_file(DECK)
	var rules = load("res://scripts/extraction_rules.gd").new()
	rules.setup(data.hangars)
	var c = _contract.new()
	c.type = _contract.Type.RETRIEVE
	c.target_tile = Vector3i(37, 0, 1)  # hangar B's crate
	c.item_code = "data_core"
	c.payout = 500
	_om.begin_mission(c)
	var crate = _loot.container_at(c.target_tile)
	_check(crate != null and crate.has_objective(), "the contract plants the item in its crate")
	_check(_om.status_text().contains("not found"), "objective line: not found (%s)" % _om.status_text())
	var square_centre: Vector3i = data.hangars[0].square[4]
	var carrier = await _spawn(PLAYER, ANCHOR)
	var corpse = await _spawn(PLAYER, ANCHOR + Vector3i(1, 0, 0))
	# The corpse's soldier got the item out of the crate before dying.
	var idx := -1
	for i in crate.items.size():
		if crate.items[i].code == "data_core":
			idx = i
	corpse.add_item(_loot.take(crate, idx))
	corpse.take_damage(9999)
	corpse.die()
	_check(_om.status_text().contains("body"), "objective line: on the body (%s)" % _om.status_text())
	var split_left: Dictionary = rules.split_passengers(0, [carrier, corpse], _em.riders_of)
	_check(not _om.is_complete(split_left["extracted"]), "not carried aboard: Retrieve is not complete")
	carrier.pick_up(corpse)
	carrier.relocate_to(square_centre)
	var split: Dictionary = rules.split_passengers(0, [carrier, corpse], _em.riders_of)
	var result = _em.build_result(split)
	_check(result.objective_complete, "the item on a CARRIED corpse completes Retrieve")
	_check(result.contract.get("item", "") == "data_core", "the result carries the contract")
	_check("data_core" in result.loot_codes(), "and the item is in the loot manifest (%s)" % [result.loot])
	var wire = load("res://scripts/mission_result.gd").from_dict(bytes_to_var(var_to_bytes(result.to_dict())), root)
	_check(wire.objective_complete and wire.loot_codes() == result.loot_codes() and wire.contract == result.contract,
		"objective, loot and contract survive the wire")
	# A living carrier counts too.
	carrier.drop_carried()
	var idx2: int = corpse.find_item_code("data_core")
	carrier.add_item(corpse.remove_item(idx2))
	_check(_om.status_text().contains("carried by"), "objective line: carried by (%s)" % _om.status_text())
	var split2: Dictionary = rules.split_passengers(0, [carrier], _em.riders_of)
	_check(_om.is_complete(split2["extracted"]), "the item in a living soldier's pack completes Retrieve")
	_om.reset()
	_check(not _om.is_active(), "reset clears the contract")
	await _free([carrier, corpse])


func _check_contract_placement() -> void:
	var gen = load("res://scripts/map_generator.gd")
	var both := 0
	var far_ok := true
	var outside_ok := true
	var destroy_ok := true
	const DECKS := 40
	for s in range(1, DECKS + 1):
		var data = gen.generate(s)
		var types: Array = _contract.supported_types(data)
		if types.has(_contract.Type.RETRIEVE) and types.has(_contract.Type.DESTROY):
			both += 1
		var dist: Dictionary = _contract.path_distances(data)
		var r = _contract.make(_contract.Type.RETRIEVE, data)
		if r != null:
			var spot = data.container_at(r.target_tile)
			outside_ok = outside_ok and spot != null and data.hangar_index_at(r.target_tile) < 0 \
				and r.item_code in _items.OBJECTIVES
			# Far third: no more than a third of the crate rooms are farther away.
			var rooms := {}
			for c in data.containers:
				var room: int = data.room_index_at(c.pos)
				if data.hangar_index_at(c.pos) >= 0:
					continue
				var d: int = _contract._tile_dist(data, c.pos, dist)
				rooms[room] = mini(rooms.get(room, 999999), d)
			var mine: int = rooms[data.room_index_at(r.target_tile)]
			var farther := 0
			for room in rooms:
				if rooms[room] > mine:
					farther += 1
			far_ok = far_ok and farther < ceili(float(rooms.size()) / 3.0)
		var d = _contract.make(_contract.Type.DESTROY, data)
		destroy_ok = destroy_ok and d != null and d.place_nest and data.is_passable(d.target_tile) \
			and dist.has(d.target_tile) and data.hangar_index_at(d.target_tile) < 0
	_check(both == DECKS, "every generated deck supports Retrieve and Destroy (%d/%d)" % [both, DECKS])
	_check(outside_ok, "Retrieve plants in a crate in an ordinary room")
	_check(far_ok, "in a room from the farthest third by path distance")
	_check(destroy_ok, "Destroy places a nest on reachable floor outside every hangar")
	var a = _contract.choose(gen.generate(9))
	var b = _contract.choose(gen.generate(9))
	_check(a != null and b != null and a.type in _contract.supported_types(gen.generate(9)), "choose returns a contract of a supported type")
	seed(5)
	var c1 = _contract.choose(gen.generate(9))
	seed(5)
	var c2 = _contract.choose(gen.generate(9))
	_check(c1.to_dict() == c2.to_dict(), "and the same seed chooses the same contract (co-op)")
	var test_deck = load("res://scripts/map_ascii.gd").load_file(DECK)
	var r2 = _contract.make(_contract.Type.RETRIEVE, test_deck)
	_check(r2 != null and test_deck.hangar_index_at(r2.target_tile) == 1,
		"on extraction_test (all rooms hangars) Retrieve falls back to the far bay's crates")


func _spawn(scene_path: String, at: Vector3i):
	var unit = load(scene_path).instantiate()
	unit.position = _grid.grid_to_world(at)
	root.add_child(unit)
	await process_frame
	return unit


func _free(units: Array) -> void:
	for unit in units:
		if is_instance_valid(unit):
			var t = _grid.get_tile(unit.grid_pos)
			if t and t.occupant == unit:
				_grid.set_occupant(unit.grid_pos, null)
			unit.remove_from_group("units")
			unit.remove_from_group("player_units")
			unit.queue_free()
	await process_frame


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
