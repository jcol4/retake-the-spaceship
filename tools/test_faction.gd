extends SceneTree
## The faction model, and specifically the claim that introducing it changed
## NOTHING about who shoots whom.
##
##   godot --headless --path . --script res://tools/test_faction.gd
##
## `Faction` replaced an `is_player_controlled` boolean, and the whole safety
## argument for doing that as its own commit is that the matrix reproduces the
## boolean's answers exactly. That argument is worth an assertion rather than a
## paragraph: the old rule was "hostile if the two booleans differ", so every
## pair below is checked against what that rule would have said.
##
## This is also the file that will FAIL, loudly and on purpose, on the day
## cross-faction hostility is switched on. That failure is the reminder to come
## back and decide what the new expected answers are, rather than letting a
## balance change land unannounced.
##
## `Faction` touches no autoload, so it is safe to name directly in a --script
## tool — see test_cerberus.gd for what happens with classes that aren't.

const PLAYER := "res://scenes/player_unit.tscn"
const SWARM := "res://scenes/swarm_unit.tscn"
const SECURUS := "res://scenes/securus_unit.tscn"
const MERC := "res://scenes/merc_unit.tscn"

const ANCHOR := Vector3i(7, 0, 6)

var _failures := 0
var _grid: Node


func _initialize() -> void:
	_grid = root.get_node_or_null("GridManager")
	var map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(map)
	await process_frame

	_check_matrix_matches_the_old_boolean()
	_check_nobody_fights_itself()
	await _check_units_carry_the_right_faction()
	await _check_hostiles_only_returns_enemies()
	await _check_mercs_do_not_fight_themselves()

	print("")
	if _failures == 0:
		print("faction: ALL CHECKS PASSED")
		quit(0)
	else:
		print("faction: %d CHECK(S) FAILED" % _failures)
		quit(1)


## THE CLAIM OF THE WHOLE REFACTOR. Old rule: hostile iff exactly one side was
## the player. Asserted over every ordered pair, so a stray edit to HOSTILE_TO
## cannot change the fight without this saying so.
func _check_matrix_matches_the_old_boolean() -> void:
	for a: int in Faction.Id.values():
		for b: int in Faction.Id.values():
			var a_is_player: bool = a == Faction.Id.CONTRACTORS
			var b_is_player: bool = b == Faction.Id.CONTRACTORS
			var old_rule: bool = a_is_player != b_is_player
			var now: bool = Faction.is_hostile(a, b)
			_check(now == old_rule, "%s vs %s: %s (old boolean said %s)" % [
				Faction.display_name(a), Faction.display_name(b),
				"hostile" if now else "not hostile",
				"hostile" if old_rule else "not hostile",
			])


## Hardcoded in `is_hostile` rather than trusted to the table, because a faction
## listed against itself would turn a squad on each other and the table is the
## kind of thing that gets edited in a hurry.
func _check_nobody_fights_itself() -> void:
	for a: int in Faction.Id.values():
		_check(not Faction.is_hostile(a, a),
			"%s is not hostile to itself" % Faction.display_name(a))


## The assignments themselves. CerberusUnit is the one that matters: it extends
## EnemyUnit, so it inherits the alien tier's `_init` and has to override the
## faction that sets — exactly the case the old boolean could not distinguish,
## since both resolved to "not the player".
func _check_units_carry_the_right_faction() -> void:
	var player = await _spawn(PLAYER, ANCHOR)
	var swarm = await _spawn(SWARM, ANCHOR + Vector3i(2, 0, 0))
	var robot = await _spawn(SECURUS, ANCHOR + Vector3i(4, 0, 0))

	_check(player.faction == Faction.Id.CONTRACTORS, "a player unit is a Contractor")
	_check(swarm.faction == Faction.Id.ALIENS, "a swarm is an Alien")
	_check(robot.faction == Faction.Id.SECURITY,
		"a Securus is Security, not an Alien, despite extending EnemyUnit")
	# The derived read-only convenience still answers for the paths that use it.
	_check(player.is_player_controlled, "and is_player_controlled still follows from it")
	_check(not swarm.is_player_controlled and not robot.is_player_controlled,
		"for both of the other two as well")

	_check(player.is_hostile_to(swarm) and player.is_hostile_to(robot),
		"the squad engages both hostile factions")
	_check(swarm.is_hostile_to(player) and robot.is_hostile_to(player),
		"and both engage the squad")
	# The gap this model exists to make statable. Expected to flip one day; when
	# it does, this line is the one to come back and rewrite.
	_check(not swarm.is_hostile_to(robot) and not robot.is_hostile_to(swarm),
		"aliens and robots still ignore each other (unchanged, for now)")

	_free([player, swarm, robot])


