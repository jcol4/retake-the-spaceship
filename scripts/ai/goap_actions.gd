class_name GoapActions
extends RefCounted
## The shared action library. Every faction draws from this; which subset it gets
## is its doctrine (docs/design/systems/coordinated-ai/ Sec 5), and the clearest
## statement of that is `Flank` being absent from the Cerberus list entirely
## rather than merely scoring badly.
##
## Every `ap_cost` below routes through `Unit.action_cost` / `move_cost_for`,
## which route through `UnitStats`. There is no cost table in this file, and
## there must not be one — see GoapAction.


## Fire on the target. The fallback doctrine every faction shares.
class Attack extends GoapAction:
	func _init() -> void:
		name = &"Attack"
		preconditions = {HAS_LOS: true, IN_RANGE: true, MAGAZINE_READY: true}
		effects = {TARGET_DAMAGED: true}

	func is_available(unit: Unit, ctx: Dictionary) -> bool:
		var target: Unit = ctx.get("target")
		if target == null or target.is_downed or not unit.can_shoot():
			return false
		if unit.ap < ap_cost(unit, ctx):
			return false
		# PROBABILISTIC FLOOR (rival-mercs README Sec 3), the same one
		# GoapBrain.read_state uses for IN_RANGE. Checked again here rather than
		# trusted from IN_RANGE alone, since that fact can go stale mid-plan —
		# this is what stops the planner from building a plan around a shot
		# with no real chance in the first place.
		if Combat.compute_accuracy(unit, target, Combat.ShotAction.SHOOT) < GoapBrain.MIN_VIABLE_ACCURACY:
			return false
		# THE CAUTION RULE (fix B). A hurt unit standing in the open, with cover it
		# could reach, is not allowed to simply trade shots — it has to get behind
		# something first, and `AttackFromCover` is the only route to damage from
		# there. This is what makes cover a MEANS rather than an end: the unit
		# never chooses between fighting and surviving, it just fights from a
		# better place.
		#
		# Gated on cover being REACHABLE, not merely on being hurt, so a wounded
		# unit caught in an open corridor still shoots back instead of standing
		# there looking for a crate that does not exist.
		if unit.is_hurt() and not RepositionToCover._best_tile(unit, target).is_empty():
			return false
		return true

	func ap_cost(unit: Unit, _ctx: Dictionary) -> int:
		return unit.action_cost(UnitStats.Action.SHOOT)

	## hit% * weapon damage — the plain expected-value reading, ahead of the crit
	## roll (base damage is deterministic; only the crit multiplier is
	## stochastic, see rival-mercs README Sec 3). What priority-target weighing
	## and bait-unit selection score actions on instead of `ap_cost`.
	func expected_value(unit: Unit, ctx: Dictionary) -> float:
		var target: Unit = ctx.get("target")
		if target == null:
			return 0.0
		var acc := Combat.compute_accuracy(unit, target, Combat.ShotAction.SHOOT)
		return float(acc) / 100.0 * float(unit.stats.weapon_damage)

	func execute(unit: Unit, ctx: Dictionary) -> bool:
		var target: Unit = ctx.get("target")
		if target == null or target.is_downed or not GridManager.has_line_of_sight(unit, target):
			return false
		unit.spend_ap(ap_cost(unit, ctx))
		var result: Combat.ShotResult = await unit.fire_at(target, Combat.ShotAction.SHOOT)
		unit.report_action("%s fires at %s (%d%% acc): %s" % [
			unit.stats.display_name, target.stats.display_name,
			result.accuracy, Combat.describe(result)])
		return true


