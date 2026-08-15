class_name EnemyUnit
extends Unit
## Base alien (the `AlienUnit` of Sec 11.8): the awareness state machine, plus
## the iteration-1 ranged combat behavior. Per-type behavior lives in subclasses
## overriding `_combat_turn` and `_move_budget` — see SwarmUnit.
##
## States (Sec 11.1, minus the deferred Search):
##   UNAWARE — rests at its nest. Sees nothing, does nothing when drawn.
##   ALERT   — has a stimulus but no confirmed target; walks to `last_known_pos`,
##             and reverts once it arrives with nothing to show for it.
##   COMBAT  — has a confirmed target and fights it, until the target dies or it
##             loses contact for `lose_contact_turns` activations.
##
## Two independent channels feed those transitions, both light-based (the Sec 5.4
## sound channel is deferred):
##   - Sight: a player in range, in LOS, standing somewhere lit enough to be made
##     out. Uses total light — an alien can see you under an overhead fixture.
##   - A beam landing on the alien itself. Uses the flashlight-only layer, so
##     static fixtures never trip it; see LightingManager._dynamic.

signal action_logged(text: String)
signal state_changed(unit: EnemyUnit)

enum AlertState { UNAWARE, ALERT, COMBAT }

const ATTACK_RANGE := 8  # tiles (Chebyshev)

const STATE_GLYPH := {
	AlertState.UNAWARE: "",
	AlertState.ALERT: " ?",
	AlertState.COMBAT: " !",
}
const STATE_COLOR := {
	AlertState.UNAWARE: Color(0.72, 0.72, 0.75),
	AlertState.ALERT: Color(1.0, 0.75, 0.2),
	AlertState.COMBAT: Color(1.0, 0.32, 0.26),
}

## How far this alien notices anything at all, by any channel (Sec 11.2).
@export var detection_range: int = 8
## A player on a tile at least this lit can be made out at range — the symmetric
## counterpart of the accuracy light modifier (Sec 5.1). Below it they're just a
## shape in the dark, and moving with the flashlight off is worth doing.
@export var sight_light_threshold: float = 25.0
## Flashlight-layer light on this alien's OWN tile meaning "a beam is on me". At
## or above `aggro` it goes straight for whoever holds the beam; at or above
## `alert` — the dim outskirts of a cone — it only stirs.
@export var beam_aggro_threshold: float = 40.0
@export var beam_alert_threshold: float = 10.0
## Radius a unit entering Combat rouses its neighbours across.
@export var alert_propagation_range: int = 6
## Activations without sight of the target before it gives up and falls back to
## investigating. This is what lets a squad break contact by killing the lights.
@export var lose_contact_turns: int = 2

var alert_state: AlertState = AlertState.UNAWARE
var target: Unit = null  # confirmed; COMBAT only
var last_known_pos: Vector3i  # where ALERT walks to

var _has_last_known: bool = false
var _turns_without_contact: int = 0


func _init() -> void:
	# The alien tier's own side. Subclasses on another faction override this in
	# their own `_init` — GDScript runs the base constructor first, so setting it
	# here is a default rather than a decision imposed on them (CerberusUnit).
	faction = Faction.Id.ALIENS
	has_flashlight = false  # aliens rely on their own senses, not a rig light


func _ready() -> void:
	super()
	# Fires on every dynamic recompute, which includes once per tile mid-walk —
	# so a beam swept across a room as a unit moves genuinely wakes what it
	# crosses, rather than only what it happens to end up pointing at.
	LightingManager.lighting_changed.connect(_on_lighting_changed)
	_refresh_label()


func report_action(text: String) -> void:
	action_logged.emit(text)


## Which compartment this unit is standing in right now, or -1 when the deck has
## no room graph or the unit is outside it.
##
## Asked PER CALL rather than cached at spawn, unlike the robots' `security_zone`.
## A machine holds a post and answers to one place for the whole mission; an
## alien wanders, and an alert it raises belongs to the room it is in when it
## raises it.
func _room_here() -> int:
	var map := get_tree().get_first_node_in_group("map")
	return map.room_at(grid_pos) if map else -1


func take_turn() -> void:
	# Coroutine — moves are animated, so TurnManager must `await` this before
	# drawing the next unit from the pool.
	_look_for_targets()
	if alert_state == AlertState.COMBAT:
		_check_contact()
	match alert_state:
		AlertState.COMBAT:
			await _combat_turn()
		AlertState.ALERT:
			await _investigate()
		_:
			pass  # UNAWARE rests at its nest (Sec 11.1) — drawn, but does nothing


