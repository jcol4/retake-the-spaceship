extends SceneTree
## The accuracy model (docs/design/systems/accuracy).
##
##   godot --headless --path . --script res://tools/test_accuracy.gd
##
## Covers:
##   - the archetype distance tables: entries, the tail past the end, distance 0,
##     an unknown archetype falling back to the Assault Rifle's;
##   - which table every gun reads: the six roster guns, Slug Rounds swapping the
##     Shotgun onto the Assault Rifle's, and every enemy gun;
##   - the formula: Aim + table, Reflexes no longer in it, Aimed Shot's +15 and
##     zones, Overwatch, the 1-95 clamp;
##   - Defense: the target's own stat, hunkering, cover 25/45, concealment from
##     light and the Thermal Sight ignoring the dark half of it;
##   - melee: Aim + the refit bonus, the target's Defense and hunkering, never
##     cover or concealment;
##   - the presets: recruits, mercs, robots, aliens on the new Aim scale, base
##     Defense where it was decided, the melee refits;
##   - saved soldiers: the "aim" key, and an old Perception mapped onto 55-65.
##
## Classes are load()ed and locals stay untyped, as in test_goap.gd.

const PLAYER := "res://scenes/player_unit.tscn"
const SWARM := "res://scenes/swarm_unit.tscn"

## The dark hall of worm_test_deck: open floor x 7..32 (see test_penetration.gd).
const ROW := 7
const SHOOTER_X := 8
## light_value at which concealment is exactly 0 (30 -> -10 across 0..100).
const NEUTRAL_LIGHT := 75.0

## WeaponPresets.WeaponId / AttachmentId / AmmoId / Combat enums by value.
const ASSAULT_RIFLE := 0
const SHOTGUN := 1
const SMG := 2
const LMG := 3
const BATTLE_RIFLE := 4
const PISTOL := 5
const THERMAL_SIGHT := 8
const SLUG := 5
const SHOOT := 0
const AIMED := 1
const OVERWATCH := 2
const HEAD := 0
const TORSO := 1
const ARM_L := 2

var _failures := 0
var _grid: Node
var _combat
var _weapons
var _arch
var _cover


func _initialize() -> void:
	_grid = root.get_node_or_null("GridManager")
	_combat = load("res://scripts/combat.gd")
	_weapons = load("res://scripts/weapon_presets.gd")
	_arch = load("res://scripts/weapon_archetype.gd")
	_cover = load("res://scripts/map_data.gd").Cover
	var map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(map)
	await process_frame
	seed(5150)

	_check_tables()
	_check_which_table()
	await _check_formula()
	await _check_defense()
	await _check_melee()
	_check_presets()
	_check_saved_soldiers()

	print("")
	if _failures == 0:
		print("accuracy: ALL CHECKS PASSED")
		quit(0)
	else:
		print("accuracy: %d CHECK(S) FAILED" % _failures)
		quit(1)


func _check_tables() -> void:
	var A = _arch.Id
	var ar := [1, 4, 5, 9, 12, 13, 15].map(func(d): return _arch.range_modifier(A.ASSAULT_RIFLE, d))
	_check(ar == [10, 10, 5, 0, 0, -4, -12], "Assault Rifle: +10 close, 0 at 9-12, -4/tile after (%s)" % [ar])
	var sg := [1, 3, 5, 8, 9, 10].map(func(d): return _arch.range_modifier(A.SHOTGUN, d))
	_check(sg == [30, 20, 0, -45, -60, -75], "Shotgun: +30 point-blank, -15/tile past 8 (%s)" % [sg])
	var br := [1, 3, 6, 9, 18, 19, 20].map(func(d): return _arch.range_modifier(A.BATTLE_RIFLE, d))
	_check(br == [-30, -20, 0, 5, 5, 2, -1], "Battle Rifle: -30 point-blank, best 9-18, -3/tile after (%s)" % [br])
	var lmg := [1, 4, 6, 12, 14, 15].map(func(d): return _arch.range_modifier(A.LMG, d))
	_check(lmg == [-20, 0, 5, 5, -3, -7], "LMG: -20 point-blank, +5 from 6 to 12, -4/tile after (%s)" % [lmg])
	var smg := [1, 6, 7, 10, 12].map(func(d): return _arch.range_modifier(A.SMG, d))
	_check(smg == [20, 5, 0, -18, -30], "SMG: +20 close, -6/tile past 10 (%s)" % [smg])
	var pis := [1, 6, 8, 10].map(func(d): return _arch.range_modifier(A.PISTOL, d))
	_check(pis == [15, 0, -16, -32], "Pistol: +15 close, -8/tile past 8 (%s)" % [pis])
	_check(_arch.range_modifier(A.SHOTGUN, 0) == 30, "distance 0 (a shared tile) reads the 1-tile value")
	_check(_arch.range_modifier(99, 15) == _arch.range_modifier(A.ASSAULT_RIFLE, 15),
		"an unknown archetype reads the Assault Rifle's table")


