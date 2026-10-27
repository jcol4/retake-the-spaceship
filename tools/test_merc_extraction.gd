extends SceneTree
## Extraction plan Phase 8: rival merc crews extract on the player's rules
## (GDD §11.10, §7.2–7.4).
##
##   godot --headless --path . --script res://tools/test_merc_extraction.gd
##
## Covers:
##   - MercJob (engine-free): deterministic rolls, the job kinds, each leave
##     trigger on its own, the rival-call hurry, the dust-off rule;
##   - ExtractionRules per crew: a merc crew knows only hangars it has walked
##     into, one lift retires the crew, the departing crew rides the snapshot;
##   - the plan's three cases on a real deck through the real ExtractionManager:
##       a merc squad with its job done calls and extracts,
##       its claim blocks the player's call on that hangar,
##       killing the squad before landing frees the hangar after departure;
##   - what the player sees: a positionless radio line, no hangar named and no
##     hull drawn until the hangar is discovered, the mission never ending on a
##     rival lift, a player standing in the rival square left alone, the rival
##     lift in the result (wire round trip) and in the campaign debrief notes;
##   - mercs loot (the crate tile counts once, the objective is left alone by a
##     looting crew and taken first by a contesting one), a carried-off Retrieve
##     item reads as flown out, a corpse keeps its pack;
##   - discovery by stepping in, and the door-gun avoidance cost;
##   - generated decks: about `merc_squad_chance` of them carry one crew, in one
##     ordinary room away from the insertion and the aliens, appended last on
##     the RNG so the rest of every deck is unchanged.
##
## Runs on maps/merc_extraction_deck.txt, driving ExtractionManager's turn hooks
## and each merc's `take_turn` by hand (no TurnManager draw loop), so every step
## is deterministic.

const PLAYER := "res://scenes/player_unit.tscn"
const MERC := "res://scenes/merc_unit.tscn"
const DECK := "res://maps/merc_extraction_deck.txt"

## The deck: hangar A (insertion) pad (3,6) ramp E; hangar B pad (36,6) ramp W,
## square x 32-34, z 5-7; the cargo room below the corridor.
const A := 0
const B := 1
const B_SQUARE_1 := Vector3i(33, 0, 6)
const B_SQUARE_2 := Vector3i(33, 0, 5)
const B_SQUARE_3 := Vector3i(32, 0, 7)
const B_BAY_OFF_SQUARE := Vector3i(30, 0, 9)
const CARGO := Vector3i(20, 0, 18)
const CORRIDOR := Vector3i(20, 0, 6)
const CRATE_LOOT := Vector3i(25, 0, 14)   # sealed_rations fusion_cell
const BESIDE_CRATE_LOOT := Vector3i(25, 0, 15)
const CRATE_CONTEST := Vector3i(26, 0, 17)  # scrap_electronics
const BESIDE_CRATE_CONTEST := Vector3i(25, 0, 17)
const A_SQUARE := Vector3i(6, 0, 6)

var _failures := 0
var _grid: Node
var _em: Node
var _tm: Node
var _om: Node
var _lm: Node
var _map: Node
var _data
var LIFE
var R  # ExtractionRules
var J  # MercJob
var MR  # MissionResult
var F  # Faction
var _ended: Array = []
var _notices: Array[String] = []
var _calls: Array = []
var _serial := 0


func _initialize() -> void:
	_grid = root.get_node_or_null("GridManager")
	_em = root.get_node_or_null("ExtractionManager")
	_tm = root.get_node_or_null("TurnManager")
	_om = root.get_node_or_null("ObjectiveManager")
	_lm = root.get_node_or_null("LootManager")
	LIFE = load("res://scripts/unit.gd").LifeState
	R = load("res://scripts/extraction_rules.gd")
	J = load("res://scripts/merc_job.gd")
	MR = load("res://scripts/mission_result.gd")
	F = load("res://scripts/faction.gd")

	_check_job_rules()
	_check_rules_per_crew()
	_check_generator()
	_check_result_and_debrief()

	_map = load("res://scenes/test_map.tscn").instantiate()
	_map.layout_path = DECK
	root.add_child(_map)
	await process_frame
	await physics_frame
	await physics_frame
	_data = _map.data
	seed(8080)
	_tm.clear_out_mode = false
	_tm.mission_over = false
	_tm.mission_ended.connect(func(result) -> void: _ended.append(result))
	_em.notice.connect(func(text: String, _radio: bool) -> void: _notices.append(text))
	_em.ship_called.connect(func(crew: int) -> void: _calls.append(crew))

	_check(_data.hangars.size() == 2 and _data.hangars[B].square.has(B_SQUARE_1),
		"the merc deck has hangars A and B with B's square where expected")
	await _check_lift()
	await _check_killed_before_landing()
	await _check_looting()
	await _check_contest()
	await _check_discovery_by_stepping()
	await _check_door_gun_avoidance()

	_em.reset()
	_om.reset()
	_tm.pool.clear()
	print("")
	if _failures == 0:
		print("merc_extraction: ALL CHECKS PASSED")
		quit(0)
	else:
		print("merc_extraction: %d CHECK(S) FAILED" % _failures)
		quit(1)


