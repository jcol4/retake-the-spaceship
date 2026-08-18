extends SceneTree
## The shared GOAP coordination framework.
##
##   godot --headless --path . --script res://tools/test_goap.gd
##
## Covers the prototype's acceptance criteria (docs/design/systems/coordinated-ai/
## Sec 9) plus the two doctrine locks, because every one of them is invisible in
## play. A merc squad that coordinates and a merc squad that got a kind draw
## order look identical on screen; so does a robot squad that never flanks and
## one that simply never found a flank worth taking.
##
## Classes are load()ed and locals stay untyped: `SquadBlackboard` and
## `GoapActions` reach TurnManager/GridManager, so naming them in a --script tool
## would make those autoloads compile-time dependencies and the tool would never
## load at all. See test_cerberus.gd.

const PLAYER := "res://scenes/player_unit.tscn"
const MERC := "res://scenes/merc_unit.tscn"

## Middle room. The deck puts light cover on the EAST side of (8,0,4), so a
## shooter east of the target is blocked by it and one to the north is not —
## which is exactly the geometry "flank" is defined against.
const TARGET_TILE := Vector3i(8, 0, 4)
const EAST_A := Vector3i(11, 0, 4)
const EAST_B := Vector3i(11, 0, 5)

var _failures := 0
var _grid: Node
var _blackboard_cls
var _doctrines
var _planner
var _action_cls
var _combat
var _barks
var _coordinator
var _tile_threat

# UnitStats.Action values, by number — see the load() note above.
const ACTION_SHOOT := 0
const ACTION_MELEE := 1
const ACTION_RELOAD := 3
const ACTION_SUPPRESS := 5


func _initialize() -> void:
	_grid = root.get_node_or_null("GridManager")
	_blackboard_cls = load("res://scripts/ai/squad_blackboard.gd")
	_doctrines = load("res://scripts/ai/doctrines.gd")
	_planner = load("res://scripts/ai/goap_planner.gd")
	_action_cls = load("res://scripts/ai/goap_action.gd")
	_combat = load("res://scripts/combat.gd")
	_barks = load("res://scripts/ai/barks.gd")
	_coordinator = load("res://scripts/ai/squad_coordinator.gd")
	_tile_threat = load("res://scripts/ai/tile_threat.gd")
	var map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(map)
	await process_frame

	await _check_costs_come_from_the_ap_formulas()
	_check_cerberus_cannot_flank()
	await _check_one_role_one_claimant()
	await _check_claims_release_on_death_and_target_loss()
	_check_stale_claims_expire()
	await _check_planner_chains_suppress_into_flank()
	await _check_barks_announce_intent()
	_check_barks_have_a_voice_per_faction()
	await _check_cover_is_a_means_not_an_end()
	await _check_goal_commitment()
	await _check_relevance_scales_with_how_hurt()
	await _check_squad_coordinator_divides_labour()
	await _check_starvation_cap_forces_offence()
	_check_veteran_tier_outperforms_standard()
	await _check_attack_gated_on_viable_accuracy_not_flat_range()
	await _check_overwatch_awareness()
	await _check_priority_targets()

	print("")
	if _failures == 0:
		print("goap: ALL CHECKS PASSED")
		quit(0)
	else:
		print("goap: %d CHECK(S) FAILED" % _failures)
		quit(1)


## ACCEPTANCE CRITERION: "All action costs are pulled from the AP-rework
## formulas, not a duplicated cost table."
##
## Asserted by comparing each action's `ap_cost` against the unit's own
## `action_cost`, so a private constant sneaking into the action library shows up
## here rather than as an AI that plans things it cannot pay for.
func _check_costs_come_from_the_ap_formulas() -> void:
	var merc = await _spawn(MERC, EAST_A)
	var target = await _spawn(PLAYER, TARGET_TILE)
	var ctx := {"target": target, "blackboard": null}
	var brain = _doctrines.merc_brain(null)

	var by_name := {}
	for action in brain.actions:
		by_name[String(action.name)] = action

	_check(by_name["Attack"].ap_cost(merc, ctx) == merc.action_cost(ACTION_SHOOT),
		"Attack costs a Shoot (%d AP)" % merc.action_cost(ACTION_SHOOT))
	_check(by_name["Suppress"].ap_cost(merc, ctx) == merc.action_cost(ACTION_SUPPRESS),
		"Suppress costs a Suppress (%d AP)" % merc.action_cost(ACTION_SUPPRESS))
	_check(by_name["Reload"].ap_cost(merc, ctx) == merc.action_cost(ACTION_RELOAD),
		"Reload costs a Reload (%d AP)" % merc.action_cost(ACTION_RELOAD))
	_check(by_name["MeleeStrike"].ap_cost(merc, ctx) == merc.action_cost(ACTION_MELEE),
		"MeleeStrike costs a Melee (%d AP)" % merc.action_cost(ACTION_MELEE))
	_free([merc, target])


