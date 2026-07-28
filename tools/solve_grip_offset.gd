extends SceneTree
## Solves WeaponMount.grip_offset by measuring where the fist actually closes.
##
## The mount currently places the rifle's TRIGGER at the right hand's BONE
## ORIGIN, which sits inside the wrist. A fist closes about 103 mm further out,
## so the weapon hangs off the hand by that much. This computes the offset that
## puts the pistol grip in the fist instead.
##
## WHY THIS RUNS IN GODOT AND NOT IN BLENDER
##
## The same measurement is easier in Blender, and would be wrong. The mount
## builds its basis from the right hand bone's own X axis, and how glTF mapped
## Blender's bone axes into Godot's skeleton is an assumption -- exactly the kind
## that has already been silently wrong twice in this pipeline (pose_bone.tail,
## the armature scale). Measuring inside the frame the mount actually runs in
## removes the conversion entirely.
##
## Method, mirroring tools/measure_grip_pose.py:
##   * grip axis = the knuckle line, index MCP to pinky MCP
##   * per finger, fit a circle through its four joints projected onto the plane
##     perpendicular to that axis -- one fit ACROSS fingers is degenerate,
##     because they separate mainly along the axis
##   * the consensus centre of those circles is where the held object's axis lies
##
## Run (windowed or headless, no rendering needed):
##   godot --headless --path . --script res://tools/solve_grip_offset.gd

# Pistol grip centroid in the rifle's own space, measured off assets/rifle.glb
# and unchanged by the compaction splices (they cut only handguard and stock).
# Blender authored it at (0.0000, -0.0334, -0.0845); Blender (x,y,z) maps to
# Godot (x, z, -y), hence the reordering here.
const GRIP_CENTROID := Vector3(0.0000, -0.0845, 0.0334)

# The right index finger lies EXTENDED along the trigger rather than wrapped, so
# its circle fit describes the trigger reach and not the grip. Middle/ring/pinky
# are the fingers that actually close around it.
const WRAP_FINGERS := ["Middle", "Ring", "Pinky"]

var _elapsed := 0.0
var _done := false


func _initialize() -> void:
	change_scene_to_file.call_deferred("res://scenes/main.tscn")


func _fit_circle(pts: Array) -> Array:
	# Least squares circle: x^2+y^2 = 2*cx*x + 2*cy*y + k is LINEAR in
	# (cx, cy, k), so this closes in form with no starting guess.
	var n := float(pts.size())
	if n < 3.0:
		return [Vector2.ZERO, 0.0]
	var sx := 0.0
	var sy := 0.0
	var sxx := 0.0
	var syy := 0.0
	var sxy := 0.0
	var sxz := 0.0
	var syz := 0.0
	var sz := 0.0
	for p: Vector2 in pts:
		var q := p.x * p.x + p.y * p.y
		sx += p.x
		sy += p.y
		sxx += p.x * p.x
		syy += p.y * p.y
		sxy += p.x * p.y
		sxz += p.x * q
		syz += p.y * q
		sz += q
	# Built from COLUMNS (Godot's Basis constructor takes column vectors), so the
	# rows come out as the normal equations above.
	var m := Basis(Vector3(2.0 * sxx, 2.0 * sxy, 2.0 * sx),
		Vector3(2.0 * sxy, 2.0 * syy, 2.0 * sy),
		Vector3(sx, sy, n))
	if absf(m.determinant()) < 1e-12:
		return [Vector2.ZERO, 0.0]
	var s := m.inverse() * Vector3(sxz, syz, sz)
	var r2: float = s.z + s.x * s.x + s.y * s.y
	return [Vector2(s.x, s.y), sqrt(maxf(r2, 0.0))]


func _bone_pos(skel: Skeleton3D, name: String) -> Vector3:
	var i := skel.find_bone(name)
	if i < 0:
		push_error("missing bone %s" % name)
		return Vector3.ZERO
	return (skel.global_transform * skel.get_bone_global_pose(i)).origin