## The same shot, taken from behind something. Identical in execution to
## `Attack` — the difference is entirely in the precondition, which is the point.
##
## This is what replaced the standalone "survive" goal. That goal asked for
## `in_cover` and nothing else, so a merc could satisfy it completely by ducking
## and was then finished: cover was a destination. Here cover is a PRECONDITION
## of hurting somebody, so every plan that routes through it still ends in a
## shot, and there is no reachable state in which a unit has "succeeded" at
## hiding.
class AttackFromCover extends GoapAction:
	func _init() -> void:
		name = &"AttackFromCover"
		preconditions = {IN_COVER: true, HAS_LOS: true, IN_RANGE: true, MAGAZINE_READY: true}
		effects = {TARGET_DAMAGED: true, IN_COVER: true}

	func is_available(unit: Unit, ctx: Dictionary) -> bool:
		var target: Unit = ctx.get("target")
		if target == null or target.is_downed or not unit.can_shoot() \
				or unit.ap < ap_cost(unit, ctx):
			return false
		# Same probabilistic floor as `Attack` — see its comment. A merc already
		# in cover should still close the distance rather than plink from behind
		# a crate at a target it cannot realistically hit.
		return Combat.compute_accuracy(unit, target, Combat.ShotAction.SHOOT) >= GoapBrain.MIN_VIABLE_ACCURACY

	func ap_cost(unit: Unit, _ctx: Dictionary) -> int:
		return unit.action_cost(UnitStats.Action.SHOOT)

	func expected_value(unit: Unit, ctx: Dictionary) -> float:
		var target: Unit = ctx.get("target")
		if target == null:
			return 0.0
		var acc := Combat.compute_accuracy(unit, target, Combat.ShotAction.SHOOT)
		return float(acc) / 100.0 * float(unit.stats.weapon_damage)

	func execute(unit: Unit, ctx: Dictionary) -> bool:
		var target: Unit = ctx.get("target")
		if target == null or target.is_downed or not GridManager.has_line_of_sight(unit, target):
			return false
		unit.spend_ap(ap_cost(unit, ctx))
		var result: Combat.ShotResult = await unit.fire_at(target, Combat.ShotAction.SHOOT)
		unit.report_action("%s fires from cover at %s (%d%% acc): %s" % [
			unit.stats.display_name, target.stats.display_name,
			result.accuracy, Combat.describe(result)])
		return true


## Pin the target so an ally can move on it. The action the merc doctrine is
## built around — it exists to ENABLE the flank, not to win a firefight, which
## is why its effect is `TARGET_SUPPRESSED` rather than damage.
class Suppress extends GoapAction:
	func _init() -> void:
		name = &"Suppress"
		preconditions = {HAS_LOS: true, IN_RANGE: true, MAGAZINE_READY: true}
		effects = {TARGET_SUPPRESSED: true}

	func is_available(unit: Unit, ctx: Dictionary) -> bool:
		var target: Unit = ctx.get("target")
		if target == null or target.is_downed or not unit.can_suppress():
			return false
		if unit.ap < ap_cost(unit, ctx):
			return false
		# Never double-pins: the penalties do not stack, so a second burst buys
		# the squad nothing and costs a whole activation.
		if target.is_suppressed():
			return false
		var board: SquadBlackboard = ctx.get("blackboard")
		return board == null or board.can_claim(SquadBlackboard.Role.SUPPRESSOR, unit)

	func ap_cost(unit: Unit, _ctx: Dictionary) -> int:
		return unit.action_cost(UnitStats.Action.SUPPRESS)

	## Not damage-based — a pin is worth what it BUYS the squad (a safer flank),
	## not what it does to the target directly. `PIN_VALUE` is a flat estimate
	## rather than a damage figure so it can be weighed against `Attack`'s real
	## expected damage on the same scale without pretending suppression deals
	## any.
	const PIN_VALUE := 3.0

	func expected_value(_unit: Unit, _ctx: Dictionary) -> float:
		return PIN_VALUE

	func execute(unit: Unit, ctx: Dictionary) -> bool:
		var target: Unit = ctx.get("target")
		if target == null or target.is_downed or not GridManager.has_line_of_sight(unit, target):
			return false
		var board: SquadBlackboard = ctx.get("blackboard")
		if board:
			# Claimed at EXECUTION, not at planning. A claim taken while merely
			# considering the action would be held by every unit that thought
			# about suppressing and released by none of them.
			if not board.claim(SquadBlackboard.Role.SUPPRESSOR, unit, target):
				return false
			board.set_fact(&"ally_is_suppressing", true)
		await unit.do_suppress(target)
		unit.report_action("%s lays down suppressing fire on %s" % [
			unit.stats.display_name, target.stats.display_name])
		return true


