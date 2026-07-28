@tool
class_name AimPitch
extends Node3D
## Rotates the upper body so the BARREL points at what the unit is shooting.
##
## Rather than a joint-chain IK solve, this rotates the spine bones shared by
## both arms — turning them swings both hands together, and WeaponMount reads the
## barrel direction straight off those hands, so the rifle follows for free. The
## hands therefore stay welded to the weapon no matter how hard this aims:
## measured, the left wrist moves 1.5 mm in weapon space between aiming off and
## fully on. See aim_bones for why the load is spread rather than concentrated.
##
## WHY IT AIMS THE BORE AND NOT THE BONE
##
## This node originally pointed the SPINE BONE at the target, in pitch only. Both
## halves of that were wrong, and the symptom was that tracers left the muzzle at
## a visible diagonal: unit.gd draws them muzzle -> target, so the line is
## straight by construction, but the barrel was not on it.
##
##   * Pitch only. face_toward yaws the BODY at the target, but the bore sits at
##     a large angle to body-forward — it comes from the mocap hand-to-hand
##     vector, and those takes were never aimed at anything of ours. Measured
##     +25.5 deg of azimuth error in aim_hold, and -26.3 in shoot_recoil, so the
##     barrel also swung ~52 deg during a burst.
##   * Aiming the bone. Putting Spine2 on target still leaves the barrel off it
##     by however much the clip holds the rifle away from the chest: +16.7 deg of
##     residual elevation even with the pitch correction working as designed.
##
## Together that missed a target 6 m dead ahead by 2.9 m. Aiming the bore instead
## takes it to 0.3 deg / 0.03 m. tools/_debug_bore.gd reports the whole table.
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
## Used only by the legacy bone-aiming path (see aim_bore).
@export var pitch_axis: Vector3 = Vector3.RIGHT
@export var pitch_flip: bool = false
## Clamped so a target far below or above the shooter doesn't bend the spine
## past what reads as a person aiming rather than contorting.
@export_range(0, 90) var max_pitch_deg: float = 35.0

## Aim the BARREL at the target instead of the spine BONE, and correct yaw as
## well as pitch. See the class docs — with this off, the bore missed a target
## 6 m dead ahead by 2.9 m.
@export var aim_bore: bool = true
## Mount that owns the barrel. Required by aim_bore; it is the only thing that
## knows where the bore points.
@export var mount_path: NodePath = ^"../RifleMount"
## Ceiling on the total bore correction. Beyond this the pose stops reading as a
## person aiming and starts reading as a person dislocating a shoulder; the
## residual is left visible rather than hidden, so it shows up as a slightly
## off-axis tracer instead of as a broken silhouette.
@export_range(0, 90) var max_bore_deg: float = 40.0

## Bones the correction is SPREAD across, root first. Putting it all on one bone
## aims just as accurately — the wrist stays within 1.5 mm of the weapon either
## way — but it shears the mesh at that joint, and the shear travels down the arm
## and shows up as a warping wrist.
##
## The load is real: aim_hold needs 26.8 deg and shoot_recoil 23.4 deg in roughly
## OPPOSITE directions, and play_burst restarts shoot_recoil every BURST_CADENCE,
## so a single joint whips ~50 deg several times a second. Split three ways that
## is ~17 deg per joint, which is inside what a spine bone's weights are painted
## to survive.
@export var aim_bones: Array[StringName] = [&"Spine", &"Spine1", &"Spine2"]

var _skel: Skeleton3D = null
var _mount: Node3D = null
var _bone_idx := -1
var _has_target := false
var _target_pos := Vector3.ZERO
var _busy := false


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
	_mount = get_node_or_null(mount_path) as Node3D
	if aim_bore and _mount == null:
		push_warning("AimPitch: aim_bore needs a WeaponMount at %s" % mount_path)
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
	if _skel == null or not _has_target or _busy:
		return
	if aim_bore and _mount != null:
		# Re-entrancy guard: the reads below force the skeleton to resolve a dirty
		# pose, which can re-emit skeleton_updated and land us back in here.
		_busy = true
		_aim_bore()
		_busy = false
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


## Rotates the aiming bone so the BORE lands on the target.
##
## The shortest-arc rotation is exact here, and a fixed-axis one is not. Both
## hands are descendants of this bone, so the vector between them — which IS the
## bore, see WeaponMount — rotates rigidly with it. Feeding that rotation in
## whole moves the bore exactly onto target, whereas decomposing it onto a single
## chosen axis loses whatever component lies along that axis: measured gains of
## 0.65 (X), 0.91 (Y) and 0.85 (Z) per degree applied, i.e. an undershoot that
## varies with the pose. tools/_debug_bore.gd reproduces those numbers.
##
## Two passes, not one, because the muzzle MOVES as the bone turns, so the
## direction we want changes slightly under us. One pass leaves a small residual
## that grows as the target gets closer; the second pass costs one more bone
## solve and drives it into the noise.
## Applies a WORLD-space rotation to one bone.
##
## Bone pose rotation is stored relative to the PARENT bone and the rest pose, so
## a world rotation has to be conjugated into that frame first.
func _rotate_bone(idx: int, rot: Quaternion, skel_basis: Basis) -> void:
	var parent := _skel.get_bone_parent(idx)
	var m := skel_basis
	if parent >= 0:
		m = m * _skel.get_bone_global_pose(parent).basis.orthonormalized()
	m = m * _skel.get_bone_rest(idx).basis.orthonormalized()
	var local := m.inverse() * Basis(rot) * m
	_skel.set_bone_pose_rotation(idx,
		local.get_rotation_quaternion() * _skel.get_bone_pose_rotation(idx))


func _aim_bore() -> void:
	var skel_basis := _skel.global_transform.basis.orthonormalized()
	# Resolved here rather than cached in _ready so editing aim_bones in the
	# inspector takes effect live, like every other knob on this node.
	var chain: Array[int] = []
	for n in aim_bones:
		var i := _skel.find_bone(n)
		if i >= 0:
			chain.append(i)
	if chain.is_empty():
		chain.append(_bone_idx)
	# Budget, not a per-pass cap: clamping each pass independently would let two
	# passes spend 2 * max_bore_deg. That let a non-aiming pose (idle, bore 84 deg
	# off) correct down to 4.5 deg against a 40 deg limit.
	var budget := deg_to_rad(max_bore_deg)
	for _pass in 2:
		var bore := _mount.call("bore_direction") as Vector3
		var origin := _mount.call("bore_origin") as Vector3
		var want := _target_pos - origin
		if want.length_squared() < 0.000001 or bore.length_squared() < 0.000001:
			return
		want = want.normalized()

		var angle := bore.angle_to(want)
		if angle < 0.0005:
			return
		var axis := bore.cross(want)
		if axis.length_squared() < 1e-12:
			return  # exactly opposed: no unique shortest arc, leave the pose alone
		angle = minf(angle, budget)
		if angle < 0.0005:
			return
		budget -= angle

		# Each bone takes an equal SHARE of the shortest arc. They are nested, so
		# the shares compose down the chain and the bore still lands on target --
		# not exactly, because each share is applied about a world axis fixed at
		# the top of the pass while the earlier bones have already moved things,
		# but that is precisely what the second pass mops up.
		var share := Quaternion.IDENTITY.slerp(
			Quaternion(axis.normalized(), angle), 1.0 / float(chain.size()))
		for idx in chain:
			_rotate_bone(idx, share, skel_basis)
		# The mount caches nothing, but its own transform is now stale; refresh it
		# so pass two (and WeaponMount's own listener) read a consistent pose.
		_mount.call("_follow")
