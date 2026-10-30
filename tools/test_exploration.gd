extends SceneTree
## Exploration mode and the step clock (GDD §4.7, EXPLORATION_PLAN.md A-C).
##
##   godot --headless --path . --script res://tools/test_exploration.gd
##
## The pure parts run against ExplorationRules. The rest drives the real
## TurnManager autoload with soldiers on the test deck, calling their commands
## directly, as the host does when a click arrives. Soldiers rather than AI where
## possible, because a soldier waits for its owner: nothing acts unasked, so the
## order of events is the loop's alone.
##
## Scripts are load()ed and locals stay untyped: a --script tool is compiled before
## the class registry and the autoloads exist. See test_cerberus.gd.

const PLAYER := "res://scenes/player_unit.tscn"
const ENEMY := "res://scenes/enemy_unit.tscn"
## Floor in the deck's open middle room (maps/worm_test_deck.txt).
const ANCHOR := Vector3i(7, 0, 6)
const PER_ROUND := 20

var _failures := 0
var _grid: Node
var _turns: Node
var _lighting: Node
var R  # ExplorationRules
var AWARE  # EnemyUnit.AlertState
var ACT  # UnitStats.Action
var LIFE  # Unit.LifeState
var _map


func _initialize() -> void:
	_grid = root.get_node("GridManager")
	_turns = root.get_node("TurnManager")
	_lighting = root.get_node("LightingManager")
	R = load("res://scripts/exploration_rules.gd")
	AWARE = load("res://scripts/enemy_unit.gd").AlertState
	ACT = load("res://scripts/unit_stats.gd").Action
	LIFE = load("res://scripts/unit.gd").LifeState
	_map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(_map)
	await process_frame
	_clear_board()

	_check_rules()
	_check_scheduler()
	await _check_two_walkers()
	await _check_reservation()
	await _check_cancel()
	await _check_may_act()
	await _check_clock_ticks_rounds()
	await _check_wounded_leg_steps()
	await _check_action_lands_before_its_round()
	await _check_timers_follow_the_clock()
	await _check_contact_stops_walker()
	await _check_per_step_detection()
	await _check_contact_stops_every_walker()
	await _check_round_hooks_run_in_a_tick()
	await _check_last_soldier_aboard()
	await _check_non_contact_starts_nothing()
	await _check_nest_is_never_contact()
	await _check_opening_shot_ap()
	await _check_opening_suppress()
	await _check_wait_keeps_overwatch()
	await _check_overwatch_fires_on_patrol()
	await _check_quiet_round_returns()
	await _check_redirect()
	await _check_ownership()

	print("")
	if _failures == 0:
		print("exploration: ALL CHECKS PASSED")
		quit(0)
	else:
		print("exploration: %d CHECK(S) FAILED" % _failures)
		quit(1)


# --- ExplorationRules --------------------------------------------------------


func _check_rules() -> void:
	_check(R.SQUAD_FACTION == load("res://scripts/faction.gd").Id.CONTRACTORS,
		"SQUAD_FACTION mirrors Faction.Id.CONTRACTORS")
	_check(R.advance(0, 20) == Vector2i(0, 1), "20 steps tick one round")
	_check(R.advance(19, 3) == Vector2i(2, 1), "19 + 3 ticks with 2 carried")
	_check(R.advance(5, 3) == Vector2i(8, 0), "under the line ticks nothing")
	_check(R.steps_to_boundary(12) == 8 and R.steps_to_boundary(0) == 20,
		"Wait burns exactly to the next boundary")
	_check(R.rounds_passed(10, 23) == 1, "the readout counts rounds a walk passes")
	_check(R.opening_ap(10, 3) == 7 and R.opening_ap(2, 5) == 0, "opening AP is floored at 0")
	_check(R.targets_squad(R.SQUAD_FACTION) and not R.targets_squad(1), "only the squad's side counts")
	_check(not R.quiet_for_a_round(5, 5) and R.quiet_for_a_round(5, 6),
		"quiet needs one full round without contact")


