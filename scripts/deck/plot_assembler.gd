@tool
class_name PlotAssembler
extends RefCounted
## Engine-free authored layout assembly. All random choices use the caller's RNG.

var errors: PackedStringArray = []
var assignments: Array = []
var _attempts := 0
const SEARCH_LIMIT := 10000

static func resources(path: String, out: Array = []) -> Array:
	# Never mutate the default argument: callers may run this more than once.
	var found := out.duplicate()
	var names := DirAccess.get_directories_at(path)
	names.sort()
	for name in names:
		found.append_array(resources(path.path_join(name)))
	var files := DirAccess.get_files_at(path)
	files.sort()
	for name in files:
		if name.ends_with(".tres"):
			var resource := load(path.path_join(name))
			if resource != null:
				found.append(resource)
	return found

static func candidates(slot: PlotSlot, parcels: Array) -> Array:
	var out: Array = []
	for parcel: ParcelData in parcels:
		if parcel.zone != slot.zone or (slot.required_type != &"" and parcel.room_type != slot.required_type):
			continue
		for mirror in ([false, true] if parcel.allow_mirror else [false]):
			for rot in 4:
				if ParcelTransform.extent(parcel.size, rot) != slot.rect.size:
					continue
				var accepted: Array[Vector3i] = []
				for socket in parcel.sockets_ok:
					accepted.append(ParcelTransform.socket(socket, parcel.size, rot, mirror))
				var fits := true
				for socket in slot.sockets:
					# A wider accepted opening also accepts a narrower socket within it.
					var covered := false
					for ok in accepted:
						if socket.x == ok.x and socket.y >= ok.y and socket.y + socket.z <= ok.y + ok.z:
							covered = true
					fits = fits and covered
				if fits:
					out.append({"parcel": parcel, "rot": rot, "mirror": mirror})
	return out

func choose(size: Vector2i, primary: int, rng: RandomNumberGenerator, plots: Array = []) -> PlotData:
	var pool: Array = []
	for plot: PlotData in (resources("res://maps/plots") if plots.is_empty() else plots):
		var dimensions := [Vector2i(72, 48), Vector2i(84, 56), Vector2i(96, 64)]
		if plot.size != size or plot.deck_size not in range(3) or dimensions[plot.deck_size] != size:
			continue
		if primary < 0 or plot.slots.any(func(s: PlotSlot) -> bool: return s.zone == primary):
			pool.append(plot)
	if pool.is_empty():
		errors.append("Authoring gap: no plot for %s with primary zone %d" % [size, primary])
		return null
	return pool[rng.randi_range(0, pool.size() - 1)]