func _fist_centre(skel: Skeleton3D, side: String) -> Array:
	var idx := _bone_pos(skel, side + "HandIndex1")
	var pky := _bone_pos(skel, side + "HandPinky1")
	var axis := (pky - idx)
	if axis.length() < 1e-6:
		return [Vector3.ZERO, 0.0]
	axis = axis.normalized()
	var u := axis.cross(Vector3.UP)
	if u.length() < 1e-4:
		u = axis.cross(Vector3.RIGHT)
	u = u.normalized()
	var v := axis.cross(u).normalized()

	var centres: Array[Vector3] = []
	var radii: Array[float] = []
	for f in WRAP_FINGERS:
		var joints: Array[Vector3] = []
		for j in range(1, 5):
			joints.append(_bone_pos(skel, "%sHand%s%d" % [side, f, j]))
		var origin := Vector3.ZERO
		for j in joints:
			origin += j
		origin /= float(joints.size())
		var flat: Array[Vector2] = []
		for j in joints:
			flat.append(Vector2((j - origin).dot(u), (j - origin).dot(v)))
		var fit := _fit_circle(flat)
		var c: Vector2 = fit[0]
		centres.append(origin + u * c.x + v * c.y)
		radii.append(fit[1])
	var mean := Vector3.ZERO
	for c in centres:
		mean += c
	mean /= float(centres.size())
	var mean_r := 0.0
	for r in radii:
		mean_r += r
	mean_r /= float(radii.size())
	return [mean, mean_r]


func _process(_delta: float) -> bool:
	_elapsed += _delta
	if _done or _elapsed < 2.0:
		return false
	_done = true

	var units := root.get_tree().get_nodes_in_group("player_units")
	if units.is_empty():
		print("[grip] no player units")
		quit()
		return true
	var unit: Node3D = units[0]
	var skel := unit.get_node_or_null(
		"Visual/soldier/Rig/Skeleton3D") as Skeleton3D
	var mount := unit.get_node_or_null(
		"Visual/soldier/Rig/Skeleton3D/RifleMount") as Node3D
	var ap := unit.get_node_or_null("Visual/soldier/AnimationPlayer") as AnimationPlayer
	if skel == null or mount == null or ap == null:
		print("[grip] skel=%s mount=%s anim=%s" % [skel, mount, ap])
		quit()
		return true

	var clips := ["idle", "run", "aim_hold", "overwatch_hold", "crouch_idle",
		"run_stop", "stand_to_crouch", "crouch_to_stand", "shoot_recoil"]
	print("[grip] pistol grip centroid in weapon space: %s" % GRIP_CENTROID)
	print("[grip] wrap fingers: %s (index excluded: it lies on the trigger)"
		% [WRAP_FINGERS])
	print("")
	print("  clip                grip_offset (x, y, z) mm      radius   fist->wrist")

	var sum_off := Vector3.ZERO
	var offs: Array[Vector3] = []
	for clip in clips:
		if not ap.has_animation(clip):
			print("  %-18s (absent)" % clip)
			continue
		ap.play(clip)
		ap.advance(ap.get_animation(clip).length * 0.5)
		ap.pause()
		# No explicit skeleton flush: get_bone_global_pose() below resolves a
		# dirty pose itself, and Skeleton3D has no force_update_bone_transforms()
		# in 4.7 -- calling it aborted _process after _done was set, which spun
		# the tool forever instead of failing loudly.
		mount.call("_follow")

		var fit := _fist_centre(skel, "Right")
		var fist: Vector3 = fit[0]
		var wrist := _bone_pos(skel, "RightHand")
		var basis := mount.global_transform.basis.orthonormalized()
		# A weapon-local point p lands at wrist + basis * (p + grip_offset), so
		# solving for the grip centroid to land on the fist gives this directly.
		var local_fist := basis.inverse() * (fist - wrist)
		var off := local_fist - GRIP_CENTROID
		offs.append(off)
		sum_off += off
		print("  %-18s (%+7.1f,%+7.1f,%+7.1f)   %5.1f mm   %5.1f mm" % [clip,
			off.x * 1000.0, off.y * 1000.0, off.z * 1000.0,
			float(fit[1]) * 1000.0, (fist - wrist).length() * 1000.0])

	if offs.is_empty():
		quit()
		return true
	var mean := sum_off / float(offs.size())
	var drift := 0.0
	for o in offs:
		drift = maxf(drift, (o - mean).length())
	print("")
	print("  MEAN grip_offset = Vector3(%.4f, %.4f, %.4f)" % [mean.x, mean.y, mean.z])
	print("  spread across clips: %.1f mm" % (drift * 1000.0))
	print("")
	print("  Paste into scenes/character_base.tscn under RifleMount:")
	print("    grip_offset = Vector3(%.4f, %.4f, %.4f)" % [mean.x, mean.y, mean.z])
	quit()
	return true
