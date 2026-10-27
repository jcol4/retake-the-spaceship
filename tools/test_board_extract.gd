extends SceneTree
## Boarding, the Extract action, the ship's reserved space, wrecks, and the
## weapon switch (GDD §7.2, §7.4, §4.3).
##
##   godot --headless --path . --script res://tools/test_board_extract.gd
##
## Covers:
##   - rules: Board only from the square of the crew's OWN landed ship; Extract
##     needs the crew's own ship down (never a rival's) and somebody aboard or
##     alive in its square, and is asked of the crew, not the soldier's tile;
##     the aboard always leave with the ship (Extract or the window running out);
##   - boarding takes a soldier and the body it carries off the board: out of the
##     groups the AI, pool and end checks read, off its tile, untargetable;
##   - Extract from OUTSIDE the square ends the mission at once: the aboard and
##     the square go, everyone else is left behind;
##   - nobody left standing on the deck with somebody aboard is an extraction,
##     not a wipe;
##   - the landed ship blocks line of sight across its reserved space (not the
##     square), its door gun still sees over it, and the blocker leaves with it;
##   - wrecks round-trip through MapAscii, block sight and give heavy cover that
##     never wears down;
##   - switching weapons costs 1 AP, swaps the rounds in hand, is refused while
##     carrying, and survives picking up and putting down a body.
##
## Runs on maps/extraction_test.txt through the real ExtractionManager, driving
## its hooks by hand, like test_door_gun.gd.

const PLAYER := "res://scenes/player_unit.tscn"
const MERC := "res://scenes/merc_unit.tscn"
const DECK := "res://maps/extraction_test.txt"

## Hangar A: pad (3,6) — tiles x1..5, z4..8 — ramp east, square x6..8, z5..7.
const A := 0
const B := 1
const SQUARE_CENTRE := Vector3i(7, 0, 6)
const OUTSIDE := Vector3i(10, 0, 10)
## UnitStats.Action by value (a --script tool is compiled before the class
## registry exists; see test_suppression.gd).
const ACTION_PICK_UP := 8
const ACTION_BOARD := 13
const ACTION_SWITCH := 14
const ACTION_EXTRACT := 15

var _failures := 0
var _grid: Node
var _em: Node
var _tm: Node
var _map: Node
var _data
var LIFE
var R
var MD
var _ended: Array = []


class Soldier:
	var name: String
	var grid_pos: Vector3i
	var life_state: int

	func _init(n: String, pos: Vector3i, state: int = 0) -> void:
		name = n
		grid_pos = pos
		life_state = state


func _initialize() -> void:
	_grid = root.get_node_or_null("GridManager")
	_em = root.get_node_or_null("ExtractionManager")
	_tm = root.get_node_or_null("TurnManager")
	LIFE = load("res://scripts/unit.gd").LifeState
	R = load("res://scripts/extraction_rules.gd")
	MD = load("res://scripts/map_data.gd")
	_map = load("res://scenes/test_map.tscn").instantiate()
	_map.layout_path = DECK
	root.add_child(_map)
	await process_frame
	await physics_frame
	await physics_frame
	_data = _map.data
	seed(4242)
	_tm.clear_out_mode = false
	_tm.mission_over = false
	_tm.mission_ended.connect(func(result) -> void: _ended.append(result))

	_check_costs()
	_check_rules()
	await _check_board_and_extract()
	await _check_squad_gone()
	await _check_ship_blocks_sight()
	await _check_wrecks()
	await _check_weapon_switch()

	_em.reset()
	_tm.pool.clear()
	print("")
	if _failures == 0:
		print("board_extract: ALL CHECKS PASSED")
		quit(0)
	else:
		print("board_extract: %d CHECK(S) FAILED" % _failures)
		quit(1)


func _check_costs() -> void:
	print("-- prices")
	var flat: Dictionary = load("res://scripts/unit_stats.gd").FLAT_AP_COST
	_check(flat[ACTION_BOARD] == 1 and flat[ACTION_SWITCH] == 1 and flat[ACTION_EXTRACT] == 0,
		"board 1, switch weapon 1, extract 0 — all flat")
	_check(flat[ACTION_PICK_UP] == 2, "pick up stays 2 (the pistol comes out as part of it)")


