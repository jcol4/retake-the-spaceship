@tool
class_name DeckValidator
extends RefCounted
## Shared by the editor (advisory) and headless content checks (hard failures).

static func issue(message: String, cell := Vector2i(-1, -1), hard := true) -> Dictionary:
	return {"message": message, "cell": cell, "hard": hard}

static func parcel(p: ParcelData, plots: Array = []) -> Array:
	var out: Array = []
	if p.size.x < 1 or p.size.y < 1 or p.terrain.size() != p.size.x * p.size.y:
		return [issue("Terrain length must equal width × depth")]
	if not RoomTypes.is_known(p.room_type): out.append(issue("Unknown room type: %s" % p.room_type))
	if Array(p.terrain).any(func(t: int) -> bool: return t not in [MapData.Terrain.FLOOR, MapData.Terrain.WALL, MapData.Terrain.DOOR]):
		out.append(issue("Parcels support floor, interior walls and doors only"))
	if p.zone != ParcelData.ZONE_HANGAR and RoomTypes.zone_of(p.room_type) != p.zone:
		out.append(issue("Room type does not belong to parcel zone"))
	if p.zone == ParcelData.ZONE_HANGAR and p.room_type != RoomTypes.HANGAR: out.append(issue("Hangar parcel must use the hangar room type"))
	var occupied := {}
	var permanent := {}
	var groups := {}
	var entries: Array = []
	entries.append_array(p.pieces)
	entries.append_array(p.lights)
	entries.append_array(p.markers)
	for entry: Resource in entries:
		if not Rect2i(Vector2i.ZERO, p.size).has_point(entry.cell): out.append(issue("Entry outside parcel", entry.cell))
		if entry.chance.size() != 4 or Array(entry.chance).any(func(c: float) -> bool: return c < 0 or c > 1):
			out.append(issue("Chance requires four values in 0..1", entry.cell))
		if entry.group != &"": groups[entry.group] = groups.get(entry.group, 0) + 1
		if entry is DeckPiece:
			var catalog := ModuleCatalog.shared().piece(String(entry.piece_id))
			if catalog.is_empty():
				out.append(issue("Unknown catalog piece: %s" % entry.piece_id, entry.cell))
				continue
			if catalog.get("mount", "floor") == "wall" and entry.wall_side < 0:
				out.append(issue("Wall piece needs wall_side", entry.cell))
			if entry.stack_on >= p.pieces.size() or entry.stack_on == p.pieces.find(entry):
				out.append(issue("Invalid stacking parent", entry.cell))
			var visited := {}
			var parent: int = entry.stack_on
			while parent >= 0 and parent < p.pieces.size():
				if visited.has(parent):
					out.append(issue("Cyclic stacking parents", entry.cell))
					break
				visited[parent] = true
				parent = p.pieces[parent].stack_on
			if entry.wall_side < 0 and catalog.get("gameplay", true):
				var rect := PlotAssembler.piece_rect(entry, catalog)
				if not Rect2i(Vector2i.ZERO, p.size).encloses(rect): out.append(issue("Piece overhangs parcel", entry.cell))
				for y in range(rect.position.y, rect.end.y):
					for x in range(rect.position.x, rect.end.x):
						var at := Vector2i(x, y)
						if occupied.has(at) and (entry.group == &"" or occupied[at] != entry.group): out.append(issue("Overlapping pieces", at))
						if _terrain(p, at) not in [MapData.Terrain.FLOOR, MapData.Terrain.DOOR]: out.append(issue("Piece on blocked terrain", at))
						occupied[at] = entry.group
						if entry.group == &"" and entry.chance == PackedFloat32Array([1, 1, 1, 1]): permanent[at] = true
		elif entry is DeckLight and entry.preset not in range(5):
			out.append(issue("Unknown light preset", entry.cell))
		if (entry is DeckPiece or entry is DeckLight) and entry.wall_side >= 0:
			if entry.wall_side > 3:
				out.append(issue("Invalid wall side", entry.cell))
				continue
			var step := MapData.SIDE_STEP[entry.wall_side]
			var behind: Vector2i = entry.cell + Vector2i(step.x, step.z)
			if Rect2i(Vector2i.ZERO, p.size).has_point(behind) and _terrain(p, behind) != MapData.Terrain.WALL:
				out.append(issue("Wall mount has no wall behind it", entry.cell))
			for socket in p.sockets_ok:
				for index in range(socket.y, socket.y + socket.z):
					if entry.wall_side == socket.x and entry.cell == ParcelTransform.edge_cell(socket.x, index, p.size):
						out.append(issue("Wall mount overlaps a door socket", entry.cell))
	for group: StringName in groups:
		if groups[group] < 2: out.append(issue("Pick-one group %s has fewer than two entries" % group, Vector2i(-1, -1), false))
	for socket in p.sockets_ok:
		out.append_array(_socket_issues(socket, p.size))
		if not _socket_issues(socket, p.size).is_empty(): continue
		for index in range(socket.y, socket.y + socket.z):
			var at := ParcelTransform.edge_cell(socket.x, index, p.size)
			var step := MapData.SIDE_STEP[socket.x]
			for depth in 2:
				var inner := at - Vector2i(step.x, step.z) * depth
				if occupied.has(inner) or _terrain(p, inner) not in [MapData.Terrain.FLOOR, MapData.Terrain.DOOR]:
					out.append(issue("Blocked door socket or approach", inner))
	for marker in p.markers:
		var blocked: bool = occupied.has(marker.cell) and (marker.group == &"" or occupied[marker.cell] != marker.group)
		if marker.kind != DeckMarker.Kind.PAD and (blocked or _terrain(p, marker.cell) not in [MapData.Terrain.FLOOR, MapData.Terrain.DOOR]):
			out.append(issue("Spawn/loot marker on occupied tile", marker.cell))
	# Check the most obstructed variant, including every optional gameplay piece.
	var walkable := {}
	var baseline := {}
	for y in p.size.y:
		for x in p.size.x:
			var at := Vector2i(x, y)
			if not occupied.has(at) and _terrain(p, at) in [MapData.Terrain.FLOOR, MapData.Terrain.DOOR]: walkable[at] = true
			if not permanent.has(at) and _terrain(p, at) in [MapData.Terrain.FLOOR, MapData.Terrain.DOOR]: baseline[at] = true
	if baseline.is_empty() or flood(baseline).size() != baseline.size(): out.append(issue("Unreachable/disconnected floor"))
	elif walkable.is_empty() or flood(walkable).size() != walkable.size(): out.append(issue("Optional combinations may obstruct walk lanes; inspect condition previews", Vector2i(-1, -1), false))
	if p.zone == ParcelData.ZONE_HANGAR:
		var pads := p.markers.filter(func(m: DeckMarker) -> bool: return m.kind == DeckMarker.Kind.PAD)
		if pads.size() != 1: out.append(issue("Hangar must have exactly one PAD"))
		else:
			var pad: DeckMarker = pads[0]
			if pad.group != &"" or pad.chance != PackedFloat32Array([1, 1, 1, 1]): out.append(issue("PAD must always be present", pad.cell))
			if pad.ramp_side not in range(4): out.append(issue("Invalid pad ramp side", pad.cell))
			else:
				var reserved := MapData.hangar_pad_cells(Vector3i(pad.cell.x, 0, pad.cell.y))
				reserved.append_array(MapData.hangar_square_cells(Vector3i(pad.cell.x, 0, pad.cell.y), pad.ramp_side))
				for pos in reserved:
					if not walkable.has(Vector2i(pos.x, pos.z)): out.append(issue("Hangar pad/square blocked or outside parcel", Vector2i(pos.x, pos.z)))
	var dark := false
	for at: Vector2i in walkable:
		if light_level(p.lights, at, true) <= 0: dark = true
	if dark: out.append(issue("Some tiles are fully dark when intact and powered", Vector2i(-1, -1), false))
	if not plots.is_empty():
		var matched := false
		for plot: PlotData in plots:
			for slot in plot.slots:
				if not PlotAssembler.candidates(slot, [p]).is_empty(): matched = true
		if not matched: out.append(issue("Parcel matches no slot in any plot", Vector2i(-1, -1), false))
	return out

