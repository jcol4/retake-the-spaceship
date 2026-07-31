class_name MapAscii
extends RefCounted
## Text <-> MapData codec. The text form is how hand-authored decks and (later)
## set-piece room prefabs are stored, and it is the fastest way to eyeball a
## generator's output — a deck printed to stdout beats a screenshot when you are
## iterating on layout.
##
## A deck file is a grid block, optionally followed by named sections:
##
##     ####################
##     #.P..#........#..E.#
##     ####################
##
##     [cover]
##     8,4 E light
##     9,6 S heavy
##
## Grid legend (one glyph per tile):
##   ' ' void      '.' floor     '#' wall      'R' raised platform
##   'P' player spawn          'E' enemy spawn         'S' swarm spawn
##   'o' overhead light        'm' monitor light       'f' flickering light
##   's' stair tile, LOWERCASE — links to the platform directly north of it,
##       and is a different thing entirely from an uppercase 'S'
##
## One glyph per tile means the grid cannot hold two features on one tile (a
## spawn standing under a light, say). MapData can. encode() therefore picks by
## the precedence in _glyph_for and drops the rest; to_text(parse(x)) == x holds
## for any layout that keeps one feature per tile, which the round-trip test
## asserts. Generators that need overlap must not round-trip through text.
##
## Cover has NO glyph, and that is the point of the [cover] section: cover sits
## on a tile BOUNDARY, and a per-tile grid cannot name a boundary at all. Each
## line is `x,z SIDE type`.
##
## Only the canonical sides E and S may be written. Every edge has two names —
## the east side of one tile is the west side of its neighbour — and accepting
## both would let one edge be authored twice with two different values, silently.
## Naming the same edge from the other tile costs one subtraction and keeps the
## file a single source of truth. Rooms are NOT stored: they are derived from the
## layout by MapData.compute_rooms, so they cannot drift out of sync with it.

const GLYPHS := {
	" ": [MapData.Terrain.VOID, MapData.Fixture.NONE, MapData.Spawn.NONE, false],
	".": [MapData.Terrain.FLOOR, MapData.Fixture.NONE, MapData.Spawn.NONE, false],
	"#": [MapData.Terrain.WALL, MapData.Fixture.NONE, MapData.Spawn.NONE, false],
	"R": [MapData.Terrain.PLATFORM, MapData.Fixture.NONE, MapData.Spawn.NONE, false],
	"P": [MapData.Terrain.FLOOR, MapData.Fixture.NONE, MapData.Spawn.PLAYER, false],
	"E": [MapData.Terrain.FLOOR, MapData.Fixture.NONE, MapData.Spawn.ENEMY, false],
	"S": [MapData.Terrain.FLOOR, MapData.Fixture.NONE, MapData.Spawn.SWARM, false],
	"o": [MapData.Terrain.FLOOR, MapData.Fixture.OVERHEAD, MapData.Spawn.NONE, false],
	"m": [MapData.Terrain.FLOOR, MapData.Fixture.MONITOR, MapData.Spawn.NONE, false],
	"f": [MapData.Terrain.FLOOR, MapData.Fixture.FLICKER, MapData.Spawn.NONE, false],
	"s": [MapData.Terrain.FLOOR, MapData.Fixture.NONE, MapData.Spawn.NONE, true],
}

const COVER_SECTION := "[cover]"

const SIDE_NAMES := {"E": MapData.Side.EAST, "S": MapData.Side.SOUTH}
const SIDE_GLYPH := {MapData.Side.EAST: "E", MapData.Side.SOUTH: "S"}
const COVER_NAMES := {"light": MapData.Cover.LIGHT, "heavy": MapData.Cover.HEAVY}
const COVER_WORD := {MapData.Cover.LIGHT: "light", MapData.Cover.HEAVY: "heavy"}


static func parse(rows: PackedStringArray, deck: int = 0) -> MapData:
	var data := MapData.new()
	var grid := _grid_rows(rows)
	for z in grid.size():
		var row: String = grid[z]
		for x in row.length():
			var glyph: String = row[x]
			if not GLYPHS.has(glyph):
				push_error("MapAscii: unknown glyph '%s' at (%d, %d)" % [glyph, x, z])
				continue
			var spec: Array = GLYPHS[glyph]
			var cell := MapData.Cell.new()
			cell.terrain = spec[0]
			cell.fixture = spec[1]
			cell.spawn = spec[2]
			cell.stair = spec[3]
			data.set_cell(Vector3i(x, deck, z), cell)
	_parse_cover(data, rows, deck)
	data.resolve_stairs()
	# Derived here rather than by the caller so every route into a MapData —
	# file, string, or test fixture — arrives with the same graph populated.
	data.compute_rooms()
	return data


