extends SceneTree
## Extraction plan Phase 6: the Hold-a-terminal and Recover objectives (GDD §7.5).
##
##   godot --headless --path . --script res://tools/test_objectives.gd
##
## Covers:
##   - TerminalRules, engine-free: a console counts only while RUNNING and held;
##     nobody beside it at a round start PAUSES it with the count KEPT; a paused
##     console never counts or resumes on its own; restarting resumes the count;
##     HOLD_ROUNDS held rounds complete it and COMPLETE latches; the noise rounds;
##     the wire snapshot;
##   - the console on the deck: placed by Contract.make on a wall tile that cuts no
##     path, built on every peer by ObjectiveManager, blocks its tile, operated
##     from beside it for 2 AP flat (OPERATE_TERMINAL), loud at radius 8 when it
##     starts and every round it runs, held by any soldier (the other co-op
##     player's included) and not by a downed one, paused when left, the verdict
##     in the MissionResult;
##   - Recover: the VIP spawns DOWNED, holds no tile, is in no crew and not in the
##     pool, does not bleed (plan A10), cannot be revived, is not a finishing
##     target for hostile AI, can be lifted by any soldier (cross-owner), takes the
##     25% redirect while carried, and dies off its bar like anyone downed;
##   - VIP extraction COUNTS — carried aboard, or set down in the square — through
##     the real departure (ExtractionManager turn hooks), alive only; the VIP is
##     kept out of the squad's result lists and the campaign report;
##   - Contract placement over generated decks: every deck supports Hold and
##     Recover; the console is against a wall, in a far room, and leaves every
##     passable tile reachable; offers include both types.

const PLAYER := "res://scenes/player_unit.tscn"
const ENEMY := "res://scenes/enemy_unit.tscn"
const DECK := "res://maps/extraction_test.txt"

## Hangar A of the test deck: the insertion, pad (3,6), ramp east, square (6,6).
const A := 0
const SQUARE_CENTRE := Vector3i(6, 0, 6)
const IN_BAY_A := Vector3i(2, 0, 10)
## UnitStats.Action.OPERATE_TERMINAL / PICK_UP by value (see test_suppression.gd).
const ACTION_OPERATE_TERMINAL := 12
const ACTION_PICK_UP := 8

var _failures := 0
var _grid: Node
var _em: Node
var _om: Node
var _tm: Node
var _map: Node
var _data
var LIFE
var TR  # TerminalRules
var MD  # MapData
var PU  # PlayerUnit
var _contract
var _vip_script
var _ended: Array = []


## A stand-in listener for SecurityNetwork.report_noise: it only needs to be in
## "units", answer `is_downed` and `grid_pos`, and have `hear_noise`.
class NoiseSpy:
	extends Node
	var is_downed := false
	var grid_pos := Vector3i.ZERO
	var heard: Array = []

	func hear_noise(at: Vector3i) -> void:
		heard.append(at)


func _initialize() -> void:
	_grid = root.get_node_or_null("GridManager")
	_em = root.get_node_or_null("ExtractionManager")
	_om = root.get_node_or_null("ObjectiveManager")
	_tm = root.get_node_or_null("TurnManager")
	LIFE = load("res://scripts/unit.gd").LifeState
	TR = load("res://scripts/terminal_rules.gd")
	MD = load("res://scripts/map_data.gd")
	PU = load("res://scripts/player_unit.gd")
	_contract = load("res://scripts/contract.gd")
	_vip_script = load("res://scripts/vip_unit.gd")
	_map = load("res://scenes/test_map.tscn").instantiate()
	_map.layout_path = DECK
	root.add_child(_map)
	await process_frame
	await physics_frame
	await physics_frame
	_data = _map.data
	seed(6060)
	_tm.clear_out_mode = false
	_tm.mission_over = false
	_tm.mission_ended.connect(func(result) -> void: _ended.append(result))

	_check_terminal_rules()
	await _check_terminal_on_deck()
	await _check_vip_body()
	await _check_vip_extraction_counts()
	await _check_vip_full_departure()
	_check_placement()

	_om.reset()
	_em.reset()
	_tm.pool.clear()
	print("")
	if _failures == 0:
		print("objectives: ALL CHECKS PASSED")
		quit(0)
	else:
		print("objectives: %d CHECK(S) FAILED" % _failures)
		quit(1)


# --- Hold: the clock --------------------------------------------------------------


