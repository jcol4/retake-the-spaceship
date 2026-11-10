extends SceneTree
## The pistol (tools/build_pistol.py) and the weapon pose families
## (UnitVisual.WEAPON_FAMILIES) it is drawn with.
##   godot --headless --path . --script res://tools/test_pistol_family.gd
##
## Pins: the pistol .glb meets the gun contract every mount reads (a muzzle
## marker down -Z at the barrel tip, a grip_support, the grip at the origin);
## the sidearm maps to that model and to the `pistol` family; and a family pose
## resolves family+cover, rifle cover, family, rifle — so a pistol with no art
## yet still plays every rifle pose, and cover is never lost to a pistol pose.

var _failed := 0


# _initialize, not _init: unit_visual.gd names autoloads (LightingManager...),
# which are only registered by then.
func _initialize() -> void:
	_check_model()
	_check_presets()
	_check_resolution()
	print("FAILED %d" % _failed if _failed else "ALL PASSED")
	quit(1 if _failed else 0)


func _check_model() -> void:
	var path := "res://assets/models/guns/pistol.glb"
	_check(ResourceLoader.exists(path), "pistol.glb exists")
	if not ResourceLoader.exists(path):
		return
	var root := (load(path) as PackedScene).instantiate() as Node3D
	var muzzle := root.find_child("muzzle_flash", true, false) as Node3D
	var support := root.find_child("grip_support", true, false) as Node3D
	_check(muzzle != null, "pistol has a muzzle_flash marker")
	_check(support != null, "pistol has a grip_support")
	if muzzle:
		var at := _to_root(muzzle, root).origin
		# Gun space in Godot: barrel down -Z, top +Y, grip at the origin.
		_check(at.z < -0.18 and at.z > -0.30, "muzzle sits at the barrel tip, -Z (%.3f)" % at.z)
		_check(absf(at.x) < 0.01, "muzzle is on the centreline (%.3f)" % at.x)
	var meshes := root.find_children("*", "MeshInstance3D", true, false)
	_check(meshes.size() >= 1, "pistol has a mesh")
	for node in meshes:
		var mi := node as MeshInstance3D
		if mi.name.begins_with("muzzle_flash"):
			continue
		var box := _to_root(mi, root) * mi.get_aabb()
		_check(box.size.z > 0.18 and box.size.z < 0.30, "pistol is real size, %.3f m long" % box.size.z)
		_check(box.position.y < -0.05, "grip hangs below the origin (%.3f)" % box.position.y)
	root.free()


func _check_presets() -> void:
	var presets: Variant = load("res://scripts/weapon_presets.gd")
	var pistol: int = presets.WeaponId.PISTOL
	_check(presets.gun_model(pistol) == &"pistol", "sidearm draws the pistol model")
	_check(presets.anim_family(pistol) == &"pistol", "sidearm is held in the pistol family")
	_check(presets.anim_family(presets.WeaponId.ASSAULT_RIFLE) == &"", "a rifle has no family")


func _check_resolution() -> void:
	var visual: Node = load("res://scripts/unit_visual.gd").new()
	visual.set("_family", &"pistol")
	visual.set("_cover", &"low")
	_check(visual.call("_bases", &"aim_hold") == [&"aim_hold_pistol_low",
		&"aim_hold_low", &"aim_hold_pistol", &"aim_hold"],
		"pistol in cover: family+cover, cover, family, plain")
	visual.set("_cover", &"")
	_check(visual.call("_bases", &"idle") == [&"idle_pistol", &"idle"],
		"pistol in the open: family, plain")
	visual.set("_family", &"")
	_check(visual.call("_bases", &"idle") == [&"idle"], "rifle in the open: plain")

	_check(visual.call("_timing_pose", &"aim_hold_pistol_low") == &"aim_hold_low",
		"family suffix is stripped for timing")
	_check(visual.call("_authored_duration", &"fire_shoot_pistol")
		== visual.call("_authored_duration", &"fire_shoot"),
		"a family pose plays in its base pose's time")
	_check(visual.call("_authored_duration", &"idle_pistol")
		== visual.call("_authored_duration", &"idle"), "family idle loops in idle's time")

	# Only the poses the model has resolve: with pistol art for `idle` alone,
	# everything else falls through to the rifle.
	visual.set("_family", &"pistol")
	visual.set("_poses", {&"idle": true, &"idle_pistol": true, &"aim_hold": true})
	_check(visual.call("_resolved_base", &"idle") == &"idle_pistol", "authored pistol pose wins")
	_check(visual.call("_resolved_base", &"aim_hold") == &"aim_hold", "missing pistol pose falls back")
	visual.free()


func _to_root(node: Node3D, root: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != root:
		t = (n as Node3D).transform * t
		n = n.get_parent()
	return t


func _check(ok: bool, what: String) -> void:
	print(("  ok  " if ok else "  FAIL ") + what)
	if not ok:
		_failed += 1
