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
## Scaled to the DAMAGE curve, not to the body's HP: what this number is for is
## "how many Aimed Shots break it", and the answer is still two. The scene
## overrides it anyway; this default just has to agree with it.
@export var head_hp: int = 12
## Damage multiplier on every subsequent hit, to any zone, once the head is off.
@export var broken_head_damage_mult: float = 1.75

var head_broken: bool = false


## The swing's price, flat rather than read off Reflexes, the same way
## SwarmUnit.CLAW_AP_COST is. Against a 12 AP pool: nine tiles and a strike.
const SWING_AP_COST := 3


func action_cost(action: UnitStats.Action) -> int:
	if action == UnitStats.Action.MELEE:
		return SWING_AP_COST
	return super(action)


## Replaces the ranged loop entirely: close and swing, with the wrist gun for a
## quarry it cannot reach this activation. Reached only in COMBAT — awareness is
## CerberusUnit's business.
##
## Melee always wins when it is affordable: if the quarry is within reach of a
## walk-and-swing, it walks. Otherwise it advances holding back a snap shot's
## price and fires once it has closed as far as that allows, so a target out of
## reach is still shot at rather than merely approached.
func _combat_turn() -> void:
	var melee_cost := action_cost(UnitStats.Action.MELEE)
	var shoot_cost := action_cost(UnitStats.Action.SHOOT)
	var reload_cost := action_cost(UnitStats.Action.RELOAD)
	while ap > 0 and not is_downed:
		var quarry := acquire_target()
		if quarry == null:
			return
		if not GridManager.is_melee_adjacent(grid_pos, quarry.grid_pos):
			var steps := GridManager.chebyshev_dist(grid_pos, quarry.grid_pos) - 1
			var from := grid_pos
			if steps * move_ap_per_tile() + melee_cost <= ap:
				await _move_toward(quarry, melee_cost)
			elif ap > shoot_cost:
				await _move_toward(quarry, shoot_cost)
			if grid_pos != from:
				continue
			# Could not (or need not) step any closer: use the gun.
			if not await _fire_wrist_gun(quarry, shoot_cost, reload_cost):
				ap = 0
				return
			continue
		if ap < melee_cost:
			ap = 0  # in contact but out of AP for the swing
			return
		_breach_cover(quarry)
		spend_ap(melee_cost)
		var result: Combat.ShotResult = await melee_at(quarry)
		action_logged.emit("%s strikes %s (%d%% acc): %s" % [
			stats.display_name, quarry.stats.display_name, result.accuracy, Combat.describe(result),
		])
		if quarry.is_downed:
			action_logged.emit("%s is DOWN!" % quarry.stats.display_name)


## One wrist-gun action at `quarry`: a shot if it has one, a reload if the drum
## is dry. Returns false when neither is possible, which ends the activation.
func _fire_wrist_gun(quarry: Unit, shoot_cost: int, reload_cost: int) -> bool:
	if not can_shoot():
		if ap < reload_cost or stats.weapon == null:
			return false
		spend_ap(reload_cost)
		await do_reload()
		action_logged.emit("%s reloads its wrist gun" % stats.display_name)
		return true
	var in_range := GridManager.chebyshev_dist(grid_pos, quarry.grid_pos) <= ATTACK_RANGE
	if not in_range or not has_shot_at(quarry) or ap < shoot_cost:
		return false
	spend_ap(shoot_cost)
	var result: Combat.ShotResult = await fire_at(quarry, Combat.ShotAction.SHOOT)
	action_logged.emit("%s fires its wrist gun at %s (%d%% acc): %s" % [
		stats.display_name, quarry.stats.display_name, result.accuracy, Combat.describe(result),
	])
	return true


## Takes a tier off whatever the target is hiding behind, on the way in. This is
## the difference between Securus and Sagittarii stated mechanically: Sagittarii
## shoots *through* light cover, Securus removes cover outright, so hunkering
## behind a crate is an answer to one and an invitation to the other.
func _breach_cover(quarry: Unit) -> void:
	var defence := Combat.defending_cover(grid_pos, quarry.grid_pos)
	# Corner cover (defence[2]) is a bulkhead; there is nothing to breach.
	if defence[0] == MapData.Cover.NONE or defence[2]:
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
