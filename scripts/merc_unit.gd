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


## The squad's shared intent, for the combat log. Required by the prototype's
## acceptance criteria: with claims invisible, "the squad coordinated" and "the
## draw order happened to be kind" look identical on screen.
func blackboard_summary() -> String:
	return _brain.blackboard.describe() if _brain else "no brain"