func assemble(plot: PlotData, rng: RandomNumberGenerator, parcels: Array = [], forced_condition := -1, faction: StringName = &"aliens") -> MapData:
	errors.clear()
	assignments.clear()
	_attempts = 0
	var data := MapData.new()
	data.authored_layout = true
	if plot == null:
		errors.append("No plot supplied")
		return data
	data.size = plot.size
	if plot.terrain.size() != plot.size.x * plot.size.y:
		errors.append("Plot terrain length does not match dimensions")
		return data
	var library := resources("res://maps/parcels") if parcels.is_empty() else parcels
	var pools: Array = []
	var order: Array[int] = []
	for i in plot.slots.size():
		var slot := plot.slots[i]
		if slot.rect.size.x < 1 or slot.rect.size.y < 1 or not Rect2i(Vector2i.ONE, plot.size - Vector2i(2, 2)).encloses(slot.rect):
			errors.append("Slot %d lies outside the hull or has invalid dimensions" % i)
		for socket in slot.sockets:
			if socket.x not in range(4) or socket.y < 0 or socket.z <= 0 or socket.y + socket.z > (slot.rect.size.y if socket.x % 2 == 0 else slot.rect.size.x):
				errors.append("Slot %d has an invalid socket: %s" % [i, socket])
		pools.append(candidates(plot.slots[i], library))
		order.append(i)
		assignments.append(null)
		if pools[i].is_empty():
			errors.append("Slot %d: no zone %d %s parcel accepts sockets %s" % [i, plot.slots[i].zone, plot.slots[i].rect.size, plot.slots[i].sockets])
	if not errors.is_empty():
		return data
	order.sort_custom(func(a: int, b: int) -> bool:
		if (plot.slots[a].required_type != &"") != (plot.slots[b].required_type != &""):
			return plot.slots[a].required_type != &""
		return pools[a].size() < pools[b].size())
	var required: Array[StringName] = []
	if not plot.test_only:
		for slot in plot.slots:
			for type: StringName in RoomTypes.ZONE_REQUIRED.get(slot.zone, []):
				if not required.has(type): required.append(type)
	if not _search(order, pools, 0, {}, required, rng):
		errors.append("No slot assignment satisfies required room types/caps (search %d/%d)" % [_attempts, SEARCH_LIMIT])
		return data
	_stamp_terrain(data, plot.terrain, plot.size, Vector2i.ZERO, 0, false, -1)
	data.explicit_doorways = true
	for i in plot.corridor_rects.size():
		var room := _room(data, plot.corridor_rects[i], plot.corridor_types[i] if i < plot.corridor_types.size() else RoomTypes.CORRIDOR)
		data.corridors.append(room)
	for i in plot.slots.size():
		var slot := plot.slots[i]
		var choice: Dictionary = assignments[i]
		var parcel: ParcelData = choice.parcel
		if parcel.terrain.size() != parcel.size.x * parcel.size.y:
			errors.append("Slot %d: parcel terrain length does not match dimensions" % i)
			return data
		var room := _room(data, slot.rect, parcel.room_type)
		choice.room = room
		_stamp_terrain(data, parcel.terrain, parcel.size, slot.rect.position, choice.rot, choice.mirror, room)
		for socket in slot.sockets:
			var door_start := ParcelTransform.edge_cell(socket.x, socket.y, slot.rect.size) + slot.rect.position
			var step := MapData.SIDE_STEP[socket.x]
			door_start += Vector2i(step.x, step.z)
			var door_size := Vector2i(1, socket.z) if socket.x % 2 == 0 else Vector2i(socket.z, 1)
			var passage := _room(data, Rect2i(door_start, door_size), RoomTypes.CORRIDOR)
			data.corridors.append(passage)
			for index in range(socket.y, socket.y + socket.z):
				var inner := ParcelTransform.edge_cell(socket.x, index, slot.rect.size) + slot.rect.position
				var pos := Vector3i(inner.x, 0, inner.y) + MapData.SIDE_STEP[socket.x]
				data.get_cell(pos).terrain = MapData.Terrain.DOOR
		if slot.zone != ParcelData.ZONE_HANGAR:
			data.zone_bands.append([slot.zone, slot.rect.position.x, slot.rect.end.x])
	RoomDressing.roll_conditions(data, rng)
	if forced_condition >= 0:
		for room in data.rooms.size(): data.room_conditions[room] = forced_condition
	_entries(data, plot, Vector2i.ZERO, plot.size, 0, false, 0, rng, faction)
	for i in plot.slots.size():
		var c: Dictionary = assignments[i]
		var parcel: ParcelData = c.parcel
		_entries(data, parcel, plot.slots[i].rect.position, parcel.size, c.rot, c.mirror, data.room_condition(c.room), rng, faction)
		if parcel.zone == ParcelData.ZONE_HANGAR:
			var pads := parcel.markers.filter(func(m: DeckMarker) -> bool: return m.kind == DeckMarker.Kind.PAD)
			if pads.size() != 1:
				errors.append("Hangar slot %d requires exactly one pad" % i)
				continue
			var at := ParcelTransform.apply(pads[0].cell, parcel.size, c.rot, c.mirror) + plot.slots[i].rect.position
			var bay := data.add_hangar(Vector3i(at.x, 0, at.y), ParcelTransform.side(pads[0].ramp_side, c.rot, c.mirror), data.hangars.is_empty())
			var problem := data.hangar_problem(bay)
			if problem != "": errors.append("Hangar slot %d: %s" % [i, problem])
	for room in data.rooms.size():
		for neighbour in data.touching_regions(room):
			if neighbour > room: data.room_links.append([room, neighbour])
	return data

func _search(order: Array[int], pools: Array, depth: int, counts: Dictionary, required: Array[StringName], rng: RandomNumberGenerator) -> bool:
	_attempts += 1
	if _attempts > SEARCH_LIMIT: return false
	if depth == order.size():
		return required.all(func(t: StringName) -> bool: return counts.get(t, 0) > 0)
	# Prune when a missing required type cannot fit any remaining slot.
	for type in required:
		if counts.get(type, 0) > 0: continue
		var possible := false
		for d in range(depth, order.size()):
			for c: Dictionary in pools[order[d]]:
				if c.parcel.room_type == type: possible = true
		if not possible: return false
	var index := order[depth]
	var pool: Array = pools[index].duplicate()
	while not pool.is_empty():
		var total := 0.0
		for c: Dictionary in pool: total += maxf(0.001, c.parcel.weight)
		var roll := rng.randf() * total
		var pick := pool.size() - 1
		for n in pool.size():
			roll -= maxf(0.001, pool[n].parcel.weight)
			if roll <= 0:
				pick = n
				break
		var choice: Dictionary = pool.pop_at(pick)
		var type: StringName = choice.parcel.room_type
		var count: int = counts.get(type, 0)
		var cap := RoomTypes.cap_of(type)
		if cap > 0 and count >= cap: continue
		counts[type] = count + 1
		assignments[index] = choice
		if _search(order, pools, depth + 1, counts, required, rng): return true
		counts[type] = count
	assignments[index] = null
	return false

