extends SceneTree
## Round-trip check for the map data model: text -> MapData -> text must come
## back byte-identical, and the parsed data must expose the same spawns, stairs
## and platform tiles the builder used to read straight off the ASCII.
##
##   godot --headless --path . --script res://tools/test_map_roundtrip.gd
##
## Deliberately touches only MapAscii/MapData, never MapBuilder: a --script tool
## is compiled before autoloads register, so anything naming GridManager would
## fail to load and the test would silently never run.

const LAYOUT_PATH := "res://maps/test_deck.txt"

var _failures := 0


func _initialize() -> void:
	var rows := MapAscii.read_rows(LAYOUT_PATH)
	_check(not rows.is_empty(), "layout file loaded")
	var data := MapAscii.parse(rows)

	var encoded := MapAscii.encode(data)
	_check(encoded.size() == rows.size(), "row count preserved (%d vs %d)" % [encoded.size(), rows.size()])
	var identical := true
	for z in mini(encoded.size(), rows.size()):
		if encoded[z] != rows[z]:
			identical = false
			print("  row %2d in : '%s'" % [z, rows[z]])
			print("  row %2d out: '%s'" % [z, encoded[z]])
	_check(identical, "round-trip is byte-identical")

	_check(data.size == Vector2i(20, 14), "deck size is 20x14 (got %s)" % data.size)
	_check(data.spawns(MapData.Spawn.PLAYER).size() == 3, "3 player spawns")
	_check(data.spawns(MapData.Spawn.ENEMY).size() == 2, "2 enemy spawns")
	_check(data.spawns(MapData.Spawn.SWARM).size() == 3, "3 swarm spawns")

	# The platform's walkable tiles sit one deck up, and the stair links onto one
	# of them — the two places where cell space and grid space differ.
	var platforms := 0
	for pos: Vector3i in data.cells:
		if data.terrain_at(pos) == MapData.Terrain.PLATFORM:
			platforms += 1
			_check(data.walkable_pos(pos).y == 1, "platform at %s is walkable on deck 1" % pos)
	_check(platforms == 4, "4 platform tiles (got %d)" % platforms)

	_check(data.stair_links.size() == 1, "1 stair link (got %d)" % data.stair_links.size())
	if data.stair_links.size() == 1:
		var link: Array = data.stair_links[0]
		_check(link[0] == Vector3i(15, 0, 11), "stair from (15,0,11) (got %s)" % link[0])
		_check(link[1] == Vector3i(15, 1, 10), "stair to (15,1,10) (got %s)" % link[1])

	# Walkable positions are what a connectivity check will flood-fill over, so
	# they must be grid keys: no platform cell may appear at its deck-0 base.
	var walkable := data.walkable_positions()
	_check(not walkable.has(Vector3i(15, 0, 10)), "platform base is not a walkable tile")
	_check(walkable.has(Vector3i(15, 1, 10)), "platform top is a walkable tile")

	print("")
	if _failures == 0:
		print("map round-trip: ALL CHECKS PASSED")
		quit(0)
	else:
		print("map round-trip: %d CHECK(S) FAILED" % _failures)
		quit(1)


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