# --- MercJob ------------------------------------------------------------------


func _check_job_rules() -> void:
	print("-- MercJob: rolls, kinds, leave triggers")
	var a = J.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	a.setup(1, "s", 3, rng)
	var b = J.new()
	rng.seed = 77
	b.setup(1, "s", 3, rng)
	_check(a.loot_goal == b.loot_goal and a.leave_round == b.leave_round and a._contest_roll == b._contest_roll,
		"the same seed rolls the same job (co-op / replay)")
	_check(a.loot_goal >= J.LOOT_GOAL_MIN and a.loot_goal <= J.LOOT_GOAL_MAX
		and a.leave_round >= J.LEAVE_ROUND_MIN and a.leave_round <= J.LEAVE_ROUND_MAX,
		"goal %d and leave round %d inside their bands" % [a.loot_goal, a.leave_round])
	var contest = J.new()
	contest.setup(1, "s", 3)
	contest._contest_roll = 0.0
	contest.resolve_kind(true)
	_check(contest.kind == J.Kind.CONTEST, "a low roll on a Retrieve deck contests the item")
	contest.resolve_kind(false)
	_check(contest.kind == J.Kind.CONTEST, "resolve_kind settles once")
	var loot = J.new()
	loot.setup(1, "s", 3)
	loot._contest_roll = 0.0
	loot.resolve_kind(false)
	_check(loot.kind == J.Kind.LOOT, "no Retrieve contract: a looting job whatever the roll")
	contest.abandon_contest()
	_check(contest.kind == J.Kind.LOOT, "an out-of-reach item falls back to looting")

	var j = J.new()
	j.setup(1, "s", 4)
	j.loot_goal = 2
	j.leave_round = 20
	_check(j.leave_reason_for(5, 4, 8, false) == "", "fresh crew, room in the packs, early: keep working")
	j.record_take(Vector3i(1, 0, 1))
	j.record_take(Vector3i(1, 0, 1))
	_check(j.leave_reason_for(5, 4, 8, false) == "", "two items from one crate are one container")
	j.record_take(Vector3i(2, 0, 1))
	_check(j.leave_reason_for(5, 4, 8, false) == "job done", "two containers: job done")
	var k = J.new()
	k.setup(1, "s", 4)
	k.leave_round = 20
	_check(k.leave_reason_for(5, 4, 0, false) == "packs full", "every pack full: leave")
	_check(k.leave_reason_for(5, 3, 3, false) == "", "one of four down: stay")
	_check(k.leave_reason_for(5, 2, 3, false) == "casualties", "half the crew down: leave")
	_check(k.leave_reason_for(20, 4, 8, false) == "out of time", "the round limit: leave")
	var c = J.new()
	c.setup(1, "s", 3)
	c.kind = J.Kind.CONTEST
	c.leave_round = 30
	c.loot_goal = 0
	_check(c.leave_reason_for(5, 3, 3, false) == "" and c.leave_reason_for(5, 3, 3, true) == "job done",
		"a contesting crew is done when it holds the item, not on a loot count")
	_check(k.update(20, 4, 8, false) and k.is_extracting() and k.leave_reason == "out of time",
		"update moves WORKING -> EXTRACTING with the reason")
	_check(not k.update(21, 4, 8, false), "and only once")
	var h = J.new()
	h.setup(1, "s", 3)
	h.leave_round = 22
	h.hear_rival_call(10)
	_check(h.leave_round == 10 + J.HURRY_ROUNDS, "a rival call-in brings the leave round forward")
	h.hear_rival_call(2)
	h.hear_rival_call(15)
	_check(h.leave_round == 2 + J.HURRY_ROUNDS, "never pushes it back")
	_check(J.should_dust_off(3, 3, 0), "dust-off at once with everyone aboard")
	_check(not J.should_dust_off(2, 3, 0) and not J.should_dust_off(2, 3, J.DUST_OFF_PATIENCE_ROUNDS - 1),
		"most aboard: wait for the others a while")
	_check(J.should_dust_off(2, 3, J.DUST_OFF_PATIENCE_ROUNDS), "then go without them")
	_check(not J.should_dust_off(1, 3, 10) and not J.should_dust_off(0, 0, 10),
		"never with a minority aboard, or nobody")
	_check(j.visit_room(4) and not j.visit_room(4) and j.has_visited(4), "rooms are visited once")


