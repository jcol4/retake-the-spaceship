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
##   'D' door — a walkable gap in a wall line, distinct from '.' only so
##       corridor-vs-room bookkeeping (MapData.room_of) can tell them apart;
##       nothing renders differently there any more
##   'P' player spawn          'E' enemy spawn         'S' swarm spawn
##   'B' brawler spawn — the swarm's heavy, same melee loop, twice the HP
##   Security robots, one glyph per model, taken from the first letter of the
##   MODEL CODE rather than of the name — the names collide with glyphs that are
##   already spoken for (S is the swarm, s is a stair), the codes do not:
##   'Q' QRN-4 Auxilium        'M' MKV-9 Sagittarii
##   'X' XVT-7 Proctor         'J' JXM-2 Securus
##   'V' rival merc spawn — 'M' was already the Sagittarii's, so this takes the
##       free letter out of "rival"
##   'A' Agile Hunter spawn (Sec 11.5) — its own initial, still free rather than bumping an established glyph
##   'W' worm spawn
##   'N' spawn nest (Sec 11.7) — a destructible OBJECTIVE, not a unit. It draws
##       from the turn pool and passes; clear-out is not won while one stands
##   'o' overhead light        'm' monitor light       'f' flickering light
##   '!' alarm panel — emits no light; tripped by anything non-alien walking onto
##       it, and fires once (Sec 6)
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
##
## `[worms]` is the same idea for a worm MASS. A mass is one `WormUnit` holding
## more HP rather than a separate unit type, so there is no glyph that could say
## "nine worms here" — the grid marks the tile 'W' as usual and this section
## attaches the count. Each line is `x,z count`; absent means one, which is what
## keeps every deck written before this existed reading exactly as it did.
##
## `[obstacles]` is the same idea for multi-tile furniture: a footprint spans
## several tiles, which a one-glyph-per-tile grid can't name any better than it
## can name a boundary. Each line is `x,z w,h light|heavy`, naming the
## footprint's top-left corner and size. The grid itself shows '.' underneath —
## MapData.Terrain.OBSTACLE is applied by the section, same as cover is applied
## on top of whatever the grid glyph already said.
##
## `[hangars]` (GDD §7.2) names each hangar's landing pad: `x,z SIDE` with an
## optional trailing `insertion`. SIDE is the way the ramp faces — N, E, S or W,
## all four this time, because it names a DIRECTION, not an edge, so the
## canonical-side rule above does not apply. Everything else about a hangar is
## derived (MapData.add_hangar): the bay is the compartment the pad sits in, the
## 3x3 extraction square sits in front of the ramp. The grid shows the pad and
## square as ordinary floor; there is no hangar glyph, for the same reason there
## is no cover glyph — a hangar is a room-sized thing, not a tile.
##
## `[loot]` (extraction plan 3.2) places a loot container — a crate the squad
## loots from a neighbouring tile — and lists what is in it: `x,z` followed by
## zero or more ItemPresets codes, space-separated (`10,1 scrap_electronics
## fusion_cell`). No glyph, because the contents are the point and a glyph cannot
## carry a list; the grid shows the crate's tile as the floor it stands on.

