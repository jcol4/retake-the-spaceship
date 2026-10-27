class_name MercUnit
extends EnemyUnit
## A rival mercenary — the prototype consumer of the shared GOAP coordination
## framework. Design: docs/design/systems/coordinated-ai/
##
## STUB. It fights with the inherited ranged loop today, which makes it a
## competent lone gunman and nothing more. The entire point of the faction is the
## squad behaviour it does not have yet: `Suppress` → `Flank` negotiated through
## a shared blackboard, so two mercs never independently claim the same job. That
## arrives by overriding `_combat_turn` — the same seam SwarmUnit and SecurusUnit
## already use — and nothing else here should need to move when it does.
##
## It extends `EnemyUnit` rather than `Unit` for the awareness state machine
## (UNAWARE/ALERT/COMBAT), and that inheritance is a better fit here than it is
## for the robots: EnemyUnit's detection is LIGHT-based, and a human being unable
## to see into a dark compartment is exactly right. The squad's own flashlight
## discipline (Sec 5.2) therefore works against mercs the same way it works
## against aliens, with no new code — turn the lights off and they lose you.
##
## Being human cuts both ways, which is the faction's real hook: they carry rig
## lights of their own, so a merc squad is *visible in the dark* and its beams
## give away its position and facing. Neither of the other two factions can be
## tracked that way — the aliens carry no light and the robots do not need one.


## Which squad's blackboard this unit negotiates on. One encounter squad in the
## alpha (doc Sec 4.6: "mercs: fixed encounter squad"); a deck that wants two
## independent merc teams sets this per spawn.
@export var squad_id: String = "mercs"

var _brain: GoapBrain = null

## Set by `take_damage` immediately before `Unit.fire_at`/`melee_at` calls
## `come_under_fire` on the same synchronous stack (no `await` runs between the
## two) — see `come_under_fire`'s comment. Cleared there once read, so it never
## outlives the shot that set it.
var _pending_hit := false


func take_damage(amount: int) -> int:
	_pending_hit = true
	return super(amount)


func _init() -> void:
	# Runs after EnemyUnit._init, which set the alien defaults. Both are wrong for
	# a human and both are corrected here.
	faction = Faction.Id.RIVAL_MERCS
	# The line EnemyUnit turns OFF for the aliens. Mercs are people in a dark
	# derelict: they bring torches, the torches light them up, and everything
	# already wired to the flashlight layer — alien aggro, the accuracy light
	# term, the player's own eyes — starts reading them for free.
	has_flashlight = true


func _ready() -> void:
	super()
	# Built per unit, not shared: `GoapBrain.run` prunes actions that turn out
	# impossible during an activation, and one merc's pruning must not disarm the
	# rest of the squad. The BLACKBOARD is the shared thing, and it is shared on
	# purpose — that is the entire mechanism.
	_brain = Doctrines.merc_brain(Doctrines.blackboard_for(squad_id))
	# A claim outlives its owner's activation (see SquadBlackboard), so death is
	# the one release that cannot wait for the next revalidation sweep — a dead
	# merc's flanker claim would otherwise block the role for two more turns.
	downed.connect(func(_u: Unit) -> void: _brain.blackboard.release_all(self))


## Replaces the inherited lone-gunman loop with the planner. THE seam the whole
## framework hangs off, and deliberately the same one SwarmUnit and SecurusUnit
## already use: a unit either has a brain or it does not, and Fodder not having
## one is structural rather than a rule somebody has to remember.
func _combat_turn() -> void:
	var quarry := acquire_target()
	if quarry == null:
		return
	# Put the contact back out every activation, not only on the transition into
	# Combat. `_propagate_alert` fires exactly once per engagement, which meant a
	# squadmate that happened to be out of the loop for that single instant — busy
	# investigating something older, or one that had lost contact and dropped back
	# to Alert — was written off for the rest of the fight. A radio net is a channel
	# that stays open, and this is the half of that which a one-shot broadcast
	# cannot express. It costs nothing once the squad is engaged: `_receive_call`
	# reports nobody reached and the bark stays quiet.
	_relay_to_squad(quarry.grid_pos, quarry)
	# The squad layer decides before this unit plans (fix D). Run from here rather
	# than on a turn-start signal because a squad only means anything once one of
	# its members has a target — and this is the first moment that is true.
	# `assigned_on_turn` makes it idempotent, so the second merc drawn reads the
	# assignment the first one caused rather than recomputing it.
	var mates := _squadmates()
	SquadCoordinator.assign(_brain.blackboard, mates, quarry)
	# PRIORITY TARGETS (rival-mercs README Sec 6) — may swap `quarry` (and this
	# unit's own `target`) onto whoever the squad has decided matters most, if
	# this unit can actually see that pick and it clears the switch margin.
	quarry = _reconsider_priority_target(quarry, mates)
	await _brain.run(self, quarry)


## Rival mercs finish downed contractors only when it is CHEAP (GDD §4.4/§11.10,
## Faction.DOWNED_POLICY OPPORTUNISTIC). Run after the rest of the activation —
## the planner, an investigation, a patrol — has spent what it wanted, on the AP
## left over, so a body never costs the squad a move it would otherwise have made:
##   - nothing ACTIVE and hostile is in this merc's line of sight (a live threat
##     is always the better use of a round), and
##   - the shot is affordable from WHERE IT STANDS with what is left ("the shot
##     costs at most the AP that remains after repositioning") — no step is ever
##     taken toward a body, and
##   - in ATTACK_RANGE, in line of sight, and the gun has a round in it.
## Not a GOAP goal (extraction plan 2.4 sketched one): the plan's conditions are
## all "after everything else, if it is free", which is a post-step, not a goal
## that competes for priority — and a goal would need the planner to treat a body
## as a target, which every one of its actions is written not to.
func take_turn() -> void:
	# The crew's job (Phase 8) runs first: whether it is time to leave, and — once
	# the crew's ship is on the pad — getting aboard outranks everything else this
	# merc might do with the activation, the fight included.
	if _job_active():
		_update_job()
		if _ship_waiting():
			await _board_turn()
			if ap > 0 and not is_downed and not TurnManager.mission_over:
				await _finish_downed_if_cheap()
			return
	await super()
	if ap > 0 and not is_downed and not TurnManager.mission_over:
		await _finish_downed_if_cheap()


