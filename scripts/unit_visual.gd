class_name UnitVisual
extends Node3D
## Owns a unit's model and its animation state. Unit code drives this by intent
## ("play the shoot action"), never by clip name, so swapping the placeholder
## capsule for a rigged model touches this file and the unit scenes only.
##
## Works with no AnimationPlayer assigned: stances become no-ops and actions
## resolve on a timer of the length the clip will eventually be. That is the
## path the capsule units take until the real model lands, and it keeps action
## pacing identical across the swap.

## Fired at the shot's muzzle-flash frame, from a method track on the shoot
## clips. Drives the VFX tracer, so the beam leaves the barrel when the arm is
## actually up rather than the instant the order was given.
signal muzzle

## Fired as each boot lands during the run stance. Hook for footstep SFX and a
## camera shake — half of "heavy" is impact feedback, not joint angles.
signal footstep

# Frames where each boot first reaches the floor, measured at 0.10s and 0.433s
# of the 0.667s run loop (tools/gen_soldier.py --traj run), so evenly spaced
# half a cycle apart. Note the plant is NOT the contact key: the leg is still
# reaching there and only loads three frames later.
const FOOTSTEP_OFFSET := 0.10
const FOOTSTEP_GAP := 0.333

# Seconds of plain idle between attempts at an IDLE_FIDGET. Rolled fresh each
# time rather than fixed, which matters most when several units are on screen:
# a constant gap would have a nest of swarm units convulsing in lockstep, and
# nothing reads as scripted faster than that.
#
# The range is set against the 6.13s clip for roughly a 1-in-5 duty cycle — often
# enough that a watched nest is never still, rare enough that it stays an
# event rather than the thing the unit does.
const FIDGET_GAP_MIN := 12.0
const FIDGET_GAP_MAX := 35.0

# Stances persist until something changes them. Actions are one-shots that
# hand back to the current stance when they finish.
const IDLE := &"idle"
const RUN := &"run"
## Short moves walk. See WALK_SPEED and Unit.move_along for when, and why it is
## not simply the run played slower.
const WALK := &"walk"
const CROUCH := &"crouch_idle"
const OVERWATCH := &"overwatch_hold"

# Firing is two clips driven by play_burst rather than one clip per shot type:
# the burst length is rolled per shot, and no fixed clip can match a count it
# does not know. AIM_HOLD is the weapon up and steady, either side of the burst;
# SHOOT_RECOIL is one round's kick, replayed from the start once per round.
const AIM_HOLD := &"aim_hold"
const SHOOT_RECOIL := &"shoot_recoil"
# Transitions. Not stances and not actions: each is a one-shot that bridges one
# stance into another, played through play_stance_exit. All degrade to a hard
# cut, at zero time cost, when the clip is absent.
const RUN_STOP := &"run_stop"
const STAND_TO_CROUCH := &"stand_to_crouch"
const CROUCH_TO_STAND := &"crouch_to_stand"
const MELEE := &"melee"
const RELOAD := &"reload"
const GRENADE := &"throw_grenade"
const INTERACT := &"interact"
const HIT_REACT := &"hit_react"
const DOWNED := &"downed"
# Alien-side only: played once when an alien wakes, by EnemyUnit's state machine
# rather than by anything the player ordered. The player's squad has no
# equivalent, and no soldier clip is mapped to it.
const ALERT_SCREAM := &"alert_scream"
# Idle variation, played at random intervals while the IDLE stance holds. Not an
# action and not a stance: it is a one-shot the unit slips into and out of on its
# own, with nothing in the game waiting on it. See _fidget_loop for why that
# distinction decides how it is played.
const IDLE_FIDGET := &"idle_fidget"

# Stand-in durations for the no-model path, so action pacing is identical whether
# or not an AnimationPlayer is attached. Only the capsule-bodied ranged alien
# still takes this path; both rigged characters have real clips and ignore it.
#
# Two characters now supply these actions at different lengths — the soldier's
# hit_react is 0.43s against the swarm's 2.00s. These are the SOLDIER's numbers,
# because a unit with no model at all is a stand-in for a soldier. Update them if
# the soldier's clip frame counts change.
const FALLBACK_TIME := {
	# Measured off the swarm's trimmed Zombie Neck Bite. Melee is alien-side, and
	# the swarm is the only thing in the game that owns a melee clip, so unlike
	# its neighbours here this one is not a soldier length.
	MELEE: 1.20,
	RELOAD: 1.20,
	GRENADE: 1.00,
	INTERACT: 1.00,
	HIT_REACT: 0.47,
	DOWNED: 0.80,
	ALERT_SCREAM: 2.80,
}
const DEFAULT_FALLBACK_TIME := 0.4