const GLYPHS := {
	" ": [MapData.Terrain.VOID, MapData.Fixture.NONE, MapData.Spawn.NONE, false],
	".": [MapData.Terrain.FLOOR, MapData.Fixture.NONE, MapData.Spawn.NONE, false],
	"#": [MapData.Terrain.WALL, MapData.Fixture.NONE, MapData.Spawn.NONE, false],
	"R": [MapData.Terrain.PLATFORM, MapData.Fixture.NONE, MapData.Spawn.NONE, false],
	"D": [MapData.Terrain.DOOR, MapData.Fixture.NONE, MapData.Spawn.NONE, false],
	"P": [MapData.Terrain.FLOOR, MapData.Fixture.NONE, MapData.Spawn.PLAYER, false],
	"E": [MapData.Terrain.FLOOR, MapData.Fixture.NONE, MapData.Spawn.ENEMY, false],
	"S": [MapData.Terrain.FLOOR, MapData.Fixture.NONE, MapData.Spawn.SWARM, false],
	"B": [MapData.Terrain.FLOOR, MapData.Fixture.NONE, MapData.Spawn.BRAWLER, false],
	"Q": [MapData.Terrain.FLOOR, MapData.Fixture.NONE, MapData.Spawn.AUXILIUM, false],
	"M": [MapData.Terrain.FLOOR, MapData.Fixture.NONE, MapData.Spawn.SAGITTARII, false],
	"X": [MapData.Terrain.FLOOR, MapData.Fixture.NONE, MapData.Spawn.PROCTOR, false],
	"J": [MapData.Terrain.FLOOR, MapData.Fixture.NONE, MapData.Spawn.SECURUS, false],
	# Rival merc. NOT "M" — that belongs to the MKV Sagittarii, and the robot
	# glyphs were assigned off model codes precisely because names collide. "V"
	# is the free letter out of "rival".
	"V": [MapData.Terrain.FLOOR, MapData.Fixture.NONE, MapData.Spawn.MERC, false],
	# Agile Hunter (Sec 11.5). 'A' for the name's own initial — free, unlike the
	# melee tier's 'S'/'B', which were taken before it existed.
	"A": [MapData.Terrain.FLOOR, MapData.Fixture.NONE, MapData.Spawn.HUNTER, false],
	# Worm. Its own initial, which was free.
	"W": [MapData.Terrain.FLOOR, MapData.Fixture.NONE, MapData.Spawn.WORM, false],
	# Spawn nest (Sec 11.7). 'N' for the name, and free — never claimed.
	"N": [MapData.Terrain.FLOOR, MapData.Fixture.NONE, MapData.Spawn.NEST, false],
	"F": [MapData.Terrain.FLOOR, MapData.Fixture.NONE, MapData.Spawn.LICTOR, false],
	"o": [MapData.Terrain.FLOOR, MapData.Fixture.OVERHEAD, MapData.Spawn.NONE, false],
	"m": [MapData.Terrain.FLOOR, MapData.Fixture.MONITOR, MapData.Spawn.NONE, false],
	"f": [MapData.Terrain.FLOOR, MapData.Fixture.FLICKER, MapData.Spawn.NONE, false],
	# Alarm panel (Sec 6 trigger 2). Lowercase like the other fixtures, since it
	# is a thing on a tile rather than something that spawns on one.
	"!": [MapData.Terrain.FLOOR, MapData.Fixture.ALARM, MapData.Spawn.NONE, false],
	"s": [MapData.Terrain.FLOOR, MapData.Fixture.NONE, MapData.Spawn.NONE, true],
}

const COVER_SECTION := "[cover]"
const OBSTACLES_SECTION := "[obstacles]"
const WORMS_SECTION := "[worms]"
const HANGARS_SECTION := "[hangars]"
const WRECKS_SECTION := "[wrecks]"
const LOOT_SECTION := "[loot]"
## The word that marks the insertion hangar on a `[hangars]` line.
const INSERTION_WORD := "insertion"
## Ramp directions for `[hangars]`. All four sides, unlike SIDE_NAMES — see the
## header: a ramp faces a direction, it does not sit on a shared edge.
const RAMP_NAMES := {
	"E": MapData.Side.EAST, "S": MapData.Side.SOUTH, "W": MapData.Side.WEST, "N": MapData.Side.NORTH,
}
const RAMP_GLYPH := {
	MapData.Side.EAST: "E", MapData.Side.SOUTH: "S", MapData.Side.WEST: "W", MapData.Side.NORTH: "N",
}

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
	_parse_obstacles(data, rows, deck)
	_parse_wrecks(data, rows, deck)
	_parse_worms(data, rows, deck)
	data.resolve_stairs()
	# Derived here rather than by the caller so every route into a MapData —
	# file, string, or test fixture — arrives with the same graph populated.
	data.compute_rooms()
	# After the room graph, not before: a hangar's bay IS a compartment of it.
	_parse_hangars(data, rows, deck)
	_parse_loot(data, rows, deck)
	_check_hangars(data)
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