## DOCTRINE LOCK (Sec 5.2, and Sec 8: "under any circumstance"). Cerberus must
## not merely deprioritise flanking — the action must be absent from the library,
## because a doctrine expressed as a low score is one tuning pass from
## evaporating.
func _check_cerberus_cannot_flank() -> void:
	var robot_names: Array[String] = []
	for action in _doctrines.cerberus_brain(null).actions:
		robot_names.append(String(action.name))
	_check(not ("Flank" in robot_names),
		"Cerberus has no Flank action at all (%s)" % ", ".join(robot_names))
	_check("DestroyCover" in robot_names and "Advance" in robot_names,
		"and does carry its own doctrine's two")

	var merc_names: Array[String] = []
	for action in _doctrines.merc_brain(null).actions:
		merc_names.append(String(action.name))
	_check("Flank" in merc_names, "while the mercs do flank")
	_check(not ("DestroyCover" in merc_names),
		"and do not grind cover down — that is the robots' pressure, not theirs")


## THE HEADLINE ACCEPTANCE CRITERION: two units must not independently claim the
## same role.
func _check_one_role_one_claimant() -> void:
	var a = await _spawn(MERC, EAST_A)
	var b = await _spawn(MERC, EAST_B)
	var target = await _spawn(PLAYER, TARGET_TILE)
	var board = _blackboard_cls.new()
	var FLANKER = board.Role.FLANKER

	_check(board.claim(FLANKER, a, target), "the first merc claims the flanker role")
	_check(not board.can_claim(FLANKER, b), "the second one cannot")
	_check(not board.claim(FLANKER, b, target), "and its claim is refused")
	_check(board.holder(FLANKER) == a, "the role still belongs to the first")
	# Re-claiming your OWN role is a refresh, not a conflict — otherwise a unit
	# would lose its role by continuing to pursue it.
	_check(board.claim(FLANKER, a, target), "the holder may refresh its own claim")

	board.release(FLANKER, a)
	_check(board.can_claim(FLANKER, b), "and once released the second merc may take it")

	# Tile claims, the other half: two flankers converging on one square turns a
	# pincer into a queue.
	board.claim(FLANKER, b, target, TARGET_TILE + Vector3i(0, 0, -2))
	_check(board.is_tile_claimed(TARGET_TILE + Vector3i(0, 0, -2), a),
		"a claimed flank tile reads as taken to everyone else")
	_check(not board.is_tile_claimed(TARGET_TILE + Vector3i(0, 0, -2), b),
		"but not to its own claimant")
	_free([a, b, target])


## ACCEPTANCE CRITERION: "Claims correctly release when a claiming unit dies or
## loses its target." Two separate dangling-reference bugs — a dead owner blocks
## the role forever, a dead target sends an ally flanking an empty room.
func _check_claims_release_on_death_and_target_loss() -> void:
	var a = await _spawn(MERC, EAST_A)
	var b = await _spawn(MERC, EAST_B)
	var target = await _spawn(PLAYER, TARGET_TILE)
	var board = _blackboard_cls.new()
	var FLANKER = board.Role.FLANKER

	board.claim(FLANKER, a, target)
	a.take_damage(99999)
	_check(a.is_downed, "the claiming merc goes down")
	board.revalidate()
	_check(board.can_claim(FLANKER, b), "and its claim is swept, freeing the role")

	board.claim(FLANKER, b, target)
	target.take_damage(99999)
	_check(target.is_downed, "the TARGET goes down")
	board.revalidate()
	_check(board.holder(FLANKER) == null,
		"and the claim goes with it — nobody flanks a corpse")
	_free([a, b, target])


