class_name RoomSystems
extends Node
## Mission-local room state. Commands are resolved on the host; state snapshots
## cover power, doors, services and attachment exchanges on every peer/resume.
const DARK_SIGHT := 0.6
const DARK_RANGE := 6
const BREACH_TURNS := 2
const SERVICE_TYPES: Array[StringName] = [&"medbay", &"armory", &"fabrication"]
var map: Node3D
var data: MapData
var doors: Dictionary = {}
var used: Dictionary = {}
var stations: Dictionary = {}
var labels: Dictionary = {}
var door_bodies: Dictionary = {}
var station_models: Dictionary = {}
var stash_delta: Dictionary = {}
var revealed := false
var robots_enabled := true
var _refresh_clock := 0.0


static func current() -> RoomSystems:
	var world := GridManager.world_node
	return world.get_node_or_null("RoomSystems") as RoomSystems if is_instance_valid(world) else null


func setup(builder: Node3D) -> void:
	name = "RoomSystems"
	map = builder
	data = builder.data
	for room in data.rooms.size():
		var type := data.room_type(room)
		if room in data.corridors or type in [RoomTypes.HANGAR, RoomTypes.GENERIC]:
			continue
		var label := Label3D.new()
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.fixed_size = true
		label.font_size = 22
		label.render_priority = 120
		label.outline_size = 6
		label.outline_modulate = Color(0, 0, 0, 0.85)
		add_child(label)
		var center := data.rooms[room].get_center()
		label.position = GridManager.grid_to_world(Vector3i(center.x, 0, center.y)) + Vector3(0, 2.8, 0)
		labels[room] = label
		if type in SERVICE_TYPES or type in [&"bridge", &"security_station", &"engineering_control"]:
			var tile := _station_tile(room)
			stations[room] = tile
			var socket := "power_switch" if type == &"engineering_control" else ("terminal_wall" if type in [&"bridge", &"security_station"] else "furniture_workbench")
			var catalog := ModuleCatalog.shared()
			# Room services use the solid furniture already generated in that
			# room; only wall-mounted controls need an additional visual prop.
			var piece := catalog.pick(socket, ModuleCatalog.hash_of([room, tile, socket])) if type not in SERVICE_TYPES and not data.authored_layout else {}
			if not piece.is_empty():
				var model := catalog.instance(piece)
				add_child(model)
				model.position = GridManager.grid_to_world(tile)
				if socket in ["terminal_wall", "power_switch"]:
					for step: Vector3i in MapData.SIDE_STEP:
						if data.terrain_at(tile + step) == MapData.Terrain.WALL:
							model.position += Vector3(step) * (GridManager.TILE_SIZE / 2.0 - 0.03)
							model.rotation.y = atan2(float(-step.x), float(-step.z))
							break
				station_models[room] = model
		if RoomTypes.is_locked(type):
			var cells: Array[Vector3i] = []
			for pos: Vector3i in data.cells:
				if data.terrain_at(pos) != MapData.Terrain.DOOR:
					continue
				for step: Vector3i in MapData.SIDE_STEP:
					if data.room_index_at(pos + step) == room:
						cells.append(pos)
						break
			if cells.is_empty():
				continue
			doors[room] = {"cells": cells, "open": false, "breach": 0, "zone": data.room_zone(room)}
			var bodies: Array = []
			for pos: Vector3i in cells:
				var body := StaticBody3D.new()
				body.collision_layer = 1
				var mesh := MeshInstance3D.new()
				var box := BoxMesh.new()
				box.size = Vector3(GridManager.TILE_SIZE, 2.6, GridManager.TILE_SIZE)
				mesh.mesh = box
				var mat := StandardMaterial3D.new()
				mat.albedo_color = Color(0.3, 0.16, 0.12)
				mesh.material_override = mat
				body.add_child(mesh)
				var collider := CollisionShape3D.new()
				var shape := BoxShape3D.new()
				shape.size = box.size
				collider.shape = shape
				body.add_child(collider)
				add_child(body)
				body.position = GridManager.grid_to_world(pos) + Vector3(0, 1.3, 0)
				bodies.append(body)
			door_bodies[room] = bodies
	_refresh_world()


