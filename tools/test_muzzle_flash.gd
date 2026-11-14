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
	await _check_muzzle_light()
	print("muzzle flash: %s" % ("ALL CHECKS PASSED" if _failed == 0 else "%d FAILED" % _failed))
	quit(1 if _failed else 0)


## The room-flooding light: a bounded pool of shadowed pulses that go dark and
## hide between rounds, sized per weapon.
func _check_muzzle_light() -> void:
	var vfx: Node3D = load("res://scripts/vfx_manager.gd").new()
	root.add_child(vfx)
	for i in 5:
		vfx.muzzle_light(Vector3(i, 1.4, 0), Vector3.FORWARD, 1.0)
	_check(vfx._muzzle_lights.size() == vfx.MUZZLE_LIGHT_POOL,
		"five shooters at once share the pool of %d" % vfx.MUZZLE_LIGHT_POOL)
	_check(vfx.muzzle_lights_lit() == vfx.MUZZLE_LIGHT_POOL, "every pooled pulse is lit")
	for light: OmniLight3D in vfx._muzzle_lights:
		_check(light.shadow_enabled, "muzzle light casts shadows (walls keep it in the room)")
	var newest: OmniLight3D = vfx._muzzle_lights[(5 - 1) % vfx.MUZZLE_LIGHT_POOL]
	_check(newest.global_position.is_equal_approx(Vector3(4, 1.4 + vfx.MUZZLE_LIGHT_LIFT, -vfx.MUZZLE_LIGHT_AHEAD)),
		"pulse sits ahead of the barrel along the bore")
	await create_timer(vfx.MUZZLE_LIGHT_HOLD + vfx.MUZZLE_LIGHT_FADE + 0.1).timeout
	_check(vfx.muzzle_lights_lit() == 0, "pulses hide once dark (no idle shadow cost)")
	vfx.muzzle_strobe(Vector3.ZERO, 4, 0.11, 1.0)
	_check(vfx.muzzle_lights_lit() == 1, "fogged strobe's first round lights at once")
	await create_timer(0.11 * 3 + 0.03).timeout
	_check(vfx.muzzle_lights_lit() >= 1, "fogged strobe keeps pulsing on cadence")
	await create_timer(vfx.MUZZLE_LIGHT_HOLD + vfx.MUZZLE_LIGHT_FADE + 0.1).timeout
	_check(vfx.muzzle_lights_lit() == 0, "fogged strobe ends dark")
	vfx.free()
	var pistol: WeaponData = WeaponPresets.make(WeaponPresets.WeaponId.PISTOL)
	var lmg: WeaponData = WeaponPresets.make(WeaponPresets.WeaponId.LMG)
	_check(WeaponPresets.muzzle_light(pistol) < WeaponPresets.muzzle_light(lmg),
		"a pistol lights less of the room than an LMG")
	var custom := WeaponData.new()
	custom.muzzle_light = 1.5
	_check(is_equal_approx(WeaponPresets.muzzle_light(custom), 1.5), "WeaponData override wins")
	_check(is_equal_approx(WeaponPresets.muzzle_light(WeaponData.new()), 1.0), "off-roster gun is 1")


func _check(ok: bool, message: String) -> void:
	if not ok:
		push_error(message)
		_failed += 1
