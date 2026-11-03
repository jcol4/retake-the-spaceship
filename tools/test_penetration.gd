extends SceneTree
## Bullet penetration and buckshot splash (docs/design/systems/penetration).
##
##   godot --headless --path . --script res://tools/test_penetration.gd
##
## Covers:
##   - the percentile math (brackets, keep per pass) and the roster's values,
##     Penetrator's and FMJ's swapped jobs, Slug replacing the splash;
##   - the traced path: bodies in front, the target, bodies behind, in order;
##     the shooter's own faction and downed units left out; a wall ends it;
##   - reach: a body in front costs a bracket, an armored one two, heavy cover
##     in front is a wall, and buckshot reaches nothing past a body;
##   - resolve: the Battle Rifle's damage chain down a line of Fodder, an
##     armored body spending double, heavy cover behind the target ending the
##     round after the body it protects, the first miss blocking the shot,
##     collateral never critting;
##   - buckshot's half-ring of splash tiles and the splash itself;
##   - fire_at landing collateral damage and describing it in the log.

const PLAYER := "res://scenes/player_unit.tscn"
const SWARM := "res://scenes/swarm_unit.tscn"
const MERC := "res://scenes/merc_unit.tscn"

## The dark hall of worm_test_deck: open floor x 7..32, wall at x 33.
const ROW := 7
const SHOOTER_X := 8

## WeaponPresets.WeaponId / AmmoPresets.AmmoId by value (see test_suppression.gd).
const ASSAULT_RIFLE := 0
const SHOTGUN := 1
const SMG := 2
const LMG := 3
const BATTLE_RIFLE := 4
const PISTOL := 5
const PENETRATOR := 1
const FMJ := 4
const SLUG := 5

var _failures := 0
var _grid: Node
var _pen
var _combat
var _weapons
var _ammo
var _cover


func _initialize() -> void:
	_grid = root.get_node_or_null("GridManager")
	_pen = load("res://scripts/penetration.gd")
	_combat = load("res://scripts/combat.gd")
	_weapons = load("res://scripts/weapon_presets.gd")
	_ammo = load("res://scripts/ammo_presets.gd")
	_cover = load("res://scripts/map_data.gd").Cover
	var map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(map)
	await process_frame
	seed(9191)

	_check_math()
	_check_roster()
	await _check_trace()
	await _check_reach()
	await _check_damage_chain()
	await _check_armored_costs_double()
	await _check_heavy_cover_ends_it()
	await _check_first_miss_blocks()
	await _check_splash()
	await _check_fire_at()

	print("")
	if _failures == 0:
		print("penetration: ALL CHECKS PASSED")
		quit(0)
	else:
		print("penetration: %d CHECK(S) FAILED" % _failures)
		quit(1)


func _check_math() -> void:
	_check(_pen.bodies_for(24) == 0 and _pen.bodies_for(25) == 1 and _pen.bodies_for(80) == 3
		and _pen.bodies_for(100) == 4, "brackets: 24->0, 25->1, 80->3, 100->4")
	_check(absf(_pen.keep_for(25) - 0.5) < 0.001, "pen 25 keeps 50%")
	_check(absf(_pen.keep_for(80) - 3.2 / 4.2) < 0.001, "pen 80 keeps %.3f" % _pen.keep_for(80))
	_check(_pen.keep_for(30) > _pen.keep_for(25), "the unfloored remainder still counts (30 > 25)")


func _check_roster() -> void:
	var pens := {}
	for id in [ASSAULT_RIFLE, SHOTGUN, SMG, LMG, BATTLE_RIFLE, PISTOL]:
		pens[id] = _weapons.make(id).effective_penetration()
	_check(pens[BATTLE_RIFLE] > pens[LMG] and pens[LMG] > pens[ASSAULT_RIFLE]
		and pens[ASSAULT_RIFLE] > pens[SMG] and pens[SMG] >= pens[PISTOL],
		"BR > LMG > AR > SMG >= Pistol (%s)" % pens)
	_check(_pen.bodies_for(pens[SMG]) == 1, "the SMG goes through exactly one body")
	_check(pens[SHOTGUN] == 0 and _weapons.make(SHOTGUN).effective_splash(), "buckshot: no pen, splash")
	var br_pen = _weapons.make(BATTLE_RIFLE, PackedInt32Array(), PENETRATOR)
	_check(br_pen.effective_penetration() == 100, "Penetrator adds 20 (BR -> 100)")
	_check(br_pen.damage_percent(true, 1) == 0, "and no longer touches armor")
	var br_fmj = _weapons.make(BATTLE_RIFLE, PackedInt32Array(), FMJ)
	_check(br_fmj.damage_percent(true, 1) == 34 and br_fmj.effective_accuracy() == 35,
		"FMJ: +34% vs armored, no accuracy bonus")
	var slug = _weapons.make(SHOTGUN, PackedInt32Array(), SLUG)
	_check(not slug.effective_splash() and slug.effective_penetration() == pens[BATTLE_RIFLE],
		"Slug Rounds: no splash, Battle Rifle penetration")


