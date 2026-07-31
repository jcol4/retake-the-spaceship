class_name Unit
extends Node3D
## Base unit: stats, HP/AP/ammo state, shared actions. Sec 4.2 AP economy.

signal hp_changed(unit: Unit)
signal ap_changed(unit: Unit)
signal downed(unit: Unit)
signal moved(unit: Unit)

const MAX_AP := 2
const TURN_TIME := 0.09  # seconds to swing toward the next tile

# Rounds per burst. One trigger pull is still one Combat.resolve_shot — one hit
# roll, one damage number, one round of ammo — so this is purely how many
# tracers that shot draws, and changing it cannot unbalance anything.
const BURST_MIN := 3
const BURST_MAX := 5
# On a hit, this many rounds are thrown wide anyway so the burst reads as a
# burst; the rest converge. On a miss every round misses. Kept below BURST_MIN
# so a hit always lands visibly more rounds on target than it throws away.
const BURST_STRAY_MAX := 2

@export var stats: UnitStats
@export var is_player_controlled: bool = false
## Metres per second while walking a path. Cosmetic ONLY — the tile budget and
## the AP economy know nothing about it, so no value here can affect balance.
##
## 4.5 is the soldier's, carried over unchanged from the 3D rig it was measured
## against. It is now the AUTHORING CONTRACT rather than a derived value: the
## sprite run cycle is drawn to read correctly at 4.5 m/s, instead of the speed
## being fitted to a clip that already existed. Slower types override it here.
@export var move_speed: float = 4.5

@onready var visual: UnitVisual = $Visual

var grid_pos: Vector3i
var current_hp: int
var ap: int = 0
var ammo: int
# Spare rounds beyond the loaded magazine. -1 means unlimited (never
# decremented by do_reload) — see WeaponData.starting_reserve.
var reserve: int = -1
var is_downed: bool = false
var hunkered: bool = false
var on_overwatch: bool = false
var stunned: bool = false  # set by an incoming torso crit; burns this unit's next activation
var is_busy: bool = false  # animating a move or a shot — reject new orders

# VATS-style body-part injury tracking (Sec 4.2/6.5). Each part accumulates the
# raw damage Aimed Shots land on it; crossing its threshold flags it injured for
# the rest of the mission (or until `heal_injury` is called by a future medical-
# resource action — not wired up to any action/UI yet).
const PART_HP_FRACTION := {
	Combat.BodyPart.TORSO: 0.50,
	Combat.BodyPart.HEAD: 0.25,
	Combat.BodyPart.ARM_L: 0.35, Combat.BodyPart.ARM_R: 0.35,
	Combat.BodyPart.LEG_L: 0.35, Combat.BodyPart.LEG_R: 0.35,
}
const LEG_INJURY_SPEED_PENALTY := 0.33  # per injured leg, fraction of move range lost
const ARM_RANGED_ACC_PENALTY := 15  # per injured arm
const ARM_MELEE_ACC_PENALTY := 25  # per injured arm
const ARM_MELEE_DMG_MULT := 0.6  # per injured arm, multiplicative (40% cut each)

var _body_part_damage: Dictionary = {}  # Combat.BodyPart -> int accumulated
var _injured_parts: Dictionary = {}  # Combat.BodyPart -> bool

# Sec 5.2: a free (0 AP) toggle. Aliens rely on their own senses rather than a
# rig-mounted light, so EnemyUnit sets has_flashlight false in _init().
var has_flashlight: bool = true
var flashlight_on: bool = true

# With no display there is nothing to animate, so walks and tracers resolve
# instantly. Keeps the `--auto` headless smoke test fast.
var _headless: bool = false
## Whether this unit's sprite is currently drawn. Written by MapBuilder from the
## compartment graph: units are rendered only in rooms holding a player unit.
## Deliberately coarser than a per-unit line-of-sight test — a room is a unit of
## space the player can reason about, where a raycast result is not.
var _rendered: bool = true

