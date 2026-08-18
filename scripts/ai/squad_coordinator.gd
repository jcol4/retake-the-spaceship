class_name SquadCoordinator
extends RefCounted
## Assigns roles to a squad before its members act, instead of leaving each unit
## to infer its own from the world.
## Design: docs/design/systems/coordinated-ai/ Sec 5.
##
## THE F.E.A.R. ARCHITECTURE, and the piece this framework was missing. Orkin
## kept squad coordination in a layer ABOVE the planner: a squad manager clustered
## nearby AI, chose a squad behaviour, and pushed orders down to individuals whose
## own planners then worked out how to carry them out. Nothing about a soldier's
## goal set knew it was in a squad.
##
## What this replaces is `squad_needs_pin` — a world-state fact that was really an
## assignment decision in disguise. It worked, and it worked for exactly two
## mercs: with three, every unit that saw an unpinned target in cover concluded
## "somebody should suppress" and all of them did, because a fact each unit
## evaluates privately cannot divide labour. Deciding once, for the squad, is the
## only thing that scales.
##
## The one thing it must survive is not knowing the draw order. F.E.A.R. could
## assign and then watch the squad execute; the initiative pool hands units out in
## random order, and an assignment made now may not be acted on for several draws
## or at all. So assignments are ADVISORY: a unit that can carry out its order
## does, a unit that cannot falls straight back to its own doctrine ranking, and
## nothing waits on anybody.

## Turns an assignment stays valid before the squad is re-read. Short, because the
## board it was computed against is being reshuffled by every intervening draw.
const ASSIGNMENT_TURNS := 1


## Reads a squad and writes one role assignment per member onto the blackboard.
##
## Deliberately does NOT claim the roles. A claim is a commitment made by a unit
## that is acting; an assignment is a suggestion made before anyone has moved, and
## conflating the two would have a suppressor's role claimed — and its bark
## fired — on a turn it may never be drawn to act on.
static func assign(board: SquadBlackboard, members: Array, target: Unit) -> void:
	if board == null or target == null or target.is_downed:
		return
	if TurnManager.turn_number - board.assigned_on_turn < ASSIGNMENT_TURNS:
		return
	board.assigned_on_turn = TurnManager.turn_number
	board.clear_assignments()

	var live: Array = members.filter(func(u: Unit) -> bool:
		return is_instance_valid(u) and not u.is_downed)
	if live.size() < 2:
		return  # one unit is not a squad; let it fight its own doctrine

	# Only worth pinning somebody who is behind something. Against a target in the
	# open there is nothing to pin them out of, and the whole squad should simply
	# shoot.
	if target.is_suppressed():
		return
	var pinner := _best_suppressor(live, target)
	if pinner == null:
		return
	board.assign(pinner, SquadBlackboard.Role.SUPPRESSOR)
	# Everyone else takes the angle the covering fire is about to buy. They
	# compete for the FLANKER claim normally when they act — the assignment says
	# who should try, the blackboard still enforces that only one succeeds.
	for unit: Unit in live:
		if unit != pinner:
			board.assign(unit, SquadBlackboard.Role.FLANKER)


## The member best placed to lay down fire: has line of sight, has the rounds for
## a full burst, and is the one whose cover the target most benefits from — i.e.
## the unit with the WORST angle, which is exactly the one that gains least by
## trying to shoot and loses least by spending its turn covering.
static func _best_suppressor(live: Array, target: Unit) -> Unit:
	var best: Unit = null
	var best_score := -1
	for unit: Unit in live:
		if not unit.can_suppress() or not GridManager.has_line_of_sight(unit, target):
			continue
		# Cover between shooter and target scores HIGH here, which reads backwards
		# until you say it out loud: the unit that cannot get a clean shot is the
		# right one to spend its activation making sure nobody else gets shot.
		var score: int = Combat.defending_cover(unit.grid_pos, target.grid_pos)[0]
		if score > best_score:
			best_score = score
			best = unit
	return best