func _check_which_table() -> void:
	var A = _arch.Id
	var expect := {ASSAULT_RIFLE: A.ASSAULT_RIFLE, SHOTGUN: A.SHOTGUN, SMG: A.SMG, LMG: A.LMG,
		BATTLE_RIFLE: A.BATTLE_RIFLE, PISTOL: A.PISTOL}
	var ok := true
	for id in expect:
		var w = _weapons.make(id)
		if w.effective_archetype() != expect[id] or w.effective_accuracy() != 0:
			ok = false
	_check(ok, "each roster gun reads its own archetype's table, with 0 flat aim")
	var slug = _weapons.make(SHOTGUN, PackedInt32Array(), SLUG)
	_check(slug.effective_archetype() == A.ASSAULT_RIFLE and slug.range_modifier(9) == 0,
		"Slug Rounds swap the Shotgun onto the Assault Rifle's table")
	var cerb = load("res://scripts/cerberus_presets.gd")
	var spawn = load("res://scripts/map_data.gd").Spawn
	_check(cerb.make_stats(spawn.AUXILIUM).weapon.archetype == A.LMG, "Auxilium sentry gun: LMG table")
	_check(cerb.make_stats(spawn.LICTOR).weapon.archetype == A.SHOTGUN, "Lictor demolition gun: Shotgun table")
	_check(cerb.make_stats(spawn.SECURUS).weapon.archetype == A.LMG
		and cerb.make_stats(spawn.SAGITTARII).weapon.archetype == A.LMG, "both wrist guns: LMG table")
	_check(load("res://scripts/door_gun_unit.gd").make_stats().weapon.archetype == A.LMG, "door gun: LMG table")
	_check(load("res://scripts/alien_presets.gd").ranged("A").weapon.archetype == A.ASSAULT_RIFLE,
		"ranged alien: Assault Rifle table")


## Aim 60 against an open, neutrally lit target, unless a check says otherwise.
func _check_formula() -> void:
	var shooter = await _shooter(ASSAULT_RIFLE)
	var target = await _spawn(SWARM, SHOOTER_X + 6)
	_check(_acc(shooter, target) == 65, "AR at 6 tiles: Aim 60 + 5 = 65 (%d)" % _acc(shooter, target))
	shooter.stats.reflexes = 99
	_check(_acc(shooter, target) == 65, "Reflexes is no longer in a hit chance")
	shooter.stats.reflexes = 0
	_check(_acc(shooter, target, AIMED, TORSO) == 80, "Aimed torso: +15 (80)")
	_check(_acc(shooter, target, AIMED, ARM_L) == 60, "Aimed limb: +15 - 20 (60)")
	_check(_acc(shooter, target, AIMED, HEAD) == 30, "Aimed head: +15 - 50 (30)")
	_check(_acc(shooter, target, OVERWATCH) == 35, "Overwatch at a minimum reserve: -30, as before (35)")
	shooter.overwatch_reserve = 4
	_check(_acc(shooter, target, OVERWATCH) == 65, "and a full reserve buys it all back (65)")
	shooter.overwatch_reserve = 0
	await _free([target])

	shooter._equip(BATTLE_RIFLE, PackedInt32Array(), -1)
	target = await _spawn(SWARM, SHOOTER_X + 2)
	_check(_acc(shooter, target) == 35, "Battle Rifle at 2 tiles: 60 - 25 = 35 (%d)" % _acc(shooter, target))
	await _free([target])
	target = await _spawn(SWARM, SHOOTER_X + 10)
	_check(_acc(shooter, target) == 65, "Battle Rifle at 10 tiles: 60 + 5 = 65 (%d)" % _acc(shooter, target))
	await _free([target])

	shooter._equip(SHOTGUN, PackedInt32Array(), -1)
	target = await _spawn(SWARM, SHOOTER_X + 2)
	_check(_acc(shooter, target) == 85, "Shotgun at 2 tiles: 60 + 25 = 85 (%d)" % _acc(shooter, target))
	shooter.stats.perception = 87
	_check(_acc(shooter, target) == 95, "capped at 95 (Aim 87 + 25 = 112)")
	shooter.stats.perception = 60
	await _free([target])
	target = await _spawn(SWARM, SHOOTER_X + 9)
	_check(_acc(shooter, target) == 1, "Shotgun at 9 tiles: 60 - 60 floors at 1 (%d)" % _acc(shooter, target))
	await _free([shooter, target])


