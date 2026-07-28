@tool
class_name AimPitch
extends Node3D
## Tilts the upper body up/down to aim the barrel at a target above or below
## eye level — floors of different height, a crouched or downed target, etc.
##
## face_toward (unit.gd) only yaws the whole body in the horizontal plane, so
## without this the barrel's vertical angle is whatever the baked aim_hold
## clip happens to hold, regardless of where the target actually is. Rather
## than a joint-chain IK solve, this rotates a single bone shared by both
## arms (Spine2 in the Mixamo rig) — pitching it swings both hands together,
## and WeaponMount reads the barrel direction straight off those hands, so the
## rifle follows for free.
##
## Same skeleton_updated hook WeaponMount uses, connected first (this node
## must sit BEFORE RifleMount under the Skeleton3D in the scene tree) so the
## additive pitch below is baked into the bone pose before WeaponMount reads
## the hand positions for the same frame.

## Skeleton whose bone we pitch. Defaults to this node's parent.
@export var skeleton_path: NodePath = ^".."
## Bone shared by both arms — pitching it tilts the whole upper body,
## and therefore both hands, together.
@export var bone_name: StringName = &"Spine2"
## Local axis the pitch rotates about. Tune in the editor against aim_hold.
@export var pitch_axis: Vector3 = Vector3.RIGHT
@export var pitch_flip: bool = false
## Clamped so a target far below or above the shooter doesn't bend the spine
## past what reads as a person aiming rather than contorting.
@export_range(0, 90) var max_pitch_deg: float = 35.0

var _skel: Skeleton3D = null
var _bone_idx := -1
var _has_target := false
var _target_pos := Vector3.ZERO


func _ready() -> void:
	_skel = get_node_or_null(skeleton_path) as Skeleton3D
	if _skel == null:
		push_warning("AimPitch: no Skeleton3D at %s" % skeleton_path)
		return
	_bone_idx = _skel.find_bone(bone_name)
	if _bone_idx < 0:
		push_warning("AimPitch: missing bone %s" % bone_name)
		_skel = null
		return
	_skel.skeleton_updated.connect(_apply)


## World point to aim the barrel at. Persists across frames (and animation
## changes) until clear_aim is called — callers drive this for as long as the
## shot/aim should hold the pose.
func aim_at(world_pos: Vector3) -> void:
	_target_pos = world_pos
	_has_target = true


func clear_aim() -> void:
	_has_target = false


func _apply() -> void:
	if _skel == null or not _has_target:
		return
	var bone_global := _skel.global_transform * _skel.get_bone_global_pose(_bone_idx)
	var to_target := _target_pos - bone_global.origin
	var horiz := Vector2(to_target.x, to_target.z).length()
	if horiz < 0.001:
		return
	var angle := atan2(to_target.y, horiz)
	angle = clampf(angle, -deg_to_rad(max_pitch_deg), deg_to_rad(max_pitch_deg))
	if pitch_flip:
		angle = -angle
	var base_rot := _skel.get_bone_pose_rotation(_bone_idx)
	var additive := Quaternion(pitch_axis.normalized(), angle)
	_skel.set_bone_pose_rotation(_bone_idx, base_rot * additive)
