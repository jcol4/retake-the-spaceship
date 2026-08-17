extends SceneTree
## The coordination deck, and the full squad sequence staged on it.
##
##   godot --headless --path . --script res://tools/test_coordination_deck.gd
##
## Two jobs. First it checks the deck itself is what the design says — size,
## compartments, one squad per wing — because every behavioural claim below rests
## on that geometry and a mis-drawn wall would quietly invalidate all of it.
##
## Then it stages the engagement that smoke runs only occasionally produce. The
## suppress-then-flank sequence needs a specific setup — a target actually behind
## cover, two or more squadmates with line of sight, ammunition for a burst — and
## a random skirmish supplies that combination rarely and never on demand. Smoke
## runs prove the framework is STABLE; this proves it is CORRECT.

const DECK := "res://maps/coordination_deck.txt"
const MERC := "res://scenes/merc_unit.tscn"
const PLAYER := "res://scenes/player_unit.tscn"

## Player room, on the LIGHT cover at (20,4)'s EAST edge — so a merc to the east
## is shooting into cover and one to the south is not. That asymmetry is the
## whole definition of a flank under the edge-cover model.
##
## Light rather than heavy only because the light pair sits clear of the room's
## other cover, which keeps the flank geometry unambiguous. NEITHER tier blocks
## line of sight — see `_check_heavy_cover_blocks_line_of_sight`.
const TARGET_TILE := Vector3i(20, 0, 4)
const EAST_LINE := [Vector3i(24, 0, 4), Vector3i(24, 0, 5), Vector3i(24, 0, 6)]
## The heavy-cover pair, kept for the check that documents its behaviour.
const HEAVY_TARGET := Vector3i(16, 0, 4)
const HEAVY_SHOOTER := Vector3i(22, 0, 4)

var _failures := 0
var _grid: Node
var _map
var _ascii
var _blackboard_cls
var _doctrines
var _coordinator
var _combat
## Loaded rather than named. Writing `_network.NOISE_RADIUS` inline makes
## security_network.gd a COMPILE-time dependency of this tool, which is compiled
## before autoloads register — it fails on GridManager, and the autoload node is
## then left scriptless, so every later `SecurityNetwork.report_noise` inside the
## engine dies with "Nonexistent function in base 'Node'". Reaching the constant
## through a loaded handle keeps it a runtime lookup.
var _network


func _initialize() -> void:
	_grid = root.get_node_or_null("GridManager")
	_ascii = load("res://scripts/map_ascii.gd")
	_blackboard_cls = load("res://scripts/ai/squad_blackboard.gd")
	_doctrines = load("res://scripts/ai/doctrines.gd")
	_coordinator = load("res://scripts/ai/squad_coordinator.gd")
	_combat = load("res://scripts/combat.gd")
	_network = load("res://scripts/security_network.gd")
	_map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(_map)
	await process_frame
	# Rebuilt onto the coordination deck. `build` frees its previous children and
	# clears GridManager, so this REPLACES the small deck the scene loaded on
	# _ready rather than layering on top of it — which is exactly what it used to
	# do, leaving stale walls inside the new map (see MapBuilder.build).
	_map.build(_ascii.load_file(DECK))
	await process_frame

	_check_the_deck_is_what_the_design_says()
	await _check_squads_are_separated_by_compartment()
	await _check_heavy_cover_blocks_line_of_sight()
	await _check_a_squad_shares_contacts_over_the_radio()
	await _check_shooting_one_merc_engages_the_whole_squad()
	await _check_the_full_squad_sequence()

	print("")
	if _failures == 0:
		print("coordination deck: ALL CHECKS PASSED")
		quit(0)
	else:
		print("coordination deck: %d CHECK(S) FAILED" % _failures)
		quit(1)


## Geometry first. Everything below assumes this shape, so a mis-drawn wall must
## fail here and not as a mysterious behavioural result twenty lines later.
func _check_the_deck_is_what_the_design_says() -> void:
	var data = _map.data
	_check(data.size == Vector2i(40, 26), "the deck is 40x26 (got %s)" % data.size)
	# Sized so crossing takes several activations. A 7 AP unit covers 7 tiles a
	# turn, and that is the entire reason the deck is this big — approach, goal
	# commitment and suppression windows do not exist on a map you cross in one.
	_check(data.size.x >= 5 * 7, "wide enough that crossing takes ~5 activations")

	_check(data.rooms.size() >= 6,
		"at least 6 compartments for propagation and escalation (got %d)" % data.rooms.size())
	_check(_map.merc_spawns.size() == 6, "6 mercs (got %d)" % _map.merc_spawns.size())
	_check(_map.player_spawns.size() == 3, "3 soldiers (got %d)" % _map.player_spawns.size())
	_check(_map.hunter_spawns.size() == 1, "1 Agile Hunter")
	_check(_map.cerberus_spawns.get(MapData.Spawn.LICTOR, []).size() == 1, "1 Lictor")
	# The alarm panel sits on the corridor every route between wings crosses.
	var alarm = _grid.get_tile(Vector3i(10, 0, 12))
	_check(alarm != null and alarm.alarm, "an alarm panel is on the corridor")


