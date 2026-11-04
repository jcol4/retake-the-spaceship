class_name AimModifier
extends SkeletonModifier3D
## The upper body's share of a turn: twists the spine toward where the unit is
## aiming while the legs (UnitVisual's body spring) are still catching up, and
## pitches it onto a target above or below the muzzle. Runs after the animation
## every frame, so every clip keeps playing underneath unchanged; Skeleton3D
## restores the animated pose before the next frame, so nothing accumulates.
##
## UnitVisual owns all the timing and writes the four inputs below. This node
## only knows how to bend a rig by them.
##
## THE GUN. The merc's `weapon` bone is a root bone, not a child of the hand, so
## twisting the spine alone would leave the gun hanging where the clip put it.
## It is carried by exactly the rigid motion the trigger hand went through,
## which keeps it in the hand, and since both hands hang off `chest` (the rig's
## IK-hand bones), the support hand stays on the grip with no IK of its own.

## Upper-body yaw relative to the legs, radians. Positive turns left (+yaw).
var twist := 0.0
## Upper-body pitch, radians. Positive aims up.
var pitch := 0.0
## Extra head and neck yaw on top of the twist: the eyes leading the gun.
var head_lead := 0.0
## World yaw the upper body faces once twisted, which fixes the pitch axis.
var aim_world_yaw := 0.0
## The twist the skeleton is SHOWING: `twist` as of the last modification pass.
## The skeleton applies modifiers later in the frame than UnitVisual sets
## `twist`, so anything that reads the drawn gun this frame needs this one.
var applied_twist := 0.0

## The rig's bones, as `profile` found them. Empty `_twist` means this rig has
## no spine to turn, and `supported` says so to UnitVisual.
var _twist: PackedInt32Array = []
var _twist_weights: PackedFloat32Array = []
var _head: PackedInt32Array = []
var _hand := -1
var _weapon := -1

## Bone names per rig family, most specific first. The merc's rig (shared by the
## civilian, brawler and nest) and Mixamo's. A name matches a bone called exactly
## that, or one ending in `_<name>` or `:<name>`, which covers Mixamo's numbered
## `mixamorig5_` prefixes. Weights sum to 1 so the gun gets the WHOLE twist:
## everything that holds it hangs below the last twist bone.
const PROFILES := [
	{"twist": ["spine_1", "chest"], "weights": [0.4, 0.6],
		"head": ["neck", "head"], "hand": "hand.R", "weapon": "weapon"},
	{"twist": ["Spine", "Spine1", "Spine2"], "weights": [0.3, 0.3, 0.4],
		"head": ["Neck", "Head"], "hand": "RightHand", "weapon": ""},
]


## Binds to `skeleton`'s bones. False when no profile fits, in which case the
## modifier does nothing and the caller should not count on any twist.
func bind(skeleton: Skeleton3D) -> bool:
	_twist.clear()
	_twist_weights.clear()
	_head.clear()
	_hand = -1
	_weapon = -1
	for p: Dictionary in PROFILES:
		var ids := PackedInt32Array()
		for bone_name: String in p["twist"]:
			var b := _find(skeleton, bone_name)
			if b < 0:
				break
			ids.append(b)
		if ids.size() != (p["twist"] as Array).size():
			continue
		_twist = ids
		_twist_weights = PackedFloat32Array(p["weights"])
		for bone_name: String in p["head"]:
			var b := _find(skeleton, bone_name)
			if b >= 0:
				_head.append(b)
		_hand = _find(skeleton, p["hand"])
		_weapon = _find(skeleton, p["weapon"]) if p["weapon"] != "" else -1
		return true
	return false


func supported() -> bool:
	return not _twist.is_empty()


static func _find(skeleton: Skeleton3D, bone_name: String) -> int:
	var exact := skeleton.find_bone(bone_name)
	if exact >= 0:
		return exact
	for i in skeleton.get_bone_count():
		var bone := skeleton.get_bone_name(i)
		if bone.ends_with("_" + bone_name) or bone.ends_with(":" + bone_name):
			return i
	return -1


func _process_modification() -> void:
	var skel := get_skeleton()
	applied_twist = 0.0
	if skel == null or _twist.is_empty():
		return
	applied_twist = twist
	if absf(twist) < 0.0001 and absf(pitch) < 0.0001 and absf(head_lead) < 0.0001:
		return
	var to_skel := skel.global_transform.basis.orthonormalized().inverse()
	var up := (to_skel * Vector3.UP).normalized()
	var right := (to_skel * Vector3(cos(aim_world_yaw), 0.0, -sin(aim_world_yaw))).normalized()
	var hand_before := skel.get_bone_global_pose(_hand) if _hand >= 0 else Transform3D()
	var weapon_before := skel.get_bone_global_pose(_weapon) if _weapon >= 0 else Transform3D()
	# Yaw first, then pitch about the axis the yaw left the chest facing across.
	for i in _twist.size():
		_rotate(skel, _twist[i], up, twist * _twist_weights[i])
	for i in _twist.size():
		_rotate(skel, _twist[i], right, pitch * _twist_weights[i])
	for b in _head:
		_rotate(skel, b, up, head_lead / float(_head.size()))
	if _weapon >= 0 and _hand >= 0:
		var carried := skel.get_bone_global_pose(_hand) * hand_before.affine_inverse() * weapon_before
		var parent := skel.get_bone_parent(_weapon)
		var local := skel.get_bone_global_pose(parent).affine_inverse() * carried if parent >= 0 else carried
		skel.set_bone_pose_position(_weapon, local.origin)
		skel.set_bone_pose_rotation(_weapon, local.basis.get_rotation_quaternion())


## Turns bone `b` by `angle` about `axis` (skeleton space, through the bone's own
## head), by pre-multiplying its local rotation with that axis seen from its
## parent: G' = R * G  =>  L' = (P^-1 R P) * L.
static func _rotate(skel: Skeleton3D, b: int, axis: Vector3, angle: float) -> void:
	if absf(angle) < 0.00001:
		return
	var parent := skel.get_bone_parent(b)
	var pb := skel.get_bone_global_pose(parent).basis.orthonormalized() if parent >= 0 else Basis()
	var local_axis := (pb.inverse() * axis).normalized()
	skel.set_bone_pose_rotation(b,
		(Quaternion(local_axis, angle) * skel.get_bone_pose_rotation(b)).normalized())
