extends SceneTree
## Measures which way the model actually faces, and where the two hands sit
## relative to each other, both in the Visual node's local space.
##
## Facing is derived from the feet rather than eyeballed: toes point forward, so
## (ToeBase - Foot) projected to XZ is the model's forward, independent of any
## rotation applied further up the tree. Godot's convention is -Z forward.
##
## The hand pair is the input to a two-bone weapon mount: right hand at the
## grip, left hand on the handguard, so (LeftHand - RightHand) is the barrel
## axis the rifle should lie along.
##
## Defaults measure the soldier through its assembled scene, so the reported
## forward is post-correction and should read ~0 degrees. Point it at a raw GLB
## instead to measure a model BEFORE any scene-level yaw, which is what tells you
## how much correction a new character needs:
##
##   godot --headless --path . --script res://tools/_debug_facing.gd
##   FACING_SCENE=res://assets/swarm_mixamo.glb FACING_MODEL=. \
##     FACING_CLIPS=idle,run,melee godot --headless --path . \
##     --script res://tools/_debug_facing.gd
##
## FACING_MODEL is "." when the scene root is already the model, as it is for a
## bare GLB. Not the empty string: PowerShell deletes an env var assigned "",
## which silently falls back to the default and reports every bone at the
## origin.
##
## The hand block below is only meaningful for a character that holds a weapon in
## both hands; on anything else it is noise, not a finding.

const SETTLE_FRAMES := 3

var _clips: PackedStringArray
var _root: Node3D
var _model: Node3D
var _skel: Skeleton3D
var _anim: AnimationPlayer
var _clip := 0
var _waited := 0


func _env(key: String, fallback: String) -> String:
	return OS.get_environment(key) if OS.has_environment(key) else fallback


func _initialize() -> void:
	var scene := _env("FACING_SCENE", "res://scenes/character_base.tscn")
	# "." means the scene root IS the model — the case when loading a GLB
	# directly, where there is no wrapper node to reach through.
	var model := _env("FACING_MODEL", "soldier")
	_clips = _env("FACING_CLIPS", "aim_hold,idle,run,crouch_idle").split(",")
	_root = load(scene).instantiate()
	root.add_child(_root)
	_model = _root if model.is_empty() else _root.get_node(model)
	_skel = _model.get_node("Rig/Skeleton3D")
	_anim = _model.get_node("AnimationPlayer")
	print("[face] %s  model=%s  clips=%s" % [scene, model, ", ".join(_clips)])
	_start()


func _start() -> void:
	_anim.play(_clips[_clip])
	_anim.seek(0.0, true)
	_waited = 0


func _bone(name: String) -> Vector3:
	# Bone poses are skeleton-local; convert into the Visual node's space so the
	# numbers are directly comparable with the unit's own -Z forward.
	var idx := _skel.find_bone(name)
	var world: Transform3D = _skel.global_transform * _skel.get_bone_global_pose(idx)
	return _root.to_local(world.origin)


func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z).normalized()


func _hand_basis(name: String) -> Basis:
	var idx := _skel.find_bone(name)
	var world: Transform3D = _skel.global_transform * _skel.get_bone_global_pose(idx)
	return (_root.global_transform.affine_inverse() * world).basis.orthonormalized()


func _process(_delta: float) -> bool:
	_waited += 1
	if _waited < SETTLE_FRAMES:
		return false
	var clip: String = _clips[_clip]

	var foot := _bone("LeftFoot")
	var toe := _bone("LeftToeBase")
	var fwd := _flat(toe - foot)
	# Second opinion from the shoulders: right-to-left crossed with up is
	# forward for a figure facing away from its own right-hand side.
	var shoulders := _flat(_bone("LeftArm") - _bone("RightArm"))
	var cross_fwd := _flat(shoulders.cross(Vector3.UP))

	var rh := _bone("RightHand")
	var lh := _bone("LeftHand")
	print("[face] %-12s feet_fwd=(%+.2f,%+.2f) shoulder_fwd=(%+.2f,%+.2f)  yaw_vs_-Z=%+.1f deg"
		% [clip, fwd.x, fwd.z, cross_fwd.x, cross_fwd.z,
			rad_to_deg(atan2(fwd.x, -fwd.z))])
	print("[face]   RightHand=(%+.3f,%+.3f,%+.3f)  LeftHand=(%+.3f,%+.3f,%+.3f)  gap=%.3fm"
		% [rh.x, rh.y, rh.z, lh.x, lh.y, lh.z, (lh - rh).length()])
	var axis := (lh - rh).normalized()
	print("[face]   R->L axis=(%+.2f,%+.2f,%+.2f)  pitch=%+.1f yaw=%+.1f"
		% [axis.x, axis.y, axis.z, rad_to_deg(asin(axis.y)),
			rad_to_deg(atan2(axis.x, -axis.z))])

	# Which of the right hand's own axes best supplies the rifle's "up"? The
	# rifle is roughly level in aim_hold, so the winning axis is the one most
	# aligned with world up once the barrel direction is projected out.
	var hb := _hand_basis("RightHand")
	for pair in [["+x", hb.x], ["-x", -hb.x], ["+y", hb.y],
			["-y", -hb.y], ["+z", hb.z], ["-z", -hb.z]]:
		var v: Vector3 = pair[1]
		var perp := (v - axis * v.dot(axis)).normalized()
		print("[face]     hand %s: dot(world_up)=%+.3f" % [pair[0], perp.dot(Vector3.UP)])

	_clip += 1
	if _clip >= _clips.size():
		return true
	_start()
	return false