## Chance to pay the Aimed Shot premium instead of taking a cheaper snap shot,
## when there's AP to spare for it. Keeps aliens from *always* eating the AP
## cost just because they can — a wounded/AP-starved one still snap-shoots.
const AIMED_SHOT_CHANCE := 0.6
const HEADSHOT_ACCURACY_THRESHOLD := 50  # only tempted by the head when odds are good
const HEADSHOT_CHANCE := 0.35
const LEG_TARGET_CHANCE := 0.4  # vs. a quarry still able to disengage


func _combat_turn() -> void:
	# The ranged loop. Overridden wholesale by melee types (SwarmUnit).
	var shoot_cost := action_cost(UnitStats.Action.SHOOT)
	var reload_cost := action_cost(UnitStats.Action.RELOAD)
	while ap > 0 and not is_downed:
		var quarry := acquire_target()
		if quarry == null:
			return
		var in_range := GridManager.chebyshev_dist(grid_pos, quarry.grid_pos) <= ATTACK_RANGE
		if in_range and GridManager.has_line_of_sight(self, quarry) and can_shoot():
			# Affordability is checked BEFORE the coin flip and the loop bails when
			# nothing is affordable, which the old flat 1/2 AP costs never needed:
			# a snap shot can now cost more than a whole small pool, and without the
			# bail an alien that cannot pay for anything spins here forever.
			if not await _take_best_shot(quarry, shoot_cost):
				ap = 0
				return
			if quarry.is_downed:
				action_logged.emit("%s is DOWN!" % quarry.stats.display_name)
		elif not can_shoot():
			if ap < reload_cost:
				ap = 0
				return
			spend_ap(reload_cost)
			await do_reload()
			action_logged.emit("%s reloaded" % stats.display_name)
		else:
			# Holds back the price of a snap shot where doing so still leaves a
			# step to take. Movement used to be a flat 1 AP whatever the distance,
			# so closing and firing in one activation was automatic; at 1 AP per
			# TILE an alien that walks its whole pool can never shoot, and the
			# ranged tier would quietly stop being a ranged tier.
			await _move_toward(quarry, shoot_cost)


## Fires the best shot this unit can currently afford at `quarry`. Returns false
## when it can afford none, which is the caller's signal to end the activation.
## Chance a unit that CAN suppress chooses to, over shooting. Low, because the
## base AI has no squad to exploit the pin — suppression pays off when an ally
## uses the window, and that reasoning belongs to the GOAP planner, not here.
## Non-zero so the mechanic is exercised by the ordinary roster rather than only
## by the factions that plan.
const SUPPRESS_CHANCE := 0.2


func _take_best_shot(quarry: Unit, shoot_cost: int) -> bool:
	var suppress_cost := action_cost(UnitStats.Action.SUPPRESS)
	# Never re-pins a unit already pinned by somebody: the accuracy and AP
	# penalties do not stack, so the second burst buys nothing at all.
	if ap >= suppress_cost and can_suppress() and not quarry.is_suppressed() \
			and randf() < SUPPRESS_CHANCE:
		await do_suppress(quarry)
		action_logged.emit("%s lays down suppressing fire on %s" % [
			stats.display_name, quarry.stats.display_name])
		return true
	# Qualified on the CHEAPEST zone, so the roll happens on the same terms the
	# player's Aimed Shot button is gated by.
	if ap >= min_aimed_shot_cost() and randf() < AIMED_SHOT_CHANCE:
		var part := _choose_aimed_part(quarry)
		# The zone it picked may cost more than the one it qualified on — Sec 4.3a
		# prices the head two AP above the torso. Fall back to the torso rather
		# than abandoning an aimed shot it has already committed to.
		if ap < aimed_shot_cost(part):
			part = Combat.BodyPart.TORSO
		await _take_aimed_shot(quarry, part)
		return true
	if ap < shoot_cost:
		return false
	spend_ap(shoot_cost)
	var result: Combat.ShotResult = await fire_at(quarry, Combat.ShotAction.SHOOT)
	action_logged.emit("%s fired at %s (%d%% acc): %s" % [stats.display_name, quarry.stats.display_name, result.accuracy, Combat.describe(result)])
	return true