func _finish_downed_if_cheap() -> void:
	var shoot_cost := action_cost(UnitStats.Action.SHOOT)
	while ap >= shoot_cost and can_shoot() and not is_downed:
		# Only a threat it would actually fight counts (Phase 7): a robot standing
		# post across the room, which the squad is deliberately leaving alone, is
		# not a reason to pass up a cheap shot.
		for live in engageable_hostiles():
			if GridManager.has_line_of_sight(self, live):
				return
		var body: Unit = null
		var best := 999999
		for candidate in downed_targets():
			var d := GridManager.chebyshev_dist(grid_pos, candidate.grid_pos)
			if d < best and d <= ATTACK_RANGE and GridManager.has_line_of_sight(self, candidate):
				best = d
				body = candidate
		if body == null:
			return
		spend_ap(shoot_cost)
		var was := body.life_state
		var result: Combat.ShotResult = await fire_at(body, Combat.ShotAction.SHOOT)
		action_logged.emit("%s puts a round into %s on the deck (%d%% acc): %s" % [
			stats.display_name, body.stats.display_name, result.accuracy, Combat.describe(result)])
		_log_casualty(body, was)


## Margin the squad's priority pick must beat the current target's own score by
## before this unit actually switches onto it — mirrors the shape of
## `GoapBrain.COMMITMENT_BONUS`'s hysteresis for the same reason: without it, a
## squad whose two candidates score within a point of each other would have
## every member retargeting every activation, which reads as indecision rather
## than as a squad focusing fire.
const PRIORITY_SWITCH_MARGIN := 5.0

func _reconsider_priority_target(current: Unit, mates: Array) -> Unit:
	var board := _brain.blackboard
	if board == null:
		return current
	var pick: Unit = SquadCoordinator.update_priority_target(board, mates)
	if pick == null or pick == current or pick.is_downed:
		return current
	# The squad's pick is only a real option for THIS unit if it can actually
	# see it — the radio buys a heading, never x-ray vision, the same limit
	# `_receive_call` already documents for a bare contact call.
	if not GridManager.has_line_of_sight(self, pick):
		return current
	var current_score := SquadCoordinator.threat_score(current, mates, board) \
		if current != null else -INF
	var pick_score := SquadCoordinator.threat_score(pick, mates, board)
	if pick_score < current_score + PRIORITY_SWITCH_MARGIN:
		return current
	target = pick
	last_known_pos = pick.grid_pos
	_has_last_known = true
	return pick


## Whether an UNAWARE merc walks the squad's patrol instead of holding still.
## Exported so an authored ambush can still plant one at a fixed post by
## turning it off.
@export var patrols: bool = true

## How close a member has to get to the squad's shared destination before it
## counts as "arrived" and picks the next one. Not zero: the destination is
## picked blind, and demanding an exact tile means one squadmate boxed out of
## it by another (or by a piece of cover) stalls the whole squad's route
## instead of just tightening the cluster.
const PATROL_ARRIVE_RADIUS := 2
## How many random tiles to try before giving up on finding a reachable one
## this activation. A miss is rare — most of a generated deck is one connected
## component — and cheap to retry; it is not worth a smarter sampler for it.
const PATROL_PICK_ATTEMPTS := 5


## The GOAP framework's per-unit combat plan makes a squad fight like a squad;
## this is the other half — a squad that is not fighting should not read as
## furniture. One destination for the whole squad, not one route per merc: it
## is written to the shared blackboard (the same object `SquadCoordinator`
## already negotiates roles on) so every member walks toward the same point
## and the squad drifts across the deck as a cluster instead of each merc
## wandering off on its own errand.
func _idle_turn() -> void:
	# On an extraction deck an unaware crew is on the job, not wandering (Phase 8).
	if _job_active():
		await _job_turn()
		return
	if not patrols or _brain == null:
		return
	var dest := _squad_patrol_dest()
	if dest == grid_pos:
		return  # nowhere reachable was found this activation
	await _move_to_tile(dest, false)
	# Same beat as `_investigate`: check again after moving, not just at the
	# top of the activation, so turning a corner mid-patrol into a sightline
	# the player is standing in reacts on the spot instead of walking another
	# leg first and only noticing next time this merc is drawn.
	_look_for_targets()
	if alert_state == AlertState.COMBAT:
		await _combat_turn()


## Reads the squad's shared destination, or has this unit pick the squad's
## NEXT one if it has just arrived at the current one (within
## `PATROL_ARRIVE_RADIUS`) or none has been set yet. Whichever member happens
## to close the distance during its own activation is the one that re-rolls
## for everybody — there is no separate "squad leader", the same way there
## isn't one for role assignment.
func _squad_patrol_dest() -> Vector3i:
	var board := _brain.blackboard
	var have_dest: bool = board.fact("patrol_dest_set", false)
	if have_dest:
		var dest: Vector3i = board.fact("patrol_dest", Vector3i.ZERO)
		if GridManager.chebyshev_dist(grid_pos, dest) > PATROL_ARRIVE_RADIUS:
			return dest
	var picked := _pick_patrol_point()
	if picked == grid_pos:
		return grid_pos  # nothing reachable found this activation — try again next time
	board.set_fact("patrol_dest", picked)
	board.set_fact("patrol_dest_set", true)
	return picked


