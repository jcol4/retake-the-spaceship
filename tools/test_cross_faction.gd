extends SceneTree
## Extraction plan Phase 7: cross-faction hostility (GDD §11.0).
##
##   godot --headless --path . --script res://tools/test_cross_faction.gd
##
## Covers:
##   - the rules (CrossFactionRules): Cerberus's faction-blind threat ranking and
##     its switch hysteresis, the mercs' "is this fight worth it" table, the
##     avoidance surcharge and the route-blocking test;
##   - an alien next to a robot with no contractor anywhere: they fight. The
##     robot's motion sensor picks up the alien in the dark; the alien cannot see
##     an unlit robot, but being shot tells it exactly who to go for;
##   - the robots rank intruders by threat and re-prioritise onto whoever fires
##     on the network (zone memory in SecurityNetwork);
##   - a merc ignores a distant, unaware robot that is not on its route; engages
##     one that is in the way, close to the squad, or hunting the squad; breaks
##     off a third-party fight that stopped being worth it; never skips the
##     player crew; and routes around a known third party instead of past it;
##   - overwatch already asks `is_hostile_to`, so a robot's reserved shot fires
##     on a moving alien (plan 7.4).
##
## Runs on maps/test_deck.txt (set explicitly: the scene defaults to the worm deck) with units spawned by
## hand, and drives activations directly, so it is deterministic. Autoload-
## touching scripts are load()ed (see test_cerberus.gd); CrossFactionRules and
## Faction touch none and are named directly.

const ALIEN := "res://scenes/enemy_unit.tscn"
const SWARM := "res://scenes/swarm_unit.tscn"
const SAGITTARII := "res://scenes/sagittarii_unit.tscn"
const MERC := "res://scenes/merc_unit.tscn"
const PLAYER := "res://scenes/player_unit.tscn"
const DECK := "res://maps/test_deck.txt"

## Middle compartment of the test deck (x 6-13, z 1-12).
const MID := Vector3i(7, 0, 2)
## Left compartment (x 1-4, z 1-12); its one doorway is (5,7), into the middle.
const LEFT_TOP := Vector3i(2, 0, 1)
const DOORWAY := Vector3i(5, 0, 7)

var _failures := 0
var _grid: Node
var _tm: Node
var _net: Node
var _map
var _alien_presets
var _cerberus_presets
var _merc_presets
var _spawn_kind_sagittarii: int
var _log: Array[String] = []


func _initialize() -> void:
	_grid = root.get_node_or_null("GridManager")
	_tm = root.get_node_or_null("TurnManager")
	_net = root.get_node_or_null("SecurityNetwork")
	_alien_presets = load("res://scripts/alien_presets.gd")
	_cerberus_presets = load("res://scripts/cerberus_presets.gd")
	_merc_presets = load("res://scripts/merc_presets.gd")
	_spawn_kind_sagittarii = load("res://scripts/map_data.gd").Spawn.SAGITTARII
	_map = load("res://scenes/test_map.tscn").instantiate()
	_map.layout_path = DECK
	root.add_child(_map)
	await process_frame
	await physics_frame
	await physics_frame
	seed(7007)
	_tm.mission_over = false
	_tm.turn_number = 10

	_check_rules()
	await _check_alien_and_robot_fight()
	await _check_robot_ranks_by_threat()
	await _check_merc_ignores_distant_robot()
	await _check_merc_engages_when_worth_it()
	await _check_merc_routes_around()
	await _check_overwatch_across_factions()

	print("")
	if _failures == 0:
		print("cross_faction: ALL CHECKS PASSED")
		quit(0)
	else:
		print("cross_faction: %d CHECK(S) FAILED" % _failures)
		quit(1)


# --- Pure rules ---------------------------------------------------------------