# Burst timing. RAISE_TIME is the beat where the weapon comes up and steadies
# before the first round — without it the shot reads as going off the instant
# the order was given. CADENCE is the gap between rounds; SHOOT_RECOIL is 0.13s
# long, so this leaves the kick just short of fully recovering before the next
# one, which is what makes a burst look continuous rather than like separate
# shots. SETTLE is the weapon held on target afterwards.
const RAISE_TIME := 0.18
const BURST_CADENCE := 0.11
const SETTLE_TIME := 0.20

# The ground RUN_STOP covers, and how it spends it. The clip is exported with its
# root motion held (build_anims.py strip_mode "hold"), so the hips do not travel
# and the STRIDES have to be paid for by moving the unit — which is what
# Unit.move_along uses this table for. Playing the clip on arrival instead leaves
# the feet walking out two more paces against ground that is not moving.
#
# Measured off the source, art_src/anims/Rifle Run To Stop.fbx: cumulative
# horizontal Hips travel in metres, sampled every 2 of its 45 frames, so entry
# i sits at i/(size-1) of the clip. Note the shape — it is NOT a smooth
# deceleration. The first 60% of the clip is a near-constant 3.16 m/s run
# covering 88% of the distance; everything after is the plant and the settle.
# That is why this is a table and not an ease-out curve: no standard easing
# spends its distance that way, and a wrong distribution IS foot skate.
const RUN_STOP_CURVE := [
	0.000, 0.211, 0.421, 0.610, 0.790, 0.987, 1.221, 1.455,
	1.654, 1.814, 1.969, 2.121, 2.270, 2.418, 2.530, 2.606,
	2.674, 2.736, 2.784, 2.814, 2.825, 2.826, 2.826,
]

## Playback rate for RUN_STOP, as a multiple of the clip's authored speed.
##
## The clip enters at 3.16 m/s (its first 2 frames of travel) while the soldier
## runs at move_speed 4.5, so played as authored the unit would drop 30% of its
## speed in one frame at the handoff — a visible lurch, at the exact moment the
## eye is tracking the unit. Scaling by the ratio makes the entry continuous, and
## it is not a fudge: a runner going 43% faster over the same 2.83 m genuinely
## has to decelerate 43% harder. Time-scaling cannot introduce skate, because the
## unit's position is driven from this same clip.
##
## Set to 1.0 to get the authored pacing back at the cost of that lurch.
const RUN_STOP_ENTRY_SPEED := 3.16

## Metres per second for the WALK stance, replacing Unit.move_speed on the moves
## that take it. Measured the same way as everything else here: Walking.fbx
## travels 1.398 m over its 42 frames, so 1.02 m/s. Played at its authored rate
## and moved at its authored speed, which is why it needs no correction of any
## kind — unlike RUN, whose clip and move_speed were chosen independently.
const WALK_SPEED := 1.02

# Stand-in barrel height for units with no rigged rifle, so their shots still
# leave something shoulder-height rather than the floor.
const FALLBACK_MUZZLE_HEIGHT := 1.4

const STANCE_BLEND := 0.15
const ACTION_BLEND := 0.08

## Playback rate for the RUN stance, and only for it. A locomotion clip is
## authored at a fixed ground speed while `Unit.move_speed` is chosen for turn
## pacing, so the two have to be reconciled somewhere or the feet skate.
##
## The soldier needs no correction — its Mixamo run is authored at 4.34 m/s
## against a move_speed of 4.5. The swarm does: Zombie Walk is authored at
## 0.32 m/s (measured off the planted foot's backward sweep, since the clip is
## In Place and has no root travel to read) against a move_speed of 1.5, which
## is a 4.7x mismatch. Playing it at 2x halves that, and a 2.0s shamble cycle
## still reads as a lurch rather than a sprint.
@export var run_speed_scale: float = 1.0

