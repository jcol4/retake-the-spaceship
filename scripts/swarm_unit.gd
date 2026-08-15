class_name SwarmUnit
extends EnemyUnit
## Fodder (Sec 11.3/11.4): slow, tanky, no ranged weapon. The entire loop is
## crawl toward the target and claw it once adjacent. The threat is attrition —
## a squad that ignores one bleeds AP and ammo to the count, not to any single
## hit, and a squad that keeps moving can outpace them entirely.
##
## MOVEMENT IS NO LONGER TWO-SPEED. The shamble/lunge pair (`shamble_tiles_per_ap`
## 1, `lunge_tiles_per_ap` 4, latched at activation start) was built on
## `_move_budget` meaning "tiles per 1 AP", and the granular AP rework deletes
## that unit of measure: movement is 1 AP per tile for every unit on the board
## (rework doc Sec 4.1). Pace now comes from the AP POOL, hand-set per type
## (Sec 4.5) — see `main.gd._swarm_stats` for the Fitness value that buys it.
##
## What that costs, stated plainly rather than hidden: Sec 11.4's lunge is gone
## as a behaviour, and with it the burst of speed that made a shambler in contact
## range read as a different creature. What SURVIVES is the property the lunge's
## latch existed to protect — the player's one turn of warning. A swarm's pool
## and its melee cost are sized so it can close OR swing in an activation but
## never both, so "that thing is near" and "that thing is on me" are still two
## separate turns. Re-adding a burst is a deliberate design decision (it would be
## an AP grant or a move-cost discount now, not a tiles-per-AP override), not
## something to restore by reflex.


func _combat_turn() -> void:
	# Replaces the base ranged loop entirely. Reached only in COMBAT — the
	# awareness states and everything that feeds them are EnemyUnit's business.
	var melee_cost := action_cost(UnitStats.Action.MELEE)
	while ap > 0 and not is_downed:
		var quarry := acquire_target()
		if quarry == null:
			return
		if GridManager.is_melee_adjacent(grid_pos, quarry.grid_pos):
			if ap < melee_cost:
				ap = 0  # in contact but cannot pay for the swing — the turn is over
				return
			spend_ap(melee_cost)
			var result: Combat.ShotResult = await melee_at(quarry)
			action_logged.emit("%s clawed %s (%d%% acc): %s" % [
				stats.display_name, quarry.stats.display_name, result.accuracy, Combat.describe(result),
			])
			if quarry.is_downed:
				action_logged.emit("%s is DOWN!" % quarry.stats.display_name)
		else:
			# Stops on the tile before the target's, so the NEXT activation opens
			# already in contact — and walking in still trips any overwatch on the
			# way. It holds back the price of a swing where it can, so arriving
			# adjacent with AP to spare means arriving with a claw in hand.
			await _move_toward(quarry, melee_cost)
