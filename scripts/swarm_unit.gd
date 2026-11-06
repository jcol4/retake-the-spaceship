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
## MOVE-THEN-CLAW (2026-11-03). The old close-OR-swing rule (a 5 AP claw against
## a 6 AP pool, so only a one-tile step could precede a swing) is retired: the
## claw is a flat CLAW_AP_COST, cheap enough that a shambler can walk a few tiles
## and still land a blow on the same activation. The player's warning now comes
## from the swarm's short reach (pool minus claw), not from a dead turn.


## The claw's price, flat rather than read off Reflexes so it does not drift
## when K_REFLEXES or the melee base moves. Against the swarm's 6 AP pool this is
## up to 3 tiles then a claw, or two claws when already in contact.
## WormUnit overrides action_cost with its own rule and is unaffected.
const CLAW_AP_COST := 3


## The horde this body was spawned in (main.gd `_spawn_hordes`, NestUnit's
## burst). Empty for a lone one. Bodies sharing an id wake as ONE: the first to
## go to combat takes the rest in with it on the same target — see
## `_enter_combat`. Set before add_child.
var horde_id := ""

## The horde's anchor (AlienPresets.brute): drawn bigger so it reads before it
## is shot. Set before add_child.
var is_brute := false

## Hordes part-way through waking (`_enter_combat`), by horde_id.
static var _waking_hordes := {}

## Set while TurnManager decides this body's horde (`_horde_turn`). A body whose
## way is held by its own mates may then WAIT for them instead of detouring round
## them or giving its turn up — see `_move_toward`.
var in_horde_turn := false

## Set when this body stopped to wait for a mate. `_horde_turn` comes back to it
## once the others have moved.
var waiting := false


func _ready() -> void:
	super()
	_vary_body()


## The basic Fodder zombie comes apart when it dies (FodderGibs); the brute,
## and the brawler and worm that extend this, do not.
func is_fodder() -> bool:
	return not is_brute


## Thirty copies of one model moving in lockstep read as a copy-paste, not a
## horde. A few percent of size and a random point in each looping clip breaks
## that up. Seeded off the node name rather than the global RNG — the name is
## the same on every peer, and the global stream is what spawning rolls stats
## off, so drawing from it here would shift every roll after this body.
## (WormUnit sets its own scale after this, from its count, and wins.)
func _vary_body() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(String(name))
	visual.model_scale = (AlienPresets.BRUTE_SCALE if is_brute else 1.0) * rng.randf_range(0.95, 1.05)
	visual.loop_phase = rng.randf()


## The shambling tier acts after everything else in the round (TurnManager) —
## Fodder, and the brawler and worm that extend it.
func draws_last() -> bool:
	return true


func action_cost(action: UnitStats.Action) -> int:
	if action == UnitStats.Action.MELEE:
		return CLAW_AP_COST
	return super(action)


## A horde wakes together. Room-scoped propagation (EnemyUnit._propagate_alert)
## only ROUSES neighbours; a horde-mate is handed the target outright, because a
## pack that trickles into the fight one body at a time is not a horde.
##
## The pack screams ONCE as it turns, from the body nearest the prey — thirty
## identical screams on one frame read as a copy-paste, the same as lockstep
## loops do (`_vary_body`). A lone body is a pack of one.
func _enter_combat(new_target: Unit, reason: String) -> void:
	var was := alert_state
	super(new_target, reason)
	# A mate being woken by its pack's first body: that body screams for it.
	if was == AlertState.COMBAT or _waking_hordes.has(horde_id):
		return
	var pack: Array[SwarmUnit] = [self]
	if horde_id != "":
		_waking_hordes[horde_id] = true
		for node in get_tree().get_nodes_in_group("enemy_units"):
			var mate := node as SwarmUnit
			if mate == null or mate == self or mate.horde_id != horde_id \
					or mate.is_downed or mate.alert_state == AlertState.COMBAT:
				continue
			mate._enter_combat(new_target, "")  # silent: one line for the pack, below
			pack.append(mate)
		_waking_hordes.erase(horde_id)
		if pack.size() > 1:
			action_logged.emit("%d more surge after %s" % [pack.size() - 1, stats.display_name])
	screamer(pack, new_target.grid_pos).visual.play_action(UnitVisual.ALERT_SCREAM)


