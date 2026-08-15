extends SceneTree
## The suppression mechanic, rule by rule.
##
##   godot --headless --path . --script res://tools/test_suppression.gd
##
## Modelled on XCOM's: spend a burst to pin somebody, they shoot badly and act
## less, and if they break cover the burst you were holding goes off at them.
## Every one of those is a separate rule that can be broken independently, so
## each gets its own check.
##
## The reaction shot is the one worth being careful about. It is deliberately NOT
## an Overwatch shot — it takes no accuracy penalty at all — and that is the
## entire return on suppression costing more AP and three rounds. An
## "optimisation" that routed it through the overwatch path would still fire,
## still log, and still look right in play; only this file would notice.

const PLAYER := "res://scenes/player_unit.tscn"
const MERC := "res://scenes/merc_unit.tscn"

const ANCHOR := Vector3i(7, 0, 6)

## UnitStats.Action.SUPPRESS / SHOOT by value — a --script tool is compiled
## before the class registry exists, so the enum cannot be named. See
## test_cerberus.gd.
const ACTION_SHOOT := 0
const ACTION_SUPPRESS := 5

var _failures := 0
var _grid: Node
var _combat


func _initialize() -> void:
	_grid = root.get_node_or_null("GridManager")
	_combat = load("res://scripts/combat.gd")
	var map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(map)
	await process_frame

	await _check_costs_more_than_a_shot()
	await _check_spends_three_rounds()
	await _check_accuracy_and_ap_penalties()
	await _check_ends_on_the_suppressor_s_turn()
	await _check_breaking_cover_draws_the_held_shot()
	await _check_a_dead_suppressor_holds_nobody()

	print("")
	if _failures == 0:
		print("suppression: ALL CHECKS PASSED")
		quit(0)
	else:
		print("suppression: %d CHECK(S) FAILED" % _failures)
		quit(1)


## Must stay dearer than a snap shot at every Reflexes value, or it is simply a
## better Shoot and there is never a reason to take the plain one.
func _check_costs_more_than_a_shot() -> void:
	var unit = await _spawn(PLAYER, ANCHOR)
	var shoot: int = unit.action_cost(ACTION_SHOOT)
	var suppress: int = unit.action_cost(ACTION_SUPPRESS)
	_check(suppress > shoot,
		"suppression (%d AP) costs more than a snap shot (%d AP)" % [suppress, shoot])
	_free([unit])


## Three rounds, spent up front. A soldier holding fewer cannot lay any down.
func _check_spends_three_rounds() -> void:
	var shooter = await _spawn(PLAYER, ANCHOR)
	var target = await _spawn(MERC, ANCHOR + Vector3i(3, 0, 0))
	shooter.ammo = 3
	_check(shooter.can_suppress(), "three rounds is enough to suppress")
	await shooter.do_suppress(target)
	_check(shooter.ammo == 0, "and the burst spends all three (got %d)" % shooter.ammo)

	shooter.ammo = 2
	_check(not shooter.can_suppress(), "two rounds is not enough")
	_free([shooter, target])


## Both halves of the pin: heavy accuracy penalty, and AP off the next turn.
func _check_accuracy_and_ap_penalties() -> void:
	var shooter = await _spawn(PLAYER, ANCHOR)
	var target = await _spawn(MERC, ANCHOR + Vector3i(3, 0, 0))
	var bystander = await _spawn(MERC, ANCHOR + Vector3i(0, 0, 3))

	# Dropped off the ceiling on purpose. `compute_accuracy` clamps to [1, 99], and
	# a merc at this range shoots well past 99 unsuppressed — so the -40 would be
	# swallowed by the clamp and the check would pass on any penalty over ~11,
	# testing nothing. Perception is the cheapest term to lower to get a reading
	# in the middle of the range where the subtraction is actually visible.
	target.stats.perception = 10
	var before: int = _combat.compute_accuracy(target, shooter, 0)
	_check(before < 99, "target's unsuppressed accuracy is off the clamp (%d%%)" % before)

	await shooter.do_suppress(target)
	_check(target.is_suppressed(), "the target is suppressed")
	_check(not bystander.is_suppressed(), "and a bystander is not")

	var after: int = _combat.compute_accuracy(target, shooter, 0)
	# Compared against the constant rather than a hardcoded number, so retuning
	# the penalty does not require editing this file.
	_check(after < before,
		"a pinned unit shoots worse (%d%% -> %d%%)" % [before, after])
	_check(before - after == _combat.SUPPRESSED_PENALTY or after == 1,
		"by exactly SUPPRESSED_PENALTY (%d), unless clamped at 1%%"
		% _combat.SUPPRESSED_PENALTY)

	# The AP half. Compared against the unit's OWN pool, since that is per-soldier.
	target.begin_activation()
	_check(target.ap == maxi(1, target.ap_pool() - target.SUPPRESSED_AP_PENALTY),
		"and starts its turn down %d AP (%d of %d)"
		% [target.SUPPRESSED_AP_PENALTY, target.ap, target.ap_pool()])
	_free([shooter, target, bystander])