func _check_scheduler() -> void:
	# A leaves (1,0) in its second step; B steps into (1,0) in its first.
	var events := [
		{"unit": "A", "kind": R.EV_STEP, "from": Vector3i(0, 0, 0), "to": Vector3i(1, 0, 0)},
		{"unit": "A", "kind": R.EV_STEP, "from": Vector3i(1, 0, 0), "to": Vector3i(2, 0, 0)},
		{"unit": "B", "kind": R.EV_STEP, "from": Vector3i(1, 0, 1), "to": Vector3i(1, 0, 0)},
		{"unit": "C", "kind": R.EV_STEP, "from": Vector3i(5, 0, 5), "to": Vector3i(5, 0, 6)},
	]
	var slots: Array = R.schedule(events)
	_check(slots[0] == 0 and slots[1] == 1, "a unit's own steps are consecutive")
	_check(slots[2] == 2, "a step into a just-vacated tile comes after the vacating step (got %d)" % slots[2])
	_check(slots[3] == 0, "an unrelated unit plays alongside, not after")
	# S shoots A, who has moved; A then falls.
	var shot := events.slice(0, 2)
	shot.append({"unit": "S", "kind": R.EV_SHOT, "target": "A"})
	shot.append({"unit": "A", "kind": R.EV_DOWN, "dead": false})
	var shot_slots: Array = R.schedule(shot)
	_check(shot_slots[2] == 2, "a shot at a mover lands after its last step (got %d)" % shot_slots[2])
	_check(shot_slots[3] == 3, "and the collapse after the shot (got %d)" % shot_slots[3])
	var groups: Array = R.by_slot(slots)
	_check(groups.size() == 3 and groups[0] == [0, 3], "by_slot groups a slot's events")


# --- Phase A ------------------------------------------------------------------


func _check_two_walkers() -> void:
	_start_exploring()
	var a = await _spawn(PLAYER, ANCHOR)
	var b = await _spawn(PLAYER, ANCHOR + Vector3i(2, 0, 0))
	# Head on along one row: they cannot both have the middle tile.
	a.move_along(_path([ANCHOR + Vector3i(1, 0, 0), ANCHOR + Vector3i(2, 0, 0), ANCHOR + Vector3i(3, 0, 0)]))
	b.move_along(_path([ANCHOR + Vector3i(1, 0, 0), ANCHOR]))
	await _settle()
	_check(a.grid_pos != b.grid_pos, "two crossing walkers never share a tile (%s, %s)" % [a.grid_pos, b.grid_pos])
	_check(_grid.get_tile(a.grid_pos).occupant == a, "the first holds its own tile")
	_check(_grid.get_tile(b.grid_pos).occupant == b, "the second holds its own tile")
	_end([a, b])
	await process_frame


func _check_reservation() -> void:
	_start_exploring()
	var a = await _spawn(PLAYER, ANCHOR)
	var goal: Vector3i = ANCHOR + Vector3i(3, 0, 0)
	var other := Node3D.new()
	root.add_child(other)
	_check(_grid.reserve(goal, a), "a free tile can be reserved")
	_check(not _grid.reserve(goal, other), "a second unit cannot reserve it")
	_check(not _grid.open_destination(goal, other) and _grid.open_destination(goal, a),
		"it is closed as a destination to anyone else")
	_check(_grid.is_free(goal), "and stays free to pass through")
	_grid.release_reservation(a)
	_check(_grid.reserve(goal, other), "released, it can be taken")
	_grid.release_reservation(other)
	other.free()
	# A walk through someone's reserved goal passes; a walk ENDING there stops short.
	var holder = await _spawn(PLAYER, ANCHOR + Vector3i(0, 0, 3))
	_grid.reserve(goal, holder)
	await a.move_along(_path([ANCHOR + Vector3i(1, 0, 0), ANCHOR + Vector3i(2, 0, 0), goal, goal + Vector3i(1, 0, 0)]))
	_check(a.grid_pos == goal + Vector3i(1, 0, 0), "a reserved tile can be walked through")
	await a.move_along(_path([goal]))
	_check(a.grid_pos == goal + Vector3i(1, 0, 0), "but not ended on (at %s)" % a.grid_pos)
	_grid.release_reservation(holder)
	_end([a, holder])
	await process_frame


