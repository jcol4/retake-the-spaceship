class_name Unit
extends Node3D
## Base unit: stats, HP/AP/ammo state, shared actions. Sec 4.2 AP economy.

signal hp_changed(unit: Unit)
signal ap_changed(unit: Unit)
signal downed(unit: Unit)
signal moved(unit: Unit)

const MAX_AP := 2
const MOVE_SPEED := 4.5  # metres/second while walking a path
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

@onready var visual: UnitVisual = $Visual

var grid_pos: Vector3i
var current_hp: int
var ap: int = 0
var ammo: int
var is_downed: bool = false
var hunkered: bool = false
var on_overwatch: bool = false
var is_busy: bool = false  # animating a move or a shot — reject new orders

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
	hunkered = false
	on_overwatch = false
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
	visual.set_stance(UnitVisual.RUN)
	for step in path:
		await _step_to(step)
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
	visual.set_stance(UnitVisual.IDLE)
	GridManager.set_occupant(grid_pos, self)
	global_position = GridManager.grid_to_world(grid_pos)
	moved.emit(self)


func _step_to(step: Vector3i) -> void:
	var target := GridManager.grid_to_world(step)
	var delta := target - global_position
	var dist := delta.length()
	if dist < 0.001:
		return
	if _instant:
		global_position = target
		return
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "global_position", target, dist / MOVE_SPEED)
	var yaw := _yaw_toward(target)
	if not is_nan(yaw):
		tween.tween_property(self, "rotation:y", yaw, TURN_TIME)
	await tween.finished


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


func fire_at(target: Unit, action: Combat.ShotAction) -> Combat.ShotResult:
	# Coroutine — callers MUST `await`. Damage lands when the shot animation
	# finishes, so the target drops in time with the effect, not before it.
	# Swing onto the target before anything else. The weapon points where the
	# body faces, so firing without this sprays the burst off toward whatever
	# direction the last move left — and face_toward also swings the flashlight,
	# which changes what is lit before the shot resolves.
	await face_toward(target.global_position)
	ammo -= 1
	var result := Combat.resolve_shot(self, target, action)
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
	visual.set_stance(UnitVisual.CROUCH)


func do_overwatch() -> void:
	on_overwatch = true
	visual.set_stance(UnitVisual.OVERWATCH)


func do_reload() -> void:
	# Coroutine, unlike the other two — callers MUST `await`, or the unit will
	# still be reloading on screen when its next action resolves.
	ammo = stats.mag_size
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
