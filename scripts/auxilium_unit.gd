class_name AuxiliumUnit
extends CerberusUnit
## QRN-4 Auxilium — the faction's chokepoint anchor.
## Design: docs/design/factions/security-robots/units/auxilium/
##
## The Fodder-equivalent slot, inverted rather than copied: where Fodder is a
## swarm that is dangerous in numbers, an Auxilium is one machine that is
## dangerous alone, holding a doorway or a junction and punishing anyone who
## walks through its sightline without a plan.
##
## Its combat behaviour needs no new code — it is the base ranged loop with a
## short leash. What is genuinely its own is what it does with a quiet
## activation: it reserves the shot. That is the existing Overwatch action (Sec
## 4.2), not a new interrupt system, because "holds position and fires when
## something enters its sightline" is precisely what Overwatch already models.


func _hold_post() -> void:
	# Reserves the shot rather than idling. Costs the AP an idle activation would
	# have wasted, so a bypassed Auxilium is never free to walk past twice — all
	# of it, in fact: do_overwatch ends the activation outright, so reserving the
	# shot forfeits any remainder. See Unit._end_activation_ap.
	if on_overwatch or not can_shoot():
		return
	do_overwatch()
	action_logged.emit("%s holds its post on overwatch" % stats.display_name)
