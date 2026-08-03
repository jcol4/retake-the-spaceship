class_name SecurusUnit
extends CerberusUnit
## JXM-2 Securus — the roster's elite, and the only unit with a component weak
## point. Design: docs/design/factions/security-robots/units/securus/
##
## Sagittarii already owns "tanky ranged pressure", so Securus is built to force
## the player out of a position rather than to punish them for holding one: it
## closes regardless of cover, breaches what it reaches, and hits at contact
## range. The intended read is a two-phase fight — grind the head down with
## committed Aimed Shots, then finish it fast once the head is off — rather than
## one flat damage sponge from start to end.

const MELEE_AP_COST := 1

## Damage a breach swing does to the cover edge between it and its target. Well
## above any tier's HP on purpose: the alpha reading of "breach" is one tier per
## swing, so heavy goes to light and light goes to nothing, using the existing
## degradation rule rather than a second destruction path.
const BREACH_DAMAGE := 999

## Separate HP pool, reachable ONLY by an Aimed Shot to the Head (2 AP, the
## existing VATS-style action). A snap shot never touches it, and neither does an
## Aimed Shot to any other zone, even on a crit — the weak point is a payoff for
## a choice the game already asks the player to make, so it has to be tied to
## that choice and not to an invisible roll.
##
## Armor deliberately does NOT protect it: a weak point that the unit's own plate
## covers is not a weak point. Head damage is the raw roll.
@export var head_hp: int = 24
## Damage multiplier on every subsequent hit, to any zone, once the head is off.
@export var broken_head_damage_mult: float = 1.75

## Tiles per 1 AP. Slow and heavy, but it does close — the threat is arrival.
@export var move_tiles_per_ap: int = 3

var head_broken: bool = false


func _move_budget() -> int:
	return move_tiles_per_ap


## Replaces the ranged loop entirely, the same way SwarmUnit's does: advance and
## swing. Reached only in COMBAT — awareness is CerberusUnit's business.
func _combat_turn() -> void:
	while ap > 0 and not is_downed:
		var quarry := acquire_target()
		if quarry == null:
			return
		if not GridManager.is_melee_adjacent(grid_pos, quarry.grid_pos):
			await _move_toward(quarry)
			continue
		_breach_cover(quarry)
		spend_ap(MELEE_AP_COST)
		var result: Combat.ShotResult = await melee_at(quarry)
		action_logged.emit("%s strikes %s (%d%% acc): %s" % [
			stats.display_name, quarry.stats.display_name, result.accuracy, Combat.describe(result),
		])
		if quarry.is_downed:
			action_logged.emit("%s is DOWN!" % quarry.stats.display_name)


## Takes a tier off whatever the target is hiding behind, on the way in. This is
## the difference between Securus and Sagittarii stated mechanically: Sagittarii
## shoots *through* light cover, Securus removes cover outright, so hunkering
## behind a crate is an answer to one and an invitation to the other.
func _breach_cover(quarry: Unit) -> void:
	var defence := Combat.defending_cover(grid_pos, quarry.grid_pos)
	if defence[0] == MapData.Cover.NONE:
		return
	GridManager.damage_cover_edge(quarry.grid_pos, defence[1], BREACH_DAMAGE)
	action_logged.emit("%s BREACHES the cover in front of %s" % [
		stats.display_name, quarry.stats.display_name,
	])


## The one place the roster's "no injury state" rule has an exception. Called by
## Unit.fire_at for an Aimed Shot only, with the RAW damage roll — see head_hp on
## why armor is not subtracted here.
func apply_body_part_damage(part: int, amount: int) -> bool:
	if part != Combat.BodyPart.HEAD or head_broken:
		return false
	head_hp = maxi(head_hp - amount, 0)
	if head_hp > 0:
		action_logged.emit("%s's sensor head is buckling (%d left)" % [stats.display_name, head_hp])
		return false
	head_broken = true
	action_logged.emit("%s's HEAD IS DESTROYED — it takes heavy damage from here on" % stats.display_name)
	# Reported as its own line above rather than through the caller's generic
	# "part is INJURED" message, which is written for a soldier's limb.
	return false


func damage_taken(amount: int) -> int:
	var through := super(amount)
	return maxi(1, roundi(through * broken_head_damage_mult)) if head_broken else through
