class_name RoomTypes
extends RefCounted
## What a room is FOR (ROOM_THEMES_PLAN.md A.1): every room type a themed deck can
## hold, with the numbers the generator, the builder and the mission read off it.
## A table like the other *_presets.gd files, engine-free so the generator and its
## tests can use it headless.
##
## A room's type is a StringName stored per room on MapData (`room_types`), so it
## saves as text (MapAscii's `[rooms]`) and never depends on enum order. The two
## enums here, Zone and Condition, ARE saved or sent as ints: APPEND-ONLY.
##
## Sizes are in tiles and "tactically roomy" (plan decision 9, about 1.5x a real
## ship's): a pair of ranges, one for the short side and one for the long side,
## so the generator can lay a room either way round. The ones the plan's "Room
## sizes" table names are its numbers; the rest are sized against those, as A.1
## asks, and are the first thing to retune once the reroll rate is measured
## (Phase B.6 / C.8).

enum Zone { HABITATION, MEDICAL, ENGINEERING, COMMAND, CARGO, UTILITY, NONE }
## Contract.Type ids, kept engine-free for MapGenerator's standalone tools.
const OBJECTIVE_ROOMS := {
	0: [&"server_room", &"bridge", &"lab", &"data_storage"],
	1: [&"engine_room"],
	2: [&"bridge", &"security_station"],
	3: [&"cabin", &"captains_quarters", &"brig", &"bunk_room"],
}

const ZONE_NAME := {
	Zone.HABITATION: "Habitation", Zone.MEDICAL: "Medical", Zone.ENGINEERING: "Engineering",
	Zone.COMMAND: "Command", Zone.CARGO: "Cargo", Zone.UTILITY: "Utility", Zone.NONE: "",
}

## Plan D.4: the state a room is found in, rolled per room.
enum Condition { INTACT, RANSACKED, BARRICADED, OVERRUN }

const CONDITION_NAME := {
	Condition.INTACT: "intact", Condition.RANSACKED: "ransacked",
	Condition.BARRICADED: "barricaded", Condition.OVERRUN: "overrun",
}

## Door rules (plan "Door rules", decision 17). ONE: a dead end, given one
## corridor link at most. TWO_PLUS: a through-room, given at least two. ANY: the
## router decides.
enum Doors { ANY, ONE, TWO_PLUS }

## Furniture arrangements (plan D.2). RANDOM is today's cover scatter, the
## fallback for any type without a layout of its own.
enum Layout {
	RANDOM, MESS_ROWS, BUNKS, LAB_ISLANDS, LOCKER_ROWS, SERVER_ROWS, MACHINERY, CONSOLE_ROWS,
	BATHROOM, GALLEY, MED_BEDS, CARGO, CELLS, CRATES, WALL_RACKS, NONE,
}

## The types every deck has whatever it rolled: not rooms a generator places from
## this table, but the names it gives the rest of `MapData.rooms`.
const CORRIDOR := &"corridor"
## One of the two port/starboard passageways (plan B.5). A corridor in every
## other respect: it is listed in `MapData.corridors`.
const SPINE := &"spine"
const HANGAR := &"hangar"
## A room in a hand-authored deck without a `[rooms]` line, and every room the
## old (untyped) generator makes.
const GENERIC := &"generic"

## Light colours (plan D.5): clinical white in medical, sodium orange in
## engineering, dim blue in quarters. The rest sit between them.
const LIGHT_CLINICAL := Color(0.9, 0.96, 1.0)
const LIGHT_SODIUM := Color(1.0, 0.6, 0.26)
const LIGHT_QUARTERS := Color(0.55, 0.64, 1.0)
const LIGHT_WARM := Color(1.0, 0.86, 0.68)
const LIGHT_COMMAND := Color(0.72, 0.88, 1.0)
const LIGHT_NEUTRAL := Color(0.88, 0.88, 0.84)

## Faction keys for `home` (plan F.1). StringNames rather than Faction values so
## this table stays free of the unit classes.
const ALIENS := &"aliens"
const ROBOTS := &"robots"
const MERCS := &"mercs"

