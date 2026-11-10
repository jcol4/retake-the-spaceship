extends SceneTree
## Runtime SubViewport renderer used by the editor; never loads editor code.

func _initialize() -> void:
	await process_frame
	var path := "res://maps/plots/test_small.tres"
	var output := "res://out/parcel_preview.png"
	var seed_value := 1
	var condition := 0
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--resource="): path = argument.trim_prefix("--resource=")
		elif argument.begins_with("--out="): output = argument.trim_prefix("--out=")
		elif argument.begins_with("--preview-seed="): seed_value = int(argument.trim_prefix("--preview-seed="))
		elif argument.begins_with("--condition="): condition = int(argument.trim_prefix("--condition="))
	var resource := load(path)
	var plot: PlotData
	if resource is ParcelData:
		plot = PlotData.new()
		plot.test_only = true
		plot.size = resource.size + Vector2i(2, 2)
		plot.terrain.resize(plot.size.x * plot.size.y)
		plot.terrain.fill(MapData.Terrain.WALL)
		var slot := PlotSlot.new()
		slot.zone = resource.zone
		slot.rect = Rect2i(Vector2i.ONE, resource.size)
		slot.required_type = resource.room_type
		plot.slots.append(slot)
	else: plot = resource as PlotData
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var assembler := PlotAssembler.new()
	var data := assembler.assemble(plot, rng, [resource] if resource is ParcelData else [], condition)
	if not assembler.errors.is_empty():
		push_error("; ".join(assembler.errors))
		quit(1)
		return
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1200, 900)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var map = load("res://scripts/map_builder.gd").new()
	map.fog_of_war = false
	viewport.add_child(map)
	map.build(data)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("171e29")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color(0.65, 0.7, 0.8)
	environment.environment.ambient_light_energy = 0.55
	viewport.add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -30, 0)
	sun.light_energy = 0.6
	viewport.add_child(sun)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = maxf(data.size.x, data.size.y) * 1.7
	camera.far = 500
	viewport.add_child(camera)
	var center := Vector3(data.size.x * 0.75, 0, data.size.y * 0.75)
	camera.position = center + Vector3(65, 85, 65)
	camera.look_at(center)
	camera.make_current()
	# Show interior wall faces by using the same cutaway pass as gameplay.
	map._revealed = {}
	for i in data.rooms.size(): map._revealed[i] = true
	map._occlusion_step = Vector3i(1, 0, 1)
	map._apply_wall_occlusion(Vector3i(1, 0, 1))
	for frame in 8: await process_frame
	await RenderingServer.frame_post_draw
	var error := viewport.get_texture().get_image().save_png(output)
	print("Parcel preview: %s (%s)" % [output, error_string(error)])
	quit(0 if error == OK else 1)