## A random walkable tile anywhere on the deck, map-wide rather than
## room-scoped — a merc squad is a roaming patrol, not a sentry post, and nothing
## here keys off `squad_id`'s room the way spawning does. Retries a few times
## against a genuinely unreachable pick (a sealed compartment, most likely)
## before settling for "stay put", which just means this unit tries again next
## activation rather than the squad ever getting stuck.
func _pick_patrol_point() -> Vector3i:
	var map := get_tree().get_first_node_in_group("map")
	if map == null:
		return grid_pos
	var tiles: Array = map.data.walkable_positions()
	if tiles.is_empty():
		return grid_pos
	for _i in PATROL_PICK_ATTEMPTS:
		var candidate: Vector3i = tiles[randi() % tiles.size()]
		if candidate != grid_pos and not GridManager.find_path(grid_pos, candidate, 999).is_empty():
			return candidate
	return grid_pos


## Set on a merc that is being roused BY its own squad, so it does not turn
## round and relay the same contact back. Without it one sighting bounces around
## the squad emitting a radio call per member per hop.
var _being_relayed: bool = false


## A merc squad shares contacts over the radio, so alerting one alerts all of
## them — anywhere on the deck.
##
## This is the third distinct alert channel in the game and the point is that all
## three are different. The aliens propagate by COMPARTMENT: they have no comms,
## so a scream carries as far as a room and shutting a door contains it. The
## security robots propagate by ZONE over `SecurityNetwork`: a machine reports to
## infrastructure, which is why bypassing one sentry can still light up a whole
## checkpoint. Mercenaries are people with radios, so their alert ignores
## geometry entirely and is bounded only by who is on the net.
##
## The practical consequence for the player is a real one: against aliens you can
## isolate and pick off, and against mercs you cannot. Engaging any part of a
## merc squad engages the squad.
func _propagate_alert() -> void:
	# Guarded here as well as in `rouse`, because a relayed merc that takes the
	# handoff enters Combat, and `_enter_combat` propagates. Without this the
	# squad's own call bounces back off every receiver it reaches.
	if _being_relayed:
		return
	# A confirmed sighting goes out as a CONTACT — the target itself, not merely
	# the tile it was standing on. That is the whole difference between a radio and
	# a scream. The aliens' `_propagate_alert` withholds the target on purpose (a
	# neighbour heard something kick off and saw nothing), but a merc on the net is
	# being TOLD who to shoot, which is what makes "engaging any part of a merc
	# squad engages the squad" true rather than aspirational.
	_relay_to_squad(last_known_pos, target)


## Shooting at ONE merc engages the WHOLE squad, and does so whether the shot
## hit, missed, or killed the man it was aimed at.
##
## The live case needs no special handling — `super` puts this merc into Combat,
## `_enter_combat` propagates, and the relay hands the shooter to every squadmate
## as a confirmed contact. The DEAD case is the one a naive implementation loses,
## and it is the case that matters most: a corpse cannot call anything in, so a
## clean kill on the only merc who knew about you would make the shot that killed
## him the quietest thing on the deck. The player would be rewarded for one-shot
## kills with a squad that never reacted, which is the exact opposite of what a
## squad on a radio should feel like.
##
## So the call goes out on his behalf. Read it as the squad hearing his channel
## open and cut off, which tells them as much as anything he could have said.
func come_under_fire(shooter: Unit) -> void:
	if shooter == null or not is_hostile_to(shooter):
		return
	# PRIORITY TARGETS' "demonstrated danger" term (rival-mercs README Sec 6):
	# tally a CONFIRMED hit against the squad, not merely an incoming shot —
	# `_pending_hit` is set by `take_damage` immediately before `Unit.fire_at`/
	# `melee_at` calls this, synchronously and with nothing else able to run in
	# between, so it names exactly the shot that just landed. Recorded ahead of
	# the `is_downed` branch below: the squad should credit the shooter for the
	# kill shot too, not only for hits its target survived.
	if _pending_hit and _brain != null and _brain.blackboard != null:
		var key := SquadCoordinator.hit_fact_key(shooter)
		_brain.blackboard.set_fact(key, _brain.blackboard.fact(key, 0.0) + 1.0)
	_pending_hit = false
	if is_downed:
		_relay_to_squad(shooter.grid_pos, shooter)
		return
	super(shooter)


## Rousing this merc also puts its squad on notice — not just entering combat.
##
## `_propagate_alert` alone fires only on a confirmed sighting, which would mean
## a merc that HEARD gunfire kept it to itself. A radio squad does not do that,
## and the sound channel is exactly the sort of half-contact a squad shares.
func rouse(at: Vector3i) -> void:
	var was := alert_state
	super(at)
	if alert_state != was and not _being_relayed:
		# No target to hand over: this merc has a stimulus, not a sighting, so the
		# squad gets the same half-contact it did.
		_relay_to_squad(at, null)


## Puts a call out to every living squadmate. `contact` is the sighted unit when
## there is one and null for a bare stimulus; handing it over is what upgrades the
## receivers to Combat rather than merely stirring them.
func _relay_to_squad(at: Vector3i, contact: Unit) -> void:
	var reached := 0
	for other: MercUnit in _squadmates():
		if other == self:
			continue
		# Flagged on the RECEIVER, not the sender: it is the unit being told that
		# must not relay onward, and one hop from the unit that actually saw
		# something is the whole of the traffic.
		other._being_relayed = true
		if other._receive_call(at, contact):
			reached += 1
		other._being_relayed = false
	if reached == 0:
		return  # nobody learned anything — the net stays quiet
	if contact != null:
		action_logged.emit("%s: \"Contact — %s at %s. All callsigns, engage.\"" % [
			stats.display_name, contact.stats.display_name, at])
	else:
		action_logged.emit("%s: \"Something at %s — all callsigns, moving.\"" % [
			stats.display_name, at])