## Squads are drawn by DRAWING WALLS — a merc takes its squad from the
## compartment it spawns in. Two wings therefore mean two independent
## blackboards, which nothing tested before now: the boards are static, so one
## squad's claims leaking into another's would be a silent, permanent bug.
func _check_squads_are_separated_by_compartment() -> void:
	var rooms := {}
	for spawn: Vector3i in _map.merc_spawns:
		rooms["mercs_room_%d" % _map.room_at(spawn)] = true
	_check(rooms.size() == 2,
		"the 6 mercs fall into 2 squads by compartment (%s)" % ", ".join(rooms.keys()))

	var alpha = _doctrines.blackboard_for("squad_alpha")
	var bravo = _doctrines.blackboard_for("squad_bravo")
	_check(alpha != bravo, "and two squad ids get two distinct blackboards")

	var a = await _spawn(MERC, EAST_LINE[0])
	alpha.claim(alpha.Role.FLANKER, a)
	_check(alpha.holder(alpha.Role.FLANKER) == a, "a claim lands on its own board")
	_check(bravo.holder(bravo.Role.FLANKER) == null, "and not on the other squad's")
	_free([a])


## NEITHER COVER TIER BLOCKS LINE OF SIGHT, which is the XCOM model the design
## cites: cover is an accuracy penalty, not an impossibility. Cover props sit on
## collision layer 4 and LOS rays mask layer 1, so the rays pass straight over
## them and `Combat.COVER_PENALTY_HEAVY` does the work instead.
##
## Asserted because getting this wrong is expensive and quiet. It briefly LOOKED
## false during development — a stale wall left behind by a rebuilt deck sat
## inside this one and stopped the ray, which read exactly like heavy cover being
## solid (see MapBuilder.build, which now frees the previous deck). A unit that
## cannot be seen cannot be shot, suppressed or flanked, so if this ever does
## become true the entire coordination framework silently stops working against
## anybody standing behind a crate.
func _check_heavy_cover_blocks_line_of_sight() -> void:
	var behind_heavy = await _spawn(PLAYER, HEAVY_TARGET)
	var shooter = await _spawn(MERC, HEAVY_SHOOTER)
	_check(_combat.defending_cover(HEAVY_SHOOTER, HEAVY_TARGET)[0] == MapData.Cover.HEAVY,
		"the heavy-cover pair really is heavy")
	_check(_grid.has_line_of_sight(shooter, behind_heavy),
		"and heavy cover does NOT block line of sight — it is a penalty, not a wall")
	_free([behind_heavy, shooter])

	var behind_light = await _spawn(PLAYER, TARGET_TILE)
	var shooter2 = await _spawn(MERC, EAST_LINE[0])
	_check(_combat.defending_cover(EAST_LINE[0], TARGET_TILE)[0] == MapData.Cover.LIGHT,
		"while the light-cover pair is light")
	_check(_grid.has_line_of_sight(shooter2, behind_light),
		"and light cover leaves the target shootable, as cover should")
	_free([behind_light, shooter2])