# The shot the muzzle-flash frame is about to draw a tracer for.
var _pending_shot: Combat.ShotResult = null
var _pending_target: Unit = null
# Which round of the burst is next, and which of them miss regardless of the
# result. Decided up front so the pattern is fixed before the first tracer.
var _burst_round: int = 0
var _burst_strays: Array[int] = []
var _name_label: Label3D = null


## Whether this unit's actions should resolve with no time on the clock.
##
## Asked FRESH at each action rather than answered once at spawn, which is the
## whole point: turn resolution awaits animations, so an unseen enemy's
## activation would otherwise burn its full wall-clock time against a completely
## static screen. Fast-forwarding it is the XCOM behaviour, and it comes out of
## the path the headless smoke test already used rather than a new one.
##
## The combat log still narrates units resolved this way. That leak is accepted:
## the log is slated for removal once the game runs smoothly, so suppressing it
## would be work spent on something being deleted.
func is_instant() -> bool:
	return _headless or not _rendered


## Called by MapBuilder when the revealed set changes. Hides the sprite, which
## also stops it being awaited — see is_instant.
func set_rendered(rendered: bool) -> void:
	if rendered == _rendered:
		return
	_rendered = rendered
	visual.visible = rendered


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	if stats == null:
		stats = UnitStats.new()
	current_hp = stats.max_hp()
	ammo = stats.mag_size
	reserve = stats.weapon.starting_reserve if stats.weapon else 0
	grid_pos = GridManager.world_to_grid(global_position)
	global_position = GridManager.grid_to_world(grid_pos)
	GridManager.set_occupant(grid_pos, self)
	_name_label = get_node_or_null("NameLabel")
	if _name_label:
		_name_label.text = stats.display_name
	visual.setup()
	visual.muzzle.connect(_on_muzzle)
	visual.set_flashlight_enabled(has_flashlight and flashlight_on)


func begin_activation() -> void:
	ap = MAX_AP
	# Sec 6.3 / 4.2: both clear on this unit's next activation.
	var was_crouched := hunkered
	hunkered = false
	on_overwatch = false
	if was_crouched:
		# Standing back up only reads if the unit was actually down there —
		# playing it from an idle stance is a rise from nothing. Not awaited,
		# for the same reason as do_hunker.
		visual.play_stance_exit(UnitVisual.CROUCH_TO_STAND, UnitVisual.IDLE)
	else:
		visual.set_stance(UnitVisual.IDLE)
	ap_changed.emit(self)


func spend_ap(cost: int) -> void:
	ap = maxi(ap - cost, 0)
	ap_changed.emit(self)


