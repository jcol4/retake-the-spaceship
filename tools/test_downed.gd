extends SceneTree
## Extraction plan Phase 2.1, 2.2 and 2.4: the downed bar, death, revive, the
## squad wipe, and who finishes a body (GDD §4.4).
##
##   godot --headless --path . --script res://tools/test_downed.gd
##
## Rule by rule, on real units on the test deck:
##   - the downed bar starts at max HP and carries ACROSS downs (a revive does not
##     refill it);
##   - it drains ceil(max HP / 5) at each round start, and damage while downed
##     comes off it too;
##   - the third down kills on the spot, and an empty bar kills;
##   - revive: 3 AP, reach, back up at ceil(25%), down count kept, out of this
##     round's pool; onto a free neighbour of the reviver when the body's tile is
##     taken, and refused when there is none;
##   - cross-owner revive (GDD §7.6): the other player's soldier, still theirs;
##   - mercs, aliens and robots die outright;
##   - no soldier standing = WIPED, everyone lost;
##   - DOWNED_POLICY: aliens finish (but a live threat in sight comes first),
##     mercs only cheaply, robots never.
##
## Scripts and enums are load()ed: a --script tool is compiled before the class
## registry and autoloads exist (see test_cerberus.gd).

const PLAYER := "res://scenes/player_unit.tscn"
const MERC := "res://scenes/merc_unit.tscn"
const SWARM := "res://scenes/swarm_unit.tscn"
const SECURUS := "res://scenes/securus_unit.tscn"

const ANCHOR := Vector3i(7, 0, 6)

## UnitStats.Action by value (append-only enum; see test_suppression.gd).
const ACTION_SHOOT := 0
const ACTION_REVIVE := 7

var _failures := 0
var _grid: Node
var _turns: Node
var LIFE  # Unit.LifeState
var _unit_script
var MR  # MissionResult script
var _results: Array = []


func _initialize() -> void:
	_grid = root.get_node_or_null("GridManager")
	_turns = root.get_node_or_null("TurnManager")
	_unit_script = load("res://scripts/unit.gd")
	LIFE = _unit_script.LifeState
	MR = load("res://scripts/mission_result.gd")
	var map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(map)
	await process_frame
	_turns.mission_ended.connect(func(r) -> void: _results.append(r))
	seed(20261010)

	await _check_bar_starts_full_and_only_soldiers_go_down()
	await _check_damage_while_downed_and_bleed()
	await _check_bar_carries_across_downs_and_third_down_kills()
	await _check_empty_bar_kills()
	await _check_revive()
	await _check_revive_onto_occupied_tile()
	await _check_cross_owner_revive()
	await _check_outright_deaths()
	await _check_squad_wipe()
	await _check_downed_policy_tables()
	await _check_aliens_finish_downed()
	await _check_mercs_finish_only_when_cheap()

	print("")
	if _failures == 0:
		print("downed: ALL CHECKS PASSED")
		quit(0)
	else:
		print("downed: %d CHECK(S) FAILED" % _failures)
		quit(1)


func _check_bar_starts_full_and_only_soldiers_go_down() -> void:
	var soldier = await _spawn(PLAYER, ANCHOR)
	var max_hp: int = soldier.stats.max_hp()
	_check(soldier.can_be_downed, "a soldier can be downed")
	_check(soldier.downed_hp == max_hp and soldier.downed_bar_max() == max_hp,
		"the downed bar starts full, the size of max HP (%d/%d)" % [soldier.downed_hp, max_hp])
	_check(soldier.down_count == 0, "with no downs yet")
	soldier.take_damage(max_hp + 50)
	_check(soldier.life_state == LIFE.DOWNED, "0 HP downs a soldier")
	_check(soldier.down_count == 1, "and counts the down")
	_check(soldier.downed_hp == max_hp, "an overkill does not touch the downed bar")
	_check(_grid.is_free(soldier.grid_pos), "a downed body holds no tile")
	_free([soldier])


func _check_damage_while_downed_and_bleed() -> void:
	var soldier = await _spawn(PLAYER, ANCHOR)
	var max_hp: int = soldier.stats.max_hp()
	soldier.take_damage(9999)
	soldier.take_damage(3)
	_check(soldier.downed_hp == max_hp - 3,
		"damage while downed comes off the downed bar (%d)" % soldier.downed_hp)
	var drain := ceili(max_hp / 5.0)
	_check(soldier.bleed_amount() == drain, "the bleed is ceil(max HP / 5) = %d" % drain)
	var before: int = soldier.downed_hp
	_turns._bleed_downed()  # what every round start runs
	_check(soldier.downed_hp == before - drain,
		"one round start drains it by that (%d -> %d)" % [before, soldier.downed_hp])
	_check(soldier.life_state == LIFE.DOWNED, "and the soldier is still only downed")
	_free([soldier])