func _take_aimed_shot(quarry: Unit, part: int) -> void:
	spend_ap(aimed_shot_cost(part))
	var result: Combat.ShotResult = await fire_at(quarry, Combat.ShotAction.AIMED_SHOT, part)
	action_logged.emit("%s aims at %s's %s (%d%% acc): %s" % [
		stats.display_name, quarry.stats.display_name, Combat.body_part_name(part), result.accuracy, Combat.describe(result),
	])
	if result.newly_injured:
		action_logged.emit("%s's %s is INJURED!" % [quarry.stats.display_name, Combat.body_part_name(part)])
	if result.stunned:
		action_logged.emit("%s is STUNNED!" % quarry.stats.display_name)


func _choose_aimed_part(quarry: Unit) -> int:
	# Simple heuristic, not full tactical reasoning (Sec 4.2): favour the head
	# when the odds are actually good enough to be worth the crit-fishing, favour
	# legs to pin down a quarry that isn't already adjacent (i.e. could still
	# disengage), and default to the torso's reliable accuracy otherwise.
	var head_acc := Combat.compute_accuracy(self, quarry, Combat.ShotAction.AIMED_SHOT, Combat.BodyPart.HEAD)
	if head_acc >= HEADSHOT_ACCURACY_THRESHOLD and randf() < HEADSHOT_CHANCE:
		return Combat.BodyPart.HEAD
	# is_melee_adjacent, not chebyshev_dist <= 1. The two agree on flat open
	# ground now that movement is eight-way, but not through a wall and not
	# between floors: chebyshev_dist ignores both, and would call a quarry one
	# deck up "adjacent" and skip the leg shot on someone who can walk away
	# freely.
	var not_adjacent := not GridManager.is_melee_adjacent(grid_pos, quarry.grid_pos)
	var legs_intact := not (quarry.is_part_injured(Combat.BodyPart.LEG_L) and quarry.is_part_injured(Combat.BodyPart.LEG_R))
	if not_adjacent and legs_intact and randf() < LEG_TARGET_CHANCE:
		return Combat.BodyPart.LEG_L if randf() < 0.5 else Combat.BodyPart.LEG_R
	return Combat.BodyPart.TORSO


func _investigate() -> void:
	# Walk to the stimulus. Arriving with nothing there drops it back to UNAWARE:
	# the Search state that would sweep the area first (Sec 11.1) is deferred, so
	# this is one trip, not a hunt. It can still spot something on the way in.
	while ap > 0 and not is_downed:
		if not _has_last_known or grid_pos == last_known_pos:
			_give_up()
			return
		var path := GridManager.find_path(grid_pos, last_known_pos, 999)
		if path.is_empty():
			_give_up()  # blocked, or something is standing on the spot
			return
		var budget := _move_budget()
		if budget < 1:
			ap = 0  # cannot afford a single tile — stop rather than spin
			return
		var walked := path.slice(0, mini(budget, path.size()))
		spend_ap(move_cost_for(walked.size()))
		await move_along(walked)
		action_logged.emit("%s moves to investigate %s" % [stats.display_name, grid_pos])
		_look_for_targets()
		if alert_state == AlertState.COMBAT:
			await _combat_turn()
			return


func acquire_target() -> Unit:
	## The only place any alien AI gets a target from. In COMBAT that's the unit
	## it confirmed; in any other state it has none, and the null return ends the
	## activation — which is what an Unaware alien idling at its nest should do.
	if alert_state != AlertState.COMBAT:
		return null
	if target == null or target.is_downed:
		_lose_target()
		return null
	last_known_pos = target.grid_pos
	_has_last_known = true
	return target


func _can_see(unit: Unit) -> bool:
	# Sight is gated on light, not just geometry (Sec 5.1). Total light_value is
	# the right reading here — being lit by an overhead fixture gives you away
	# exactly as much as being lit by your own flashlight does.
	if unit == null or unit.is_downed:
		return false
	if GridManager.chebyshev_dist(grid_pos, unit.grid_pos) > detection_range:
		return false
	var t: GridTileData = GridManager.get_tile(unit.grid_pos)
	if t == null or t.light_value < sight_light_threshold:
		return false
	return GridManager.has_line_of_sight(self, unit)


func _look_for_targets() -> void:
	# Skipped while already locked on — an alien in a fight doesn't shop around.
	if alert_state == AlertState.COMBAT and target != null and not target.is_downed:
		return
	var best: Unit = null
	var best_dist := 999999
	# Everything this unit would engage, rather than the `player_units` group it
	# used to scan. Identical today — aliens and robots are hostile only to the
	# contractors — but it is now a question about sides instead of an assumption
	# that the player is the only other side there is.
	for unit in hostiles():
		var d := GridManager.chebyshev_dist(grid_pos, unit.grid_pos)
		if d >= best_dist or not _can_see(unit):
			continue
		best_dist = d
		best = unit
	if best:
		_enter_combat(best, "%s spotted %s!" % [stats.display_name, best.stats.display_name])