static func _room(data: MapData, rect: Rect2i, type: StringName) -> int:
	var index := data.rooms.size()
	data.rooms.append(rect)
	data.ensure_room_types()
	data.set_room_type(index, type)
	for z in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			data.room_of[Vector3i(x, 0, z)] = index
	return index

static func _stamp_terrain(data: MapData, terrain: PackedByteArray, size: Vector2i, origin: Vector2i, rot: int, mirror: bool, room: int) -> void:
	if terrain.size() != size.x * size.y: return
	for z in size.y:
		for x in size.x:
			var p := ParcelTransform.apply(Vector2i(x, z), size, rot, mirror) + origin
			var at := Vector3i(p.x, 0, p.y)
			var cell := MapData.Cell.new()
			cell.terrain = terrain[z * size.x + x]
			data.cells[at] = cell
			if room >= 0: data.room_of[at] = room

static func optional(entries: Array, condition: int, rng: RandomNumberGenerator) -> Array:
	var groups := {}
	var selected: Array = []
	for entry: Resource in entries:
		if entry.group == &"": selected.append(entry)
		else:
			if not groups.has(entry.group): groups[entry.group] = []
			groups[entry.group].append(entry)
	for group: Array in groups.values():
		var total := 0.0
		for entry: Resource in group: total += maxf(0.001, entry.weight)
		var roll := rng.randf() * total
		for entry: Resource in group:
			roll -= maxf(0.001, entry.weight)
			if roll <= 0:
				selected.append(entry)
				break
	return selected.filter(func(e: Resource) -> bool: return e.chance.size() == 4 and rng.randf() < e.chance[clampi(condition, 0, 3)])

static func piece_rect(piece: DeckPiece, catalog: Dictionary) -> Rect2i:
	var a: Array = catalog.get("footprint", [1, 1])
	return Rect2i(piece.cell, ParcelTransform.extent(Vector2i(a[0], a[1]), piece.rot))

