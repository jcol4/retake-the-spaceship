class_name GoapBrain
extends RefCounted
## Drives one planning unit through an activation: reads the world, ranks goals,
## plans, and executes — replanning whenever a step fails.
## Design: docs/design/systems/coordinated-ai/
##
## FACTION-NEUTRAL. What makes a merc squad feel unlike a robot squad is entirely
## the two things handed in from outside: the ACTION LIBRARY it may draw from and
## the GOAL ORDER it wants. Cerberus does not flank because `Flank` is not in its
## library at all (doc Sec 5.2, a locked decision), not because it scores badly —
## a doctrine expressed as a low score is one bad tuning pass from evaporating.
##
## Sits behind `_combat_turn`, the same override point SwarmUnit and SecurusUnit
## already use, so a unit either has a brain or does not. That is what keeps
## Fodder planner-free structurally rather than by discipline (doc Sec 8).

## Replanning cadence (doc Sec 7 item 1, previously open).
##
## Plan on entering combat, then REPLAN AFTER EVERY EXECUTED STEP, rather than
## walking a plan through to its end. Chosen after building it, and the reasoning
## is specific to this game rather than general GOAP practice: the initiative
## pool means an arbitrary number of other units act between a unit's own
## activations, so a plan more than one step old was formed against a board that
## has since moved. Since plans here are two or three steps deep over a library
## of under a dozen actions, a full replan costs less than the bookkeeping needed
## to decide whether the old plan is still valid.
##
## The cheap alternative — plan once per activation, execute blind — is what
## produces an AI that suppresses a unit somebody else has already killed.

## How many turns a unit sticks with a goal before it is willing to re-rank
## freely (fix C — commitment/hysteresis).
##
## Matters far more here than it would in the real-time GOAP this is modelled on.
## F.E.A.R. replanned several times a second, so a goal picked badly corrected
## itself in under a second and nobody saw it. A unit here acts once per draw
## from a random pool, so switching goals between activations means spending one
## whole turn walking toward cover and the next walking back — which does not
## read as a mistake, it reads as an AI with no idea what it is doing.
##
## Two turns: long enough to finish a two-step intention, short enough that a
## stale plan cannot define a whole fight.
const COMMITMENT_TURNS := 2

## Relevance a goal gets from its position in the list (fix A). Goals are still
## AUTHORED in priority order — that is how a designer thinks about doctrine —
## but the order is converted to a score so everything else can be expressed as
## an adjustment to it rather than as another special case in the selection loop.
const RANK_RELEVANCE_STEP := 10.0

## Bonus the currently-committed goal receives (fix C, restated for fix A).
##
## Commitment started as a hard lock: hold this goal, ignore the ranking. Once
## goals carry scores, that is better said as a THUMB ON THE SCALE — the unit
## keeps doing what it was doing unless something else is meaningfully better,
## which is the standard way to get hysteresis out of a scored system and much
## less brittle than a lock with an exception list bolted to it.
##
## Set just under one rank step, deliberately: commitment beats a goal that is
## merely tied or marginally better, and loses to one a full priority tier above
## it. So a unit sees an intention through, and still drops it the moment the
## situation genuinely changes.
const COMMITMENT_BONUS := 9.0

## Bonus a goal gets when the squad coordinator has assigned this unit its role
## (fix D). A full rank step and a bit, so an order reorders the doctrine — being
## told to cover somebody must beat wanting the angle for yourself — while still
## being a score, so a unit that cannot carry out its order falls through to the
## next thing rather than stalling on an assignment made several draws ago.
const ASSIGNMENT_BONUS := 15.0

## Consecutive activations a unit may spend without offering violence before the
## engage goal is forced (fix F).
##
## A backstop that should never fire. Fix B already makes hiding-as-an-end
## unreachable, so this exists for the failure nobody has thought of — a
## reload/reposition cycle, an unreachable flank pursued forever. It catches the
## SHAPE of the bug (this unit has stopped fighting) rather than any particular
## cause, which is what a guard is for.
const PASSIVE_ACTIVATION_LIMIT := 3

## The probabilistic replacement for the old flat `chebyshev_dist <=
## EnemyUnit.ATTACK_RANGE` cutoff (docs/design/factions/rival-mercs/README.md
## Sec 3). `IN_RANGE` no longer means "close enough" — it means "a shot exists
## that isn't a wild one," read straight off `Combat.compute_accuracy`, which
## already folds in distance falloff, cover, light, suppression and weapon
## range. 15 is the same rough floor a player would eyeball as "not a wild
## shot"; `EnemyUnit.ATTACK_RANGE` still governs Flank's tile search
## (`GoapActions.Flank._best_tile`) and the non-GOAP alien loop
## (`EnemyUnit._combat_turn`), but no longer gates a GOAP unit's
## shoot-vs-advance decision on its own.
const MIN_VIABLE_ACCURACY := 15