# --- ExtractionRules, per crew ----------------------------------------------------


func _check_rules_per_crew() -> void:
	print("-- ExtractionRules: per-crew discovery, retirement, the snapshot")
	var data = load("res://scripts/map_ascii.gd").load_file(DECK)
	var rules = R.new()
	rules.setup(data.hangars)
	var merc: int = R.MERC_CREW_BASE
	var other: int = R.MERC_CREW_BASE + 1
	_check(not rules.crew_knows(B, merc) and rules.call_blocker(B, merc) == "hangar not discovered",
		"a merc crew does not know B until it has been there")
	_check(rules.discover_room_for(data.hangars[B].room_index, merc) == B, "entering B's room teaches it B")
	_check(rules.discover_room_for(data.hangars[B].room_index, merc) == -1, "once")
	_check(rules.crew_knows(B, merc) and not rules.crew_knows(B, other) and not rules.is_discovered(B),
		"that crew only — not the other merc crew, not the player")
	_check(rules.known_hangars(merc) == [B], "known_hangars lists it")
	_check(rules.call_ship(B, merc, 3), "the crew calls B")
	_check(rules.call_blocker(B, R.PLAYER_CREW) != "", "the player cannot call B (and does not know it)")
	rules.discover(B)
	_check(rules.call_blocker(B, R.PLAYER_CREW) == "another crew has claimed this hangar",
		"discovered, B is still the mercs': first call claims it")
	rules.start_round(6)
	var snap: Array = rules.snapshot(B)
	rules.resolve_departure(B, 8, true)
	_check(rules.is_retired(merc) and rules.states[B].last_crew == merc, "a lift with somebody aboard retires the crew")
	rules.discover_room_for(data.hangars[A].room_index, merc)
	_check(rules.call_blocker(A, merc) == "this crew has already flown out", "one lift per crew: no second call")
	_check(rules.call_blocker(B, R.PLAYER_CREW) == "", "B is free again for the player")
	var client = R.new()
	client.setup(data.hangars)
	client.apply_snapshot(B, snap)
	client.apply_snapshot(B, rules.snapshot(B))
	_check(client.states[B].last_crew == merc, "the departing crew rides the snapshot to a client")
	client.apply_snapshot(B, snap.slice(0, 5))
	_check(client.states[B].last_crew == R.NO_CREW, "an old 5-field snapshot still applies")
	var empty = R.new()
	empty.setup(data.hangars)
	empty.discover_room_for(data.hangars[B].room_index, merc)
	empty.call_ship(B, merc, 1)
	empty.start_round(4)
	empty.resolve_departure(B, 8, false)
	_check(not empty.is_retired(merc) and empty.state_of(B) == R.State.COOLDOWN,
		"an empty departure does not end the crew's run; the pad cools down")


# --- Generator --------------------------------------------------------------------