## Engine-free: the rules on stand-ins.
func _check_rules() -> void:
	print("-- rules")
	var rules = R.new()
	rules.setup(_data.hangars)
	rules.discover(B)
	var in_sq := Soldier.new("Reyes", SQUARE_CENTRE)
	var out_sq := Soldier.new("Park", OUTSIDE)
	_check(rules.board_blocker(SQUARE_CENTRE, R.PLAYER_CREW) != "", "no boarding with no ship down")
	_check(rules.extract_blocker(R.PLAYER_CREW, [in_sq]) != "", "no extracting with no ship down")
	# A rival's ship down at A: the squad can neither board it nor leave on it.
	rules.states[A].known_by[R.MERC_CREW_BASE] = true
	rules.call_ship(A, R.MERC_CREW_BASE, 1)
	rules.start_round(4)
	_check(rules.state_of(A) == R.State.LANDED, "a rival crew's ship lands at A")
	_check(rules.board_blocker(SQUARE_CENTRE, R.PLAYER_CREW) != "", "the squad cannot board a rival's ship")
	_check(rules.extract_blocker(R.PLAYER_CREW, [in_sq]) != "",
		"nor extract on it, even standing in its square")
	# Our own ship, called but still inbound.
	var ours = R.new()
	ours.setup(_data.hangars)
	ours.call_ship(A, R.PLAYER_CREW, 1)
	_check(ours.extract_blocker(R.PLAYER_CREW, [in_sq]) != "", "no extracting while our ship is inbound")
	ours.start_round(4)
	_check(ours.board_blocker(SQUARE_CENTRE, R.PLAYER_CREW) == "", "board from our square once it is down")
	_check(ours.board_blocker(OUTSIDE, R.PLAYER_CREW) != "", "but not from outside it")
	_check(ours.extract_blocker(R.PLAYER_CREW, [out_sq]) != "", "nobody aboard or in the square: no extract")
	_check(ours.extract_blocker(R.PLAYER_CREW, [in_sq, out_sq]) == "",
		"one of ours in the square: extract — asked of the crew, wherever the asker is")
	var dead_in := Soldier.new("Vance", SQUARE_CENTRE, LIFE.DEAD)
	_check(ours.extract_blocker(R.PLAYER_CREW, [dead_in, out_sq]) != "", "a corpse in the square is not enough")
	var downed_in := Soldier.new("Ito", SQUARE_CENTRE, LIFE.DOWNED)
	_check(ours.extract_blocker(R.PLAYER_CREW, [downed_in]) == "", "a downed soldier in the square is")
	var boarded := Soldier.new("Okafor", SQUARE_CENTRE)
	ours.board(A, [boarded])
	boarded.grid_pos = Vector3i(-50, 0, -50)  # off the board
	_check(ours.aboard_for(R.PLAYER_CREW) == [boarded], "the boarded are recorded on the ship")
	_check(ours.extract_blocker(R.PLAYER_CREW, [out_sq]) == "", "somebody aboard: extract, square empty or not")
	# The window runs out with them aboard: they still go.
	var due: Array = ours.departures_due(8)
	_check(due.has(A), "the ship's window runs out at the end of round 8")
	var split: Dictionary = ours.split_passengers(A, [out_sq])
	_check(split["extracted"] == [boarded] and split["lost"] == [out_sq],
		"the aboard leave with it however it goes; the rest are lost")
	ours.resolve_departure(A, 8, true)
	_check(ours.states[A].aboard.is_empty(), "the passenger list clears with the departure")


func _land_ours(caller) -> void:
	_em.begin_mission(_data)
	_tm.turn_number = 1
	_tm.pool.clear()
	_em.call_ship(caller)
	for turn in [2, 3, 4]:
		_tm.turn_number = turn
		_em._on_turn_started(turn)


