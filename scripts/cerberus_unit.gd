class_name CerberusUnit
extends EnemyUnit
## Base security robot — the `CerberusUnit` of
## docs/design/factions/security-robots/. Alpha implementation: everything below
## is the design doc's v1 proposal expressed in the systems that already exist,
## with the numbers held as exports so they are tunable rather than argued about.
##
## It extends `EnemyUnit` rather than `Unit` on purpose. The awareness state
## machine (UNAWARE/ALERT/COMBAT), the ranged combat loop and the target
## bookkeeping are all faction-neutral, and the faction's own doc says to reuse
## them. What Cerberus changes is exactly four things:
##
##   1. **Light does not exist.** Not to its sensors, and not to shots fired at
##      it. `_can_see` reads MOTION instead, and `Combat` drops the light term for
##      any roll involving one of these. Turning the flashlight off is the
##      player's answer to the aliens; against a robot it buys nothing.
##   2. **Alerts go over the network**, to a whole zone at once, rather than to
##      whatever happened to be standing nearby. See SecurityNetwork.
##   3. **Armor**, a flat reduction applied where damage lands — under the cover
##      system, not instead of it — with EMP as the lever that switches it off.
##   4. **No injury state.** A robot at 0 HP is destroyed and drops Salvage;
##      there is no downed-and-recoverable middle for something that was never on
##      the player's side.
##
## UNAWARE is read as **Standing Post** for this faction: the same slot in the
## state machine, but a robot that finds nothing walks back to its assigned
## position instead of settling wherever the search ended. That is the whole
## behavioural difference, and it is what makes bypassing one a real option.

## Status-light colour by state (faction-identity.md). The player cannot read a
## machine's posture off its body language the way they can an alien's, so the
## light is the diegetic substitute — and it stays legible in the dark, because
## UnitVisual deliberately does not dim this layer with the tile's light value.
const STATUS_COLOR := {
	AlertState.UNAWARE: Color(0.25, 1.0, 0.45),  # standing post — green
	AlertState.ALERT: Color(1.0, 0.72, 0.12),  # amber
	AlertState.COMBAT: Color(1.0, 0.18, 0.14),  # red
}
## Shown instead while EMP has it down: the one state where the light says
## "this thing is not currently a threat", which is the window the player bought.
const STATUS_COLOR_DISABLED := Color(0.25, 0.5, 1.0)

## Damage that gets through no matter how thick the plate. Without a floor, a
## weapon whose damage is at or below a unit's Armor does literally nothing, and
## an SMG stops being a weapon rather than becoming a poor choice.
const MIN_DAMAGE_THROUGH_ARMOR := 1

## Turns a target is still considered "moving" after its last move. Motion
## detection needs a memory or it would only ever fire on the exact activation a
## unit walked, which no robot would ever be drawn in time to catch.
const MOTION_MEMORY_TURNS := 1

## Flat damage reduction (armor-and-destruction.md). Applied AFTER the accuracy
## roll succeeds, at the point damage is dealt — so it neither stacks with nor
## replaces the Cover/Elevation/Light terms in the Sec 6.5 formula. Cover decides
## whether the shot lands; Armor decides how much it hurt.
@export var armor_value: int = 0

## How far this unit can make out a target that just MOVED, versus one holding
## still. Sensors read movement, not lit-vs-dark appearance, so a squad that
## stops is genuinely harder to pick up than one that sprints past — which is the
## robot-facing equivalent of the flashlight decision, and the only stealth lever
## that still works against this faction.
@export var motionless_detection_range: int = 4

## True for a unit that defends a place rather than a direction — it returns to
## its post and will not chase beyond `post_leash`.
@export var holds_position: bool = false
## Tiles from its post it is willing to be pulled. Ignored when `holds_position`
## is false.
@export var post_leash: int = 3

## Which SecurityZone this unit answers to. Assigned at spawn from the deck's
## compartment graph (see MapBuilder.zone_at); an authored level may set it by
## hand, and SecurityNetwork.NO_ZONE means "on nobody's network".
@export var security_zone: int = -1

## Dropped on destruction. Deliberately a flat per-unit number in the alpha —
## what Salvage BUYS is unspecified until the between-missions economy exists.
@export var salvage_value: int = 1