func _check_generator() -> void:
	print("-- generated decks carry a merc crew sometimes")
	var Gen = load("res://scripts/map_generator.gd")
	var MD = load("res://scripts/map_data.gd")
	var with_mercs := 0
	var bad_place := 0
	var bad_size := 0
	var changed := 0
	var nondeterministic := 0
	var decks := 120
	for s in range(1, decks + 1):
		var data = Gen.generate(s)
		var mercs: Array = data.spawns(MD.Spawn.MERC)
		if not mercs.is_empty():
			with_mercs += 1
			if mercs.size() != Gen.Config.new().merc_squad_size:
				bad_size += 1
			var room: int = data.room_index_at(mercs[0])
			var ins = data.insertion_hangar()
			var near_insertion: bool = room == ins.room_index
			for link in data.room_links:
				if (link[0] == ins.room_index and link[1] == room) or (link[1] == ins.room_index and link[0] == room):
					near_insertion = true
			var in_hangar := false
			for h in data.hangars:
				if h.room_index == room:
					in_hangar = true
			var with_aliens := false
			for e in data.spawns(MD.Spawn.ENEMY):
				if data.room_index_at(e) == room:
					with_aliens = true
			var one_room := true
			for m in mercs:
				if data.room_index_at(m) != room or not data.is_passable(m):
					one_room = false
			if near_insertion or in_hangar or with_aliens or not one_room or data.corridors.has(room):
				bad_place += 1
		var again = Gen.generate(s)
		if again.spawns(MD.Spawn.MERC) != mercs:
			nondeterministic += 1
		if s <= 30:
			var cfg = Gen.Config.new()
			cfg.merc_squad_chance = 0.0
			var plain = Gen.generate(s, cfg)
			if not plain.spawns(MD.Spawn.MERC).is_empty() \
					or plain.spawns(MD.Spawn.ENEMY) != data.spawns(MD.Spawn.ENEMY) \
					or plain.spawns(MD.Spawn.PLAYER) != data.spawns(MD.Spawn.PLAYER) \
					or plain.containers.size() != data.containers.size():
				changed += 1
	var share := float(with_mercs) / decks
	print("    %d of %d decks carry a crew (%.0f%%)" % [with_mercs, decks, share * 100.0])
	_check(share > 0.25 and share < 0.55, "about merc_squad_chance (0.4) of decks carry a crew")
	_check(bad_size == 0, "a crew is merc_squad_size strong")
	_check(bad_place == 0, "in one ordinary room: not a hangar, a corridor, the insertion's neighbourhood or an alien room")
	_check(nondeterministic == 0, "the same seed places the same crew")
	_check(changed == 0, "chance 0 gives the same deck minus the crew (mercs are the last draw)")


# --- Result and debrief -----------------------------------------------------------


func _check_result_and_debrief() -> void:
	print("-- rival lifts in the result and the debrief")
	var r = MR.new(MR.Outcome.EXTRACTED)
	r.rivals = [{"crew": 1, "aboard": 2, "stranded": 1, "items": ["crew_tags", "fusion_cell"], "turn": 18}]
	var lines: Array = r.rival_lines()
	_check(lines.size() == 1 and "round 18" in lines[0] and "2 aboard" in lines[0] and "2 item(s)" in lines[0]
		and "1 stranded" in lines[0], "one line per lift: %s" % (lines[0] if not lines.is_empty() else "-"))
	var wire = MR.from_dict(r.to_dict(), root)
	_check(wire.rivals == r.rivals, "rivals survive the wire")
	var CS = load("res://scripts/campaign/campaign_state.gd")
	var state = CS.new_campaign(4)
	var summary: Dictionary = state.apply_report({"outcome": MR.Outcome.WIPED, "soldiers": [],
		"rival_notes": lines})
	_check((summary["notes"] as Array).has(lines[0]), "the debrief notes carry it")


# --- On the deck ----------------------------------------------------------------------


