extends SceneTree
## Prints generated decks to stdout as ASCII. At the layout stage text is a
## faster loop than screenshots — five decks are readable in one screen.
##
##   godot --headless --path . --script res://tools/preview_map.gd
##   MAP_SEEDS=7,8 MAP_W=60 MAP_D=34 godot ... --script res://tools/preview_map.gd
##
## Only MapGenerator/MapAscii/MapData, never MapBuilder: a --script tool is
## compiled before autoloads register.


func _initialize() -> void:
	var cfg := MapGenerator.Config.new()
	if OS.has_environment("MAP_W"):
		cfg.width = int(OS.get_environment("MAP_W"))
	if OS.has_environment("MAP_D"):
		cfg.depth = int(OS.get_environment("MAP_D"))
	if OS.has_environment("MAP_DOOR"):
		cfg.doorway_width = int(OS.get_environment("MAP_DOOR"))
	if OS.has_environment("MAP_MIN"):
		cfg.min_room = int(OS.get_environment("MAP_MIN"))
	if OS.has_environment("MAP_MAX"):
		cfg.max_room = int(OS.get_environment("MAP_MAX"))
	if OS.has_environment("MAP_SPINE"):
		cfg.spine_width = int(OS.get_environment("MAP_SPINE"))

	var seeds: Array = [1, 2, 3, 4, 5]
	if OS.has_environment("MAP_SEEDS"):
		seeds = []
		for part in OS.get_environment("MAP_SEEDS").split(","):
			seeds.append(int(part))

	for map_seed: int in seeds:
		var data := MapGenerator.generate(map_seed, cfg)
		print("")
		print("=== seed %d — %dx%d ===" % [map_seed, data.size.x, data.size.y])
		print(MapAscii.to_text(data))
		print(_stats(data))
	quit(0)


func _stats(data: MapData) -> String:
	var walkable := data.walkable_positions().size()
	var total := data.size.x * data.size.y
	var loops := data.room_links.size() - (data.rooms.size() - 1)
	var areas: Array[int] = []
	for room: Rect2i in data.rooms:
		areas.append(room.size.x * room.size.y)
	areas.sort()
	return "    rooms %d  links %d (loops %d)  open %d%%  room tiles min %d / median %d / max %d" % [
		data.rooms.size(),
		data.room_links.size(),
		loops,
		roundi(100.0 * walkable / total),
		areas[0],
		areas[areas.size() / 2],
		areas[areas.size() - 1],
	]
