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
		# The same reachability test `execute` makes (a squadmate or a wall in the
		# shot's path). Without it the shot was planned, refused at execution, and
		# the failure dropped Attack from the unit's library.
		if not unit.has_shot_at(target):
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
		if target == null or target.is_downed or not unit.has_shot_at(target):
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
				or unit.ap < ap_cost(unit, ctx) or not unit.has_shot_at(target):
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
		if target == null or target.is_downed or not unit.has_shot_at(target):
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
		ends_activation = true  # Unit.do_suppress burns the rest of the turn

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
		return not _pick(unit, ctx).is_empty()

	func ap_cost(unit: Unit, ctx: Dictionary) -> int:
		var pick := _pick(unit, ctx)
		return unit.move_cost_for(int(pick.get("steps", 1))) if not pick.is_empty() else 99

	## Whether the flank tile is also in cover from the target, so the planner
	## knows [Flank, AttackFromCover] works there — and, just as important, that
	## an uncovered flank tile leaves the unit OUT of cover it may be in now.
	func planned_effects(unit: Unit, ctx: Dictionary) -> Dictionary:
		var pick := _pick(unit, ctx)
		var target: Unit = ctx.get("target")
		var fx := effects.duplicate()
		fx[IN_COVER] = not pick.is_empty() and target != null \
			and Combat.defending_cover(target.grid_pos, pick["tile"])[0] != MapData.Cover.NONE
		return fx

	## `_best_tile` for this step, cached on `ctx` (rebuilt by GoapBrain.run every
	## step) so the planner's availability/cost/effect queries share one flood.
	func _pick(unit: Unit, ctx: Dictionary) -> Dictionary:
		if not ctx.has(&"_flank_pick"):
			ctx[&"_flank_pick"] = _best_tile(unit, ctx.get("target"), ctx.get("blackboard"))
		return ctx[&"_flank_pick"]

	func execute(unit: Unit, ctx: Dictionary) -> bool:
		var target: Unit = ctx.get("target")
		var board: SquadBlackboard = ctx.get("blackboard")
		var pick := _pick(unit, ctx)
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
	## "Steps" a flank tile is credited for having cover of its own against the
	## target. A flank in the open used to be immediately undone: the next replan
	## found the merc exposed and walked it to the nearest cover — which put the
	## target's cover back between them, so it flanked again, and spent the turn
	## running between the two. Preferring a tile that is both is what makes the
	## flank somewhere to shoot from rather than a stop on the way to cover.
	const COVERED_FLANK_BONUS := 3

	static func _best_tile(unit: Unit, target: Unit, board: SquadBlackboard) -> Dictionary:
		if target == null:
			return {}
		# Only as far as still leaves a shot: the flank goal now ends in one, and a
		# flank that eats the shot's AP is a turn spent walking.
		var reach := GoapBrain.move_reach_keeping_shot(unit)
		if reach < 1:
			return {}
		# ONE flood, reused. Calling `reachable_costs` inside the loop as well as
		# for it would run a fresh BFS per candidate tile — hundreds per planning
		# unit per activation, for an answer that does not change.
		var costs := GridManager.reachable_costs(unit.grid_pos, reach)
		var watcher_list := TileThreat.watchers(unit)
		var best := {}
		var best_score := 1 << 30
		for tile: Vector3i in costs:
			var steps: int = costs[tile]
			# Cheap tests first, on the best score this tile could possibly reach
			# (cover bonus taken, no overwatch penalty) — a valid lower bound, so
			# pruning on it can never discard a tile that would have won.
			if steps - COVERED_FLANK_BONUS >= best_score:
				continue
			if board and board.is_tile_claimed(tile, unit):
				continue
			if GridManager.chebyshev_dist(tile, target.grid_pos) > EnemyUnit.ATTACK_RANGE:
				continue
			if Combat.defending_cover(tile, target.grid_pos)[0] != MapData.Cover.NONE:
				continue
			# The flanker will be at rest on the tile when it shoots, so it may
			# lean from it; the target leans if it is at rest now (GDD §6.1.2).
			# And the shot has to be worth taking, not merely possible — a flank
			# in the dark at the edge of range buys nothing.
			if not GoapBrain.shot_viable_from(unit, tile, target):
				continue
			var score := steps
			if Combat.defending_cover(target.grid_pos, tile)[0] != MapData.Cover.NONE:
				score -= COVERED_FLANK_BONUS
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
		return not _pick(unit, ctx).is_empty()

	func ap_cost(unit: Unit, ctx: Dictionary) -> int:
		var pick := _pick(unit, ctx)
		return unit.move_cost_for(int(pick.get("steps", 1))) if not pick.is_empty() else 99

	## Whether the cover tile keeps (or gains) the flank. The planner used to
	## assume a flank survived any move, so a wounded merc — barred from a plain
	## Attack by the caution rule — satisfied "flank and shoot" with
	## [RepositionToCover, AttackFromCover], walked off its angle into cover, found
	## itself unflanked, flanked again, and repeated that for the whole turn.
	func planned_effects(unit: Unit, ctx: Dictionary) -> Dictionary:
		var pick := _pick(unit, ctx)
		var target: Unit = ctx.get("target")
		var fx := effects.duplicate()
		if not pick.is_empty() and target != null:
			var open: bool = Combat.defending_cover(pick["tile"], target.grid_pos)[0] \
				== MapData.Cover.NONE
			fx[FLANKED] = open
			fx[COVER_BROKEN] = open
		return fx

	func _pick(unit: Unit, ctx: Dictionary) -> Dictionary:
		if not ctx.has(&"_cover_pick"):
			ctx[&"_cover_pick"] = _best_tile(unit, ctx.get("target"))
		return ctx[&"_cover_pick"]

	func execute(unit: Unit, ctx: Dictionary) -> bool:
		var pick := _pick(unit, ctx)
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

	##
	## The tile must still leave a viable shot at the threat, within a walk that
	## keeps the shot's AP in hand. Cover here only ever exists to shoot from
	## (`AttackFromCover`); a cover tile behind a corner with no line, or one so
	## far away the walk spends the shot, was a turn of walking with nothing at
	## the end of it — and it handed the next replan an unflanked position to
	## flank out of again.
	static func _best_tile(unit: Unit, threat: Unit) -> Dictionary:
		if threat == null:
			return {}
		var reach := GoapBrain.move_reach_keeping_shot(unit)
		if reach < 1:
			return {}
		var costs := GridManager.reachable_costs(unit.grid_pos, reach)
		var watcher_list := TileThreat.watchers(unit)
		var best := {}
		var best_score := 1 << 30
		for tile: Vector3i in costs:
			var steps: int = costs[tile]
			if steps >= best_score:
				continue
			if Combat.defending_cover(threat.grid_pos, tile)[0] == MapData.Cover.NONE:
				continue
			if not GoapBrain.shot_viable_from(unit, tile, threat):
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
		# Corner cover is a wall (defence[2]), and there is no shooting a wall
		# out: offered anyway, a cover-breaker would fire at it every activation.
		var defence := Combat.defending_cover(unit.grid_pos, target.grid_pos)
		return defence[0] != MapData.Cover.NONE and not defence[2]

	func ap_cost(unit: Unit, _ctx: Dictionary) -> int:
		return unit.action_cost(UnitStats.Action.SHOOT)

	func execute(unit: Unit, ctx: Dictionary) -> bool:
		var target: Unit = ctx.get("target")
		if target == null or target.is_downed:
			return false
		var defence := Combat.defending_cover(unit.grid_pos, target.grid_pos)
		if defence[0] == MapData.Cover.NONE or defence[2]:
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
##
## STOPS AT THE FIRST TILE WITH A SHOT. It used to walk its whole budget toward
## the target's tile regardless, and was priced to the planner as a single tile —
## so it looked nearly free, got picked whenever IN_RANGE was false (which, since
## IN_RANGE became "a 15% shot exists", includes darkness and heavy cover at close
## quarters), and walked the merc a full turn's distance in. A few of those and
## it was standing next to the player. Now the planner is charged for the tiles
## actually walked, and promises IN_RANGE/HAS_LOS only when the walk really ends
## somewhere with a shot; otherwise it promises only CLOSED_DISTANCE, which only
## a doctrine's last-resort "close" goal asks for.
class Advance extends GoapAction:
	func _init() -> void:
		name = &"Advance"
		preconditions = {}
		effects = {IN_RANGE: true, HAS_LOS: true, CLOSED_DISTANCE: true}

	func is_available(unit: Unit, ctx: Dictionary) -> bool:
		var target: Unit = ctx.get("target")
		if target == null or target.is_downed:
			return false
		if unit.move_tiles_affordable() < 1 \
				or GridManager.chebyshev_dist(unit.grid_pos, target.grid_pos) <= 1:
			return false
		return not _walk(unit, ctx).is_empty()

	func ap_cost(unit: Unit, ctx: Dictionary) -> int:
		var walk := _walk(unit, ctx)
		return unit.move_cost_for(walk["path"].size()) if not walk.is_empty() else 99

	func planned_effects(unit: Unit, ctx: Dictionary) -> Dictionary:
		var walk := _walk(unit, ctx)
		if not walk.is_empty() and walk["shot"]:
			return effects
		return {CLOSED_DISTANCE: true}

	## {"path": the tiles to walk, "shot": whether its last tile has a viable
	## shot}, or {} for no useful walk. Cached on `ctx`, which `GoapBrain.run`
	## rebuilds every step, so the planner's repeated cost/effect queries share one
	## path search and the cache can never outlive the board it was computed on.
	##
	## Walks within the AP that still leaves a shot; when the unit cannot afford a
	## shot anyway, within everything it has (still stopping at a shot tile, for
	## next activation).
	static func _walk(unit: Unit, ctx: Dictionary) -> Dictionary:
		if ctx.has(&"_advance_walk"):
			return ctx[&"_advance_walk"]
		var out := {}
		var target: Unit = ctx.get("target")
		if target != null:
			# Routed THROUGH squadmates, the way a horde body plans through its own
			# pack (SwarmUnit._move_toward): they are about to move on. Without it
			# one merc paused in a single-tile corridor cut the only route for the
			# whole squad behind it — they found no path at all and went on
			# overwatch, every round, at the back of the queue.
			var mates := {}
			for ally: Unit in unit.allies():
				mates[ally.grid_pos] = true
			var full := GridManager.find_path(unit.grid_pos, target.grid_pos, 999, true, null, mates)
			if full.size() > 1:
				full.resize(full.size() - 1)  # never onto the target's own tile
				# Walk only the clear stretch: up to the first held tile, so a
				# blocked merc closes up behind the one ahead instead of stopping.
				for i in full.size():
					if not GridManager.is_free(full[i]):
						full.resize(i)
						break
				var budget := GoapBrain.move_reach_keeping_shot(unit)
				if budget < 1:
					budget = unit.move_tiles_affordable()
				var cap := mini(budget, full.size())
				if cap >= 1:
					out = {"path": full.slice(0, cap), "shot": false}
					for i in cap:
						if GoapBrain.shot_viable_from(unit, full[i], target):
							out = {"path": full.slice(0, i + 1), "shot": true}
							break
		ctx[&"_advance_walk"] = out
		return out

	func execute(unit: Unit, ctx: Dictionary) -> bool:
		var target: Unit = ctx.get("target")
		if target == null:
			return false
		var walk := _walk(unit, ctx)
		if walk.is_empty():
			return false
		var board: SquadBlackboard = ctx.get("blackboard")
		if board:
			board.claim(SquadBlackboard.Role.ADVANCER, unit, target)
		var path: Array[Vector3i] = []
		path.assign(walk["path"])
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
		# NOT `IN_COVER`, which it used to claim: that let "fight from cover" be
		# satisfied by [HoldOverwatch, AttackFromCover] — the cheapest plan whenever
		# real cover was far off — and overwatch ends the activation, so the shot
		# never came. A merc in the open with a clean line went on overwatch.
		effects = {HOLDING_ANGLE: true}
		ends_activation = true

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