func _station_tile(room: int) -> Vector3i:
	if data.authored_layout:
		for entry: Array in data.wall_pieces:
			var piece := ModuleCatalog.shared().piece(String(entry[0]))
			if data.room_index_at(entry[1]) == room and piece.get("socket", "") in ["terminal_wall", "power_switch"]:
				return entry[1]
	var choices: Array[Vector3i] = []
	for pos: Vector3i in data.room_of:
		if data.room_of[pos] == room and data.is_passable(pos) and data.get_cell(pos).spawn == MapData.Spawn.NONE:
			for step: Vector3i in MapData.SIDE_STEP:
				if data.terrain_at(pos + step) == MapData.Terrain.WALL:
					choices.append(pos)
	choices.sort()
	if not choices.is_empty():
		return choices[0]
	var center := data.rooms[room].get_center()
	return Vector3i(center.x, 0, center.y)


func _process(delta: float) -> void:
	_refresh_clock -= delta
	if _refresh_clock > 0.0:
		return
	_refresh_clock = 0.15
	var active = TurnManager.active_unit
	if not is_instance_valid(active):
		active = get_tree().get_first_node_in_group("player_units")
	for room: int in labels:
		var known: bool = revealed or map._explored.has(room)
		var focused: bool = room == map._hover_room or (is_instance_valid(active) and data.room_index_at(active.grid_pos) == room)
		var label: Label3D = labels[room]
		label.visible = NameTags.shows_hangar(known) and (focused or data.room_zone(room) != RoomTypes.Zone.UTILITY or NameTags.mode == NameTags.Mode.ALL)
		label.font_size = 16 if focused else 10
		label.text = "[ %s ]" % RoomTypes.display_name(data.room_type(room))
		if focused:
			label.text += "\n%s%s" % [RoomTypes.CONDITION_NAME[data.room_condition(room)].capitalize(), " · No power" if data.room_is_dark(room) else ""]
		label.modulate = RoomTypes.light_of(data.room_type(room))
		if focused and doors.has(room) and not doors[room].open:
			label.text += " · Locked"
		if focused and used.has(room):
			label.text += " · Used"
		if station_models.has(room):
			station_models[room].visible = known
		for body in door_bodies.get(room, []):
			var door_known := known
			var cell := GridManager.world_to_grid(body.position - Vector3(0, 1.3, 0))
			for step: Vector3i in MapData.SIDE_STEP:
				door_known = door_known or map._explored.has(data.room_index_at(cell + step))
			body.get_child(0).visible = door_known and not doors[room].open


func room_text(at: Vector3i) -> String:
	var room := data.room_index_at(at)
	if room < 0 or (not revealed and not map._explored.has(room)):
		return ""
	return "%s · %s" % [RoomTypes.display_name(data.room_type(room)), "Emergency power" if data.room_is_dark(room) else "Powered"]


func _add_option(out: Array, action: String, room: int, title: String, cost: int, extra := -1) -> void:
	out.append({"action": action, "room": room, "label": title, "cost": cost, "extra": extra})


