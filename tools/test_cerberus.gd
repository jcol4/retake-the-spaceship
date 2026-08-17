extends SceneTree
## The security-robot faction's rules, checked against the real built deck rather
## than a fixture — so the map format, the spawner, the network autoload and the
## combat maths all have to agree for this to pass.
##
##   godot --headless --path . --script res://tools/test_cerberus.gd
##
## Each case is phrased against a claim in docs/design/factions/security-robots/,
## so a failure points at a design rule rather than at bookkeeping.
##
## Scripts are load()ed and called dynamically rather than named: cerberus_unit.gd
## and combat.gd reference autoloads at COMPILE time, and a --script tool is
## compiled before autoloads register. Locals stay untyped for the same reason.

const AUXILIUM := "res://scenes/auxilium_unit.tscn"
const SAGITTARII := "res://scenes/sagittarii_unit.tscn"
const PROCTOR := "res://scenes/proctor_unit.tscn"
const SECURUS := "res://scenes/securus_unit.tscn"
const ALIEN := "res://scenes/enemy_unit.tscn"
const PLAYER := "res://scenes/player_unit.tscn"

# Middle compartment, well clear of the deck's own spawn markers.
const MID_A := Vector3i(7, 0, 2)
const MID_B := Vector3i(10, 0, 10)
const LEFT := Vector3i(2, 0, 2)

var _failures := 0
var _grid: Node
var _net: Node
var _combat
var _presets
var _map


func _initialize() -> void:
	_grid = root.get_node_or_null("GridManager")
	_net = root.get_node_or_null("SecurityNetwork")
	_combat = load("res://scripts/combat.gd")
	_presets = load("res://scripts/cerberus_presets.gd")
	_map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(_map)
	await process_frame

	_check_deck()
	_check_zones()
	await _check_light_exception()
	await _check_armor_and_emp()
	await _check_head_weak_point()
	await _check_network_alert()
	await _check_standing_post()
	await _check_sound()
	_check_evidence()
	await _check_salvage()

	print("")
	if _failures == 0:
		print("cerberus: ALL CHECKS PASSED")
		quit(0)
	else:
		print("cerberus: %d CHECK(S) FAILED" % _failures)
		quit(1)


# --- Deck and zones ----------------------------------------------------------


func _check_deck() -> void:
	# NONE, currently: the test deck is staged to judge the alien melee tier on
	# its own and places no robots at all.
	#
	# This used to assert one of each, on the reasoning that the glyph table is
	# better exercised by the deck the game ships with than by a fixture. That is
	# still true and the coverage did not go with it — test_map_roundtrip.gd's
	# _check_spawn_glyphs owns it now, on a layout the test controls, which is
	# what stops deck staging from silently deciding what gets tested.
	#
	# Nothing below depends on the deck's roster: every check that needs a robot
	# spawns its own at a chosen tile. So this is a statement about the map, and
	# it is asserted rather than dropped so that putting robots back is a
	# deliberate edit here.
	#
	# The Lictor IS on the deck now, deliberately: the security faction's
	# cover-breaking doctrine is worth exercising in the map the game actually
	# loads rather than only in fixtures, and one gun platform in the far room
	# does not turn an alien-tier deck into a robot fight.
	for kind in MapData.CERBERUS_SPAWNS:
		if kind == MapData.Spawn.LICTOR:
			continue
		var spawns: Array = _map.cerberus_spawns.get(kind, [])
		_check(spawns.is_empty(), "%s: no spawn on the test deck (got %d)" % [
			_presets.display_name(kind), spawns.size()])


func _check_zones() -> void:
	# A zone is coarser than a tile and no coarser than a compartment: two robots
	# in the same room answer the same broadcast, one across a bulkhead does not.
	var mid_a: int = _map.zone_at(MID_A)
	var mid_b: int = _map.zone_at(MID_B)
	var left: int = _map.zone_at(LEFT)
	_check(mid_a != _net.NO_ZONE, "a tile in the middle compartment resolves to a zone")
	_check(mid_a == mid_b, "two tiles in one compartment share it (%d vs %d)" % [mid_a, mid_b])
	_check(mid_a != left, "a tile across a bulkhead does not (%d vs %d)" % [mid_a, left])
	# A doorway is its own region in the room graph; a sentry standing in one must
	# still answer to a real compartment rather than to a one-tile zone of its own.
	_check(_map.zone_at(Vector3i(5, 0, 7)) != _net.NO_ZONE, "a doorway resolves to a compartment")