## Scales an incoming EMP's duration. 1.0 for the roster; Securus is the one
## unit that takes less, which is its "elite" tell rather than a bigger HP bar.
@export var emp_stun_duration_mult: float = 1.0

## Set true only by Proctor. Kept here rather than on the subclass because the
## shared combat loop is the thing that has to check it.
@export var avoids_combat: bool = false

## Hovering: terrain movement cost does not apply. No terrain currently costs
## more than one tile, so this changes nothing today — it is declared here so the
## unit that owns the behaviour owns the flag, and adding hazard tiles later is a
## change to the pathfinder rather than to the roster.
@export var ignores_terrain_move_cost: bool = false

## Where this unit stands when it has nothing to react to. Captured at spawn.
var post_pos: Vector3i
## Activations still lost to an EMP hit. While above zero the unit does nothing
## on its draw AND its Armor reads zero, which is the whole point of the window.
var emp_turns: int = 0

var _priority_call: bool = false  # this alert came from a Proctor's call-in


func _ready() -> void:
	super()
	add_to_group("cerberus_units")
	post_pos = grid_pos
	downed.connect(_on_destroyed)
	_refresh_status_light()


# --- What makes it a machine -------------------------------------------------


## No light term in any accuracy roll involving this unit, in either direction
## (detection-and-network-alert.md). Read by Combat.compute_accuracy.
##
## Symmetric on purpose. The doc specifies the `Unit vs CerberusUnit` half; the
## other half falls out of the same sentence — a sensor package that cannot be
## blinded cannot be blinded when it is the one shooting either. Making it
## one-directional would let a player hide in the dark from a machine that
## demonstrably does not see that way.
func light_agnostic() -> bool:
	return true


## Motion + line of sight. No light gate at all, which is the single line that
## separates this faction's detection from the aliens'.
func _can_see(unit: Unit) -> bool:
	if unit == null or unit.is_downed:
		return false
	var moving := TurnManager.turn_number - unit.last_moved_turn <= MOTION_MEMORY_TURNS
	var reach := detection_range if moving else motionless_detection_range
	if GridManager.chebyshev_dist(grid_pos, unit.grid_pos) > reach:
		return false
	return GridManager.has_line_of_sight(self, unit)


## A beam landing on a robot means nothing to it. Overridden to a no-op rather
## than left inherited, because the base version would otherwise have a torch
## sweep across a corridor waking every machine in it — the exact tactic the
## faction exists to invalidate.
func _on_lighting_changed() -> void:
	pass


## Zone-wide, over the network, instead of the aliens' local radius rouse.
func _propagate_alert() -> void:
	var reached := SecurityNetwork.broadcast(security_zone, last_known_pos, false, self)
	if reached > 0:
		action_logged.emit("%s broadcasts an intrusion alert — %d unit(s) in zone %d respond" % [
			stats.display_name, reached, security_zone,
		])


## Called by SecurityNetwork on every unit in the alerted zone. Returns whether
## the broadcast actually did something to this unit, so the broadcaster reports
## a real count rather than the size of the zone.
##
## "Did something" is deliberately broader than "woke it up": redirecting three
## units that were already converging on a stale position is as much a use of the
## network as waking three that were standing idle, and a count that ignored it
## would say nothing happened during exactly the fights where the network matters
## most.
func receive_broadcast(at: Vector3i, priority: bool) -> bool:
	if is_downed or alert_state == AlertState.COMBAT:
		return false
	_priority_call = _priority_call or priority
	var was := alert_state
	rouse(at)
	if alert_state != was:
		return true
	# Already investigating something else: a fresh broadcast still redirects it,
	# because the network's newest report is better information than a stale one.
	if alert_state == AlertState.ALERT and last_known_pos != at:
		last_known_pos = at
		_has_last_known = true
		return true
	return false


## Sound (Sec 5.4). The one channel the two factions share — deliberately, so
## "stay quiet" stays a universally useful plan instead of a counter to exactly
## one enemy type. Unlike sight it needs no line of sight and no light.
func hear_noise(at: Vector3i) -> void:
	if is_downed or alert_state == AlertState.COMBAT:
		return
	var was := alert_state
	rouse(at)
	if alert_state != was:
		action_logged.emit("%s picks up gunfire at %s" % [stats.display_name, at])


# --- Armor, EMP and destruction ----------------------------------------------


