extends SceneTree
## The mission snapshot (MULTIPLAYER_PLAN.md §2.5): what a rejoining co-op client
## catches up from, and what a co-op host's checkpoint resumes from.
##
##   godot --headless --path . --script res://tools/test_mission_snapshot.gd
##
## On a real contract deck built through the real mission scene (main.tscn):
##   1. play some changes onto the board — a soldier hurt and injured and moved,
##      grenades spent, a hostile killed, another made aware, a crate looted and a
##      pile dropped, cover hit, a hangar discovered, the hivemind roused — plus a
##      mid-mission spawn when the deck has a nest;
##   2. capture, and check the capture survives the checkpoint file (var_to_str)
##      unchanged;
##   3. tear the mission down, build the SAME deployment's board again from scratch,
##      apply the snapshot as a resuming host, capture again — and compare the two
##      captures section by section, unit by unit;
##   4. the same again as a rejoining client.
## Never touches the player's slot (a throwaway campaign with no file).

const MAIN := "res://scenes/main.tscn"
const SEED := 4242

var _failures := 0
var _campaign: Node
var _snap_script
## Set by `_play_changes`: a merc who left the board, a soldier put aboard.
var _gone := ""
var _aboard := ""


func _initialize() -> void:
	_campaign = root.get_node("Campaign")
	_snap_script = load("res://scripts/net/mission_snapshot.gd")
	await process_frame  # the autoloads' `multiplayer` exists once the tree runs
	_campaign.use_throwaway("", SEED)
	var state = _campaign.state
	var ids: Array = []
	for r in state.roster:
		ids.append(r.id)
	# Prefer a Destroy contract: its nest gives the journal a spawn to replay.
	var offer := 0
	for i in state.contracts.size():
		if state.contracts[i].type == 1:
			offer = i
	var err: String = _campaign.launch(ids, offer)
	_check(err == "", "a deployment to build from (%s)" % err)
	var deployment: Dictionary = _campaign.deployment.duplicate(true)

	var main := await _build(deployment)
	_check(main != null and _units(main).size() > 4, "the mission board is built (%d units)" % _units(main).size())
	await _play_changes(main)
	var first: Dictionary = _snap_script.capture(main)
	var text: String = _snap_script.to_text(first)
	var back: Dictionary = _snap_script.from_text(text)
	_check(back == first, "the snapshot survives the checkpoint file unchanged (%d chars)" % text.length())

	await _teardown(main)
	var rebuilt := await _build(deployment)
	var before: Dictionary = _snap_script.capture(rebuilt)
	_check(before["units"] != first["units"], "the fresh board differs from the played one (the test means something)")
	_snap_script.apply(rebuilt, back, true)
	await process_frame
	var second: Dictionary = _snap_script.capture(rebuilt)
	_compare(first, second)

	await _teardown(rebuilt)
	# The same, as a rejoining client applies it (it also sets the round locally).
	var client := await _build(deployment)
	_snap_script.apply(client, back, false)
	await process_frame
	var third: Dictionary = _snap_script.capture(client)
	print("  -- as a rejoining client:")
	_compare(first, third)
	await _teardown(client)
	print("")
	if _failures == 0:
		print("mission snapshot: ALL CHECKS PASSED")
		quit(0)
	else:
		print("mission snapshot: %d CHECK(S) FAILED" % _failures)
		quit(1)


func _build(deployment: Dictionary) -> Node:
	_campaign.deployment = deployment.duplicate(true)
	_campaign.deployment_fresh = true
	var main: Node = load(MAIN).instantiate()
	root.add_child(main)
	for _i in 4:
		await process_frame
	return main


func _teardown(main: Node) -> void:
	root.get_node("TurnManager").abandon()
	main.queue_free()
	for _i in 3:
		await process_frame


func _units(main: Node) -> Array:
	return main.get_children().filter(func(n: Node) -> bool:
		return n.get_script() != null and n.has_method("take_damage") and not n.is_queued_for_deletion())