## Every type. Fields:
##   name       display name (HUD tooltip, plan D.9)
##   zone       Zone
##   short/long [min, max] tiles for the room's short and long side
##   cap        most of this type on one deck; 0 is unlimited
##   doors      Doors
##   near       {type: weight} soft neighbour preferences (plan "Neighbour rules"):
##              positive pulls the two together, negative pushes them apart
##   layout     Layout
##   light      Color
##   floor      "medical" | "engineering" | "quarters" | "command" | "" (kit floor)
##   loot       loot table key (plan F.2; ItemPresets)
##   home       factions this is a home room for (plan F.1)
##   locked     a locked room (plan E.3)
const TYPES := {
	# --- Habitation -------------------------------------------------------------
	&"bunk_room": {"name": "Bunk Room", "zone": Zone.HABITATION, "short": [6, 8], "long": [8, 10], "cap": 0,
		"doors": Doors.ANY, "near": {&"bathroom": 3.0, &"locker_room": 1.5, &"bunk_room": 1.0,
			&"engine_room": -4.0, &"life_support": -4.0, &"fuel_storage": -4.0, &"cargo_hold": -4.0},
		"layout": Layout.BUNKS, "light": LIGHT_QUARTERS, "floor": "quarters", "loot": &"quarters", "home": []},
	&"bathroom": {"name": "Bathroom Block", "zone": Zone.HABITATION, "short": [4, 5], "long": [6, 8], "cap": 0,
		"doors": Doors.ANY, "near": {&"bunk_room": 3.0},
		"layout": Layout.BATHROOM, "light": LIGHT_NEUTRAL, "floor": "medical", "loot": &"generic", "home": []},
	&"locker_room": {"name": "Locker Room", "zone": Zone.HABITATION, "short": [4, 6], "long": [6, 8], "cap": 2,
		"doors": Doors.ANY, "near": {&"bunk_room": 1.5, &"gym": 1.5},
		"layout": Layout.LOCKER_ROWS, "light": LIGHT_QUARTERS, "floor": "quarters", "loot": &"quarters", "home": []},
	&"laundry": {"name": "Laundry", "zone": Zone.HABITATION, "short": [4, 5], "long": [5, 7], "cap": 1,
		"doors": Doors.ONE, "near": {&"bunk_room": 1.5},
		"layout": Layout.WALL_RACKS, "light": LIGHT_NEUTRAL, "floor": "", "loot": &"generic", "home": []},
	&"mess": {"name": "Mess Hall", "zone": Zone.HABITATION, "short": [12, 14], "long": [14, 18], "cap": 2,
		"doors": Doors.TWO_PLUS, "near": {&"galley": 4.0, &"cold_store": 1.0, &"medbay": 0.5},
		"layout": Layout.MESS_ROWS, "light": LIGHT_WARM, "floor": "", "loot": &"mess", "home": []},
	&"galley": {"name": "Galley", "zone": Zone.HABITATION, "short": [6, 7], "long": [8, 10], "cap": 2,
		"doors": Doors.ANY, "near": {&"mess": 4.0, &"cold_store": 3.0},
		"layout": Layout.GALLEY, "light": LIGHT_WARM, "floor": "medical", "loot": &"mess", "home": []},
	&"cold_store": {"name": "Cold Store", "zone": Zone.HABITATION, "short": [4, 5], "long": [5, 6], "cap": 2,
		"doors": Doors.ONE, "near": {&"galley": 3.0},
		"layout": Layout.CRATES, "light": LIGHT_CLINICAL, "floor": "", "loot": &"mess", "home": []},
	&"lounge": {"name": "Lounge", "zone": Zone.HABITATION, "short": [7, 8], "long": [8, 10], "cap": 1,
		"doors": Doors.ANY, "near": {&"mess": 1.0, &"bunk_room": 1.0},
		"layout": Layout.RANDOM, "light": LIGHT_WARM, "floor": "quarters", "loot": &"quarters", "home": []},
	&"gym": {"name": "Gym", "zone": Zone.HABITATION, "short": [7, 8], "long": [8, 10], "cap": 1,
		"doors": Doors.ANY, "near": {&"locker_room": 1.5},
		"layout": Layout.RANDOM, "light": LIGHT_NEUTRAL, "floor": "", "loot": &"generic", "home": []},
	&"cabin": {"name": "Officer's Cabin", "zone": Zone.HABITATION, "short": [4, 5], "long": [5, 6], "cap": 0,
		"doors": Doors.ONE, "near": {&"cabin": 1.5, &"captains_quarters": 1.0,
			&"engine_room": -3.0, &"cargo_hold": -3.0},
		"layout": Layout.RANDOM, "light": LIGHT_QUARTERS, "floor": "quarters", "loot": &"quarters", "home": []},
	&"captains_quarters": {"name": "Captain's Quarters", "zone": Zone.HABITATION, "short": [6, 7], "long": [7, 9],
		"cap": 1, "doors": Doors.ONE, "near": {&"bridge": 2.0, &"cabin": 1.0},
		"layout": Layout.RANDOM, "light": LIGHT_QUARTERS, "floor": "quarters", "loot": &"captain", "home": [],
		"locked": true},

	# --- Medical + Research --------------------------------------------------------
	&"medbay": {"name": "Medbay", "zone": Zone.MEDICAL, "short": [8, 10], "long": [10, 14], "cap": 2,
		"doors": Doors.TWO_PLUS, "near": {&"surgery": 3.0, &"icu": 3.0, &"mess": 0.5, &"hangar": 0.5},
		"layout": Layout.MED_BEDS, "light": LIGHT_CLINICAL, "floor": "medical", "loot": &"medical", "home": []},
	&"surgery": {"name": "Surgery", "zone": Zone.MEDICAL, "short": [6, 7], "long": [7, 9], "cap": 1,
		"doors": Doors.ANY, "near": {&"medbay": 3.0, &"morgue": 2.0, &"icu": 1.5},
		"layout": Layout.RANDOM, "light": LIGHT_CLINICAL, "floor": "medical", "loot": &"medical", "home": []},
	&"icu": {"name": "ICU", "zone": Zone.MEDICAL, "short": [6, 8], "long": [7, 9], "cap": 1,
		"doors": Doors.ANY, "near": {&"medbay": 3.0, &"surgery": 1.5},
		"layout": Layout.MED_BEDS, "light": LIGHT_CLINICAL, "floor": "medical", "loot": &"medical", "home": []},
	&"morgue": {"name": "Morgue", "zone": Zone.MEDICAL, "short": [5, 6], "long": [7, 9], "cap": 1,
		"doors": Doors.ANY, "near": {&"surgery": 2.0, &"cryo": 1.0},
		"layout": Layout.WALL_RACKS, "light": LIGHT_CLINICAL, "floor": "medical", "loot": &"research",
		"home": [ALIENS]},
	&"cryo": {"name": "Cryo Bay", "zone": Zone.MEDICAL, "short": [6, 8], "long": [8, 10], "cap": 1,
		"doors": Doors.ANY, "near": {&"morgue": 1.0, &"specimen_hold": 1.0},
		"layout": Layout.SERVER_ROWS, "light": LIGHT_CLINICAL, "floor": "medical", "loot": &"research",
		"home": [ALIENS]},
	&"lab": {"name": "Laboratory", "zone": Zone.MEDICAL, "short": [8, 10], "long": [10, 12], "cap": 2,
		"doors": Doors.TWO_PLUS, "near": {&"clean_room": 3.0, &"specimen_hold": 3.0, &"data_storage": 1.0},
		"layout": Layout.LAB_ISLANDS, "light": LIGHT_CLINICAL, "floor": "medical", "loot": &"research",
		"home": [ALIENS]},
	&"clean_room": {"name": "Clean Room", "zone": Zone.MEDICAL, "short": [5, 6], "long": [6, 8], "cap": 1,
		"doors": Doors.ANY, "near": {&"lab": 3.0},
		"layout": Layout.LAB_ISLANDS, "light": LIGHT_CLINICAL, "floor": "medical", "loot": &"research", "home": []},
	&"specimen_hold": {"name": "Specimen Hold", "zone": Zone.MEDICAL, "short": [6, 8], "long": [8, 10], "cap": 1,
		"doors": Doors.ANY, "near": {&"lab": 3.0, &"cryo": 1.0},
		"layout": Layout.SERVER_ROWS, "light": LIGHT_CLINICAL, "floor": "medical", "loot": &"research",
		"home": [ALIENS]},
	&"imaging": {"name": "Imaging", "zone": Zone.MEDICAL, "short": [5, 6], "long": [6, 8], "cap": 1,
		"doors": Doors.ANY, "near": {&"medbay": 1.5},
		"layout": Layout.CONSOLE_ROWS, "light": LIGHT_CLINICAL, "floor": "medical", "loot": &"medical", "home": []},
	&"data_storage": {"name": "Data Storage", "zone": Zone.MEDICAL, "short": [5, 6], "long": [6, 8], "cap": 1,
		"doors": Doors.ONE, "near": {&"lab": 1.0},
		"layout": Layout.SERVER_ROWS, "light": LIGHT_CLINICAL, "floor": "command", "loot": &"research", "home": []},

	# --- Engineering ---------------------------------------------------------------
	&"engine_room": {"name": "Engine Room", "zone": Zone.ENGINEERING, "short": [16, 18], "long": [18, 22],
		"cap": 1, "doors": Doors.TWO_PLUS, "near": {&"engineering_control": 3.0, &"fuel_storage": 2.0,
			&"life_support": 1.0},
		"layout": Layout.MACHINERY, "light": LIGHT_SODIUM, "floor": "engineering", "loot": &"engineering", "home": []},
	&"engineering_control": {"name": "Engineering Control", "zone": Zone.ENGINEERING, "short": [7, 8],
		"long": [8, 10], "cap": 1, "doors": Doors.TWO_PLUS, "near": {&"engine_room": 3.0},
		"layout": Layout.CONSOLE_ROWS, "light": LIGHT_SODIUM, "floor": "engineering", "loot": &"engineering",
		"home": []},
	&"fuel_storage": {"name": "Fuel Storage", "zone": Zone.ENGINEERING, "short": [5, 6], "long": [6, 8], "cap": 1,
		"doors": Doors.ANY, "near": {&"engine_room": 2.0},
		"layout": Layout.CRATES, "light": LIGHT_SODIUM, "floor": "engineering", "loot": &"engineering", "home": []},
	&"life_support": {"name": "Life Support", "zone": Zone.ENGINEERING, "short": [7, 9], "long": [9, 11], "cap": 1,
		"doors": Doors.TWO_PLUS, "near": {&"engine_room": 1.0},
		"layout": Layout.MACHINERY, "light": LIGHT_SODIUM, "floor": "engineering", "loot": &"engineering", "home": []},
	&"fabrication": {"name": "Fabrication Shop", "zone": Zone.ENGINEERING, "short": [7, 8], "long": [8, 10],
		"cap": 1, "doors": Doors.TWO_PLUS, "near": {&"engine_room": 1.0, &"armory": 0.5},
		"layout": Layout.LAB_ISLANDS, "light": LIGHT_SODIUM, "floor": "engineering", "loot": &"engineering",
		"home": []},
	&"maintenance": {"name": "Maintenance Crawlway", "zone": Zone.ENGINEERING, "short": [3, 4], "long": [8, 12],
		"cap": 2, "doors": Doors.ANY, "near": {&"engine_room": 1.0, &"life_support": 1.0},
		"layout": Layout.RANDOM, "light": LIGHT_SODIUM, "floor": "engineering", "loot": &"engineering", "home": []},

	# --- Command + Security ----------------------------------------------------------
	&"bridge": {"name": "Bridge", "zone": Zone.COMMAND, "short": [10, 12], "long": [12, 16], "cap": 1,
		"doors": Doors.ANY, "near": {&"comms": 3.0, &"navigation": 3.0, &"captains_quarters": 2.0},
		"layout": Layout.CONSOLE_ROWS, "light": LIGHT_COMMAND, "floor": "command", "loot": &"command",
		"home": [ROBOTS], "locked": true},
	&"security_station": {"name": "Security Station", "zone": Zone.COMMAND, "short": [6, 8], "long": [7, 9],
		"cap": 1, "doors": Doors.ANY, "near": {&"armory": 3.0, &"brig": 2.0},
		"layout": Layout.CONSOLE_ROWS, "light": LIGHT_COMMAND, "floor": "command", "loot": &"command",
		"home": [ROBOTS]},
	&"armory": {"name": "Armory", "zone": Zone.COMMAND, "short": [5, 6], "long": [6, 8], "cap": 1,
		"doors": Doors.ONE, "near": {&"security_station": 3.0},
		"layout": Layout.WALL_RACKS, "light": LIGHT_COMMAND, "floor": "command", "loot": &"command",
		"home": [ROBOTS, MERCS], "locked": true},
	&"brig": {"name": "Brig", "zone": Zone.COMMAND, "short": [6, 8], "long": [8, 10], "cap": 1,
		"doors": Doors.ONE, "near": {&"security_station": 2.0},
		"layout": Layout.CELLS, "light": LIGHT_COMMAND, "floor": "command", "loot": &"command", "home": [],
		"locked": true},
	&"comms": {"name": "Comms", "zone": Zone.COMMAND, "short": [5, 7], "long": [6, 8], "cap": 1,
		"doors": Doors.ANY, "near": {&"bridge": 3.0, &"server_room": 1.0},
		"layout": Layout.CONSOLE_ROWS, "light": LIGHT_COMMAND, "floor": "command", "loot": &"command", "home": []},
	&"navigation": {"name": "Navigation", "zone": Zone.COMMAND, "short": [5, 7], "long": [6, 8], "cap": 1,
		"doors": Doors.ANY, "near": {&"bridge": 3.0},
		"layout": Layout.CONSOLE_ROWS, "light": LIGHT_COMMAND, "floor": "command", "loot": &"command", "home": []},
	&"server_room": {"name": "Server Room", "zone": Zone.COMMAND, "short": [6, 8], "long": [8, 10], "cap": 1,
		"doors": Doors.ONE, "near": {&"comms": 1.0, &"bridge": 1.0},
		"layout": Layout.SERVER_ROWS, "light": LIGHT_COMMAND, "floor": "command", "loot": &"command",
		"home": [ROBOTS], "locked": true},

	# --- Cargo -------------------------------------------------------------------------
	&"cargo_hold": {"name": "Cargo Hold", "zone": Zone.CARGO, "short": [10, 12], "long": [12, 16], "cap": 2,
		"doors": Doors.TWO_PLUS, "near": {&"hangar": 1.5, &"storage_closet": 1.0},
		"layout": Layout.CARGO, "light": LIGHT_NEUTRAL, "floor": "", "loot": &"generic", "home": [MERCS]},

	# --- Utility (filler, plan C.4) -----------------------------------------------------
	&"storage_closet": {"name": "Storage Closet", "zone": Zone.UTILITY, "short": [3, 4], "long": [3, 5], "cap": 0,
		"doors": Doors.ONE, "near": {},
		"layout": Layout.CRATES, "light": LIGHT_NEUTRAL, "floor": "", "loot": &"generic", "home": []},
	&"elevator_lobby": {"name": "Elevator Lobby", "zone": Zone.UTILITY, "short": [4, 5], "long": [4, 6], "cap": 0,
		"doors": Doors.ANY, "near": {},
		"layout": Layout.NONE, "light": LIGHT_NEUTRAL, "floor": "command", "loot": &"generic", "home": []},
}