## Move to a tile that takes the target's cover out of the equation. The merc
## headline goal (Sec 5.1), and deliberately absent from the Cerberus library.
class Flank extends GoapAction:
	func _init() -> void:
		name = &"Flank"
		preconditions = {}
		effects = {FLANKED: true, HAS_LOS: true, IN_RANGE: true}

	func is_available(unit: Unit, ctx: Dictionary) -> bool:
		var target: Unit = ctx.get("target")
		if target == null or target.is_downed:
			return false
		var board: SquadBlackboard = ctx.get("blackboard")
		if board and not board.can_claim(SquadBlackboard.Role.FLANKER, unit):
			return false
		return not _best_tile(unit, target, board).is_empty()

	func ap_cost(unit: Unit, ctx: Dictionary) -> int:
		var target: Unit = ctx.get("target")
		var board: SquadBlackboard = ctx.get("blackboard")
		var pick := _best_tile(unit, target, board)
		return unit.move_cost_for(int(pick.get("steps", 1))) if not pick.is_empty() else 99

	func execute(unit: Unit, ctx: Dictionary) -> bool:
		var target: Unit = ctx.get("target")
		var board: SquadBlackboard = ctx.get("blackboard")
		var pick := _best_tile(unit, target, board)
		if pick.is_empty():
			return false
		var tile: Vector3i = pick["tile"]
		if board and not board.claim(SquadBlackboard.Role.FLANKER, unit, target, tile):
			return false
		var path := GridManager.find_path(unit.grid_pos, tile, unit.move_tiles_affordable())
		if path.is_empty():
			return false
		unit.spend_ap(unit.move_cost_for(path.size()))
		await unit.move_along(path)
		unit.report_action("%s moves to flank %s" % [
			unit.stats.display_name, target.stats.display_name])
		return true

	## Cheapest reachable tile with line of sight to the target and NO cover
	## defending the target from it — which is what "flank" means mechanically
	## under the edge-cover model, rather than any notion of angle.
	##
	## Tiles already claimed by an ally are skipped, so two flankers never
	## converge on one square and turn a pincer into a queue.
	##
	## THE LINE-OF-SIGHT TEST IS LOAD-BEARING, and its absence was a hang. Without
	## it "flank" meant "get within weapon range with no crate in between", and
	## Chebyshev range ignores walls while `defending_cover` only reads cover
	## edges — so a tile on the far side of a bulkhead passed both tests. A unit
	## walked to such a tile, still had no shot, replanned, and flanked again,
	## every activation, forever. It never showed up on a deck where everything
	## shared one room.
	## A tile a known overwatch watcher covers still ranks — it just costs
	## `OVERWATCH_TILE_PENALTY` extra "steps" against the flood's real ones
	## (Sec 5: expensive ground, not impassable), so a flank a couple of tiles
	## farther but out of the lane wins, and a covered tile is only ever picked
	## when nothing safer is reachable at all.
	const OVERWATCH_TILE_PENALTY := 6

	static func _best_tile(unit: Unit, target: Unit, board: SquadBlackboard) -> Dictionary:
		if target == null:
			return {}
		# ONE flood, reused. Calling `reachable_costs` inside the loop as well as
		# for it would run a fresh BFS per candidate tile — hundreds per planning
		# unit per activation, for an answer that does not change.
		var costs := GridManager.reachable_costs(unit.grid_pos, unit.move_tiles_affordable())
		var watcher_list := TileThreat.watchers(unit)
		var best := {}
		var best_score := 1 << 30
		var aim := target.global_position + Vector3(0, 0.9, 0)
		for tile: Vector3i in costs:
			var steps: int = costs[tile]
			# Cheap tests first, on the RAW step count — a valid lower bound on this
			# candidate's eventual score (the overwatch penalty only adds), so
			# pruning on it here can never discard a tile that would have won.
			if steps >= best_score:
				continue
			if board and board.is_tile_claimed(tile, unit):
				continue
			if GridManager.chebyshev_dist(tile, target.grid_pos) > EnemyUnit.ATTACK_RANGE:
				continue
			if Combat.defending_cover(tile, target.grid_pos)[0] != MapData.Cover.NONE:
				continue
			if not GridManager.has_clear_line(
					unit, GridManager.grid_to_world(tile) + Vector3(0, 1.4, 0), aim):
				continue
			var score := steps
			if TileThreat.is_covered(tile, watcher_list):
				score += OVERWATCH_TILE_PENALTY
			if score >= best_score:
				continue
			best_score = score
			best = {"tile": tile, "steps": steps}
		return best