## Acts on a squadmate's radio call. Returns whether this merc learned anything
## from it, so the caller can stay silent on a call that told nobody anything.
##
## Deliberately NOT gated on being UNAWARE, which is the shape `rouse` has and the
## shape this used to have. That gate is right for a scream — a creature already
## reacting to something does not need telling twice — and it is exactly wrong for
## a radio, because the one call it throws away is the one that matters. A merc
## roused by a distant noise is ALERT, so when a squadmate opened fire a moment
## later the UNAWARE-only filter dropped the sighting on the floor and left it
## walking to a tile the player had already left. It arrived, found nothing,
## settled back to UNAWARE, and the player got to fight the squad one merc at a
## time. Worse, the stimulus that caused it was usually the squad's own opening
## shot: the louder the fight, the more reliably the rest of the squad sat it out.
func _receive_call(at: Vector3i, contact: Unit) -> bool:
	if is_downed:
		return false
	if contact != null and not contact.is_downed:
		if alert_state == AlertState.COMBAT and target == contact:
			return false  # already fighting the unit being called out
		# Silent — the caller narrates the squad's whole response in one line.
		#
		# Note this hands over a target across the deck, with no sight of it and no
		# line to it, which for any other faction would be a cheat. It is the merc
		# hook working as designed, and it is self-correcting rather than absolute:
		# every shooting action is gated on real LOS, and `_check_contact` walks a
		# merc that cannot actually SEE what it was told about back down to ALERT
		# after `lose_contact_turns`. So the radio buys the squad a heading, not
		# x-ray vision, and killing the lights still breaks the lock.
		_enter_combat(contact, "")
		return true
	if alert_state == AlertState.COMBAT:
		return false  # a vague stimulus tells a unit already in a firefight nothing
	if alert_state == AlertState.ALERT:
		# Already stirred, but by something older. Redirect rather than ignore: the
		# newer call is the better guess at where the trouble actually is.
		if _has_last_known and last_known_pos == at:
			return false
		last_known_pos = at
		_has_last_known = true
		return true
	rouse(at)
	return alert_state != AlertState.UNAWARE


## Living members of this unit's squad, itself included. Keyed by `squad_id`
## rather than by proximity: a merc that has been separated is still on the team,
## and letting distance dissolve the squad would quietly disable coordination
## exactly when a flank has pulled somebody wide.
func _squadmates() -> Array:
	var out: Array = [self]
	for node in get_tree().get_nodes_in_group("units"):
		var other := node as MercUnit
		if other != null and other != self and not other.is_downed and other.squad_id == squad_id:
			out.append(other)
	return out


# --- Third parties (extraction plan Phase 7, GDD §11.0) ----------------------
#
# Mercs are professionals on a job. The player crew is the competition and is
# always fair game. Aliens and robots are hazards: they get fought when they have
# found the squad, stand in its way, or get too close to ignore
# (CrossFactionRules.merc_engages), and are otherwise routed around
# (CrossFactionRules.avoid_penalty). Being shot at always counts as found:
# `come_under_fire` engages the shooter without asking.

## Rank bonus that puts any player-crew contact ahead of any third party in
## `_target_rank`, whatever the distances. Bigger than any deck is wide.
const CONTRACTOR_RANK_BONUS := 1000.0

## The route this merc means to walk this activation (to the noise it is
## investigating, or the squad's patrol point), refreshed at the top of each look
## around. What "blocks the job" is measured against. Empty in Combat: the job is
## then the fight, and the target is not "in the way" of itself.
var _route_cache: Array[Vector3i] = []


func will_engage(other: Unit) -> bool:
	if not is_hostile_to(other):
		return false
	if other.faction == Faction.Id.CONTRACTORS:
		return true  # skip the board reads below for the common case
	return CrossFactionRules.merc_engages(other.faction, _hunting_squad(other),
		CrossFactionRules.blocks_route(other.grid_pos, _route_cache), _squad_distance(other))


## Player crew first, always; then nearest. The squad coordinator's priority
## scoring already weights the crew the same way (FACTION_WEIGHT_PRIMARY).
func _target_rank(unit: Unit, distance: int) -> float:
	var rank := -float(distance)
	if unit.faction == Faction.Id.CONTRACTORS:
		rank += CONTRACTOR_RANK_BONUS
	return rank


## Refreshes the intended route, and lets go of a third-party target that is no
## longer worth the squad's time before looking around again. A merc that broke
## off goes back to the job (UNAWARE: the squad's patrol) rather than to ALERT,
## which would walk it straight back to the thing it just decided to leave.
func _look_for_targets() -> void:
	_route_cache = _intended_route()
	if alert_state == AlertState.COMBAT and target != null and not target.is_downed \
			and _still_a_target(target) and not will_engage(target):
		var left := target
		_has_last_known = false
		_set_state(AlertState.UNAWARE)
		action_logged.emit("%s breaks off from %s — not worth the rounds" % [
			stats.display_name, left.stats.display_name])
		_route_cache = _intended_route()
	super()


## Where this merc is headed when it is not fighting, as a path. With a job
## (Phase 8) that is the job's current destination — the crate, the objective,
## the room it is scouting, the hangar square — whenever the job is what it is
## doing: unaware, or extracting (an extracting crew does not chase noises).
func _intended_route() -> Array[Vector3i]:
	var none: Array[Vector3i] = []
	if _job_active() and (alert_state == AlertState.UNAWARE or job.is_extracting()) \
			and alert_state != AlertState.COMBAT:
		var dest := _job_destination()
		if dest != MercJob.NO_TILE and dest != grid_pos:
			return _route_path(dest, false)
		return none
	match alert_state:
		AlertState.ALERT:
			if _has_last_known and last_known_pos != grid_pos:
				return _route_path(last_known_pos, false)
		AlertState.UNAWARE:
			if patrols and _brain != null and _brain.blackboard != null \
					and _brain.blackboard.fact("patrol_dest_set", false):
				var dest: Vector3i = _brain.blackboard.fact("patrol_dest", grid_pos)
				if dest != grid_pos:
					return _route_path(dest, false)
	return none


## Routes swing wide of third-party hostiles the squad can see, rather than
## walking past them (CrossFactionRules.avoid_penalty). With none in sight it is
## the ordinary shortest path, so a merc on an empty deck walks exactly as before.
func _route_path(dest: Vector3i, allow_occupied_goal: bool) -> Array[Vector3i]:
	var hazards := _known_hazards()
	var guns := _hostile_door_guns()
	if hazards.is_empty() and guns.is_empty():
		return super(dest, allow_occupied_goal)
	return GridManager.find_path_weighted(grid_pos, dest, 999,
		func(tile: Vector3i) -> int: return _route_penalty(tile, hazards, guns),
		allow_occupied_goal)


