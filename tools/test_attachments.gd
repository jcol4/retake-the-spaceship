extends SceneTree
## Weapon attachments and ammo: each mod lands on the stat it names, stacks by
## the rules in WeaponMod, and reaches Combat through the accessors.
##
##   godot --headless --path . --script res://tools/test_attachments.gd
##
## Ids are read off the loaded preset scripts (`A.HOLO_SIGHT`) rather than
## named as classes — a --script tool is compiled before the class registry
## exists. See test_cerberus.gd.

const PLAYER := "res://scenes/player_unit.tscn"
const MERC := "res://scenes/merc_unit.tscn"
const ANCHOR := Vector3i(7, 0, 6)

var _failures := 0
var _grid: Node
var _weapons
var _attachments
var _ammo
var _stats_script
var _combat
var W  # WeaponPresets.WeaponId
var A  # AttachmentPresets.AttachmentId
var M  # AmmoPresets.AmmoId
var ACT  # UnitStats.Action
var AP  # WeaponData.ApAction


func _initialize() -> void:
	_grid = root.get_node_or_null("GridManager")
	_weapons = load("res://scripts/weapon_presets.gd")
	_attachments = load("res://scripts/attachment_presets.gd")
	_ammo = load("res://scripts/ammo_presets.gd")
	_stats_script = load("res://scripts/unit_stats.gd")
	_combat = load("res://scripts/combat.gd")
	W = _weapons.WeaponId
	A = _attachments.AttachmentId
	M = _ammo.AmmoId
	ACT = _stats_script.Action
	AP = load("res://scripts/weapon_data.gd").ApAction

	_check_bare_weapon_is_unchanged()
	_check_flat_bonuses_stack()
	_check_one_per_slot()
	_check_fit()
	_check_per_action_ap()
	_check_ap_discount_cap()
	_check_damage_percents_add()
	_check_armored_ammo()
	_check_slugs()
	_check_noise_multiplies()
	_check_close_accuracy()
	_check_every_preset_builds()

	var map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(map)
	await process_frame
	await _check_thermal_in_combat()
	await _check_laser_is_seen_further()
	await _check_factions_armored()

	print("")
	if _failures == 0:
		print("attachments: ALL CHECKS PASSED")
		quit(0)
	else:
		print("attachments: %d CHECK(S) FAILED" % _failures)
		quit(1)


func _make(weapon_id: int, attachment_ids: Array = [], ammo_id: int = -1):
	return _weapons.make(weapon_id, PackedInt32Array(attachment_ids), ammo_id)


func _stats_with(weapon):
	var s = _stats_script.new()
	s.reflexes = 50
	s.weapon = weapon
	return s


func _check_bare_weapon_is_unchanged() -> void:
	var w = _make(W.ASSAULT_RIFLE)
	_check(w.effective_accuracy() == w.base_accuracy, "no mods: accuracy is the base")
	_check(w.damage_against(true, 5) == w.damage and w.damage_against(false, 5) == w.damage,
		"no mods: damage is the base against anything")
	_check(w.effective_noise_radius() == 5, "no mods: noise is the old flat 5 tiles")
	for action in AP.values():
		_check(w.ap_modifier(action) == 0, "no mods: no AP change on %s" % AP.keys()[action])


func _check_flat_bonuses_stack() -> void:
	var w = _make(W.ASSAULT_RIFLE, [A.VERTICAL_GRIP, A.MUZZLE_BRAKE, A.EXTENDED_MAG], M.FMJ)
	_check(w.effective_accuracy() == w.base_accuracy + 12,
		"grip + brake + FMJ = +12 accuracy (got %+d)" % (w.effective_accuracy() - w.base_accuracy))
	_check(w.effective_mag_size() == w.mag_size + 1, "extended mag adds 1 round")
	var stats = _stats_with(w)
	_check(stats.weapon_base_accuracy == w.effective_accuracy(),
		"UnitStats.weapon_base_accuracy reads the modded total (what Combat uses)")


func _check_one_per_slot() -> void:
	var w = _make(W.ASSAULT_RIFLE, [A.HOLO_SIGHT, A.THERMAL_SIGHT])
	_check(w.attachments().size() == 1 and w.optic.id == A.THERMAL_SIGHT,
		"two optics leave one fitted, the later one")


func _check_fit() -> void:
	for mag in [A.EXTENDED_MAG, A.DRUM_MAG, A.LIGHT_MAG]:
		_check(_make(W.SHOTGUN, [mag]).magazine == null, "%s doesn't fit the shotgun" % _attachments.DATA[mag]["display_name"])
	for aid in [A.SUPPRESSOR, A.SCOPE, A.LONG_BARREL]:
		_check(_make(W.SHOTGUN, [aid]).attachments().size() == 1, "%s fits the shotgun" % _attachments.DATA[aid]["display_name"])
	_check(_make(W.BATTLE_RIFLE, [A.DRUM_MAG]).magazine != null, "drum mag fits the battle rifle")
	_check(_make(W.ASSAULT_RIFLE, [], M.SLUG).ammo == null, "slugs don't fit a rifle, so it loads standard")
	_check(_make(W.SHOTGUN, [], M.HOLLOW_POINT).ammo == null, "hollow point doesn't fit the shotgun")