## `[obstacles]` mirrors `[cover]`'s reasoning: a footprint spans several
## tiles, which a one-glyph-per-tile grid cannot express any more than it can
## express a boundary. Each line is `x,z w,h tier`, naming the footprint's
## top-left corner, its size in tiles, and light|heavy.
static func _parse_obstacles(data: MapData, rows: PackedStringArray, deck: int) -> void:
	var inside := false
	for raw in rows:
		var line: String = (raw as String).strip_edges()
		if line.begins_with("["):
			inside = line == OBSTACLES_SECTION
			continue
		if not inside or line.is_empty():
			continue
		var parts := line.split(" ", false)
		var coords := parts[0].split(",") if parts.size() == 3 else PackedStringArray()
		var size := parts[1].split(",") if parts.size() == 3 else PackedStringArray()
		if coords.size() != 2 or size.size() != 2 or not COVER_NAMES.has(parts[2]):
			push_error("MapAscii: bad [obstacles] line '%s' (want 'x,z w,h light|heavy')" % line)
			continue
		var footprint := Rect2i(int(coords[0]), int(coords[1]), int(size[0]), int(size[1]))
		var tier: int = COVER_NAMES[parts[2]]
		for z in range(footprint.position.y, footprint.position.y + footprint.size.y):
			for x in range(footprint.position.x, footprint.position.x + footprint.size.x):
				data.get_cell(Vector3i(x, deck, z)).terrain = MapData.Terrain.OBSTACLE
		data.obstacles.append([footprint, tier])


## `[worms]` names a COUNT for a tile the grid has already marked 'W'. Each line
## is `x,z count`.
##
## The grid cannot carry this itself. A worm mass is one `WormUnit` holding more
## HP rather than a distinct type (see the worm-mass design doc), so there is no
## per-tier glyph to spend — and spending four of them would be worse than the
## problem, since the tiers are a continuum of sixteen sizes and only the
## boundaries have names.
##
## Placing a count on a tile with no worm on it is an authoring mistake rather
## than a way to spawn one, and is rejected as such: the grid stays the single
## statement of WHERE things are, and this section only ever says how many.
static func _parse_worms(data: MapData, rows: PackedStringArray, deck: int) -> void:
	var inside := false
	for raw in rows:
		var line: String = (raw as String).strip_edges()
		if line.begins_with("["):
			inside = line == WORMS_SECTION
			continue
		if not inside or line.is_empty():
			continue
		var parts := line.split(" ", false)
		var coords := parts[0].split(",") if parts.size() == 2 else PackedStringArray()
		if coords.size() != 2 or not parts[1].is_valid_int():
			push_error("MapAscii: bad [worms] line '%s' (want 'x,z count')" % line)
			continue
		var pos := Vector3i(int(coords[0]), deck, int(coords[1]))
		var cell := data.get_cell(pos)
		if cell == null or cell.spawn != MapData.Spawn.WORM:
			push_error("MapAscii: [worms] line '%s' names a tile with no 'W' on it" % line)
			continue
		data.worm_counts[pos] = maxi(1, int(parts[1]))


## `[hangars]`: `x,z SIDE [insertion]` per line, naming the pad centre and the
## way the ramp faces. A pad that does not land in any compartment, or a square
## that is not entirely walkable, is an authoring mistake and says so — the
## hangar is still added, so the deck loads and the mistake is visible in play
## rather than silently missing.
static func _parse_hangars(data: MapData, rows: PackedStringArray, deck: int) -> void:
	var inside := false
	for raw in rows:
		var line: String = (raw as String).strip_edges()
		if line.begins_with("["):
			inside = line == HANGARS_SECTION
			continue
		if not inside or line.is_empty():
			continue
		var parts := line.split(" ", false)
		var coords := parts[0].split(",") if parts.size() in [2, 3] else PackedStringArray()
		var insertion := parts.size() == 3 and parts[2] == INSERTION_WORD
		if coords.size() != 2 or not RAMP_NAMES.has(parts[1]) or (parts.size() == 3 and not insertion):
			push_error("MapAscii: bad [hangars] line '%s' (want 'x,z N|E|S|W [insertion]')" % line)
			continue
		var pad := Vector3i(int(coords[0]), deck, int(coords[1]))
		var h := data.add_hangar(pad, RAMP_NAMES[parts[1]], insertion)
		if h.room_index < 0:
			push_error("MapAscii: [hangars] pad at %s is not inside any compartment" % pad)