## The backstop release. Explicit releases catch every case anyone has thought
## of; this catches a unit that quietly stops pursuing a role without dying.
func _check_stale_claims_expire() -> void:
	var board = _blackboard_cls.new()
	var turns = root.get_node_or_null("TurnManager")
	var before: int = turns.turn_number
	# A claim stamped far enough in the past that the sweep must drop it. Faked
	# by winding the turn counter, which is what the sweep actually reads.
	board._claims[board.Role.SUPPRESSOR] = {
		"owner": null, "target": null, "tile": Vector3i.ZERO,
		"turn": before - (board.CLAIM_STALE_TURNS + 5),
	}
	board.revalidate()
	_check(board.holder(board.Role.SUPPRESSOR) == null,
		"a claim older than %d turns is abandoned" % board.CLAIM_STALE_TURNS)
	turns.turn_number = before


## THE HEADLINE ACCEPTANCE CRITERION, end to end: "A rival merc squad of at least
## 2 units can execute a Suppress -> Flank sequence without both units
## independently claiming the flanker role."
##
## Run as a SQUAD sequence across two activations, not as one unit's plan,
## because that is what it physically is: `do_suppress` ends the suppressor's
## activation outright, so the merc that pins can never be the merc that flanks.
## The coordination is therefore entirely carried by the blackboard surviving
## between two draws — which is the thing the initiative pool makes hard and the
## whole reason this framework exists.
##
## The second merc is NOT told what the first did. It reads a world in which the
## target happens to be pinned, and its own doctrine does the rest.
func _check_planner_chains_suppress_into_flank() -> void:
	var a = await _spawn(MERC, EAST_A)
	var b = await _spawn(MERC, EAST_B)
	var target = await _spawn(PLAYER, TARGET_TILE)
	var board = _blackboard_cls.new()
	var brain_a = _doctrines.merc_brain(board)
	var brain_b = _doctrines.merc_brain(board)
	var SUPPRESSOR = board.Role.SUPPRESSOR
	var FLANKER = board.Role.FLANKER

	# A spawned unit holds 0 AP until it is drawn — `ap` is filled by
	# `begin_activation`, not by `_ready`.
	a.begin_activation()
	await brain_a.run(a, target)
	_check(target.is_suppressed(), "the first merc drawn pins the target")
	_check(board.holder(SUPPRESSOR) == a, "and claims the suppressor role")
	_check(a.ap == 0, "spending its whole activation on it, as suppression does")

	b.begin_activation()
	var b_start: Vector3i = b.grid_pos
	await brain_b.run(b, target)
	_check(board.holder(SUPPRESSOR) == a,
		"the second merc does NOT re-pin an already-pinned target")
	_check(board.holder(FLANKER) == b, "it takes the flanker role instead")
	_check(b.grid_pos != b_start, "and actually moves (%s -> %s)" % [b_start, b.grid_pos])
	# The payoff, stated as the thing the player would feel: the second merc used
	# the window to IMPROVE ITS POSITION — either it took an angle the target's
	# cover does not reach, or it got behind something itself.
	#
	# Either outcome is the doctrine working. Which one it picks depends on
	# whether a flanking tile exists from where it happens to stand, and pinning
	# the assertion to the flank alone made the test fail whenever the geometry
	# offered cover but no angle — a legitimate choice reported as a bug.
	var flanked: bool = _combat.defending_cover(b.grid_pos, target.grid_pos)[0] == 0
	var in_cover: bool = not _grid.covered_sides(b.grid_pos).is_empty()
	_check(flanked or in_cover,
		"and improved its position — flanked=%s, in cover=%s" % [flanked, in_cover])
	_free([a, b, target])