static func _grid_rows(rows: PackedStringArray) -> PackedStringArray:
	# The grid runs until the first section header. Blank lines before it are
	# padding around the header, not rows of void.
	var out := PackedStringArray()
	for line in rows:
		if (line as String).begins_with("["):
			break
		out.append(line)
	while not out.is_empty() and out[out.size() - 1].strip_edges().is_empty():
		out.remove_at(out.size() - 1)
	return out


static func _parse_cover(data: MapData, rows: PackedStringArray, deck: int) -> void:
	var inside := false
	for raw in rows:
		var line: String = (raw as String).strip_edges()
		if line.begins_with("["):
			inside = line == COVER_SECTION
			continue
		if not inside or line.is_empty():
			continue
		# `x,z SIDE type`
		var parts := line.split(" ", false)
		var coords := parts[0].split(",") if parts.size() == 3 else PackedStringArray()
		if coords.size() != 2 or not SIDE_NAMES.has(parts[1]) or not COVER_NAMES.has(parts[2]):
			push_error("MapAscii: bad [cover] line '%s' (want 'x,z E|S light|heavy')" % line)
			continue
		var pos := Vector3i(int(coords[0]), deck, int(coords[1]))
		data.set_cover_edge(pos, SIDE_NAMES[parts[1]], COVER_NAMES[parts[2]])


static func encode(data: MapData, deck: int = 0) -> PackedStringArray:
	# Grid block only. to_text is what round-trips a whole file.
	var rows := PackedStringArray()
	for z in data.size.y:
		var row := ""
		for x in data.size.x:
			row += _glyph_for(data.get_cell(Vector3i(x, deck, z)))
		rows.append(row)
	return rows


static func encode_cover(data: MapData, deck: int = 0) -> PackedStringArray:
	# Empty when the deck has no edge cover, so a deck that never had a [cover]
	# section does not grow one on the way out.
	var rows := PackedStringArray()
	for entry: Array in data.cover_edge_list():
		var pos: Vector3i = entry[0]
		if pos.y != deck:
			continue
		if rows.is_empty():
			rows.append("")
			rows.append(COVER_SECTION)
		rows.append("%d,%d %s %s" % [pos.x, pos.z, SIDE_GLYPH[entry[1]], COVER_WORD[entry[2]]])
	return rows


static func _glyph_for(cell: MapData.Cell) -> String:
	# Precedence: terrain first (a wall can hold nothing), then the feature that
	# most changes how the tile plays.
	if cell == null or cell.terrain == MapData.Terrain.VOID:
		return " "
	if cell.terrain == MapData.Terrain.WALL:
		return "#"
	if cell.terrain == MapData.Terrain.PLATFORM:
		return "R"
	match cell.spawn:
		MapData.Spawn.PLAYER: return "P"
		MapData.Spawn.ENEMY: return "E"
		MapData.Spawn.SWARM: return "S"
	match cell.fixture:
		MapData.Fixture.OVERHEAD: return "o"
		MapData.Fixture.MONITOR: return "m"
		MapData.Fixture.FLICKER: return "f"
	if cell.stair:
		return "s"
	return "."


static func load_file(path: String, deck: int = 0) -> MapData:
	return parse(read_rows(path), deck)


static func read_rows(path: String) -> PackedStringArray:
	# Tolerates CRLF and trailing blank lines; a stray blank row would otherwise
	# become a row of void tiles and quietly change the deck's depth.
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("MapAscii: cannot open %s" % path)
		return PackedStringArray()
	var rows := PackedStringArray()
	for line in file.get_as_text().split("\n"):
		rows.append((line as String).trim_suffix("\r"))
	while not rows.is_empty() and rows[rows.size() - 1].strip_edges().is_empty():
		rows.remove_at(rows.size() - 1)
	return rows


static func to_text(data: MapData, deck: int = 0) -> String:
	var rows := encode(data, deck)
	rows.append_array(encode_cover(data, deck))
	return "\n".join(rows)
