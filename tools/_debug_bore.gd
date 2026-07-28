extends SceneTree
## Measures how far the BORE points off the target the unit is shooting at.
##
## The tracer in unit.gd runs muzzle_origin() -> target.global_position, which is
## a straight line by construction. It still reads as diagonal on screen, and the
## reason is that nothing in the pipeline ever aims the BARREL: face_toward yaws
## the whole unit, AimPitch tilts the spine vertically, and the barrel direction
## itself is whatever the mocap clip's hand-to-hand vector happens to be. So the
## line is straight but leaves the muzzle sideways instead of down the bore.
##
## This reports, per clip, the angle between the bore (-Z of RifleMount) and the
## direction to a target 6 m dead ahead, split into the two components that have
## different fixes:
##
##   AZIMUTH   horizontal. Nothing corrects this at all today.
##   ELEVATION vertical. AimPitch is supposed to, so a residual here means it is
##             aiming the SPINE at the target rather than the BORE.
##
##   godot --headless --path . --script res://tools/_debug_bore.gd

const CLIPS := ["aim_hold", "shoot_recoil", "overwatch_hold", "idle"]
const RANGE := 6.0

var _elapsed := 0.0
var _done := false


func _initialize() -> void:
	change_scene_to_file.call_deferred("res://scenes/main.tscn")