## Extra cost of stepping on `tile`: the third-party avoidance (Phase 7) plus
## DOOR_GUN_AVOID_PENALTY for every hostile ship's gun covering it (Phase 8 —
## the Phase 5 note: mercs keep out of an enemy ship's field of fire).
func _route_penalty(tile: Vector3i, hazards: Array, guns: Array) -> int:
	var cost := CrossFactionRules.avoid_penalty(tile, hazards) if not hazards.is_empty() else 0
	for gun: DoorGunUnit in guns:
		if gun.covers(tile):
			cost += DOOR_GUN_AVOID_PENALTY
	return cost


## Per tile inside a hostile door gun's reach (DoorGunUnit.covers). Bigger than
## the third-party penalty: a gunner on a belt is worse company than an alien,
## and the ship it rides is not going anywhere. Still finite, so a merc whose
## only way through is under the gun takes it rather than freezing.
const DOOR_GUN_AVOID_PENALTY := 4


## Live hostile door gunners this merc's crew knows are there: ships at hangars
## the crew has found (Phase 8). Empty off an extraction deck, so a legacy deck
## routes exactly as before.
func _hostile_door_guns() -> Array:
	var out: Array = []
	for node in get_tree().get_nodes_in_group(DoorGunUnit.GROUP):
		var gun := node as DoorGunUnit
		if gun == null or gun.is_disabled() or not is_hostile_to(gun):
			continue
		if crew_id != ExtractionRules.NO_CREW and ExtractionManager.is_active() \
				and not ExtractionManager.rules.crew_knows(gun.hangar_index, crew_id):
			continue
		out.append(gun)
	return out


## Grid positions of live non-crew hostiles some squadmate can see, minus this
## merc's own target (it is chasing that one, not avoiding it). Sight is each
## member's own light-and-LOS test: the radio shares what the squad SEES, so a
## robot holding still in the dark is not avoided — and that is how a merc
## patrol walks into a sentry.
func _known_hazards() -> Array:
	var out: Array = []
	var mates := _squadmates()
	for other in hostiles():
		if other.faction == Faction.Id.CONTRACTORS or other == target:
			continue
		for mate: MercUnit in mates:
			if mate._can_see(other):
				out.append(other.grid_pos)
				break
	return out


## Whether `other` has found the squad: it is in a fight with a squadmate, or it
## has already landed a hit on one (the confirmed-hit tally on the blackboard).
func _hunting_squad(other: Unit) -> bool:
	var enemy := other as EnemyUnit
	if enemy != null and enemy.alert_state == AlertState.COMBAT:
		var prey := enemy.target as MercUnit
		if prey != null and prey.squad_id == squad_id:
			return true
	if _brain != null and _brain.blackboard != null:
		return float(_brain.blackboard.fact(SquadCoordinator.hit_fact_key(other), 0.0)) > 0.0
	return false


## Tiles from `other` to the nearest live squadmate (this merc included).
func _squad_distance(other: Unit) -> int:
	var best := 999999
	for mate: MercUnit in _squadmates():
		best = mini(best, GridManager.chebyshev_dist(mate.grid_pos, other.grid_pos))
	return best


## The squad's shared intent, for the combat log. Required by the prototype's
## acceptance criteria: with claims invisible, "the squad coordinated" and "the
## draw order happened to be kind" look identical on screen.
func blackboard_summary() -> String:
	return _brain.blackboard.describe() if _brain else "no brain"



# --- The crew's job and its way out (extraction plan Phase 8, GDD §11.10) ------
#
# On an extraction deck every merc squad is a crew (ExtractionManager arms it:
# `crew_id`, and one MercJob shared by the whole squad). The job decides what an
# unaware crew does with its time — loot, or go for the player's own Retrieve
# item — and when it leaves; leaving runs on exactly the player's rules
# (ExtractionRules): find a hangar by walking into it, call from the bay (1 AP,
# loud, positionless radio notice), hold the square, board on landing.
#
# NOT a GOAP goal, though the plan sketched one. The planner only runs in Combat
# against a quarry (`_combat_turn`), and every leg of this — looting, scouting,
# walking to a hangar, waiting for a ship — happens out of combat. So the job is
# an activation-level layer, the same shape as `_idle_turn`'s patrol it
# replaces, and "Extract outranks the rest" is the order of the checks: once the
# crew's ship is down, `take_turn` boards before it fights.
#
# Off an extraction deck (`ExtractionManager.is_active()` false: every legacy
# test deck) none of this runs and a merc patrols and fights exactly as before.

## The crew this merc flies with (ExtractionRules crew ids), or NO_CREW.
var crew_id: int = ExtractionRules.NO_CREW
## The squad's shared job (the same object on every member), or null.
var job: MercJob = null


func _job_active() -> bool:
	return job != null and crew_id != ExtractionRules.NO_CREW \
		and job.phase != MercJob.Phase.DEPARTED and ExtractionManager.is_active()


func _contract_is_retrieve() -> bool:
	var c: Contract = ObjectiveManager.contract
	return c != null and c.type == Contract.Type.RETRIEVE


## Whether a living member of this crew carries the Retrieve item.
func _crew_holds_objective() -> bool:
	if not _contract_is_retrieve():
		return false
	for mate: MercUnit in _squadmates():
		if mate.has_item_code(ObjectiveManager.contract.item_code):
			return true
	return false


## The line a merc puts on the net when the crew decides to leave, by reason.
const LEAVE_LINES := {
	"job done": "That's the job",
	"packs full": "We're full",
	"casualties": "We're bleeding out here",
	"out of time": "Clock's run out",
}