func _check_bar_carries_across_downs_and_third_down_kills() -> void:
	var soldier = await _spawn(PLAYER, ANCHOR)
	var max_hp: int = soldier.stats.max_hp()
	soldier.take_damage(9999)
	soldier.bleed_out_tick()
	var left: int = soldier.downed_hp
	soldier.revive_at(soldier.grid_pos)
	_check(soldier.life_state == LIFE.ACTIVE, "revived")
	_check(soldier.downed_hp == left, "a revive does NOT refill the downed bar (%d/%d)" % [left, max_hp])
	soldier.take_damage(9999)
	_check(soldier.life_state == LIFE.DOWNED and soldier.down_count == 2,
		"a second down is still a down (count %d)" % soldier.down_count)
	_check(soldier.downed_hp == left, "and starts from what the first left (%d)" % soldier.downed_hp)
	soldier.revive_at(soldier.grid_pos)
	soldier.take_damage(9999)
	_check(soldier.life_state == LIFE.DEAD, "the third down kills on the spot")
	_check(soldier.downed_hp > 0, "even with bar left (%d) — it is the count that kills" % soldier.downed_hp)
	_check(soldier.take_damage(10) == 0, "a corpse takes no damage")
	_free([soldier])


func _check_empty_bar_kills() -> void:
	var a = await _spawn(PLAYER, ANCHOR)
	a.take_damage(9999)
	a.take_damage(a.downed_hp)
	_check(a.life_state == LIFE.DEAD, "damage that empties the downed bar kills")

	var b = await _spawn(PLAYER, ANCHOR + Vector3i(2, 0, 0))
	b.take_damage(9999)
	var rounds := 0
	while b.life_state == LIFE.DOWNED and rounds < 20:
		_turns._bleed_downed()
		rounds += 1
	_check(b.life_state == LIFE.DEAD, "an untended soldier bleeds out")
	_check(rounds == ceili(float(b.downed_bar_max()) / b.bleed_amount()),
		"in max/drain rounds — five on a full bar (%d)" % rounds)
	_free([a, b])


func _check_revive() -> void:
	var medic = await _spawn(PLAYER, ANCHOR)
	var body = await _spawn(PLAYER, ANCHOR + Vector3i(1, 0, 0))
	var far = await _spawn(PLAYER, ANCHOR + Vector3i(4, 0, 0))
	body.take_damage(9999)
	_check(far.revive_blocker(body) == "out of reach", "revive needs reach (got '%s')" % far.revive_blocker(body))
	_check(medic.revive_blocker(body) == "", "an adjacent squadmate can revive")
	_check(medic.action_cost(ACTION_REVIVE) == 3, "revive is 3 AP flat")
	_turns.pool.append(body)  # as if it had gone down earlier in this round
	medic.ap = 10
	await medic.try_revive(body)
	_check(body.life_state == LIFE.ACTIVE, "try_revive stands them up")
	_check(medic.ap == 7, "for 3 AP (%d left)" % medic.ap)
	var expect := ceili(body.stats.max_hp() * 0.25)
	_check(body.current_hp == expect, "at ceil(25%%) of max HP (%d, want %d)" % [body.current_hp, expect])
	_check(body.down_count == 1, "keeping the down count")
	_check(_grid.get_tile(body.grid_pos).occupant == body, "holding its tile again")
	_check(not (body in _turns.pool), "and out of this round's pool — it acts next round")
	_turns.pool.clear()

	medic.ap = 2
	body.take_damage(9999)
	await medic.try_revive(body)
	_check(body.life_state == LIFE.DOWNED, "no revive without 3 AP")
	_free([medic, body, far])