static func plot(p: PlotData, parcels: Array) -> Array:
	var out: Array = []
	var dimensions := [Vector2i(72, 48), Vector2i(84, 56), Vector2i(96, 64)]
	if p.deck_size not in range(3) or p.size != dimensions[clampi(p.deck_size, 0, 2)]: out.append(issue("Plot dimensions disagree with deck size"))
	if p.terrain.size() != p.size.x * p.size.y: return [issue("Plot terrain length does not match dimensions")]
	if Array(p.terrain).any(func(t: int) -> bool: return t not in [MapData.Terrain.VOID, MapData.Terrain.FLOOR, MapData.Terrain.WALL, MapData.Terrain.DOOR]):
		out.append(issue("Plots do not support raised platforms/stairs or baked obstacles"))
	# Reuse entry checks for corridor props, with no parcel floor-connectivity rule.
	var corridor_content := ParcelData.new()
	corridor_content.size = p.size
	corridor_content.zone = RoomTypes.Zone.NONE
	corridor_content.room_type = RoomTypes.GENERIC
	corridor_content.terrain = p.terrain.duplicate()
	for i in corridor_content.terrain.size():
		if corridor_content.terrain[i] == MapData.Terrain.VOID: corridor_content.terrain[i] = MapData.Terrain.WALL
	corridor_content.pieces = p.pieces
	corridor_content.lights = p.lights
	corridor_content.markers = p.markers
	for entry_issue: Dictionary in parcel(corridor_content):
		if entry_issue.message not in ["Unreachable/disconnected floor", "Some tiles are fully dark when intact and powered"]: out.append(entry_issue)
	for corridor in p.corridor_rects:
		if corridor.size.x <= 0 or corridor.size.y <= 0 or not Rect2i(Vector2i.ONE, p.size - Vector2i(2, 2)).encloses(corridor): out.append(issue("Corridor outside hull", corridor.position))
	var hangar := false
	var covered := {}
	for i in p.slots.size():
		var slot := p.slots[i]
		if slot.zone == ParcelData.ZONE_HANGAR: hangar = true
		if slot.rect.size.x <= 0 or slot.rect.size.y <= 0 or not Rect2i(Vector2i.ONE, p.size - Vector2i(2, 2)).encloses(slot.rect): out.append(issue("Slot outside hull", slot.rect.position))
		if slot.sockets.is_empty(): out.append(issue("Slot %d has no sockets" % i, slot.rect.position))
		for socket in slot.sockets: out.append_array(_socket_issues(socket, slot.rect.size))
		for corridor in p.corridor_rects:
			if corridor.intersects(slot.rect): out.append(issue("Slot overlaps corridor", slot.rect.position))
		if PlotAssembler.candidates(slot, parcels).is_empty(): out.append(issue("Slot %d: no zone %d %s parcel accepts %s" % [i, slot.zone, slot.rect.size, slot.sockets], slot.rect.position))
		for y in range(slot.rect.position.y, slot.rect.end.y):
			for x in range(slot.rect.position.x, slot.rect.end.x):
				var at := Vector2i(x, y)
				if covered.has(at): out.append(issue("Slots overlap", at))
				covered[at] = true
	if not hangar: out.append(issue("Plot has no HANGAR slot"))
	for y in p.size.y:
		for x in p.size.x:
			if (x == 0 or y == 0 or x == p.size.x - 1 or y == p.size.y - 1) and p.terrain[y * p.size.x + x] not in [MapData.Terrain.WALL, MapData.Terrain.VOID]:
				out.append(issue("Hull is open", Vector2i(x, y)))
	if out.any(func(i: Dictionary) -> bool: return i.hard): return out
	var assembler := PlotAssembler.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 0
	var data := assembler.assemble(p, rng, parcels, 0)
	for message in assembler.errors: out.append(issue(message))
	out.append_array(assembled(data))
	if p.test_only: out.append(issue("Test-only plot: zone-required room types are exempt", Vector2i(-1, -1), false))
	return out

