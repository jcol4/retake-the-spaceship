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

# Stances persist until something changes them. Actions are one-shots that
# hand back to the current stance when they finish.
const IDLE := &"idle"
const RUN := &"run"
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

# Stand-in durations for the no-model path, matching the real clip lengths
# reported by tools/gen_soldier.py so action pacing is identical whether or not
# an AnimationPlayer is attached. Update these if the clip frame counts change.
const FALLBACK_TIME := {
	# Unlike the rest, this one isn't measured from a clip: melee belongs to the
	# aliens and there is no alien model yet. It's a guess at a lunge-and-recover,
	# to be replaced with the real length once that rig exists.
	MELEE: 0.55,
	RELOAD: 1.20,
	GRENADE: 1.00,
	INTERACT: 1.00,
	HIT_REACT: 0.47,
	DOWNED: 0.80,
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

# Stand-in barrel height for units with no rigged rifle, so their shots still
# leave something shoulder-height rather than the floor.
const FALLBACK_MUZZLE_HEIGHT := 1.4

const STANCE_BLEND := 0.15
const ACTION_BLEND := 0.08

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

var anim: AnimationPlayer = null
var fallback_mesh: Node3D = null
var flashlight: Light3D = null
var muzzle_point: Node3D = null

var _stance: StringName = IDLE
var _action: StringName = &""
var _instant: bool = false
var _stepping: bool = false


func _ready() -> void:
	# Children are ready before their parent, so Unit._ready can rely on these.
	anim = get_node_or_null(anim_path) as AnimationPlayer
	fallback_mesh = get_node_or_null(fallback_mesh_path) as Node3D
	flashlight = get_node_or_null(flashlight_path) as Light3D
	muzzle_point = get_node_or_null(muzzle_path) as Node3D


func setup(instant: bool) -> void:
	_instant = instant
	if anim and not _instant:
		anim.play(IDLE)


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


## Where a shot leaves the weapon, in world space. Falls back to a point above
## the unit for anything with no rigged rifle (the enemy capsule), so callers
## never have to special-case it.
func muzzle_origin() -> Vector3:
	if muzzle_point:
		return muzzle_point.global_position
	return global_position + Vector3(0.0, FALLBACK_MUZZLE_HEIGHT, 0.0)


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


func _play(clip: StringName, blend: float) -> void:
	if anim == null or _instant:
		return
	if anim.current_animation != clip and anim.has_animation(clip):
		anim.play(clip, blend)