# Exported as NodePaths and resolved in _ready rather than as exported Node
# references: a NodePath written by hand into a .tscn does not get resolved into
# a Node, which silently left every unit in the no-animation fallback path.
@export var anim_path: NodePath = ^"soldier/AnimationPlayer"
## Hidden when the unit goes down — capsule path only. A real model plays a
## collapse and stays lying on the floor instead of vanishing.
@export var fallback_mesh_path: NodePath
## Empty on units with no rigged flashlight (the enemy capsule) — set_flashlight_enabled
## is then a no-op rather than an error.
@export var flashlight_path: NodePath = ^"soldier/Rig/Skeleton3D/RifleMount/rifle/Muzzle/Flashlight"
## The barrel tip. Rides the rifle's BoneAttachment3D, so it tracks the weapon
## through every clip — which is the whole point: shots have to leave the barrel
## wherever the animation has put it, not the middle of the unit.
@export var muzzle_path: NodePath = ^"soldier/Rig/Skeleton3D/RifleMount/rifle/Muzzle"
## Empty on units with no rigged skeleton (the enemy capsule) — set_aim_pitch
## is then a no-op rather than an error.
@export var aim_pitch_path: NodePath = ^"soldier/Rig/Skeleton3D/AimPitch"

var anim: AnimationPlayer = null
var fallback_mesh: Node3D = null
var flashlight: Light3D = null
var muzzle_point: Node3D = null
var aim_pitch: AimPitch = null

var _stance: StringName = IDLE
var _action: StringName = &""
var _instant: bool = false
var _stepping: bool = false
var _fidgeting: bool = false


func _ready() -> void:
	# Children are ready before their parent, so Unit._ready can rely on these.
	anim = get_node_or_null(anim_path) as AnimationPlayer
	fallback_mesh = get_node_or_null(fallback_mesh_path) as Node3D
	flashlight = get_node_or_null(flashlight_path) as Light3D
	muzzle_point = get_node_or_null(muzzle_path) as Node3D
	aim_pitch = get_node_or_null(aim_pitch_path) as AimPitch


func setup(instant: bool) -> void:
	_instant = instant
	# has_animation guard for the same reason every other play site has one: a
	# character whose idle clip failed to build would otherwise error here, once,
	# at spawn — easy to miss in a log, and the unit then holds the rig's T-pose
	# for the rest of the mission. (build_anims.py now refuses to export a GLB
	# missing a stance clip, so this should be unreachable; it is cheap insurance
	# against the model and the code disagreeing about a clip name.)
	if anim and not _instant and anim.has_animation(IDLE):
		anim.play(IDLE)
	# Started here as well as from set_stance so a unit fidgets from the moment it
	# spawns. Aliens spend most of a mission UNAWARE at their nests, which is
	# precisely when the player is looking at one standing still.
	_maybe_start_fidget()


func set_flashlight_enabled(on: bool) -> void:
	if flashlight:
		flashlight.visible = on


func set_stance(stance: StringName) -> void:
	# Recorded even when a one-shot is mid-flight; play_action hands back to
	# whatever the stance has become rather than to what it was on entry.
	_stance = stance
	if _action != &"":
		return
	_play(stance, STANCE_BLEND)
	if stance == RUN and not _stepping and not _instant:
		_footstep_loop()  # deliberately not awaited: runs until the stance ends
	elif stance == IDLE:
		_maybe_start_fidget()


func play_action(action: StringName) -> void:
	# Coroutine — callers MUST await, or the next game action resolves while
	# this one is still on screen.
	# Shooting does NOT come through here — see play_burst. This drives the
	# one-shot clips that fire no rounds, so nothing here emits `muzzle`.
	if _instant:
		return
	if anim == null or not anim.has_animation(action):
		# No clip yet: hold for as long as the clip will, so timing-dependent
		# code behaves the same before and after the model exists.
		if action == DOWNED and fallback_mesh:
			fallback_mesh.visible = false
		await get_tree().create_timer(
			FALLBACK_TIME.get(action, DEFAULT_FALLBACK_TIME)).timeout
		return
	_action = action
	anim.play(action, ACTION_BLEND)
	# Ignore finish signals from anything but the clip we just started.
	while anim.is_playing() and anim.current_animation == action:
		await anim.animation_finished
	_action = &""
	# DOWNED holds its last frame; every other action returns to the stance.
	if action != DOWNED:
		_play(_stance, STANCE_BLEND)


## Plays a one-shot that bridges the current stance into `next`, then settles
## there. Coroutine — callers MUST await.
##
## Unlike play_action, a missing clip costs NO time: it falls straight through to
## the stance, which is exactly what the old behaviour was. That makes this safe
## to call before the clip has been sourced, and means an absent clip degrades to
## a hard cut rather than to a mysterious pause on every move.
func play_stance_exit(action: StringName, next: StringName) -> void:
	if _instant or anim == null or not anim.has_animation(action):
		set_stance(next)
		return
	# Assigned rather than passed to set_stance: writing the field directly
	# records where to land WITHOUT playing it, so the exit clip is what shows
	# on screen. play_action's tail then blends into whatever _stance has become.
	_stance = next
	await play_action(action)