# --- Detection ---------------------------------------------------------------


func _check_light_exception() -> void:
	# The faction's central bet: light is not a term in any roll involving a
	# robot. The alien is the control — same shooter, same tiles, same distance.
	# Stats set by hand rather than rolled: a rolled Assault soldier sits well
	# above the formula's 99 clamp at this range, and a clamped number cannot show
	# a difference in a term. These are chosen to leave headroom on both sides.
	var shooter = await _spawn(PLAYER, Vector3i(7, 0, 6))
	shooter.stats = _shooter_stats()
	var robot = await _spawn(SAGITTARII, MID_A)
	var alien = await _spawn(ALIEN, MID_B)
	alien.stats = _alien_stats()

	var robot_dark := _accuracy_at_light(shooter, robot, 0.0)
	var robot_lit := _accuracy_at_light(shooter, robot, 100.0)
	_check(robot_dark == robot_lit,
		"light does not change the odds against a robot (%d dark vs %d lit)" % [robot_dark, robot_lit])

	var alien_dark := _accuracy_at_light(shooter, alien, 0.0)
	var alien_lit := _accuracy_at_light(shooter, alien, 100.0)
	_check(alien_lit > alien_dark,
		"but it still does against an alien (%d dark vs %d lit)" % [alien_dark, alien_lit])
	_check(not _combat.light_matters(shooter, robot), "light_matters is false with a robot on either end")
	_check(_combat.light_matters(shooter, alien), "and true between two light-reading units")

	# Motion, the channel that replaces it: a target that just moved is picked up
	# further out than one holding still.
	robot.detection_range = 8
	robot.motionless_detection_range = 2
	shooter.last_moved_turn = -99
	_check(not robot._can_see(shooter), "a motionless target beyond the short range is not detected")
	shooter.last_moved_turn = _turn()
	_check(robot._can_see(shooter), "the same target, having just moved, is")

	_free([shooter, robot, alien])


func _accuracy_at_light(shooter, target, light: float) -> int:
	# Written straight onto the tile: LightingManager would recompute this away on
	# its own schedule, and what is under test is the accuracy formula's reaction
	# to a light value, not how the value got there.
	_grid.get_tile(target.grid_pos).light_value = light
	return _combat.compute_accuracy(shooter, target, _combat.ShotAction.SHOOT, _combat.BodyPart.TORSO)


# --- Armor, EMP, weak points -------------------------------------------------


func _check_armor_and_emp() -> void:
	var robot = await _spawn(SAGITTARII, MID_A)
	robot.armor_value = 8

	_check(robot.damage_taken(20) == 12, "armor comes off the damage roll (20 -> %d)" % robot.damage_taken(20))
	_check(robot.damage_taken(3) == robot.MIN_DAMAGE_THROUGH_ARMOR,
		"a shot weaker than the plate still does its floor, not zero")

	var before: int = robot.current_hp
	var landed: int = robot.take_damage(20)
	_check(landed == 12, "take_damage reports what actually landed (%d)" % landed)
	_check(robot.current_hp == before - 12, "and that is what came off its HP")

	robot.apply_emp(2)
	_check(robot.emp_turns == 2, "EMP disables it for the roster default (got %d)" % robot.emp_turns)
	_check(robot.effective_armor() == 0, "and its armor reads zero for the window")
	_check(robot.damage_taken(20) == 20, "so a follow-up shot bypasses the plate entirely")

	# The window closes on its own activations, which is what makes EMP timing a
	# decision rather than a permanent debuff.
	await robot.take_turn()
	_check(robot.emp_turns == 1, "one activation is burned per turn while disabled")
	_check(robot.ap == 0, "and it does nothing on that draw")
	await robot.take_turn()
	_check(robot.emp_turns == 0 and robot.effective_armor() == 8, "then the armor is back")

	# Securus is the one unit that gets less of it — the elite tell.
	var securus = await _spawn(SECURUS, MID_B)
	securus.apply_emp(2)
	_check(securus.emp_turns == 1,
		"Securus takes a shorter EMP window than the roster (got %d)" % securus.emp_turns)

	_free([robot, securus])