## The types that are names for structure rather than rooms to place.
const STRUCTURAL := {
	CORRIDOR: {"name": "Corridor", "zone": Zone.NONE, "layout": Layout.NONE, "light": LIGHT_NEUTRAL, "floor": "",
		"loot": &"generic", "home": []},
	SPINE: {"name": "Main Passageway", "zone": Zone.NONE, "layout": Layout.NONE, "light": LIGHT_NEUTRAL,
		"floor": "", "loot": &"generic", "home": []},
	HANGAR: {"name": "Hangar Bay", "zone": Zone.NONE, "layout": Layout.NONE, "light": LIGHT_NEUTRAL, "floor": "",
		"loot": &"generic", "home": []},
	GENERIC: {"name": "Compartment", "zone": Zone.NONE, "layout": Layout.RANDOM, "light": LIGHT_NEUTRAL,
		"floor": "", "loot": &"generic", "home": []},
}

## Plan "Rooms per zone": what every band of a zone holds, and what it may roll.
## CARGO's list is this file's own (the plan names the zone but not its rooms).
const ZONE_REQUIRED := {
	Zone.HABITATION: [&"bunk_room", &"bathroom", &"mess", &"galley"],
	Zone.MEDICAL: [&"medbay", &"lab"],
	Zone.ENGINEERING: [&"engine_room", &"engineering_control"],
	Zone.COMMAND: [&"bridge", &"security_station"],
	Zone.CARGO: [&"cargo_hold"],
	Zone.UTILITY: [],
}
const ZONE_OPTIONAL := {
	Zone.HABITATION: [&"lounge", &"gym", &"cabin", &"cabin", &"captains_quarters", &"laundry", &"locker_room"],
	Zone.MEDICAL: [&"surgery", &"icu", &"morgue", &"cryo", &"clean_room", &"specimen_hold", &"imaging",
		&"data_storage"],
	Zone.ENGINEERING: [&"fuel_storage", &"life_support", &"fabrication", &"maintenance"],
	Zone.COMMAND: [&"armory", &"brig", &"comms", &"navigation", &"server_room"],
	Zone.CARGO: [&"cargo_hold", &"storage_closet"],
	Zone.UTILITY: [&"storage_closet", &"elevator_lobby"],
}