func _check_cancel() -> void:
	_start_exploring()
	var a = await _spawn(PLAYER, ANCHOR)
	var stepped := [0]
	a.stepped.connect(func(_u) -> void:
		stepped[0] += 1
		if stepped[0] == 2:
			a.cancel_walk())
	await a.move_along(_path([ANCHOR + Vector3i(1, 0, 0), ANCHOR + Vector3i(2, 0, 0), ANCHOR + Vector3i(3, 0, 0)]))
	_check(a.grid_pos == ANCHOR + Vector3i(2, 0, 0), "a cancel stops on the tile boundary (at %s)" % a.grid_pos)
	_check(_grid.get_tile(a.grid_pos).occupant == a, "and it holds that tile")
	_check(_grid.is_free(ANCHOR) and _grid.is_free(ANCHOR + Vector3i(1, 0, 0)), "and nothing behind it")
	_check(not a.is_walking() and not _turns.is_anyone_walking(), "and no walk is left registered")
	_end([a])
	await process_frame


func _check_may_act() -> void:
	_grid_clear_turn()
	var a = await _spawn(PLAYER, ANCHOR)
	var b = await _spawn(PLAYER, ANCHOR + Vector3i(1, 0, 0))
	a.owner_peer_id = 7
	_turns.active_unit = b
	_check(_turns.may_act(b, 1, &"_do_shoot") == "", "turn mode: the drawn unit may act")
	_check(_turns.may_act(a, 7, &"_do_shoot") != "", "turn mode: nobody else may, even its owner")
	_turns.active_unit = a
	_check(_turns.may_act(a, 1, &"_do_shoot") != "", "turn mode: nor a peer who does not own it")
	_turns.active_unit = null
	_end([a, b])
	await process_frame


# --- The clock ----------------------------------------------------------------


func _check_clock_ticks_rounds() -> void:
	_start_exploring()
	var a = await _spawn(PLAYER, ANCHOR)
	_check(_turns.turn_number == 1 and _turns.in_exploration(), "a mission opens in exploration on round 1")
	_check(_turns.active_unit == null or _turns.active_unit == a, "with no draw")
	_turns.add_steps(19)
	await _turns.settle_clock()
	_check(_turns.turn_number == 1 and _turns.steps == 19, "19 steps tick nothing")
	_turns.add_steps(3)
	_check(_turns.turn_number == 1, "add_steps only records; the tick waits for a settle")
	await _turns.settle_clock()
	_check(_turns.turn_number == 2 and _turns.steps == 2, "19 + 3 ticks one round with 2 carried (round %d, %d steps)" % [_turns.turn_number, _turns.steps])
	var r: int = _turns.turn_number
	await a.try_wait()
	_check(_turns.turn_number == r + 1 and _turns.steps == 0, "wait advances exactly one round")
	await a.try_wait()
	_check(_turns.turn_number == r + 2, "and again")
	_end([a])
	await process_frame


func _check_wounded_leg_steps() -> void:
	_start_exploring()
	var a = await _spawn(PLAYER, ANCHOR)
	var unhurt: int = a.move_ap_per_tile()
	await a.move_along(_path([ANCHOR + Vector3i(1, 0, 0), ANCHOR + Vector3i(2, 0, 0)]))
	_check(_turns.steps == 2 * unhurt, "two tiles cost two steps (%d)" % _turns.steps)
	a.apply_injuries([load("res://scripts/combat.gd").BodyPart.LEG_L])
	var one_leg: int = a.move_ap_per_tile()
	_check(one_leg == 2, "one bad leg costs 2 a tile (%d)" % one_leg)
	_turns.steps = 0
	await a.move_along(_path([ANCHOR + Vector3i(3, 0, 0)]))
	_check(_turns.steps == 2, "and the clock charges it (%d)" % _turns.steps)
	a.apply_injuries([load("res://scripts/combat.gd").BodyPart.LEG_R])
	_check(a.move_ap_per_tile() == 3, "both legs cost 3 a tile (%d)" % a.move_ap_per_tile())
	_end([a])
	await process_frame