## Get behind something. Reactive rather than proactive for the mercs (Sec 5.1) —
## it scores as a survival goal, not a doctrine goal.
class RepositionToCover extends GoapAction:
	func _init() -> void:
		name = &"RepositionToCover"
		preconditions = {}
		effects = {IN_COVER: true}

	func is_available(unit: Unit, ctx: Dictionary) -> bool:
		return not _best_tile(unit, ctx.get("target")).is_empty()

	func ap_cost(unit: Unit, ctx: Dictionary) -> int:
		var pick := _best_tile(unit, ctx.get("target"))
		return unit.move_cost_for(int(pick.get("steps", 1))) if not pick.is_empty() else 99

	func execute(unit: Unit, ctx: Dictionary) -> bool:
		var pick := _best_tile(unit, ctx.get("target"))
		if pick.is_empty():
			return false
		var path := GridManager.find_path(unit.grid_pos, pick["tile"], unit.move_tiles_affordable())
		if path.is_empty():
			return false
		unit.spend_ap(unit.move_cost_for(path.size()))
		await unit.move_along(path)
		unit.report_action("%s takes cover at %s" % [unit.stats.display_name, unit.grid_pos])
		return true

	## Nearest reachable tile with cover facing the threat. Asked from the
	## TARGET's side of the edge, since cover only counts against the direction a
	## shot actually crosses.
	## Same tile-ranking treatment as `Flank._best_tile` — see its comment.
	const OVERWATCH_TILE_PENALTY := 6

	static func _best_tile(unit: Unit, threat: Unit) -> Dictionary:
		if threat == null:
			return {}
		var costs := GridManager.reachable_costs(unit.grid_pos, unit.move_tiles_affordable())
		var watcher_list := TileThreat.watchers(unit)
		var best := {}
		var best_score := 1 << 30
		for tile: Vector3i in costs:
			var steps: int = costs[tile]
			if steps >= best_score:
				continue
			if Combat.defending_cover(threat.grid_pos, tile)[0] == MapData.Cover.NONE:
				continue
			var score := steps
			if TileThreat.is_covered(tile, watcher_list):
				score += OVERWATCH_TILE_PENALTY
			if score >= best_score:
				continue
			best_score = score
			best = {"tile": tile, "steps": steps}
		return best


## Shoot the cover out from under the target. The Cerberus headline goal (Sec
## 5.2): a squad that never flanks still forces the player to move, by removing
## the reason they were standing there.
class DestroyCover extends GoapAction:
	func _init() -> void:
		name = &"DestroyCover"
		preconditions = {HAS_LOS: true, IN_RANGE: true, MAGAZINE_READY: true}
		effects = {COVER_BROKEN: true}

	func is_available(unit: Unit, ctx: Dictionary) -> bool:
		var target: Unit = ctx.get("target")
		if target == null or target.is_downed or not unit.can_shoot():
			return false
		if unit.ap < ap_cost(unit, ctx):
			return false
		var board: SquadBlackboard = ctx.get("blackboard")
		if board and not board.can_claim(SquadBlackboard.Role.COVER_BREAKER, unit):
			return false
		return Combat.defending_cover(unit.grid_pos, target.grid_pos)[0] != MapData.Cover.NONE

	func ap_cost(unit: Unit, _ctx: Dictionary) -> int:
		return unit.action_cost(UnitStats.Action.SHOOT)

	func execute(unit: Unit, ctx: Dictionary) -> bool:
		var target: Unit = ctx.get("target")
		if target == null or target.is_downed:
			return false
		var defence := Combat.defending_cover(unit.grid_pos, target.grid_pos)
		if defence[0] == MapData.Cover.NONE:
			return false
		var board: SquadBlackboard = ctx.get("blackboard")
		if board:
			board.claim(SquadBlackboard.Role.COVER_BREAKER, unit, target)
		unit.spend_ap(ap_cost(unit, ctx))
		await unit.face_toward(target.global_position)
		# Deliberately routed through the SAME edge-damage call a stray shot uses
		# (Sec 6.1.1), with the weapon's own damage, rather than a bespoke
		# demolition number — a cover-breaker is a unit that aims at the crate,
		# not one with a private rule about crates.
		var left := GridManager.damage_cover_edge(
			target.grid_pos, defence[1], unit.cover_breaking_damage())
		await unit.visual.play_burst(3)
		unit.report_action("%s fires on the cover shielding %s%s" % [
			unit.stats.display_name, target.stats.display_name,
			" — it collapses" if left == MapData.Cover.NONE else ""])
		return true


