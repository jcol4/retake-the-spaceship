class_name LictorUnit
extends CerberusUnit
## FRC-6 Lictor — the roster's cover-breaker, and the unit the security faction's
## GOAP doctrine was missing.
## Design: docs/design/systems/coordinated-ai/ Sec 5.2.
##
## The doctrine says a robot squad advances, suppresses and grinds through
## whatever the player is hiding behind — it never flanks. Three of those four
## roles already existed on the roster: Auxilium holds an angle, Sagittarii
## applies ranged pressure, Securus closes and breaches. What did not exist was a
## unit that removes cover AT RANGE. Securus breaks cover, but only by walking up
## and hitting it, which is a different threat with a different answer.
##
## Without this unit the no-flank doctrine has no teeth: a squad that cannot
## manoeuvre and cannot remove your cover is a squad you can simply hold a corner
## against indefinitely. The Lictor is what turns "they will not out-position
## you" into "so do not expect the position to last".
##
## The counterplay is its own fragility. It carries the roster's second-thinnest
## plate and a slow, small magazine: it has to be given time to work, so killing
## it — or breaking line of sight to it — is a real and available answer.

## Multiplier on this unit's weapon damage when it fires deliberately AT a cover
## edge (Sec 6.1.1's bonus-damage-to-cover trait, which the GDD flags as a
## grenade/Heavy-Weapons property and this is the roster's first user of).
##
## Applied to the SAME `damage_cover_edge` call every stray shot uses rather than
## through a private destruction path, so cover has one HP pool and one way to
## lose it. A demolition gun is a unit that aims at the crate, not a unit with its
## own rules about crates.
@export var cover_damage_multiplier: float = 3.0


func _ready() -> void:
	super()
	# Holds its ground like the rest of the roster, but on a long leash: its whole
	# contribution is line of sight to the cover, so it repositions to keep that
	# rather than to close.
	holds_position = true
	post_leash = 6


func cover_breaking_damage() -> int:
	return maxi(1, roundi(stats.weapon_damage * cover_damage_multiplier))