static func is_known(type: StringName) -> bool:
	return TYPES.has(type) or STRUCTURAL.has(type)


## A type's row, or GENERIC's for a name this table does not know (a deck written
## by a newer build, say), so a reader never has to null-check.
static func info(type: StringName) -> Dictionary:
	if TYPES.has(type):
		return TYPES[type]
	return STRUCTURAL.get(type, STRUCTURAL[GENERIC])


static func display_name(type: StringName) -> String:
	return String(info(type)["name"])


static func zone_of(type: StringName) -> int:
	return int(info(type)["zone"])


static func layout_of(type: StringName) -> int:
	return int(info(type)["layout"])


static func light_of(type: StringName) -> Color:
	return info(type)["light"]


static func floor_of(type: StringName) -> String:
	return String(info(type)["floor"])


static func loot_of(type: StringName) -> StringName:
	return info(type)["loot"]


static func is_home_of(type: StringName, faction: StringName) -> bool:
	return faction in info(type)["home"]


static func is_locked(type: StringName) -> bool:
	return bool(info(type).get("locked", false))


static func doors_of(type: StringName) -> int:
	return int(info(type).get("doors", Doors.ANY))


static func cap_of(type: StringName) -> int:
	return int(info(type).get("cap", 0))


## Soft neighbour weight between two types, symmetric: the stronger of the two
## rows' opinions, so a pull written on one side only still pulls both ways.
static func neighbour_weight(a: StringName, b: StringName) -> float:
	var ab := float(info(a).get("near", {}).get(b, 0.0))
	var ba := float(info(b).get("near", {}).get(a, 0.0))
	return ab if absf(ab) >= absf(ba) else ba


## The types of a zone, required first then optional, each once.
static func types_in(zone: int) -> Array[StringName]:
	var out: Array[StringName] = []
	for t: StringName in ZONE_REQUIRED.get(zone, []) + ZONE_OPTIONAL.get(zone, []):
		if not out.has(t):
			out.append(t)
	return out


static func condition_from_name(word: String) -> int:
	for c: int in CONDITION_NAME:
		if CONDITION_NAME[c] == word:
			return c
	return -1