## The AR at 6 tiles (65 in the open, neutral light) against each Defense source.
func _check_defense() -> void:
	var shooter = await _shooter(ASSAULT_RIFLE)
	var target = await _spawn(SWARM, SHOOTER_X + 6)
	target.stats.defense = 20
	_check(_acc(shooter, target) == 45, "the target's own Defense 20: 45")
	target.stats.defense = 0
	target.hunkered = true
	_check(_acc(shooter, target) == 45, "hunkered: +20 Defense, 45")
	target.hunkered = false
	_grid.add_cover_edge(target.grid_pos, 2, _cover.LIGHT, null).indestructible = true  # WEST, facing the shooter
	_check(_acc(shooter, target) == 40, "behind light cover: +25 Defense, 40 (%d)" % _acc(shooter, target))
	_clear_cover(target.grid_pos)
	_grid.add_cover_edge(target.grid_pos, 2, _cover.HEAVY, null).indestructible = true
	_check(_acc(shooter, target) == 20, "behind heavy cover: +45 Defense, 20 (%d)" % _acc(shooter, target))
	_check(_combat.ranged_defense(shooter, target) == 45, "ranged_defense reports the same 45")
	_clear_cover(target.grid_pos)
	_light(target, 0.0)
	_check(_acc(shooter, target) == 35, "in the dark: +30 concealment, 35 (%d)" % _acc(shooter, target))
	_light(target, 100.0)
	_check(_acc(shooter, target) == 75, "fully lit: -10, 75 (%d)" % _acc(shooter, target))
	shooter._equip(ASSAULT_RIFLE, PackedInt32Array([THERMAL_SIGHT]), -1)
	_light(target, 0.0)
	_check(_acc(shooter, target) == 72, "Thermal in the dark: no concealment, +7 sight, 72 (%d)" % _acc(shooter, target))
	_light(target, 100.0)
	_check(_acc(shooter, target) == 82, "Thermal still takes the lit bonus: 82 (%d)" % _acc(shooter, target))
	await _free([shooter, target])


func _check_melee() -> void:
	var attacker = await _shooter(ASSAULT_RIFLE)
	attacker.stats.melee_base_accuracy = 15
	var target = await _spawn(SWARM, SHOOTER_X + 1)
	_check(_combat.compute_melee_accuracy(attacker, target) == 75, "a soldier's swing: Aim 60 + 15 = 75")
	target.hunkered = true
	_check(_combat.compute_melee_accuracy(attacker, target) == 55, "against a hunkered target: 55")
	target.hunkered = false
	target.stats.defense = 20
	_check(_combat.compute_melee_accuracy(attacker, target) == 55, "against Defense 20: 55")
	target.stats.defense = 0
	_grid.add_cover_edge(target.grid_pos, 2, _cover.HEAVY, null).indestructible = true
	_light(target, 0.0)
	_check(_combat.compute_melee_accuracy(attacker, target) == 75, "cover and the dark do nothing to a swing")
	_clear_cover(target.grid_pos)
	await _free([attacker, target])