func move_along(path: Array[Vector3i]) -> void:
	# Walks the path one tile at a time. This is a coroutine — callers MUST
	# `await` it, or the unit will still be sliding when the next action
	# resolves. The unit holds no tile mid-walk (only one unit ever moves at a
	# time), so dying to overwatch part-way leaves no tile wrongly reserved.
	if path.is_empty():
		return
	GridManager.set_occupant(grid_pos, null)
	is_busy = true
	# A one-tile hop walks rather than runs, where the character has both gaits:
	# a soldier crossing a single tile does not break into a sprint. Everything
	# else the deceleration system used to decide here died with the 3D rig —
	# a sprite has no stride to skate, so a tile is a tile.
	var walking := path.size() == 1 and visual.has_walk()
	var speed := UnitVisual.WALK_SPEED if walking else move_speed
	visual.set_stance(UnitVisual.WALK if walking else UnitVisual.RUN)
	var was_hidden := is_instant()
	for step in path:
		# Visibility is re-read per tile, which is what makes a unit that walks
		# into the squad's line of sight animate the REST of its move instead of
		# popping across the deck. The loop already does per-tile work for
		# lighting and overwatch, so this drops in alongside it.
		var hidden := is_instant()
		if was_hidden and not hidden:
			# Handover. Re-assert the stance from the top rather than trying to
			# join a one-shot that has been running invisibly: a walk cycle can be
			# picked up mid-stride, a reload cannot.
			visual.set_stance(UnitVisual.WALK if walking else UnitVisual.RUN)
		was_hidden = hidden
		await _step_to(GridManager.grid_to_world(step), speed)
		grid_pos = step
		if is_downed:
			break
		if has_flashlight and flashlight_on:
			# Keeps the beacon tracking mid-sprint, so an overwatcher's shot
			# below judges light as it actually was at the moment it fired.
			LightingManager.recompute_dynamic()
		await TurnManager.check_overwatch(self)
		if is_downed:
			break
	is_busy = false
	if is_downed:
		return  # the collapse is already playing — don't stand it back up
	# Grid state is settled before the transition plays out: the unit owns its
	# destination tile from the moment it arrives, and what is left is purely
	# cosmetic — nothing downstream waits on it to know where the unit is.
	GridManager.set_occupant(grid_pos, self)
	global_position = GridManager.grid_to_world(grid_pos)
	if walking:
		# A walk is already at rest by the time it ends, so it settles straight
		# into idle rather than through a stop.
		visual.set_stance(UnitVisual.IDLE)
	else:
		await visual.play_stance_exit(UnitVisual.RUN_STOP, UnitVisual.IDLE)
	moved.emit(self)


func _step_to(target: Vector3, speed: float) -> void:
	var dist := global_position.distance_to(target)
	if dist < 0.001:
		return
	if is_instant():
		global_position = target
		return
	var seconds := dist / speed
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "global_position", target, seconds)
	_tween_yaw(tween, target, seconds)
	await tween.finished


## Adds the turn toward `target` to a parallel movement tween, `seconds` long.
##
## Both guards are about that parallel: `finished` waits for the LONGEST branch,
## so a fixed 0.09s turn would hold up any leg shorter than that.
func _tween_yaw(tween: Tween, target: Vector3, seconds: float) -> void:
	var yaw := _yaw_toward(target)
	if is_nan(yaw) or absf(yaw - rotation.y) < 0.001:
		return  # already facing it: every leg of a straight path
	tween.tween_property(self, "rotation:y", yaw, minf(TURN_TIME, seconds))


func _yaw_toward(world_pos: Vector3) -> float:
	# Godot forward is -Z. Returns the short way round rather than unwinding
	# through a full turn, or NAN when the point is directly underfoot.
	var delta := world_pos - global_position
	if absf(delta.x) <= 0.001 and absf(delta.z) <= 0.001:
		return NAN
	return rotation.y + wrapf(atan2(-delta.x, -delta.z) - rotation.y, -PI, PI)


func face_toward(world_pos: Vector3) -> void:
	# Turn in place. Coroutine — callers MUST `await`. Matters beyond looking
	# right: the flashlight cone rotates with facing (Sec 5.2), so which tiles
	# this unit lights, and therefore which aliens notice it, follow from here.
	var yaw := _yaw_toward(world_pos)
	if is_nan(yaw):
		return
	if is_instant():
		rotation.y = yaw
	else:
		is_busy = true
		var tween := create_tween()
		tween.tween_property(self, "rotation:y", yaw, TURN_TIME * 2.0)
		await tween.finished
		is_busy = false
	if has_flashlight and flashlight_on:
		# Same guard move_along uses: the cone has swung, so what it lights (and
		# what notices being lit) has to be recomputed before anything else acts.
		LightingManager.recompute_dynamic()