## Plan case 1 and 2: a crew with its job done calls B, the claim blocks the
## player, the ship lands (hidden until the player knows B), the crew boards and
## leaves; the mission goes on.
func _check_lift() -> void:
	print("-- a merc crew with its job done calls, holds and extracts")
	_notices.clear()
	_calls.clear()
	var m1 = await _spawn_merc(B_SQUARE_1, "lift")
	var m2 = await _spawn_merc(B_SQUARE_2, "lift")
	var straggler = await _spawn_merc(CARGO, "lift")
	m2.add_item(load("res://scripts/item_presets.gd").make("crew_tags"))
	var c = load("res://scripts/contract.gd").new()
	c.type = c.Type.RETRIEVE
	c.item_code = "data_core"
	_om.contract = c
	m1.add_item(load("res://scripts/item_presets.gd").make("data_core"))
	_em.begin_mission(_data)
	_tm.turn_number = 1
	_tm.pool.clear()
	var crew: int = _em.crew_of(m1)
	var job = _em.merc_job(crew)
	_check(crew >= R.MERC_CREW_BASE and _em.crew_of(straggler) == crew and job != null and m1.job == job,
		"the squad is one merc crew (%d) sharing one job" % crew)
	_check(_em.rules.crew_knows(B, crew) and not _em.rules.crew_knows(A, crew),
		"it knows the hangar it spawned in, not the player's")
	_check(not _em.rules.is_discovered(B), "B is not known to the player")
	job.resolve_kind(false)
	for i in job.loot_goal:
		job.record_take(Vector3i(100 + i, 0, 0))
	await _activate(m1)
	_check(job.is_extracting() and job.leave_reason == "job done", "job done: the crew decides to leave")
	_check(_em.claim_of(crew) == B and _em.rules.state_of(B) == R.State.CALLED, "and calls the ship to B")
	_check(_calls == [crew], "the radio notice went out (ship_called) for the merc crew")
	_check(_notices.has("RADIO: Another crew has called a ship."), "the player hears a positionless call")
	_check(not _any_notice_has("Hangar B"), "nothing names B")
	_check(m1.ap < m1.ap_pool(), "calling cost AP")

	# The player cannot take B from them.
	var player = await _spawn(PLAYER, B_BAY_OFF_SQUARE)
	_check(_em.callable_hangar_for(player) == -1, "a player soldier in B's bay cannot call (claimed, unknown)")
	_em.rules.discover(B)
	_check(_em.rules.call_blocker(B, R.PLAYER_CREW) == "another crew has claimed this hangar"
		and _em.callable_hangar_for(player) == -1, "nor once B is discovered: the merc claim blocks it")
	_em.rules.states[B].discovered = false
	_em.rules.states[B].state = R.State.CALLED
	await _free([player])

	for turn in [2, 3]:
		_tm.turn_number = turn
		_em._on_turn_started(turn)
	_tm.turn_number = 4
	_em._on_turn_started(4)
	_check(_em.rules.state_of(B) == R.State.LANDED, "the ship lands on round 4")
	var gun = _em.door_gun(B)
	_check(gun != null and gun.faction == F.Id.RIVAL_MERCS and _em.crew_of(gun) == R.NO_CREW,
		"with a merc door gun aboard, in no crew")
	var ship = _em._dropships.get(B)
	_check(ship != null and not ship.visible, "the hull is not drawn over a hangar the player has not found")
	_check(not _any_notice_has("Hangar B"), "still nothing names B")
	_em.rules.discover(B)
	_em._broadcast(B, _em.rules.state_of(B), true)
	_check(ship != null and ship.visible, "discovering B shows the rival ship")

	await _activate(m1)
	await _activate(m2)
	_check(_em.rules.states[B].dust_off_requested == false,
		"2 of 3 aboard on the landing round: they wait for the third")
	_tm.turn_number = 4 + J.DUST_OFF_PATIENCE_ROUNDS
	await _activate(m2)
	_check(_em.rules.states[B].dust_off_requested, "after %d rounds down they signal dust-off" % J.DUST_OFF_PATIENCE_ROUNDS)

	var watcher = await _spawn(PLAYER, B_SQUARE_3)
	var turn: int = _tm.turn_number
	await _em._on_round_ending(turn)
	_check(_ended.is_empty() and not _tm.mission_over, "a rival lift never ends the player's mission")
	_check(not m1.is_in_group("units") and not m2.is_in_group("units"), "the two aboard left the board")
	_check(is_instance_valid(straggler) and straggler.is_in_group("units") and straggler.job.phase == J.Phase.DEPARTED,
		"the straggler is stranded on the deck, his crew's run over")
	_check(not straggler._job_active(), "and goes back to the plain merc behaviour")
	_check(_em.rules.is_retired(crew) and _em.rules.call_blocker(A, crew) != "", "the crew can never call again")
	_check(_em.rules.state_of(B) == R.State.DISCOVERED and _em.rules.states[B].claimed_by == R.NO_CREW,
		"B is free again")
	_check(_em.door_gun(B) == null, "the merc gunner went with the ship")
	_check(watcher.visible, "a player soldier standing in the rival square is not 'boarded'")
	_check(_notices.has("The rival ship lifts off from Hangar B."), "the lift is named once B is known")
	var report: Array = _em.rival_report()
	_check(report.size() == 1 and int(report[0]["aboard"]) == 2 and int(report[0]["stranded"]) == 1
		and (report[0]["items"] as Array).has("crew_tags") and (report[0]["items"] as Array).has("data_core"),
		"the rival report: 2 aboard, 1 stranded, their packs (%s)" % [report])
	_check(_om.carried_off and "flown out by a rival crew" in _om.status_text(),
		"the Retrieve item went with them: %s" % _om.status_text())
	_tm.end_mission(MR.new(MR.Outcome.WIPED))
	_check(not _ended.is_empty() and (_ended[-1].rivals as Array).size() == 1,
		"end_mission attaches the rival lifts to whatever result ends the mission")
	_tm.mission_over = false
	_ended.clear()
	_om.reset()
	await process_frame
	await _free([straggler, watcher])
	_em.reset()


