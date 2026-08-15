class_name MercPresets
extends RefCounted
## Roster table for the rival mercenaries — the third faction's answer to
## `ClassPresets`, `AlienPresets` and `CerberusPresets`.
## Design: docs/design/systems/coordinated-ai/
##
## THE PROTOTYPE FACTION for the shared GOAP coordination framework, and a stub
## on purpose: what this faction exists to prove is squad role negotiation, and
## that lives in the planner, not in a stat block. So there is one unit type here
## rather than a role roster — a "suppressor" and a "flanker" are the same
## mercenary running different plans, and baking those roles into stats would
## decide by authoring what the blackboard is supposed to decide at runtime.
##
## Hand-set per the AP rework's Sec 4.5/5.5, like every other non-player faction:
## `fitness` is the AP pool and therefore pace, `base_hp` is toughness,
## `base_initiative` is standing in the draw order.

## How much of a soldier a merc is, expressed as the one decision that matters:
## they are people with the same equipment and the same training, tuned a notch
## below the squad on every axis rather than crippled on any one.
##
## A notch, deliberately, and not more. These are the only enemies in the game
## that fight the way the player does — same actions, same weapons, same cover
## rules — so the fight is legible precisely to the degree they are a fair
## comparison. Making them clearly worse would turn the faction into a tutorial;
## the intended edge over them is COORDINATION, which they will shortly have too.
static func rifleman(display_name: String) -> UnitStats:
	var stats := UnitStats.new()
	stats.display_name = display_name
	# Against a rolled Assault's 30-50 / 45-65 / 60-85 / 30-60.
	stats.perception = randi_range(30, 45)
	stats.reflexes = randi_range(35, 55)
	stats.fitness = randi_range(50, 70)  # 9-11 AP, a shade under a soldier's 10-12
	stats.luck = randi_range(25, 45)
	# 12 against the squad's 15 baseline — lands a merc at 16-17 max HP against a
	# soldier's 17-22, so a merc dies a little sooner than a soldier does. Under
	# the shortened HP scale that gap is worth about one connected hit at the
	# margins, where it used to be worth a fraction of one.
	stats.base_hp = 12
	stats.base_initiative = 44  # -> ~57, drawing just behind the squad's ~62-68
	stats.equipment_initiative = 5
	# SMG, not the Assault Rifle, and the reason is mechanical rather than
	# flavour: suppression costs 3 rounds, and the Assault and Battle Rifles hold
	# exactly 3. A merc carrying either could only ever suppress on a completely
	# fresh magazine — one shot and the squad's whole doctrine becomes
	# unavailable until it reloads. The SMG's 4 leaves a round in hand.
	#
	# That coupling is worth knowing about generally: any weapon with a magazine
	# at or below Unit.SUPPRESS_AMMO_COST cannot sustain suppressing fire, which
	# is a real constraint on who can hold the suppressor role.
	stats.weapon = WeaponPresets.make(WeaponPresets.WeaponId.SMG)
	# Full parity with the player at contact range too. They are not a melee
	# tier, but a mercenary backed into a corner swings rather than politely
	# running out of options.
	stats.melee_base_accuracy = 40
	stats.melee_damage = 4
	return stats


## The squad's designated gun. One per merc team, and it exists because the
## coordinator has to pick a suppressor every engagement — a squad where that
## choice is arbitrary reads as arbitrary.
##
## The LMG's six rounds is two full bursts of suppressing fire against the SMG's
## one, so the unit built to hold an angle is the one that can actually hold it,
## and the role assignment has a reason behind it the player can see.
static func support(display_name: String) -> UnitStats:
	var stats := rifleman(display_name)
	stats.weapon = WeaponPresets.make(WeaponPresets.WeaponId.LMG)
	# Steadier and slower than its squadmates: it is here to put rounds in one
	# direction for a whole activation, not to reposition.
	stats.perception = randi_range(35, 50)
	stats.reflexes = randi_range(30, 45)
	return stats