func _check_contact() -> void:
	# Run once per activation while in COMBAT. Losing sight — by breaking LOS or
	# by the target going dark — eventually breaks the lock, which is the other
	# half of making the flashlight a decision rather than a free upgrade.
	if _can_see(target):
		_turns_without_contact = 0
		return
	_turns_without_contact += 1
	if _turns_without_contact >= lose_contact_turns:
		_lose_target()


func _on_lighting_changed() -> void:
	# State changes only. An alien never *acts* outside its own activation — that
	# interrupt is overwatch's job alone (TurnManager.check_overwatch).
	if is_downed or alert_state == AlertState.COMBAT:
		return
	var lit := LightingManager.flashlight_value(grid_pos)
	if lit < beam_alert_threshold:
		return
	var holder := LightingManager.flashlight_source(grid_pos)
	if holder == null or holder.is_downed:
		return
	# The beam has to belong to somebody this unit would actually fight.
	#
	# Free for the aliens, who carry no light at all (`has_flashlight = false`
	# below), and that is exactly why the check was missing: for as long as every
	# unit with this state machine was unlit, the only beam that could ever land
	# on one belonged to the player. The rival mercs broke that — they are human,
	# they carry torches, and their own torch lights their own tile. Without this
	# guard a merc reads its own beam as an intruder's, enters Combat against
	# itself and opens fire on itself; a squadmate's beam does the same.
	if not is_hostile_to(holder):
		return
	if lit >= beam_aggro_threshold:
		_enter_combat(holder, "%s is caught in %s's light!" % [stats.display_name, holder.stats.display_name])
	elif alert_state == AlertState.UNAWARE:
		rouse(holder.grid_pos)
		action_logged.emit("%s stirs — something moved at the edge of the light" % stats.display_name)


## Sound (Sec 5.4) — the one detection channel every faction shares, and the only
## one that needs neither light nor line of sight. Deliberately identical in
## shape to `CerberusUnit.hear_noise`, which used to be the only implementation:
## a robot hears gunfire because its microphones do not care about the dark, and
## an alien hears it for the more obvious reason.
##
## Sited on `EnemyUnit` rather than on the robot subclass so that every unit with
## an awareness state machine gets it — which is what makes "stay quiet" a plan
## against the whole board rather than against one faction.
func hear_noise(at: Vector3i) -> void:
	if is_downed or alert_state == AlertState.COMBAT:
		return
	var was := alert_state
	rouse(at)
	if alert_state != was:
		action_logged.emit("%s hears something at %s" % [stats.display_name, at])


func rouse(at: Vector3i) -> void:
	# Nudged by a neighbour's alert, or any stimulus short of a confirmed sighting.
	if is_downed or alert_state != AlertState.UNAWARE:
		return
	last_known_pos = at
	_has_last_known = true
	_set_state(AlertState.ALERT)


func _enter_combat(new_target: Unit, reason: String) -> void:
	var was := alert_state
	target = new_target
	last_known_pos = new_target.grid_pos
	_has_last_known = true
	_turns_without_contact = 0
	_set_state(AlertState.COMBAT)
	if was != AlertState.COMBAT:
		action_logged.emit(reason)
		_propagate_alert()


func _lose_target() -> void:
	if target != null:
		last_known_pos = target.grid_pos
		_has_last_known = true
	action_logged.emit("%s loses track of its target" % stats.display_name)
	_set_state(AlertState.ALERT)
	_turns_without_contact = 0


## Drops back to UNAWARE without the "finds nothing" narration. Used by the
## hivemind's de-escalation sweep (Sec 6), which settles a whole deck at once —
## one line per alien would bury the log under a paragraph nobody reads.
func settle() -> void:
	if is_downed or alert_state == AlertState.COMBAT:
		return
	_has_last_known = false
	_set_state(AlertState.UNAWARE)


func _give_up() -> void:
	_has_last_known = false
	_set_state(AlertState.UNAWARE)
	action_logged.emit("%s finds nothing and settles" % stats.display_name)


