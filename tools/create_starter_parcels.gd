extends SceneTree
## Rebuild the deliberately minimal authoring examples. No shipping plot is implied.

func _initialize() -> void:
	var hangar := ParcelData.new()
	hangar.display_name = "Standard hangar"
	hangar.zone = ParcelData.ZONE_HANGAR
	hangar.room_type = RoomTypes.HANGAR
	hangar.size = Vector2i(18, 14) # Actual bays are 210–280 tiles, not 14x12.
	hangar.terrain = _floor(hangar.size)
	hangar.sockets_ok = [Vector3i(MapData.Side.EAST, 6, 2)]
	var pad := DeckMarker.new()
	pad.kind = DeckMarker.Kind.PAD
	pad.cell = Vector2i(7, 5)
	pad.ramp_side = MapData.Side.SOUTH
	hangar.markers.append(pad)
	for at in [Vector2i(3, 3), Vector2i(13, 3), Vector2i(3, 11), Vector2i(13, 11)]:
		hangar.lights.append(_light(at))
	var crate_id := _id("cover_light")
	for spec in [[Vector2i(12, 1), "hangar_wreck_a", [1, 1, 1, 1]], [Vector2i(1, 1), "hangar_wreck_b", [0.2, 0.5, 0.9, 0.8]], [Vector2i(12, 10), "hangar_wreck_c", [0.1, 0.7, 0.2, 1]]]:
		var wreck := _piece(spec[1], spec[0])
		wreck.chance = PackedFloat32Array(spec[2])
		hangar.pieces.append(wreck)
	for at in [Vector2i(2, 6), Vector2i(14, 5), Vector2i(14, 9)]:
		var piece := _piece(crate_id, at)
		if at.y == 9: piece.chance = PackedFloat32Array([0.3, 0.7, 1, 0.5])
		hangar.pieces.append(piece)
	_save(hangar, "res://maps/parcels/hangar/hangar_standard.tres")
	var bunk := ParcelData.new()
	bunk.display_name = "Bunk room A"
	bunk.zone = RoomTypes.Zone.HABITATION
	bunk.room_type = &"bunk_room"
	bunk.size = Vector2i(8, 10)
	bunk.terrain = _floor(bunk.size)
	bunk.sockets_ok = [Vector3i(MapData.Side.NORTH, 3, 2), Vector3i(MapData.Side.SOUTH, 3, 2)]
	for z in [2, 6]:
		for x in [0, 6]:
			var piece := _piece("ship_bunk", Vector2i(x, z))
			piece.chance = PackedFloat32Array([1, 0.65, 1, 0.4])
			bunk.pieces.append(piece)
	var terminal := _piece(_id("terminal_wall"), Vector2i(7, 4))
	terminal.wall_side = MapData.Side.EAST
	terminal.offset.y = 1.2
	bunk.pieces.append(terminal)
	for z in [2, 6]:
		var locker := _piece(_id("furniture_locker"), Vector2i(0, z + 1))
		# Floor-standing lockers use their catalog footprint and face into the room.
		locker.rot = 3
		bunk.pieces.append(locker)
	for z in [2, 7]: bunk.lights.append(_light(Vector2i(4, z)))
	var flicker := _light(Vector2i(1, 4))
	flicker.preset = DeckLight.Preset.FLICKER
	bunk.lights.append(flicker)
	for at in [Vector2i(1, 8), Vector2i(6, 8)]:
		var crate := _piece(crate_id, at)
		crate.group = &"barricade"
		crate.chance = PackedFloat32Array([0, 0.1, 1, 0.2])
		bunk.pieces.append(crate)
	var loot := DeckMarker.new()
	loot.kind = DeckMarker.Kind.LOOT
	loot.cell = Vector2i(1, 4)
	bunk.markers.append(loot)
	var enemy := DeckMarker.new()
	enemy.cell = Vector2i(6, 4)
	bunk.markers.append(enemy)
	_save(bunk, "res://maps/parcels/habitation/bunk_room_a.tres")
	var plot := PlotData.new()
	plot.display_name = "Small authoring test (Habitation only)"
	plot.test_only = true
	plot.terrain.resize(72 * 48)
	plot.terrain.fill(MapData.Terrain.WALL)
	# Two spines with cross passages; all remaining space is solid hull.
	plot.corridor_rects = [Rect2i(21, 1, 2, 46), Rect2i(49, 1, 2, 46), Rect2i(23, 7, 26, 2), Rect2i(23, 37, 26, 2)]
	plot.corridor_types = [RoomTypes.SPINE, RoomTypes.SPINE, RoomTypes.CORRIDOR, RoomTypes.CORRIDOR]
	for rect in plot.corridor_rects: _paint(plot, rect, MapData.Terrain.FLOOR)
	for rect in [Rect2i(2, 14, 18, 14), Rect2i(52, 14, 18, 14)]:
		var slot := PlotSlot.new()
		slot.zone = ParcelData.ZONE_HANGAR
		slot.rect = rect
		slot.sockets = [Vector3i(MapData.Side.EAST if rect.position.x == 2 else MapData.Side.WEST, 6, 2)]
		plot.slots.append(slot)
	for at in [Vector2i(26, 10), Vector2i(37, 10), Vector2i(26, 26), Vector2i(37, 26)]:
		var slot := PlotSlot.new()
		slot.rect = Rect2i(at, bunk.size)
		slot.zone = RoomTypes.Zone.HABITATION
		slot.sockets = bunk.sockets_ok.duplicate()
		plot.slots.append(slot)
		_paint(plot, Rect2i(at.x + 3, 9, 2, at.y - 9), MapData.Terrain.FLOOR)
		_paint(plot, Rect2i(at.x + 3, at.y + 11, 2, 37 - at.y - 11), MapData.Terrain.FLOOR)
	# Connect central frontage to cross passages, outside slot boundary walls.
	for x in [29, 40]:
		_paint(plot, Rect2i(x, 9, 2, 1), MapData.Terrain.FLOOR)
		_paint(plot, Rect2i(x, 21, 2, 4), MapData.Terrain.FLOOR)
		plot.corridor_rects.append(Rect2i(x, 21, 2, 4))
		plot.corridor_types.append(RoomTypes.CORRIDOR)
	_save(plot, "res://maps/plots/test_small.tres")
	quit()

func _floor(size: Vector2i) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(size.x * size.y)
	out.fill(MapData.Terrain.FLOOR)
	return out

func _id(socket: String) -> String:
	return ModuleCatalog.shared().pick(socket, 0).get("id", "")

func _piece(id: String, at: Vector2i) -> DeckPiece:
	var piece := DeckPiece.new()
	piece.piece_id = StringName(id)
	piece.cell = at
	return piece

func _light(at: Vector2i) -> DeckLight:
	var light := DeckLight.new()
	light.cell = at
	return light

func _paint(plot: PlotData, rect: Rect2i, terrain: int) -> void:
	for z in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x): plot.terrain[z * plot.size.x + x] = terrain

func _save(resource: Resource, path: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	assert(ResourceSaver.save(resource, path) == OK)