func _check_terminal_rules() -> void:
	print("-- TerminalRules: counting, pausing, resuming")
	var r = TR.new()
	_check(r.state == TR.State.IDLE and r.progress == 0, "a new console is idle at 0")
	_check(r.tick(true) == TR.Tick.NONE and r.progress == 0, "an idle console does not count, even held")
	_check(r.start() and r.state == TR.State.RUNNING, "operating it starts it")
	_check(not r.start() and r.start_blocker() == "already running", "starting a running console is refused")
	_check(r.tick(true) == TR.Tick.COUNTED and r.progress == 1, "held at a round start: counts 1")
	_check(r.tick(true) == TR.Tick.COUNTED and r.progress == 2, "held again: 2")
	_check(r.tick(false) == TR.Tick.INTERRUPTED and r.state == TR.State.PAUSED, "nobody beside it: PAUSED")
	_check(r.progress == 2 and r.interruptions == 1, "the count is KEPT through the pause (2), one interruption")
	_check(r.tick(true) == TR.Tick.NONE and r.progress == 2, "a paused console does not resume on its own, even held")
	_check(r.tick(false) == TR.Tick.NONE and r.progress == 2, "nor lose more of the count")
	_check(r.start_blocker() == "" and r.start(), "it can be restarted")
	var ticks: Array = []
	while r.state == TR.State.RUNNING:
		ticks.append(r.tick(true))
	_check(ticks.size() == TR.HOLD_ROUNDS - 2 and ticks[-1] == TR.Tick.COMPLETED,
		"it resumes from 2 and completes after the remaining %d held rounds" % (TR.HOLD_ROUNDS - 2))
	_check(r.is_complete() and r.progress == TR.HOLD_ROUNDS, "complete at %d/%d" % [r.progress, TR.HOLD_ROUNDS])
	_check(r.tick(false) == TR.Tick.NONE and r.is_complete(), "COMPLETE latches: leaving it changes nothing")
	_check(not r.start() and r.start_blocker() == "already complete", "and it cannot be started again")
	_check(TR.is_loud(TR.Tick.COUNTED) and TR.is_loud(TR.Tick.COMPLETED)
		and not TR.is_loud(TR.Tick.INTERRUPTED) and not TR.is_loud(TR.Tick.NONE),
		"loud on the rounds it runs, quiet on a pause or idle")
	var mirror = TR.new()
	mirror.apply_snapshot(bytes_to_var(var_to_bytes(r.snapshot())))
	_check(mirror.state == r.state and mirror.progress == r.progress and mirror.interruptions == r.interruptions,
		"the wire snapshot round-trips")
	_check(TR.HOLD_ROUNDS == 4 and TR.NOISE_RADIUS == 8, "HOLD_ROUNDS 4, noise radius 8 (plan Phase 6)")
	var fresh = TR.new()
	fresh.start()
	var n := 0
	while fresh.state == TR.State.RUNNING:
		fresh.tick(true)
		n += 1
	_check(n == TR.HOLD_ROUNDS, "an unbroken hold takes exactly HOLD_ROUNDS round starts")


# --- Hold: the console on the deck ------------------------------------------------


