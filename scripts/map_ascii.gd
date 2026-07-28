class_name MapAscii
extends RefCounted
## ASCII <-> MapData codec. The text form is how hand-authored decks and (later)
## set-piece room prefabs are stored, and it is the fastest way to eyeball a
## generator's output — a deck printed to stdout beats a screenshot when you are
## iterating on layout.
##
## Legend (one glyph per tile):
##   ' ' void      '.' floor     '#' wall      'R' raised platform
##   'l' light cover           'h' heavy cover
##   'P' player spawn          'E' enemy spawn         'S' swarm spawn
##   'o' overhead light        'm' monitor light       'f' flickering light
##   's' stair tile, LOWERCASE — links to the platform directly north of it,
##       and is a different thing entirely from an uppercase 'S'
##
## One glyph per tile means the text form cannot hold two features on one tile
## (a spawn standing under a light, say). MapData can. encode() therefore picks
## by the precedence in _glyph_for and drops the rest; encode(parse(x)) == x
## holds for any layout that keeps one feature per tile, which the round-trip
## test asserts. Generators that need overlap must not round-trip through text.

const GLYPHS := {
	" ": [MapData.Terrain.VOID, MapData.Cover.NONE, MapData.Fixture.NONE, MapData.Spawn.NONE, false],
	".": [MapData.Terrain.FLOOR, MapData.Cover.NONE, MapData.Fixture.NONE, MapData.Spawn.NONE, false],
	"#": [MapData.Terrain.WALL, MapData.Cover.NONE, MapData.Fixture.NONE, MapData.Spawn.NONE, false],
	"R": [MapData.Terrain.PLATFORM, MapData.Cover.NONE, MapData.Fixture.NONE, MapData.Spawn.NONE, false],
	"l": [MapData.Terrain.FLOOR, MapData.Cover.LIGHT, MapData.Fixture.NONE, MapData.Spawn.NONE, false],
	"h": [MapData.Terrain.FLOOR, MapData.Cover.HEAVY, MapData.Fixture.NONE, MapData.Spawn.NONE, false],
	"P": [MapData.Terrain.FLOOR, MapData.Cover.NONE, MapData.Fixture.NONE, MapData.Spawn.PLAYER, false],
	"E": [MapData.Terrain.FLOOR, MapData.Cover.NONE, MapData.Fixture.NONE, MapData.Spawn.ENEMY, false],
	"S": [MapData.Terrain.FLOOR, MapData.Cover.NONE, MapData.Fixture.NONE, MapData.Spawn.SWARM, false],
	"o": [MapData.Terrain.FLOOR, MapData.Cover.NONE, MapData.Fixture.OVERHEAD, MapData.Spawn.NONE, false],
	"m": [MapData.Terrain.FLOOR, MapData.Cover.NONE, MapData.Fixture.MONITOR, MapData.Spawn.NONE, false],
	"f": [MapData.Terrain.FLOOR, MapData.Cover.NONE, MapData.Fixture.FLICKER, MapData.Spawn.NONE, false],
	"s": [MapData.Terrain.FLOOR, MapData.Cover.NONE, MapData.Fixture.NONE, MapData.Spawn.NONE, true],
}


static func parse(rows: PackedStringArray, deck: int = 0) -> MapData:
	var data := MapData.new()
	for z in rows.size():
		var row: String = rows[z]
		for x in row.length():
			var glyph: String = row[x]
			if not GLYPHS.has(glyph):
				push_error("MapAscii: unknown glyph '%s' at (%d, %d)" % [glyph, x, z])
				continue
			var spec: Array = GLYPHS[glyph]
			var cell := MapData.Cell.new()
			cell.terrain = spec[0]
			cell.cover = spec[1]
			cell.fixture = spec[2]
			cell.spawn = spec[3]
			cell.stair = spec[4]
			data.set_cell(Vector3i(x, deck, z), cell)
	data.resolve_stairs()
	return data


static func encode(data: MapData, deck: int = 0) -> PackedStringArray:
	var rows := PackedStringArray()
	for z in data.size.y:
		var row := ""
		for x in data.size.x:
			row += _glyph_for(data.get_cell(Vector3i(x, deck, z)))
		rows.append(row)
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
	match cell.cover:
		MapData.Cover.LIGHT: return "l"
		MapData.Cover.HEAVY: return "h"
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
	return "\n".join(encode(data, deck))
