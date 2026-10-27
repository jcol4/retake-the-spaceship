extends SceneTree
## Extraction plan Phase 0: the groundwork every later phase stands on.
##
##   godot --headless --path . --script res://tools/test_turn_hooks.gd
##
##   0.1  `turn_ending` fires once per round, before the next `turn_started`, and
##        a turn-end hook is awaited to completion — and may end the mission —
##        before the next round begins. Ship departure (Phase 1) depends on both.
##   0.2  MissionResult survives the trip to a client (to_dict / from_dict, and
##        the binary encoding an RPC actually uses), and `clear_out_mode` is the
##        only thing standing between "no hostiles left" and the mission ending.
##   0.3  `is_downed` is derived from `life_state`.
##   0.4  (in test_faction.gd)
##   0.5  Flat-cost actions ignore Reflexes and the weapon.
##
## The turn loop is driven for real: the TurnManager autoload, two soldiers on the
## test deck, and `end_activation` standing in for the player's End Turn button.
## Soldiers rather than aliens because a soldier waits for its owner — nothing
## acts on its own, so the order of events is entirely the loop's.
##
## Scripts are load()ed rather than named, and locals stay untyped: a --script
## tool is compiled before the class registry and the autoloads exist. See
## test_cerberus.gd.

const PLAYER := "res://scenes/player_unit.tscn"
const ANCHOR := Vector3i(7, 0, 6)

## Rounds driven in the ordering check. Three is the fewest that shows a pattern
## rather than a coincidence: two complete round boundaries.
const ROUNDS := 3
## Frames to give the loop to reach the next activation before calling it hung.
## It needs two or three (a deferred `_draw_next`, a hook awaiting a frame).
const FRAME_BUDGET := 30

var _failures := 0
var _grid: Node
var _turns: Node
var MR  # MissionResult script
var LIFE  # Unit.LifeState
var ACT  # UnitStats.Action
var _stats_script

var _events: Array[String] = []
var _results: Array = []


func _initialize() -> void:
	_grid = root.get_node_or_null("GridManager")
	_turns = root.get_node_or_null("TurnManager")
	MR = load("res://scripts/mission_result.gd")
	LIFE = load("res://scripts/unit.gd").LifeState
	_stats_script = load("res://scripts/unit_stats.gd")
	ACT = _stats_script.Action
	var map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(map)
	await process_frame

	_turns.turn_started.connect(func(n: int) -> void: _events.append("started %d" % n))
	_turns.turn_ending.connect(func(n: int) -> void: _events.append("ending %d" % n))
	_turns.mission_ended.connect(func(r) -> void: _results.append(r))

	_check_flat_costs_static()
	await _check_flat_costs_on_a_unit()
	await _check_life_state()
	await _check_mission_result_round_trip()
	await _check_clear_out_mode()
	await _check_turn_ending_order()
	await _check_hook_can_end_the_mission()

	print("")
	if _failures == 0:
		print("turn_hooks: ALL CHECKS PASSED")
		quit(0)
	else:
		print("turn_hooks: %d CHECK(S) FAILED" % _failures)
		quit(1)


# --- 0.5 ----------------------------------------------------------------------

## The GDD §4.2 numbers, read straight off the table, and the floor-free 0.
func _check_flat_costs_static() -> void:
	var flat: Dictionary = _stats_script.FLAT_AP_COST
	_check(flat[ACT.REVIVE] == 3 and flat[ACT.PICK_UP] == 2 and flat[ACT.LOOT] == 1
		and flat[ACT.CALL_SHIP] == 1 and flat[ACT.DUST_OFF] == 0,
		"FLAT_AP_COST matches GDD §4.2 (revive 3, pick up 2, loot 1, call ship 1, dust-off 0)")
	var overlap := false
	for action in flat:
		if _stats_script.BASE_AP_COST.has(action) or _stats_script.K_REFLEXES.has(action):
			overlap = true
	_check(not overlap, "no action is priced by both the flat and the discounted tables")
	# The pre-existing actions keep their numbers — the test tools that name them
	# by value depend on the enum being append-only.
	_check(ACT.SHOOT == 0 and ACT.SUPPRESS == 5 and ACT.OVERWATCH == 6,
		"the original Action values did not move")


