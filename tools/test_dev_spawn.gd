extends SceneTree
## The testing mode (scripts/dev_spawn.gd): boots the real game, spawns every
## creature type through it, and checks each lands where it was put and joins
## the fight like a map-placed unit.
##
##   godot --path . --script res://tools/test_dev_spawn.gd
##
## Windowed, like the other model tests: the menu and the tile marker are only
## built with a display. DEV_SHOT=<png> also saves a screenshot with the menu open.
##
## Untyped locals and dynamic calls: a --script tool compiles before autoloads.

var _failed := 0


func _initialize() -> void:
	change_scene_to_file.call_deferred("res://scenes/main.tscn")
	_run.call_deferred()


func _run() -> void:
	for i in 30:
		await process_frame
	var main := current_scene
	var dev = main.get_node_or_null("DevSpawn")
	_check(dev != null, "main adds the DevSpawn node")
	if dev == null:
		return _finish()
	_check(dev._ui != null, "the host gets the menu in a debug build")
	var grid = root.get_node("GridManager")
	# Free tiles, spread out: one per kind, two apart so a horde has room.
	var free: Array = []
	for tile in grid.tiles:
		if grid.is_free(tile) and tile.x % 3 == 0 and tile.z % 3 == 0:
			free.append(tile)
	free.sort()
	var kinds: Array = []
	for k in dev.KINDS:
		kinds.append(k[0])
	_check(free.size() >= kinds.size(), "the deck has room to test (%d free tiles)" % free.size())
	var before := get_nodes_in_group("units").size()
	var at := 0
	for kind in kinds:
		var tile = free[at]
		at += 1
		var err: String = dev.spawn(kind, tile)
		_check(err == "", "%s spawns (%s)" % [kind, err if err != "" else "ok"])
		var unit = grid.get_tile(tile).occupant
		_check(unit != null and String(unit.name).begins_with("Dev_"),
			"%s stands on its tile %s" % [kind, tile])
		if unit != null:
			_check(unit.is_in_group("units"), "%s joins the turn order" % kind)
			_check(unit.grid_pos == tile, "%s's grid_pos is the clicked tile" % kind)
	var after := get_nodes_in_group("units").size()
	_check(after - before >= kinds.size() + 4, "horde adds a pack, not one body (%d new units)" % (after - before))
	var occupied = free[0]
	_check(dev.spawn("zombie", occupied) != "", "an occupied tile is refused")
	_check(dev.spawn("zombie", Vector3i(999, 0, 999)) != "", "a tile off the deck is refused")
	# The robot is its real model, not the placeholder.
	for node in get_nodes_in_group("units"):
		if String(node.name).begins_with("Dev_securus"):
			_check(node.visual._authored, "the spawned Securus draws its model")
			_check(node.visual._eye_material != null, "and has its eye")
		if String(node.name).begins_with("Dev_zombie") and not String(node.name).begins_with("Dev_zombie2"):
			_check(node.visual._authored and node.visual.variant == &"zombie", "the spawned Zombie draws the Mixamo model")
			_check(node.has_method("is_fodder") and node.is_fodder(), "the Zombie is Fodder")
		if String(node.name).begins_with("Dev_zombie2"):
			_check(node.visual._authored and node.visual.variant == &"zombie_2", "Zombie 2 draws the zombie 2 model")
	if OS.has_environment("DEV_SHOT"):
		dev._set_open(true)
		dev._arm("securus")
		var cam = main.camera_rig
		cam.focus_on(grid.grid_to_world(free[0]))
		for i in 40:
			await process_frame
		root.get_viewport().get_texture().get_image().save_png(OS.get_environment("DEV_SHOT"))
	_finish()


func _check(ok: bool, what: String) -> void:
	print(("  PASS  " if ok else "  FAIL  ") + what)
	if not ok:
		_failed += 1


func _finish() -> void:
	print("dev spawn: %s" % ("ALL CHECKS PASSED" if _failed == 0 else "%d FAILED" % _failed))
	quit(1 if _failed else 0)