var actions: Array = []
## Authored highest priority first. Each entry:
##   {"name": StringName, "goal": {...}, "when": StringName?, "relevance": Callable?}
##
## `relevance` is the fix-A escape hatch: a goal that needs to care HOW MUCH
## rather than merely whether — "I am at 8% health" is a different situation from
## "I am at 49%", and a gate cannot say so — supplies a Callable returning a float
## to add to its rank score. Goals without one are ranked exactly as before.
var goals: Array = []
var blackboard: SquadBlackboard = null

## The goal this unit is currently seeing through, and the turn it took it up.
var _committed_goal: StringName = &""
var _committed_turn: int = -1
## Consecutive activations this unit has ended without attacking anything.
var _passive_activations: int = 0


func _init(action_library: Array, goal_list: Array, board: SquadBlackboard = null) -> void:
	actions = action_library
	goals = goal_list
	blackboard = board


## Runs `unit`'s whole activation. Coroutine — callers MUST await.
func run(unit: Unit, target: Unit) -> void:
	if blackboard:
		# Swept once at the top of the activation rather than on a signal per way
		# a claim can die. See SquadBlackboard.revalidate.
		blackboard.revalidate()
	var attacked := false
	var guard := 0
	while unit.ap > 0 and not unit.is_downed and target != null and not target.is_downed:
		# Belt and braces against an action that reports success without spending
		# anything. A planner that cannot make progress must end the turn, not
		# spin inside it — the turn loop awaits this.
		guard += 1
		if guard > 8:
			break
		var ctx := {"target": target, "blackboard": blackboard}
		var state := read_state(unit, target)
		var plan := _plan_for_best_goal(unit, state, ctx)
		if plan.is_empty():
			break
		var step: GoapAction = plan[0]
		var ap_before := unit.ap
		if not await step.execute(unit, ctx):
			# The step turned out to be impossible after all. Dropping it from
			# this activation rather than retrying is what stops an unreachable
			# flank tile becoming an infinite loop.
			actions = actions.filter(func(a): return a != step)
			continue
		if step.effects.get(GoapAction.TARGET_DAMAGED, false) \
				or step.effects.get(GoapAction.TARGET_SUPPRESSED, false):
			attacked = true
		if unit.ap == ap_before:
			break  # executed but cost nothing — treat as no progress
	# Fix F. Counted per ACTIVATION rather than per action: a unit that spent its
	# whole turn repositioning has been passive once, however many tiles it walked.
	_passive_activations = 0 if attacked else _passive_activations + 1
	if blackboard and (unit.is_downed or target == null or target.is_downed):
		blackboard.release_all(unit)


## The highest-priority goal that yields a plan. Falling THROUGH unreachable
## goals rather than failing on them is what gives doctrine its shape: a merc
## wants to flank, and shoots only because it currently cannot.
##
## A goal may carry a `when` key naming a world-state fact that must hold for it
## to apply at all. That is what makes a goal REACTIVE rather than merely
## low-priority — the mercs' self-preservation goal is gated on having actually
## been hurt (Sec 5.1: cover is "used when *they're* flanked", not an opening
## move). Ranking it low instead would not do: an unhurt merc standing in the
## open satisfies nothing else more cheaply than by ducking, so it would still
## duck first, every time, and never flank at all.
## The most relevant goal that yields a plan.
##
## Scored rather than merely ordered (fix A), which is what F.E.A.R. did: each
## goal reports how much it matters right now and the highest wins. Rank supplies
## the base score, so a doctrine still reads as a priority list; commitment and
## per-goal relevance functions are adjustments on top.
##
## Falling THROUGH goals that yield no plan is unchanged and still what gives
## doctrine its shape: a merc wants to flank, and shoots only because it
## currently cannot.
func _plan_for_best_goal(unit: Unit, state: Dictionary, ctx: Dictionary) -> Array:
	# FIX F, applied before anything else has a say. A unit that has gone this
	# many activations without offering violence stops weighing doctrine and
	# shoots — whatever it thought it was doing, it has stopped being a threat,
	# and being a threat is the entire job.
	if _passive_activations >= PASSIVE_ACTIVATION_LIMIT:
		# EVERY offensive goal is tried, not just the first. Stopping at the first
		# was a bug the moment a second ungated damage goal existed: the merc
		# doctrine's `fight_from_cover` demands cover as well as damage, so on a
		# tile with no reachable cover it plans nothing — and a starvation guard
		# that gave up there would leave the unit starved forever, which is the
		# exact failure it exists to break.
		for entry: Dictionary in goals:
			if not entry["goal"].get(GoapAction.TARGET_DAMAGED, false):
				continue
			if entry.get("when", &"") != &"":
				continue
			var forced := GoapPlanner.plan(unit, actions, state, entry["goal"], ctx)
			if not forced.is_empty():
				_commit_to(entry["name"])
				return forced

	var scored: Array = []
	for i in goals.size():
		var entry: Dictionary = goals[i]
		if not _gate_open(entry, state):
			continue
		scored.append({"entry": entry, "score": _relevance(entry, i, unit, state)})
	scored.sort_custom(func(a, b): return a["score"] > b["score"])

	for row: Dictionary in scored:
		var entry: Dictionary = row["entry"]
		var plan := GoapPlanner.plan(unit, actions, state, entry["goal"], ctx)
		if not plan.is_empty():
			_commit_to(entry["name"])
			return plan
	return []