## Priced through `Unit.action_cost`, the call the planner and the HUD use, at the
## two ends of Reflexes — where Shoot's price visibly moves and these must not.
func _check_flat_costs_on_a_unit() -> void:
	var unit = await _spawn(PLAYER, ANCHOR)
	var flat: Dictionary = _stats_script.FLAT_AP_COST
	var original_reflexes: int = unit.stats.reflexes
	unit.stats.reflexes = 0
	var slow_shot: int = unit.action_cost(ACT.SHOOT)
	var slow := {}
	for action in flat:
		slow[action] = unit.action_cost(action)
	unit.stats.reflexes = 99
	var fast_shot: int = unit.action_cost(ACT.SHOOT)
	_check(fast_shot < slow_shot,
		"sanity: Reflexes does discount Shoot (%d -> %d)" % [slow_shot, fast_shot])
	var all_flat := true
	for action in flat:
		var fast: int = unit.action_cost(action)
		if fast != flat[action] or slow[action] != flat[action]:
			all_flat = false
			print("    %s: %d at Reflexes 0, %d at 99, table says %d" % [
				ACT.keys()[action], slow[action], fast, flat[action]])
	_check(all_flat, "every flat-cost action costs its table price at Reflexes 0 and 99")
	unit.stats.reflexes = original_reflexes  # the stat block may be a shared resource
	_free([unit])


# --- 0.3 ----------------------------------------------------------------------

func _check_life_state() -> void:
	var unit = await _spawn(PLAYER, ANCHOR)
	_check(unit.life_state == LIFE.ACTIVE and not unit.is_downed, "a fresh unit is ACTIVE")
	unit.life_state = LIFE.DOWNED
	_check(unit.is_downed, "DOWNED reads as is_downed")
	unit.life_state = LIFE.DEAD
	_check(unit.is_downed, "DEAD reads as is_downed")
	unit.life_state = LIFE.ACTIVE
	_check(not unit.is_downed, "and back to ACTIVE reads as up")
	# No behaviour change: dropping to 0 HP still downs, it does not kill.
	unit.take_damage(unit.current_hp + 100)
	_check(unit.life_state == LIFE.DOWNED,
		"0 HP puts a unit DOWNED, not DEAD (Phase 2 decides that)")
	_free([unit])


# --- 0.2 ----------------------------------------------------------------------

func _check_mission_result_round_trip() -> void:
	var out = await _spawn(PLAYER, ANCHOR)
	var left = await _spawn(PLAYER, ANCHOR + Vector3i(1, 0, 0))
	var result = MR.new(MR.Outcome.EXTRACTED)
	result.extracted_units.append(out)
	result.lost_units.append(left)
	result.objective_complete = true
	result.loot = [{"item": 3, "count": 2}, "keycard"]

	var data: Dictionary = result.to_dict()
	# What an RPC argument really goes through — an Object anywhere in the
	# dictionary would come out the other side as null (or not at all).
	var wire = bytes_to_var(var_to_bytes(data))
	_check(wire == data, "to_dict survives binary encoding unchanged (no Objects in it)")

	var back = MR.from_dict(wire, root)
	_check(back.outcome == MR.Outcome.EXTRACTED, "outcome round-trips")
	_check(back.extracted_units.size() == 1 and back.extracted_units[0] == out,
		"extracted units round-trip by node path")
	_check(back.lost_units.size() == 1 and back.lost_units[0] == left,
		"lost units round-trip by node path")
	_check(back.objective_complete, "objective_complete round-trips")
	_check(back.loot == result.loot, "loot round-trips")
	_check(back.is_success() and not MR.new(MR.Outcome.WIPED).is_success()
		and not MR.new(MR.Outcome.ABANDONED).is_success()
		and MR.new(MR.Outcome.CLEARED).is_success(),
		"is_success: EXTRACTED and CLEARED only")

	# A unit gone by the time it arrives is dropped, never kept as a null.
	data["lost"].append("/root/NoSuchUnit")
	_check(MR.from_dict(data, root).lost_units.size() == 1, "an unresolvable path is dropped")
	_free([out, left])


