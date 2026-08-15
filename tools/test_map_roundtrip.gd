extends SceneTree
## Round-trip check for the map data model: text -> MapData -> text must come
## back byte-identical, and the parsed data must expose the same spawns, stairs,
## platform tiles, edge cover and compartment graph the builder reads off it.
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

	# The whole file, sections included — not just the grid block, or the
	# [cover] section could drift without the test noticing.
	var encoded := MapAscii.to_text(data).split("\n")
	_check(encoded.size() == rows.size(), "line count preserved (%d vs %d)" % [encoded.size(), rows.size()])
	var identical := true
	for z in mini(encoded.size(), rows.size()):
		if encoded[z] != rows[z]:
			identical = false
			print("  line %2d in : '%s'" % [z, rows[z]])
			print("  line %2d out: '%s'" % [z, encoded[z]])
	_check(identical, "round-trip is byte-identical")

	_check(data.size == Vector2i(20, 14), "deck size is 20x14 (got %s)" % data.size)
	_check(data.spawns(MapData.Spawn.PLAYER).size() == 3, "3 player spawns")
	_check(data.spawns(MapData.Spawn.ENEMY).size() == 2, "2 enemy spawns")
	_check(data.spawns(MapData.Spawn.SWARM).size() == 2, "2 swarm spawns")
	_check(data.spawns(MapData.Spawn.BRAWLER).size() == 3, "3 brawler spawns")
	# The rival mercs hold the right-hand room, which was empty. Placed there
	# rather than among the aliens deliberately: the middle room is staged to
	# judge the melee tier on its own, and a third faction mixed into it would
	# change what that fight is measuring.
	_check(data.spawns(MapData.Spawn.MERC).size() == 2, "2 merc spawns")
	_check(data.spawns(MapData.Spawn.HUNTER).size() == 1, "1 Agile Hunter spawn")
	# The deck now DOES carry one robot — the Lictor, so the security faction's
	# cover-breaking doctrine is exercised by the map the game actually loads
	# rather than only by a test fixture.
	_check(data.spawns(MapData.Spawn.LICTOR).size() == 1, "1 Lictor spawn")
	for kind: int in [MapData.Spawn.AUXILIUM, MapData.Spawn.SAGITTARII, MapData.Spawn.PROCTOR,
			MapData.Spawn.SECURUS]:
		_check(data.spawns(kind).is_empty(),
			"no spawn of Spawn kind %d (got %d)" % [kind, data.spawns(kind).size()])

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

	_check_cover(data)
	_check_rooms(data)
	_check_spawn_glyphs()

	print("")
	if _failures == 0:
		print("map round-trip: ALL CHECKS PASSED")
		quit(0)
	else:
		print("map round-trip: %d CHECK(S) FAILED" % _failures)
		quit(1)


func _check_cover(data: MapData) -> void:
	_check(data.cover_edges.size() == 3, "3 cover edges (got %d)" % data.cover_edges.size())
	_check(data.cover_edge(Vector3i(8, 0, 4), MapData.Side.EAST) == MapData.Cover.LIGHT,
		"light cover on the east edge of (8,4)")
	_check(data.cover_edge(Vector3i(9, 0, 6), MapData.Side.SOUTH) == MapData.Cover.HEAVY,
		"heavy cover on the south edge of (9,6)")

	# The half of the model everything else depends on: an edge has two names and
	# both must resolve to the same entry, or a crate would grant cover from one
	# side and nothing from the other. (7,8)-east IS (8,8)-west.
	_check(data.cover_edge(Vector3i(8, 0, 8), MapData.Side.WEST) == MapData.Cover.LIGHT,
		"the same edge read from the neighbouring tile's west side")
	_check(data.cover_edge(Vector3i(9, 0, 6), MapData.Side.SOUTH)
		== data.cover_edge(Vector3i(9, 0, 7), MapData.Side.NORTH),
		"north/south naming of one edge agrees")

	# A tile is protected from the directions its covered edges face, and from
	# nothing else.
	var south_only: Array[int] = [MapData.Side.SOUTH]
	_check(data.covered_sides(Vector3i(9, 0, 6)) == south_only,
		"(9,6) is covered to the south only (got %s)" % [data.covered_sides(Vector3i(9, 0, 6))])
	_check(data.covered_sides(Vector3i(1, 0, 1)).is_empty(), "an open tile has no covered sides")

	# Cover no longer eats floor: units stand ON these tiles now.
	_check(data.is_walkable(Vector3i(9, 0, 6)), "a covered tile is still walkable")


