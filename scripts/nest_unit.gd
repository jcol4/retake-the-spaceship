class_name NestUnit
extends EnemyUnit
## A spawn nest, Sec 11.7. Design:
## docs/design/factions/aliens/design-choices/spawn-nests.md
##
## NOT FINISHED, and the missing half is the whole point of the thing: this
## nest has HP and can be destroyed, and it does NOT spawn anything. The spawn
## timer (one unit every 3 turns) and the 70/20/10 spawn table are the feature;
## what is here is the objective they will hang off, placed so the art can be
## seen on a deck and shot at.
##
## WHY IT IS A UNIT AND NOT A PROP. `CoverObject` is the other obvious base --
## a StaticBody3D whose HP GridManager owns -- and it was the wrong one. A nest
## needs a rendered, animated, eight-facing sprite, a name label, a hit
## reaction, and a place in the damage system that already prices every shot on
## the board. `Unit` has all of that; `CoverObject` has none of it and would
## have meant reimplementing the sprite pipeline for one prop. The cost is that
## a nest is drawn from the turn pool like anything else, which `take_turn`
## below answers in one line.
##
## It extends `EnemyUnit` rather than `Unit` for the faction plumbing (alert
## state, the room-graph hooks, the action log), not for the senses -- see
## `take_turn`.


## Passes, every time, without looking.
##
## Deliberately does NOT call `super()`. `EnemyUnit.take_turn` opens with
## `_look_for_targets`, and a nest has no senses at all: it does not see, hear,
## feel footsteps, acquire, alert or propagate. It is a thing that sits in a
## room and bleeds aliens until someone kills it, and the moment it can notice
## a squad it stops reading as scenery and starts reading as a monster that
## forgot to attack.
##
## When the spawn timer lands it goes HERE, not in an override of `_idle_turn`:
## a nest producing a unit is what its activation IS, not something it does
## while idling.
##
## Nothing else is needed to keep it still: movement is something a unit spends
## its own activation on, and this one never spends it. The eight rendered
## facings are therefore eight views of one motionless object, and which is
## drawn is settled entirely by the camera (`camera_rig.gd` snaps in quarter
## turns; sprite direction is unit yaw MINUS camera yaw).
func take_turn() -> void:
	pass