## The leave decision, once per activation: settles the job kind, drops a
## contested item that has gone out of reach, and moves WORKING -> EXTRACTING
## when MercJob says so (job done, packs full, half the crew down, out of time).
func _update_job() -> void:
	job.resolve_kind(_contract_is_retrieve())
	if job.kind == MercJob.Kind.CONTEST and job.is_working() and not _crew_holds_objective() \
			and _contested_source() == null:
		job.abandon_contest()
		action_logged.emit("%s: \"The package is gone. Strip what we can.\"" % stats.display_name)
	var mates := _squadmates()
	var free := 0
	for mate: MercUnit in mates:
		free += mate.free_slots()
	if job.update(TurnManager.turn_number, mates.size(), free, _crew_holds_objective()):
		action_logged.emit("%s: \"%s. Find us a ship.\"" % [stats.display_name,
			LEAVE_LINES.get(job.leave_reason, "Time to go")])


## Where the Retrieve item is when this crew can go and take it: its crate or
## pile, or an uncarried body holding it. Null when it is in somebody's living
## hands (or gone).
func _contested_source() -> Object:
	if not _contract_is_retrieve():
		return null
	var holder = ObjectiveManager.item_holder()
	if holder is LootContainer:
		return holder
	var body := holder as Unit
	if body != null and body.life_state == LifeState.DEAD and body.carried_by == null \
			and body.leaves_body():
		return body
	return null


## The crew's ship is on the pad: board.
func _ship_waiting() -> bool:
	if not job.is_extracting():
		return false
	var index := ExtractionManager.claim_of(crew_id)
	return index >= 0 and ExtractionManager.rules.state_of(index) == ExtractionRules.State.LANDED


## An out-of-combat activation spent on the job (from `_idle_turn`, or from
## `_investigate` while extracting). Looks round again afterwards, like the
## patrol it replaces, so walking into a fight reacts on the spot.
func _job_turn() -> void:
	if job.is_extracting():
		await _extract_leg()
	else:
		await _work_leg()
	if is_downed or TurnManager.mission_over:
		return
	_look_for_targets()
	if alert_state == AlertState.COMBAT:
		await _combat_turn()


## An extracting crew does not walk off to look into a noise: the ship is the
## job now. Everyone else investigates as before (and hears a rival call-in that
## way — its 15-tile noise reaches them by the ordinary hearing rules).
func _investigate() -> void:
	if _job_active() and job.is_extracting():
		await _job_turn()
		return
	await super()


# --- Working: loot, or the contested item --------------------------------------


func _work_leg() -> void:
	_loot_in_reach()
	if ap <= 0 or is_downed:
		return
	var source := _job_source()
	if source == null:
		await _scout()
		return
	var tile: Vector3i = source.loot_tile()
	if within_reach(tile):
		return  # in reach, and nothing more it can take this activation
	var dest := _reach_tile(tile)
	if dest == MercJob.NO_TILE:
		# Boxed in by bodies or other units this activation: drop the pick so the
		# squad does not queue on it, and try another next time.
		job.target_tile = MercJob.NO_TILE
		return
	if await _job_walk(dest, action_cost(UnitStats.Action.LOOT), "heads for %s" % source.loot_name()):
		_loot_in_reach()


## What the crew is working on: the contested item's source, or the squad's
## current container (kept until it is empty, so the squad converges on one
## crate), or the nearest container with something in it in a room the crew has
## been through. Null when there is nothing known to take.
func _job_source() -> Object:
	if job.kind == MercJob.Kind.CONTEST:
		return _contested_source()
	if job.target_tile != MercJob.NO_TILE:
		var current := LootManager.container_at(job.target_tile)
		if current != null and _lootable_for_job(current):
			return current
		job.target_tile = MercJob.NO_TILE
	var map := get_tree().get_first_node_in_group("map")
	if map == null:
		return null
	var best: LootContainer = null
	var best_d := 999999
	for c: LootContainer in LootManager.all_containers():
		if not _lootable_for_job(c):
			continue
		if not job.has_visited(map.data.room_index_at(c.tile)):
			continue
		var d := GridManager.chebyshev_dist(grid_pos, c.tile)
		if d < best_d:
			best_d = d
			best = c
	if best != null:
		job.target_tile = best.tile
	return best


## Whether a container still holds something a LOOT crew wants: anything but the
## player's objective item, which is not theirs to know the worth of.
func _lootable_for_job(c: LootContainer) -> bool:
	for item in c.items:
		if not item.is_objective():
			return true
	return false


## Takes what it can from every source in reach, best first, at the player's
## price (UnitStats LOOT, 1 AP flat per item) into free slots, through the same
## LootManager.take the player's loot action uses. A contesting crew takes the
## objective first; a looting crew leaves it. Each container taken from counts
## once toward the job.
func _loot_in_reach() -> void:
	var cost := action_cost(UnitStats.Action.LOOT)
	while ap >= cost and has_free_slot() and not is_downed:
		var pick := _best_take()
		if pick.is_empty():
			return
		var source: Object = pick["source"]
		var where: String = source.loot_name()
		var tile: Vector3i = source.loot_tile()
		var from_container := source is LootContainer
		var item: ItemData = LootManager.take(source, int(pick["index"]))
		if item == null:
			return
		spend_ap(cost)
		add_item(item)
		if from_container:
			job.record_take(tile)
		action_logged.emit("%s takes %s from %s" % [stats.display_name, item.display_name, where])


## {"source", "index"} of the best item in reach, or {} for none.
func _best_take() -> Dictionary:
	var sources: Array = LootManager.sources_in_reach(self)
	var contest := job.kind == MercJob.Kind.CONTEST and _contract_is_retrieve()
	if contest:
		var body := _contested_source() as Unit
		if body != null and body.loot_blocker(self) == "":
			sources.append(body)
	var best := {}
	var best_value := -1
	for source in sources:
		var items: Array = source.loot_items()
		for i in items.size():
			var item: ItemData = items[i]
			var value := item.value
			if item.is_objective():
				if not contest or item.code != ObjectiveManager.contract.item_code:
					continue
				value = 1 << 30  # the reason the crew came
			if value > best_value:
				best_value = value
				best = {"source": source, "index": i}
	return best