func _check_rooms(data: MapData) -> void:
	# Three compartments joined by two one-tile doorways: (5,7) through the left
	# bulkhead and (14,12) through the right one. Each doorway is its own
	# one-cell corridor region, which is why the count is 5 and not 3 — and why
	# the graph is a chain, left - middle - right, with no direct left-right link.
	_check(data.rooms.size() == 5, "5 regions (got %d)" % data.rooms.size())
	_check(data.corridors.size() == 2, "2 of them are corridors (got %d)" % data.corridors.size())

	var left := data.room_index_at(Vector3i(2, 0, 2))
	var middle := data.room_index_at(Vector3i(9, 0, 6))
	var right := data.room_index_at(Vector3i(17, 0, 2))
	_check(left >= 0 and middle >= 0 and right >= 0, "the three squad rooms all resolve")
	_check(left != middle and middle != right and left != right,
		"the three rooms are distinct (%d, %d, %d)" % [left, middle, right])
	_check(data.room_index_at(Vector3i(1, 0, 12)) == left,
		"the far corner of the left room is the same room")

	# A doorway belongs to neither room it joins — that separation is the whole
	# reason a plain flood fill was not enough.
	var door := data.room_index_at(Vector3i(5, 0, 7))
	_check(door >= 0 and door != left and door != middle, "the (5,7) doorway is its own region")
	_check(door in data.corridors, "and is flagged as a corridor")
	_check(left in data.linked_rooms(door) and middle in data.linked_rooms(door),
		"that doorway links the left and middle rooms")
	_check(not (right in data.linked_rooms(door)),
		"and does not reach the right room, two doorways away")

	# Grid space vs cell space: the platform top is a grid key one deck up, and
	# must still resolve to the room its base sits in.
	_check(data.room_index_at(Vector3i(15, 1, 10)) == right,
		"a platform top resolves to the room below it")
	_check(data.room_index_at(Vector3i(0, 0, 0)) == -1, "a bulkhead belongs to no region")


## Every spawn glyph, on a fixture rather than on the shipped deck.
##
## The census above used to carry this: the deck held one of each robot, so the
## glyphs were exercised by the map the game actually loads. That is the better
## test where it is available, and it is not available any more — the deck is
## staged for an alien fight and has no robots on it. A layout the test owns is
## what keeps `Q`/`M`/`X`/`J` from quietly ceasing to parse while every check
## still passes, and it is where `B` earns its coverage too.
##
## Both halves matter and they fail differently: the SPAWN check catches a glyph
## that parses to the wrong kind, the ROUND-TRIP check catches one that parses
## correctly but has no entry in `_glyph_for` and so encodes back as plain floor.
func _check_spawn_glyphs() -> void:
	var rows := PackedStringArray([
		"########",
		"#QMXJVA#",
		"#BSEPF!#",
		"########",
	])
	var data := MapAscii.parse(rows)
	var expected := {
		Vector3i(1, 0, 1): MapData.Spawn.AUXILIUM,
		Vector3i(2, 0, 1): MapData.Spawn.SAGITTARII,
		Vector3i(3, 0, 1): MapData.Spawn.PROCTOR,
		Vector3i(4, 0, 1): MapData.Spawn.SECURUS,
		# 'V', not 'M' — the merc glyph sits next to the Sagittarii's on purpose,
		# since those two are the collision this legend had to route around.
		Vector3i(5, 0, 1): MapData.Spawn.MERC,
		Vector3i(6, 0, 1): MapData.Spawn.HUNTER,
		Vector3i(1, 0, 2): MapData.Spawn.BRAWLER,
		Vector3i(2, 0, 2): MapData.Spawn.SWARM,
		Vector3i(3, 0, 2): MapData.Spawn.ENEMY,
		Vector3i(4, 0, 2): MapData.Spawn.PLAYER,
		Vector3i(5, 0, 2): MapData.Spawn.LICTOR,
	}
	# The alarm panel is a FIXTURE, not a spawn, so it is checked separately —
	# but it belongs in this fixture for the same reason the spawn glyphs do: the
	# round-trip below is what catches a glyph that parses and then encodes back
	# as plain floor for want of a `_glyph_for` entry.
	var alarm_cell := data.get_cell(Vector3i(6, 0, 2))
	_check(alarm_cell != null and alarm_cell.fixture == MapData.Fixture.ALARM,
		"'!' parses as an alarm panel fixture")
	for pos: Vector3i in expected:
		var got: Array[Vector3i] = data.spawns(expected[pos])
		_check(got.size() == 1 and got[0] == pos,
			"spawn kind %d parses at %s (got %s)" % [expected[pos], pos, got])

	# Only the grid block is compared: the fixture carries no cover, so whether
	# `to_text` emits an empty [cover] section is not this check's business.
	var encoded := MapAscii.to_text(data).split("\n")
	var identical := encoded.size() >= rows.size()
	for z in mini(encoded.size(), rows.size()):
		if encoded[z] != rows[z]:
			identical = false
			print("  line %2d in : '%s'" % [z, rows[z]])
			print("  line %2d out: '%s'" % [z, encoded[z]])
	_check(identical, "every spawn glyph round-trips")


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
