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
## Not a free choice: stride is fixed by whichever clip the unit's RUN stance
## plays, so this is derived from the clip rather than picked (Sec 6.4 of
## docs/mixamo-pipeline-plan.md). 4.5 is the soldier's, within 4% of its Mixamo
## run's authored 4.34 m/s. Types whose clip disagrees override this in their
## scene and take up the slack with UnitVisual.run_speed_scale.
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
var _instant: bool = false

# The shot the muzzle-flash frame is about to draw a tracer for.
var _pending_shot: Combat.ShotResult = null
var _pending_target: Unit = null
# Which round of the burst is next, and which of them miss regardless of the
# result. Decided up front so the pattern is fixed before the first tracer.
var _burst_round: int = 0
var _burst_strays: Array[int] = []
var _name_label: Label3D = null


func _ready() -> void:
	_instant = DisplayServer.get_name() == "headless"
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
	visual.setup(_instant)
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
	# The deceleration clip strides out ground of its own, so it has to START
	# that far from the destination rather than play on arrival — otherwise the
	# feet walk out two paces the unit never covers. Zero when the character has
	# no such clip, which collapses everything below back to a plain run.
	var stop_span := visual.run_stop_travel()
	var stop_rate := visual.run_stop_rate(move_speed)
	var left := _distance_left(path)
	var total := left[0] + global_position.distance_to(GridManager.grid_to_world(path[0]))
	# A move with less ground than the deceleration needs cannot pay for it, and
	# there is no honest way to shorten a stop: the clip's strides are its own
	# length. Such a move walks instead — nothing to shed speed from, so nothing
	# to stop out of — which is also what a soldier crossing one tile would do.
	var walking := total < stop_span and visual.has_walk()
	var speed := UnitVisual.WALK_SPEED if walking else move_speed
	if walking:
		stop_span = 0.0  # keeps the deceleration out of every branch below
	visual.set_stance(UnitVisual.WALK if walking else UnitVisual.RUN)
	var stopping := false
	for i in path.size():
		var step := path[i]
		var target := GridManager.grid_to_world(step)
		var leg := global_position.distance_to(target)
		# Whatever of this tile lies further out than the stop is still a run.
		# Usually that is all of it or none of it; the split matters on the one
		# tile the handover falls inside, which is rarely a tile boundary.
		var run_span := clampf(leg + left[i] - stop_span, 0.0, leg)
		if run_span > 0.001:
			await _step_to(global_position.move_toward(target, run_span), speed)
		if run_span < leg - 0.001:
			# Metres of the clip's travel already behind us where this leg opens:
			# zero on any path long enough to fit the whole deceleration, positive
			# on a short hop, which skips into the clip rather than crawling it.
			var covered := stop_span - left[i] - (leg - run_span)
			if not stopping:
				stopping = visual.begin_run_stop(covered, stop_rate)
			await _decelerate_to(target, covered, stop_span - left[i], stop_rate)
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
	# Grid state is settled BEFORE the settle plays out: the unit owns its
	# destination tile from the moment it arrives, and what is left of the clip is
	# purely cosmetic — nothing downstream waits on it to know where the unit is.
	GridManager.set_occupant(grid_pos, self)
	global_position = GridManager.grid_to_world(grid_pos)
	if stopping:
		await visual.finish_run_stop()
	elif walking:
		# A walk is already at rest by the time it ends — there is nothing to
		# decelerate out of, so it settles straight into idle.
		visual.set_stance(UnitVisual.IDLE)
	else:
		# No deceleration clip on this character: the old path, where the
		# transition either plays in place or degrades to a hard cut.
		await visual.play_stance_exit(UnitVisual.RUN_STOP, UnitVisual.IDLE)
	moved.emit(self)


## Metres of path still to cover once each step is reached, so move_along can
## ask "is the stop's worth of ground left?" before committing to a tile.
func _distance_left(path: Array[Vector3i]) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(path.size())
	var acc := 0.0
	for i in range(path.size() - 1, -1, -1):
		out[i] = acc
		if i > 0:
			acc += GridManager.grid_to_world(path[i - 1]).distance_to(
				GridManager.grid_to_world(path[i]))
	return out


func _step_to(target: Vector3, speed: float) -> void:
	var dist := global_position.distance_to(target)
	if dist < 0.001:
		return
	if _instant:
		global_position = target
		return
	var seconds := dist / speed
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "global_position", target, seconds)
	_tween_yaw(tween, target, seconds)
	await tween.finished


## Covers the last stretch to `target` on the deceleration clip's own travel
## curve — `from` and `to` are how far into that travel this leg starts and ends.
## Position is driven from the clip rather than at a speed of its own, which is
## the whole point: the feet are planting at the clip's pace, so the ground has
## to move underneath them at exactly that pace or they skate.
##
## One known gap: an overwatch shot between two of these legs pauses the unit
## while the clip keeps playing, so the rest of the stop runs out of sync. It
## costs one leg of slide — the same artefact this replaced, at a fraction of the
## length, and only on an interrupted move.
func _decelerate_to(target: Vector3, from: float, to: float, rate: float) -> void:
	var span := to - from
	var seconds := (visual.run_stop_time_at(to) - visual.run_stop_time_at(from)) / rate
	if _instant or span < 0.001 or seconds < 0.001:
		global_position = target
		return
	var origin := global_position
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_method(_slide.bind(origin, target, from, span),
		visual.run_stop_time_at(from), visual.run_stop_time_at(to), seconds)
	_tween_yaw(tween, target, seconds)
	await tween.finished
	# The curve's last samples are flat to the millimetre, so the tween can land
	# a hair short of the tile. Snapped rather than trusted.
	global_position = target


func _slide(clip_time: float, origin: Vector3, target: Vector3,
		from: float, span: float) -> void:
	var covered := visual.run_stop_travel_at(clip_time) - from
	global_position = origin.lerp(target, clampf(covered / span, 0.0, 1.0))


## Adds the turn toward `target` to a parallel movement tween, `seconds` long.
##
## Both guards are about that parallel: `finished` waits for the LONGEST branch,
## so a fixed 0.09s turn holds up any leg shorter than that — and the run now
## ends on a leg deliberately cut short, the sliver between the last tile
## boundary and where the deceleration takes over. Measured at 50 ms of the unit
## standing still mid-sprint before the guards went in.
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
	if _instant:
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
	# face_toward only yaws the body — this tilts it so the barrel also points
	# up/down at a target on a different floor or in a different stance.
	visual.set_aim_pitch(target.global_position)
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
	visual.clear_aim_pitch()
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
		if not _instant:
			var vfx := get_tree().get_first_node_in_group("vfx")
			if vfx:
				vfx.impact(target.global_position, result.crit)
		target.take_damage(result.damage)
	is_busy = false
	return result


func _on_muzzle() -> void:
	# One of these per round of the burst, fired by UnitVisual.play_burst.
	if _instant or _pending_shot == null or _pending_target == null:
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