## "Every hostile down = won" exists only behind clear_out_mode. The deck below
## holds one soldier and nothing hostile: with the flag on that is an instant
## CLEARED, with it off the round just runs.
func _check_clear_out_mode() -> void:
	var unit = await _spawn(PLAYER, ANCHOR)

	_turns.clear_out_mode = true
	_results.clear()
	_turns.start_mission()
	await process_frame
	_check(_results.size() == 1 and _results[0].outcome == MR.Outcome.CLEARED,
		"clear_out_mode ON: no hostiles ends the mission CLEARED")
	if _results.size() == 1:
		_check(unit in _results[0].extracted_units,
			"and the standing soldier is counted as extracted")

	_turns.clear_out_mode = false
	_results.clear()
	_turns.start_mission()
	await process_frame
	_check(_results.is_empty() and not _turns.mission_over,
		"clear_out_mode OFF: no hostiles does not end the mission")
	_check(_turns.active_unit == unit, "and the soldier is drawn to act")
	_turns.abandon()
	_check(_results.size() == 1 and _results[0].outcome == MR.Outcome.ABANDONED,
		"abandon() ends it ABANDONED")
	_free([unit])
	await process_frame


# --- 0.1 ----------------------------------------------------------------------

## THE ordering contract. A hook awaiting a frame proves the loop waits for it:
## if it did not, "started" would land before "hook done".
func _check_turn_ending_order() -> void:
	var a = await _spawn(PLAYER, ANCHOR)
	var b = await _spawn(PLAYER, ANCHOR + Vector3i(1, 0, 0))
	var hook := func(n: int) -> void:
		await process_frame
		_events.append("hook done %d" % n)
	_turns.add_turn_end_hook(hook)
	_turns.add_turn_end_hook(hook)  # idempotent: must still run once a round

	_turns.clear_out_mode = false
	_events.clear()
	_turns.start_mission()
	var hung := not await _drive_until(func() -> bool: return _turns.turn_number > ROUNDS)
	_turns.remove_turn_end_hook(hook)
	_turns.abandon()

	_check(not hung, "the loop reached round %d (events: %s)" % [ROUNDS + 1, _events])
	var expected: Array[String] = ["started 1"]
	for n in range(1, ROUNDS + 1):
		expected.append_array(["ending %d" % n, "hook done %d" % n, "started %d" % (n + 1)])
	_check(_events == expected,
		"each round: turn_ending, then its hook completes, then the next turn_started\n      got      %s\n      expected %s" % [_events, expected])
	_free([a, b])
	await process_frame


## Departure's shape (Phase 1): a hook ends the mission, and the next round never
## starts.
func _check_hook_can_end_the_mission() -> void:
	var a = await _spawn(PLAYER, ANCHOR)
	var leave := func(n: int) -> void:
		await process_frame
		if n == 2:
			_turns.end_mission(MR.new(MR.Outcome.EXTRACTED))
	_turns.add_turn_end_hook(leave)

	_turns.clear_out_mode = false
	_events.clear()
	_results.clear()
	_turns.start_mission()
	await _drive_until(func() -> bool: return _turns.mission_over)
	_turns.remove_turn_end_hook(leave)

	_check(_results.size() == 1 and _results[0].outcome == MR.Outcome.EXTRACTED,
		"a turn-end hook can end the mission")
	_check(not ("started 3" in _events),
		"and the round after it never starts (events: %s)" % [_events])
	_turns.abandon()
	_free([a])
	await process_frame


## Ends whichever soldier is up, frame after frame, until `done` holds. False if
## the loop stopped producing activations first.
func _drive_until(done: Callable) -> bool:
	var idle := 0
	while not done.call():
		if _turns.mission_over:
			return done.call()
		if _turns.active_unit != null:
			_turns.end_activation(_turns.active_unit)
			idle = 0
		else:
			idle += 1
			if idle > FRAME_BUDGET:
				return false
		await process_frame
	return true


func _spawn(scene_path: String, at: Vector3i):
	var unit = load(scene_path).instantiate()
	unit.position = _grid.grid_to_world(at)
	root.add_child(unit)
	await process_frame
	return unit


func _free(units: Array) -> void:
	for unit in units:
		if is_instance_valid(unit):
			_grid.set_occupant(unit.grid_pos, null)
			unit.queue_free()


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