func _check_board_and_extract() -> void:
	print("-- board, then extract from outside the square")
	_ended.clear()
	_tm.mission_over = false
	var caller = await _spawn(PLAYER, SQUARE_CENTRE)
	var carrier = await _spawn(PLAYER, SQUARE_CENTRE + Vector3i(-1, 0, -1))
	var casualty = await _spawn(PLAYER, SQUARE_CENTRE + Vector3i(-1, 0, 0))
	var holder = await _spawn(PLAYER, OUTSIDE)
	var raider = await _spawn(MERC, Vector3i(10, 0, 2))
	await _land_ours(caller)
	_check(_em.rules.state_of(A) == R.State.LANDED, "our ship is down at A")
	casualty.take_damage(9999)
	_check(casualty.life_state == LIFE.DOWNED, "a squadmate is downed in the bay")
	carrier.pick_up(casualty)
	_check(_em.board_hangar_for(holder) < 0, "the soldier outside the square cannot board")
	_check(_em.board_hangar_for(carrier) == A, "the carrier in the square can")
	var tile: Vector3i = carrier.grid_pos
	_check(_em.board(carrier), "the carrier boards with the casualty")
	_check(carrier.aboard and casualty.aboard, "both are aboard")
	_check(not carrier.is_in_group("units") and not carrier.is_in_group("player_units")
		and not casualty.is_in_group("units"), "out of every group the AI, the pool and the end checks read")
	_check(carrier.is_in_group(_em.ABOARD_GROUP), "and in the aboard group")
	_check(_grid.get_tile(tile).occupant != carrier, "the tile is free")
	_check(not carrier.visible and not casualty.visible, "and they are gone from view")
	_check(not raider.hostiles().has(carrier) and not raider.hostiles().has(casualty),
		"no hostile can target them now")
	_check(_em.board_hangar_for(carrier) < 0, "boarding twice is refused")
	_check(_em.extract_blocker(holder) == "", "the soldier OUTSIDE the square may give the word")
	_check(_em.extract(holder), "extract")
	_check(_tm.mission_over and _ended.size() == 1, "the mission ends at once")
	if _ended.size() == 1:
		var result = _ended[0]
		_check(result.outcome == 0, "EXTRACTED")
		_check(result.extracted_units.has(carrier) and result.extracted_units.has(casualty)
			and result.extracted_units.has(caller), "the aboard and the soldier in the square go home")
		_check(result.lost_units == [holder], "the one who gave the word from outside stays behind")
	_check(_em.rules.state_of(A) != R.State.LANDED, "the ship has gone")
	_tm.mission_over = false
	_em.reset()
	await _free([caller, carrier, casualty, holder, raider])


func _check_squad_gone() -> void:
	print("-- nobody standing on the deck, somebody aboard")
	_ended.clear()
	_tm.mission_over = false
	var first = await _spawn(PLAYER, SQUARE_CENTRE)
	var last = await _spawn(PLAYER, OUTSIDE)
	await _land_ours(first)
	_em.board(first)
	last.take_damage(9999)
	_check(last.life_state == LIFE.DOWNED, "the last soldier on the deck goes down")
	_check(_tm._check_end_conditions(), "the end check ends the mission")
	if _ended.size() == 1:
		_check(_ended[0].outcome == 0 and _ended[0].extracted_units == [first] and _ended[0].lost_units == [last],
			"as an EXTRACTION of the one aboard, not a wipe")
	else:
		_check(false, "as an EXTRACTION of the one aboard, not a wipe")
	_tm.mission_over = false
	_em.reset()
	await _free([first, last])
	# And the old rule where nobody boarded.
	_ended.clear()
	var lone = await _spawn(PLAYER, SQUARE_CENTRE)
	await _land_ours(lone)
	lone.take_damage(9999)
	_tm._check_end_conditions()
	_check(_ended.size() == 1 and _ended[0].outcome == 1, "nobody aboard and nobody standing is still a wipe")
	_tm.mission_over = false
	_em.reset()
	await _free([lone])


func _check_ship_blocks_sight() -> void:
	print("-- the landed ship blocks sight across its space")
	var north = await _spawn(PLAYER, Vector3i(3, 0, 2))
	var south = await _spawn(MERC, Vector3i(3, 0, 10))
	var left = await _spawn(PLAYER, Vector3i(7, 0, 3))
	var right = await _spawn(MERC, Vector3i(7, 0, 9))
	await physics_frame
	_check(_grid.has_line_of_sight(north, south), "across the empty pad: clear")
	await _land_ours(north)
	await physics_frame
	await physics_frame
	_check(_em.ship_blocker(A) != null, "a blocker stands on the pad while the ship is down")
	_check(not _grid.has_line_of_sight(north, south), "across the landed ship: blocked")
	_check(_grid.has_line_of_sight(left, right), "across the square in front of it: still clear")
	var gun = _em.door_gun(A)
	var in_square = await _spawn(MERC, SQUARE_CENTRE + Vector3i(-1, 0, 1))
	await physics_frame
	_check(gun != null and _grid.has_line_of_sight(gun, in_square) and _grid.has_line_of_sight(in_square, gun),
		"the door gun on the hull still sees the square, and can be seen")
	var raised: bool = _grid.has_clear_line(north, north.global_position + Vector3(0, 1.2, 0),
		south.global_position + Vector3(0, 0.5, 0))
	_check(not raised, "and light rays (has_clear_line) are blocked too")
	# The window runs out: it leaves empty, and the blocker goes with it.
	_tm.turn_number = 8
	await _em._on_round_ending(8)
	await physics_frame
	await physics_frame
	_check(_em.ship_blocker(A) == null and _grid.has_line_of_sight(north, south),
		"it leaves, and so does the blocker")
	_em.reset()
	await _free([north, south, left, right, in_square])