func _check_terminal_on_deck() -> void:
	print("-- the console on the deck")
	var c = _contract.make(_contract.Type.HOLD, _data)
	_check(c != null and c.type == _contract.Type.HOLD and c.title() == "Hold: Terminal",
		"extraction_test hosts a Hold contract")
	if c == null:
		return
	var tile: Vector3i = c.target_tile
	_check(_data.hangar_index_at(tile) != 0 and _data.room_index_at(tile) != _data.hangars[A].room_index,
		"its console is outside the insertion bay: %s" % tile)
	_om.begin_mission(c)
	var t = _om.terminal()
	_check(t != null and t.tile == tile and t.is_inside_tree(), "ObjectiveManager builds the console at %s" % tile)
	_check(not _grid.get_tile(tile).passable and _grid.find_path(IN_BAY_A, tile, 999).is_empty(),
		"it blocks its tile")
	_check(_om.status_text().begins_with("Hold: Terminal — not started"), "line: %s" % _om.status_text())
	var beside := _free_neighbour(tile)
	var holder = await _spawn(PLAYER, beside)
	var far = await _spawn(PLAYER, IN_BAY_A)
	holder.owner_peer_id = 1
	far.owner_peer_id = 2
	_check(_om.operate_blocker(far) == "out of reach", "a soldier across the deck can't operate it")
	_check(_om.operate_blocker(holder) == "", "a soldier beside it can")
	_check("try_operate_terminal" in PU._COMMANDS, "the command is in PlayerUnit's RPC allowlist (a client can send it)")
	_check(holder.action_cost(ACTION_OPERATE_TERMINAL) == 2, "OPERATE_TERMINAL is 2 AP flat")
	holder.stats.reflexes = 99
	_check(holder.action_cost(ACTION_OPERATE_TERMINAL) == 2, "(Reflexes 99 changes nothing)")
	var spy_near := _spy(tile + Vector3i(-8, 0, 0))
	var spy_far := _spy(tile + Vector3i(-9, 0, 0))
	_tm.turn_number = 1
	_tm.active_unit = holder
	holder.ap = 5
	await holder.try_operate_terminal()
	_check(holder.ap == 3 and _om.terminal_rules.is_running(), "operating it costs 2 AP and starts it (%d AP left)" % holder.ap)
	_check(spy_near.heard.has(tile) and spy_far.heard.is_empty(), "loud the round it starts: heard at 8 tiles, not 9")
	holder.ap = 5
	await holder.try_operate_terminal()
	_check(holder.ap == 5, "operating a running console is refused at no cost")
	spy_near.heard.clear()
	_om._on_turn_started(2)
	_check(_om.terminal_rules.progress == 1 and spy_near.heard.size() == 1, "round 2 starts held: 1/4, and loud again")
	_check(_om.status_text().contains("running 1/"), "line: %s" % _om.status_text())
	# The holder goes down: a downed soldier beside it is not holding it.
	holder.take_damage(9999)
	_check(holder.life_state == LIFE.DOWNED, "(the holder is downed)")
	spy_near.heard.clear()
	_om._on_turn_started(3)
	_check(_om.terminal_rules.state == TR.State.PAUSED and _om.terminal_rules.progress == 1,
		"round 3 starts with only a downed soldier beside it: PAUSED, count kept at 1")
	_check(spy_near.heard.is_empty(), "a paused console is quiet")
	_om._on_turn_started(4)
	_check(_om.terminal_rules.progress == 1 and _om.terminal_rules.state == TR.State.PAUSED, "still paused on round 4")
	_check(_om.status_text().contains("PAUSED"), "line: %s" % _om.status_text())
	# The OTHER player's soldier walks up and restarts it (GDD §7.6: the crew is the squad).
	far.relocate_to(_free_neighbour(tile))
	_check(_om.operate_blocker(far) == "", "the other player's soldier can restart it")
	_check(_om.operate_terminal(far) and _om.terminal_rules.is_running(), "restarted")
	var verdict_before: bool = _om.is_complete([far])
	for turn in range(5, 5 + TR.HOLD_ROUNDS - 1):
		_om._on_turn_started(turn)
	_check(_om.terminal_rules.is_complete(), "held by the other player's soldier through 3 more round starts: complete")
	_check(not verdict_before and _om.is_complete([]), "the verdict follows the count (not before, latched after)")
	_check(_om.status_text().contains("complete"), "line: %s" % _om.status_text())
	_check(_om.operate_blocker(far) == "already complete", "a finished console offers nothing more")
	# The departure writes it into the result.
	var rules = load("res://scripts/extraction_rules.gd").new()
	rules.setup(_data.hangars)
	far.relocate_to(SQUARE_CENTRE)
	var result = _em.build_result(rules.split_passengers(A, [far], _em.riders_of))
	_check(result.objective_complete and int(result.contract.get("type", -1)) == _contract.Type.HOLD,
		"an extraction after the hold reports the objective complete")
	_unspy([spy_near, spy_far])
	_om.reset()
	_check(_om.terminal() == null and _grid.get_tile(tile).passable, "reset removes the console and frees its tile")
	await _free([holder, far])


# --- Recover: the VIP -------------------------------------------------------------


func _make_vip_contract():
	var c = _contract.make(_contract.Type.RECOVER, _data)
	return c


func _spawn_vip(c):
	var vip = _vip_script.make(c.target_tile, c.vip_name)
	root.add_child(vip)
	await process_frame
	return vip