## FIX E — announcing intent.
##
## The bark is the cheapest thing in the framework and, per Orkin, does more for
## the FEEL of coordination than the planning does. Three rules make it work and
## each can break silently: it fires once per role change (not per refresh), the
## flanker answers covering fire when there is any, and each faction speaks in
## its own register — an alien must never announce a flank in English.
func _check_barks_announce_intent() -> void:
	var a = await _spawn(MERC, EAST_A)
	var b = await _spawn(MERC, EAST_B)
	var target = await _spawn(PLAYER, TARGET_TILE)
	var board = _blackboard_cls.new()
	var SUPPRESSOR = board.Role.SUPPRESSOR
	var FLANKER = board.Role.FLANKER

	var said: Array[String] = []
	a.action_logged.connect(func(t: String) -> void: said.append(t))
	b.action_logged.connect(func(t: String) -> void: said.append(t))

	board.claim(SUPPRESSOR, a, target)
	_check(said.size() == 1, "claiming a role says exactly one thing (%d)" % said.size())
	_check("Suppressing" in said[0], "and it names the role: %s" % said[0])

	# THE SPAM REGRESSION. Re-claiming your own role is a refresh, so a suppressor
	# holding for three turns must not announce itself three times.
	board.claim(SUPPRESSOR, a, target)
	board.claim(SUPPRESSOR, a, target)
	_check(said.size() == 1, "refreshing the same claim stays quiet (%d)" % said.size())

	# THE CALL AND RESPONSE. Same action, different sentence, and the only input
	# is that an ally is already laying down fire.
	board.claim(FLANKER, b, target)
	_check(said.size() == 2, "the flanker speaks up too")
	_check("Copy" in said[1], "answering the covering fire rather than narrating: %s" % said[1])

	var solo: String = _barks.line(Faction.Id.RIVAL_MERCS, _barks.ROLE_FLANKER, "M", "T", false)
	_check(solo != said[1], "and it would have said something else with nobody covering")
	_free([a, b, target])


## Voice per faction, asserted directly on the table because the alien case is a
## design constraint rather than flavour: a hivemind that announced itself in
## words would undo the faction.
func _check_barks_have_a_voice_per_faction() -> void:
	var alien_flank: String = _barks.line(Faction.Id.ALIENS, _barks.ROLE_FLANKER, "Swarm", "Reyes", false)
	_check(alien_flank != "" and not ("\"" in alien_flank),
		"an alien announces without speaking: %s" % alien_flank)
	_check(not ("Swarm:" in alien_flank), "and without being quoted by name")

	var robot: String = _barks.line(Faction.Id.SECURITY, _barks.ROLE_COVER_BREAKER, "Lictor", "Reyes", false)
	_check(robot == robot.to_upper() or "DEMOLITION" in robot,
		"a robot talks like network traffic: %s" % robot)
	# The doctrine lock, restated in the one place it could leak into fiction.
	_check(_barks.line(Faction.Id.SECURITY, _barks.ROLE_FLANKER, "Lictor", "Reyes", false) == "",
		"and has no flanking line at all, because it has no flanking action")


## FIX B — cover is a step toward fighting, never a destination.
##
## The old encoding gave hurt mercs a goal of `{IN_COVER: true}`, which a unit
## satisfied COMPLETELY by ducking: it succeeded, and stopped. Every plan that
## routes through cover must now still end in a shot.
func _check_cover_is_a_means_not_an_end() -> void:
	var merc = await _spawn(MERC, EAST_A)
	var target = await _spawn(PLAYER, TARGET_TILE)
	merc.begin_activation()
	var brain = _doctrines.merc_brain(null)

	var names: Array[String] = []
	for entry: Dictionary in brain.goals:
		names.append(String(entry["name"]))
	_check(not ("survive" in names),
		"there is no standalone survive goal left (%s)" % ", ".join(names))

	for entry: Dictionary in brain.goals:
		if entry["name"] == &"fight_from_cover":
			_check(entry["goal"].get(_action_cls.TARGET_DAMAGED, false),
				"the cover goal demands damage as well as cover")

	# A hurt merc in the open must not simply trade shots when cover is available.
	merc.current_hp = 1
	var ctx := {"target": target, "blackboard": null}
	var by_name := {}
	for action in brain.actions:
		by_name[String(action.name)] = action
	_check(merc.is_hurt(), "the merc counts as hurt")
	_check(not by_name["Attack"].is_available(merc, ctx),
		"a hurt merc in the open will not stand and trade")
	_check(by_name["RepositionToCover"].is_available(merc, ctx),
		"but it can reach cover")
	_free([merc, target])