func _check_head_weak_point() -> void:
	var securus = await _spawn(SECURUS, MID_A)
	securus.head_hp = 10
	securus.armor_value = 10

	# Only an Aimed Shot to the head touches the pool. Anything else is an
	# ordinary damage roll, even a crit — the weak point is tied to a choice the
	# player makes, not to a roll they cannot see.
	_check(securus.apply_body_part_damage(_combat.BodyPart.TORSO, 8) == false,
		"a torso hit reports no injury (robots have no injury state)")
	_check(securus.head_hp == 10, "and does not touch the head pool")

	securus.apply_body_part_damage(_combat.BodyPart.HEAD, 6)
	_check(securus.head_hp == 4, "an Aimed Shot to the head takes the RAW roll off it (got %d)" % securus.head_hp)
	_check(not securus.head_broken, "which is not yet enough to break it")

	var normal: int = securus.damage_taken(20)
	securus.apply_body_part_damage(_combat.BodyPart.HEAD, 6)
	_check(securus.head_broken, "the hit that empties the pool breaks the head off")
	_check(securus.damage_taken(20) > normal,
		"and every hit after it lands harder (%d -> %d)" % [normal, securus.damage_taken(20)])

	_free([securus])


# --- The network -------------------------------------------------------------


func _check_network_alert() -> void:
	# Alerts are zone-scoped, not radius-scoped: distance and line of sight are
	# both irrelevant inside a zone, and neither buys anything outside one.
	var near = await _spawn(AUXILIUM, MID_A)
	var far = await _spawn(SAGITTARII, MID_B)
	var elsewhere = await _spawn(AUXILIUM, LEFT)
	near.security_zone = _map.zone_at(MID_A)
	far.security_zone = _map.zone_at(MID_B)
	elsewhere.security_zone = _map.zone_at(LEFT)

	var reached: int = _net.broadcast(near.security_zone, MID_A, false, near)
	_check(reached == 1, "a broadcast reaches its zone and stops there (%d units)" % reached)
	_check(far.alert_state == far.AlertState.ALERT,
		"the unit across the room is alerted without having seen anything")
	_check(elsewhere.alert_state == elsewhere.AlertState.UNAWARE,
		"the unit in the next compartment is not")
	_check(far.last_known_pos == MID_A, "and the alerted unit is told where to look")

	# A second broadcast to a NEW position redirects a unit that is already
	# converging on a stale one — which is the case the network exists for, and so
	# it has to count as having reached it.
	_check(far.receive_broadcast(MID_B, false), "a later broadcast redirects an already-alerted unit")
	_check(far.last_known_pos == MID_B, "and it goes to the newer report")
	_check(not far.receive_broadcast(MID_B, false), "re-sending the same position changes nothing")

	# A robot already in a fight is not redirected by network chatter.
	far._set_state(far.AlertState.COMBAT)
	_check(not far.receive_broadcast(LEFT, false), "a unit in combat ignores a fresh broadcast")

	_free([near, far, elsewhere])


func _check_standing_post() -> void:
	# The behaviour that makes bypassing an Auxilium a real option: it reserves a
	# shot at its post instead of idling, and it will not be walked off it.
	var sentry = await _spawn_robot(MapData.Spawn.AUXILIUM, MID_A)
	sentry.begin_activation()
	await sentry.take_turn()
	_check(sentry.on_overwatch, "a quiet Auxilium reserves its shot rather than idling")
	# Overwatch pays a fixed cost (priced as a Shoot) and still ends the
	# activation outright, so the sentry ends its turn on zero rather than merely
	# down a point — asserted against the pool, which is per-unit now.
	_check(sentry.ap == 0 and sentry.ap_pool() > 0, "and pays the AP for it")

	# Leashed: a target further from its post than post_leash is not chased.
	var bait = await _spawn(PLAYER, LEFT)
	sentry.holds_position = true
	sentry.post_leash = 2
	sentry.begin_activation()
	var stood: Vector3i = sentry.grid_pos
	await sentry._move_toward(bait)
	_check(sentry.grid_pos == stood, "and it holds position rather than chasing across the deck")

	# The same unit off its post walks back to it once it has nothing to react to.
	# Over several activations, not one: it walks a move budget at a time like
	# anything else, and MID_B is most of the compartment away from its post.
	sentry.grid_pos = MID_B
	sentry.position = _grid.grid_to_world(MID_B)
	var walked := 0
	while sentry.grid_pos != sentry.post_pos and walked < 6:
		sentry.begin_activation()
		await sentry.take_turn()
		walked += 1
	_check(sentry.grid_pos == sentry.post_pos,
		"a robot that wandered walks back to its post (took %d activations, ended %s)" % [
			walked, sentry.grid_pos])

	_free([sentry, bait])