## A free tile from which `tile` (a crate, a pile, a body) is within reach,
## nearest this merc, or NO_TILE. A crate's own tile is impassable; a pile's or
## a body's tile can be stood on.
func _reach_tile(tile: Vector3i) -> Vector3i:
	var best := MercJob.NO_TILE
	var best_d := 999999
	for dz in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			var n: Vector3i = tile + Vector3i(dx, 0, dz)
			var t: GridTileData = GridManager.get_tile(n)
			if t == null or not t.passable:
				continue
			if n != grid_pos and not GridManager.is_free(n):
				continue
			if n != tile and not GridManager.is_melee_adjacent(n, tile):
				continue
			var d := GridManager.chebyshev_dist(grid_pos, n)
			if d < best_d:
				best_d = d
				best = n
	return best


# --- Scouting: rooms the crew has not been through ---------------------------------


## Walks toward the nearest room the crew has not been through — that is how it
## finds both containers and hangars (it knows only what it has walked into,
## GDD §7.2). Shared on the job, so the squad scouts together. With every room
## seen it falls back to the plain map-wide patrol.
func _scout() -> void:
	var dest := _scout_tile()
	if dest == MercJob.NO_TILE:
		if patrols and _brain != null:
			var patrol := _squad_patrol_dest()
			if patrol != grid_pos:
				await _move_to_tile(patrol, false)
		return
	if not await _job_walk(dest, 0, "scouts ahead"):
		# Unreachable from here (sealed, or the way is shut): give up on that room.
		job.visit_room(job.explore_room)


## The tile to walk to for the squad's scouting target, or NO_TILE when there is
## no room left to scout. Picks (and stores on the job) a new room when needed.
func _scout_tile() -> Vector3i:
	var map := get_tree().get_first_node_in_group("map")
	if map == null:
		return MercJob.NO_TILE
	var data: MapData = map.data
	var cells := _room_cells(data)
	if job.explore_room < 0 or job.has_visited(job.explore_room):
		job.explore_room = -1
		var best_d := 999999
		for room: int in cells:
			if job.has_visited(room) or data.corridors.has(room):
				continue
			var d := GridManager.chebyshev_dist(grid_pos, _nearest_cell(cells[room]))
			if d < best_d:
				best_d = d
				job.explore_room = room
	if job.explore_room < 0:
		return MercJob.NO_TILE
	return _nearest_cell(cells[job.explore_room], true)


## Room index -> its walkable tiles, built once per deck and kept on the job
## (static data, so whichever member asks first builds it for the squad).
func _room_cells(data: MapData) -> Dictionary:
	if not job.room_cells.is_empty():
		return job.room_cells
	for pos in data.walkable_positions():
		var room := data.room_index_at(pos)
		if room < 0 or not data.is_passable(pos):
			continue
		if not job.room_cells.has(room):
			job.room_cells[room] = []
		job.room_cells[room].append(pos)
	return job.room_cells


## The tile of `tiles` nearest this merc (Chebyshev); `free_only` skips tiles
## somebody is standing on. NO_TILE if none qualify.
func _nearest_cell(tiles: Array, free_only := false) -> Vector3i:
	var best := MercJob.NO_TILE
	var best_d := 999999
	for pos: Vector3i in tiles:
		if free_only and pos != grid_pos and not GridManager.is_free(pos):
			continue
		if not GridManager.has_tile(pos) or not GridManager.get_tile(pos).passable:
			continue
		var d := GridManager.chebyshev_dist(grid_pos, pos)
		if d < best_d:
			best_d = d
			best = pos
	return best


# --- Extracting: a hangar, the call, the square --------------------------------------


## Out of combat with the job done: get to a hangar the crew knows, call, then
## hold the square until the ship is down (`_board_turn` takes over then).
func _extract_leg() -> void:
	var claim := ExtractionManager.claim_of(crew_id)
	if claim < 0:
		if _try_call():
			claim = ExtractionManager.claim_of(crew_id)
		else:
			var target := _pick_hangar()
			if target < 0:
				await _scout()  # no hangar known and free: keep looking
				return
			job.target_hangar = target
			var h := ExtractionManager.hangar(target)
			var dest := _nearest_cell(h.square, true)
			if dest == MercJob.NO_TILE:
				dest = _nearest_cell(h.bay_cells, true)
			if dest == MercJob.NO_TILE:
				return
			await _job_walk(dest, action_cost(UnitStats.Action.CALL_SHIP),
				"makes for %s" % _hangar_label(target))
			if not is_downed and _try_call():
				claim = ExtractionManager.claim_of(crew_id)
			if claim < 0:
				return
	await _hold_square(claim)


## Calls the crew's ship from where this merc stands, if it can (a bay it knows,
## free, 1 AP). The same ExtractionManager.call_ship the player's button uses, so
## the claim, the 15-tile noise and the radio notice are exactly the player's.
func _try_call() -> bool:
	var cost := action_cost(UnitStats.Action.CALL_SHIP)
	var index := ExtractionManager.callable_hangar_for(self)
	if ap < cost or index < 0:
		return false
	if not ExtractionManager.call_ship(self):
		return false
	spend_ap(cost)
	job.target_hangar = index
	action_logged.emit("%s calls in the crew's ship" % stats.display_name)
	return true


## The hangar the crew should make for: the one it was already heading to if it
## can still be called, else the nearest one it knows that can be. -1 if none.
func _pick_hangar() -> int:
	var rules: ExtractionRules = ExtractionManager.rules
	if job.target_hangar >= 0 and rules.can_call(job.target_hangar, crew_id):
		return job.target_hangar
	var best := -1
	var best_d := 999999
	for i in rules.known_hangars(crew_id):
		if not rules.can_call(i, crew_id):
			continue
		var d := GridManager.chebyshev_dist(grid_pos, ExtractionManager.hangar(i).pad_center)
		if d < best_d:
			best_d = d
			best = i
	return best