## PRIORITY TARGETS (rival-mercs README Sec 6). The squad's shared answer to
## "who matters most right now", decided once and read by every member —
## exactly the same move `assign` already made for role negotiation, and for
## the same reason: a fact each unit evaluates privately ("the wounded one
## looks juicier") cannot divide the squad's attention any better than
## `squad_needs_pin` could divide its labour before `assign` existed.
##
## Candidates are every hostile visible to AT LEAST ONE live member. A hostile
## the whole squad is currently blind to cannot be this activation's priority
## regardless of how it would score; `MercUnit._reconsider_priority_target`
## separately checks the ACTING unit's own line of sight before switching onto
## the pick, so this only ever buys the squad a heading, never x-ray vision —
## the same limit the radio-contact channel already carries.
static func update_priority_target(board: SquadBlackboard, members: Array) -> Unit:
	if board == null:
		return null
	var live: Array = members.filter(func(u: Unit) -> bool:
		return is_instance_valid(u) and not u.is_downed)
	var seen := {}
	for member: Unit in live:
		for hostile: Unit in member.hostiles():
			if hostile.is_downed or seen.has(hostile):
				continue
			if GridManager.has_line_of_sight(member, hostile):
				seen[hostile] = true
	var best: Unit = null
	var best_score := -INF
	for hostile: Unit in seen:
		var score := threat_score(hostile, live, board)
		if score > best_score:
			best_score = score
			best = hostile
	if best != null:
		board.set_fact(&"priority_target", best)
	return best


## How much attention the squad owes `hostile` right now — higher means "worth
## organising the squad's plan around", not merely "worth shooting at". Additive
## rather than multiplicative on purpose: each factor should be able to matter
## on its own — a barely-wounded VIP in the open still outranks a healthy
## nobody — rather than one weak factor zeroing out a strong one.
const FACTION_WEIGHT_PRIMARY := 10.0
const FACTION_WEIGHT_INCIDENTAL := 3.0
const COVER_WEIGHT := 2.0
const VULNERABILITY_WEIGHT := 5.0
const SUPPRESSING_ALLY_BONUS := 4.0
const CONFIRMED_HIT_WEIGHT := 2.0

static func threat_score(hostile: Unit, members: Array, board: SquadBlackboard) -> float:
	if hostile == null or hostile.is_downed:
		return -INF
	var score := 0.0
	# FACTION WEIGHT. A player unit is the mission; an alien that wandered into
	# the same fight is not worth the squad's coordinated attention, only
	# whatever a member can spend on it opportunistically on its own turn.
	score += FACTION_WEIGHT_PRIMARY if hostile.faction == Faction.Id.CONTRACTORS \
		else FACTION_WEIGHT_INCIDENTAL
	# POSITIONAL THREAT. The BEST cover this target enjoys against any live
	# member — a target every member but one is stuck shooting through a crate
	# at is worth planning around; one already standing in the open is
	# something any single member can already punish without the squad
	# needing to agree on anything.
	var best_cover := MapData.Cover.NONE
	for member: Unit in members:
		if member.is_downed:
			continue
		var cover: int = Combat.defending_cover(member.grid_pos, hostile.grid_pos)[0]
		best_cover = maxi(best_cover, cover)
	score += float(best_cover) * COVER_WEIGHT
	# VULNERABILITY. Worth finishing over a healthy target at equal threat —
	# real focus fire goes to the wounded one, not whoever was spotted first.
	var hp_frac := float(hostile.current_hp) / float(maxi(hostile.stats.max_hp(), 1))
	score += (1.0 - hp_frac) * VULNERABILITY_WEIGHT
	# DEMONSTRATED DANGER. Currently pinning one of ours (read straight off
	# `Unit.suppressed_by`, live state rather than a tally), or has already
	# landed a confirmed hit on the squad this encounter (see
	# `MercUnit.take_damage` / `come_under_fire`, which write the fact this
	# reads under `hit_fact_key`).
	for member: Unit in members:
		if member.suppressed_by == hostile:
			score += SUPPRESSING_ALLY_BONUS
			break
	if board:
		score += float(board.fact(hit_fact_key(hostile), 0.0)) * CONFIRMED_HIT_WEIGHT
	return score


## Blackboard fact key a confirmed hit against the squad is tallied under, keyed
## by instance id rather than by the shooter itself: a Dictionary key that is an
## Object compares by identity, so a freed/downed shooter would still resolve
## correctly today, but the id survives even a future change to how shooters are
## looked up here. Shared between the writer (`MercUnit.come_under_fire`) and
## the reader (`threat_score` above) so the two can never drift out of format.
static func hit_fact_key(shooter: Unit) -> StringName:
	return StringName("hit_count_%d" % shooter.get_instance_id())