## Plan case 3: the crew dies before its ship lands; the ship sits out its window
## empty, the pad cools down, and the hangar is the player's to call.
func _check_killed_before_landing() -> void:
	print("-- killing the squad before landing frees the hangar after departure")
	var m1 = await _spawn_merc(B_SQUARE_1, "doomed")
	var m2 = await _spawn_merc(B_SQUARE_2, "doomed")
	m1.add_item(load("res://scripts/item_presets.gd").make("fusion_cell"))
	_em.begin_mission(_data)
	_tm.turn_number = 1
	var crew: int = _em.crew_of(m1)
	_check(_em.call_ship(m1), "the crew calls B")
	m1.die()
	m2.die()
	_check(m1.life_state == LIFE.DEAD and m1.leaves_body(), "mercs die outright and leave a body")
	for turn in [2, 3, 4]:
		_tm.turn_number = turn
		_em._on_turn_started(turn)
	_check(_em.rules.state_of(B) == R.State.LANDED, "the ship still lands on schedule")
	_check(_em.rules.departures_due(7).is_empty() and _em.rules.departures_due(8) == [B],
		"and waits out its 5 rounds (leaves at the end of round 8)")
	_tm.turn_number = 8
	await _em._on_round_ending(8)
	_check(_em.rules.state_of(B) == R.State.COOLDOWN and _em.rules.states[B].ready_round == 13,
		"nobody aboard: COOLDOWN until round 13")
	_check(_em.rival_report().is_empty() and not _em.rules.is_retired(crew),
		"no rival lift recorded, the (dead) crew not retired")
	_check(_ended.is_empty() and not _tm.mission_over, "the player's mission goes on")
	_tm.turn_number = 13
	_em._on_turn_started(13)
	_em.rules.discover(B)
	_check(_em.rules.call_blocker(B, R.PLAYER_CREW) == "", "after the cooldown the player can call B")
	var looter = await _spawn(PLAYER, B_SQUARE_3)
	_check(m1.loot_blocker(looter) == "" and m1.has_item_code("fusion_cell"),
		"the corpse keeps its pack for the player to loot (%s)" % [m1.inventory_codes])
	await _free([m1, m2, looter])
	_em.reset()


## Mercs loot through LootManager.take; a looting crew leaves the objective, the
## crate counts once, and the finished job turns the crew for home.
func _check_looting() -> void:
	print("-- mercs loot")
	var merc = await _spawn_merc(BESIDE_CRATE_LOOT, "looters")
	_em.begin_mission(_data)
	_tm.turn_number = 2
	var c = load("res://scripts/contract.gd").new()
	c.type = c.Type.RETRIEVE
	c.item_code = "data_core"
	_om.contract = c
	_lm.put(CRATE_LOOT, "data_core")
	var crate = _lm.container_at(CRATE_LOOT)
	_check(crate != null and crate.items.size() == 3, "the crate holds two valuables and the objective")
	var job = merc.job
	job.resolve_kind(false)
	job.loot_goal = 1
	job.leave_round = 99
	await _activate(merc)
	_check(merc.has_item_code("sealed_rations") and merc.has_item_code("fusion_cell")
		and not merc.has_item_code("data_core"), "the merc took both valuables (%s)" % [merc.inventory_codes])
	_check(crate.items.size() == 1 and crate.items[0].code == "data_core",
		"a looting crew leaves the player's objective in the crate")
	_check(job.looted.has(CRATE_LOOT), "the crate counts toward the job")
	_check(merc.ap <= merc.ap_pool() - 2 * merc.action_cost(load("res://scripts/unit_stats.gd").Action.LOOT),
		"each item cost the player's flat loot price")
	await _activate(merc)
	_check(job.is_extracting() and job.leave_reason == "job done", "job done: the crew heads for a ship")
	_om.reset()
	await _free([merc])
	_em.reset()