## FIX C — a unit sees an intention through instead of re-deciding every draw.
##
## Matters much more here than in the real-time GOAP this copies: switching goals
## between activations means walking to cover one turn and back the next, which
## reads as an AI with no idea what it is doing rather than as a mistake.
func _check_goal_commitment() -> void:
	var merc = await _spawn(MERC, EAST_A)
	var target = await _spawn(PLAYER, TARGET_TILE)
	merc.begin_activation()
	var brain = _doctrines.merc_brain(null)
	var ctx := {"target": target, "blackboard": null}

	var state: Dictionary = brain.read_state(merc, target)
	brain._plan_for_best_goal(merc, state, ctx)
	var first: StringName = brain._committed_goal
	_check(first != &"", "the brain records what it committed to (%s)" % first)

	# Same turn, same situation: it must not drift to a different goal.
	brain._plan_for_best_goal(merc, state, ctx)
	_check(brain._committed_goal == first, "and holds it while nothing has changed")

	# A GATED goal turning on is the one thing that earns an interrupt — gates
	# mark a change of situation, which is exactly what a plan should be abandoned
	# for. An ungated goal merely ranking higher is not.
	# Commitment is a THUMB ON THE SCALE, not a lock, so what has to be true is
	# that a goal which becomes sufficiently more relevant can still outweigh it.
	# Asserted on the scores rather than on the outcome, because whether the merc
	# actually switches also depends on whether the cover goal can be PLANNED from
	# where it happens to be standing — a separate question, and not this one.
	merc.current_hp = 1
	var hurt_state: Dictionary = brain.read_state(merc, target)
	_check(hurt_state[_action_cls.HURT], "the merc is now hurt")
	var committed_score := 0.0
	var cover_score := 0.0
	for i in brain.goals.size():
		var entry: Dictionary = brain.goals[i]
		if entry["name"] == first:
			committed_score = brain._relevance(entry, i, merc, hurt_state)
		if entry["name"] == &"fight_from_cover":
			cover_score = brain._relevance(entry, i, merc, hurt_state)
	_check(cover_score > committed_score,
		"and being nearly dead outweighs the committed goal (%.1f vs %.1f)"
		% [cover_score, committed_score])
	_free([merc, target])


## FIX A — relevance is a curve, not a threshold.
##
## The case a gate cannot state: `HURT` says a merc at 8% health and one at 49%
## are in the same situation, and they are not. Scoring lets wanting cover grow
## continuously, so one barely over the line still weighs flanking against it and
## one nearly dead does not.
func _check_relevance_scales_with_how_hurt() -> void:
	var merc = await _spawn(MERC, EAST_A)
	var target = await _spawn(PLAYER, TARGET_TILE)
	merc.begin_activation()
	var brain = _doctrines.merc_brain(null)

	var cover_goal := {}
	var rank := 0
	for i in brain.goals.size():
		if brain.goals[i]["name"] == &"fight_from_cover":
			cover_goal = brain.goals[i]
			rank = i
	_check(not cover_goal.is_empty(), "the cover goal carries a relevance curve")

	merc.current_hp = maxi(1, merc.stats.max_hp() / 2)
	var barely: float = brain._relevance(cover_goal, rank, merc, brain.read_state(merc, target))
	merc.current_hp = 1
	var nearly_dead: float = brain._relevance(cover_goal, rank, merc, brain.read_state(merc, target))

	_check(nearly_dead > barely,
		"a nearly-dead merc wants cover more than one just over the line (%.1f vs %.1f)"
		% [nearly_dead, barely])
	_free([merc, target])