func _check_vip_body() -> void:
	print("-- the VIP")
	var c = _make_vip_contract()
	_check(c != null and c.vip_name in _contract.VIP_NAMES and c.title() == "Recover: %s" % c.vip_name,
		"extraction_test hosts a Recover contract (%s)" % (c.title() if c else "null"))
	if c == null:
		return
	_check(_data.hangar_index_at(c.target_tile) != 0, "the VIP is not in the insertion bay")
	var vip = await _spawn_vip(c)
	_om.begin_mission(c)
	_check(_om.vip() == vip, "ObjectiveManager finds the VIP by tile")
	_check(vip.life_state == LIFE.DOWNED and vip.downed_hp == vip.downed_bar_max(), "spawned DOWNED, bar full")
	_check(_grid.is_free(vip.grid_pos), "holds no tile (a body)")
	_check(not vip.is_player_controlled and _em.crew_of(vip) == -1, "not player-controlled, in no crew")
	_check(not _tm._all_units().has(vip), "never in the draw pool")
	_check(vip.faction == load("res://scripts/faction.gd").Id.CONTRACTORS, "on the Contractors' side")
	_check(_om.status_text().contains("stable"), "line: %s" % _om.status_text())
	# A10: no bleed.
	var bar: int = vip.downed_hp
	_tm._bleed_downed()
	_tm._bleed_downed()
	_check(vip.downed_hp == bar and vip.life_state == LIFE.DOWNED, "does not bleed at round start (A10)")
	# Hostile AI does not go for it on purpose; a downed soldier still is prey.
	var alien = await _spawn(ENEMY, _free_neighbour(c.target_tile))
	var bleeding = await _spawn(PLAYER, _free_neighbour(alien.grid_pos))
	bleeding.take_damage(9999)
	var prey: Array = alien.downed_targets()
	_check(prey.has(bleeding) and not prey.has(vip), "aliens finish a downed soldier but not the VIP (%d prey)" % prey.size())
	# Revive refused; lift allowed for any owner's soldier.
	var lifter = await _spawn(PLAYER, _free_neighbour(vip.grid_pos))
	lifter.owner_peer_id = 2
	_check(lifter.revive_blocker(vip).contains("carry them out"), "revive is refused: %s" % lifter.revive_blocker(vip))
	_check(lifter.pick_up_blocker(vip) == "" and vip in lifter.body_targets(PU.Mode.PICK_UP),
		"any soldier can lift the VIP (owner 2 here)")
	_check(not (vip in lifter.body_targets(PU.Mode.REVIVE)), "and the revive button never offers them")
	_tm.active_unit = lifter
	lifter.ap = 5
	await lifter.try_pick_up(vip)
	_check(lifter.carrying == vip and vip.carried_by == lifter and lifter.ap == 3,
		"try_pick_up lifts the VIP for 2 AP")
	_check(_om.status_text().contains("carried by"), "line: %s" % _om.status_text())
	# The 25% redirect applies to them (plan Phase 6).
	var combat = load("res://scripts/combat.gd")
	var open_result = combat.ShotResult.new()
	open_result.hit = true
	var n := 0
	for i in 8000:
		if lifter.redirects_hit_to_carried(alien, open_result):
			n += 1
	_check(absf(n / 8000.0 - 0.25) < 0.02, "a hit on the carrier goes into the VIP %.2f%% of the time" % (n / 80.0))
	# Damage comes off the bar; an empty bar kills; a dead VIP is a failed contract.
	vip.take_damage(5)
	_check(vip.downed_hp == bar - 5 and vip.life_state == LIFE.DOWNED, "damage comes off the downed bar")
	_check(_om.is_complete([lifter, vip]), "carried aboard alive: Recover complete")
	vip.take_damage(999)
	_check(vip.life_state == LIFE.DEAD and lifter.carrying == vip, "an empty bar kills them (still carried)")
	_check(not _om.is_complete([lifter, vip]), "a dead VIP carried aboard is a failed contract")
	_check(_om.status_text().contains("failed"), "line: %s" % _om.status_text())
	_check(vip.loot_items().is_empty(), "nothing to loot off them")
	_om.reset()
	await _free([alien, bleeding, lifter, vip])