## Plan A3: a body holds no tile, so somebody may stand on it.
func _check_revive_onto_occupied_tile() -> void:
	var body = await _spawn(PLAYER, ANCHOR)
	body.take_damage(9999)
	# The medic walks onto the body's tile — bodies do not block.
	var medic = await _spawn(PLAYER, ANCHOR + Vector3i(0, 0, 2))
	await medic.move_along([ANCHOR + Vector3i(0, 0, 1), ANCHOR] as Array[Vector3i])
	_check(medic.grid_pos == ANCHOR, "the medic is standing on the body")
	var tile: Vector3i = medic.revive_tile_for(body)
	_check(tile != ANCHOR and _grid.is_melee_adjacent(medic.grid_pos, tile) and _grid.is_free(tile),
		"revive picks a free tile next to the reviver (%s)" % tile)
	medic.ap = 10
	await medic.try_revive(body)
	_check(body.life_state == LIFE.ACTIVE and body.grid_pos == tile,
		"and stands the body up there")
	_check(_grid.get_tile(ANCHOR).occupant == medic, "without displacing the medic")

	# Box the medic in: every neighbour taken. Then there is nowhere to stand them.
	body.take_damage(9999)
	body.grid_pos = ANCHOR
	var blockers := []
	for n in _grid.neighbors(ANCHOR):
		if _grid.is_free(n):
			blockers.append(await _spawn(MERC, n))
	_check(medic.revive_blocker(body) == "no room to stand them up",
		"with every neighbour taken, revive is refused ('%s')" % medic.revive_blocker(body))
	_free([body, medic] + blockers)


## GDD §7.6: either player revives either player's soldiers.
func _check_cross_owner_revive() -> void:
	var medic = await _spawn(PLAYER, ANCHOR)
	var theirs = await _spawn(PLAYER, ANCHOR + Vector3i(1, 0, 0))
	medic.owner_peer_id = 1
	theirs.owner_peer_id = 2
	theirs.take_damage(9999)
	_check(medic.revive_blocker(theirs) == "", "peer 1's soldier can revive peer 2's")
	medic.ap = 10
	await medic.try_revive(theirs)
	_check(theirs.life_state == LIFE.ACTIVE, "and does")
	_check(theirs.owner_peer_id == 2, "and the revived soldier is still peer 2's")
	_free([medic, theirs])


func _check_outright_deaths() -> void:
	var merc = await _spawn(MERC, ANCHOR)
	var swarm = await _spawn(SWARM, ANCHOR + Vector3i(2, 0, 0))
	var robot = await _spawn(SECURUS, ANCHOR + Vector3i(4, 0, 0))
	var died := []
	var kinds := {merc: "a merc", swarm: "an alien", robot: "a robot"}
	for u in [merc, swarm, robot]:
		_check(not u.can_be_downed, "%s cannot be downed" % kinds[u])
		u.died.connect(func(x) -> void: died.append(x))
		u.take_damage(99999)
	_check(merc.life_state == LIFE.DEAD, "a rival merc dies outright at 0 HP")
	_check(swarm.life_state == LIFE.DEAD, "an alien dies outright")
	_check(robot.life_state == LIFE.DEAD, "a robot dies outright")
	_check(died.size() == 3, "each emits died once (%d)" % died.size())
	_check(merc.is_downed and not (merc in merc.allies()), "and is out of every live-unit query")
	_free([merc, swarm, robot])


func _check_squad_wipe() -> void:
	var a = await _spawn(PLAYER, ANCHOR)
	var b = await _spawn(PLAYER, ANCHOR + Vector3i(2, 0, 0))
	var c = await _spawn(PLAYER, ANCHOR + Vector3i(4, 0, 0))
	var swarm = await _spawn(SWARM, ANCHOR + Vector3i(0, 0, 3))
	_turns.clear_out_mode = false
	_turns.mission_over = false
	_results.clear()
	a.take_damage(9999)
	b.take_damage(9999)
	_check(not _turns._check_end_conditions(), "one soldier standing: the mission goes on")
	c.take_damage(9999)
	c.take_damage(9999)
	c.take_damage(9999)  # dead, for a mixed board
	_check(_turns._check_end_conditions(), "nobody standing ends it")
	_check(_results.size() == 1 and _results[0].outcome == MR.Outcome.WIPED, "as WIPED")
	if _results.size() == 1:
		var r = _results[0]
		_check(r.extracted_units.is_empty() and r.lost_units.size() == 3
			and a in r.lost_units and b in r.lost_units and c in r.lost_units,
			"with every deployed soldier lost (%d)" % r.lost_units.size())
	_turns.mission_over = false
	_turns.clear_out_mode = true
	_free([a, b, c, swarm])