## Every hangar must leave its pad and square clear (MapData.hangar_problem):
## somewhere for the ship to set down and nine tiles to board from. Run after the
## crates are placed, since a crate on the square is as much a mistake as a wall.
static func _check_hangars(data: MapData) -> void:
	for h: MapData.Hangar in data.hangars:
		var why := data.hangar_problem(h)
		if why != "":
			push_error("MapAscii: [hangars] the hangar at %s is not usable: %s" % [h.pad_center, why])


## `[wrecks]`: `x,z w,h` per line — a full-height, indestructible footprint
## (MapData.wrecks), the hangar set dressing that blocks sight like a wall.
static func _parse_wrecks(data: MapData, rows: PackedStringArray, deck: int) -> void:
	var inside := false
	for raw in rows:
		var line: String = (raw as String).strip_edges()
		if line.begins_with("["):
			inside = line == WRECKS_SECTION
			continue
		if not inside or line.is_empty():
			continue
		var parts := line.split(" ", false)
		var coords := parts[0].split(",") if parts.size() == 2 else PackedStringArray()
		var size := parts[1].split(",") if parts.size() == 2 else PackedStringArray()
		if coords.size() != 2 or size.size() != 2:
			push_error("MapAscii: bad [wrecks] line '%s' (want 'x,z w,h')" % line)
			continue
		var footprint := Rect2i(int(coords[0]), int(coords[1]), int(size[0]), int(size[1]))
		for z in range(footprint.position.y, footprint.position.y + footprint.size.y):
			for x in range(footprint.position.x, footprint.position.x + footprint.size.x):
				data.get_cell(Vector3i(x, deck, z)).terrain = MapData.Terrain.OBSTACLE
		data.wrecks.append(footprint)


static func encode_wrecks(data: MapData, _deck: int = 0) -> PackedStringArray:
	var rows := PackedStringArray()
	for footprint: Rect2i in data.wrecks:
		if rows.is_empty():
			rows.append("")
			rows.append(WRECKS_SECTION)
		rows.append("%d,%d %d,%d" % [
			footprint.position.x, footprint.position.y, footprint.size.x, footprint.size.y])
	return rows


## `[loot]`: `x,z [code ...]` per line. A crate on a tile nobody could stand on
## (a wall, void, a spawn) or with an item code that names nothing is an authoring
## mistake and says so; a bad code is dropped, the crate is still placed.
static func _parse_loot(data: MapData, rows: PackedStringArray, deck: int) -> void:
	var inside := false
	for raw in rows:
		var line: String = (raw as String).strip_edges()
		if line.begins_with("["):
			inside = line == LOOT_SECTION
			continue
		if not inside or line.is_empty():
			continue
		var parts := line.split(" ", false)
		var coords := parts[0].split(",")
		if coords.size() != 2 or not coords[0].is_valid_int() or not coords[1].is_valid_int():
			push_error("MapAscii: bad [loot] line '%s' (want 'x,z [item ...]')" % line)
			continue
		var pos := Vector3i(int(coords[0]), deck, int(coords[1]))
		var cell := data.get_cell(pos)
		if not data.is_walkable(pos) or (cell != null and cell.spawn != MapData.Spawn.NONE) \
				or data.has_container(pos):
			push_error("MapAscii: [loot] crate at %s is not on a free floor tile" % pos)
			continue
		var items := PackedStringArray()
		for i in range(1, parts.size()):
			if ItemPresets.from_code(parts[i]) == null:
				push_error("MapAscii: [loot] line '%s' names an unknown item '%s'" % [line, parts[i]])
				continue
			items.append(parts[i])
		data.add_container(pos, items)


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