func _check_vip_extraction_counts() -> void:
	print("-- VIP extraction: carried, set down in the square, or left")
	var c = _make_vip_contract()
	var vip = await _spawn_vip(c)
	_em.begin_mission(_data)
	_om.begin_mission(c)
	var rules = load("res://scripts/extraction_rules.gd").new()
	rules.setup(_data.hangars)
	var carrier = await _spawn(PLAYER, SQUARE_CENTRE)
	carrier.record_id = "T0"
	# Left where they lie.
	var split: Dictionary = rules.split_passengers(A, [carrier], _em.riders_of)
	split["extracted"].append_array(_em.escorts_in_square(A, split["extracted"]))
	var result = _em.build_result(split)
	_check(not result.objective_complete, "the squad leaves without the VIP: not complete")
	# Carried aboard: a rider.
	carrier.relocate_to(_free_neighbour(vip.grid_pos))
	carrier.pick_up(vip)
	carrier.relocate_to(SQUARE_CENTRE)
	split = rules.split_passengers(A, [carrier], _em.riders_of)
	result = _em.build_result(split)
	_check(result.objective_complete, "carried onto the ship: Recover complete")
	_check(result.extracted_units.size() == 1 and result.extracted_units[0] == carrier and not result.lost_units.has(vip),
		"the VIP is in neither of the squad's lists")
	_check(load("res://scripts/mission_result.gd").manifest_for(result.extracted_units).is_empty(), "and adds nothing to the loot manifest")
	var report: Dictionary = load("res://scripts/campaign/campaign.gd").report_from_result(result, [carrier, vip], {})
	_check(report["soldiers"].size() == 1 and report["objective_complete"], "the campaign report lists only the soldier")
	# Set down in the square (not carried).
	carrier.drop_carried()
	_check(vip.grid_pos == SQUARE_CENTRE and vip.carried_by == null, "(put down in the square)")
	split = rules.split_passengers(A, [carrier], _em.riders_of)
	_check(not split["extracted"].has(vip), "an uncarried VIP is not a crew passenger")
	var escorts: Array = _em.escorts_in_square(A, split["extracted"])
	_check(escorts == [vip], "but is an escort in the square")
	split["extracted"].append_array(escorts)
	_check(_em.build_result(split).objective_complete, "set down in the square at departure: complete")
	# Outside the square: not an escort.
	vip.relocate_to(IN_BAY_A)
	_check(_em.escorts_in_square(A, []).is_empty(), "lying outside the square: not aboard")
	_om.reset()
	_em.reset()
	await _free([carrier, vip])


## The real path: ExtractionManager's turn hooks land the ship, a soldier carrying
## the VIP signals dust-off from the square, and the departure ends the mission
## with the objective met.
func _check_vip_full_departure() -> void:
	print("-- VIP extraction through the real departure")
	var c = _make_vip_contract()
	var vip = await _spawn_vip(c)
	var carrier = await _spawn(PLAYER, _free_neighbour(vip.grid_pos))
	carrier.owner_peer_id = 2
	_em.begin_mission(_data)
	_om.begin_mission(c)
	_tm.mission_over = false
	_ended.clear()
	carrier.pick_up(vip)
	carrier.relocate_to(IN_BAY_A)
	_tm.turn_number = 1
	_tm.pool.clear()
	_check(_em.call_ship(carrier), "the carrier calls the ship at A")
	for turn in [2, 3, 4]:
		_tm.turn_number = turn
		_em._on_turn_started(turn)
	_check(_em.rules.state_of(A) == load("res://scripts/extraction_rules.gd").State.LANDED, "landed on round 4")
	carrier.relocate_to(SQUARE_CENTRE)
	_check(_em.request_dust_off(carrier), "the carrier signals dust-off")
	await _em._on_round_ending(4)
	_check(_ended.size() == 1, "the departure ends the mission")
	if _ended.size() == 1:
		var result = _ended[0]
		_check(result.objective_complete, "with the VIP aboard: objective complete")
		_check(result.extracted_units.size() == 1 and result.extracted_units[0] == carrier, "extracted: the carrier only (%d)" % result.extracted_units.size())
	_tm.mission_over = false
	_om.reset()
	_em.reset()
	await _free([carrier, vip])


# --- Placement over generated decks -----------------------------------------------


