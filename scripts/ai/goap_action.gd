class_name GoapAction
extends RefCounted
## One thing a planning unit can do, with what it needs, what it changes, and
## what it costs. Design: docs/design/systems/coordinated-ai/
##
## COSTS COME FROM THE AP FORMULAS, never from a table of their own. That is an
## acceptance criterion rather than a preference: a planner scoring against
## invented numbers would drift out of step with what the actions actually charge
## the moment either is tuned, and the drift would show up as an AI that plans
## things it cannot afford. `ap_cost` therefore asks the unit, and the unit asks
## `UnitStats.action_cost` — the same call the player's buttons are priced by.
##
## Subclasses override four things: `is_available`, `apply_effects`, `ap_cost`
## and `execute`. Everything else — the planner, the blackboard, the goal
## ranking — is faction-neutral and lives above this.

## Symbolic effect keys. The planner reasons over these rather than over the game
## state, which is what makes an action graph searchable at all.
const HAS_LOS := &"has_los_to_target"
const IN_COVER := &"in_cover"
const TARGET_SUPPRESSED := &"target_suppressed"
const FLANKED := &"flanking_position_reached"
const IN_RANGE := &"in_attack_range"
const MAGAZINE_READY := &"magazine_ready"
const COVER_BROKEN := &"target_cover_broken"
const NEAR_SQUAD := &"near_squad"
const TARGET_DAMAGED := &"target_damaged"
## Whether this unit has taken enough damage to start caring about its own skin.
## Not something an action produces — it is a fact about the world used to GATE
## goals, which is how "reactive" is expressed (see GoapBrain's `when`).
const HURT := &"is_hurt"
## Whether pinning this target would be worth more to the SQUAD than shooting it
## would be worth to this unit: the target is behind cover, nobody has pinned it
## yet, and there is a living ally to exploit the window.
##
## Also a gate rather than an effect. It is what decides which merc suppresses
## and which one takes the angle — without it both plan orders satisfy the
## doctrine goal equally, the planner picks arbitrarily, and every merc flanks
## for itself while nobody ever covers anybody.
const SQUAD_NEEDS_PIN := &"squad_needs_pin"

var name: StringName = &"action"
## World-state keys this action needs true before it can be planned.
var preconditions: Dictionary = {}
## World-state keys it makes true. The planner treats these as facts once the
## action is in the plan, which is how a two-step plan (suppress, then flank) is
## discovered rather than scripted.
var effects: Dictionary = {}


## Runtime gate, asked of the real world rather than of the symbolic state.
##
## Separate from `preconditions` on purpose, and the split matters: preconditions
## are what the PLANNER reasons about and may satisfy with an earlier action,
## while this is what cannot be arranged — no ammo, no target, no reachable tile,
## a role already claimed by an ally. Folding the two together would have the
## planner cheerfully build plans whose first step is impossible.
func is_available(_unit: Unit, _ctx: Dictionary) -> bool:
	return true


## AP this action would cost `unit`, from the AP-rework formulas. Also the
## planner's edge weight, so a plan is cheap in exactly the currency the unit
## actually spends.
func ap_cost(_unit: Unit, _ctx: Dictionary) -> int:
	return 1


## Roughly "how good is taking this action right now", in damage-equivalent
## points — hit% * weapon damage for a shot, the pin's worth for Suppress, 0.0
## (the default) for actions whose value is indirect, like a reposition.
##
## NOT the planner's edge weight — `ap_cost` stays what A* searches against, so
## the cheapest-plan guarantee is untouched. This is a second number scored
## ONLY by things that need "which of several legal actions is actually worth
## it", per docs/design/factions/rival-mercs/README.md Sec 3: priority-target
## weighing and bait-unit selection read this, `GoapPlanner` never does.
func expected_value(_unit: Unit, _ctx: Dictionary) -> float:
	return 0.0


## Runs the action. Coroutine — callers MUST await. Returns false when it could
## not be carried out after all, which tells the executor to stop and replan
## rather than walk the rest of a plan built on a false assumption.
func execute(_unit: Unit, _ctx: Dictionary) -> bool:
	return false


## Writes this action's effects into a symbolic state during planning. Overridden
## only by actions whose effects depend on context; the default copies `effects`.
func apply_effects(state: Dictionary) -> Dictionary:
	var out := state.duplicate()
	for key: StringName in effects:
		out[key] = effects[key]
	return out


## Whether `state` satisfies every precondition. Absent keys count as false, so
## a plan is never built on a fact nobody established.
func preconditions_met(state: Dictionary) -> bool:
	for key: StringName in preconditions:
		if state.get(key, false) != preconditions[key]:
			return false
	return true
