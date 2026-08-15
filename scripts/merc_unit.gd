class_name MercUnit
extends EnemyUnit
## A rival mercenary — the prototype consumer of the shared GOAP coordination
## framework. Design: docs/design/systems/coordinated-ai/
##
## STUB. It fights with the inherited ranged loop today, which makes it a
## competent lone gunman and nothing more. The entire point of the faction is the
## squad behaviour it does not have yet: `Suppress` → `Flank` negotiated through
## a shared blackboard, so two mercs never independently claim the same job. That
## arrives by overriding `_combat_turn` — the same seam SwarmUnit and SecurusUnit
## already use — and nothing else here should need to move when it does.
##
## It extends `EnemyUnit` rather than `Unit` for the awareness state machine
## (UNAWARE/ALERT/COMBAT), and that inheritance is a better fit here than it is
## for the robots: EnemyUnit's detection is LIGHT-based, and a human being unable
## to see into a dark compartment is exactly right. The squad's own flashlight
## discipline (Sec 5.2) therefore works against mercs the same way it works
## against aliens, with no new code — turn the lights off and they lose you.
##
## Being human cuts both ways, which is the faction's real hook: they carry rig
## lights of their own, so a merc squad is *visible in the dark* and its beams
## give away its position and facing. Neither of the other two factions can be
## tracked that way — the aliens carry no light and the robots do not need one.


## Which squad's blackboard this unit negotiates on. One encounter squad in the
## alpha (doc Sec 4.6: "mercs: fixed encounter squad"); a deck that wants two
## independent merc teams sets this per spawn.
@export var squad_id: String = "mercs"

var _brain: GoapBrain = null


func _init() -> void:
	# Runs after EnemyUnit._init, which set the alien defaults. Both are wrong for
	# a human and both are corrected here.
	faction = Faction.Id.RIVAL_MERCS
	# The line EnemyUnit turns OFF for the aliens. Mercs are people in a dark
	# derelict: they bring torches, the torches light them up, and everything
	# already wired to the flashlight layer — alien aggro, the accuracy light
	# term, the player's own eyes — starts reading them for free.
	has_flashlight = true


func _ready() -> void:
	super()
	# Built per unit, not shared: `GoapBrain.run` prunes actions that turn out
	# impossible during an activation, and one merc's pruning must not disarm the
	# rest of the squad. The BLACKBOARD is the shared thing, and it is shared on
	# purpose — that is the entire mechanism.
	_brain = Doctrines.merc_brain(Doctrines.blackboard_for(squad_id))
	# A claim outlives its owner's activation (see SquadBlackboard), so death is
	# the one release that cannot wait for the next revalidation sweep — a dead
	# merc's flanker claim would otherwise block the role for two more turns.
	downed.connect(func(_u: Unit) -> void: _brain.blackboard.release_all(self))


## Replaces the inherited lone-gunman loop with the planner. THE seam the whole
## framework hangs off, and deliberately the same one SwarmUnit and SecurusUnit
## already use: a unit either has a brain or it does not, and Fodder not having
## one is structural rather than a rule somebody has to remember.
func _combat_turn() -> void:
	var quarry := acquire_target()
	if quarry == null:
		return
	# The squad layer decides before this unit plans (fix D). Run from here rather
	# than on a turn-start signal because a squad only means anything once one of
	# its members has a target — and this is the first moment that is true.
	# `assigned_on_turn` makes it idempotent, so the second merc drawn reads the
	# assignment the first one caused rather than recomputing it.
	SquadCoordinator.assign(_brain.blackboard, _squadmates(), quarry)
	await _brain.run(self, quarry)


## Set on a merc that is being roused BY its own squad, so it does not turn
## round and relay the same contact back. Without it one sighting bounces around
## the squad emitting a radio call per member per hop.
var _being_relayed: bool = false


## A merc squad shares contacts over the radio, so alerting one alerts all of
## them — anywhere on the deck.
##
## This is the third distinct alert channel in the game and the point is that all
## three are different. The aliens propagate by COMPARTMENT: they have no comms,
## so a scream carries as far as a room and shutting a door contains it. The
## security robots propagate by ZONE over `SecurityNetwork`: a machine reports to
## infrastructure, which is why bypassing one sentry can still light up a whole
## checkpoint. Mercenaries are people with radios, so their alert ignores
## geometry entirely and is bounded only by who is on the net.
##
## The practical consequence for the player is a real one: against aliens you can
## isolate and pick off, and against mercs you cannot. Engaging any part of a
## merc squad engages the squad.
func _propagate_alert() -> void:
	_relay_to_squad(last_known_pos)


## Rousing this merc also puts its squad on notice — not just entering combat.
##
## `_propagate_alert` alone fires only on a confirmed sighting, which would mean
## a merc that HEARD gunfire kept it to itself. A radio squad does not do that,
## and the sound channel is exactly the sort of half-contact a squad shares.
func rouse(at: Vector3i) -> void:
	var was := alert_state
	super(at)
	if alert_state != was and not _being_relayed:
		_relay_to_squad(at)


func _relay_to_squad(at: Vector3i) -> void:
	var reached := 0
	for other: MercUnit in _squadmates():
		if other == self or other.alert_state != AlertState.UNAWARE:
			continue
		# Flagged on the RECEIVER, not the sender: it is the unit being told that
		# must not relay onward, and one hop from the unit that actually saw
		# something is the whole of the traffic.
		other._being_relayed = true
		other.rouse(at)
		other._being_relayed = false
		reached += 1
	if reached > 0:
		action_logged.emit("%s: \"Contact at %s — all callsigns, moving.\"" % [
			stats.display_name, at])


## Living members of this unit's squad, itself included. Keyed by `squad_id`
## rather than by proximity: a merc that has been separated is still on the team,
## and letting distance dissolve the squad would quietly disable coordination
## exactly when a flank has pulled somebody wide.
func _squadmates() -> Array:
	var out: Array = [self]
	for node in get_tree().get_nodes_in_group("units"):
		var other := node as MercUnit
		if other != null and other != self and not other.is_downed and other.squad_id == squad_id:
			out.append(other)
	return out


## The squad's shared intent, for the combat log. Required by the prototype's
## acceptance criteria: with claims invisible, "the squad coordinated" and "the
## draw order happened to be kind" look identical on screen.
func blackboard_summary() -> String:
	return _brain.blackboard.describe() if _brain else "no brain"
