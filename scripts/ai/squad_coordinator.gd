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
