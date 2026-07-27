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

const SHOOT_SNAP := &"shoot_snap"
const SHOOT_AIMED := &"shoot_aimed"
const RELOAD := &"reload"
const GRENADE := &"throw_grenade"
const INTERACT := &"interact"
const HIT_REACT := &"hit_react"
const DOWNED := &"downed"

# Stand-in durations for the no-model path, matching the real clip lengths
# reported by tools/gen_soldier.py so action pacing is identical whether or not
# an AnimationPlayer is attached. Update these if the clip frame counts change.
const FALLBACK_TIME := {
	SHOOT_SNAP: 0.40,
	SHOOT_AIMED: 0.90,
	RELOAD: 1.20,
	GRENADE: 1.00,
	INTERACT: 1.00,
	HIT_REACT: 0.47,
	DOWNED: 0.80,
}
const DEFAULT_FALLBACK_TIME := 0.4

# Where the shot leaves the barrel within each clip, per tools/gen_soldier.py.
# Driven by a timer rather than an animation method track on purpose: the clips
# come from the imported .glb, so every unit shares those Animation resources
# and inserting tracks into them at runtime would mutate shared state.
const MUZZLE_TIME := {
	SHOOT_SNAP: 0.07,
	SHOOT_AIMED: 0.33,
}

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

var anim: AnimationPlayer = null
var fallback_mesh: Node3D = null
var flashlight: Light3D = null

var _stance: StringName = IDLE
var _action: StringName = &""
var _instant: bool = false
var _stepping: bool = false


func _ready() -> void:
	# Children are ready before their parent, so Unit._ready can rely on these.
	anim = get_node_or_null(anim_path) as AnimationPlayer
	fallback_mesh = get_node_or_null(fallback_mesh_path) as Node3D
	flashlight = get_node_or_null(flashlight_path) as Light3D


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
	if _instant:
		muzzle.emit()
		return
	if anim == null or not anim.has_animation(action):
		# No clip yet: hold for as long as the clip will, so timing-dependent
		# code behaves the same before and after the model exists.
		muzzle.emit()
		if action == DOWNED and fallback_mesh:
			fallback_mesh.visible = false
		await get_tree().create_timer(
			FALLBACK_TIME.get(action, DEFAULT_FALLBACK_TIME)).timeout
		return
	_action = action
	anim.play(action, ACTION_BLEND)
	var muzzle_at: float = MUZZLE_TIME.get(action, -1.0)
	if muzzle_at >= 0.0:
		_muzzle_after(muzzle_at)  # deliberately not awaited: runs alongside
	# Ignore finish signals from anything but the clip we just started.
	while anim.is_playing() and anim.current_animation == action:
		await anim.animation_finished
	_action = &""
	# DOWNED holds its last frame; every other action returns to the stance.
	if action != DOWNED:
		_play(_stance, STANCE_BLEND)


func _footstep_loop() -> void:
	_stepping = true
	await get_tree().create_timer(FOOTSTEP_OFFSET).timeout
	while _stance == RUN and is_inside_tree():
		footstep.emit()
		await get_tree().create_timer(FOOTSTEP_GAP).timeout
	_stepping = false


func _muzzle_after(delay: float) -> void:
	await get_tree().create_timer(delay).timeout
	muzzle.emit()


func _play(clip: StringName, blend: float) -> void:
	if anim == null or _instant:
		return
	if anim.current_animation != clip and anim.has_animation(clip):
		anim.play(clip, blend)