## A contesting crew goes for the player's Retrieve item and takes it first.
func _check_contest() -> void:
	print("-- a contesting crew takes the player's item first")
	var merc = await _spawn_merc(BESIDE_CRATE_CONTEST, "rivals")
	_em.begin_mission(_data)
	_tm.turn_number = 2
	var c = load("res://scripts/contract.gd").new()
	c.type = c.Type.RETRIEVE
	c.item_code = "data_core"
	_om.contract = c
	_lm.put(CRATE_CONTEST, "data_core")
	var job = merc.job
	job._contest_roll = 0.0
	job.resolve_kind(true)
	job.leave_round = 99
	_check(job.kind == J.Kind.CONTEST, "the crew is after the item")
	merc.add_item(load("res://scripts/item_presets.gd").make("crew_tags"))
	merc.add_item(load("res://scripts/item_presets.gd").make("crew_tags"))
	merc.add_item(load("res://scripts/item_presets.gd").make("crew_tags"))
	await _activate(merc)
	_check(merc.has_item_code("data_core"), "with one slot left it takes the objective, not the valuable")
	_check(_om.item_holder() == merc and "taken by" in _om.status_text(), "the objective line: %s" % _om.status_text())
	await _activate(merc)
	_check(job.is_extracting() and job.leave_reason == "job done", "holding it, the crew leaves")
	_om.reset()
	await _free([merc])
	_em.reset()


## A crew learns a hangar by stepping into its room, and only then can call it.
func _check_discovery_by_stepping() -> void:
	print("-- mercs discover hangars by walking in")
	var merc = await _spawn_merc(CORRIDOR, "scouts")
	_em.begin_mission(_data)
	var crew: int = merc.crew_id
	_check(not _em.rules.crew_knows(B, crew), "starting in the corridor, the crew knows no hangar")
	merc.relocate_to(B_BAY_OFF_SQUARE)
	_check(_em.callable_hangar_for(merc) == -1, "standing in B's bay without having walked in: cannot call")
	merc.stepped.emit(merc)
	_check(_em.rules.crew_knows(B, crew) and _em.callable_hangar_for(merc) == B, "a step inside teaches it B")
	_check(not _em.rules.is_discovered(B), "the player learns nothing from it")
	_check(merc.job.has_visited(_data.room_index_at(B_BAY_OFF_SQUARE)), "and the room counts as scouted")
	await _free([merc])
	_em.reset()


## A merc's route prices tiles under a hostile ship's gun (Phase 5 note).
func _check_door_gun_avoidance() -> void:
	print("-- mercs route around a hostile door gun's field of fire")
	var soldier = await _spawn(PLAYER, A_SQUARE)
	var merc = await _spawn_merc(CORRIDOR, "wary")
	_em.begin_mission(_data)
	_tm.turn_number = 1
	_check(_em.call_ship(soldier), "the player calls A")
	for turn in [2, 3, 4]:
		_tm.turn_number = turn
		_em._on_turn_started(turn)
	var gun = _em.door_gun(A)
	_check(gun != null and gun.faction == F.Id.CONTRACTORS, "the player's gun is down at A")
	_check(merc._hostile_door_guns().is_empty(), "a crew that has never seen A does not know about it")
	_em.rules.discover_room_for(_data.hangars[A].room_index, merc.crew_id)
	_check(merc._hostile_door_guns() == [gun], "once it knows A, it knows the gun")
	_check(merc._route_penalty(A_SQUARE, [], [gun]) >= merc.DOOR_GUN_AVOID_PENALTY
		and merc._route_penalty(CORRIDOR, [], [gun]) == 0, "tiles under the gun cost extra, others nothing")
	await _free([soldier, merc])
	_em.reset()


# --- Helpers -------------------------------------------------------------------------


func _activate(unit) -> void:
	unit.begin_activation()
	await unit.take_turn()


func _spawn_merc(at: Vector3i, squad: String):
	_serial += 1
	var merc = load(MERC).instantiate()
	merc.squad_id = squad
	merc.name = "TestMerc_%d" % _serial
	merc.position = _grid.grid_to_world(at)
	root.add_child(merc)
	await process_frame
	return merc


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
			unit.remove_from_group("enemy_units")
			unit.queue_free()
	await process_frame


func _any_notice_has(text: String) -> bool:
	for n in _notices:
		if text in n:
			return true
	return false


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
