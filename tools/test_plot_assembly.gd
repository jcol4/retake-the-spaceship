extends SceneTree
## Runtime integration, deterministic placement and negative constraint tests.
var failures := 0

func _initialize() -> void:
	await process_frame
	var cfg := MapGenerator.Config.new()
	cfg.width = 72
	cfg.depth = 48
	cfg.profile_primary = RoomTypes.Zone.HABITATION
	_check(cfg.deck_source == MapGenerator.DeckSource.PLOT, "Plots are the default")
	for seed_value in 20:
		var data := MapGenerator.generate(seed_value, cfg)
		_check(data.layout_errors.is_empty(), "Generator integrates authored layout")
		_check(data.spawns(MapData.Spawn.PLAYER).size() == cfg.player_spawn_count, "Insertion player count")
		_check(data.hangars.size() == 2 and data.rooms_of_type(&"bunk_room").size() == 4, "Starter slot and corridor topology")
		for room in data.rooms.size():
			_check(data.touching_regions(room).size() > 1, "Doorways connect the room graph")
		_check(DeckValidator.assembled(data).is_empty(), "Runtime tail preserves reachability and spawn safety")
		var again := MapGenerator.generate(seed_value, cfg)
		_check(data.obstacles == again.obstacles and data.light_specs == again.light_specs and data.wall_pieces == again.wall_pieces, "Deterministic authored pieces and lights")
		_check(MapAscii.to_text(data) == MapAscii.to_text(again), "Seeded content/loot/spawns match")
	# Build with actual collision, catalog models and lighting, twice.
	var map = load("res://scripts/map_builder.gd").new()
	root.add_child(map)
	var data := MapGenerator.generate(7, cfg)
	map.build(data)
	await process_frame
	var choices: PackedStringArray = map.piece_log.duplicate()
	_check(" ".join(choices).contains("authored:ship_bunk"), "Builder uses authored catalog ids")
	_check(" ".join(choices).contains("authored_wreck:hangar_wreck_a"), "Builder uses authored hangar wreck")
	map.build(MapGenerator.generate(7, cfg))
	await process_frame
	_check(choices == map.piece_log, "Builder repeats exact models")
	map.queue_free()
	_constraints()
	print("Plot assembly integration: %d failures" % failures)
	quit(1 if failures else 0)

func _constraints() -> void:
	var source: PlotData = load("res://maps/plots/test_small.tres")
	var plot: PlotData = source.duplicate(true)
	var library := PlotAssembler.resources("res://maps/parcels")
	var rng := RandomNumberGenerator.new()
	var assembler := PlotAssembler.new()
	var slot: PlotSlot = plot.slots[2]
	var original := slot.sockets.duplicate()
	slot.sockets = [Vector3i(MapData.Side.EAST, 0, 2)]
	_check(PlotAssembler.candidates(slot, library).is_empty(), "Incompatible socket is rejected")
	assembler.assemble(plot, rng, library)
	_check(not assembler.errors.is_empty(), "Unfillable slot reports an authoring gap")
	slot.sockets = original
	plot.test_only = false
	assembler.assemble(plot, rng, library)
	_check(not assembler.errors.is_empty(), "Shipping plots enforce zone-required room types")
	plot.test_only = true
	slot.required_type = &"bridge"
	_check(PlotAssembler.candidates(slot, library).is_empty(), "Explicit required type is enforced")
	# Supply a complete small zone library to exercise successful constraint search.
	var complete := library.duplicate()
	for type: StringName in [&"bathroom", &"mess", &"galley"]:
		var variant: ParcelData = load("res://maps/parcels/habitation/bunk_room_a.tres").duplicate(true)
		variant.room_type = type
		complete.append(variant)
	var shipping: PlotData = source.duplicate(true)
	shipping.test_only = false
	shipping.slots[2].required_type = &"bunk_room"
	for seed_value in 10:
		rng.seed = seed_value
		var filled := assembler.assemble(shipping, rng, complete)
		_check(assembler.errors.is_empty(), "Complete library satisfies production required types")
		for type: StringName in RoomTypes.ZONE_REQUIRED[RoomTypes.Zone.HABITATION]:
			_check(not filled.rooms_of_type(type).is_empty(), "Required room is present: %s" % type)
	shipping.slots[3].required_type = &"galley"
	shipping.slots[4].required_type = &"galley"
	assembler.assemble(shipping, rng, complete)
	_check(not assembler.errors.is_empty(), "Unique-room caps reject conflicting required slots")
	var parcel: ParcelData = load("res://maps/parcels/habitation/bunk_room_a.tres").duplicate(true)
	parcel.markers[0].cell = parcel.pieces[0].cell
	_check(DeckValidator.parcel(parcel).any(func(i: Dictionary) -> bool: return i.hard and i.message.contains("occupied")), "Validator rejects occupied markers")
	var one := DeckPiece.new()
	var two := DeckLight.new()
	one.group = &"shared"
	two.group = &"shared"
	for seed_value in 30:
		rng.seed = seed_value
		_check(PlotAssembler.optional([one, two], 0, rng).size() == 1, "Pick-one groups span entry kinds")
	one.group = &""
	one.chance = PackedFloat32Array([0, 0, 1, 0])
	_check(PlotAssembler.optional([one], 0, rng).is_empty() and PlotAssembler.optional([one], 2, rng).size() == 1, "Condition chance resolved after condition selection")
	var missing := PlotAssembler.new()
	_check(missing.choose(Vector2i(84, 56), RoomTypes.Zone.MEDICAL, rng) == null and not missing.errors.is_empty(), "No procedural fallback for missing plots")

func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)