## E6: a revive started at 19 steps lands BEFORE the round it crosses ticks, so the
## body is up by the time the bleed comes round.
func _check_action_lands_before_its_round() -> void:
	_start_exploring()
	var medic = await _spawn(PLAYER, ANCHOR)
	var body = await _spawn(PLAYER, ANCHOR + Vector3i(1, 0, 0))
	body.take_damage(body.current_hp + 100)
	_check(body.life_state == LIFE.DOWNED, "sanity: the soldier is down")
	var bar: int = body.downed_hp
	_turns.steps = 19
	await medic.try_revive(body)
	_check(body.life_state == LIFE.ACTIVE, "the revive landed")
	_check(_turns.turn_number == 2, "and crossing the line ticked the round (%d)" % _turns.turn_number)
	_check(body.downed_hp == bar, "with no bleed on the revived soldier (%d -> %d)" % [bar, body.downed_hp])
	_end([medic, body])
	await process_frame


func _check_timers_follow_the_clock() -> void:
	_start_exploring()
	var a = await _spawn(PLAYER, ANCHOR)
	var body = await _spawn(PLAYER, ANCHOR + Vector3i(3, 0, 0))
	body.take_damage(body.current_hp + 100)
	var bar: int = body.downed_hp
	var started := [0]
	var ending := [0]
	var count_start := func(_n: int) -> void: started[0] += 1
	var count_end := func(_n: int) -> void: ending[0] += 1
	_turns.turn_started.connect(count_start)
	_turns.turn_ending.connect(count_end)
	await process_frame
	await process_frame
	_check(started[0] == 0 and body.downed_hp == bar, "standing still advances nothing")
	_turns.add_steps(PER_ROUND)
	await _turns.settle_clock()
	_check(started[0] == 1 and ending[0] == 1, "a round on the clock fires both round signals (%d, %d)" % [started[0], ending[0]])
	_check(body.downed_hp < bar, "and the downed bleed (%d -> %d)" % [bar, body.downed_hp])
	_turns.turn_started.disconnect(count_start)
	_turns.turn_ending.disconnect(count_end)
	_end([a, body])
	await process_frame


# --- Contact ------------------------------------------------------------------


func _check_contact_stops_walker() -> void:
	_start_exploring()
	var a = await _spawn(PLAYER, ANCHOR)
	var e = await _spawn(ENEMY, ANCHOR + Vector3i(4, 0, 2))
	var round_before: int = _turns.turn_number
	var bleeds := [0]
	var count := func(_n: int) -> void: bleeds[0] += 1
	_turns.turn_started.connect(count)
	var stepped := [0]
	a.stepped.connect(func(_u) -> void:
		stepped[0] += 1
		if stepped[0] == 2:
			e._enter_combat(a, "spotted"))
	await a.move_along(_path([ANCHOR + Vector3i(1, 0, 0), ANCHOR + Vector3i(2, 0, 0), ANCHOR + Vector3i(3, 0, 0)]))
	_check(a.grid_pos == ANCHOR + Vector3i(2, 0, 0), "a walker spotted mid-path stops on that tile (at %s)" % a.grid_pos)
	await _settle()
	_check(not _turns.in_exploration(), "and the mission is in turn mode")
	_check(_turns.turn_number == round_before and bleeds[0] == 0, "with the same round and no round start")
	_check(_turns.steps == 0, "and the leftover steps gone")
	_turns.turn_started.disconnect(count)
	_end([a, e])
	await process_frame