func _play_changes(main: Node) -> void:
	var systems = main.get_node("TestMap/RoomSystems")
	var rooms: Dictionary = systems.capture()
	rooms.revealed = true
	rooms.robots = false
	for zone in rooms.power:
		rooms.power[zone] = true
	for room in rooms.doors:
		rooms.doors[room].open = true
		rooms.doors[room].breach = 1
	rooms.used[0] = true
	systems.restore(rooms)
	var grid := root.get_node("GridManager")
	var loot := root.get_node("LootManager")
	var players: Array = _units(main).filter(func(u: Node) -> bool: return u.get("record_id") != null and u.record_id != "")
	var hostiles: Array = _units(main).filter(func(u: Node) -> bool: return u.get("alert_state") != null and u.get("crew_id") == null)
	_check(players.size() >= 2 and hostiles.size() >= 2, "soldiers and hostiles to work with")
	# A soldier hurt, injured, moved, a grenade spent.
	var p = players[0]
	p.take_damage(3)
	p.apply_injuries([4])
	p.grenade_charges = 0
	var dest: Vector3i = p.grid_pos
	for n in grid.neighbors(p.grid_pos):
		if grid.is_free(n):
			dest = n
			break
	grid.set_occupant(p.grid_pos, null)
	p.grid_pos = dest
	p.global_position = grid.grid_to_world(dest)
	grid.set_occupant(dest, p)
	p.rotation.y = 1.25
	p.ammo = 3
	# A hostile killed; another made aware.
	hostiles[0].take_damage(9999)
	hostiles[1]._set_state(2)
	# A crate looted, an item dropped into a pile.
	for c in loot.all_containers():
		if not c.items.is_empty():
			var item = loot.take(c, 0)
			loot.drop_to_pile(p.grid_pos, item)
			break
	# Cover hit.
	for tile in grid.tiles.values():
		var hit := false
		for side in tile.cover_edges:
			grid.damage_cover_edge(tile.pos if tile.get("pos") != null else grid.world_to_grid(tile.world_pos), side, 1)
			hit = true
			break
		if hit:
			break
	# A hangar found.
	var em := root.get_node("ExtractionManager")
	if em.is_active():
		for i in em.rules.hangar_count():
			if not em.rules.is_discovered(i):
				em.rules.discover(i)
				break
	root.get_node("AlienHivemind").is_escalated = true
	# A merc flies out (leaves the board for good); a soldier is already aboard.
	for u in _units(main):
		if u.get("crew_id") != null and u.has_method("board_ship"):
			_gone = String(u.name)
			u.board_ship()
			break
	if _gone == "" and hostiles.size() >= 3:
		# No merc on this deck: take a hostile off the way an absorbed worm leaves.
		var h = hostiles[2]
		_gone = String(h.name)
		grid.set_occupant(h.grid_pos, null)
		for g in h.get_groups():
			h.remove_from_group(g)
		h.queue_free()
	if players.size() >= 2:
		_aboard = String(players[1].name)
		em._take_aboard(PackedStringArray([String(players[1].get_path())]))
	# A mid-mission spawn, if the deck has a nest.
	for u in _units(main):
		if u.has_method("spawn_unit") and u.has_method("free_spawn_tile"):
			var tile: Vector3i = u.free_spawn_tile()
			if tile != u.NO_SPAWN_TILE:
				u.spawn_unit(0, tile)
			break
	await process_frame


func _compare(a: Dictionary, b: Dictionary) -> void:
	_check(a["journal"] == b["journal"], "journal: %d entr(ies) carried over" % (a["journal"] as Array).size())
	_check(a["turn"] == b["turn"], "the round")
	_check(a["loot"] == b["loot"], "every container's contents (%d)" % (a["loot"] as Array).size())
	_check(a["hangars"] == b["hangars"], "hangars")
	_check(a["rooms"] == b["rooms"], "room power, locks, services, terminals and fabrication stock")
	_check(a["objective"] == b["objective"] and a["world"] == b["world"], "objective and world")
	var by_name := {}
	for u: Dictionary in b["units"]:
		by_name[u["name"]] = u
	_check(by_name.size() == (a["units"] as Array).size(), "the same units (%d vs %d)" % [(a["units"] as Array).size(), by_name.size()])
	var mismatched := 0
	for u: Dictionary in a["units"]:
		var other: Dictionary = by_name.get(u["name"], {})
		if other.is_empty():
			print("    missing after apply: %s" % u["name"])
			mismatched += 1
			continue
		for section in ["props", "extra"]:
			for key in u[section]:
				var x = u[section][key]
				var y = other[section].get(key)
				var same: bool = is_equal_approx(x, y) if x is float and y is float else \
					(x.is_equal_approx(y) if x is Vector3 and y is Vector3 else x == y)
				if not same:
					print("    %s.%s.%s: %s vs %s" % [u["name"], section, key, x, y])
					mismatched += 1
	_check(mismatched == 0, "every unit's state matches after the rebuild (%d mismatch(es))" % mismatched)
	if _gone != "":
		_check(not by_name.has(_gone), "a unit that left the board stays off the rebuilt one (%s)" % _gone)
	if _aboard != "":
		_check(by_name.has(_aboard) and bool(by_name[_aboard]["extra"]["aboard"]), "a soldier aboard is still aboard (%s)" % _aboard)


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
