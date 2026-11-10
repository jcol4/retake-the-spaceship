@tool
extends SceneTree
## Run with --editor --script; exercises the installed plugin and editor undo.
var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	for frame in 15: await process_frame
	while EditorInterface.get_resource_filesystem().is_scanning(): await process_frame
	for frame in 30: await process_frame
	var plugin := _find_plugin(root)
	if plugin == null:
		push_error("Deck Editor plugin was not loaded")
		quit(1)
		return
	var parcel: ParcelData = load("res://maps/parcels/habitation/bunk_room_a.tres").duplicate(true)
	plugin._set_document(parcel)
	plugin._select([parcel.pieces[0]])
	var original: Vector2i = parcel.pieces[0].cell
	plugin._move(Vector2i.ONE)
	_check(parcel.pieces[0].cell == original + Vector2i.ONE, "move selection")
	var manager = plugin.get_undo_redo()
	var undo = manager.get_history_undo_redo(manager.get_object_history_id(parcel))
	undo.undo()
	_check(parcel.pieces[0].cell == original, "undo move")
	undo.redo()
	_check(parcel.pieces[0].cell == original + Vector2i.ONE, "redo move")
	undo.undo()
	var count := parcel.pieces.size()
	plugin._duplicate()
	_check(parcel.pieces.size() == count + 1, "duplicate")
	plugin._delete()
	_check(parcel.pieces.size() == count, "delete")
	var child := DeckPiece.new()
	child.stack_on = 0
	plugin._array_add("pieces", child)
	var parent := parcel.pieces[0]
	plugin._select([parent, child])
	plugin._duplicate()
	_check(parcel.pieces[-1].stack_on == parcel.pieces.size() - 2, "duplicate remaps stacking parent")
	plugin._delete()
	plugin._select([parent])
	plugin._delete()
	_check(child.stack_on == -1, "deleting stacking parent clears reference")
	plugin.group_edit.text = "test_group"
	plugin._select([parcel.pieces[0], parcel.pieces[1]])
	plugin._group()
	_check(parcel.pieces[0].group == &"test_group" and parcel.pieces[1].group == &"test_group", "selection group")
	# All saves are allowed, including a deliberately invalid authoring resource.
	parcel.terrain = PackedByteArray()
	DirAccess.make_dir_recursive_absolute("res://.godot/deck_editor_tests")
	var path := "res://.godot/deck_editor_tests/invalid.tres"
	_check(ResourceSaver.save(parcel, path) == OK, "invalid content still saves")
	plugin._set_document(load("res://maps/plots/test_small.tres").duplicate(true))
	_check(plugin.issues.all(func(i: Dictionary) -> bool: return not i.hard), "plot validator in editor")
	plugin._select([])
	if OS.has_environment("DECK_EDITOR_SCREENSHOT"):
		plugin._thumb_queue.clear()
		EditorInterface.set_main_screen_editor("Deck Editor")
		plugin._make_visible(true)
		plugin._preview()
		while plugin.preview_timer.is_stopped() == false:
			await process_frame
		for frame in 20: await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(OS.get_environment("DECK_EDITOR_SCREENSHOT"))
	# Editor scans/imports asynchronously; allow its startup scan to finish.
	while EditorInterface.get_resource_filesystem().is_scanning(): await process_frame
	print("Deck Editor: %d failures" % failures)
	quit(1 if failures else 0)

func _find_plugin(node: Node) -> Node:
	if node is EditorPlugin and node.get_script() != null and node.get_script().resource_path == "res://addons/deck_editor/plugin.gd": return node
	for child in node.get_children():
		var found := _find_plugin(child)
		if found != null: return found
	return null

func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)
