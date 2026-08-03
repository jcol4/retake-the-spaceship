class_name SagittariiUnit
extends CerberusUnit
## MKV-9 Sagittarii — the faction's heavy ranged threat.
## Design: docs/design/factions/security-robots/units/sagittarii/
##
## The unit a player plans around rather than reacts to: slow enough that it is
## never a surprise, armored enough that chipping at it with snap shots is a
## losing trade. Where the Spitter is "kill it fast, it is fragile", this is
## "you cannot kill it fast, so manage your exposure to it" — and the intended
## answer is an EMP grenade zeroing its Armor for a turn, not more bullets.

## Tiles per 1 AP move, replacing the Fitness-derived distance. Deliberately
## short: it advances deliberately, a tile or two at a time, rather than holding
## a fixed post the way an Auxilium does or closing the way a Securus does.
@export var move_tiles_per_ap: int = 2

## Fraction of the LIGHT cover penalty its weapon still respects. A heavier
## calibre than the rest of the roster carries, so a crate is less help against
## it — but only a crate. Heavy cover is untouched, which is what keeps this a
## reason to respect the unit rather than a repeal of the cover system.
@export var light_cover_penalty_mult: float = 0.5


func _move_budget() -> int:
	return move_tiles_per_ap


## Read by Combat.compute_accuracy in place of the flat table, so the reduction
## applies to the shot the HUD previews as well as the one it fires.
func cover_penalty_for(cover_type: int) -> int:
	if cover_type == MapData.Cover.LIGHT:
		return roundi(Combat.COVER_PENALTY_LIGHT * light_cover_penalty_mult)
	return Combat.cover_penalty(cover_type)