func take_damage(amount: int) -> void:
	current_hp = maxi(current_hp - amount, 0)
	hp_changed.emit(self)
	if current_hp == 0 and not is_downed:
		is_downed = true
		on_overwatch = false
		stunned = false
		GridManager.set_occupant(grid_pos, null)
		if _name_label:
			_name_label.visible = false
		# Deliberately not awaited: the unit is out of the fight the moment its
		# HP hits zero, and the shooter's own activation shouldn't stall on the
		# collapse playing out. (ActiveMarker self-hides off is_downed.)
		visual.play_action(UnitVisual.DOWNED)
		downed.emit(self)
	elif not is_downed:
		visual.play_action(UnitVisual.HIT_REACT)


func can_shoot() -> bool:
	return ammo > 0


func can_reload() -> bool:
	return ammo < stats.mag_size and (reserve < 0 or reserve > 0)


func move_run() -> int:
	return maxi(1, roundi(stats.move_run() * _leg_speed_multiplier()))


func move_sprint() -> int:
	return maxi(1, roundi(stats.move_sprint() * _leg_speed_multiplier()))


func ranged_accuracy_penalty() -> int:
	return ARM_RANGED_ACC_PENALTY * _injured_arm_count()


func melee_accuracy_penalty() -> int:
	return ARM_MELEE_ACC_PENALTY * _injured_arm_count()


func melee_damage_multiplier() -> float:
	return pow(ARM_MELEE_DMG_MULT, _injured_arm_count())


func is_part_injured(part: int) -> bool:
	return _injured_parts.get(part, false)


func injured_summary() -> String:
	var names: Array[String] = []
	for part in _injured_parts:
		if _injured_parts[part]:
			names.append(Combat.body_part_name(part))
	return ", ".join(names) if not names.is_empty() else "None"


func apply_body_part_damage(part: int, amount: int) -> bool:
	# Accumulates raw damage against this part's own threshold (Sec 4.2/6.5).
	# Returns true the first time this hit pushes it over the threshold —
	# callers use that to log "X's Y is injured!" only once, on the hit that did it.
	_body_part_damage[part] = _body_part_damage.get(part, 0) + amount
	if _injured_parts.get(part, false):
		return false
	if _body_part_damage[part] >= _body_part_threshold(part):
		_injured_parts[part] = true
		return true
	return false


func heal_injury(part: int) -> void:
	# Hook for a future medical-resource action (GDD Sec 4.4) — not yet wired to
	# any action or UI. Clears the injury and resets its damage counter.
	_injured_parts[part] = false
	_body_part_damage[part] = 0


func _body_part_threshold(part: int) -> int:
	return maxi(1, roundi(stats.max_hp() * PART_HP_FRACTION.get(part, 0.35)))


func _injured_leg_count() -> int:
	var n := 0
	if is_part_injured(Combat.BodyPart.LEG_L):
		n += 1
	if is_part_injured(Combat.BodyPart.LEG_R):
		n += 1
	return n


func _injured_arm_count() -> int:
	var n := 0
	if is_part_injured(Combat.BodyPart.ARM_L):
		n += 1
	if is_part_injured(Combat.BodyPart.ARM_R):
		n += 1
	return n


func _leg_speed_multiplier() -> float:
	return 1.0 - LEG_INJURY_SPEED_PENALTY * _injured_leg_count()


func fire_at(target: Unit, action: Combat.ShotAction, body_part: int = Combat.BodyPart.TORSO) -> Combat.ShotResult:
	# Coroutine — callers MUST `await`. Damage lands when the shot animation
	# finishes, so the target drops in time with the effect, not before it.
	# Swing onto the target before anything else. The weapon points where the
	# body faces, so firing without this sprays the burst off toward whatever
	# direction the last move left — and face_toward also swings the flashlight,
	# which changes what is lit before the shot resolves.
	await face_toward(target.global_position)
	# No vertical aim. A sprite has no spine to tilt, so a shot at a target on
	# another deck reads flatter than it did; if that comes back it will be
	# per-pitch-band art on an arm layer, not a bone solve.
	ammo -= 1
	var result := Combat.resolve_shot(self, target, action, body_part)
	is_busy = true
	var rounds := randi_range(BURST_MIN, BURST_MAX)
	_pending_shot = result
	_pending_target = target
	_burst_round = 0
	_burst_strays = _pick_strays(rounds, result.hit)
	await visual.play_burst(rounds)  # emits `muzzle` once per round
	_pending_shot = null
	_pending_target = null
	if result.hit:
		target.take_damage(result.damage)
		if action == Combat.ShotAction.AIMED_SHOT and not target.is_downed:
			result.newly_injured = target.apply_body_part_damage(body_part, result.damage)
			if result.stunned:
				target.stunned = true
	is_busy = false
	return result