func _check_rules() -> void:
	print("-- rules")
	var R = CrossFactionRules
	# Every pair hostile, both ways, never self.
	var all_ok := true
	for a: int in Faction.Id.values():
		for b: int in Faction.Id.values():
			if Faction.is_hostile(a, b) != (a != b):
				all_ok = false
	_check(all_ok, "Faction matrix: every faction hostile to every other, never itself")

	# Cerberus threat. Each term on its own raises the score.
	var base := R.intruder_threat(6, false, false, false)
	_check(R.intruder_threat(6, true, false, false) > base, "armed raises threat")
	_check(R.intruder_threat(6, false, true, false) > base, "moving raises threat")
	_check(R.intruder_threat(6, false, false, true) > base, "having fired on the network raises threat")
	_check(R.intruder_threat(2, false, false, false) > base, "closer raises threat")
	_check(R.intruder_threat(40, false, false, false) == 0.0, "proximity never goes negative far away")
	# The ordering the design leans on: a far shooter beats a near bystander.
	_check(R.intruder_threat(8, true, false, true) > R.intruder_threat(1, false, true, false),
		"a far intruder that fired on the net outranks a near one that did nothing")
	_check(R.intruder_threat(7, true, false, false) > R.intruder_threat(3, false, false, false),
		"an armed intruder outranks a slightly closer unarmed one")
	# Hysteresis.
	_check(not R.should_switch(5.0, 5.0 + R.THREAT_SWITCH_MARGIN - 0.5), "a marginally bigger threat does not pull a robot")
	_check(R.should_switch(5.0, 5.0 + R.THREAT_SWITCH_MARGIN), "a clearly bigger one does")
	_check(R.THREAT_ATTACKED_NETWORK > R.THREAT_SWITCH_MARGIN, "firing on the network always clears the switch margin")

	# Mercs.
	_check(R.merc_engages(Faction.Id.CONTRACTORS, false, false, 99), "mercs always engage the player crew")
	for f: int in [Faction.Id.ALIENS, Faction.Id.SECURITY]:
		var n := Faction.display_name(f)
		_check(not R.merc_engages(f, false, false, R.MERC_ENGAGE_RADIUS + 1), "mercs leave a distant, unaware, out-of-the-way %s alone" % n)
		_check(R.merc_engages(f, true, false, 99), "mercs engage %s that has found them" % n)
		_check(R.merc_engages(f, false, true, 99), "mercs engage %s in their way" % n)
		_check(R.merc_engages(f, false, false, R.MERC_ENGAGE_RADIUS), "mercs engage %s within %d tiles" % [n, R.MERC_ENGAGE_RADIUS])

	# Avoidance and blocking.
	var hz: Array = [Vector3i(5, 0, 5)]
	_check(R.avoid_penalty(Vector3i(7, 0, 5), hz) == R.MERC_AVOID_PENALTY, "a tile within the avoid radius costs extra")
	_check(R.avoid_penalty(Vector3i(8, 0, 5), hz) == 0, "one beyond it does not")
	_check(R.avoid_penalty(Vector3i(5, 1, 5), hz) == 0, "nor one on another floor")
	var route: Array = []
	for x in range(1, 12):
		route.append(Vector3i(x, 0, 0))
	_check(R.blocks_route(Vector3i(3, 0, 1), route), "a hostile beside the next stretch of route blocks it")
	_check(not R.blocks_route(Vector3i(3, 0, 2), route), "one two tiles off does not")
	_check(not R.blocks_route(Vector3i(R.MERC_ROUTE_LOOKAHEAD + 3, 0, 0), route),
		"one beyond the lookahead does not (yet): it can still be routed around")


# --- Alien vs robot -------------------------------------------------------------