static func encode_obstacles(data: MapData, deck: int = 0) -> PackedStringArray:
	var rows := PackedStringArray()
	for entry: Array in data.obstacles:
		var footprint: Rect2i = entry[0]
		var tier: int = entry[1]
		if rows.is_empty():
			rows.append("")
			rows.append(OBSTACLES_SECTION)
		rows.append("%d,%d %d,%d %s" % [
			footprint.position.x, footprint.position.y,
			footprint.size.x, footprint.size.y,
			COVER_WORD[tier],
		])
	return rows


## Counts above one only. A lone worm is what an absent entry already means, so
## writing `13,2 1` would grow a section onto every deck that has ever held a
## worm and make the round-trip test fail on files nobody edited.
##
## Sorted, because `worm_counts` is a Dictionary and its iteration order is
## insertion order — which is parse order for a file, but arbitrary for a
## generated or hand-built MapData. Without this, `to_text` of the same deck
## could emit the same lines in a different sequence.
static func encode_worms(data: MapData, deck: int = 0) -> PackedStringArray:
	var rows := PackedStringArray()
	var positions: Array = []
	for pos: Vector3i in data.worm_counts:
		if pos.y == deck and data.worm_counts[pos] > 1:
			positions.append(pos)
	positions.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		return a.z < b.z if a.z != b.z else a.x < b.x)
	for pos: Vector3i in positions:
		if rows.is_empty():
			rows.append("")
			rows.append(WORMS_SECTION)
		rows.append("%d,%d %d" % [pos.x, pos.z, data.worm_counts[pos]])
	return rows


## In list order, which is parse order for a file — so a text deck round-trips
## byte-identical — and placement order for a generated one. Empty for a deck
## with no hangar, so the legacy decks do not grow a section on the way out.
static func encode_hangars(data: MapData, deck: int = 0) -> PackedStringArray:
	var rows := PackedStringArray()
	for h: MapData.Hangar in data.hangars:
		if h.pad_center.y != deck:
			continue
		if rows.is_empty():
			rows.append("")
			rows.append(HANGARS_SECTION)
		var line := "%d,%d %s" % [h.pad_center.x, h.pad_center.z, RAMP_GLYPH[h.ramp_side]]
		if h.is_insertion:
			line += " " + INSERTION_WORD
		rows.append(line)
	return rows


## In list order — parse order for a file, placement order for a generated deck.
## Empty for a deck with no containers, so older decks do not grow a section.
static func encode_loot(data: MapData, deck: int = 0) -> PackedStringArray:
	var rows := PackedStringArray()
	for spot: MapData.LootSpot in data.containers:
		if spot.pos.y != deck:
			continue
		if rows.is_empty():
			rows.append("")
			rows.append(LOOT_SECTION)
		var line := "%d,%d" % [spot.pos.x, spot.pos.z]
		if not spot.items.is_empty():
			line += " " + " ".join(spot.items)
		rows.append(line)
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
	if cell.terrain == MapData.Terrain.DOOR:
		return "D"
	match cell.spawn:
		MapData.Spawn.PLAYER: return "P"
		MapData.Spawn.ENEMY: return "E"
		MapData.Spawn.SWARM: return "S"
		MapData.Spawn.BRAWLER: return "B"
		MapData.Spawn.AUXILIUM: return "Q"
		MapData.Spawn.SAGITTARII: return "M"
		MapData.Spawn.PROCTOR: return "X"
		MapData.Spawn.SECURUS: return "J"
		MapData.Spawn.MERC: return "V"
		MapData.Spawn.HUNTER: return "A"
		MapData.Spawn.WORM: return "W"
		MapData.Spawn.NEST: return "N"
		MapData.Spawn.LICTOR: return "F"
	match cell.fixture:
		MapData.Fixture.OVERHEAD: return "o"
		MapData.Fixture.MONITOR: return "m"
		MapData.Fixture.FLICKER: return "f"
		MapData.Fixture.ALARM: return "!"
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
	rows.append_array(encode_obstacles(data, deck))
	rows.append_array(encode_wrecks(data, deck))
	rows.append_array(encode_worms(data, deck))
	rows.append_array(encode_hangars(data, deck))
	rows.append_array(encode_loot(data, deck))
	return "\n".join(rows)
