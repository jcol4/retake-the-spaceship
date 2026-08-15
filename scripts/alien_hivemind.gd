extends Node
## Autoload. Ship-wide alien escalation — the aliens' counterpart to
## `SecurityNetwork`, and deliberately much smaller than it.
## Design: docs/design/systems/coordinated-ai/ Sec 6.
##
## LOCAL IS STILL THE DEFAULT. Alien alerts are scoped to a compartment
## (EnemyUnit._propagate_alert), and isolating rooms with doors stays a valid,
## intentional player strategy (Sec 11.2). This file adds a small set of loud
## events that break that scoping ONCE, ship-wide, and a rule for settling back
## down afterwards. It is not a second alert system running in parallel.
##
## What escalation does NOT do is as important as what it does. Roused aliens go
## to ALERT and walk toward the noise — they do not skip to COMBAT, and they gain
## no knowledge of where anybody actually is. So escalation compresses "how many
## things are heading your way" without ever breaking "they still have to find
## you to fight you", and the local detection rules keep deciding everything that
## happens after the first step.

signal escalated(at: Vector3i, reason: String)
signal de_escalated()

## Turns an escalation stays live before the ship settles. Aliens roused by it
## that never made contact fall back to UNAWARE.
##
## Tunable rather than hardcoded per the design's explicit instruction (Sec 7
## item 4). Four turns is long enough that a squad cannot simply stand still and
## wait it out, short enough that one tripped alarm does not define the rest of
## the mission.
const DE_ESCALATION_TURNS := 4

## Radius that means "the whole deck" when routed through the ordinary sound
## channel. Not infinity — a real number keeps `report_noise`'s distance test
## honest, and no deck is anywhere near this wide.
const SHIP_WIDE_RADIUS := 9999

var is_escalated: bool = false
var last_trigger: Vector3i = Vector3i.ZERO
var _escalated_on_turn: int = -1
## Units this escalation roused, so de-escalation can settle exactly those and
## leave anything that found a real reason to be awake alone.
var _roused: Array[Unit] = []


func _ready() -> void:
	TurnManager.turn_started.connect(_on_turn_started)


func reset() -> void:
	is_escalated = false
	_escalated_on_turn = -1
	_roused.clear()


## Wakes every UNAWARE alien on the ship and sends it toward `at`.
##
## Rouse, not engage: `rouse` puts a unit into ALERT with a position to
## investigate, which is the same state a neighbour's scream produces. Nothing
## here hands out targets.
func escalate(at: Vector3i, reason: String) -> int:
	last_trigger = at
	is_escalated = true
	_escalated_on_turn = TurnManager.turn_number
	var woken := 0
	for node in get_tree().get_nodes_in_group("enemy_units"):
		var alien := node as EnemyUnit
		# Aliens only. The security robots have their own escalation path — the
		# zone broadcast — and a hivemind is not something a machine belongs to.
		if alien == null or alien.is_downed or alien.faction != Faction.Id.ALIENS:
			continue
		if alien.alert_state != EnemyUnit.AlertState.UNAWARE:
			continue  # already awake for its own reasons; leave it alone
		alien.rouse(at)
		if not (alien in _roused):
			_roused.append(alien)
		woken += 1
	TurnManager.log_message.emit("!!! %s — the ship stirs: %d alien(s) begin converging on %s" % [
		reason, woken, at])
	escalated.emit(at, reason)
	return woken


## Called by a destroyed nest (Sec 6 trigger 1). Kept as its own entry point
## rather than a bare `escalate` call so the Nest node, when it exists, has an
## obvious thing to invoke and this file documents the relationship.
##
## NOT YET WIRED TO ANYTHING: `Nest` (Sec 11.7) does not exist in code. This is
## the seam it plugs into, and the trigger the design ranks first — destroying a
## nest stops the bleeding but risks waking the deck, which is a real tradeoff
## laid over an objective the player already has a reason to pursue.
func report_nest_destroyed(at: Vector3i) -> int:
	return escalate(at, "A nest is destroyed")


## Called when an alarm panel is tripped (Sec 6 trigger 2).
##
## Routed through the ORDINARY sound channel with its radius opened up, exactly
## as the design asks, rather than as a bespoke mechanic: a gunshot is a 5-tile
## alert, an alarm is the same pathway at ship scale. That reuse is why this
## trigger also wakes the security robots for free — they were already listening.
func report_alarm(at: Vector3i, source: Node = null) -> void:
	SecurityNetwork.report_noise(at, source, SHIP_WIDE_RADIUS)
	escalate(at, "An alarm sounds")


## Settles the ship once the escalation has gone stale. Aliens that made real
## contact in the meantime are left awake — they have their own reason now, and
## the local rules own them from here.
func _on_turn_started(turn_number: int) -> void:
	if not is_escalated or turn_number - _escalated_on_turn <= DE_ESCALATION_TURNS:
		return
	var settled := 0
	for alien in _roused:
		if not is_instance_valid(alien) or alien.is_downed:
			continue
		# COMBAT means it found something. Anything else means it walked toward a
		# noise, found nothing, and has no reason to still be up.
		if alien.alert_state == EnemyUnit.AlertState.COMBAT:
			continue
		alien.settle()
		settled += 1
	is_escalated = false
	_roused.clear()
	if settled > 0:
		TurnManager.log_message.emit(
			"The ship falls quiet again — %d alien(s) settle" % settled)
	de_escalated.emit()
