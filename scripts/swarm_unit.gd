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
## when K_REFLEXES or the melee base moves. Against the swarm's 8 AP pool this is
## up to 5 tiles then a claw, or two claws when already in contact.
## WormUnit overrides action_cost with its own rule and is unaffected.
const CLAW_AP_COST := 3

## SYNAPSE. Enough of the swarm in one place and it stops acting like separate
## bodies: every one within SYNAPSE_RADIUS of SYNAPSE_MASS awake kin (itself
## included, any horde) is LINKED, and a linked body is agitated — it walks
## LINKED_FREE_TILES extra a turn and everything it does plays faster. Gunfire
## or a blast within SURGE_RADIUS of a linked body PRIMES a surge: its next
## activation gets SURGE_FREE_TILES instead, and it goes faster still.
##
## Mobility and look ONLY. The free tiles are move-only (`move_cost_for`), never
## AP, so a linked body in contact claws exactly as often as a lone one — and
## nothing here touches HP or damage. A horde spawns 5-8 (AlienPresets.HORDE_*),
## so a full pack starts linked and thinning it is how the player breaks it.
## Lone shamblers stay outpaceable, which is the tier's whole premise.
const SYNAPSE_MASS := 6
const SYNAPSE_RADIUS := 3
const SURGE_RADIUS := 4
const LINKED_FREE_TILES := 1
const SURGE_FREE_TILES := 2

## Animation and walk-speed multiplier per agitation level: calm, linked,
## surging. UnitVisual.tempo and `move_speed` scale together so feet stay planted.
const AGITATION_TEMPO: Array[float] = [1.0, 1.3, 1.55]

## CROWD GAIT, for a body whose model owns a walk AND a run (zombie_2): it
## shambles on its own and runs once `run_crowd` awake kin are within
## SYNAPSE_RADIUS (itself included), and at CROWD_SPRINT the run plays at the
## linked tempo. That replaces the synapse's linked tempo for such a body; the
## surge's still goes over the top. 0 means one gait — `walks_only` as authored.
@export var run_crowd := 0

## The run's `move_speed` at tempo 1, owed the same care as the walk's: it is
## the clip's stride over its cycle in UnitVisual, or the feet skate.
@export var run_speed := 0.0

const CROWD_SPRINT := 8


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

## Whether this body was in the synapse when last checked (`_refresh_synapse`).
var linked := false

## Awake kin within SYNAPSE_RADIUS, itself included, when last checked. 0 for a
## body that is asleep or outside the synapse.
var crowd := 0

## 0 calm, 1 linked, 2 surging — indexes AGITATION_TEMPO.
var agitation := 0

## Tiles this activation may still walk without paying AP. Spent before AP
## (`move_cost_for`, `move_along`); set afresh by every `begin_activation`.
var free_tiles := 0

## Set by gunfire heard close while linked; spent by the next activation.
var _surge_primed := false

## `move_speed` as authored, which agitation scales.
var _calm_move_speed := 0.0

## Last round each pack's surge was logged, by horde_id (or name for a lone
## body): one line a pack, not one per body.
static var _surge_logged := {}


func _ready() -> void:
	super()
	_vary_body()
	_calm_move_speed = move_speed


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


## The zombie tier bleeds (VFX.HitStyle.FLESH): Fodder, the brute and the
## brawler. The worm extends this and opts back out.
func hit_style() -> int:
	return VFX.HitStyle.FLESH


## The shambling tier acts after everything else in the round (TurnManager) —
## Fodder, and the brawler and worm that extend it.
func draws_last() -> bool:
	return true


func action_cost(action: UnitStats.Action) -> int:
	if action == UnitStats.Action.MELEE:
		return CLAW_AP_COST
	return super(action)


# --- Synapse -------------------------------------------------------------------


## Whether this type takes part in the synapse at all. The worm has its own
## gather-and-grow answer to numbers (WormUnit) and opts out.
func joins_synapse() -> bool:
	return true


func begin_activation() -> void:
	super()
	_refresh_synapse()
	free_tiles = 0
	if linked:
		free_tiles = SURGE_FREE_TILES if _surge_primed else LINKED_FREE_TILES
		_set_agitation(2 if _surge_primed else 1)
	else:
		_set_agitation(0)
	# Spent by this activation. The tiles are NOT zeroed when take_turn returns:
	# a body held up by its pack comes back through `_combat_turn` afterwards
	# (TurnManager._horde_turn) and is owed them; the next activation resets.
	_surge_primed = false


## Sound still rouses as it does for every alien (super). On top of that, a
## linked body close to the noise is primed to surge at it — even one already
## in COMBAT, which the base hearing ignores.
func hear_noise(at: Vector3i) -> void:
	super(at)
	if is_downed or not joins_synapse() \
			or GridManager.chebyshev_dist(grid_pos, at) > SURGE_RADIUS:
		return
	_refresh_synapse()
	if not linked:
		return
	_surge_primed = true
	_set_agitation(2)  # shown now: the pack bristles as the shot goes off
	var pack := horde_id if horde_id != "" else String(name)
	if _surge_logged.get(pack, -1) != TurnManager.turn_number:
		_surge_logged[pack] = TurnManager.turn_number
		action_logged.emit("The swarm around %s surges toward the noise" % stats.display_name)


func _refresh_synapse() -> void:
	var awake := joins_synapse() and not is_downed and alert_state != AlertState.UNAWARE
	crowd = _kin_in_reach() if awake else 0
	linked = crowd >= SYNAPSE_MASS


