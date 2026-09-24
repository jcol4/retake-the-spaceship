extends SceneTree
## The exported character models (tools/export_models.py) against what
## UnitVisual asks of them.
##   godot --headless --path . --script res://tools/test_unit_models.gd
##
## Headless builds no model on a unit (UnitVisual._build_model), so this loads
## the .glb files directly. What it pins is the CONTRACT between the export and
## the game: animations are named after poses, the poses each character is
## played through exist, and the pile layouts hold the worm counts WormUnit's
## tiers are drawn at.

const REQUIRED := {
	&"merc": [&"idle", &"run", &"begin_shoot", &"fire_shoot", &"end_shoot",
		&"downed", &"dead", &"throw_grenade", &"reload", &"idle_low"],
	&"brawler": [&"idle", &"walk", &"melee"],
	&"worm": [&"idle", &"walk", &"melee"],
	&"nest": [&"idle"],
}
## WormUnit.TIER_FLOOR tops, per pile layout.
const PILE_COUNTS := {&"worm_clutch": 5, &"worm_knot": 9, &"worm_tide": 16}

var _failed := 0


func _init() -> void:
	for variant: StringName in REQUIRED:
		var path := "res://assets/models/%s.glb" % variant
		_check(ResourceLoader.exists(path), "%s.glb exists" % variant)
		if not ResourceLoader.exists(path):
			continue
		var root: Node = (load(path) as PackedScene).instantiate()
		var players := root.find_children("*", "AnimationPlayer", true, false)
		_check(players.size() == 1, "%s has one AnimationPlayer" % variant)
		if players.size() == 1:
			var player := players[0] as AnimationPlayer
			for pose: StringName in REQUIRED[variant]:
				_check(player.has_animation(pose), "%s animates `%s`" % [variant, pose])
		_check(not root.find_children("*", "Skeleton3D", true, false).is_empty(),
			"%s is rigged" % variant)
		root.free()

	var merc_flash: Node = (load("res://assets/models/merc.glb") as PackedScene) \
		.instantiate()
	_check(merc_flash.find_child("muzzle_flash", true, false) != null,
		"merc carries the muzzle_flash node the rig light mounts on")
	merc_flash.free()

	var sidecar: Variant = JSON.parse_string(
		FileAccess.get_file_as_string("res://assets/models/merc.json"))
	_check(sidecar is Dictionary and is_equal_approx(
		float(sidecar.get("pose_yaw_degrees", {}).get("run", 0.0)), 90.0),
		"merc's `run` carries its quarter-turn correction")

	for pile: StringName in PILE_COUNTS:
		var layout: Variant = JSON.parse_string(FileAccess.get_file_as_string(
			"res://assets/models/%s.json" % pile))
		_check(layout is Dictionary, "%s layout parses" % pile)
		if not (layout is Dictionary):
			continue
		var instances: Array = layout.get("instances", [])
		_check(instances.size() == PILE_COUNTS[pile],
			"%s holds %d worms (got %d)" % [pile, PILE_COUNTS[pile], instances.size()])
		_check(layout.get("pile_of") == "worm", "%s is a pile of the worm" % pile)
		_check(not ("melee" in layout.get("poses", [])),
			"%s has no melee — a mass tramples by walking" % pile)
		var phases := {}
		for entry: Dictionary in instances:
			phases[snappedf(float(entry.get("phase", 0.0)), 0.01)] = true
		_check(phases.size() == instances.size(),
			"%s's worms are all out of step" % pile)

	print("unit models: %s" % ("ALL CHECKS PASSED" if _failed == 0
		else "%d CHECK(S) FAILED" % _failed))
	quit(1 if _failed else 0)


func _check(ok: bool, what: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		_failed += 1