func _process(_delta: float) -> bool:
	_elapsed += _delta
	if _done or _elapsed < 2.0:
		return false
	_done = true

	var units := root.get_tree().get_nodes_in_group("player_units")
	if units.is_empty():
		print("[bore] no player units")
		quit()
		return true
	var unit: Node3D = units[0]
	var vis: Node = unit.get_node_or_null("Visual")
	var skel_path := "Visual/soldier/Rig/Skeleton3D/"
	var mount := unit.get_node_or_null(skel_path + "RifleMount") as Node3D
	var pitch := unit.get_node_or_null(skel_path + "AimPitch")
	var ap := unit.get_node_or_null("Visual/soldier/AnimationPlayer") as AnimationPlayer
	if mount == null or ap == null:
		print("[bore] mount=%s anim=%s" % [mount, ap])
		quit()
		return true
	var muzzle := mount.find_children("Muzzle", "", true, false)
	var muz: Node3D = muzzle[0] if not muzzle.is_empty() else null

	# Dead ahead of the unit, at chest height: any azimuth error reported below is
	# therefore the weapon's own, not a body-facing error.
	var fwd := -unit.global_transform.basis.z.normalized()
	var target: Vector3 = unit.global_position + fwd * RANGE + Vector3(0.0, 1.2, 0.0)

	print("[bore] target %s, %0.1f m dead ahead at chest height" % [target, RANGE])
	print("")
	print("  clip              azimuth   elevation   total    muzzle offset from bore-line")

	for clip in CLIPS:
		if not ap.has_animation(clip):
			print("  %-16s (absent)" % clip)
			continue
		ap.play(clip)
		ap.advance(ap.get_animation(clip).length * 0.5)
		ap.pause()
		if vis and vis.has_method("set_aim_pitch"):
			vis.call("set_aim_pitch", target)
		if pitch and pitch.has_method("_apply"):
			pitch.call("_apply")
		mount.call("_follow")

		var origin: Vector3 = muz.global_position if muz else mount.global_position
		var bore := -mount.global_transform.basis.z.normalized()
		var want := (target - origin).normalized()

		# Split in the UNIT's frame so azimuth/elevation mean what they say
		# regardless of where the unit happens to be standing.
		var b := unit.global_transform.basis.orthonormalized()
		var lb := b.inverse() * bore
		var lw := b.inverse() * want
		var az := rad_to_deg(atan2(lb.x, -lb.z) - atan2(lw.x, -lw.z))
		var el := rad_to_deg(asin(clampf(lb.y, -1.0, 1.0)) - asin(clampf(lw.y, -1.0, 1.0)))
		var total := rad_to_deg(bore.angle_to(want))
		# How far the drawn tracer starts from where the bore actually points --
		# this is the on-screen "diagonal" in metres at the target.
		var miss := (origin + bore * origin.distance_to(target)).distance_to(target)
		print("  %-16s %+7.1f   %+7.1f    %6.1f    %5.2f m at the target" % [
			clip, az, el, total, miss])

	# WARP TEST. The left hand visibly distorts when the rifle snaps onto target.
	# Aiming rotates Spine2, which is an ancestor of BOTH hands, so it should move
	# them rigidly and leave the hand-to-weapon relationship untouched. This checks
	# that (left wrist position in WEAPON space, aim off vs on) and separately
	# reports how far the spine has to swing per clip -- because if the correction
	# differs a lot between the clips a burst cross-fades through, the torso whips
	# through that difference several times a second, which would read as warping
	# even though no single frame is wrong.
	print("")
	print("[bore] warp test: left wrist in WEAPON space, and spine swing needed")
	print("  clip              wrist off-aim        wrist on-aim         shift   spine")
	var skel2 := unit.get_node_or_null(skel_path.trim_suffix("/")) as Skeleton3D
	var li := skel2.find_bone("LeftHand")
	var si2 := skel2.find_bone("Spine2")
	for clip in CLIPS:
		if not ap.has_animation(clip):
			continue
		var wrist_local := []
		var spine := []
		for aiming in [false, true]:
			ap.play(clip)
			ap.advance(ap.get_animation(clip).length * 0.5)
			ap.pause()
			if aiming and vis and vis.has_method("set_aim_pitch"):
				vis.call("set_aim_pitch", target)
				if pitch and pitch.has_method("_apply"):
					pitch.call("_apply")
			elif vis and vis.has_method("clear_aim_pitch"):
				vis.call("clear_aim_pitch")
			mount.call("_follow")
			var w := (skel2.global_transform
				* skel2.get_bone_global_pose(li)).origin
			wrist_local.append(
				mount.global_transform.affine_inverse() * w)
			spine.append(skel2.get_bone_pose_rotation(si2))
		var a: Vector3 = wrist_local[0]
		var b: Vector3 = wrist_local[1]
		var swing := rad_to_deg(spine[0].angle_to(spine[1]))
		print("  %-16s (%+.3f,%+.3f,%+.3f) (%+.3f,%+.3f,%+.3f) %6.1f mm %6.1f deg" % [
			clip, a.x, a.y, a.z, b.x, b.y, b.z, (b - a).length() * 1000.0, swing])
	if vis and vis.has_method("set_aim_pitch"):
		vis.call("set_aim_pitch", target)

	# GAIN TEST. The proposed fix rotates Spine2 to swing the bore onto target.
	# That only works if bore angle responds ~1:1 to spine angle -- the bore is
	# built from two HANDS, and if the arms absorb part of the rotation (or the
	# rig's Spine2 axes are not the ones assumed) the gain is not 1 and a
	# closed-form correction would under- or over-shoot. Measured, not assumed.
	var skel := unit.get_node_or_null(skel_path.trim_suffix("/")) as Skeleton3D
	var si := skel.find_bone("Spine2")
	print("")
	print("[bore] gain test on aim_hold: rotate Spine2, see how far the bore moves")
	print("  axis   applied   bore moved   gain")
	for axis_name in ["X (pitch)", "Y (yaw)", "Z (roll)"]:
		var axis := Vector3.RIGHT
		if axis_name.begins_with("Y"):
			axis = Vector3.UP
		elif axis_name.begins_with("Z"):
			axis = Vector3.BACK
		ap.play("aim_hold")
		ap.advance(ap.get_animation("aim_hold").length * 0.5)
		ap.pause()
		mount.call("_follow")
		var before := -mount.global_transform.basis.z.normalized()
		var base := skel.get_bone_pose_rotation(si)
		var applied := 10.0
		skel.set_bone_pose_rotation(si,
			base * Quaternion(axis, deg_to_rad(applied)))
		mount.call("_follow")
		var after := -mount.global_transform.basis.z.normalized()
		var moved := rad_to_deg(before.angle_to(after))
		skel.set_bone_pose_rotation(si, base)
		print("  %-10s %5.1f     %6.2f      %5.2f" % [
			axis_name, applied, moved, moved / applied])

	quit()
	return true