## B.4 through the real path: an enemy with eyes on the walker, in its own light.
func _check_per_step_detection() -> void:
	_start_exploring()
	var a = await _spawn(PLAYER, ANCHOR)
	var e = await _spawn(ENEMY, ANCHOR + Vector3i(4, 0, 0))
	var nest = await _spawn("res://scenes/nest_unit.tscn", ANCHOR + Vector3i(3, 0, 3))
	a.flashlight_on = false
	for tile: Vector3i in _grid.tiles:
		_grid.get_tile(tile).light_value = 100.0
	await a.move_along(_path([ANCHOR + Vector3i(0, 0, 1), ANCHOR + Vector3i(0, 0, 2), ANCHOR + Vector3i(0, 0, 3)]))
	_check(a.grid_pos == ANCHOR + Vector3i(0, 0, 1), "an enemy in sight stops the walker on its first step (at %s)" % a.grid_pos)
	_check(e.alert_state == AWARE.COMBAT and e.target == a, "by spotting it with its own senses")
	_check(nest.alert_state == AWARE.UNAWARE, "a nest looks at nothing")
	await _settle()
	_check(not _turns.in_exploration(), "and that is contact")
	_end([a, e, nest])
	await process_frame


## C.4: contact is global. One soldier spotted stops the other's walk as well.
func _check_contact_stops_every_walker() -> void:
	_start_exploring()
	var a = await _spawn(PLAYER, ANCHOR)
	var b = await _spawn(PLAYER, ANCHOR + Vector3i(0, 0, 2))
	b.owner_peer_id = 2
	var e = await _spawn(ENEMY, ANCHOR + Vector3i(6, 0, 1))
	var stepped := [0]
	a.stepped.connect(func(_u) -> void:
		stepped[0] += 1
		if stepped[0] == 2:
			e._enter_combat(a, "spotted"))
	var long_a := [ANCHOR + Vector3i(1, 0, 0), ANCHOR + Vector3i(2, 0, 0), ANCHOR + Vector3i(3, 0, 0), ANCHOR + Vector3i(4, 0, 0)]
	var long_b := [ANCHOR + Vector3i(1, 0, 2), ANCHOR + Vector3i(2, 0, 2), ANCHOR + Vector3i(3, 0, 2), ANCHOR + Vector3i(4, 0, 2)]
	a.move_along(_path(long_a))
	b.move_along(_path(long_b))
	await _settle()
	_check(a.grid_pos != long_a[-1] and b.grid_pos != long_b[-1], "one soldier spotted stops both walks (%s, %s)" % [a.grid_pos, b.grid_pos])
	_check(not _turns.in_exploration(), "and the mode switch waited for both to land")
	_end([a, b, e])
	await process_frame


## The hooks are ship departure's and the Hold's: the same ones a combat round runs.
func _check_round_hooks_run_in_a_tick() -> void:
	_start_exploring()
	var a = await _spawn(PLAYER, ANCHOR)
	var ran := []
	var hook := func(n: int) -> void:
		await process_frame
		ran.append(n)
	_turns.add_turn_end_hook(hook)
	_turns.add_steps(PER_ROUND)
	await _turns.settle_clock()
	_turns.remove_turn_end_hook(hook)
	_check(ran == [1], "a tick awaits the round-end hooks, with the round ending (%s)" % [ran])
	_check(_turns.turn_number == 2, "before the next round starts")
	_end([a])
	await process_frame


## Out of combat nothing draws, so the end check has to be asked for.
func _check_last_soldier_aboard() -> void:
	_start_exploring()
	var a = await _spawn(PLAYER, ANCHOR)
	var asked := [0]
	_turns.squad_gone_hook = func() -> bool:
		asked[0] += 1
		return true
	a.remove_from_group("player_units")
	a.remove_from_group("units")
	_turns.squad_changed()
	_check(asked[0] == 1, "the last soldier off the board is noticed between ticks")
	_end([a])
	await process_frame