func _propagate_alert() -> void:
	# Sec 11.2: alerts are local, never ship-wide. Neighbours are only roused,
	# never handed the target: they heard something kick off, they didn't see who.
	#
	# SCOPED BY COMPARTMENT, not by radius. The design always said room/nest
	# cluster; the radius was a stopgap from when the room graph did not exist.
	# It does now (`MapData.compute_rooms`, read through `MapBuilder.room_at`),
	# and the difference is not cosmetic — a radius leaks straight through
	# bulkheads, so "isolating rooms via doors is a valid, intentional player
	# strategy" was not actually true while an alert could pass through a wall.
	#
	# Falls back to the radius when either unit is in no compartment at all,
	# which is the honest answer for a unit standing somewhere the graph does not
	# describe rather than a silent failure to alert anybody.
	var here := _room_here()
	for node in get_tree().get_nodes_in_group("enemy_units"):
		var other := node as EnemyUnit
		if other == null or other == self:
			continue
		# Same side only. The `enemy_units` group holds the security robots too,
		# so without this an alien's scream rouses a machine that is not on its
		# side — invisible while everything hostile was lumped together as "not
		# the player", and plainly wrong once the factions have names.
		if other.faction != faction:
			continue
		var there := other._room_here()
		var reached := here >= 0 and there >= 0 and here == there
		if not reached and (here < 0 or there < 0):
			reached = GridManager.chebyshev_dist(grid_pos, other.grid_pos) <= alert_propagation_range
		if reached:
			other.rouse(last_known_pos)


func _set_state(new_state: AlertState) -> void:
	if alert_state == new_state:
		return
	var was := alert_state
	alert_state = new_state
	if new_state != AlertState.COMBAT:
		target = null
	# Waking up is the one awareness change with a performance behind it. Fired
	# on leaving UNAWARE by either channel — spotting a player, or catching a
	# beam — because both mean "it has noticed", which is what the player needs
	# to read. ALERT -> COMBAT deliberately does NOT re-fire: that is the same
	# creature narrowing down a stimulus it is already reacting to, and screaming
	# twice over one contact reads as a bug rather than as escalation.
	#
	# Deliberately NOT awaited, like the DOWNED collapse. This is reached from
	# _on_lighting_changed as well as from the unit's own activation, and that
	# callback runs once per tile in the MIDDLE of a player unit's walk — holding
	# it would freeze the player halfway down a corridor for the length of a
	# scream. Nothing downstream depends on the clip finishing.
	if was == AlertState.UNAWARE and new_state != AlertState.UNAWARE:
		visual.play_action(UnitVisual.ALERT_SCREAM)
	_refresh_label()
	state_changed.emit(self)


func _refresh_label() -> void:
	# The player's only read on any of this, so it has to survive being glanced
	# at from XCOM camera distance: a colour and one character.
	if _name_label == null:
		return
	_name_label.text = stats.display_name + STATE_GLYPH[alert_state]
	_name_label.modulate = STATE_COLOR[alert_state]


## Tiles this unit walks in one move step, and the per-type override point (Sec
## 11.8). No longer "tiles per 1 AP": movement is 1 AP per tile for everyone
## (rework doc Sec 4.1), so pace is a property of the AP POOL — a type that
## should crawl is given a small Fitness value (Sec 4.5), not a private rate.
##
## `reserve_ap` is what the caller wants left over for the action it intends to
## take afterwards. Held back only when doing so still leaves at least one tile
## to walk; a unit that cannot both move and act spends everything on moving,
## which is the right answer for something out of range of anything.
func _move_budget(reserve_ap: int = 0) -> int:
	var spendable := ap - reserve_ap
	if spendable < move_ap_per_tile():
		spendable = ap
	return spendable / move_ap_per_tile()


func _move_toward(unit: Unit, reserve_ap: int = 0) -> void:
	await _move_to_tile(unit.grid_pos, true, reserve_ap)


func _move_to_tile(dest: Vector3i, stop_short: bool, reserve_ap: int = 0) -> void:
	# Path all the way to `dest` (allowed occupied), then walk the first
	# _move_budget() steps of it — routes around walls instead of greedy
	# straight-line chasing. `stop_short` drops the final tile, for closing on a
	# unit rather than onto it.
	var full_path := GridManager.find_path(grid_pos, dest, 999, true)
	if stop_short and not full_path.is_empty():
		full_path.resize(full_path.size() - 1)  # never step onto the target itself
	var budget := _move_budget(reserve_ap)
	if full_path.is_empty() or budget < 1:
		ap = 0  # adjacent already, fully blocked, or a tile is unaffordable
		return
	var path := full_path.slice(0, mini(budget, full_path.size()))
	spend_ap(move_cost_for(path.size()))
	await move_along(path)
	action_logged.emit("%s moved to %s" % [stats.display_name, path[-1]])