## Whether this character can walk a short move rather than run it. False for
## anything with no walk clip (the swarm, the capsule alien), which keeps those
## units on the single gait they have.
func has_walk() -> bool:
	return not _instant and anim != null and anim.has_animation(WALK)


## Metres of ground the deceleration needs, so a mover knows how far from its
## destination to hand over. Zero when this character has no RUN_STOP clip (and
## on the headless path), which is what keeps every caller free of the question:
## a zero-length stop is simply never entered, and the move ends as it used to.
func run_stop_travel() -> float:
	if _instant or anim == null or not anim.has_animation(RUN_STOP):
		return 0.0
	var last: float = RUN_STOP_CURVE[RUN_STOP_CURVE.size() - 1]
	return last


## Playback rate that makes the clip enter at `speed`. See RUN_STOP_ENTRY_SPEED.
func run_stop_rate(speed: float) -> float:
	return speed / RUN_STOP_ENTRY_SPEED


## Clip time, in seconds, at which the deceleration has covered `metres`.
func run_stop_time_at(metres: float) -> float:
	var last := RUN_STOP_CURVE.size() - 1
	var full: float = RUN_STOP_CURVE[last]
	var target := clampf(metres, 0.0, full)
	for i in last:
		var to: float = RUN_STOP_CURVE[i + 1]
		if target > to:
			continue
		var from: float = RUN_STOP_CURVE[i]
		# Guard the flat tail, where several samples share a value and the
		# fraction would be 0/0.
		var frac := 0.0 if to == from else (target - from) / (to - from)
		return (float(i) + frac) / float(last) * _run_stop_length()
	return _run_stop_length()


## The inverse: metres covered by clip time `seconds`.
func run_stop_travel_at(seconds: float) -> float:
	var last := RUN_STOP_CURVE.size() - 1
	var length := _run_stop_length()
	if length <= 0.0:
		return 0.0
	var x := clampf(seconds / length, 0.0, 1.0) * float(last)
	var i := mini(int(x), last - 1)
	var from: float = RUN_STOP_CURVE[i]
	var to: float = RUN_STOP_CURVE[i + 1]
	return lerpf(from, to, x - float(i))


## Starts the deceleration `metres` into its own travel — non-zero only when the
## path was too short to fit the whole clip, in which case the front of it is
## skipped so the part that IS played still lands on the ground available.
## Returns false when there is no clip, leaving the caller on the old path.
func begin_run_stop(metres: float, rate: float) -> bool:
	if _instant or anim == null or not anim.has_animation(RUN_STOP):
		return false
	# Set like play_action's, so nothing treats the unit as free mid-stop; unlike
	# play_action this does NOT await, because the caller is driving the unit's
	# position through the same clip and has to stay in control of the timing.
	_action = RUN_STOP
	anim.play(RUN_STOP, ACTION_BLEND, rate)
	if metres > 0.0:
		anim.seek(run_stop_time_at(metres), true)
	return true


## Holds until the settle at the tail of the clip — the part past the last of the
## travel, which no movement pays for — finishes, then lands in IDLE.
## Coroutine — callers MUST await.
func finish_run_stop() -> void:
	if _action == RUN_STOP:
		while anim.is_playing() and anim.current_animation == RUN_STOP:
			await anim.animation_finished
		_action = &""
		_play(IDLE, STANCE_BLEND)
	# Written last, and unconditionally: if something else took the body during
	# the move (a hit react on the way in), that one-shot's own tail hands back to
	# whatever _stance has become — and a unit that has arrived is standing, not
	# still running. Same reason play_stance_exit assigns the field directly.
	_stance = IDLE


func _run_stop_length() -> float:
	return anim.get_animation(RUN_STOP).length if anim else 0.0


## Where a shot leaves the weapon, in world space. Falls back to a point above
## the unit for anything with no rigged rifle (the enemy capsule), so callers
## never have to special-case it.
func muzzle_origin() -> Vector3:
	if muzzle_point:
		return muzzle_point.global_position
	return global_position + Vector3(0.0, FALLBACK_MUZZLE_HEIGHT, 0.0)