func _check_alien_and_robot_fight() -> void:
	print("-- an alien next to a robot, no contractors: they fight")
	var alien = await _spawn(ALIEN, MID, _alien_presets.ranged("Alien_X"))
	var robot = await _spawn_robot(MID + Vector3i(2, 0, 0), 3)
	_tm.turn_number = 10
	# Both stood still: the robot's motionless range still covers 2 tiles.
	alien.last_moved_turn = -100
	robot.last_moved_turn = -100
	_light(robot.grid_pos, 0.0)
	_light(alien.grid_pos, 0.0)
	_check(alien.is_hostile_to(robot) and robot.is_hostile_to(alien), "they are hostile to each other")
	_check(robot._can_see(alien), "the robot's sensors pick up the alien in the dark")
	_check(not alien._can_see(robot), "the alien cannot make out an unlit robot")
	_light(robot.grid_pos, 100.0)
	_check(alien._can_see(robot), "but sees one standing in the light")
	_light(robot.grid_pos, 0.0)

	_log.clear()
	robot.begin_activation()
	await robot.take_turn()
	_check(robot.alert_state == 2 and robot.target == alien,
		"the robot engages the alien on its own activation (state %d)" % robot.alert_state)
	var robot_fired := _logged_by(robot.stats.display_name, "Alien_X")
	_check(robot_fired, "and opens fire on it")
	_check(alien.alert_state == 2 and alien.target == robot,
		"being shot tells the alien who to go for, light or no light")

	_log.clear()
	var hp_before: int = robot.current_hp
	alien.begin_activation()
	await alien.take_turn()
	_check(_logged("fired at %s" % robot.stats.display_name) or _logged("aims at %s" % robot.stats.display_name)
		or _logged("suppressing fire on %s" % robot.stats.display_name),
		"the alien fights back on its own activation")
	print("    (robot HP %d -> %d)" % [hp_before, robot.current_hp])
	await _free([alien, robot])


# --- Cerberus threat ranking -----------------------------------------------------


func _check_robot_ranks_by_threat() -> void:
	print("-- a robot ranks intruders by threat, not species or distance alone")
	var robot = await _spawn_robot(MID, 5)
	var swarm = await _spawn(SWARM, MID + Vector3i(1, 0, 1), _alien_presets.swarm("Swarm_X"))
	var merc = await _spawn(MERC, MID + Vector3i(4, 0, 0), _merc_presets.rifleman("Merc_X", false))
	merc.patrols = false
	for u in [robot, swarm, merc]:
		u.last_moved_turn = -100
	_check(robot._can_see(swarm) and robot._can_see(merc), "both intruders are within its sensors")
	robot._look_for_targets()
	_check(robot.target == merc, "the armed merc 4 tiles off outranks the unarmed Fodder beside it (got %s)" % _name(robot.target))
	# The Fodder claws the robot: a hostile act against the network.
	robot.come_under_fire(swarm)
	_check(_net.is_aggressor(5, swarm), "the network remembers who attacked it, by zone")
	_check(not _net.is_aggressor(6, swarm), "and only on that zone")
	robot._look_for_targets()
	_check(robot.target == swarm, "the robot re-prioritises onto the attacker (got %s)" % _name(robot.target))
	_net.clear_aggression()
	_check(not _net.is_aggressor(5, swarm), "clear_aggression forgets it (start of mission)")
	await _free([robot, swarm, merc])


# --- Mercs ------------------------------------------------------------------------


func _check_merc_ignores_distant_robot() -> void:
	print("-- a merc ignores a distant, unaware robot that is not on its route")
	var merc = await _spawn(MERC, LEFT_TOP, _merc_presets.rifleman("Merc_A", false))
	merc.patrols = false
	var robot = await _spawn_robot(LEFT_TOP + Vector3i(0, 0, 6), 1)
	robot.last_moved_turn = -100
	_light(robot.grid_pos, 100.0)
	_check(merc._can_see(robot), "the merc can see the robot (lit, in line of sight)")
	_check(robot.alert_state == 0, "the robot is unaware")
	_check(not merc.will_engage(robot), "the merc would not pick that fight")
	merc._look_for_targets()
	_check(merc.alert_state != 2, "so it does not engage (state %d)" % merc.alert_state)
	# The squad's priority layer skips it too.
	_check(not (robot in merc.engageable_hostiles()) and robot in merc.hostiles(),
		"it is hostile, just not engageable")
	await _free([merc, robot])