## Mercenaries have radios: alerting one alerts the whole squad, wherever its
## members are standing.
##
## Both halves matter and they fail in opposite directions. It must cross
## COMPARTMENTS — the aliens' room-scoped propagation would stop at the first
## bulkhead, and a squad that loses contact with itself by walking through a door
## is not a squad. And it must respect SQUAD BOUNDARIES — a deck with two merc
## teams must not have one sighting bring both, or the two squads are one squad
## with extra steps and `squad_id` is decoration.
func _check_a_squad_shares_contacts_over_the_radio() -> void:
	# Deliberately far apart and in different compartments: one in the top-left
	# wing, one in the top-right, one down in the corridor between them.
	var spotter = await _spawn(MERC, Vector3i(5, 0, 7))
	var far_wing = await _spawn(MERC, Vector3i(34, 0, 9))
	var in_corridor = await _spawn(MERC, Vector3i(20, 0, 12))
	var other_squad = await _spawn(MERC, Vector3i(30, 0, 6))
	for merc in [spotter, far_wing, in_corridor]:
		merc.squad_id = "alpha"
	other_squad.squad_id = "bravo"

	_check(_map.room_at(spotter.grid_pos) != _map.room_at(far_wing.grid_pos),
		"the squad really is spread across different compartments")
	for merc in [spotter, far_wing, in_corridor, other_squad]:
		_check(merc.alert_state == merc.AlertState.UNAWARE, "everyone starts unaware")

	spotter.rouse(Vector3i(6, 0, 8))

	_check(far_wing.alert_state != far_wing.AlertState.UNAWARE,
		"a squadmate three compartments away is alerted")
	_check(in_corridor.alert_state != in_corridor.AlertState.UNAWARE,
		"and so is the one out in the corridor")
	_check(other_squad.alert_state == other_squad.AlertState.UNAWARE,
		"while the OTHER squad hears nothing — the radio net has an edge")

	# A CONFIRMED sighting, on a squad that is now already ALERT from the stimulus
	# above. This is the case the relay used to drop on the floor: it only spoke to
	# squadmates that were UNAWARE, so the noise a moment earlier had spent the
	# squad's one chance to be told anything and the actual contact reached nobody.
	# The rest of the squad walked to a stale tile, found nothing, settled, and the
	# player fought a six-man squad one merc at a time.
	var quarry = await _spawn(PLAYER, Vector3i(7, 0, 8))
	spotter._enter_combat(quarry, "spotter opens fire")

	for merc in [far_wing, in_corridor]:
		_check(merc.alert_state == merc.AlertState.COMBAT,
			"a squadmate already ALERT is upgraded by the call, not skipped")
		_check(merc.target == quarry,
			"and is handed the contact itself — a radio names who, a scream cannot")
	_check(other_squad.alert_state == other_squad.AlertState.UNAWARE,
		"the other squad still hears nothing, sighting or not")

	# Losing sight drops a merc back to ALERT mid-fight (`_check_contact`), and
	# under a one-shot broadcast that was permanent — `_propagate_alert` had
	# already fired for this engagement and would never fire again. `_combat_turn`
	# now re-broadcasts every activation; that call is made directly here rather
	# than by running the turn, which would drag in the planner and its animations.
	in_corridor._lose_target()
	_check(in_corridor.alert_state == in_corridor.AlertState.ALERT,
		"a merc that loses contact falls back to ALERT")
	spotter._relay_to_squad(quarry.grid_pos, quarry)
	_check(in_corridor.alert_state == in_corridor.AlertState.COMBAT,
		"and the next call pulls it back in — the net stays open all fight")

	_free([spotter, far_wing, in_corridor, other_squad, quarry])


## SHOOTING ONE MERC ENGAGES THE SQUAD — hit, miss, or clean kill.
##
## Staged deliberately OUT OF EARSHOT. Every merc here is further from the player
## than `_network.NOISE_RADIUS`, so the gunshot-noise channel reaches none
## of them and cannot be what produced the result. That isolation is the whole
## value of the check: awareness used to come only from sight, beams and noise,
## which meant a shot fired from 6 tiles away triggered literally nothing.
func _check_shooting_one_merc_engages_the_whole_squad() -> void:
	var shooter = await _spawn(PLAYER, TARGET_TILE)

	# --- The shot lands, the man survives -----------------------------------
	var squad := await _spawn_squad()
	for merc in squad:
		_check(_grid.chebyshev_dist(merc.grid_pos, shooter.grid_pos) > _network.NOISE_RADIUS,
			"the squad is out of earshot (%d > %d) — noise cannot be the trigger" % [
				_grid.chebyshev_dist(merc.grid_pos, shooter.grid_pos), _network.NOISE_RADIUS])
	squad[0].come_under_fire(shooter)
	_check_whole_squad_engaged(squad, shooter, "shot at")

	# --- The shot MISSES ----------------------------------------------------
	# Identical by construction: `_report_incoming` is called outside the `if
	# result.hit` branch, so a miss is the same stimulus as a hit. Asserted anyway,
	# because "we only react to damage" is the obvious way to write this and it
	# would pass every other check in this file.
	_free(squad)
	squad = await _spawn_squad()
	var before = squad[0].current_hp
	squad[0].come_under_fire(shooter)
	_check(squad[0].current_hp == before, "a miss does no damage")
	_check_whole_squad_engaged(squad, shooter, "missed")

	# --- The shot KILLS the man it was aimed at -----------------------------
	# The case that matters most and the one a damage-driven implementation loses.
	# Ordered exactly as `fire_at` orders it — `take_damage` first, the report
	# after — so the victim really is downed by the time the call goes out.
	_free(squad)
	squad = await _spawn_squad()
	var victim = squad[0]
	victim.take_damage(9999)
	_check(victim.is_downed, "the shot killed the merc it was aimed at")
	shooter._report_incoming(victim)
	var survivors: Array = [squad[1], squad[2]]
	_check_whole_squad_engaged(survivors, shooter, "killed outright")

	# --- End to end, through a REAL shot ------------------------------------
	# Everything above calls the hook directly. This proves `fire_at` is actually
	# wired to it, which no amount of direct calls can. Hit or miss is left to the
	# dice on purpose: the assertion holds either way, and saying so is the point.
	_free(squad)
	squad = await _spawn_squad()
	var result = await shooter.fire_at(squad[0], _combat.ShotAction.SHOOT)
	_check_whole_squad_engaged(squad, shooter,
		"a real shot that %s" % ("hit" if result.hit else "missed"))

	_free(squad)
	_free([shooter])


