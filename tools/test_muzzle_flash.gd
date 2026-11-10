extends SceneTree
## Check the real flash mounting path for empty wrist markers and mesh markers.
## godot --headless --path . --script res://tools/test_muzzle_flash.gd

var _failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var reference_scale := 0.0
	for path: String in ["res://assets/models/guns/lmg.glb",
			"res://assets/models/wrist_guns/wrist_lmg.glb"]:
		var gun := (load(path) as PackedScene).instantiate() as Node3D
		root.add_child(gun)
		# Do not add UnitVisual to the tree: its normal setup builds a unit.
		var visual: Node3D = load("res://scripts/unit_visual.gd").new()
		visual._find_muzzles(gun)
		visual._mount_flash()
		_check(visual._flashes.size() == (2 if "wrist_guns" in path else 1),
			"%s mounts every barrel" % path)
		for i in visual._flashes.size():
			var flash: Node3D = visual._flashes[i]
			var marker: Node3D = visual._muzzles[i]
			_check(flash.global_position.is_equal_approx(marker.global_position),
				"flash starts at the barrel tip")
			if reference_scale == 0.0:
				reference_scale = flash.global_basis.get_scale().x
			_check(absf(flash.global_basis.get_scale().x - reference_scale) < 0.001,
				"wrist and rifle flashes have the same mounting scale")
			for shot in 12:
				flash.fire(0.1)
				var mesh: MeshInstance3D = flash._mesh
				_check(mesh.global_basis.z.normalized().dot(
					marker.global_basis.z.normalized()) > 0.999,
					"flash roll stays aligned with the bore")
				_check(is_equal_approx(mesh.scale.x, MuzzleFlash.SIZE),
					"each round resets to the expected flash size")
		visual.free()
		gun.free()
	print("muzzle flash: %s" % ("ALL CHECKS PASSED" if _failed == 0 else "%d FAILED" % _failed))
	quit(1 if _failed else 0)


func _check(ok: bool, message: String) -> void:
	if not ok:
		push_error(message)
		_failed += 1