func _check_non_contact_starts_nothing() -> void:
	_start_exploring()
	var a = await _spawn(PLAYER, ANCHOR)
	var e = await _spawn(ENEMY, ANCHOR + Vector3i(4, 0, 2))
	e.rouse(a.grid_pos)
	await _settle()
	_check(e.alert_state == AWARE.ALERT and _turns.in_exploration(), "an ALERT enemy starts nothing")
	var other = await _spawn(ENEMY, ANCHOR + Vector3i(4, 0, 0))
	other.faction = 2
	e._enter_combat(other, "")
	await _settle()
	_check(e.alert_state == AWARE.COMBAT and _turns.in_exploration(),
		"and neither does a fight between two other factions")
	_end([a, e, other])
	await process_frame


## A nest inherits the beam channel and `come_under_fire`, and never takes a turn.
func _check_nest_is_never_contact() -> void:
	_start_exploring()
	var a = await _spawn(PLAYER, ANCHOR)
	var nest = await _spawn("res://scenes/nest_unit.tscn", ANCHOR + Vector3i(2, 0, 2))
	nest._enter_combat(a, "")
	await _settle()
	_check(_turns.in_exploration(), "a nest lit or shot is not contact")
	_check(not _turns._squad_in_contact(), "and never holds the squad in a fight")
	_end([a, nest])
	await process_frame


func _check_opening_shot_ap() -> void:
	_start_exploring()
	var a = await _spawn(PLAYER, ANCHOR)
	var e = await _spawn(ENEMY, ANCHOR + Vector3i(3, 0, 0))
	var cost: int = a.action_cost(ACT.SHOOT)
	var pool: int = a.ap_pool()
	# Read as the draw hands it over: the first activation is the one that pays.
	var first_ap := [-1]
	var note := func(u) -> void:
		if u == a and first_ap[0] < 0:
			first_ap[0] = a.ap
	_turns.unit_activated.connect(note)
	await a._do_shoot(e)
	await _settle()
	_check(not _turns.in_exploration(), "an attack from exploration starts turn mode")
	var guard := 0
	while first_ap[0] < 0 and guard < 200 and not _turns.mission_over:
		guard += 1
		await process_frame
	_turns.unit_activated.disconnect(note)
	_check(first_ap[0] == pool - cost, "the shooter's first activation is short by the shot (%d of %d, cost %d)" % [first_ap[0], pool, cost])
	a.begin_activation()
	_check(a.ap == pool, "and only the first")
	_end([a, e])
	await process_frame


func _check_opening_suppress() -> void:
	_start_exploring()
	var a = await _spawn(PLAYER, ANCHOR)
	var b = await _spawn(PLAYER, ANCHOR + Vector3i(0, 0, 1))
	var e = await _spawn(ENEMY, ANCHOR + Vector3i(3, 0, 0))
	await a._try_suppress(e)
	await _settle()
	_check(not _turns.in_exploration(), "an opening Suppress starts turn mode")
	_check(e.suppressed_by == a, "with the target pinned")
	var drawn := []
	var note := func(u) -> void: drawn.append(u)
	_turns.unit_activated.connect(note)
	# Round 1's pool runs out: the suppressor is never drawn, and the pin holds.
	var opening: int = _turns.turn_number
	# Read at the round's end itself: a frame later, round 2 may already have drawn
	# the suppressor, which is exactly what lets the pin go.
	var pinned_at_end := [false]
	var at_end := func(_n: int) -> void:
		if not pinned_at_end[0]:
			pinned_at_end[0] = e.suppressed_by == a or e.is_downed
	_turns.turn_ending.connect(at_end, CONNECT_ONE_SHOT)
	var guard := 0
	while _turns.turn_number == opening and guard < 400 and not _turns.mission_over:
		if _turns.active_unit != null and _turns.active_unit.is_player_controlled:
			_check(_turns.active_unit != a, "the suppressor is left out of the opening round")
			_turns.end_activation(_turns.active_unit)
		guard += 1
		await process_frame
	_check(pinned_at_end[0], "the pin holds through the opening round")
	guard = 0
	while not drawn.has(a) and guard < 400 and not _turns.mission_over:
		if _turns.active_unit != null and _turns.active_unit.is_player_controlled:
			_turns.end_activation(_turns.active_unit)
		guard += 1
		await process_frame
	_check(drawn.has(a) and a.suppressing == null, "and releases at their round-2 activation")
	_turns.unit_activated.disconnect(note)
	_end([a, b, e])
	await process_frame


