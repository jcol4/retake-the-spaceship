@tool
class_name WeaponMount
extends Node3D
## Places a weapon from BOTH hands rather than parenting it to one bone.
##
## A BoneAttachment3D on the right hand alone cannot keep a rifle looking held.
## Barrel direction then comes entirely from that one bone's roll, and Mixamo
## clips are separate mocap takes with no rifle in the actor's hand, so wrist
## roll varies between them. Measured on this rig, the barrel swung 43 degrees
## between aim_hold and idle off a mount solved to be exact in aim_hold.
##
## Two hands fix that, because grip-to-handguard is a real and stable feature of
## any rifle-holding pose:
##   * the right hand supplies POSITION,
##   * the vector to the left hand supplies BARREL DIRECTION,
##   * the right hand's +X axis supplies ROLL — measured, not guessed:
##     dot(world_up) = +0.948 in the aim pose against +0.610 for the next best
##     candidate axis (tools/_debug_facing.gd).
##
## The hand gap is NOT constant across clips — 0.468 m in aim_hold, 0.320 m in
## idle, 0.334 m in run. A rigid rifle cannot pin both hands, so the right hand
## wins on position and the left only steers. That lets the left hand slide
## along the handguard by up to ~0.15 m, which is within a handguard's length
## and reads as ordinary handling rather than as a bug.
##
## Because this writes global_transform, it does not matter that Skeleton3D sits
## under a 0.01-scaled Rig node: the child weapon gets unit scale for free, and
## the 100x compensation the old fixed mount needed is gone.

## Skeleton holding the hands. Defaults to this node's parent, which is where a
## mount naturally sits.
@export var skeleton_path: NodePath = ^".."
## Bone the weapon is gripped by. Owns the weapon's position.
@export var grip_bone: StringName = &"RightHand"
## Bone on the handguard. Owns barrel direction only, never position.
@export var steer_bone: StringName = &"LeftHand"
## Which of the grip bone's own axes points "up" out of the weapon. 0/1/2 = X/Y/Z.
@export_range(0, 2) var roll_axis: int = 0:
	set(value):
		roll_axis = value
		_follow()
@export var roll_flip: bool = false:
	set(value):
		roll_flip = value
		_follow()

# The two knobs for tuning by hand. This script is @tool, so dragging either in
# the inspector updates the viewport immediately — scrub the AnimationPlayer to
# whichever clip you are judging and adjust until it sits right. That beats
# posing it in Blender, which cannot see the two-bone solve at all.

## Position nudge, in mount space, applied after the basis is built.
## -Z is down the barrel, +Y is up out of the sights, +X is to the weapon's right.
@export var grip_offset: Vector3 = Vector3.ZERO:
	set(value):
		grip_offset = value
		_follow()
## Orientation nudge in degrees, applied in mount space before grip_offset.
## Z is roll about the barrel, X is pitch, Y is yaw.
@export var grip_rotation: Vector3 = Vector3.ZERO:
	set(value):
		grip_rotation = value
		_follow()

var _skel: Skeleton3D = null
var _grip_idx := -1
var _steer_idx := -1


func _ready() -> void:
	_skel = get_node_or_null(skeleton_path) as Skeleton3D
	if _skel == null:
		push_warning("WeaponMount: no Skeleton3D at %s" % skeleton_path)
		return
	_grip_idx = _skel.find_bone(grip_bone)
	_steer_idx = _skel.find_bone(steer_bone)
	if _grip_idx < 0 or _steer_idx < 0:
		push_warning("WeaponMount: missing bone %s/%s" % [grip_bone, steer_bone])
		_skel = null
		return
	# skeleton_updated rather than _process: it fires after the pose is solved,
	# so the weapon never trails the hands by a frame. That matters beyond
	# looking right — muzzle_origin() feeds the shot VFX, and a stale muzzle puts
	# the tracer where the barrel was last frame.
	_skel.skeleton_updated.connect(_follow)
	_follow()


func _follow() -> void:
	if _skel == null:
		return
	var grip := _skel.global_transform * _skel.get_bone_global_pose(_grip_idx)
	var steer := _skel.global_transform * _skel.get_bone_global_pose(_steer_idx)

	var along := steer.origin - grip.origin
	if along.length_squared() < 0.000001:
		return  # hands coincident: keep the last good pose rather than blow up
	# Godot points -Z forward, so the basis' z column is the barrel reversed.
	var z := -along.normalized()

	var up: Vector3 = grip.basis.orthonormalized()[roll_axis]
	if roll_flip:
		up = -up
	# Gram-Schmidt: strip whatever part of `up` lies along the barrel, so the
	# result is a clean orthonormal basis even when the wrist is rolled.
	up -= z * up.dot(z)
	if up.length_squared() < 0.000001:
		up = Vector3.UP - z * Vector3.UP.dot(z)  # up parallel to barrel; fall back
		if up.length_squared() < 0.000001:
			return
	var y := up.normalized()
	var x := y.cross(z)

	var basis := Basis(x, y, z)
	if grip_rotation != Vector3.ZERO:
		# Composed on the right so the euler reads in the weapon's own frame:
		# Z really is roll about the barrel regardless of where the hand is.
		basis *= Basis.from_euler(Vector3(
			deg_to_rad(grip_rotation.x),
			deg_to_rad(grip_rotation.y),
			deg_to_rad(grip_rotation.z)))
	global_transform = Transform3D(basis, grip.origin + basis * grip_offset)