## The XCOM duration rule: suppression lasts until the SUPPRESSOR acts again,
## not until the target does. The target taking a turn while pinned is the whole
## point of the mechanic, so it must survive that.
func _check_ends_on_the_suppressor_s_turn() -> void:
	var shooter = await _spawn(PLAYER, ANCHOR)
	var target = await _spawn(MERC, ANCHOR + Vector3i(3, 0, 0))
	await shooter.do_suppress(target)

	target.begin_activation()
	_check(target.is_suppressed(), "the pin survives the TARGET's activation")

	shooter.begin_activation()
	_check(not target.is_suppressed(), "and ends on the SUPPRESSOR's next one")
	_check(shooter.suppressing == null, "with the shooter's own link cleared too")
	_free([shooter, target])


## THE PAYOFF RULE. A pinned unit that moves eats the burst the suppressor was
## holding, and it lands at FULL accuracy — not the -30% a reserved Overwatch
## shot takes. That difference is the entire return on suppression costing more
## AP and three rounds than a snap shot, and it is invisible in play: routing the
## reaction through the overwatch path would still fire, still log, and still
## look correct on screen.
func _check_breaking_cover_draws_the_held_shot() -> void:
	var shooter = await _spawn(PLAYER, ANCHOR)
	var target = await _spawn(MERC, ANCHOR + Vector3i(3, 0, 0))
	var turns = root.get_node_or_null("TurnManager")
	await shooter.do_suppress(target)
	shooter.ammo = 5  # refilled after the burst, so the reaction has something to fire

	var before_ammo: int = shooter.ammo
	await turns.check_suppression_break(target)
	_check(shooter.ammo == before_ammo - 1,
		"breaking cover draws a shot (ammo %d -> %d)" % [before_ammo, shooter.ammo])
	_check(not target.is_suppressed(),
		"and the burst is spent — a pin fires once, then it is gone")

	# The penalty-free part, asserted against the alternative rather than against a
	# number: whatever OVERWATCH costs in accuracy, the reaction must not pay it.
	shooter.overwatch_reserve = 1  # the worst case, so the gap is at its widest
	var as_shot: int = _combat.compute_accuracy(shooter, target, 0)  # ShotAction.SHOOT
	var as_overwatch: int = _combat.compute_accuracy(shooter, target, 2)  # OVERWATCH
	_check(as_shot > as_overwatch,
		"a plain shot beats a minimally-reserved one (%d%% vs %d%%), which is what the reaction uses"
		% [as_shot, as_overwatch])

	# The reserve scale itself, which is what makes committing a whole activation
	# to an angle worth doing rather than reserving with the last spare AP.
	_check(_combat.overwatch_penalty_for(1) == _combat.OVERWATCH_PENALTY,
		"a 1 AP reserve pays the full overwatch penalty (%d)" % _combat.OVERWATCH_PENALTY)
	_check(_combat.overwatch_penalty_for(3) < _combat.overwatch_penalty_for(1),
		"a bigger reserve covers the angle better (%d vs %d)"
		% [_combat.overwatch_penalty_for(3), _combat.overwatch_penalty_for(1)])
	_check(_combat.overwatch_penalty_for(99) == 0,
		"and a full commitment cancels it — but never goes negative")
	_free([shooter, target])


## A corpse pins nobody — checked from both directions, because the back-link is
## the one a `is_downed` guard alone would leave dangling.
func _check_a_dead_suppressor_holds_nobody() -> void:
	var shooter = await _spawn(PLAYER, ANCHOR)
	var target = await _spawn(MERC, ANCHOR + Vector3i(3, 0, 0))
	await shooter.do_suppress(target)
	_check(target.is_suppressed(), "pinned to start with")

	shooter.take_damage(99999)
	_check(shooter.is_downed, "the suppressor goes down")
	_check(not target.is_suppressed(), "and its target is no longer pinned")
	_check(target.suppressed_by == null, "with the back-link cleared, not dangling")
	_free([shooter, target])


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
