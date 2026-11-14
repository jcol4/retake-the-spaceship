extends SceneTree
## Close quarters (docs/design/systems/close-quarters).
##
##   godot --headless --path . --script res://tools/test_close_quarters.gd
##
## Covers:
##   - the roster's engaged rule: SMG and Pistol -1 AP on Shoot, nothing on the
##     other four (the Battle Rifle's and LMG's accuracy penalties moved into
##     their distance tables, docs/design/systems/accuracy);
##   - what counts as engaged: a hostile within 3 tiles that the shooter can see;
##     not 4 tiles, not an ally, not a downed body;
##   - accuracy: being engaged no longer changes any gun's odds;
##   - AP: an engaged SMG/Pistol Shoot is 1 cheaper, stacking with a Laser Sight
##     to -2; nothing else is repriced; pricing at a tile the unit is not on;
##   - the AI pricing a shot where its plan leaves it (GoapBrain.shot_cost,
##     keeps_shot_at, Attack.ap_cost under GoapPlanner.PLAN_TILE).
##
## Classes are load()ed and locals stay untyped, as in test_goap.gd.

const PLAYER := "res://scenes/player_unit.tscn"
const SWARM := "res://scenes/swarm_unit.tscn"

## The dark hall of worm_test_deck: open floor x 7..32 (see test_penetration.gd).
const ROW := 7
const SHOOTER_X := 8

## WeaponPresets.WeaponId / AttachmentId / UnitStats.Action / Combat enums by value.
const ASSAULT_RIFLE := 0
const SHOTGUN := 1
const SMG := 2
const LMG := 3
const BATTLE_RIFLE := 4
const PISTOL := 5
const LASER_SIGHT := 2
const ACT_SHOOT := 0
const ACT_OVERWATCH := 6
const SHOOT := 0
const AIMED := 1
const OVERWATCH := 2
const TORSO := 1

var _failures := 0
var _grid: Node
var _combat
var _weapons
var _brain
var _planner
var _actions


func _initialize() -> void:
	_grid = root.get_node_or_null("GridManager")
	_combat = load("res://scripts/combat.gd")
	_weapons = load("res://scripts/weapon_presets.gd")
	_brain = load("res://scripts/ai/goap_brain.gd")
	_planner = load("res://scripts/ai/goap_planner.gd")
	_actions = load("res://scripts/ai/goap_actions.gd")
	var map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(map)
	await process_frame
	seed(4242)

	_check_roster()
	await _check_engaged()
	await _check_accuracy()
	await _check_ap()
	await _check_ai_pricing()

	print("")
	if _failures == 0:
		print("close quarters: ALL CHECKS PASSED")
		quit(0)
	else:
		print("close quarters: %d CHECK(S) FAILED" % _failures)
		quit(1)


func _check_roster() -> void:
	for id in [SMG, PISTOL]:
		var w = _weapons.make(id)
		_check(w.engaged_shoot_ap == -1 and w.has_engaged_rule(), "%s: Shoot 1 AP cheaper engaged" % w.display_name)
	# The Battle Rifle's and LMG's engaged accuracy penalties became their
	# distance tables (docs/design/systems/accuracy): no engaged rule left on them.
	for id in [ASSAULT_RIFLE, SHOTGUN, LMG, BATTLE_RIFLE]:
		var w = _weapons.make(id)
		_check(not w.has_engaged_rule(), "%s: no close-quarters rule" % w.display_name)


func _check_engaged() -> void:
	var shooter = await _shooter(SMG)
	_check(not shooter.is_engaged(), "nobody near: not engaged")
	var far = await _spawn(SWARM, SHOOTER_X + 4)
	_check(not shooter.is_engaged(), "a hostile 4 tiles off: not engaged")
	var ally = await _spawn(PLAYER, SHOOTER_X + 1)
	_check(not shooter.is_engaged(), "an ally next to it: not engaged")
	var near = await _spawn(SWARM, SHOOTER_X + 3, ROW - 1)
	_check(shooter.is_engaged(), "a hostile it can see 3 tiles off (diagonal counts 1): engaged")
	near.take_damage(9999)
	_check(near.is_downed and not shooter.is_engaged(), "the same hostile downed: not engaged")
	await _free([shooter, far, ally, near])


## Being engaged no longer moves accuracy for any gun: a Battle Rifle or LMG with
## a zombie at its elbow shoots a target 6 tiles off exactly as well as without
## one. Being bad up close is the distance to the TARGET now (test_accuracy.gd).
func _check_accuracy() -> void:
	var shooter = await _shooter(BATTLE_RIFLE)
	var target = await _spawn(SWARM, SHOOTER_X + 6)
	for id in [BATTLE_RIFLE, LMG, ASSAULT_RIFLE]:
		shooter._equip(id, PackedInt32Array(), -1)
		shooter.stats.perception = 50
		var base := _accs(shooter, target)
		var close = await _spawn(SWARM, SHOOTER_X + 2, ROW - 1)
		var engaged := _accs(shooter, target)
		_check(shooter.is_engaged() and engaged == base,
			"%s: same Shoot/Aimed/Overwatch odds engaged (%s)" % [shooter.stats.weapon.display_name, engaged])
		await _free([close])
	await _free([shooter, target])