func _check_presets() -> void:
	var classes = load("res://scripts/class_presets.gd")
	var in_band := true
	for cls in 4:
		for i in 25:
			var p: int = classes.roll(cls, "R").perception
			if p < 55 or p > 65:
				in_band = false
	_check(in_band, "every class rolls Aim 55-65")
	var mercs = load("res://scripts/merc_presets.gd")
	var merc_band := true
	var vet_band := true
	for i in 25:
		for s in [mercs.rifleman("M"), mercs.support("S")]:
			if s.perception < 55 or s.perception > 65:
				merc_band = false
		var vet: int = mercs.rifleman("V", true).perception
		if vet < 65 or vet > 75:
			vet_band = false
	_check(merc_band, "mercs at parity: Aim 55-65")
	_check(vet_band, "veterans keep their +10: Aim 65-75, under the 87 cap")
	var aliens = load("res://scripts/alien_presets.gd")
	var cerb = load("res://scripts/cerberus_presets.gd")
	var spawn = load("res://scripts/map_data.gd").Spawn
	_check(aliens.hunter("H").defense == 20 and cerb.make_stats(spawn.PROCTOR).defense == 20,
		"Agile Hunter and Proctor: +20 Defense")
	_check(aliens.swarm("F").defense == 0 and cerb.make_stats(spawn.SECURUS).defense == 0
		and mercs.rifleman("M").defense == 0, "everyone else: 0")
	# The melee refit: old odds (capped at 95) minus the new Aim.
	var swing := func(s): return s.perception + s.melee_base_accuracy
	var fodder_ok := true
	var hunter_ok := true
	for i in 25:
		var f: int = swing.call(aliens.swarm("F"))
		var h: int = swing.call(aliens.hunter("H"))
		fodder_ok = fodder_ok and f >= 70 and f <= 80
		hunter_ok = hunter_ok and h >= 80 and h <= 90
	_check(fodder_ok, "a Fodder bite stays ~75% (70-80)")
	_check(hunter_ok, "a Hunter swing ~85% before its ambush (80-90)")
	_check(swing.call(cerb.make_stats(spawn.SECURUS)) == 95, "a Securus swing: 95")


func _check_saved_soldiers() -> void:
	var rec = load("res://scripts/campaign/soldier_record.gd")
	_check(rec.from_dict({"perception": 30}).perception == 55, "an old Perception 30 (Assault floor) loads as Aim 55")
	_check(rec.from_dict({"perception": 90}).perception == 65, "an old 90 (Sniper ceiling) loads as 65")
	_check(rec.from_dict({"perception": 60}).perception == 60, "an old 60 loads as 60")
	_check(rec.from_dict({"aim": 62}).perception == 62, "a new save's \"aim\" is read as it is")
	var d: Dictionary = rec.from_dict({"aim": 62}).to_dict()
	_check(d.get("aim") == 62 and not d.has("perception"), "and saved under \"aim\" only")


func _acc(shooter, target, action: int = SHOOT, part: int = TORSO) -> int:
	return _combat.compute_accuracy(shooter, target, action, part)


func _shooter(weapon: int, x: int = SHOOTER_X):
	var u = await _spawn(PLAYER, x)
	u._equip(weapon, PackedInt32Array(), -1)
	u.stats.perception = 60
	u.stats.reflexes = 0
	u.stats.luck = 0
	u.stats.defense = 0
	return u


func _spawn(scene_path: String, x: int, z: int = ROW):
	var unit = load(scene_path).instantiate()
	unit.position = _grid.grid_to_world(Vector3i(x, 0, z))
	root.add_child(unit)
	await process_frame
	unit.stats.luck = 0
	unit.current_hp = 999
	_light(unit, NEUTRAL_LIGHT)
	return unit


func _light(unit, value: float) -> void:
	var t = _grid.get_tile(unit.grid_pos)
	if t:
		t.light_value = value


func _clear_cover(pos: Vector3i) -> void:
	for p in [pos, pos + Vector3i(-1, 0, 0)]:
		var t = _grid.get_tile(p)
		if t:
			t.cover_edges.clear()


func _free(units: Array) -> void:
	for unit in units:
		if is_instance_valid(unit):
			var t = _grid.get_tile(unit.grid_pos)
			if t and t.occupant == unit:
				_grid.set_occupant(unit.grid_pos, null)
			unit.remove_from_group("units")
			unit.remove_from_group("player_units")
			unit.queue_free()
	await process_frame


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
