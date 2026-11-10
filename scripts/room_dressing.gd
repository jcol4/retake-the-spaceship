class_name RoomDressing
extends RefCounted
## Seeded furniture placement; every footprint keeps a walking lane around it.
const CONDITION_WEIGHTS := [20, 50, 15, 15]
const HAZARDS := {&"fuel_storage": &"fuel_tank", &"galley": &"gas", &"engineering_control": &"panel", &"engine_room": &"panel"}
const LAYOUTS := {
	RoomTypes.Layout.MESS_ROWS: [&"mess_table", Vector2i(3, 1), MapData.Cover.LIGHT],
	RoomTypes.Layout.BUNKS: [&"bunk", Vector2i(2, 1), MapData.Cover.LIGHT],
	RoomTypes.Layout.LAB_ISLANDS: [&"lab_bench", Vector2i(2, 1), MapData.Cover.LIGHT],
	RoomTypes.Layout.LOCKER_ROWS: [&"locker", Vector2i(1, 1), MapData.Cover.HEAVY],
	RoomTypes.Layout.SERVER_ROWS: [&"server_rack", Vector2i(2, 1), MapData.Cover.HEAVY],
	RoomTypes.Layout.MACHINERY: [&"machinery", Vector2i(3, 2), MapData.Cover.HEAVY],
	RoomTypes.Layout.CONSOLE_ROWS: [&"console", Vector2i(2, 1), MapData.Cover.LIGHT],
	RoomTypes.Layout.BATHROOM: [&"toilet", Vector2i(1, 1), MapData.Cover.LIGHT],
	RoomTypes.Layout.GALLEY: [&"galley", Vector2i(1, 1), MapData.Cover.LIGHT],
	RoomTypes.Layout.MED_BEDS: [&"med_bed", Vector2i(2, 1), MapData.Cover.LIGHT],
	RoomTypes.Layout.CARGO: [&"cargo", Vector2i(2, 1), MapData.Cover.HEAVY],
	RoomTypes.Layout.CELLS: [&"cell_bars", Vector2i(2, 1), MapData.Cover.HEAVY],
	RoomTypes.Layout.CRATES: [&"crate", Vector2i(1, 1), MapData.Cover.LIGHT],
	RoomTypes.Layout.WALL_RACKS: [&"weapon_rack", Vector2i(2, 1), MapData.Cover.HEAVY],
}
const TYPE_PIECES := {
	&"fabrication": [&"workbench", Vector2i(2, 1), MapData.Cover.LIGHT],
	&"cabin": [&"bed", Vector2i(2, 1), MapData.Cover.LIGHT],
	&"captains_quarters": [&"bed", Vector2i(2, 1), MapData.Cover.LIGHT],
	&"lounge": [&"couch", Vector2i(2, 1), MapData.Cover.LIGHT],
	&"gym": [&"gym", Vector2i(2, 1), MapData.Cover.LIGHT],
	&"surgery": [&"surgery", Vector2i(2, 1), MapData.Cover.LIGHT],
	&"morgue": [&"morgue", Vector2i(1, 1), MapData.Cover.HEAVY],
	&"cryo": [&"specimen_tank", Vector2i(1, 1), MapData.Cover.HEAVY],
	&"specimen_hold": [&"specimen_tank", Vector2i(1, 1), MapData.Cover.HEAVY],
	&"laundry": [&"washer", Vector2i(1, 1), MapData.Cover.HEAVY],
}


static func roll_conditions(data: MapData, rng: RandomNumberGenerator) -> void:
	for room in data.rooms.size():
		if room in data.corridors or data.room_type(room) in [RoomTypes.HANGAR, RoomTypes.GENERIC]:
			continue
		var roll := rng.randi_range(0, 99)
		for condition in CONDITION_WEIGHTS.size():
			roll -= CONDITION_WEIGHTS[condition]
			if roll < 0:
				data.room_conditions[room] = condition
				break
	for band: Array in data.zone_bands:
		if not data.zone_power.has(band[0]):
			data.zone_power[band[0]] = rng.randi_range(0, 2) != 0


static func seed_overrun(data: MapData, rng: RandomNumberGenerator) -> void:
	for room in data.rooms.size():
		if data.room_condition(room) != RoomTypes.Condition.OVERRUN or room in data.corridors:
			continue
		var seeded := false
		for pos: Vector3i in data.room_of:
			if data.room_of[pos] != room or not data.is_passable(pos): continue
			var cell := data.get_cell(pos)
			if cell.spawn == MapData.Spawn.NONE and (not seeded or rng.randf() < 0.04):
				cell.spawn = MapData.Spawn.WORM
				data.worm_counts[pos] = rng.randi_range(2, 5)
				seeded = true