func options(unit) -> Array:
	var out: Array = []
	if unit == null or unit.is_downed or unit.aboard or unit.is_busy:
		return out
	var room := data.room_index_at(unit.grid_pos)
	var full: int = unit.stats.ap_pool()
	for target: int in doors:
		if doors[target].open:
			continue
		var near := false
		for tile: Vector3i in doors[target].cells:
			near = near or unit.within_reach(tile)
		if near:
			var title := RoomTypes.display_name(data.room_type(target))
			if _card_holder(unit, data.room_type(target)):
				_add_option(out, "key", target, "Unlock %s (keycard)" % title, 0)
			if _item_index(unit, "breaching_charge") >= 0:
				_add_option(out, "charge", target, "Breach %s (charge)" % title, 1)
			_add_option(out, "breach", target, "Breach %s (%d/%d)" % [title, doors[target].breach, BREACH_TURNS], full)
	for station: int in stations:
		var type := data.room_type(station)
		if type in [&"bridge", &"security_station"] and unit.within_reach(stations[station]):
			_add_option(out, "reveal", station, "Terminal: reveal room map", 1)
			_add_option(out, "robots", station, "Terminal: %s security robots" % ("disable" if robots_enabled else "enable"), 1)
			_add_option(out, "hack", station, "Terminal: unlock doors (full turn)", full)
		if type == &"engineering_control" and unit.within_reach(stations[station]) and data.zone_power.values().has(false):
			_add_option(out, "power", station, "Restore one dark zone", 1)
	if not used.has(room):
		match data.room_type(room):
			&"medbay": _add_option(out, "heal", room, "Medbay: heal / revive one soldier", full)
			&"armory": _add_option(out, "ammo", room, "Armory: refill ammunition + grenade", full)
			&"fabrication":
				for id: int in _spare_attachments(unit):
					_add_option(out, "fit", room, "Fit %s from stash" % AttachmentPresets.DATA[id].display_name, full, id)
	for index in unit.inventory.size():
		var item: ItemData = unit.inventory[index]
		if item.id in ["medkit", "stim", "armour_patch"]:
			if item.id == "stim" and TurnManager.in_exploration():
				continue
			if item.id == "armour_patch" and unit.armour_bonus >= 3:
				continue
			_add_option(out, "item", room, "Use %s" % item.display_name, 1, index)
			out[-1]["expected"] = item.code
	if unit.ammo > 0:
		for index in data.obstacles.size():
			var edge := _hazard_edge(index)
			if edge.is_empty():
				continue
			var node: CollisionObject3D = edge[2].node
			var at := GridManager.world_to_grid(node.global_position)
			if GridManager.chebyshev_dist(unit.grid_pos, at) <= 10 and map.squad_sees_tile(at) and GridManager.has_clear_line(unit, unit.global_position + Vector3.UP, node.global_position, [node.get_rid()]):
				_add_option(out, "hazard", data.room_index_at(at), "Fire at %s" % String(node.get("kind")).replace("_", " "), unit.action_cost(UnitStats.Action.SHOOT), index)
	return out


func _hazard_edge(index: int) -> Array:
	if index < 0 or index >= data.obstacles.size():
		return []
	var entry: Array = data.obstacles[index]
	if entry.size() < 3 or entry[2] not in [&"fuel_tank", &"gas", &"panel"]:
		return []
	var rect: Rect2i = entry[0]
	for z in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			for side in 4:
				var at := Vector3i(x, 0, z) + MapData.SIDE_STEP[side]
				var facing := GridManager.opposite_side(side)
				var edge := GridManager.cover_edge(at, facing)
				if edge != null and edge.footprint == rect and edge.is_intact():
					return [at, facing, edge]
	return []


func _item_index(unit, code: String) -> int:
	for i in unit.inventory.size():
		if unit.inventory[i].code == code:
			return i
	return -1


func _card_holder(unit, type: StringName) -> bool:
	# Cards are carried by an actual squad member in reach, never a remote
	# teammate whose inventory happens to be replicated on this machine.
	for other in get_tree().get_nodes_in_group("player_units"):
		if not other.is_downed and unit.within_reach(other.grid_pos) and _item_index(other, "keycard:" + String(type)) >= 0:
			return true
	return false