## Zero while EMP has it down — that suppression IS the payoff for the grenade,
## and it is what makes "EMP, then dump a magazine into it" the intended answer
## to the tanky half of the roster.
func effective_armor() -> int:
	return 0 if emp_turns > 0 else armor_value


func damage_taken(amount: int) -> int:
	if amount <= 0:
		return 0
	return maxi(MIN_DAMAGE_THROUGH_ARMOR, amount - effective_armor())


## Applies an EMP hit. `turns` is the roster default; this unit's own
## `emp_stun_duration_mult` decides what it actually gets, floored at one
## activation so the grenade is never a total no-op against anything.
func apply_emp(turns: int) -> void:
	if is_downed:
		return
	emp_turns = maxi(1, roundi(turns * emp_stun_duration_mult))
	_refresh_status_light()
	action_logged.emit("%s is DISABLED by EMP — armor offline for %d activation(s)" % [
		stats.display_name, emp_turns,
	])


func _on_destroyed(_unit: Unit) -> void:
	SecurityNetwork.add_salvage(salvage_value)
	action_logged.emit("%s is DESTROYED — %d Salvage recovered" % [stats.display_name, salvage_value])


# --- Activation --------------------------------------------------------------


func take_turn() -> void:
	# Coroutine, like the base version — TurnManager awaits it.
	if emp_turns > 0:
		emp_turns -= 1
		ap = 0
		action_logged.emit("%s is offline (%d activation(s) left)" % [stats.display_name, emp_turns])
		_refresh_status_light()
		return
	await super()
	# Nothing to react to and standing somewhere it was not posted: walk back.
	# This is the whole of "Standing Post" as a behaviour — a robot defends a
	# place, so it returns to one rather than settling wherever a search ended.
	if alert_state != AlertState.UNAWARE or ap <= 0:
		return
	if grid_pos != post_pos:
		await _return_to_post()
	if grid_pos == post_pos and ap > 0 and not is_downed:
		_hold_post()


func _return_to_post() -> void:
	# Somebody ELSE standing on the post is not a reason to walk into them.
	# `_move_to_tile` paths with the goal allowed to be occupied — correct when the
	# goal IS the target, wrong here — so the check belongs on this side of the
	# call. `is_free` is the wrong test: it fails on a unit still registered as the
	# occupant of its own post, which is every robot that has not moved yet.
	var tile: GridTileData = GridManager.get_tile(post_pos)
	if tile == null or not tile.passable:
		return
	if tile.occupant != null and tile.occupant != self:
		return
	await _move_to_tile(post_pos, false)
	if grid_pos == post_pos:
		action_logged.emit("%s resumes its post" % stats.display_name)


## What this unit does once it is standing where it belongs with AP left over.
## The per-type override point for posture, the way `_combat_turn` is the one for
## fighting: an Auxilium reserves its shot, everything else simply waits.
func _hold_post() -> void:
	pass


## No injury state, for any zone. A robot has no arms to cripple and no torso to
## wind — an Aimed Shot against one is a damage roll with an accuracy penalty and
## nothing else, unless the unit declares a component weak point of its own (see
## SecurusUnit's head).
func apply_body_part_damage(_part: int, _amount: int) -> bool:
	return false


## Refuses to be pulled off a post it is meant to hold. The base implementation
## chases without limit, which for a checkpoint unit turns "trip it and run" into
## "trip it and it follows you across the deck" — removing the bypass option that
## is this faction's most distinctive player choice.
func _move_toward(unit: Unit) -> void:
	if holds_position and GridManager.chebyshev_dist(post_pos, unit.grid_pos) > post_leash:
		ap = 0  # hold the line instead of burning AP walking off it
		return
	await super(unit)


func _give_up() -> void:
	# Same transition as the base, different story: a machine does not "settle",
	# it goes back to where it was told to stand. The walk itself happens in
	# take_turn, so this stays a pure state change like the version it replaces.
	_has_last_known = false
	_set_state(AlertState.UNAWARE)
	action_logged.emit("%s finds nothing and returns to its post" % stats.display_name)


func _set_state(new_state: AlertState) -> void:
	super(new_state)
	_refresh_status_light()


func _refresh_status_light() -> void:
	if visual == null:
		return
	var color: Color = STATUS_COLOR_DISABLED if emp_turns > 0 else STATUS_COLOR[alert_state]
	visual.set_status_color(color)