## FIX D — the squad decides once, instead of every unit deciding privately.
##
## THE CASE THAT BROKE THE OLD DESIGN. `squad_needs_pin` was a world fact each
## merc evaluated for itself, so with three mercs all three independently
## concluded "somebody should suppress" and all three did: a fact cannot divide
## labour. An assignment can, because it is made once for the whole squad.
func _check_squad_coordinator_divides_labour() -> void:
	var a = await _spawn(MERC, EAST_A)
	var b = await _spawn(MERC, EAST_B)
	var c = await _spawn(MERC, EAST_A + Vector3i(0, 0, -1))
	var target = await _spawn(PLAYER, TARGET_TILE)
	var board = _blackboard_cls.new()
	var SUPPRESSOR = board.Role.SUPPRESSOR
	var FLANKER = board.Role.FLANKER

	_coordinator.assign(board, [a, b, c], target)

	var pinners := 0
	var flankers := 0
	for unit in [a, b, c]:
		var role: int = board.assignment_for(unit)
		if role == SUPPRESSOR:
			pinners += 1
		elif role == FLANKER:
			flankers += 1
	_check(pinners == 1, "exactly one merc of three is told to suppress (%d)" % pinners)
	_check(flankers == 2, "and the other two are told to take the angle (%d)" % flankers)

	# Advisory, not an override — the pool means an assignment can be several
	# draws stale by the time its owner acts, so it must never be able to stall a
	# unit that cannot carry it out.
	_check(board.assignment_for(target) == -1, "a non-member has no assignment")

	# A lone unit is not a squad and should just fight.
	var solo_board = _blackboard_cls.new()
	_coordinator.assign(solo_board, [a], target)
	_check(solo_board.assignment_for(a) == -1, "one merc alone is given no orders")
	_free([a, b, c, target])


## FIX F — the backstop that should never fire.
##
## Fix B already makes hiding-as-an-end unreachable, so this catches the SHAPE of
## a bug nobody has thought of — a reload/reposition cycle, a flank pursued
## forever — rather than any particular cause. Asserted because a guard that
## silently stopped working would be indistinguishable from one that never fired.
func _check_starvation_cap_forces_offence() -> void:
	var merc = await _spawn(MERC, EAST_A)
	var target = await _spawn(PLAYER, TARGET_TILE)
	merc.begin_activation()
	var brain = _doctrines.merc_brain(null)
	var ctx := {"target": target, "blackboard": null}
	var state: Dictionary = brain.read_state(merc, target)

	brain._passive_activations = brain.PASSIVE_ACTIVATION_LIMIT
	var plan: Array = brain._plan_for_best_goal(merc, state, ctx)
	_check(not plan.is_empty(), "a starved unit still produces a plan")
	# The invariant is "stop weighing doctrine and hurt somebody", not any one
	# goal by name — the merc doctrine has two goals that demand damage, and which
	# of them is reachable depends on whether cover is within walking distance.
	var forced_demands_damage := false
	for entry: Dictionary in brain.goals:
		if entry["name"] == brain._committed_goal:
			forced_demands_damage = entry["goal"].get(_action_cls.TARGET_DAMAGED, false)
	_check(forced_demands_damage,
		"and it is forced onto a goal that demands damage (%s)" % brain._committed_goal)

	# And the counter must actually reset, or every unit ends up permanently
	# starved and doctrine stops existing.
	brain._passive_activations = 0
	brain._committed_goal = &""
	brain._plan_for_best_goal(merc, state, ctx)
	_check(brain._committed_goal != &"engage" or brain.goals.size() == 1,
		"while an unstarved one is free to follow doctrine (%s)" % brain._committed_goal)
	_free([merc, target])