## Rank, plus the squad's orders, plus the commitment thumb, plus whatever the
## goal says about itself.
func _relevance(entry: Dictionary, rank: int, unit: Unit, state: Dictionary) -> float:
	var score := float(goals.size() - rank) * RANK_RELEVANCE_STEP
	# The squad layer's say (fix D). A big enough push to reorder the doctrine —
	# being told to cover somebody has to beat wanting the angle yourself — but
	# still a SCORE rather than an override, so a unit that cannot carry out its
	# order quietly does the next best thing instead of stalling.
	if entry.get("role", -1) != -1 and blackboard \
			and blackboard.assignment_for(unit) == entry["role"]:
		score += ASSIGNMENT_BONUS
	if entry["name"] == _committed_goal \
			and TurnManager.turn_number - _committed_turn < COMMITMENT_TURNS:
		score += COMMITMENT_BONUS
	var fn: Callable = entry.get("relevance", Callable())
	if fn.is_valid():
		score += float(fn.call(unit, state))
	return score


func _gate_open(entry: Dictionary, state: Dictionary) -> bool:
	var gate: StringName = entry.get("when", &"")
	return gate == &"" or state.get(gate, false)


func _commit_to(goal_name: StringName) -> void:
	if goal_name == _committed_goal:
		return
	_committed_goal = goal_name
	_committed_turn = TurnManager.turn_number


## Snapshot of the world as symbolic facts. The planner reasons over this and
## nothing else, which is what keeps it faction-neutral.
func read_state(unit: Unit, target: Unit) -> Dictionary:
	var has_los := target != null and GridManager.has_line_of_sight(unit, target)
	# PROBABILISTIC, not a tile count (Sec 3 of the rival-mercs design doc). Still
	# capped by ATTACK_RANGE/LOS through `has_los` and Combat's own distance and
	# weapon-range penalties, but the cutoff itself is now "would this shot be
	# worth taking", not "is the target within N tiles" — a merc with a clean
	# angle at range 9 is in range; one at range 3 through heavy cover, hunkered
	# target, and bad light may not be.
	var in_range := has_los \
		and Combat.compute_accuracy(unit, target, Combat.ShotAction.SHOOT) >= MIN_VIABLE_ACCURACY
	var covered := not GridManager.covered_sides(unit.grid_pos).is_empty()
	# Explicitly typed: `defending_cover` returns an untyped Array, so indexing it
	# yields a Variant and `:=` has nothing to infer from.
	var target_behind_cover: bool = target != null \
		and Combat.defending_cover(unit.grid_pos, target.grid_pos)[0] != MapData.Cover.NONE
	return {
		GoapAction.HAS_LOS: has_los,
		GoapAction.IN_RANGE: in_range,
		GoapAction.MAGAZINE_READY: unit.can_shoot(),
		GoapAction.IN_COVER: covered,
		GoapAction.TARGET_SUPPRESSED: target != null and target.is_suppressed(),
		GoapAction.COVER_BROKEN: target != null \
			and Combat.defending_cover(unit.grid_pos, target.grid_pos)[0] == MapData.Cover.NONE,
		GoapAction.FLANKED: target != null \
			and Combat.defending_cover(unit.grid_pos, target.grid_pos)[0] == MapData.Cover.NONE \
			and has_los,
		GoapAction.NEAR_SQUAD: true,
		GoapAction.TARGET_DAMAGED: false,
		GoapAction.HURT: unit.current_hp * 2 <= unit.stats.max_hp(),
		# All three clauses matter. No cover means there is nothing to pin them
		# out of; already pinned means a second burst adds nothing; and with no
		# ally left, covering fire covers nobody and the unit should just shoot.
		GoapAction.SQUAD_NEEDS_PIN: has_los and target_behind_cover \
			and target != null and not target.is_suppressed() \
			and not unit.allies().is_empty(),
	}