## Shoot, Aimed (torso) and Overwatch accuracy, keyed by Combat.ShotAction value.
func _accs(shooter, target) -> Dictionary:
	var out := {}
	out[SHOOT] = _combat.compute_accuracy(shooter, target, SHOOT, TORSO)
	out[AIMED] = _combat.compute_accuracy(shooter, target, AIMED, TORSO)
	out[OVERWATCH] = _combat.compute_accuracy(shooter, target, OVERWATCH, TORSO)
	return out


func _check_ap() -> void:
	var shooter = await _shooter(SMG)
	var plain: int = shooter.action_cost(ACT_SHOOT)
	var overwatch: int = shooter.action_cost(ACT_OVERWATCH)
	var aimed: int = shooter.min_aimed_shot_cost()
	var near_tile := Vector3i(SHOOTER_X + 12, 0, ROW)
	var hostile = await _spawn(SWARM, SHOOTER_X + 14)
	_check(shooter.action_cost(ACT_SHOOT) == plain, "SMG, hostile far off: Shoot %d" % plain)
	_check(shooter.action_cost_at(ACT_SHOOT, near_tile) == plain - 1,
		"priced at a tile 2 from the hostile: %d" % (plain - 1))
	_check(shooter.grid_pos == Vector3i(SHOOTER_X, 0, ROW), "and the unit is back on its own tile")
	_check(shooter.cheapest_shot_cost() == plain - 1, "cheapest_shot_cost is the engaged price")
	var close = await _spawn(SWARM, SHOOTER_X + 2, ROW - 1)
	_check(shooter.action_cost(ACT_SHOOT) == plain - 1, "SMG engaged: Shoot %d -> %d" % [plain, plain - 1])
	_check(shooter.action_cost(ACT_OVERWATCH) == overwatch and shooter.min_aimed_shot_cost() == aimed,
		"Overwatch and Aimed Shot are not repriced")
	shooter._equip(SMG, PackedInt32Array([LASER_SIGHT]), -1)
	_check(shooter.action_cost(ACT_SHOOT) == plain - 2, "with a Laser Sight: -2 (%d)" % shooter.action_cost(ACT_SHOOT))
	shooter._equip(PISTOL, PackedInt32Array(), -1)
	var pistol_close: int = shooter.action_cost(ACT_SHOOT)
	await _free([close])
	_check(shooter.action_cost(ACT_SHOOT) == pistol_close + 1, "Pistol: 1 AP cheaper engaged")
	shooter._equip(BATTLE_RIFLE, PackedInt32Array(), -1)
	var br_plain: int = shooter.action_cost(ACT_SHOOT)
	close = await _spawn(SWARM, SHOOTER_X + 2, ROW - 1)
	_check(shooter.action_cost(ACT_SHOOT) == br_plain, "Battle Rifle: price unchanged engaged")
	await _free([shooter, hostile, close])


func _check_ai_pricing() -> void:
	var unit = await _shooter(SMG)
	var hostile = await _spawn(SWARM, SHOOTER_X + 8)
	var plain: int = unit.action_cost(ACT_SHOOT)
	var near_tile := Vector3i(SHOOTER_X + 5, 0, ROW)  # 3 from the hostile
	var far_tile := Vector3i(SHOOTER_X + 1, 0, ROW)  # 7 from it
	_check(_brain.shot_cost(unit, {}) == plain, "shot_cost outside planning: where it stands")
	var ctx := {_planner.PLAN_TILE: near_tile}
	_check(_brain.shot_cost(unit, ctx) == plain - 1, "shot_cost at the plan's tile: the engaged price")
	var attack = _actions.Attack.new()
	_check(attack.ap_cost(unit, ctx) == plain - 1, "Attack after a move is priced at the move's end")
	unit.ap = 3 * unit.move_ap_per_tile() + plain - 1
	_check(_brain.keeps_shot_at(unit, near_tile, 3), "3 tiles + an engaged shot fits exactly")
	_check(not _brain.keeps_shot_at(unit, far_tile, 3), "the same walk to an unengaged tile does not")
	await _free([unit, hostile])


func _shooter(weapon: int, x: int = SHOOTER_X):
	var u = await _spawn(PLAYER, x)
	u._equip(weapon, PackedInt32Array(), -1)
	u.stats.perception = 50
	u.stats.reflexes = 0
	u.stats.luck = 0
	return u


func _spawn(scene_path: String, x: int, z: int = ROW):
	var unit = load(scene_path).instantiate()
	unit.position = _grid.grid_to_world(Vector3i(x, 0, z))
	root.add_child(unit)
	await process_frame
	unit.stats.luck = 0
	unit.current_hp = 999
	var t = _grid.get_tile(unit.grid_pos)
	if t:
		t.light_value = 100.0
	return unit


func _free(units: Array) -> void:
	for unit in units:
		if is_instance_valid(unit):
			var t = _grid.get_tile(unit.grid_pos)
			if t and t.occupant == unit:
				_grid.set_occupant(unit.grid_pos, null)
			unit.remove_from_group("units")
			unit.remove_from_group("player_units")
			unit.queue_free()
	await process_frame


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
