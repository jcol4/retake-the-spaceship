extends SceneTree
## Prints generated decks to stdout as ASCII. At the layout stage text is a
## faster loop than screenshots — five decks are readable in one screen.
##
##   godot --headless --path . --script res://tools/preview_map.gd
##   MAP_SEEDS=7,8 MAP_TYPES=1 godot ... --script res://tools/preview_map.gd
##
## Other overrides: MAP_MIN/MAP_MAX (room size band), MAP_CORRIDOR (hallway
## width), MAP_ENTRANCE (opening width) — see MapGenerator.Config for the rest.
##
## Only MapGenerator/MapAscii/MapData, never MapBuilder: a --script tool is
## compiled before autoloads register.


func _initialize() -> void:
	var cfg := MapGenerator.Config.new()
	if OS.has_environment("MAP_THEMED"):
		cfg.themed_rooms = OS.get_environment("MAP_THEMED") != "0"
	if OS.has_environment("MAP_MIXED"):
		cfg.mixed_profile = OS.get_environment("MAP_MIXED") == "1"
	if OS.has_environment("MAP_SCALE"):
		cfg.room_scale = float(OS.get_environment("MAP_SCALE"))
	if OS.has_environment("MAP_PRIMARY"):
		cfg.profile_primary = int(OS.get_environment("MAP_PRIMARY"))
	if OS.has_environment("MAP_SECONDARY"):
		cfg.profile_secondary = int(OS.get_environment("MAP_SECONDARY"))
	if OS.has_environment("MAP_W"):
		cfg.width = int(OS.get_environment("MAP_W"))
	if OS.has_environment("MAP_D"):
		cfg.depth = int(OS.get_environment("MAP_D"))
	if OS.has_environment("MAP_ENTRANCE"):
		cfg.entrance_width = int(OS.get_environment("MAP_ENTRANCE"))
	if OS.has_environment("MAP_MIN"):
		cfg.room_min = int(OS.get_environment("MAP_MIN"))
	if OS.has_environment("MAP_MAX"):
		cfg.room_max = int(OS.get_environment("MAP_MAX"))
	if OS.has_environment("MAP_CORRIDOR"):
		cfg.corridor_width = int(OS.get_environment("MAP_CORRIDOR"))

	var seeds: Array = [1, 2, 3, 4, 5]
	if OS.has_environment("MAP_SEEDS"):
		seeds = []
		for part in OS.get_environment("MAP_SEEDS").split(","):
			seeds.append(int(part))

	for map_seed: int in seeds:
		var data := MapGenerator.generate(map_seed, cfg)
		print("")
		print("=== seed %d — %dx%d ===" % [map_seed, data.size.x, data.size.y])
		print("%s; generation attempt %d" % [data.profile_name(), data.generation_attempt])
		print(_type_view(data) if OS.get_environment("MAP_TYPES") == "1" else MapAscii.to_text(data))
		print(_stats(data))
	quit(0)


## Unique letters assigned in catalog order, with a legend for the rooms used.
## Door and wall glyphs take precedence, furniture does not hide a room's type.
func _type_view(data: MapData) -> String:
	const LETTERS := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	var glyphs := {RoomTypes.SPINE: "=", RoomTypes.CORRIDOR: "-", RoomTypes.HANGAR: "H", RoomTypes.GENERIC: "."}
	var index := 0
	for type: StringName in RoomTypes.TYPES:
		while LETTERS[index] == "H":
			index += 1
		glyphs[type] = LETTERS[index]
		index += 1
	var lines: PackedStringArray = []
	var used := {}
	for z in data.size.y:
		var line := ""
		for x in data.size.x:
			var pos := Vector3i(x, 0, z)
			var terrain := data.terrain_at(pos)
			if terrain == MapData.Terrain.WALL:
				line += "#"
			elif terrain == MapData.Terrain.DOOR:
				line += "+"
			else:
				var type := data.room_type_at(pos)
				line += glyphs.get(type, " ")
				if glyphs.has(type):
					used[type] = true
		lines.append(line)
	for type: StringName in glyphs:
		if used.has(type):
			lines.append("%s %s" % [glyphs[type], type])
	return "\n".join(lines)


func _stats(data: MapData) -> String:
	var walkable := data.walkable_positions().size()
	var total := data.size.x * data.size.y
	var real_room_count := data.rooms.size() - data.corridors.size()
	var loops := data.room_links.size() - maxi(real_room_count - 1, 0)
	var areas: Array[int] = []
	for i in data.rooms.size():
		if i in data.corridors:
			continue  # a corridor's rect is only its bounding box, not comparable to a room's
		var room: Rect2i = data.rooms[i]
		areas.append(room.size.x * room.size.y)
	areas.sort()
	return "    rooms %d  corridors %d  links %d (loops %d)  open %d%%  room tiles min %d / median %d / max %d" % [
		real_room_count,
		data.corridors.size(),
		data.room_links.size(),
		loops,
		roundi(100.0 * walkable / total),
		areas[0] if not areas.is_empty() else 0,
		areas[areas.size() / 2] if not areas.is_empty() else 0,
		areas[areas.size() - 1] if not areas.is_empty() else 0,
	]