func _check_trace() -> void:
	var shooter = await _shooter(BATTLE_RIFLE)
	var front = await _spawn(SWARM, 10)
	var target = await _spawn(SWARM, 12)
	var ally = await _spawn(PLAYER, 14)
	var downed = await _spawn(SWARM, 16)
	var behind = await _spawn(SWARM, 18)
	downed.take_damage(9999)
	var path: Array = _pen.trace(shooter, target, true)
	var units := path.filter(func(e): return e.has("unit")).map(func(e): return e["unit"])
	_check(units == [front, target, behind],
		"path is front, target, behind; the ally ducks and the downed body is skipped (%d bodies)" % units.size())
	var short: Array = _pen.trace(shooter, target, false)
	_check(short.size() == 2 and short[-1]["unit"] == target, "without past_target it ends at the target")
	_check(_pen.through_penalty(shooter, target) == 30, "one body in front: -30")
	await _free([shooter, front, target, ally, downed, behind])


func _check_reach() -> void:
	var smg = await _shooter(SMG)
	var a = await _spawn(SWARM, 10)
	var b = await _spawn(SWARM, 11)
	var c = await _spawn(SWARM, 12)
	_check(smg.has_shot_at(b), "SMG reaches past one zombie")
	_check(not smg.has_shot_at(c), "but not past two")
	smg._equip(SHOTGUN, PackedInt32Array(), -1)
	_check(smg.has_shot_at(a) and not smg.has_shot_at(b), "buckshot reaches nothing past a body")
	smg._equip(BATTLE_RIFLE, PackedInt32Array(), -1)
	_check(smg.has_shot_at(c), "the Battle Rifle reaches past two")
	# Heavy cover on the body in front is a wall.
	_grid.add_cover_edge(a.grid_pos, 2, _cover.HEAVY, null)  # Side.WEST, facing the shooter
	_check(not smg.has_shot_at(b), "a body in front behind heavy cover blocks the shot")
	_clear_cover(a.grid_pos)
	await _free([smg, a, b, c])


func _check_damage_chain() -> void:
	var shooter = await _shooter(BATTLE_RIFLE)
	var target = await _spawn(SWARM, 10)
	var line := []
	for x in [12, 14, 16, 18]:
		line.append(await _spawn(SWARM, x))
	var full := 0
	var seen_chain := false
	for i in 40:
		var r = _pen.resolve(shooter, target, _combat.ShotAction.SHOOT, _combat.BodyPart.TORSO)
		if not r.hit or r.crit:
			continue
		var dmg := [r.damage]
		for c in r.collateral:
			dmg.append(c.damage if c.hit else -1)
		if dmg == [10, 8, 6, 4]:
			seen_chain = true
		if r.collateral.size() == 3 and r.collateral.all(func(c): return c.hit):
			full += 1
		for c in r.collateral:
			if c.crit:
				_check(false, "collateral never crits")
	_check(seen_chain, "BR down a line of Fodder: 10 -> 8 -> 6 -> 4")
	_check(full > 20, "a BR round goes through three bodies, not four (%d of 40 full lines)" % full)
	await _free([shooter, target] + line)


func _check_armored_costs_double() -> void:
	var shooter = await _shooter(LMG)
	var merc = await _spawn(MERC, 10)
	var behind = await _spawn(SWARM, 12)
	var further = await _spawn(SWARM, 14)
	merc.stats.armored = true  # MercPresets sets it; the bare scene does not
	# LMG 60: the merc is hit free, passing through it costs 50, and the 10 left
	# reaches the next body but cannot pay to pass it. Unarmored, the same round
	# would still have 35 after the first pass and reach a third body.
	var reached_behind := 0
	var reached_further := 0
	for i in 40:
		var r = _pen.resolve(shooter, merc, _combat.ShotAction.SHOOT, _combat.BodyPart.TORSO)
		for c in r.collateral:
			if c.unit == behind:
				reached_behind += 1
			if c.unit == further:
				reached_further += 1
	_check(reached_behind > 20, "an LMG round passes through an armored merc (%d of 40)" % reached_behind)
	_check(reached_further == 0, "but spends 50 doing it and goes no further (%d)" % reached_further)
	merc.stats.armored = false
	reached_further = 0
	for i in 40:
		var r = _pen.resolve(shooter, merc, _combat.ShotAction.SHOOT, _combat.BodyPart.TORSO)
		for c in r.collateral:
			if c.unit == further:
				reached_further += 1
	_check(reached_further > 20, "unarmored, the same round reaches the third body (%d)" % reached_further)
	await _free([shooter, merc, behind, further])