func _check_wait_keeps_overwatch() -> void:
	_start_exploring()
	var a = await _spawn(PLAYER, ANCHOR)
	await a.try_overwatch()
	_check(a.on_overwatch, "overwatch can be set out of combat")
	_check(_turns.steps == a.action_cost(ACT.OVERWATCH), "at its AP price in steps (%d)" % _turns.steps)
	await a.try_wait()
	_check(a.on_overwatch, "waiting does not let go of it")
	await a.try_reload()
	_check(a.on_overwatch == false or not a.can_reload(), "acting does")
	a.on_overwatch = true
	await a.move_along(_path([ANCHOR + Vector3i(1, 0, 0)]))
	_check(not a.on_overwatch, "so does moving")
	_end([a])
	await process_frame


func _check_overwatch_fires_on_patrol() -> void:
	_start_exploring()
	var a = await _spawn(PLAYER, ANCHOR)
	var e = await _spawn(ENEMY, ANCHOR + Vector3i(4, 0, 0))
	await a.try_overwatch()
	var ammo: int = a.ammo
	# A patrol's turn in a tick: it was told to go somewhere, and walks through the
	# angle. It sees nothing itself, so the shot is what starts the fight.
	e.detection_range = 0
	e.rouse(ANCHOR + Vector3i(4, 0, 3))
	_turns.add_steps(PER_ROUND)
	await _turns.settle_clock()
	await _settle()
	_check(a.ammo < ammo, "overwatch set out of combat fires on a patrol during a tick")
	_check(not _turns.in_exploration(), "and that starts combat")
	_end([a, e])
	await process_frame


func _check_quiet_round_returns() -> void:
	_start_exploring()
	var a = await _spawn(PLAYER, ANCHOR)
	var e = await _spawn(ENEMY, ANCHOR + Vector3i(4, 0, 2))
	var other = await _spawn(ENEMY, ANCHOR + Vector3i(-4, 0, 2))
	other.faction = a.faction  # a friend, so the run has no reason to end or to fight
	e._enter_combat(a, "spotted")
	await _settle()
	_check(not _turns.in_exploration(), "sanity: in turn mode")
	a.hunkered = true
	a.on_overwatch = true
	a.stunned = true
	a.suppressed_by = e
	# Contact ends by the enemy leaving the fight.
	e.alert_state = AWARE.UNAWARE
	e.target = null
	var guard := 0
	while not _turns.in_exploration() and guard < 400 and not _turns.mission_over:
		if _turns.active_unit != null and _turns.active_unit.is_player_controlled:
			a.on_overwatch = true  # as if held; a draw's begin_activation would clear it
			a.hunkered = true
			_turns.end_activation(_turns.active_unit)
		guard += 1
		await process_frame
	_check(_turns.in_exploration(), "a quiet round returns to exploration")
	_check(not a.hunkered and a.suppressed_by == null and not a.stunned, "with hunker, suppression and stun cleared")
	_check(a.on_overwatch, "and overwatch kept")
	_check(_turns.pool.is_empty() and _turns.steps == 0, "and the pool and clock reset")
	_end([a, e, other])
	await process_frame