static func assembled(data: MapData) -> Array:
	var out: Array = []
	var walkable := {}
	for pos: Vector3i in data.cells:
		if data.is_passable(pos): walkable[Vector2i(pos.x, pos.z)] = true
	var insertion := data.insertion_hangar()
	if insertion == null: return [issue("No insertion hangar")]
	var start := insertion.square[0]
	var reached := flood(walkable, Vector2i(start.x, start.z))
	if reached.size() != walkable.size(): out.append(issue("Walkable floor disconnected from insertion"))
	for room in data.rooms:
		var has_floor := false
		var accessible := false
		for at: Vector2i in walkable:
			if room.has_point(at):
				has_floor = true
				if reached.has(at): accessible = true
		if has_floor and not accessible: out.append(issue("Room unreachable from insertion", room.position))
	for pos: Vector3i in data.cells:
		if data.get_cell(pos).spawn != MapData.Spawn.NONE and not data.is_walkable(pos): out.append(issue("Spawn on obstacle", Vector2i(pos.x, pos.z)))
	return out

static func _terrain(p: ParcelData, at: Vector2i) -> int:
	if not Rect2i(Vector2i.ZERO, p.size).has_point(at): return MapData.Terrain.VOID
	return p.terrain[at.y * p.size.x + at.x]

static func _socket_issues(socket: Vector3i, size: Vector2i) -> Array:
	if socket.x not in range(4) or socket.y < 0 or socket.z <= 0 or socket.y + socket.z > (size.y if socket.x % 2 == 0 else size.x):
		return [issue("Socket outside edge: %s" % socket)]
	return []

static func flood(walkable: Dictionary, start := Vector2i(-1, -1)) -> Dictionary:
	if walkable.is_empty(): return {}
	if start == Vector2i(-1, -1): start = walkable.keys()[0]
	if not walkable.has(start): return {}
	var seen := {start: true}
	var queue: Array[Vector2i] = [start]
	var head := 0
	while head < queue.size():
		var at := queue[head]
		head += 1
		for step in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var next: Vector2i = at + step
			if walkable.has(next) and not seen.has(next):
				seen[next] = true
				queue.append(next)
	return seen

## LightingManager's radial Chebyshev linear falloff; preview has no physics world.
static func light_level(lights: Array, at: Vector2i, powered: bool, condition := 0) -> float:
	var value := 0.0
	for light: DeckLight in lights:
		if light.preset == DeckLight.Preset.ALARM or light.chance.size() != 4 or light.chance[condition] <= 0: continue
		var reach: float = light.overrides.get("light_range", 2.5 if light.preset == DeckLight.Preset.MONITOR else 6.0)
		var intensity: float = light.overrides.get("intensity", 45.0 if light.preset == DeckLight.Preset.MONITOR else 90.0)
		var delta := (at - light.cell).abs()
		if reach > 0: value += maxf(0, intensity * (1.0 - maxf(delta.x, delta.y) / reach)) * (1.0 if powered else 0.15)
	return clampf(value, 0, 100)
