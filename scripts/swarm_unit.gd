class_name SwarmUnit
extends EnemyUnit
## Fodder (Sec 11.3/11.4): slow, tanky, no ranged weapon. The entire loop is
## crawl toward the target and claw it once adjacent. The threat is attrition —
## a squad that ignores one bleeds AP and ammo to the count, not to any single
## hit, and a squad that keeps moving can outpace them entirely.

const MELEE_AP_COST := 1

## Tiles walked per 1 AP, replacing the Fitness-derived run distance every other
## unit uses. Kept below it on purpose: the swarm has to be outrunnable for its
## numbers to read as a cost rather than a chase. With 2 AP that's crawl 3 and
## swing, crawl 6, or — already in contact — two swings.
@export var move_tiles_per_ap: int = 3


func _combat_turn() -> void:
	# Replaces the base ranged loop entirely. Reached only in COMBAT — the
	# awareness states and everything that feeds them are EnemyUnit's business.
	while ap > 0 and not is_downed:
		var quarry := acquire_target()
		if quarry == null:
			return
		if GridManager.is_melee_adjacent(grid_pos, quarry.grid_pos):
			spend_ap(MELEE_AP_COST)
			var result: Combat.ShotResult = await melee_at(quarry)
			action_logged.emit("%s clawed %s (%d%% acc): %s" % [
				stats.display_name, quarry.stats.display_name, result.accuracy, Combat.describe(result),
			])
			if quarry.is_downed:
				action_logged.emit("%s is DOWN!" % quarry.stats.display_name)
		else:
			# Stops on the tile before the target's, so the next AP is already a
			# swing — and walking in still trips any overwatch on the way.
			await _move_toward(quarry)


func _move_budget() -> int:
	return move_tiles_per_ap