func _pick_strays(rounds: int, hit: bool) -> Array[int]:
	# A miss throws everything wide. A hit still throws one or two away, because
	# a burst where every round lands in the same spot reads as a single shot.
	var strays: Array[int] = []
	if not hit:
		for i in rounds:
			strays.append(i)
		return strays
	var pool: Array[int] = []
	for i in rounds:
		pool.append(i)
	pool.shuffle()
	return pool.slice(0, randi_range(1, BURST_STRAY_MAX))


func melee_at(target: Unit) -> Combat.ShotResult:
	# Coroutine — callers MUST `await`. Mirrors fire_at: damage lands when the
	# animation finishes, so the target reacts in time with the swing rather than
	# before it. No ammo is spent and no tracer is drawn — nothing left the unit.
	var result := Combat.resolve_melee(self, target)
	is_busy = true
	await visual.play_action(UnitVisual.MELEE)
	if result.hit:
		if not is_instant():
			var vfx := get_tree().get_first_node_in_group("vfx")
			if vfx:
				vfx.impact(target.global_position, result.crit)
		target.take_damage(result.damage)
	is_busy = false
	return result


func _on_muzzle() -> void:
	# One of these per round of the burst, fired by UnitVisual.play_burst.
	if is_instant() or _pending_shot == null or _pending_target == null:
		return
	var round_index := _burst_round
	_burst_round += 1
	var vfx := get_tree().get_first_node_in_group("vfx")
	if vfx == null:
		return
	# Origin is the barrel tip as the animation currently has it, not the middle
	# of the unit — the rifle is held off to the right, so a centreline tracer
	# visibly left the chest.
	var from := visual.muzzle_origin()
	var lands := _pending_shot.hit and round_index not in _burst_strays
	vfx.tracer(from, _pending_target.global_position, lands, _pending_shot.crit)
	vfx.muzzle_flash(from)


func do_hunker() -> void:
	hunkered = true
	# Deliberately not awaited, and do_hunker stays a plain function: dropping
	# into cover is cosmetic, and the unit is already counted as hunkered by the
	# line above. The transition hands off to CROUCH when it finishes.
	visual.play_stance_exit(UnitVisual.STAND_TO_CROUCH, UnitVisual.CROUCH)


func do_overwatch() -> void:
	on_overwatch = true
	visual.set_stance(UnitVisual.OVERWATCH)


func do_reload() -> void:
	# Coroutine, unlike the other two — callers MUST `await`, or the unit will
	# still be reloading on screen when its next action resolves. Draws from
	# `reserve` (spare rounds beyond the loaded mag); reserve < 0 means
	# unlimited, so it's never decremented — see WeaponData.starting_reserve.
	var needed := stats.mag_size - ammo
	var drawn := needed
	if reserve >= 0:
		drawn = mini(needed, reserve)
		reserve -= drawn
	ammo += drawn
	is_busy = true
	await visual.play_action(UnitVisual.RELOAD)
	is_busy = false


func toggle_flashlight() -> void:
	# Free action (0 AP, Sec 4.2) — on for detection range, off to stay dark.
	if not has_flashlight:
		return
	flashlight_on = not flashlight_on
	visual.set_flashlight_enabled(flashlight_on)
	LightingManager.recompute_dynamic()