## The body in `pack` nearest `at`, a tie broken at random. The draw is seeded
## off the pack and the round rather than the global RNG, which spawning rolls
## stats off (see `_vary_body`). Host-only: the scream mirrors itself.
static func screamer(pack: Array[SwarmUnit], at: Vector3i) -> SwarmUnit:
	var nearest: Array[SwarmUnit] = []
	var best := INF
	for body in pack:
		var d := Vector3(body.grid_pos - at).length_squared()
		if d < best:
			best = d
			nearest = [body]
		elif d == best:
			nearest.append(body)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%s:%d:%d" % [pack[0].horde_id, TurnManager.turn_number, nearest.size()])
	return nearest[rng.randi_range(0, nearest.size() - 1)]


## A Fodder does not scream on merely noticing something — it screams when it
## turns on its prey, once per pack (`_enter_combat`).
func _on_woken() -> void:
	pass


func _combat_turn() -> void:
	# Replaces the base ranged loop entirely. Reached only in COMBAT — the
	# awareness states and everything that feeds them are EnemyUnit's business.
	var melee_cost := action_cost(UnitStats.Action.MELEE)
	while ap > 0 and not is_downed:
		var quarry := acquire_target()
		if quarry == null:
			return
		# Or standing ON it: a body holds no tile, so a swarm can end a walk on top
		# of one, and must still be able to reach it from there.
		if GridManager.is_melee_adjacent(grid_pos, quarry.grid_pos) or grid_pos == quarry.grid_pos:
			if ap < melee_cost:
				ap = 0  # in contact but cannot pay for the swing — the turn is over
				return
			spend_ap(melee_cost)
			# The quarry may already be DOWN — the aliens finish prey (GDD §4.4,
			# Faction.DOWNED_POLICY), and a claw on a body comes off its downed
			# bar. The loop needs nothing else for it: a body holds no tile, so
			# closing on one walks up beside it exactly as closing on a soldier does.
			var was := quarry.life_state
			var result: Combat.ShotResult = await melee_at(quarry)
			action_logged.emit("%s %s %s (%d%% acc): %s" % [
				stats.display_name, _melee_verb(), quarry.stats.display_name, result.accuracy,
				Combat.describe(result),
			])
			_log_casualty(quarry, was)
		else:
			# Stops on the tile before the target's, so the NEXT activation opens
			# already in contact — and walking in still trips any overwatch on the
			# way. It holds back the price of a swing where it can, so arriving
			# adjacent with AP to spare means arriving with a claw in hand.
			await _move_toward(quarry, melee_cost)
			if waiting:
				return  # held up by the pack; the horde turn comes back for it


## Closing in as a pack. The plain route treats every body as a wall, and a horde
## is decided one body at a time — so a body behind its mates (in the clump it
## starts in, or in a doorway) found no way out before they had moved, gave its
## whole activation up, and lagged a round behind the rest.
##
## During a horde turn this plans THROUGH the pack instead, since the mates are
## heading the same way, and walks only as far as the way is clear: the body
## comes up behind the one in front and waits there (`waiting`) for
## `_horde_turn` to try it again. A way round that is no longer than the way
## through is simply taken, as before.
func _move_toward(quarry: Unit, reserve_ap: int = 0) -> void:
	waiting = false
	if not in_horde_turn or horde_id == "":
		await super(quarry, reserve_ap)
		return
	var direct := GridManager.find_path(grid_pos, quarry.grid_pos, 999, true, null, _mate_tiles())
	var around := _route_path(quarry.grid_pos, true)
	if direct.is_empty() or (not around.is_empty() and around.size() <= direct.size()):
		await super(quarry, reserve_ap)
		return
	direct.resize(direct.size() - 1)  # never step onto the prey itself
	var clear := 0
	while clear < direct.size() and GridManager.is_free(direct[clear]):
		clear += 1
	var steps := mini(_move_budget(reserve_ap), clear)
	if steps < 1:
		waiting = true
		return
	var path := direct.slice(0, steps)
	spend_ap(move_cost_for(path.size()))
	await move_along(path)
	action_logged.emit("%s moved to %s" % [stats.display_name, path[-1]])


## The tiles this body's standing horde-mates hold.
func _mate_tiles() -> Dictionary:
	var out := {}
	for node in get_tree().get_nodes_in_group("enemy_units"):
		var mate := node as SwarmUnit
		if mate != null and mate != self and mate.horde_id == horde_id and not mate.is_downed:
			out[mate.grid_pos] = true
	return out


## What the log calls this unit's melee blow. The worm bites.
func _melee_verb() -> String:
	return "clawed"