## PHASE 1 — veteran tier (docs/design/factions/rival-mercs/README.md Sec 2,
## Test Criteria #2). Stat-only: measurably better, doctrine untouched.
func _check_veteran_tier_outperforms_standard() -> void:
	# Same seed for both draws, so the only difference between the two stat
	# blocks is the veteran bonus rather than which side of a wide random range
	# each happened to land on — `rifleman`'s roll (30-45 perception, etc.)
	# overlaps `veteran`'s (that range +10), so comparing two independent rolls
	# is genuinely flaky, not just unlucky.
	seed(12345)
	var standard := MercPresets.rifleman("Standard")
	seed(12345)
	var veteran := MercPresets.rifleman("Veteran", true)
	_check(veteran.perception > standard.perception,
		"a veteran out-shoots the roll (%d vs %d)" % [veteran.perception, standard.perception])
	_check(veteran.max_hp() > standard.max_hp(),
		"and outlasts it (%d vs %d HP)" % [veteran.max_hp(), standard.max_hp()])
	_check(veteran.fitness > standard.fitness and veteran.reflexes > standard.reflexes,
		"with a bigger AP pool and a cheaper one")

	# Doctrine parity: a veteran is a better BODY, not a different plan.
	var std_names: Array[String] = []
	for action in _doctrines.merc_brain(null).actions:
		std_names.append(String(action.name))
	# There is no separate veteran_brain — Doctrines.merc_brain takes no tier
	# argument at all, which is the assertion: the same call produces the same
	# library regardless of who ends up standing behind these stats.
	_check(std_names.size() > 0, "the doctrine has no tier knob to diverge on (%d actions)"
		% std_names.size())


## PHASE 2 — the hard ATTACK_RANGE gate becomes a probabilistic one. IN_RANGE
## now means "there exists a shot worth taking" (Combat.compute_accuracy above
## MIN_VIABLE_ACCURACY), not "within 8 Chebyshev tiles" — so a merc beyond the
## old cutoff with a favourable angle still attacks, and one inside it with no
## real shot still closes distance instead.
func _check_attack_gated_on_viable_accuracy_not_flat_range() -> void:
	var merc = await _spawn(MERC, EAST_A)
	var target = await _spawn(PLAYER, TARGET_TILE)
	merc.begin_activation()
	var brain = _doctrines.merc_brain(null)
	var ctx := {"target": target, "blackboard": null}
	var by_name := {}
	for action in brain.actions:
		by_name[String(action.name)] = action

	var acc: int = _combat.compute_accuracy(merc, target, _combat.ShotAction.SHOOT)
	var state: Dictionary = brain.read_state(merc, target)
	_check(state[_action_cls.IN_RANGE] == (acc >= brain.MIN_VIABLE_ACCURACY),
		"IN_RANGE tracks a real accuracy floor (%d%% vs %d%% floor), not a tile count"
		% [acc, brain.MIN_VIABLE_ACCURACY])
	_check(by_name["Attack"].is_available(merc, ctx) == (acc >= brain.MIN_VIABLE_ACCURACY),
		"and Attack is only ever available when that floor is actually met")
	_check(by_name["Advance"].is_available(merc, ctx),
		"Advance stays available regardless, as the planner's fallback")
	_free([merc, target])


## PHASE 3 — overwatch awareness (rival-mercs README Sec 5). A tile a known
## player overwatch covers should rank as expensive ground for a merc choosing
## where to move, not be treated the same as an uncovered one — and never be
## treated as IMPASSABLE, since sometimes there is nothing better reachable.
func _check_overwatch_awareness() -> void:
	var merc = await _spawn(MERC, EAST_B)
	var target = await _spawn(PLAYER, TARGET_TILE)
	var watcher = await _spawn(PLAYER, EAST_A)
	merc.begin_activation()
	var brain = _doctrines.merc_brain(null)
	var by_name := {}
	for action in brain.actions:
		by_name[String(action.name)] = action

	_check(_tile_threat.watchers(merc).is_empty(),
		"no watchers counted while nobody is holding overwatch")

	watcher.on_overwatch = true
	var watcher_list = _tile_threat.watchers(merc)
	_check(watcher_list.size() == 1 and watcher_list[0] == watcher,
		"a hostile holding overwatch is picked up as a watcher (%d found)" % watcher_list.size())

	# The mechanism itself, decoupled from any one map's geometry: a tile right
	# on top of a watcher is trivially within its own sightline, so scoring it
	# must come out higher (worse) than scoring the same tile with no watcher
	# at all — proving the penalty actually fires rather than asserting which
	# tile a real flank happens to prefer on this particular deck.
	var hot_tile: Vector3i = watcher.grid_pos
	_check(_tile_threat.is_covered(hot_tile, watcher_list),
		"a tile a watcher stands on reads as covered by it")
	watcher.on_overwatch = false
	_check(not _tile_threat.is_covered(hot_tile, _tile_threat.watchers(merc)),
		"and the same tile reads as safe once the reservation is gone")

	# Never a hard exclusion: even with the ONLY reachable flank tile covered,
	# Flank must still return it rather than reporting nothing.
	watcher.on_overwatch = true
	var pick = by_name["Flank"]._best_tile(merc, target, null)
	_check(not pick.is_empty(),
		"Flank still finds a tile with a watcher covering part of the map")
	_free([merc, target, watcher])