## Close the distance, keeping the price of a shot in hand.
##
## THE ACTION EVERY GUNFIGHTING FACTION NEEDS, and its absence from the merc
## library was a bug with a very quiet signature: beyond weapon range a merc
## could plan nothing at all. `Attack` requires `IN_RANGE`, and `Flank` only ever
## considers tiles within weapon range of the target, so at 20 tiles every goal
## was unreachable, the planner returned nothing, and the unit simply stood there
## looking like it had decided to. It only ever moved once the PLAYER had walked
## into its range.
##
## Nothing here needed a new goal. The existing "damage the target" goal becomes
## reachable at any distance because this action supplies exactly the two facts
## `Attack` is missing — so the planner discovers [Advance, Attack] on its own.
##
## Named plainly because it is shared. Cerberus uses it as the advancing half of
## its suppress-and-grind doctrine (Sec 5.2); a merc uses it to get somewhere it
## can start flanking from. Same movement, different reason, which is the split
## the whole framework is built on.
class Advance extends GoapAction:
	func _init() -> void:
		name = &"Advance"
		preconditions = {}
		effects = {IN_RANGE: true, HAS_LOS: true}

	func is_available(unit: Unit, ctx: Dictionary) -> bool:
		var target: Unit = ctx.get("target")
		if target == null or target.is_downed:
			return false
		return unit.move_tiles_affordable() >= 1 \
			and GridManager.chebyshev_dist(unit.grid_pos, target.grid_pos) > 1

	func ap_cost(unit: Unit, _ctx: Dictionary) -> int:
		return unit.move_ap_per_tile()

	func execute(unit: Unit, ctx: Dictionary) -> bool:
		var target: Unit = ctx.get("target")
		if target == null:
			return false
		var board: SquadBlackboard = ctx.get("blackboard")
		if board:
			board.claim(SquadBlackboard.Role.ADVANCER, unit, target)
		# Holds back the price of a shot where it can, so arriving in range means
		# arriving able to use it — the same reservation EnemyUnit's plain loop
		# makes, for the same reason.
		var full := GridManager.find_path(unit.grid_pos, target.grid_pos, 999, true)
		if full.size() <= 1:
			return false
		full.resize(full.size() - 1)
		var reserve := unit.action_cost(UnitStats.Action.SHOOT)
		var budget: int = maxi(1, (unit.ap - reserve) / unit.move_ap_per_tile())
		if unit.move_tiles_affordable() < 1:
			return false
		var path: Array[Vector3i] = full.slice(0, mini(budget, full.size()))
		unit.spend_ap(unit.move_cost_for(path.size()))
		await unit.move_along(path)
		unit.report_action("%s advances on %s" % [
			unit.stats.display_name, target.stats.display_name])
		return true