static func place(data: MapData, room: int, rng: RandomNumberGenerator, budget: int) -> bool:
	if budget <= 0:
		return true
	var type := data.room_type(room)
	var layout := RoomTypes.layout_of(type)
	var spec: Array = TYPE_PIECES.get(type, LAYOUTS.get(layout, [&"crate", Vector2i.ONE, MapData.Cover.LIGHT]))
	var rect := data.rooms[room]
	var condition := data.room_condition(room)
	var shape: Vector2i = spec[1]
	var maximum := mini(budget, maxi(1, rect.get_area() / 18))
	if condition == RoomTypes.Condition.OVERRUN:
		shape = Vector2i.ONE
		maximum = maxi(1, maximum / 2)
	if layout == RoomTypes.Layout.NONE:
		maximum = 0
	var placed := 0
	for z in range(rect.position.y + 1, rect.end.y - shape.y, shape.y + 2):
		for x in range(rect.position.x + 1, rect.end.x - shape.x, shape.x + 2):
			if placed >= maximum:
				break
			var at := Vector2i(x, z)
			if layout == RoomTypes.Layout.RANDOM:
				at = Vector2i(rng.randi_range(rect.position.x + 1, rect.end.x - shape.x - 1), rng.randi_range(rect.position.y + 1, rect.end.y - shape.y - 1))
			if layout == RoomTypes.Layout.BUNKS and z > rect.position.y + 1 and z + shape.y < rect.end.y - 2:
				continue
			if condition == RoomTypes.Condition.RANSACKED:
				if rng.randf() < 0.3:
					continue
				at += Vector2i(rng.randi_range(-1, 1), rng.randi_range(-1, 1))
			var hp_scale := 0.45 if condition == RoomTypes.Condition.OVERRUN else 1.0
			if put(data, room, Rect2i(at, shape), spec[2], spec[0], hp_scale):
				placed += 1
	if condition == RoomTypes.Condition.BARRICADED:
		# Keep the central doorway lane clear; barricades sit beside it.
		for pos: Vector3i in data.room_of:
			if data.room_of[pos] != room:
				continue
			for step: Vector3i in MapData.SIDE_STEP:
				if data.terrain_at(pos + step) == MapData.Terrain.DOOR:
					var side := Vector3i(-step.z, 0, step.x)
					var at := pos - step + side * 2
					put(data, room, Rect2i(at.x, at.z, 1, 1), MapData.Cover.LIGHT, &"crate")
	if HAZARDS.has(type):
		for z in range(rect.position.y + 1, rect.end.y - 1):
			var done := false
			for x in range(rect.position.x + 1, rect.end.x - 1):
				if put(data, room, Rect2i(x, z, 1, 1), MapData.Cover.LIGHT, HAZARDS[type]):
					done = true
					break
			if done:
				break
	if condition == RoomTypes.Condition.OVERRUN:
		var seeded := false
		for z in range(rect.position.y + 1, rect.end.y - 1):
			for x in range(rect.position.x + 1, rect.end.x - 1):
				var pos := Vector3i(x, 0, z)
				var cell := data.get_cell(pos)
				if cell.terrain == MapData.Terrain.FLOOR and cell.spawn == MapData.Spawn.NONE and (not seeded or rng.randf() < 0.04):
					cell.spawn = MapData.Spawn.WORM
					data.worm_counts[pos] = rng.randi_range(2, 5)
					seeded = true
	return true


static func put(data: MapData, room: int, footprint: Rect2i, tier: int, kind: StringName, hp_scale := 1.0) -> bool:
	if not data.rooms[room].encloses(footprint.grow(1)):
		return false
	for z in range(footprint.position.y - 1, footprint.end.y + 1):
		for x in range(footprint.position.x - 1, footprint.end.x + 1):
			var pos := Vector3i(x, 0, z)
			var cell := data.get_cell(pos)
			if cell == null or cell.terrain != MapData.Terrain.FLOOR or cell.spawn != MapData.Spawn.NONE or data.room_index_at(pos) != room:
				return false
	for z in range(footprint.position.y, footprint.end.y):
		for x in range(footprint.position.x, footprint.end.x):
			data.get_cell(Vector3i(x, 0, z)).terrain = MapData.Terrain.OBSTACLE
	data.obstacles.append([footprint, tier, kind, hp_scale])
	return true