func _spare_attachments(unit) -> Array[int]:
	var owner: Dictionary = (Campaign.deployment.get("owners", {}) as Dictionary).get(unit.owner_key, Campaign.deployment)
	var available: Dictionary = owner.get("attachments", {}).duplicate()
	for other in get_tree().get_nodes_in_group("player_units"):
		if other.owner_key != unit.owner_key or other.stats.weapon == null or other.is_queued_for_deletion():
			continue
		for attachment: AttachmentData in other.stats.weapon.attachments():
			available[attachment.id] = int(available.get(attachment.id, 0)) - 1
	# Current fitted weapons already include previous exchanges. Applying the
	# exchange journal here too would count returned attachments twice.
	var result: Array[int] = []
	for id in available:
		if int(available[id]) > 0 and AttachmentPresets.fits(int(id), unit.stats.weapon.id):
			var attachment := AttachmentPresets.make(int(id))
			var old: AttachmentData = unit.stats.weapon.get_attachment(attachment.slot)
			if old == null or old.id != int(id):
				result.append(int(id))
	result.sort()
	return result


func act(unit, action: String, room: int, extra := -1) -> bool:
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return false
	var chosen := {}
	for option: Dictionary in options(unit):
		if option.action == action and option.room == room and option.extra == extra:
			chosen = option
			break
	if chosen.is_empty() or not unit.can_afford(chosen.cost):
		return false
	# Pay before changing the world. Exploration prices full turns on its clock.
	if action == "hazard":
		unit._pay_attack(chosen.cost)
	else:
		unit.pay(chosen.cost)
	match action:
		"hazard":
			var edge := _hazard_edge(extra)
			unit.ammo -= 1
			SecurityNetwork.report_noise(unit.grid_pos, unit, unit.gunfire_noise_radius())
			GridManager.damage_cover_edge(edge[0], edge[1], unit.stats.weapon_damage)
		"key": doors[room].open = true
		"charge":
			unit.remove_item(_item_index(unit, "breaching_charge"))
			doors[room].open = true
			_alert_zone(unit, room)
		"breach":
			doors[room].breach += 1
			doors[room].open = doors[room].breach >= BREACH_TURNS
			_alert_zone(unit, room)
		"hack":
			for door in doors.values():
				door.open = true
		"reveal": revealed = true
		"robots": robots_enabled = not robots_enabled
		"power":
			var zones: Array = data.zone_power.keys()
			zones.sort()
			for zone: int in zones:
				if not data.zone_power[zone]:
					data.zone_power[zone] = true
					break
		"heal":
			var target = unit
			for other in get_tree().get_nodes_in_group("player_units"):
				if other.life_state == Unit.LifeState.DOWNED and data.room_index_at(other.grid_pos) == room:
					var at: Vector3i = other.grid_pos
					if not GridManager.is_free(at):
						for next: Vector3i in GridManager.neighbors(at):
							if GridManager.is_free(next) and data.room_index_at(next) == room:
								at = next
								break
					if GridManager.is_free(at):
						other.revive_at(at)
						target = other
						break
			target.current_hp = target.stats.max_hp()
			target.hp_changed.emit(target)
			used[room] = true
		"ammo":
			unit.ammo = unit.stats.mag_size
			unit.reserve = unit.stats.mag_size * 3
			unit.grenade_charges += 1
			used[room] = true
		"fit":
			var attachment := AttachmentPresets.make(extra)
			var weapon: WeaponData = unit.stats.weapon
			var old := weapon.get_attachment(attachment.slot)
			if not stash_delta.has(unit.owner_key):
				stash_delta[unit.owner_key] = {}
			var delta: Dictionary = stash_delta[unit.owner_key]
			delta[extra] = int(delta.get(extra, 0)) - 1
			if old != null:
				delta[old.id] = int(delta.get(old.id, 0)) + 1
			var ids := PackedInt32Array()
			for fitted: AttachmentData in weapon.attachments():
				if fitted.slot != attachment.slot:
					ids.append(fitted.id)
			ids.append(extra)
			unit._apply_loadout(weapon.id, ids, weapon.ammo.id if weapon.ammo != null else -1)
			if multiplayer.has_multiplayer_peer():
				for peer in SteamLobby.ready_peers:
					unit._rpc_sync_loadout.rpc_id(peer, weapon.id, ids, weapon.ammo.id if weapon.ammo != null else -1)
			used[room] = true
		"item":
			var item: ItemData = unit.remove_item(extra)
			if item.id == "stim":
				unit.ap = mini(unit.stats.ap_pool(), unit.ap + 4)
			elif item.id == "armour_patch":
				unit.armour_bonus = mini(3, unit.armour_bonus + 1)
			else:
				unit.current_hp = mini(unit.stats.max_hp(), unit.current_hp + (10 if item.id == "medkit" else 4))
				unit.hp_changed.emit(unit)
	_refresh_world()
	unit.action_logged.emit("%s: %s" % [unit.stats.display_name, chosen.label])
	if multiplayer.has_multiplayer_peer():
		for peer in SteamLobby.ready_peers:
			_restore.rpc_id(peer, capture())
	return true