func _check_merc_engages_when_worth_it() -> void:
	print("-- a merc engages when it is worth it, and breaks off when it is not")
	var merc = await _spawn(MERC, LEFT_TOP, _merc_presets.rifleman("Merc_B", false))
	merc.patrols = false
	var robot = await _spawn_robot(LEFT_TOP + Vector3i(0, 0, 6), 1)
	robot.last_moved_turn = -100
	_light(robot.grid_pos, 100.0)

	# Close to a squad member.
	robot.relocate_to(LEFT_TOP + Vector3i(0, 0, CrossFactionRules.MERC_ENGAGE_RADIUS))
	_light(robot.grid_pos, 100.0)
	merc._look_for_targets()
	_check(merc.alert_state == 2 and merc.target == robot, "a robot within %d tiles is engaged" % CrossFactionRules.MERC_ENGAGE_RADIUS)
	# It moves off again (and never noticed the merc): not worth the rounds.
	robot.relocate_to(LEFT_TOP + Vector3i(0, 0, 7))
	_light(robot.grid_pos, 100.0)
	_log.clear()
	merc._look_for_targets()
	_check(merc.alert_state == 0, "it breaks off once the robot is distant and unaware (state %d)" % merc.alert_state)
	_check(_logged("breaks off"), "and says so in the log")

	# Hunting the squad: the robot found the merc.
	robot._enter_combat(merc, "")
	_check(merc.will_engage(robot), "a robot hunting the squad is engaged however far")
	merc._look_for_targets()
	_check(merc.alert_state == 2 and merc.target == robot, "so the merc fights it")
	robot._set_state(0)
	merc._set_state(0)

	# Shot at: always engages the shooter, and keeps the fight while it is hit.
	merc._pending_hit = true
	merc.come_under_fire(robot)
	_check(merc.alert_state == 2 and merc.target == robot, "being shot at engages the shooter")
	merc._look_for_targets()
	_check(merc.alert_state == 2, "and a shooter that landed a hit stays worth fighting")
	merc._brain.blackboard.set_fact(load("res://scripts/ai/squad_coordinator.gd").hit_fact_key(robot), 0.0)
	merc._set_state(0)

	# In the way: a robot just past the only doorway out of the room, on the
	# patrol route, more than MERC_ENGAGE_RADIUS from the merc.
	merc.relocate_to(Vector3i(2, 0, 7))
	robot.relocate_to(Vector3i(6, 0, 7))
	_light(robot.grid_pos, 100.0)
	merc.patrols = true
	merc._brain.blackboard.set_fact("patrol_dest", Vector3i(10, 0, 7))
	merc._brain.blackboard.set_fact("patrol_dest_set", true)
	_check(_grid.chebyshev_dist(merc.grid_pos, robot.grid_pos) > CrossFactionRules.MERC_ENGAGE_RADIUS,
		"the robot is beyond the proximity radius")
	merc._look_for_targets()
	_check(CrossFactionRules.blocks_route(robot.grid_pos, merc._route_cache),
		"the patrol route through the doorway passes it (%d tiles)" % merc._route_cache.size())
	_check(merc.alert_state == 2 and merc.target == robot, "so the merc engages what blocks the job")
	merc._set_state(0)
	merc.patrols = false
	merc._brain.blackboard.set_fact("patrol_dest_set", false)

	# The player crew: always, and first.
	var soldier = await _spawn(PLAYER, Vector3i(3, 0, 10), null)
	_light(soldier.grid_pos, 100.0)
	robot.relocate_to(Vector3i(3, 0, 8))
	_light(robot.grid_pos, 100.0)
	merc.relocate_to(Vector3i(2, 0, 6))
	_check(merc.will_engage(soldier), "the player crew is always engageable")
	merc._look_for_targets()
	_check(merc.target == soldier, "and ranked ahead of a nearer robot (got %s)" % _name(merc.target))
	await _free([merc, robot, soldier])