func _check_per_action_ap() -> void:
	var bare = _stats_with(_make(W.ASSAULT_RIFLE))
	var scoped = _stats_with(_make(W.ASSAULT_RIFLE, [A.SCOPE]))
	_check(scoped.action_cost(ACT.SHOOT) == bare.action_cost(ACT.SHOOT) - 1, "scope: Shoot -1")
	_check(scoped.action_cost(ACT.OVERWATCH) == bare.action_cost(ACT.OVERWATCH) - 1, "scope: Overwatch -1")
	_check(scoped.action_cost(ACT.SUPPRESS) == bare.action_cost(ACT.SUPPRESS) + 1, "scope: Suppress +1")
	_check(_combat.aimed_shot_ap_cost(0, 50, scoped.aimed_ap_modifier()) == _combat.aimed_shot_ap_cost(0, 50) - 2,
		"scope: Aimed Shot -2")

	var laser = _stats_with(_make(W.ASSAULT_RIFLE, [A.LASER_SIGHT]))
	_check(laser.action_cost(ACT.OVERWATCH) == bare.action_cost(ACT.OVERWATCH),
		"laser sight discounts Shoot only, not Overwatch")
	var light = _stats_with(_make(W.ASSAULT_RIFLE, [A.LIGHT_MAG]))
	_check(light.action_cost(ACT.RELOAD) == bare.action_cost(ACT.RELOAD) - 1, "light mag: Reload -1")
	_check(light.action_cost(ACT.MELEE) == bare.action_cost(ACT.MELEE), "melee doesn't touch the gun")


func _check_ap_discount_cap() -> void:
	# Laser (-1) + Holo (-1) + Ergo (-1) = -3 on Shoot, capped at -2.
	var w = _make(W.ASSAULT_RIFLE, [A.LASER_SIGHT, A.HOLO_SIGHT, A.ERGO_STOCK])
	_check(w.ap_modifier(AP.SHOOT) == -2, "three Shoot discounts cap at -2 (got %d)" % w.ap_modifier(AP.SHOOT))
	# Scope (-2) + Ergo (-1) on Aimed Shot: also capped.
	var aimed = _make(W.ASSAULT_RIFLE, [A.SCOPE, A.ERGO_STOCK])
	_check(aimed.ap_modifier(AP.AIMED) == -2, "scope + ergo on Aimed Shot caps at -2")
	# Increases aren't capped: Long Barrel (+1) + Scope (+1) on Suppress.
	var heavy = _make(W.ASSAULT_RIFLE, [A.LONG_BARREL, A.SCOPE])
	_check(heavy.ap_modifier(AP.SUPPRESS) == 2, "price increases stack uncapped")


func _check_damage_percents_add() -> void:
	# Long Barrel +20% and Hollow Point +50% vs unarmored ADD to +70%.
	var w = _make(W.ASSAULT_RIFLE, [A.LONG_BARREL], M.HOLLOW_POINT)
	_check(w.damage_percent(false, 5) == 70, "long barrel + hollow point = +70%% (got %d)" % w.damage_percent(false, 5))
	_check(w.damage_against(false, 5) == roundi(w.damage * 1.7), "and damage is base x1.7")
	_check(w.effective_damage() == roundi(w.damage * 1.2),
		"with no target in mind, only the unconditional +20% applies")


func _check_armored_ammo() -> void:
	var pen = _make(W.ASSAULT_RIFLE, [], M.PENETRATOR)
	_check(pen.damage_percent(true, 5) == 34 and pen.damage_percent(false, 5) == 0,
		"penetrator: +34% vs armored, nothing vs unarmored")
	var hp = _make(W.ASSAULT_RIFLE, [], M.HOLLOW_POINT)
	_check(hp.damage_percent(true, 5) == -15 and hp.damage_percent(false, 5) == 50,
		"hollow point: -15% vs armored, +50% vs unarmored")


func _check_slugs() -> void:
	var bare = _make(W.SHOTGUN)
	var slug = _make(W.SHOTGUN, [], M.SLUG)
	_check(slug.effective_optimal_range() == bare.optimal_range + 3, "slugs push optimal range out 3 tiles")
	_check(slug.damage_percent(true, 6) == 50 and slug.damage_percent(false, 6) == 25,
		"slugs at range: +50% armored, +25% unarmored")
	_check(slug.damage_percent(true, 4) == 16 and slug.damage_percent(false, 4) == -9,
		"slugs within 4 tiles take -34% on top")
	_check(slug.damage_percent(true, 5) == 50, "and 5 tiles is no longer close")


