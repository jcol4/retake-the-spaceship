extends SceneTree
## Checks the in-game barrel against the angles tools/gen_soldier.py authored,
## and solves the rifle's mount transform when they disagree.
##
## The mount is a hand-written Transform3D in scenes/character_base.tscn, and a
## hand-derived one was wrong: it put the barrel 8-16 degrees off the authored
## pitch and ~14 degrees off in yaw, which at 5 m throws the muzzle over a metre
## from where the unit is facing. Rather than re-derive the Blender-to-Godot
## axis swap by hand a second time, solve it: in the aim pose the barrel must
## point dead forward with the sights up, so the correct mount basis is simply
## the inverse of the hand bone's basis in that pose.
##
## The measurement has to happen a frame or two AFTER the clip is set: the
## BoneAttachment3D only picks up a new skeleton pose when the skeleton next
## processes, so reading it immediately reports the rest pose and every clip
## measures identical.
##
## Run: godot_console.exe --headless --path <proj> --script res://tools/_debug_aim.gd

const CLIPS := ["aim_hold", "idle", "run", "crouch_idle"]
const SETTLE_FRAMES := 3
## Grip offset down the hand bone, matching GRIP_LOCAL in tools/gen_soldier.py.
const GRIP_OFFSET := Vector3(0.0, 0.055, 0.0)

var _anim: AnimationPlayer
var _mount: Node3D
var _rifle: Node3D
var _clip := 0
var _waited := 0


func _initialize() -> void:
	var vis: Node3D = load("res://scenes/character_base.tscn").instantiate()
	root.add_child(vis)
	_anim = vis.get_node("soldier/AnimationPlayer")
	_mount = vis.get_node("soldier/Rig/Skeleton3D/RifleMount")
	_rifle = vis.get_node("soldier/Rig/Skeleton3D/RifleMount/rifle")
	_start()


func _start() -> void:
	_anim.play(CLIPS[_clip])
	_anim.seek(0.0, true)
	_waited = 0


func _process(_delta: float) -> bool:
	_waited += 1
	if _waited < SETTLE_FRAMES:
		return false
	var clip: String = CLIPS[_clip]
	# Godot -Z is the barrel and +Y is up, so this pitch is directly comparable
	# with the asin(aim.z) that gen_soldier's dump_trajectory prints.
	var dir := -_rifle.global_transform.basis.z.normalized()
	print("[aim] %-12s pitch=%+6.1f  yaw=%+6.1f"
		% [clip, rad_to_deg(asin(dir.y)), rad_to_deg(atan2(dir.x, -dir.z))])
	if clip == "aim_hold":
		# Aim points dead forward in this pose, so the rifle's world basis must
		# come out identity — which makes the correct local basis simply the
		# inverse of the mount's.
		#
		# NOT orthonormalized, unlike the first version of this tool. The Mixamo
		# rig's Rig node carries scale 0.01 and its bones are in centimetres, so
		# the mount's basis has that scale baked in. Orthonormalizing throws it
		# away and the rifle renders at 1/100 size. The raw inverse carries the
		# 100x back, which is exactly the compensation wanted.
		var basis := _mount.global_transform.basis
		var scale := basis.get_scale()
		# The offset lives in the mount's own space, so it has to be expressed in
		# the skeleton's units (centimetres here) rather than metres.
		var fixed := Transform3D(basis.inverse(), GRIP_OFFSET / scale)
		print("[aim] skeleton scale=%s (grip offset %s -> %s)"
			% [scale, GRIP_OFFSET, GRIP_OFFSET / scale])
		print("[aim] mount transform for scenes/character_base.tscn:")
		print("[aim]   transform = %s" % var_to_str(fixed))
	_clip += 1
	if _clip >= CLIPS.size():
		return true
	_start()
	return false