func _check_placement() -> void:
	print("-- placement on generated decks")
	var gen = load("res://scripts/map_generator.gd")
	const DECKS := 40
	var hold_ok := 0
	var recover_ok := 0
	var wall_ok := true
	var reach_ok := true
	var far_ok := true
	var vip_ok := true
	for s in range(1, DECKS + 1):
		var data = gen.generate(s)
		var types: Array = _contract.supported_types(data)
		if types.has(_contract.Type.HOLD):
			hold_ok += 1
		if types.has(_contract.Type.RECOVER):
			recover_ok += 1
		var h = _contract.make(_contract.Type.HOLD, data)
		if h != null:
			var pos: Vector3i = h.target_tile
			var walled := false
			for step in MD.SIDE_STEP:
				if data.terrain_at(pos + step) == MD.Terrain.WALL:
					walled = true
			wall_ok = wall_ok and walled and data.hangar_index_at(pos) < 0
			# Blocking the console must leave every other reachable tile reachable.
			var before: Dictionary = _contract.path_distances(data)
			far_ok = far_ok and _in_far_third(data, pos, _contract._terminal_candidates(data, before), before)
			data.add_container(pos, PackedStringArray())  # stands in for the console
			var after: Dictionary = _contract.path_distances(data)
			if after.size() != before.size() - 1:
				reach_ok = false
				print("    seed %d: console at %s cuts %d tile(s) off" % [s, pos, before.size() - 1 - after.size()])
		var r = _contract.make(_contract.Type.RECOVER, data)
		if r != null:
			var dist: Dictionary = _contract.path_distances(data)
			vip_ok = vip_ok and dist.has(r.target_tile) and data.hangar_index_at(r.target_tile) < 0 \
				and r.vip_name != ""
	_check(hold_ok == DECKS, "every generated deck supports Hold (%d/%d)" % [hold_ok, DECKS])
	_check(recover_ok == DECKS, "every generated deck supports Recover (%d/%d)" % [recover_ok, DECKS])
	_check(wall_ok, "the console stands against a wall, outside every hangar")
	_check(reach_ok, "and never cuts any tile off from the insertion square")
	_check(far_ok, "in a room from the farthest third by path distance")
	_check(vip_ok, "the VIP lies on reachable floor outside every hangar, named")
	seed(77)
	var a = _contract.choose(gen.generate(12))
	seed(77)
	var b = _contract.choose(gen.generate(12))
	_check(a.to_dict() == b.to_dict(), "the same seed chooses the same contract (co-op), Hold/Recover included")
	var wire = _contract.from_dict(bytes_to_var(var_to_bytes(_contract.make(_contract.Type.RECOVER, gen.generate(3)).to_dict())))
	_check(wire.vip_name != "" and wire.type == _contract.Type.RECOVER, "the VIP's name rides the contract's wire form")
	var offer_script = load("res://scripts/campaign/contract_offer.gd")
	_check(offer_script.OFFERED_TYPES.has(_contract.Type.HOLD) and offer_script.OFFERED_TYPES.has(_contract.Type.RECOVER),
		"the hub offers Hold and Recover")
	var econ = load("res://scripts/campaign/campaign_economy.gd")
	_check(econ.payout_for(_contract.Type.HOLD, 1) == 550 and econ.payout_for(_contract.Type.RECOVER, 1) == 650
		and econ.payout_for(_contract.Type.RECOVER, 0) == 450,
		"payouts: Hold 550, Recover 650 on a Medium deck (Small Recover %d)" % econ.payout_for(_contract.Type.RECOVER, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var seen := {}
	for i in 24:
		seen[offer_script.generate(rng).type] = true
	_check(seen.has(_contract.Type.HOLD) and seen.has(_contract.Type.RECOVER), "the board deals them (%s)" % [seen.keys()])


func _in_far_third(data, pos: Vector3i, candidates: Array, dist: Dictionary) -> bool:
	var rooms := {}
	for c in candidates:
		var room: int = data.room_index_at(c)
		rooms[room] = mini(rooms.get(room, 999999), _contract._tile_dist(data, c, dist))
	var mine: int = rooms.get(data.room_index_at(pos), -1)
	var farther := 0
	for room in rooms:
		if rooms[room] > mine:
			farther += 1
	return farther < ceili(float(rooms.size()) / 3.0)


# --- Helpers ------------------------------------------------------------------------


func _free_neighbour(tile: Vector3i) -> Vector3i:
	for n in _grid.neighbors(tile):
		if _grid.is_free(n) and _grid.get_tile(n).passable:
			return n
	return tile


func _spy(at: Vector3i) -> NoiseSpy:
	var spy := NoiseSpy.new()
	spy.grid_pos = at
	spy.add_to_group("units")
	root.add_child(spy)
	return spy


func _unspy(spies: Array) -> void:
	for spy in spies:
		spy.remove_from_group("units")
		spy.queue_free()


func _spawn(scene_path: String, at: Vector3i):
	var unit = load(scene_path).instantiate()
	unit.position = _grid.grid_to_world(at)
	root.add_child(unit)
	await process_frame
	return unit


func _free(units: Array) -> void:
	for unit in units:
		if is_instance_valid(unit):
			if unit.carrying != null:
				unit.drop_carried()
			var t = _grid.get_tile(unit.grid_pos)
			if t and t.occupant == unit:
				_grid.set_occupant(unit.grid_pos, null)
			unit.remove_from_group("units")
			unit.remove_from_group("player_units")
			unit.remove_from_group("vips")
			unit.queue_free()
	await process_frame


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