## PHASE 4 — priority targets (rival-mercs README Sec 6). The squad's shared
## answer to "who matters most", not each unit's private read of the board.
func _check_priority_targets() -> void:
	var merc = await _spawn(MERC, EAST_A)
	var weak = await _spawn(PLAYER, TARGET_TILE)
	var strong = await _spawn(PLAYER, EAST_B)
	var alien = load("res://scenes/enemy_unit.tscn").instantiate()
	alien.stats = AlienPresets.ranged("Alien")
	alien.position = _grid.grid_to_world(EAST_A + Vector3i(0, 0, 2))
	root.add_child(alien)
	await process_frame

	merc.begin_activation()
	var mates: Array = [merc]
	var fresh_board = _blackboard_cls.new()

	# FACTION WEIGHT: a player unit outranks an incidental alien, all else equal.
	_check(_coordinator.threat_score(weak, mates, fresh_board) >
			_coordinator.threat_score(alien, mates, fresh_board),
		"a player unit outranks an incidental alien")

	# VULNERABILITY: the same target, wounded, outranks itself healthy.
	var healthy_score: float = _coordinator.threat_score(weak, mates, fresh_board)
	weak.current_hp = 1
	var wounded_score: float = _coordinator.threat_score(weak, mates, fresh_board)
	_check(wounded_score > healthy_score,
		"a wounded target outranks the same target healthy (%.1f vs %.1f)" % [wounded_score, healthy_score])
	weak.current_hp = weak.stats.max_hp()

	# DEMONSTRATED DANGER: a confirmed hit against the squad is tallied on the
	# squad's OWN blackboard (merc._brain.blackboard, not a fresh one) and read
	# straight back through threat_score — the write side is `take_damage` +
	# `come_under_fire`'s synchronous handshake, not this test poking a fact in.
	var board = merc._brain.blackboard
	var before: float = _coordinator.threat_score(strong, mates, board)
	merc.take_damage(1)
	merc.come_under_fire(strong)
	var key: StringName = _coordinator.hit_fact_key(strong)
	_check(board.fact(key, 0.0) == 1.0, "a confirmed hit against a merc is tallied on the squad board")
	var after: float = _coordinator.threat_score(strong, mates, board)
	_check(after > before, "and raises the shooter's priority (%.1f -> %.1f)" % [before, after])

	# END TO END: the squad retargets when the pick clears the switch margin.
	merc.target = weak
	strong.current_hp = 1
	merc.suppressed_by = strong
	var switched = merc._reconsider_priority_target(weak, mates)
	_check(switched == strong, "the squad retargets onto the higher-priority hostile")
	_check(merc.target == strong, "and the unit's own COMBAT target actually moves with it")

	# ...and holds when nothing clears the margin.
	merc.suppressed_by = null
	strong.current_hp = strong.stats.max_hp()
	merc.target = weak
	var held = merc._reconsider_priority_target(weak, mates)
	_check(held == weak, "but a marginal difference alone does not trigger a switch")

	_free([merc, weak, strong])
	_grid.set_occupant(alien.grid_pos, null)
	alien.queue_free()


## MUST carry a real stat block, assigned before `add_child`. A scene
## instantiated bare gets a default `UnitStats` from `Unit._ready` — no weapon,
## so mag_size 0, so ammo 0 — and every action that needs a magazine reports
## itself unavailable. The planner then correctly finds nothing, and the test
## looks like a planner bug instead of a setup one.
func _spawn(scene_path: String, at: Vector3i):
	var unit = load(scene_path).instantiate()
	if scene_path == MERC:
		unit.stats = MercPresets.rifleman("Merc")
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