func _alert_zone(unit, room: int) -> void:
	SecurityNetwork.report_noise(unit.grid_pos, unit, 12)
	for enemy in get_tree().get_nodes_in_group("units"):
		if enemy.has_method("hear_noise") and data.zone_at(enemy.grid_pos) == data.room_zone(room):
			enemy.hear_noise(unit.grid_pos)


func capture() -> Dictionary:
	return {"power": data.zone_power.duplicate(), "doors": doors.duplicate(true), "used": used.duplicate(), "revealed": revealed, "robots": robots_enabled, "stash": stash_delta.duplicate(true)}


@rpc("authority", "call_remote", "reliable")
func _restore(state: Dictionary) -> void:
	restore(state)


func restore(state: Dictionary) -> void:
	if state.is_empty():
		return
	data.zone_power = state.get("power", {}).duplicate()
	doors = state.get("doors", {}).duplicate(true)
	used = state.get("used", {}).duplicate()
	revealed = bool(state.get("revealed", false))
	robots_enabled = bool(state.get("robots", true))
	stash_delta = state.get("stash", {}).duplicate(true)
	_refresh_world()


func _refresh_world() -> void:
	for room: int in doors:
		var opened: bool = doors[room].open
		for tile: Vector3i in doors[room].cells:
			var grid := GridManager.get_tile(tile)
			if grid != null:
				grid.passable = opened
		for body in door_bodies.get(room, []):
			body.collision_layer = 0 if opened else 1
			var mesh: MeshInstance3D = body.get_child(0)
			var material: StandardMaterial3D = mesh.material_override
			var powered: bool = data.zone_power.get(data.room_zone(room), true)
			material.albedo_color = Color(0.3, 0.16, 0.12) if powered else Color(0.09, 0.07, 0.07)
	for source: LightSource in LightingManager._sources:
		source.set_powered(not (data.room_is_dark(source.room_index) or data.is_dark_at(source.grid_pos)))
	if revealed:
		for room in data.rooms.size():
			map._explored[room] = true
		map._apply_fog()
	GridManager.invalidate_sight_cache()
	map._sight_cache.clear()
	map._fog_sight_key = []
	map._dim_key = []
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.has_method("_refresh_status_light"):
			unit._refresh_status_light()
	if not map._building:
		LightingManager.recompute_base()
		_refresh_after_physics()


func _refresh_after_physics() -> void:
	# Collision changes become visible to ray queries on the next physics step.
	# Clear caches again then, so a same-frame query cannot preserve a shut door.
	await get_tree().physics_frame
	await get_tree().process_frame
	if not is_instance_valid(map) or not is_inside_tree():
		return
	GridManager.invalidate_sight_cache()
	map._sight_cache.clear()
	map._fog_sight_key = []
	map._dim_key = []
	LightingManager.recompute_base()
