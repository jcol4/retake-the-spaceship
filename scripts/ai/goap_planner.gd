class_name GoapPlanner
extends RefCounted
## A* over the action graph: given a world state, a goal and a library of
## actions, returns the cheapest ordered plan that satisfies the goal.
## Design: docs/design/systems/coordinated-ai/
##
## FORWARD search, not the backward chaining GOAP is usually written with. The
## reason is `GoapAction.is_available`: half of what gates an action here is
## real-world state (ammo in the magazine, a reachable tile, a role an ally has
## not already claimed) rather than symbolic state, and that can only be asked
## honestly of a unit standing somewhere specific. Backward chaining would have
## to guess at it.
##
## The graphs are tiny — under a dozen actions, plans two or three deep — so the
## cost of forward search is irrelevant and the clarity is worth a great deal.
## MAX_PLAN_LENGTH is what keeps it that way if somebody adds a cycle.

const MAX_PLAN_LENGTH := 4
## Guard against a pathological action library. Nothing near this is reachable
## with the current rosters; it exists so a bad edit degrades to "no plan" rather
## than to a frozen turn.
const MAX_NODES := 256
## The `ctx` key holding where the plan being expanded has the unit standing, set
## before each action is asked about a node and erased once planning is done.
## Each node carries its own tile — the destination of the last move in its plan
## (GoapAction.planned_tile) — so a shot after a move is priced at the move's end
## (GoapBrain.shot_cost): close quarters makes an SMG's shot cheaper there.
const PLAN_TILE := &"plan_tile"


## Cheapest ordered list of actions taking `state` to a state satisfying `goal`,
## or empty when the goal is unreachable with what this unit can currently do.
##
## `goal` is a Dictionary of world-state keys to required values, so "get a
## flanking angle on someone who is pinned" is `{TARGET_SUPPRESSED: true,
## FLANKED: true}` and the planner works out that Suppress has to precede Flank
## without either action knowing about the other.
static func plan(unit: Unit, actions: Array, state: Dictionary, goal: Dictionary,
		ctx: Dictionary) -> Array:
	if _satisfies(state, goal):
		return []
	# Each frontier entry: {state, plan, cost}. Kept as a plain sorted array —
	# with a handful of actions a priority queue would be more code than search.
	# Each node also carries the AP the unit would have LEFT at that point. Without
	# it every action was checked against the unit's current AP, so a plan like
	# [walk five tiles to cover, shoot] passed even when the walk spent the shot —
	# the unit walked, replanned, could not afford the shot, and ended its turn
	# having fired nothing.
	var frontier: Array = [{"state": state, "plan": [], "cost": 0, "ap": unit.ap,
		"tile": unit.grid_pos}]
	var best_plan: Array = []
	var best_cost := 1 << 30
	var expanded := 0

	while not frontier.is_empty() and expanded < MAX_NODES:
		frontier.sort_custom(func(a, b): return _f_score(a, goal) < _f_score(b, goal))
		var node: Dictionary = frontier.pop_front()
		expanded += 1
		if node["cost"] >= best_cost:
			continue  # already worse than a complete plan we hold
		if node["plan"].size() >= MAX_PLAN_LENGTH:
			continue
		ctx[PLAN_TILE] = node["tile"]
		for action: GoapAction in actions:
			if not action.preconditions_met(node["state"]):
				continue
			if not action.is_available(unit, ctx):
				continue
			# No action twice in one plan. Every action here is idempotent in its
			# effects, so a repeat can only ever add cost — and without this the
			# search happily builds Reload-Reload-Reload.
			if action in node["plan"]:
				continue
			var step_cost := action.ap_cost(unit, ctx)
			if step_cost > int(node["ap"]):
				continue  # cannot be afforded after the steps before it
			var next_state: Dictionary = node["state"].duplicate()
			var fx: Dictionary = action.planned_effects(unit, ctx)
			for key: StringName in fx:
				next_state[key] = fx[key]
			var next_cost: int = node["cost"] + step_cost
			if next_cost >= best_cost:
				continue
			var next_ap: int = 0 if action.ends_activation else int(node["ap"]) - step_cost
			var next_plan: Array = node["plan"].duplicate()
			next_plan.append(action)
			if _satisfies(next_state, goal):
				best_plan = next_plan
				best_cost = next_cost
				continue
			frontier.append({"state": next_state, "plan": next_plan, "cost": next_cost,
				"ap": next_ap, "tile": action.planned_tile(unit, ctx, node["tile"])})
	# Gone before anything executes, so an action's `ap_cost` at execution time
	# prices where the unit really is, not where some search branch left it.
	ctx.erase(PLAN_TILE)
	return best_plan


## Cost so far plus an admissible heuristic: one AP per goal key still unmet.
## Deliberately an underestimate — every real action costs at least 1 AP — so A*
## keeps its guarantee of finding the cheapest plan rather than merely a plan.
static func _f_score(node: Dictionary, goal: Dictionary) -> int:
	var unmet := 0
	for key: StringName in goal:
		if node["state"].get(key, false) != goal[key]:
			unmet += 1
	return int(node["cost"]) + unmet


static func _satisfies(state: Dictionary, goal: Dictionary) -> bool:
	for key: StringName in goal:
		if state.get(key, false) != goal[key]:
			return false
	return true