## Close to contact. The alien melee tier's version of advancing.
class Rush extends GoapAction:
	func _init() -> void:
		name = &"Rush"
		preconditions = {}
		effects = {IN_RANGE: true, HAS_LOS: true}

	func is_available(unit: Unit, ctx: Dictionary) -> bool:
		var target: Unit = ctx.get("target")
		return target != null and not target.is_downed \
			and unit.move_tiles_affordable() >= 1 \
			and not GridManager.is_melee_adjacent(unit.grid_pos, target.grid_pos)

	func ap_cost(unit: Unit, _ctx: Dictionary) -> int:
		return unit.move_ap_per_tile()

	func execute(unit: Unit, ctx: Dictionary) -> bool:
		var target: Unit = ctx.get("target")
		if target == null:
			return false
		var full := GridManager.find_path(unit.grid_pos, target.grid_pos, 999, true)
		if full.size() <= 1:
			return false
		full.resize(full.size() - 1)
		var reserve := unit.action_cost(UnitStats.Action.MELEE)
		var budget: int = maxi(1, (unit.ap - reserve) / unit.move_ap_per_tile())
		var path: Array[Vector3i] = full.slice(0, mini(budget, full.size()))
		unit.spend_ap(unit.move_cost_for(path.size()))
		await unit.move_along(path)
		unit.report_action("%s rushes %s" % [unit.stats.display_name, target.stats.display_name])
		return true


## Swing at whatever is in contact.
class MeleeStrike extends GoapAction:
	func _init() -> void:
		name = &"MeleeStrike"
		preconditions = {IN_RANGE: true}
		effects = {TARGET_DAMAGED: true}

	func is_available(unit: Unit, ctx: Dictionary) -> bool:
		var target: Unit = ctx.get("target")
		return target != null and not target.is_downed \
			and GridManager.is_melee_adjacent(unit.grid_pos, target.grid_pos) \
			and unit.ap >= ap_cost(unit, ctx)

	func ap_cost(unit: Unit, _ctx: Dictionary) -> int:
		return unit.action_cost(UnitStats.Action.MELEE)

	func execute(unit: Unit, ctx: Dictionary) -> bool:
		var target: Unit = ctx.get("target")
		if target == null or not GridManager.is_melee_adjacent(unit.grid_pos, target.grid_pos):
			return false
		unit.spend_ap(ap_cost(unit, ctx))
		var result: Combat.ShotResult = await unit.melee_at(target)
		unit.report_action("%s strikes %s (%d%% acc): %s" % [
			unit.stats.display_name, target.stats.display_name,
			result.accuracy, Combat.describe(result)])
		return true


class Reload extends GoapAction:
	func _init() -> void:
		name = &"Reload"
		preconditions = {}
		effects = {MAGAZINE_READY: true}

	func is_available(unit: Unit, ctx: Dictionary) -> bool:
		return unit.can_reload() and unit.ap >= ap_cost(unit, ctx)

	func ap_cost(unit: Unit, _ctx: Dictionary) -> int:
		return unit.action_cost(UnitStats.Action.RELOAD)

	func execute(unit: Unit, ctx: Dictionary) -> bool:
		if not unit.can_reload():
			return false
		unit.spend_ap(ap_cost(unit, ctx))
		await unit.do_reload()
		unit.report_action("%s reloads" % unit.stats.display_name)
		return true


## Reserve the rest of the activation. The plan of last resort — taken when
## nothing scores better, which under a pool means "I have AP but no use for it".
class HoldOverwatch extends GoapAction:
	func _init() -> void:
		name = &"HoldOverwatch"
		preconditions = {}
		effects = {IN_COVER: true}

	func is_available(unit: Unit, ctx: Dictionary) -> bool:
		return unit.ap >= ap_cost(unit, ctx) and unit.can_shoot() and not unit.on_overwatch

	func ap_cost(unit: Unit, _ctx: Dictionary) -> int:
		# Priced as a Shoot (UnitStats.Action.OVERWATCH) rather than "whatever is
		# left" — see Unit.do_overwatch.
		return unit.action_cost(UnitStats.Action.OVERWATCH)

	func execute(unit: Unit, _ctx: Dictionary) -> bool:
		unit.do_overwatch()
		unit.report_action("%s holds overwatch (%d AP reserved)" % [
			unit.stats.display_name, unit.overwatch_reserve])
		return true