## Tilts the upper body so the barrel points at a target above or below eye
## level. No-op on units with no skeleton (the enemy capsule) — the raw
## height difference then plays no part in whether the shot lands.
func set_aim_pitch(world_pos: Vector3) -> void:
	if aim_pitch:
		aim_pitch.aim_at(world_pos)


func clear_aim_pitch() -> void:
	if aim_pitch:
		aim_pitch.clear_aim()


func play_burst(rounds: int) -> void:
	# Coroutine — callers MUST await. Weapon comes up, fires `rounds` rounds on a
	# fixed cadence, holds, then hands back to the stance. One `muzzle` per round.
	if _instant:
		for _i in rounds:
			muzzle.emit()
		return
	if anim == null or not anim.has_animation(SHOOT_RECOIL):
		# No clips yet: hold for as long as the real burst will so shot pacing is
		# the same before and after the model exists.
		for _i in rounds:
			muzzle.emit()
			await get_tree().create_timer(BURST_CADENCE).timeout
		await get_tree().create_timer(RAISE_TIME + SETTLE_TIME).timeout
		return
	_action = SHOOT_RECOIL
	_play(AIM_HOLD, STANCE_BLEND)
	await get_tree().create_timer(RAISE_TIME).timeout
	for _i in rounds:
		# seek(0) rather than a plain play(): play() on the clip already running
		# is a no-op, so every round after the first would silently skip its kick.
		anim.play(SHOOT_RECOIL)
		anim.seek(0.0, true)
		muzzle.emit()
		await get_tree().create_timer(BURST_CADENCE).timeout
	_play(AIM_HOLD, ACTION_BLEND)
	await get_tree().create_timer(SETTLE_TIME).timeout
	_action = &""
	_play(_stance, STANCE_BLEND)


func _footstep_loop() -> void:
	_stepping = true
	await get_tree().create_timer(FOOTSTEP_OFFSET).timeout
	while _stance == RUN and is_inside_tree():
		footstep.emit()
		await get_tree().create_timer(FOOTSTEP_GAP).timeout
	_stepping = false


func _maybe_start_fidget() -> void:
	# Silently does nothing for a character with no fidget clip, which is every
	# character but the swarm. Same shape as every other clip in this file: the
	# code is written once and the model decides whether it applies.
	if _instant or _fidgeting or anim == null or not anim.has_animation(IDLE_FIDGET):
		return
	_fidget_loop()  # deliberately not awaited: runs until the stance leaves IDLE


func _fidget_loop() -> void:
	## Slips an idle variation in at random intervals. Not awaited by anything —
	## a fidget is scenery, and no game state may ever depend on one.
	##
	## Played through anim.play directly rather than through play_action, and that
	## is the whole design. play_action sets `_action`, which makes set_stance
	## record-but-not-play until the one-shot finishes — correct for a reload,
	## disastrous here, because IDLE is the default stance and a 6-second fidget
	## would routinely be in flight when a move order arrives. The unit would
	## then slide to its destination still convulsing. Leaving `_action` empty
	## means any real stance change cuts the fidget off mid-frame and wins, which
	## is exactly the priority a decoration should have.
	_fidgeting = true
	while _stance == IDLE and is_inside_tree():
		await get_tree().create_timer(
			randf_range(FIDGET_GAP_MIN, FIDGET_GAP_MAX)).timeout
		# Nothing from before the wait may be trusted: whole turns pass in it.
		if not is_inside_tree() or _stance != IDLE:
			break
		if _action != &"":
			continue  # a real one-shot owns the body; try again after the next gap
		anim.play(IDLE_FIDGET, STANCE_BLEND)
		await get_tree().create_timer(
			anim.get_animation(IDLE_FIDGET).length).timeout
		# Hand back only if the fidget is still what is playing. Testing the clip
		# rather than the stance is what makes the interruption safe: if anything
		# took over during those seconds it already called play() itself, and this
		# becomes a no-op instead of yanking the unit back to idle.
		if is_inside_tree() and anim.current_animation == IDLE_FIDGET:
			_play(IDLE, STANCE_BLEND)
	_fidgeting = false


func _play(clip: StringName, blend: float) -> void:
	if anim == null or _instant:
		return
	if anim.current_animation != clip and anim.has_animation(clip):
		# RUN is the only rate-corrected clip. Every other one is a gesture whose
		# authored timing IS the content, and the game already awaits its real
		# length — scaling those would desynchronise animation from turn pacing.
		anim.play(clip, blend, run_speed_scale if clip == RUN else 1.0)