## Awake swarm bodies within SYNAPSE_RADIUS, this one included.
func _kin_in_reach() -> int:
	var count := 0
	for node in get_tree().get_nodes_in_group("enemy_units"):
		var kin := node as SwarmUnit
		if kin == null or kin.is_downed or kin.faction != faction or not kin.joins_synapse() \
				or kin.alert_state == AlertState.UNAWARE:
			continue
		if GridManager.chebyshev_dist(grid_pos, kin.grid_pos) <= SYNAPSE_RADIUS:
			count += 1
	return count


func _set_agitation(level: int) -> void:
	agitation = level
	_refresh_pace()


## Gait, tempo and `move_speed` from `agitation` and `crowd`, kept in step so
## the feet stay planted whichever clip is playing.
func _refresh_pace() -> void:
	var tempo := AGITATION_TEMPO[agitation]
	var speed := _calm_move_speed
	if run_crowd > 0:
		var running := crowd >= run_crowd
		walks_only = not running
		if running:
			speed = run_speed
		if agitation < 2:
			tempo = AGITATION_TEMPO[1] if crowd >= CROWD_SPRINT else 1.0
	move_speed = speed * tempo
	if not is_equal_approx(tempo, visual.tempo):
		visual.set_tempo(tempo)


## The free tiles on top of what the AP buys. Where the AP alone would leave
## nothing after the reserve, the free tiles are walked and the reserve kept —
## so a surge closes the gap and still arrives with the claw in hand.
func _move_budget(reserve_ap: int = 0) -> int:
	if free_tiles > 0 and ap >= reserve_ap and ap - reserve_ap < move_ap_per_tile():
		return free_tiles
	return super(reserve_ap) + free_tiles


## Free tiles come off the front of any walk. Spent in `move_along`, which every
## paid walk follows its `spend_ap(move_cost_for(...))` with.
func move_cost_for(tiles: int) -> int:
	return super(maxi(0, tiles - free_tiles))


## Also re-reads the crowd first, so the gait is the pack as it stands when
## this body sets off, not as it stood when the activation began.
func move_along(path: Array[Vector3i]) -> void:
	free_tiles = maxi(0, free_tiles - path.size())
	_refresh_synapse()
	_refresh_pace()
	await super(path)


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


## SQUEEZING PAST (2026-11-09). The zombie tier walks THROUGH any standing
## alien's tile mid-move — its own pack, another horde, a ranged alien in a
## corridor — and only has to END on a tile of its own (Unit.move_along steps it
## off a shared one). A pack therefore pours through a doorway instead of queueing
## at it, and a horde turn needs no waiting and retrying round its own bodies.
## Soldiers, robots and mercs still block. The worm, which attacks by moving onto
## its prey, keeps its own rules (WormUnit).
func squeezes_past() -> bool:
	return true


## The plain route, squeezing past other aliens (see `squeezes_past`).
func _route_path(dest: Vector3i, allow_occupied_goal: bool) -> Array[Vector3i]:
	return GridManager.find_path(grid_pos, dest, 999, allow_occupied_goal, null, alien_tiles())


## Closing in as a crowd: the walk this activation can afford that ends on a tile
## of this body's own, as close to the prey as it gets.
##
## In reach, it takes the free tile beside the prey it reaches soonest, so a pack
## WRAPS ROUND its prey rather than every body aiming for the one tile in front.
## Out of reach, it walks as far along its route as the AP allows and stops on the
## last free tile of that stretch. Nothing to walk (or nowhere free to stop) ends
## its activation, as a blocked walk always has.
func _move_toward(quarry: Unit, reserve_ap: int = 0) -> void:
	if not squeezes_past():
		await super(quarry, reserve_ap)
		return
	var path := _squeeze_path(quarry.grid_pos, _move_budget(reserve_ap), alien_tiles())
	if path.is_empty():
		ap = 0
		return
	spend_ap(move_cost_for(path.size()))
	await move_along(path)
	action_logged.emit("%s moved to %s" % [stats.display_name, path[-1]])


## The walk `_move_toward` takes toward `prey`, at most `budget` tiles, crossing
## the tiles in `through`, ending on a tile nobody holds or reserves. [] for none.
func _squeeze_path(prey: Vector3i, budget: int, through: Dictionary) -> Array[Vector3i]:
	var none: Array[Vector3i] = []
	if budget < 1:
		return none
	var reach: Dictionary = GridManager.reachable_costs(grid_pos, budget, through)
	var best := Vector3i.ZERO
	var best_cost := budget + 1
	for spot: Vector3i in GridManager.neighbors(prey):
		var cost: int = reach.get(spot, budget + 1)
		if cost < best_cost and _can_stop_on(spot):
			best = spot
			best_cost = cost
	if best_cost <= budget:
		return GridManager.find_path(grid_pos, best, budget, false, null, through)
	var route := GridManager.find_path(grid_pos, prey, 999, true, null, through)
	if route.is_empty():
		return none
	route.resize(route.size() - 1)  # never onto the prey itself
	route = route.slice(0, mini(budget, route.size()))
	while not route.is_empty() and not _can_stop_on(route[-1]):
		route.pop_back()
	return route


func _can_stop_on(tile: Vector3i) -> bool:
	return GridManager.is_free(tile) and GridManager.open_destination(tile, self)


## What the log calls this unit's melee blow. The worm bites.
func _melee_verb() -> String:
	return "clawed"