## Three mercs on one squad, scattered across three compartments and all well
## outside the player's earshot.
func _spawn_squad() -> Array:
	var squad: Array = []
	for tile: Vector3i in [Vector3i(5, 0, 7), Vector3i(34, 0, 9), Vector3i(20, 0, 12)]:
		var merc = await _spawn(MERC, tile)
		merc.squad_id = "under_fire"
		squad.append(merc)
	return squad


func _check_whole_squad_engaged(squad: Array, shooter, label: String) -> void:
	var engaged := 0
	for merc in squad:
		if merc.alert_state == merc.AlertState.COMBAT and merc.target == shooter:
			engaged += 1
	_check(engaged == squad.size(),
		"%s: all %d mercs are in COMBAT on the shooter (got %d)" % [
			label, squad.size(), engaged])


## THE WHOLE POINT, staged end to end on the real deck.
##
## Three mercs east of a soldier who is behind heavy cover. Each is drawn in turn
## and plans for itself; nothing tells any of them what the others did. What must
## come out is division of labour — one lays down fire and ends its turn, the
## rest use the window — and it must come out through the blackboard, since that
## is the only thing that survives between two draws of the initiative pool.
func _check_the_full_squad_sequence() -> void:
	var target = await _spawn(PLAYER, TARGET_TILE)
	var squad: Array = []
	for tile: Vector3i in EAST_LINE:
		squad.append(await _spawn(MERC, tile))
	var board = _blackboard_cls.new()
	var SUPPRESSOR = board.Role.SUPPRESSOR
	var FLANKER = board.Role.FLANKER

	# Cover is what makes any of this worth doing. Asserted rather than assumed,
	# because if the geometry is wrong every behavioural check below passes or
	# fails for the wrong reason.
	_check(_combat.defending_cover(EAST_LINE[0], TARGET_TILE)[0] != 0,
		"the soldier is genuinely behind cover from the east")

	var said: Array[String] = []
	var brains := {}
	for merc in squad:
		merc.action_logged.connect(func(t: String) -> void: said.append(t))
		brains[merc] = _doctrines.merc_brain(board)

	for merc in squad:
		merc.begin_activation()
		_coordinator.assign(board, squad, target)
		await brains[merc].run(merc, target)

	var pinner = board.holder(SUPPRESSOR)
	_check(pinner != null, "somebody in the squad took the suppressor role")
	_check(target.is_suppressed(), "and the soldier is actually pinned")
	_check(board.holder(FLANKER) != pinner,
		"while the flanker role went to somebody else — the division of labour")

	var announced := "\n".join(said)
	_check("Suppressing" in announced or "suppressing" in announced,
		"the pin was announced: %s" % _first_matching(said, "uppressing"))
	_check("Copy" in announced,
		"and answered by the unit exploiting it: %s" % _first_matching(said, "Copy"))

	# Exactly one holder per role, which is the failure the whole blackboard
	# exists to prevent and the one that looks like nothing on screen.
	var holders := {}
	for role in [SUPPRESSOR, FLANKER]:
		var h = board.holder(role)
		if h != null:
			_check(not holders.has(h), "no unit holds two roles at once")
			holders[h] = true
	_free(squad + [target])


func _first_matching(lines: Array[String], needle: String) -> String:
	for line in lines:
		if needle in line:
			return line
	return "(never said)"


func _spawn(scene_path: String, at: Vector3i):
	var unit = load(scene_path).instantiate()
	if scene_path == MERC:
		unit.stats = MercPresets.support("Merc")
	else:
		unit.stats = ClassPresets.roll(UnitStats.UnitClass.ASSAULT, "Reyes")
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