## Into the square of the crew's claimed hangar (or stay there), and signal
## dust-off when the crew is aboard.
func _hold_square(index: int) -> void:
	if index < 0:
		return
	var h := ExtractionManager.hangar(index)
	if not h.in_square(grid_pos):
		var dest := _nearest_cell(h.square, true)
		if dest != MercJob.NO_TILE:
			await _job_walk(dest, 0, "takes the landing square at %s" % _hangar_label(index))
	if not is_downed and h.in_square(grid_pos) \
			and ExtractionManager.rules.state_of(index) == ExtractionRules.State.LANDED:
		_maybe_dust_off(index)


## The crew's ship is down: into the square, dust-off if the crew is aboard,
## then fire from where it stands with what is left — never stepping back out
## to chase. Overrides the whole activation, Combat included (`take_turn`).
func _board_turn() -> void:
	_look_for_targets()
	if alert_state == AlertState.COMBAT:
		_check_contact()
	await _hold_square(ExtractionManager.claim_of(crew_id))
	if is_downed or TurnManager.mission_over:
		return
	var shoot_cost := action_cost(UnitStats.Action.SHOOT)
	var reload_cost := action_cost(UnitStats.Action.RELOAD)
	while ap > 0 and not is_downed and alert_state == AlertState.COMBAT:
		var quarry := acquire_target()
		if quarry == null or quarry.is_downed \
				or GridManager.chebyshev_dist(grid_pos, quarry.grid_pos) > ATTACK_RANGE \
				or not GridManager.has_line_of_sight(self, quarry):
			return
		if not can_shoot():
			if ap < reload_cost:
				return
			spend_ap(reload_cost)
			await do_reload()
			action_logged.emit("%s reloaded" % stats.display_name)
			continue
		var was := quarry.life_state
		if not await _take_best_shot(quarry, shoot_cost):
			return
		_log_casualty(quarry, was)


## Signals dust-off (0 AP, like the player's) when MercJob.should_dust_off says
## the crew is aboard enough.
func _maybe_dust_off(index: int) -> void:
	var rules: ExtractionRules = ExtractionManager.rules
	if rules.dust_off_blocker(grid_pos, crew_id) != "":
		return
	var h := ExtractionManager.hangar(index)
	var mates := _squadmates()
	var aboard := 0
	for mate: MercUnit in mates:
		if h.in_square(mate.grid_pos):
			aboard += 1
	var landed_round: int = rules.states[index].depart_by_round - ExtractionRules.LANDED_ROUNDS
	if MercJob.should_dust_off(aboard, mates.size(), TurnManager.turn_number - landed_round):
		if ExtractionManager.request_dust_off(self):
			action_logged.emit("%s signals dust-off (%d of %d aboard)" % [
				stats.display_name, aboard, mates.size()])


## Where the job is taking this merc right now, without changing anything: the
## approach tile of its source, the scouting room, the hangar square. NO_TILE for
## nowhere in particular. Read by `_intended_route` (what "blocks the job").
func _job_destination() -> Vector3i:
	if job.is_extracting():
		var index := ExtractionManager.claim_of(crew_id)
		if index < 0:
			index = job.target_hangar
		if index >= 0 and ExtractionManager.rules.is_valid(index):
			var h := ExtractionManager.hangar(index)
			return grid_pos if h.in_square(grid_pos) else _nearest_cell(h.square, true)
		return MercJob.NO_TILE
	var tile := job.target_tile
	if job.kind == MercJob.Kind.CONTEST:
		var source := _contested_source()
		if source != null:
			tile = source.loot_tile()
	if tile != MercJob.NO_TILE:
		return grid_pos if within_reach(tile) else _reach_tile(tile)
	if job.explore_room >= 0 and job.room_cells.has(job.explore_room):
		return _nearest_cell(job.room_cells[job.explore_room], true)
	return MercJob.NO_TILE


## Walks toward `dest` on the merc's own routing (around seen third parties and
## hostile door guns), as far as this activation's AP goes, holding back
## `reserve_ap` for what it means to do on arrival when it can. Free tiles only:
## unlike a chase, a job never ends on somebody else's tile. True if it moved.
func _job_walk(dest: Vector3i, reserve_ap: int, why: String) -> bool:
	if dest == grid_pos or dest == MercJob.NO_TILE:
		return false
	var path := _route_path(dest, false)
	if path.is_empty():
		return false
	var budget := _move_budget(reserve_ap)
	if budget < 1:
		return false
	var walked: Array[Vector3i] = path.slice(0, mini(budget, path.size()))
	spend_ap(move_cost_for(walked.size()))
	await move_along(walked)
	action_logged.emit("%s %s (%s)" % [stats.display_name, why, grid_pos])
	return true


## Leaves the board aboard the crew's ship (ExtractionManager, every peer). Like
## DoorGunUnit.retire: out of every group first, so the next pool snapshot and
## every group scan stop seeing it at once, off the pool and its tile, then
## freed. Its pack goes with it — that loot is off the deck.
func board_ship() -> void:
	if _brain != null and _brain.blackboard != null:
		_brain.blackboard.release_all(self)
	remove_from_group("units")
	remove_from_group("enemy_units")
	TurnManager.pool.erase(self)
	if TurnManager.active_unit == self:
		TurnManager.active_unit = null
	var tile: GridTileData = GridManager.get_tile(grid_pos)
	if tile and tile.occupant == self:
		GridManager.set_occupant(grid_pos, null)
	flashlight_on = false
	visible = false
	queue_free()
	LightingManager.recompute_dynamic()


## A hangar as a merc's log line names it: by name only once the player has
## discovered it, so the combat log never gives away an unfound hangar (GDD §7.3).
func _hangar_label(index: int) -> String:
	if ExtractionManager.rules.is_discovered(index):
		return ExtractionManager.hangar_name(index)
	return "a hangar"
