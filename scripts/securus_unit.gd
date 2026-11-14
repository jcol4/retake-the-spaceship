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
## SwarmUnit.CLAW_AP_COST is. Against an 11 AP pool: seven tiles and a strike.
const SWING_AP_COST := 4
## AP off the wrist gun's shot, after the usual Reflexes pricing (6 -> 5).
const SHOT_AP_DISCOUNT := 1


func action_cost(action: UnitStats.Action) -> int:
	if action == UnitStats.Action.MELEE:
		return SWING_AP_COST
	if action == UnitStats.Action.SHOOT:
		return maxi(UnitStats.MIN_AP_COST, super(action) - SHOT_AP_DISCOUNT)
	return super(action)


## Replaces the ranged loop entirely: close and swing, with the wrist gun for a
## quarry it cannot reach this activation. Reached only in COMBAT — awareness is
## CerberusUnit's business.
##
## Melee always wins when it is affordable: if the WALKING ROUTE to the quarry
## (not the straight-line distance) leaves AP for a swing, it walks in. Otherwise
## the whole activation goes to the gun (`_gun_step`): fire from where it stands
## if it has a shot, else walk the fewest tiles to one that has, then fire with
## everything left. A quarry it cannot walk to at all is still closed on as far
## as the deck allows and shot at.
func _combat_turn() -> void:
	var melee_cost := action_cost(UnitStats.Action.MELEE)
	var fired := false
	while ap > 0 and not is_downed:
		var quarry := acquire_target()
		if quarry == null:
			return
		if not GridManager.is_melee_adjacent(grid_pos, quarry.grid_pos):
			# The route ends ON the quarry's tile; the swing is thrown from the one before.
			var route := _route_path(quarry.grid_pos, true)
			var walk := route.size() - 1
			if walk > 0 and walk * move_ap_per_tile() + melee_cost <= ap:
				var from := grid_pos
				await _move_toward(quarry, melee_cost)
				if grid_pos != from:
					continue
			var step := await _gun_step(quarry, route.size() > 0, fired)
			if step == GunStep.NONE:
				ap = 0
				return
			fired = fired or step == GunStep.FIRED
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


## What one `_gun_step` did. NONE ends the activation.
enum GunStep { NONE, FIRED, RELOADED, MOVED }


## One wrist-gun action at `quarry`, for a quarry it cannot reach and swing at:
##   * the drum is dry: reload;
##   * it has a shot: fire;
##   * a tile it can walk to with a shot's price still in hand has a line of
##     fire: walk there (the cheapest; the next step fires);
##   * none does, and it has not fired yet: close with all of it — along the
##     route when there is one (`reachable`), else to whichever reachable tile
##     is nearest the quarry, so a quarry it cannot walk to (across a gap, behind
##     a locked door with a window) is still brought into range.
## Once it has fired, AP short of another shot is left unspent rather than
## walking it out of the spot it just fired from.
func _gun_step(quarry: Unit, reachable: bool, fired: bool) -> GunStep:
	var shoot_cost := action_cost(UnitStats.Action.SHOOT)
	if not can_shoot():
		var reload_cost := action_cost(UnitStats.Action.RELOAD)
		if ap < reload_cost or stats.weapon == null:
			return GunStep.NONE
		spend_ap(reload_cost)
		await do_reload()
		action_logged.emit("%s reloads its wrist gun" % stats.display_name)
		return GunStep.RELOADED
	if ap < shoot_cost and fired:
		return GunStep.NONE
	if ap >= shoot_cost and _in_range(quarry) and has_shot_at(quarry):
		spend_ap(shoot_cost)
		var result: Combat.ShotResult = await fire_at(quarry, Combat.ShotAction.SHOOT)
		action_logged.emit("%s fires its wrist gun at %s (%d%% acc): %s" % [
			stats.display_name, quarry.stats.display_name, result.accuracy, Combat.describe(result),
		])
		return GunStep.FIRED
	var spot: Variant = _firing_tile(quarry, (ap - shoot_cost) / move_ap_per_tile())
	if spot != null:
		return GunStep.MOVED if await _walk_to(spot) else GunStep.NONE
	if fired:
		return GunStep.NONE
	if reachable:
		var from := grid_pos
		await _move_toward(quarry)
		return GunStep.MOVED if grid_pos != from else GunStep.NONE
	spot = _closing_tile(quarry, ap / move_ap_per_tile())
	if spot != null and await _walk_to(spot):
		return GunStep.MOVED
	return GunStep.NONE


func _in_range(quarry: Unit) -> bool:
	return GridManager.chebyshev_dist(grid_pos, quarry.grid_pos) <= ATTACK_RANGE


## Whether this robot may end a move on `tile`: free, and inside its post's
## leash if it is posted (CerberusUnit.holds_position).
func _may_stand(tile: Vector3i) -> bool:
	return GridManager.is_free(tile) and (not holds_position
		or GridManager.chebyshev_dist(post_pos, tile) <= post_leash)


## The cheapest tile within `tiles` steps that is in ATTACK_RANGE of `quarry`
## and sees it, nearer the quarry breaking a tie; null when there is none. A
## candidate's sight is judged without leaning, so it never banks on a peek the
## tile might not give; Unit.has_shot_at has the last word once it is there.
func _firing_tile(quarry: Unit, tiles: int) -> Variant:
	if tiles < 1:
		return null
	var best: Variant = null
	var best_cost := 1 << 30
	var best_dist := 1 << 30
	var costs := GridManager.reachable_costs(grid_pos, tiles)
	for tile: Vector3i in costs:
		var cost: int = costs[tile]
		var dist := GridManager.chebyshev_dist(tile, quarry.grid_pos)
		if dist > ATTACK_RANGE or cost > best_cost or (cost == best_cost and dist >= best_dist):
			continue
		if not _may_stand(tile) or not GridManager.tiles_have_sight(self, tile, quarry.grid_pos):
			continue
		best = tile
		best_cost = cost
		best_dist = dist
	return best


## The reachable tile within `tiles` steps nearest `quarry` (straight line, the
## shorter walk breaking a tie), if it is nearer than where the robot stands.
func _closing_tile(quarry: Unit, tiles: int) -> Variant:
	if tiles < 1:
		return null
	var best: Variant = null
	var best_dist := GridManager.chebyshev_dist(grid_pos, quarry.grid_pos)  # standing still
	var best_cost := 0
	var costs := GridManager.reachable_costs(grid_pos, tiles)
	for tile: Vector3i in costs:
		var dist := GridManager.chebyshev_dist(tile, quarry.grid_pos)
		var cost: int = costs[tile]
		var better := dist < best_dist or (best != null and dist == best_dist and cost < best_cost)
		if not better or not _may_stand(tile):
			continue
		best = tile
		best_dist = dist
		best_cost = cost
	return best


## Walks to `tile` by the shortest route. False if there is none it can afford.
func _walk_to(tile: Vector3i) -> bool:
	var path := GridManager.find_path(grid_pos, tile, 999)
	if path.is_empty() or move_cost_for(path.size()) > ap:
		return false
	spend_ap(move_cost_for(path.size()))
	await move_along(path)
	action_logged.emit("%s moved to %s" % [stats.display_name, tile])
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


func damage_taken(amount: int, armor_ignore: int = 0) -> int:
	var through := super(amount, armor_ignore)
	return maxi(1, roundi(through * broken_head_damage_mult)) if head_broken else through