func _check_downed_policy_tables() -> void:
	var F = load("res://scripts/faction.gd")
	_check(F.downed_policy(F.Id.ALIENS) == F.DownedPolicy.ALWAYS, "aliens: ALWAYS")
	_check(F.downed_policy(F.Id.RIVAL_MERCS) == F.DownedPolicy.OPPORTUNISTIC, "mercs: OPPORTUNISTIC")
	_check(F.downed_policy(F.Id.SECURITY) == F.DownedPolicy.NEVER, "Cerberus: NEVER")
	var body = await _spawn(PLAYER, ANCHOR)
	var swarm = await _spawn(SWARM, ANCHOR + Vector3i(2, 0, 0))
	var merc = await _spawn(MERC, ANCHOR + Vector3i(3, 0, 0))
	var robot = await _spawn(SECURUS, ANCHOR + Vector3i(4, 0, 0))
	body.take_damage(9999)
	_check(not (body in swarm.hostiles()), "a downed soldier is not in hostiles()")
	_check(body in swarm.downed_targets(), "but is in an alien's downed_targets()")
	_check(body in merc.downed_targets(), "and a merc's")
	_check(robot.downed_targets().is_empty(), "and never a robot's")
	_check(swarm.finishes_downed() and not merc.finishes_downed() and not robot.finishes_downed(),
		"only the aliens lock onto a body")
	# A robot that had the soldier as its target lets go.
	robot.alert_state = robot.AlertState.COMBAT
	robot.target = body
	_check(robot.acquire_target() == null, "a robot drops a target that goes down")
	_free([body, swarm, merc, robot])


func _check_aliens_finish_downed() -> void:
	var body = await _spawn(PLAYER, ANCHOR)
	var swarm = await _spawn(SWARM, ANCHOR + Vector3i(1, 0, 0))
	_light([ANCHOR, ANCHOR + Vector3i(1, 0, 0), ANCHOR + Vector3i(0, 0, 3)])
	body.take_damage(9999)
	swarm.alert_state = swarm.AlertState.COMBAT
	swarm.target = body
	_check(swarm.acquire_target() == body, "an alien keeps a target that goes down — prey")
	var before: int = body.downed_hp
	swarm.ap = 60
	await swarm._combat_turn()
	_check(body.downed_hp < before or body.life_state == LIFE.DEAD,
		"and claws the body (downed bar %d -> %d)" % [before, body.downed_hp])

	# A live soldier in sight outranks the body.
	var body2 = await _spawn(PLAYER, ANCHOR + Vector3i(2, 0, 0))
	body2.take_damage(9999)
	var live = await _spawn(PLAYER, ANCHOR + Vector3i(4, 0, -1))
	# After the spawn: its flashlight recomputes the light map, which would
	# overwrite a value set any earlier.
	_light([ANCHOR + Vector3i(4, 0, -1)])
	swarm.target = body2
	swarm.alert_state = swarm.AlertState.COMBAT
	_check(swarm.acquire_target() == live, "but a live soldier in sight is the better target")

	# An alien with nothing alive in sight finds a body on the deck.
	var lurker = await _spawn(SWARM, ANCHOR + Vector3i(-1, 0, 0))
	_free([live])
	await process_frame
	lurker.alert_state = lurker.AlertState.UNAWARE
	lurker._look_for_targets()
	_check(lurker.alert_state == lurker.AlertState.COMBAT and lurker.target != null
		and lurker.target.is_downed, "an Unaware alien that sees a lit body goes for it")
	_free([body, body2, swarm, lurker])


func _check_mercs_finish_only_when_cheap() -> void:
	var body = await _spawn(PLAYER, ANCHOR)
	var merc = await _spawn(MERC, ANCHOR + Vector3i(4, 0, 0))
	merc.stats.weapon = load("res://scripts/weapon_presets.gd").make(2)  # SMG, as the presets give mercs
	merc.ammo = merc.stats.mag_size
	merc.reserve = -1
	body.take_damage(9999)
	merc.ap = 20
	var before: int = merc.ap
	await merc._finish_downed_if_cheap()
	_check(merc.ap < before, "a merc with nothing live in sight spends spare AP on a body (%d -> %d)" % [before, merc.ap])

	body.take_damage(0)
	var live = await _spawn(PLAYER, ANCHOR + Vector3i(2, 0, 2))
	merc.ap = 20
	merc.ammo = merc.stats.mag_size
	await merc._finish_downed_if_cheap()
	_check(merc.ap == 20, "but not with a live contractor in its sight")
	merc.ap = merc.action_cost(ACTION_SHOOT) - 1
	_free([live])
	await process_frame
	await merc._finish_downed_if_cheap()
	_check(merc.ap == merc.action_cost(ACTION_SHOOT) - 1, "nor without the AP for the shot where it stands")
	_free([body, merc])


func _light(tiles: Array) -> void:
	for t in tiles:
		var tile = _grid.get_tile(t)
		if tile:
			tile.light_value = 100.0


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
			unit.queue_free()


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