func _check_noise_multiplies() -> void:
	var w = _make(W.ASSAULT_RIFLE, [A.SUPPRESSOR], M.SUBSONIC)
	_check(w.effective_noise_radius() == roundi(5 * 0.5 * 0.7),
		"suppressor x0.5 and subsonic x0.7 multiply (got %d)" % w.effective_noise_radius())
	_check(_make(W.ASSAULT_RIFLE, [A.LASER_SIGHT]).visibility_multiplier() == 1.5, "laser sight: seen from x1.5")


func _check_close_accuracy() -> void:
	var w = _make(W.ASSAULT_RIFLE, [A.ANGLED_GRIP])
	_check(w.close_accuracy_at(7) == 7, "angled grip: +7 at 7 tiles")
	_check(w.close_accuracy_at(8) == 0, "and nothing at 8")


func _check_every_preset_builds() -> void:
	for aid in _attachments.DATA:
		_check(_attachments.make(aid).display_name != "", "attachment %s builds" % A.keys()[aid])
	for mid in _ammo.DATA:
		_check(_ammo.make(mid).display_name != "", "ammo %s builds" % M.keys()[mid])


func _check_thermal_in_combat() -> void:
	var shooter = await _spawn(PLAYER, ANCHOR)
	var target = await _spawn(MERC, ANCHOR + Vector3i(3, 0, 0))
	shooter.stats.perception = 10
	shooter.stats.reflexes = 0
	_grid.get_tile(target.grid_pos).light_value = 0.0
	shooter.stats.weapon = _make(W.ASSAULT_RIFLE)
	var dark: int = _combat.compute_accuracy(shooter, target, 0)
	shooter.stats.weapon = _make(W.ASSAULT_RIFLE, [A.THERMAL_SIGHT])
	var thermal: int = _combat.compute_accuracy(shooter, target, 0)
	_check(thermal == dark + 7 + _combat.LIGHT_DARK_PENALTY,
		"thermal in the dark: +7 and no darkness penalty (%d -> %d)" % [dark, thermal])
	_free([shooter, target])


func _check_laser_is_seen_further() -> void:
	var soldier = await _spawn(PLAYER, ANCHOR)
	var merc = await _spawn(MERC, ANCHOR + Vector3i(0, 0, 3))
	soldier.stats.weapon = _make(W.ASSAULT_RIFLE, [A.LASER_SIGHT])
	_check(soldier.visibility_multiplier() == 1.5, "a unit with a laser reports x1.5 visibility")
	_check(roundi(merc.detection_range * soldier.visibility_multiplier()) > merc.detection_range,
		"so an enemy's sight reaches further against it")
	_free([soldier, merc])


func _check_factions_armored() -> void:
	var soldier = await _spawn(PLAYER, ANCHOR)
	var merc = await _spawn(MERC, ANCHOR + Vector3i(0, 0, 3))
	# Scene-spawned units skip the presets, so the faction defaults are read
	# straight off them.
	_check(load("res://scripts/class_presets.gd").roll(0, "x").armored, "contractors count as armored")
	_check(load("res://scripts/merc_presets.gd").rifleman("x").armored, "mercs count as armored")
	_check(not load("res://scripts/alien_presets.gd").ranged("x").armored, "aliens don't")
	var cerberus = load("res://scripts/cerberus_presets.gd")
	_check(cerberus.make_stats(cerberus.DATA.keys()[0]).armored, "robots do")
	merc.stats.armored = true
	# The flag is what ammo reads, end to end through Combat.
	soldier.stats.weapon = _make(W.ASSAULT_RIFLE, [], M.HOLLOW_POINT)
	var vs_armored: int = _combat.shot_damage(soldier, merc)
	merc.stats.armored = false
	var vs_unarmored: int = _combat.shot_damage(soldier, merc)
	_check(vs_unarmored > vs_armored, "hollow point hits harder once the target is unarmored (%d vs %d)" % [vs_unarmored, vs_armored])
	_free([soldier, merc])


func _spawn(scene_path: String, at: Vector3i):
	var unit = load(scene_path).instantiate()
	unit.position = _grid.grid_to_world(at)
	root.add_child(unit)
	await process_frame
	return unit


func _free(units: Array) -> void:
	for unit in units:
		if is_instance_valid(unit):
			_grid.set_occupant(unit.grid_pos, null)
			unit.queue_free()


func _check(cond: bool, label: String) -> void:
	if cond:
		print("  PASS  " + label)
	else:
		_failures += 1
		print("  FAIL  " + label)