func _check_wrecks() -> void:
	print("-- wrecks")
	var rows := PackedStringArray([
		"#########",
		"#.......#",
		"#.......#",
		"#.......#",
		"#########",
		"",
		"[wrecks]",
		"3,1 2,3",
	])
	var ascii = load("res://scripts/map_ascii.gd")
	var deck = ascii.parse(rows)
	_check(deck.wrecks == [Rect2i(3, 1, 2, 3)], "[wrecks] parses into MapData.wrecks")
	_check(deck.get_cell(Vector3i(4, 0, 2)).terrain == MD.Terrain.OBSTACLE and not deck.is_walkable(Vector3i(3, 0, 1)),
		"its cells are impassable")
	_check(ascii.to_text(deck).split("\n") == rows, "and round-trip")
	# Built on the live deck, off the pad: a wreck at (2,10)-(3,10).
	var west = await _spawn(PLAYER, Vector3i(1, 0, 10))
	var east = await _spawn(MERC, Vector3i(5, 0, 10))
	await physics_frame
	_check(_grid.has_line_of_sight(west, east), "before the wreck: clear")
	_map._add_wreck(Rect2i(2, 10, 2, 1))
	await physics_frame
	await physics_frame
	_check(not _grid.has_line_of_sight(west, east), "a wreck blocks sight like a bulkhead")
	var edge = _grid.cover_edge(Vector3i(4, 0, 10), MD.Side.WEST)
	_check(edge != null and edge.type == MD.Cover.HEAVY and edge.indestructible, "and gives heavy cover beside it")
	if edge != null:
		_grid.damage_cover_edge(Vector3i(4, 0, 10), MD.Side.WEST, 9999)
		_check(edge.type == MD.Cover.HEAVY, "that no amount of fire wears down")
	await _free([west, east])


func _check_weapon_switch() -> void:
	print("-- switching weapons")
	var s = await _spawn(PLAYER, Vector3i(9, 0, 2))
	var body = await _spawn(PLAYER, Vector3i(10, 0, 2))
	s.ap = 10
	var primary_ammo: int = s.ammo
	var pistol_ammo: int = s.stowed_ammo
	_check(not s.stats.sidearm_drawn and s.switch_weapon_blocker() == "", "primary in hand; a switch is allowed")
	s.try_switch_weapon()
	_check(s.ap == 9, "switching costs 1 AP (%d left)" % s.ap)
	_check(s.stats.sidearm_drawn and s.active_weapon() == s.stats.sidearm, "the pistol is in hand")
	_check(s.ammo == pistol_ammo and s.stowed_ammo == primary_ammo, "each gun keeps its own magazine")
	body.take_damage(9999)
	var before: int = s.ap
	s.pick_up(body)
	_check(s.ap == before and s.stats.sidearm_drawn and s.ammo == pistol_ammo,
		"lifting a body with the pistol already out changes nothing about the gun")
	_check(s.switch_weapon_blocker() != "", "no switching while carrying")
	s.try_switch_weapon()
	_check(s.ap == before and s.stats.sidearm_drawn, "a refused switch costs nothing")
	s.drop_carried()
	_check(s.stats.sidearm_drawn and s.ammo == pistol_ammo, "putting the body down keeps the gun they chose")
	s.try_switch_weapon()
	_check(not s.stats.sidearm_drawn and s.ammo == primary_ammo, "and switching back hands the primary over")
	# The other way round: primary chosen, carrying forces the pistol, dropping returns it.
	s.pick_up(body)
	_check(s.stats.sidearm_drawn and s.ammo == pistol_ammo, "carrying draws the pistol")
	s.drop_carried()
	_check(not s.stats.sidearm_drawn and s.ammo == primary_ammo, "and putting the body down holsters it again")
	await _free([s, body])


func _spawn(scene_path: String, at: Vector3i):
	var unit = load(scene_path).instantiate()
	unit.position = _grid.grid_to_world(at)
	root.add_child(unit)
	await process_frame
	return unit


func _free(units: Array) -> void:
	for unit in units:
		if is_instance_valid(unit):
			var t = _grid.get_tile(unit.grid_pos)
			if t and t.occupant == unit:
				_grid.set_occupant(unit.grid_pos, null)
			unit.remove_from_group("units")
			unit.remove_from_group("player_units")
			unit.remove_from_group(_em.ABOARD_GROUP)
			unit.queue_free()
	await process_frame


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
