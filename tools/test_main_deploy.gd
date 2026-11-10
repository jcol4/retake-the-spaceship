extends SceneTree
## Reproduce editor Play Scene -> loadout Deploy, without touching the save slot.
var failures := 0

func _initialize() -> void:
	await process_frame
	var campaign = root.get_node("Campaign")
	campaign.use_throwaway("", 45)
	var scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	for frame in 6: await process_frame
	var loadout: Node = null
	for child in scene.get_children():
		if child.get_script() == load("res://scripts/loadout_menu.gd"): loadout = child
	_check(loadout != null, "Main scene opens the loadout screen")
	_check(not scene.map.data.cells.is_empty() and not scene.map.player_spawns.is_empty(), "Main scene has a map and player insertion")
	_check(not root.get_node("GridManager").tiles.is_empty(), "Gameplay grid exists")
	if loadout != null: loadout._on_deploy()
	# Direct scene's ASCII deck has no insertion animation; Deploy starts the loop.
	for frame in 20: await process_frame
	_check(root.get_node("TurnManager").turn_number > 0, "Deploy starts the mission")
	_check(not scene.map._explored.is_empty(), "Squad reveals its map region")
	var visible_region := false
	for node in scene.map._fog_groups.values():
		if node.visible: visible_region = true
	_check(visible_region, "Map geometry is visible after Deploy")
	if OS.has_environment("MAIN_DEPLOY_SCREENSHOT"):
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(OS.get_environment("MAIN_DEPLOY_SCREENSHOT"))
	print("Main scene Deploy: %d failures" % failures)
	quit(1 if failures else 0)

func _check(ok: bool, message: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", message])
	if not ok:
		failures += 1
		push_error(message)