## `hostiles()` replaced the player_units/enemy_units group lookups that
## targeting used to read off. It must not pick up allies, and must not pick up
## the caller.
func _check_hostiles_only_returns_enemies() -> void:
	var player = await _spawn(PLAYER, ANCHOR)
	var mate = await _spawn(PLAYER, ANCHOR + Vector3i(1, 0, 0))
	var swarm = await _spawn(SWARM, ANCHOR + Vector3i(2, 0, 0))
	var robot = await _spawn(SECURUS, ANCHOR + Vector3i(4, 0, 0))

	var seen: Array = player.hostiles()
	_check(swarm in seen and robot in seen, "a soldier sees both hostile factions")
	_check(not (mate in seen) and not (player in seen),
		"and neither its squadmate nor itself")

	var alien_seen: Array = swarm.hostiles()
	_check(player in alien_seen and mate in alien_seen,
		"a swarm sees the whole squad (%d)" % alien_seen.size())
	_check(not (robot in alien_seen), "and not the robot beside it")

	# A downed unit is not a target. `hostiles()` filters it, which is what the
	# old per-call `is_downed` checks at each call site were doing.
	swarm.is_downed = true
	_check(not (swarm in player.hostiles()), "a downed hostile drops out of the set")

	_free([player, mate, swarm, robot])


## REGRESSION GUARD, for a bug the smoke test caught the moment mercs first
## walked onto a deck: they opened fire on themselves.
##
## The cause was an assumption, not a typo. `EnemyUnit._on_lighting_changed`
## treats a beam landing on the unit as an intruder's, which was safe for as long
## as every unit carrying that state machine was an alien with no light of its
## own — so the only beam that could ever reach one belonged to the player. Mercs
## are human, they carry rig lights, and a rig light lights its own tile: each
## merc read its own beam as a contact, entered Combat against itself, and shot
## itself. A squadmate's beam did the same.
##
## The fix is the hostility guard asserted here, so the property under test is
## "a merc is never a valid target for a merc" rather than any particular line of
## lighting code.
func _check_mercs_do_not_fight_themselves() -> void:
	var merc = await _spawn(MERC, ANCHOR)
	var mate = await _spawn(MERC, ANCHOR + Vector3i(1, 0, 0))
	var player = await _spawn(PLAYER, ANCHOR + Vector3i(3, 0, 0))

	_check(merc.faction == Faction.Id.RIVAL_MERCS, "a merc is a Rival Merc")
	# The property that made the bug reachable at all. Asserted so nobody
	# "tidies" it away later without meeting this test.
	_check(merc.has_flashlight,
		"and carries a light, unlike the aliens sharing its base class")

	_check(not merc.is_hostile_to(merc), "a merc is not a target to itself")
	_check(not merc.is_hostile_to(mate) and not mate.is_hostile_to(merc),
		"nor is its squadmate")
	_check(not (merc in merc.hostiles()) and not (mate in merc.hostiles()),
		"so neither shows up in its hostiles()")
	_check(merc.is_hostile_to(player) and player.is_hostile_to(merc),
		"while the squad and the mercs do engage each other")

	_free([merc, mate, player])


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