func _check_sound() -> void:
	# The one channel both factions share. No line of sight, no light, just range.
	var robot = await _spawn(AUXILIUM, MID_A)
	var distant = await _spawn(AUXILIUM, LEFT)
	robot.hear_noise(MID_A + Vector3i(3, 0, 0))
	_check(robot.alert_state == robot.AlertState.ALERT, "gunfire in earshot rouses a robot")

	# Range, and only range: no walls are consulted, so the far shot has to be
	# genuinely out of earshot rather than merely on the other side of a bulkhead.
	var far_off := Vector3i(17, 0, 2)
	distant.alert_state = distant.AlertState.UNAWARE
	_net.report_noise(far_off, robot)
	_check(distant.alert_state == distant.AlertState.UNAWARE,
		"a shot %d tiles away does not (radius is %d)" % [
			_grid.chebyshev_dist(far_off, LEFT), _net.NOISE_RADIUS])

	_free([robot, distant])


func _check_evidence() -> void:
	# The Proctor-only third channel: it survives the event that made it, and is
	# consumed when read so one corpse cannot alert a zone every activation.
	var pos := Vector3i(9, 0, 5)
	_net.report_evidence(pos, _net.Evidence.BRASS)
	_net.report_evidence(pos, _net.Evidence.BRASS)
	var found: Array = _net.scan_evidence(pos + Vector3i(2, 0, 0), 4)
	_check(found.size() == 1, "one pile of brass per tile, not one per round (got %d)" % found.size())
	_check(_net.scan_evidence(pos, 4).is_empty(), "and it is consumed once reported")
	_check(_net.scan_evidence(Vector3i(1, 0, 1), 1).is_empty(), "an unrelated tile has nothing on it")


func _check_salvage() -> void:
	# No injury state: a robot at 0 HP is gone, and leaves the resource that makes
	# clearing one worth the ammunition.
	var robot = await _spawn(PROCTOR, MID_A)
	robot.salvage_value = 3
	var before: int = _net.salvage
	robot.take_damage(9999)
	_check(robot.is_downed, "a destroyed robot is downed outright")
	_check(_net.salvage == before + 3, "and drops its Salvage (%d -> %d)" % [before, _net.salvage])
	_free([robot])


# --- Helpers -----------------------------------------------------------------


func _spawn(scene_path: String, at: Vector3i):
	var unit = load(scene_path).instantiate()
	unit.position = _grid.grid_to_world(at)
	root.add_child(unit)
	await process_frame
	return unit


## A robot spawned the way main.gd spawns one: roster stats assigned BEFORE it
## enters the tree, since `Unit._ready` reads mag size and HP off them. Spawning
## one without this leaves it with a null weapon and no ammunition, which quietly
## disables every behaviour gated on `can_shoot()`.
func _spawn_robot(kind: int, at: Vector3i):
	var unit = _presets.scene_for(kind).instantiate()
	unit.stats = _presets.make_stats(kind)
	unit.position = _grid.grid_to_world(at)
	root.add_child(unit)
	await process_frame
	return unit


func _free(units: Array) -> void:
	for unit in units:
		_grid.set_occupant(unit.grid_pos, null)
		unit.queue_free()


func _turn() -> int:
	return root.get_node("TurnManager").turn_number


func _shooter_stats():
	var stats := UnitStats.new()
	stats.display_name = "Tester"
	stats.perception = 20
	stats.reflexes = 10
	stats.fitness = 50
	stats.luck = 0  # no Luck rerolls: compute_accuracy is what is under test
	stats.weapon = WeaponPresets.make(WeaponPresets.WeaponId.ASSAULT_RIFLE)
	return stats


func _alien_stats():
	var stats := UnitStats.new()
	stats.display_name = "Control Alien"
	stats.perception = 40
	stats.reflexes = 35
	stats.fitness = 40
	stats.luck = 20
	return stats


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
