class_name AgileHunterUnit
extends EnemyUnit
## Agile Hunter (Sec 11.5) — the alien tier's ambusher, and the alien side of the
## shared GOAP framework. Design: docs/design/systems/coordinated-ai/ Sec 5.3.
##
## Fast, fragile, solo or in pairs, never a swarm. Where Fodder is a cost you pay
## in ammunition, a Hunter is a threat you have to answer this turn.
##
## FLANKING IS ITS STANDING TACTIC, not something it waits for permission to do.
## That is a deliberate change from Sec 11.5's original framing, where the
## darkness-plus-proximity condition gated the ambush itself: under GOAP it
## flanks whenever it is in Combat and an angle exists, competing for position
## the way a mercenary would. The old condition survives as a BONUS — when it is
## met, the same plan resolves as a genuine surprise attack (see
## `ambush_bonus_accuracy`). So the condition now decides how well an ambush goes
## rather than whether the creature is allowed to try one, which is what makes it
## dangerous in the dark instead of inert in the light.
##
## Its hivemind link to Fodder costs Fodder nothing (Sec 8): a shambler crawling
## at the same target writes `ally_is_engaging_target` simply by doing what it
## always does, and this unit's planner reads that as an opening. Fodder gets no
## planner and no blackboard access, and never learns it helped.

## Light level on the target's tile at or below which this counts as darkness.
## Deliberately the same reading `Combat.light_modifier` and alien sight use — a
## Hunter ambushes in the dark the game already agrees is dark.
@export var ambush_light_threshold: float = 25.0
## How close the quarry must be for the strike to count as a surprise.
@export var ambush_proximity_range: int = 3
## Accuracy added when both ambush conditions hold (Sec 7 item 5, previously
## open). Reuses the existing accuracy math rather than inventing a bonus type,
## which was the constraint the design put on this number; the magnitude itself
## is a starting point, like every other combat constant.
@export var ambush_bonus_accuracy: int = 25

## Which nest cluster's blackboard it negotiates on. Aliens scope by compartment
## (Sec 4.6), so this is filled from the room it spawns in.
var squad_id: String = "aliens"

var _brain: GoapBrain = null


func _init() -> void:
	# Faction and the no-flashlight rule both come from EnemyUnit — a Hunter is
	# an alien in every respect except how it fights.
	pass


func _ready() -> void:
	super()
	squad_id = "aliens_room_%d" % _room_here()
	_brain = Doctrines.hunter_brain(Doctrines.blackboard_for(squad_id))
	downed.connect(func(_u: Unit) -> void: _brain.blackboard.release_all(self))


## Replaces the inherited ranged loop — it has no gun. Publishes the hivemind
## fact first, so its own planner reads a board that already reflects whatever
## the Fodder around it is doing.
func _combat_turn() -> void:
	var quarry := acquire_target()
	if quarry == null:
		return
	_brain.blackboard.set_fact(&"ally_is_engaging_target", _fodder_is_engaging(quarry))
	await _brain.run(self, quarry)


## Whether any Fodder is already on this target — in contact, or closing on it.
##
## THE HIVEMIND, mechanically, and the cheapest possible version of it: Fodder is
## not asked to intend anything or to coordinate, only to be doing what it always
## does. Reading its state costs Fodder nothing and keeps it exactly as cheap and
## dumb as it was designed to be (Sec 8).
func _fodder_is_engaging(quarry: Unit) -> bool:
	for node in get_tree().get_nodes_in_group("enemy_units"):
		var swarm := node as SwarmUnit
		if swarm == null or swarm.is_downed:
			continue
		if swarm.alert_state == AlertState.COMBAT and swarm.target == quarry:
			return true
	return false


## Whether Sec 11.5's original ambush condition holds right now: the quarry is in
## the dark AND close. Both halves, as the design specifies — a creature that
## ambushed on either alone would be either a darkness tax or a proximity tax
## rather than a reason to carry a flashlight and think about when to use it.
func has_ambush_conditions(quarry: Unit) -> bool:
	if quarry == null or quarry.is_downed:
		return false
	if GridManager.chebyshev_dist(grid_pos, quarry.grid_pos) > ambush_proximity_range:
		return false
	var tile: GridTileData = GridManager.get_tile(quarry.grid_pos)
	return tile != null and tile.light_value <= ambush_light_threshold


## The bonus itself, read by `Combat.compute_melee_accuracy` through the same
## hook `melee_accuracy_penalty` uses — so it lands on the previewed number and
## the rolled one together, rather than being applied at one of the two.
func melee_accuracy_bonus(target: Unit) -> int:
	return ambush_bonus_accuracy if has_ambush_conditions(target) else 0
