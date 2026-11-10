extends SceneTree
## Windowed visual check of actual generated furniture, lighting and room labels.
## godot --path . --script res://tools/preview_room_gameplay.gd -- --room=engine_room --out=C:/tmp/rooms.png


func _initialize() -> void:
	await process_frame
	root.mode = Window.MODE_WINDOWED
	root.size = Vector2i(1600, 1000)
	root.set_flag(Window.FLAG_NO_FOCUS, true)
	var wanted := &"engine_room"
	var output := "user://room_gameplay_preview.png"
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--room="):
			wanted = StringName(argument.trim_prefix("--room="))
		if argument.begins_with("--out="):
			output = argument.trim_prefix("--out=")
	var map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(map)
	await process_frame
	var cfg := MapGenerator.Config.new()
	cfg.profile_primary = RoomTypes.Zone.ENGINEERING
	cfg.profile_secondary = RoomTypes.Zone.COMMAND
	map.build_generated(7, cfg)
	var systems = map.get_node("RoomSystems")
	systems.revealed = true
	systems._refresh_world()
	var room: int = map.data.rooms_of_type(wanted)[0]
	var rect: Rect2i = map.data.rooms[room]
	var center := Vector3(rect.get_center().x * 1.5, 0, rect.get_center().y * 1.5)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.025, 0.035, 0.05)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color(0.5, 0.57, 0.65)
	environment.environment.ambient_light_energy = 0.7
	root.add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -30, 0)
	sun.light_energy = 1.0
	root.add_child(sun)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = maxf(rect.size.x, rect.size.y) * 1.8
	camera.far = 300
	root.add_child(camera)
	camera.position = center + Vector3(30, 35, 30)
	camera.look_at(center)
	camera.make_current()
	# A real player keeps the room cutaway and labels on the normal runtime path.
	var actor = load("res://scenes/player_unit.tscn").instantiate()
	actor.name = "PreviewSoldier"
	actor.stats = load("res://scripts/unit_stats.gd").new()
	actor.stats.weapon = load("res://scripts/weapon_presets.gd").make(0)
	for pos in map.data.room_of:
		if map.data.room_of[pos] == room and map.data.is_passable(pos):
			actor.position = Vector3(pos.x * 1.5, 0, pos.z * 1.5)
			break
	root.add_child(actor)
	var hud = load("res://scenes/hud.tscn").instantiate()
	root.add_child(hud)
	var turns = root.get_node("TurnManager")
	turns.active_unit = actor
	turns.mode = 0
	turns.unit_selected.emit(actor)
	hud._refresh_room_controls()
	for _frame in 12:
		await process_frame
	await RenderingServer.frame_post_draw
	var error := root.get_texture().get_image().save_png(output)
	print("room preview: %s (%s)" % [ProjectSettings.globalize_path(output), error_string(error)])
	quit(0 if error == OK else 1)