func _check_heavy_cover_ends_it() -> void:
	var shooter = await _shooter(BATTLE_RIFLE)
	var target = await _spawn(SWARM, 10)
	var covered = await _spawn(SWARM, 12)
	var past = await _spawn(SWARM, 14)
	# Indestructible, or forty rounds chew it down to nothing partway through.
	_grid.add_cover_edge(covered.grid_pos, 2, _cover.HEAVY, null).indestructible = true
	var covered_hit := 0
	var past_rolled := 0
	for i in 40:
		var r = _pen.resolve(shooter, target, _combat.ShotAction.SHOOT, _combat.BodyPart.TORSO)
		for c in r.collateral:
			if c.unit == covered and c.hit:
				covered_hit += 1
			if c.unit == past:
				past_rolled += 1
	_check(covered_hit > 0, "the body behind heavy cover can still be hit (%d)" % covered_hit)
	_check(past_rolled == 0, "and the round ends there")
	_clear_cover(covered.grid_pos)
	await _free([shooter, target, covered, past])


func _check_first_miss_blocks() -> void:
	var shooter = await _shooter(BATTLE_RIFLE)
	shooter.stats.perception = -500
	var front = await _spawn(SWARM, 10)
	var target = await _spawn(SWARM, 12)
	var blocked := 0
	var target_rolled := false
	for i in 40:
		var r = _pen.resolve(shooter, target, _combat.ShotAction.SHOOT, _combat.BodyPart.TORSO)
		if r.blocked_by != "":
			blocked += 1
			if r.hit:
				target_rolled = true
	_check(blocked > 30, "a miss on the body in front blocks the shot (%d of 40)" % blocked)
	_check(not target_rolled, "and a blocked shot never hits the target")
	await _free([shooter, front, target])


func _check_splash() -> void:
	var tiles: Array = _pen.splash_tiles(Vector3i(8, 0, ROW), Vector3i(10, 0, ROW))
	var expect := [Vector3i(9, 0, ROW), Vector3i(9, 0, ROW + 1), Vector3i(9, 0, ROW - 1),
		Vector3i(10, 0, ROW + 1), Vector3i(10, 0, ROW - 1)]
	tiles.sort()
	expect.sort()
	_check(tiles == expect, "buckshot splashes front, front diagonals and sides (%s)" % [tiles])
	var diag: Array = _pen.splash_tiles(Vector3i(8, 0, 2), Vector3i(10, 0, 4))
	_check(Vector3i(9, 0, 3) in diag and Vector3i(11, 0, 5) not in diag and diag.size() == 5,
		"from a diagonal, the facing snaps to the diagonal")

	var shooter = await _shooter(SHOTGUN, 9)
	var target = await _spawn(SWARM, 11)
	var side = await _spawn(SWARM, 11, ROW - 1)
	var back = await _spawn(SWARM, 12)
	var splashed := 0
	var back_hit := false
	for i in 40:
		var r = _pen.resolve(shooter, target, _combat.ShotAction.SHOOT, _combat.BodyPart.TORSO)
		for c in r.collateral:
			if c.unit == side and c.hit and c.damage == shooter.stats.weapon.damage_against(false, 2):
				splashed += 1
			if c.unit == back:
				back_hit = true
	_check(splashed > 10, "the side body takes full damage splash (%d)" % splashed)
	_check(not back_hit, "the tile behind the target is spared")
	await _free([shooter, target, side, back])


func _check_fire_at() -> void:
	var shooter = await _shooter(BATTLE_RIFLE)
	var target = await _spawn(SWARM, 10)
	var behind = await _spawn(SWARM, 12)
	var log_seen := false
	var behind_hurt := false
	for i in 20:
		target.current_hp = 999
		behind.current_hp = 999
		shooter.ammo = 99
		var r = await shooter.fire_at(target, _combat.ShotAction.SHOOT)
		if r.hit and not r.collateral.is_empty() and r.collateral[0].hit:
			behind_hurt = behind.current_hp < 999
			log_seen = _combat.describe(r).contains("also:")
			break
	_check(behind_hurt, "fire_at lands the collateral damage")
	_check(log_seen, "and the log line names it")
	await _free([shooter, target, behind])


func _shooter(weapon: int, x: int = SHOOTER_X):
	var u = await _spawn(PLAYER, x)
	u._equip(weapon, PackedInt32Array(), -1)
	u.stats.perception = 99
	u.stats.luck = 0
	return u


func _spawn(scene_path: String, x: int, z: int = ROW):
	var unit = load(scene_path).instantiate()
	unit.position = _grid.grid_to_world(Vector3i(x, 0, z))
	root.add_child(unit)
	await process_frame
	unit.stats.luck = 0
	unit.current_hp = 999
	var t = _grid.get_tile(unit.grid_pos)
	if t:
		t.light_value = 100.0
	return unit


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