func _check_merc_routes_around() -> void:
	print("-- a merc routes around a known third party")
	var merc = await _spawn(MERC, Vector3i(8, 0, 1), _merc_presets.rifleman("Merc_C", false))
	merc.patrols = false
	var robot = await _spawn_robot(Vector3i(8, 0, 6), 1)
	_light(robot.grid_pos, 100.0)
	# The middle compartment: wide enough (x 6-13) to swing around the robot.
	var dest := Vector3i(8, 0, 11)
	var plain: Array = _grid.find_path(merc.grid_pos, dest, 999)
	var routed: Array = merc._route_path(dest, false)
	_check(not plain.is_empty() and not routed.is_empty(), "both routes exist")
	_check(_closest(plain, robot.grid_pos) <= 1, "the shortest path brushes past the robot (%d)" % _closest(plain, robot.grid_pos))
	_check(_closest(routed, robot.grid_pos) >= 2, "the merc's route keeps its distance (%d)" % _closest(routed, robot.grid_pos))
	_check(routed[-1] == dest, "and still arrives")
	# Unseen hazards are not avoided: the radio shares what the squad SEES.
	_light(robot.grid_pos, 0.0)
	var dark: Array = merc._route_path(dest, false)
	_check(dark.size() == plain.size() and _closest(dark, robot.grid_pos) <= 1,
		"a robot standing in the dark is walked straight into")
	await _free([merc, robot])


# --- Overwatch ------------------------------------------------------------------


func _check_overwatch_across_factions() -> void:
	print("-- overwatch fires across factions (plan 7.4)")
	var robot = await _spawn_robot(MID, 2)
	var alien = await _spawn(ALIEN, MID + Vector3i(3, 0, 0), _alien_presets.ranged("Alien_OW"))
	robot.on_overwatch = true
	await _tm.check_overwatch(alien)
	_check(not robot.on_overwatch, "a robot's reserved shot is spent on a moving alien")
	var mate = await _spawn_robot(MID + Vector3i(0, 0, 2), 2)
	mate.on_overwatch = true
	await _tm.check_overwatch(robot)
	_check(mate.on_overwatch, "but never on another robot")
	await _free([robot, alien, mate])


# --- Helpers ---------------------------------------------------------------------


func _spawn(scene_path: String, at: Vector3i, stats):
	var unit = load(scene_path).instantiate()
	if stats != null:
		unit.stats = stats
	unit.position = _grid.grid_to_world(at)
	root.add_child(unit)
	await process_frame
	if unit.has_signal("action_logged"):
		unit.action_logged.connect(func(t: String) -> void: _log.append(t))
	return unit


func _spawn_robot(at: Vector3i, zone: int):
	var robot = load(SAGITTARII).instantiate()
	robot.stats = _cerberus_presets.make_stats(_spawn_kind_sagittarii, 1)
	robot.security_zone = zone
	robot.position = _grid.grid_to_world(at)
	root.add_child(robot)
	await process_frame
	robot.action_logged.connect(func(t: String) -> void: _log.append(t))
	return robot


## Written straight onto the tile, as test_cerberus does: nothing recomputes the
## lighting between here and the read.
func _light(tile: Vector3i, value: float) -> void:
	var t = _grid.get_tile(tile)
	if t != null:
		t.light_value = value


func _closest(path: Array, to: Vector3i) -> int:
	var best := 999
	for t: Vector3i in path:
		best = mini(best, _grid.chebyshev_dist(t, to))
	return best


func _logged(fragment: String) -> bool:
	for line in _log:
		if fragment in line:
			return true
	return false


func _logged_by(speaker: String, fragment: String) -> bool:
	for line in _log:
		if line.begins_with(speaker) and fragment in line:
			return true
	return false


func _name(unit) -> String:
	return unit.stats.display_name if unit != null else "nobody"


func _free(units: Array) -> void:
	for unit in units:
		if is_instance_valid(unit):
			_grid.set_occupant(unit.grid_pos, null)
			unit.queue_free()
	await process_frame


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