func _check_redirect() -> void:
	_start_exploring()
	var a = await _spawn(PLAYER, ANCHOR)
	var stepped := [0]
	var back: Vector3i = ANCHOR + Vector3i(1, 0, 1)
	a.stepped.connect(func(_u) -> void:
		stepped[0] += 1
		if stepped[0] == 1:
			a._try_move(back))
	await a._try_move(ANCHOR + Vector3i(4, 0, 0))
	_check(a.grid_pos == back, "a new order mid-walk redirects at the next tile (at %s)" % a.grid_pos)
	_check(_grid.reserved_by(back) == null, "and the goal is released on arrival")
	_end([a])
	await process_frame


# --- Phase C, rules level -----------------------------------------------------


func _check_ownership() -> void:
	_start_exploring()
	var a = await _spawn(PLAYER, ANCHOR)
	var b = await _spawn(PLAYER, ANCHOR + Vector3i(0, 0, 2))
	a.owner_peer_id = 1
	b.owner_peer_id = 2
	_check(_turns.may_act(a, 1, &"_try_move") == "", "exploration: an owner may act")
	_check(_turns.may_act(b, 1, &"_try_move") != "", "and may not act on the other owner's soldier")
	_check(_turns.may_act(b, 2, &"_try_move") == "", "whose own owner can, at the same time")
	var goal: Vector3i = ANCHOR + Vector3i(4, 0, 1)
	_check(_grid.reserve(goal, a) and not _grid.reserve(goal, b), "a reservation refuses the other owner's goal")
	_grid.release_reservation(a)
	var rejected := []
	b.command_rejected.connect(func(why: String) -> void: rejected.append(why))
	_grid.reserve(goal, a)
	await b._explore_move(goal)
	_check(rejected == ["tile taken"], "a clash is reported as 'tile taken' (%s)" % [rejected])
	_grid.release_reservation(a)
	_turns.steps = 0
	var first := [ANCHOR + Vector3i(1, 0, 0), ANCHOR + Vector3i(2, 0, 0)]
	var second := [ANCHOR + Vector3i(0, 0, 3)]
	a.move_along(_path(first))
	b.move_along(_path(second))
	await _settle()
	_check(_turns.steps == 3, "the counter sums both owners' steps (%d)" % _turns.steps)
	_end([a, b])
	await process_frame


# --- Harness ------------------------------------------------------------------


func _path(tiles: Array) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	out.assign(tiles)
	return out


func _start_exploring() -> void:
	_clear_board()
	_turns.clear_out_mode = false
	_turns.exploration_enabled = true
	# Each case places its soldiers after this: an empty board is not yet a wipe.
	_turns.squad_gone_hook = func() -> bool: return true
	_turns.start_mission()


func _grid_clear_turn() -> void:
	_clear_board()
	_turns.exploration_enabled = false
	_turns.clear_out_mode = false
	_turns.mode = _turns.Mode.TURN


## The test deck's own units have no part in this: every case places its own.
func _clear_board() -> void:
	for node in get_nodes_in_group("units"):
		_grid.set_occupant(node.grid_pos, null)
		node.remove_from_group("units")
		node.free()


## Long enough for a deferred switch to turn mode and any walk to land.
func _settle() -> void:
	for _i in 12:
		await process_frame


func _end(units: Array) -> void:
	_turns.abandon()
	for unit in units:
		if is_instance_valid(unit):
			_grid.release_reservation(unit)
			_grid.set_occupant(unit.grid_pos, null)
			unit.remove_from_group("units")
			unit.queue_free()


func _spawn(scene_path: String, at: Vector3i):
	var unit = load(scene_path).instantiate()
	unit.position = _grid.grid_to_world(at)
	root.add_child(unit)
	await process_frame
	await physics_frame
	# A soldier on no campaign record deploys with nothing in hand.
	if unit.is_player_controlled:
		unit.stats.weapon = load("res://scripts/weapon_presets.gd").make(0)
		unit.ammo = unit.stats.mag_size
		unit.reserve = 30
	return unit


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