func _entries(data: MapData, source: Resource, origin: Vector2i, size: Vector2i, rot: int, mirror: bool, condition: int, rng: RandomNumberGenerator, faction: StringName) -> void:
	var entries: Array = []
	entries.append_array(source.pieces)
	entries.append_array(source.lights)
	entries.append_array(source.markers)
	var kept := optional(entries, condition, rng)
	for key: Vector3i in source.cover_edges:
		var p := ParcelTransform.apply(Vector2i(key.x, key.y), size, rot, mirror) + origin
		data.set_cover_edge(Vector3i(p.x, 0, p.y), ParcelTransform.side(key.z, rot, mirror), source.cover_edges[key])
	for entry: Resource in kept:
		var p := ParcelTransform.apply(entry.cell, size, rot, mirror) + origin
		var at := Vector3i(p.x, 0, p.y)
		if not data.has_cell(at) or not Rect2i(Vector2i.ZERO, size).has_point(entry.cell):
			errors.append("Entry outside authored bounds at %s" % at)
			continue
		if entry is DeckPiece:
			var catalog := ModuleCatalog.shared().piece(String(entry.piece_id))
			if catalog.is_empty():
				errors.append("Unknown piece %s" % entry.piece_id)
				continue
			if not Rect2i(Vector2i.ZERO, size).encloses(piece_rect(entry, catalog)):
				errors.append("Piece %s overhangs authored bounds at %s" % [entry.piece_id, at])
				continue
			var wall := ParcelTransform.side(entry.wall_side, rot, mirror)
			if wall >= 0:
				if data.terrain_at(at + MapData.SIDE_STEP[wall]) != MapData.Terrain.WALL:
					push_warning("Dropped wall piece %s at %s: no wall behind mount" % [entry.piece_id, at])
					continue
				data.wall_pieces.append([entry.piece_id, at, wall, ParcelTransform.offset(entry.offset, rot, mirror)])
			elif not catalog.get("gameplay", true):
				var stack_height := 0.0
				var parent_index: int = entry.stack_on
				var visited := {}
				var missing_parent := false
				while parent_index >= 0:
					if parent_index >= source.pieces.size() or visited.has(parent_index):
						errors.append("Invalid/cyclic stacking parent at %s" % at)
						missing_parent = true
						break
					visited[parent_index] = true
					var parent: DeckPiece = source.pieces[parent_index]
					if parent not in kept:
						missing_parent = true
						break
					var parent_catalog := ModuleCatalog.shared().piece(String(parent.piece_id))
					var parent_height := 0.0
					for part: Array in ModuleCatalog.shared().mesh_parts(parent_catalog):
						var bounds: AABB = part[1] * part[0].get_aabb()
						parent_height = maxf(parent_height, bounds.end.y)
					stack_height += parent_height + parent.offset.y
					parent_index = parent.stack_on
				if missing_parent: continue
				var footprint := ParcelTransform.rect(piece_rect(entry, catalog), size, rot, mirror)
				var center := Vector2(footprint.position) + Vector2(footprint.size - Vector2i.ONE) / 2.0 + Vector2(origin)
				var offset := ParcelTransform.offset(entry.offset, rot, mirror)
				offset.y += stack_height
				var yaw := -ParcelTransform.rotation(entry.rot, rot, mirror) * PI / 2.0 + deg_to_rad(-entry.yaw_deg if mirror else entry.yaw_deg)
				data.dressing.append([entry.piece_id, Transform3D(Basis(Vector3.UP, yaw), Vector3(center.x * 1.5, 0, center.y * 1.5) + offset)])
			else:
				var footprint := ParcelTransform.rect(piece_rect(entry, catalog), size, rot, mirror)
				footprint.position += origin
				var tier: int = entry.cover_override if entry.cover_override >= 0 else (MapData.Cover.HEAVY if catalog.get("tier", "light") == "heavy" else MapData.Cover.LIGHT)
				var socket: String = catalog.socket
				var kind := StringName(socket.trim_prefix("furniture_").trim_prefix("hazard_"))
				if socket == "hangar_wreck":
					data.wrecks.append(footprint)
					data.wreck_specs[footprint] = [entry.piece_id, ParcelTransform.rotation(entry.rot, rot, mirror)]
				else:
					data.obstacles.append([footprint, tier, kind, 1.0, entry.piece_id, ParcelTransform.rotation(entry.rot, rot, mirror)])
				for z in range(footprint.position.y, footprint.end.y):
					for x in range(footprint.position.x, footprint.end.x): data.get_cell(Vector3i(x, 0, z)).terrain = MapData.Terrain.OBSTACLE
		elif entry is DeckLight:
			if entry.preset not in range(5):
				errors.append("Invalid light preset at %s" % at)
				continue
			var wall := ParcelTransform.side(entry.wall_side, rot, mirror)
			if wall >= 0 and data.terrain_at(at + MapData.SIDE_STEP[wall]) != MapData.Terrain.WALL:
				push_warning("Dropped wall light at %s: no wall" % at)
				continue
			data.get_cell(at).fixture = [MapData.Fixture.OVERHEAD, MapData.Fixture.MONITOR, MapData.Fixture.FLICKER, MapData.Fixture.OVERHEAD, MapData.Fixture.ALARM][entry.preset]
			var overrides: Dictionary = entry.overrides.duplicate()
			if entry.use_room_color and not overrides.has("light_color"):
				overrides.light_color = RoomTypes.light_of(data.room_type_at(at))
			data.light_specs[at] = {"preset": entry.preset, "overrides": overrides, "wall_side": wall}
		elif entry is DeckMarker:
			if entry.kind == DeckMarker.Kind.PAD: continue
			if not data.is_walkable(at):
				errors.append("Marker on blocked tile %s" % at)
				continue
			if entry.kind == DeckMarker.Kind.LOOT:
				data.add_container(at, ItemPresets.roll_container(rng, entry.loot_table if entry.loot_table != &"" else RoomTypes.loot_of(data.room_type_at(at))))
			elif entry.pinned_spawn >= 0: data.get_cell(at).spawn = entry.pinned_spawn
			elif entry.kind == DeckMarker.Kind.PLAYER: data.get_cell(at).spawn = MapData.Spawn.PLAYER
			elif entry.kind == DeckMarker.Kind.NEST_SPOT: data.get_cell(at).spawn = MapData.Spawn.NEST
			else: data.get_cell(at).spawn = MapData.Spawn.SAGITTARII if faction == &"robots" else MapData.Spawn.ENEMY
