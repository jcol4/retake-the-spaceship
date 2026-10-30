extends SceneTree
## Extraction plan Phase 2.3 and 2.5: carrying a body and the pistol it forces
## (GDD §4.4, §4.3), plus the two Phase 1 fixes that ride along with Phase 2.
##
##   godot --headless --path . --script res://tools/test_carry.gd
##
## Covers:
##   - pick up (2 AP flat, reach, any owner's body) and drop (free);
##   - the body follows its carrier tile by tile, holding no tile of its own;
##   - it drops automatically when the carrier goes down;
##   - while carrying: the pistol's stats, magazine and reserve; no Suppress;
##     Reload reloads the pistol; the primary's rounds come back on the drop;
##   - fire at a carrier: ~25% of landed hits go into a downed body in the open
##     (seeded loop, through the real fire_at), 0% when the carrier is in cover
##     from the shot, and never into a corpse;
##   - a carried corpse extracts with its carrier, and the result marks it as a
##     recovered body rather than a survivor;
##   - Phase 1 fixes: discovery fires per TILE walked (Unit.stepped), and a landed
##     ship's pad is impassable with anyone on it moved off.

const PLAYER := "res://scenes/player_unit.tscn"
const MERC := "res://scenes/merc_unit.tscn"
const DECK := "res://maps/extraction_test.txt"

const ANCHOR := Vector3i(7, 0, 6)

## UnitStats.Action / WeaponPresets.WeaponId by value (see test_suppression.gd).
const ACTION_PICK_UP := 8
const ASSAULT_RIFLE := 0
const PISTOL := 5

var _failures := 0
var _grid: Node
var _em: Node
var LIFE
var _combat
var _weapons


func _initialize() -> void:
	_grid = root.get_node_or_null("GridManager")
	_em = root.get_node_or_null("ExtractionManager")
	LIFE = load("res://scripts/unit.gd").LifeState
	_combat = load("res://scripts/combat.gd")
	_weapons = load("res://scripts/weapon_presets.gd")
	var map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(map)
	await process_frame
	seed(4242)

	await _check_pick_up_and_drop()
	await _check_body_follows_carrier()
	await _check_auto_drop_on_down()
	await _check_pistol_while_carrying()
	await _check_redirect_rate_in_the_open()
	await _check_no_redirect_in_cover()
	await _check_corpse_takes_nothing()
	await _check_cross_owner_carry()
	await _check_carried_corpse_extracts()
	await _check_discovery_per_tile()
	await _check_landed_pad_is_blocked()

	print("")
	if _failures == 0:
		print("carry: ALL CHECKS PASSED")
		quit(0)
	else:
		print("carry: %d CHECK(S) FAILED" % _failures)
		quit(1)


func _check_pick_up_and_drop() -> void:
	var carrier = await _spawn(PLAYER, ANCHOR)
	var body = await _spawn(PLAYER, ANCHOR + Vector3i(1, 0, 0))
	var far = await _spawn(PLAYER, ANCHOR + Vector3i(4, 0, 0))
	body.take_damage(9999)
	_check(carrier.action_cost(ACTION_PICK_UP) == 2, "pick up is 2 AP flat")
	_check(far.pick_up_blocker(body) == "out of reach", "and needs reach")
	carrier.ap = 10
	await carrier.try_pick_up(body)
	_check(carrier.carrying == body and body.carried_by == carrier, "try_pick_up links carrier and body")
	_check(carrier.ap == 8, "for 2 AP (%d left)" % carrier.ap)
	_check(body.grid_pos == carrier.grid_pos, "the body shares the carrier's tile")
	_check(not body.visible, "and is hidden (placeholder)")
	_check(carrier._carry_marker != null and carrier._carry_marker.visible, "the carrier shows a carry marker")
	_check(carrier.pick_up_blocker(far) != "", "nobody carries two")
	carrier.ap = 0
	await carrier.try_drop()
	_check(carrier.carrying == null and body.carried_by == null, "drop is free (at 0 AP) and unlinks")
	_check(body.visible and body.grid_pos == carrier.grid_pos, "the body is back, on the carrier's tile")
	_check(_grid.get_tile(carrier.grid_pos).occupant == carrier, "and the carrier still holds the tile")
	_free([carrier, body, far])


func _check_body_follows_carrier() -> void:
	var carrier = await _spawn(PLAYER, ANCHOR)
	var body = await _spawn(PLAYER, ANCHOR + Vector3i(0, 0, 1))
	body.take_damage(9999)
	carrier.pick_up(body)
	var steps := [0]
	carrier.stepped.connect(func(_u) -> void: steps[0] += 1)
	var trail: Array[Vector3i] = [ANCHOR + Vector3i(1, 0, 0), ANCHOR + Vector3i(1, 0, -1), ANCHOR + Vector3i(0, 0, -2)]
	var seen := []
	carrier.stepped.connect(func(_u) -> void: seen.append(body.grid_pos == carrier.grid_pos))
	await carrier.move_along(trail)
	_check(steps[0] == 3, "stepped fires once per tile (%d)" % steps[0])
	_check(seen.size() == 3 and not seen.has(false), "the body is on the carrier's tile at every step")
	_check(body.grid_pos == trail[-1], "and ends where the carrier ends (%s)" % body.grid_pos)
	_check(_grid.get_tile(trail[-1]).occupant == carrier, "holding no tile of its own")
	_check(_grid.is_free(ANCHOR + Vector3i(0, 0, 1)), "nor leaving one behind")
	_free([carrier, body])


func _check_auto_drop_on_down() -> void:
	var carrier = await _spawn(PLAYER, ANCHOR)
	var body = await _spawn(PLAYER, ANCHOR + Vector3i(1, 0, 0))
	body.take_damage(9999)
	carrier.pick_up(body)
	carrier.take_damage(9999)
	_check(carrier.life_state == LIFE.DOWNED, "the carrier goes down")
	_check(body.carried_by == null and carrier.carrying == null, "and the body drops")
	_check(body.grid_pos == carrier.grid_pos and body.visible, "on the carrier's tile, visible")
	_check(not carrier.stats.sidearm_drawn, "the dropped carrier no longer has the pistol out")
	_free([carrier, body])


func _check_pistol_while_carrying() -> void:
	var carrier = await _spawn(PLAYER, ANCHOR)
	var body = await _spawn(PLAYER, ANCHOR + Vector3i(1, 0, 0))
	var target = await _spawn(MERC, ANCHOR + Vector3i(4, 0, 0))
	carrier._equip(ASSAULT_RIFLE, PackedInt32Array(), -1)
	var rifle_mag: int = carrier.ammo
	var rifle_reserve: int = carrier.reserve
	_check(carrier.stats.sidearm != null and carrier.stats.sidearm.id == PISTOL, "every soldier has a pistol")
	_check(carrier.active_weapon().id == ASSAULT_RIFLE, "holstered until needed")
	_check(carrier.can_suppress() or rifle_mag < 3, "the rifle can suppress")
	body.take_damage(9999)
	carrier.pick_up(body)
	_check(carrier.active_weapon().id == PISTOL, "carrying draws the pistol")
	_check(carrier.stats.weapon_base_accuracy == 30 and carrier.stats.weapon_damage == 5
		and carrier.stats.mag_size == 8, "Shoot reads the pistol's numbers (acc 30 / dmg 5 / mag 8)")
	_check(_combat.shot_damage(carrier, target) == 5, "a shot does the pistol's damage")
	_check(carrier.gunfire_noise_radius() == 4, "and makes the pistol's noise")
	_check(carrier.ammo == 8 and carrier.reserve == 16, "with the pistol's own magazine and reserve (%d/%d)" % [carrier.ammo, carrier.reserve])
	_check(carrier.stowed_ammo == rifle_mag and carrier.stowed_reserve == rifle_reserve, "the rifle's rounds are kept aside")
	_check(not carrier.can_suppress(), "no Suppress while carrying, with a full pistol")
	carrier.ap = 20
	await carrier._try_suppress(target)
	_check(carrier.suppressing == null and carrier.ammo == 8 and carrier.ap == 20, "a Suppress order is refused outright")
	carrier.ap = 20
	await carrier._do_shoot(target)
	_check(carrier.ammo == 7, "a shot spends a pistol round (%d)" % carrier.ammo)
	_check(carrier.stowed_ammo == rifle_mag, "not a rifle round")
	carrier.ap = 20
	await carrier.try_reload()
	_check(carrier.ammo == 8 and carrier.reserve == 15, "Reload reloads the pistol (%d/%d)" % [carrier.ammo, carrier.reserve])
	await carrier.try_drop()
	_check(carrier.active_weapon().id == ASSAULT_RIFLE, "dropping the body holsters the pistol")
	_check(carrier.ammo == rifle_mag and carrier.reserve == rifle_reserve, "and the rifle's rounds are back")
	_check(carrier.stowed_ammo == 8 and carrier.stowed_reserve == 15, "the pistol keeps what it had")
	_free([carrier, body, target])


## The real shot path, in the open: about a quarter of the hits that land go
## into the downed body. Bars are topped up every shot so nobody dies.
func _check_redirect_rate_in_the_open() -> void:
	var carrier = await _spawn(PLAYER, ANCHOR)  # (7,6): no cover facing east
	var body = await _spawn(PLAYER, ANCHOR + Vector3i(0, 0, 1))
	var shooter = await _spawn(PLAYER, ANCHOR + Vector3i(4, 0, 0))
	shooter._equip(ASSAULT_RIFLE, PackedInt32Array(), -1)
	shooter.stats.perception = 99
	body.take_damage(9999)
	carrier.pick_up(body)
	_light([carrier.grid_pos])
	seed(777)
	var hits := 0
	var redirected := 0
	for i in 600:
		carrier.current_hp = carrier.stats.max_hp()
		body.downed_hp = body.downed_bar_max()
		shooter.ammo = 99
		var r = await shooter.fire_at(carrier, _combat.ShotAction.SHOOT)
		if r.hit:
			hits += 1
			if r.hit_carried:
				redirected += 1
	var rate := float(redirected) / maxf(1.0, hits)
	_check(hits > 300, "the shooter lands most shots (%d of 600)" % hits)
	_check(rate > 0.19 and rate < 0.31,
		"about 25%% of landed hits go into the body in the open (%d/%d = %.1f%%)" % [redirected, hits, rate * 100.0])
	# And the pure rule, many more times, for a tighter band.
	var open_result = _combat.ShotResult.new()
	open_result.hit = true
	var n := 0
	for i in 8000:
		if carrier.redirects_hit_to_carried(shooter, open_result):
			n += 1
	_check(absf(n / 8000.0 - 0.25) < 0.02, "redirects_hit_to_carried: %.2f%% over 8000 rolls" % (n / 80.0))
	_free([carrier, body, shooter])


## The test map (worm_test_deck) authors no cover, so a light cover edge is laid
## on the carrier's east side here, and the shooter stands due east of it.
func _check_no_redirect_in_cover() -> void:
	const EAST := 0  # MapData.Side.EAST
	var md = load("res://scripts/map_data.gd")
	var spot := Vector3i(10, 0, 3)
	var carrier = await _spawn(PLAYER, spot)
	var body = await _spawn(PLAYER, spot + Vector3i(0, 0, 1))
	var shooter = await _spawn(PLAYER, spot + Vector3i(4, 0, 0))
	_grid.add_cover_edge(spot, EAST, md.Cover.LIGHT, null)
	body.take_damage(9999)
	carrier.pick_up(body)
	var cover = _combat.defending_cover(shooter.grid_pos, carrier.grid_pos)
	_check(cover[0] == md.Cover.LIGHT, "the carrier is behind light cover from the shooter (tier %d)" % cover[0])
	# The result a landed shot across that edge produces (resolve_shot would also
	# chip the cover; this loop asks the rule, not the cover's durability).
	var r = _combat.ShotResult.new()
	r.hit = true
	r.had_cover = true
	r.cover_type = cover[0]
	r.cover_side = cover[1]
	_check(_combat.target_in_cover(shooter, r), "the shot is one the carrier is in cover from")
	var open = _combat.ShotResult.new()
	open.hit = true
	var flank_n := 0
	for i in 400:
		if carrier.redirects_hit_to_carried(shooter, open):
			flank_n += 1
	_check(flank_n > 0, "the same carrier flanked (no defending edge) can have the body hit (%d/400)" % flank_n)
	var n := 0
	for i in 4000:
		if carrier.redirects_hit_to_carried(shooter, r):
			n += 1
	_check(n == 0, "in cover the body is never hit (%d of 4000)" % n)
	_grid.get_tile(spot).cover_edges.erase(EAST)
	_grid.get_tile(spot + Vector3i(1, 0, 0)).cover_edges.erase(2)  # its WEST twin
	_free([carrier, body, shooter])


func _check_corpse_takes_nothing() -> void:
	var carrier = await _spawn(PLAYER, ANCHOR)
	var corpse = await _spawn(PLAYER, ANCHOR + Vector3i(0, 0, 1))
	var shooter = await _spawn(PLAYER, ANCHOR + Vector3i(4, 0, 0))
	shooter._equip(ASSAULT_RIFLE, PackedInt32Array(), -1)
	shooter.stats.perception = 99
	corpse.take_damage(9999)
	corpse.die()
	_check(corpse.life_state == LIFE.DEAD and corpse.is_carriable(), "a corpse can be carried")
	carrier.pick_up(corpse)
	_light([carrier.grid_pos])
	var open_result = _combat.ShotResult.new()
	open_result.hit = true
	var n := 0
	for i in 2000:
		if carrier.redirects_hit_to_carried(shooter, open_result):
			n += 1
	_check(n == 0, "a carried corpse never takes a redirected hit (%d)" % n)
	var any_redirect := false
	var carrier_hit := 0
	for i in 80:
		carrier.current_hp = carrier.stats.max_hp()
		shooter.ammo = 99
		var r = await shooter.fire_at(carrier, _combat.ShotAction.SHOOT)
		any_redirect = any_redirect or r.hit_carried
		if r.hit:
			carrier_hit += 1
	_check(not any_redirect and carrier_hit > 0, "every landed hit stays on the carrier (%d)" % carrier_hit)
	_check(corpse.downed_hp == corpse.downed_bar_max() or corpse.life_state == LIFE.DEAD, "the corpse is untouched")
	_free([carrier, corpse, shooter])


## GDD §7.6: either player carries either player's soldiers.
func _check_cross_owner_carry() -> void:
	var carrier = await _spawn(PLAYER, ANCHOR)
	var theirs = await _spawn(PLAYER, ANCHOR + Vector3i(1, 0, 1))
	carrier.owner_peer_id = 1
	theirs.owner_peer_id = 2
	theirs.take_damage(9999)
	_check(carrier.pick_up_blocker(theirs) == "", "peer 1's soldier can lift peer 2's")
	carrier.ap = 10
	await carrier.try_pick_up(theirs)
	_check(carrier.carrying == theirs, "and does")
	_check(theirs.owner_peer_id == 2, "and the body is still peer 2's")
	_free([carrier, theirs])


## Plan 2.3 "Done when": a corpse carried to the ship is on the extracted list,
## not the lost one — through the real ExtractionManager.riders_of seam.
func _check_carried_corpse_extracts() -> void:
	var data = load("res://scripts/map_ascii.gd").load_file(DECK)
	var rules = load("res://scripts/extraction_rules.gd").new()
	rules.setup(data.hangars)
	var square_centre: Vector3i = data.hangars[0].square[4]
	var carrier = await _spawn(PLAYER, ANCHOR)
	var corpse = await _spawn(PLAYER, ANCHOR + Vector3i(1, 0, 0))
	var left = await _spawn(PLAYER, ANCHOR + Vector3i(3, 0, 3))
	corpse.take_damage(9999)
	corpse.die()
	carrier.pick_up(corpse)
	carrier.relocate_to(square_centre)
	_check(corpse.grid_pos == square_centre, "the corpse rides into the square")
	_check(_em.riders_of(carrier) == [corpse], "riders_of names what the carrier holds")
	var split: Dictionary = rules.split_passengers(0, [carrier, corpse, left], _em.riders_of)
	_check(corpse in split["extracted"] and not (corpse in split["lost"]), "the carried corpse extracts")
	_check(carrier in split["extracted"] and left in split["lost"], "with its carrier; the soldier outside is lost")
	var result = _em.build_result(split)
	_check(corpse in result.extracted_units and not (corpse in result.lost_units),
		"in the result the corpse's owner is extracted, not lost")
	_check(result.recovered_corpses == [corpse], "and marked as a recovered body")
	_check(not (corpse in result.survivors()) and carrier in result.survivors(), "not as a survivor")
	var back = load("res://scripts/mission_result.gd").from_dict(bytes_to_var(var_to_bytes(result.to_dict())), root)
	_check(back.recovered_corpses == [corpse], "recovered_corpses survives the wire")
	_free([carrier, corpse, left])


## Phase 1 fix: discovery used to need the walk to END in the bay.
func _check_discovery_per_tile() -> void:
	var data = load("res://scripts/map_ascii.gd").load_file(DECK)
	var walker = await _spawn(PLAYER, ANCHOR)
	_em.begin_mission(data)
	_check(not _em.rules.is_discovered(1), "hangar B starts undiscovered")
	# Passing through: one tile of the walk lands in B's bay, and the walk goes on.
	walker.grid_pos = data.hangars[1].bay_cells[0]
	walker.stepped.emit(walker)
	walker.grid_pos = ANCHOR
	_check(_em.rules.is_discovered(1), "a single step through the bay discovers it")
	_em.reset()
	_free([walker])


## Phase 1 fix: a landed ship's pad is impassable, and whoever is on it moves off.
func _check_landed_pad_is_blocked() -> void:
	var data = load("res://scripts/map_ascii.gd").load_file(DECK)
	var pad_centre: Vector3i = data.hangars[0].pad_center  # (3,6) — floor on the test deck too
	var on_pad = await _spawn(PLAYER, pad_centre)
	var body = await _spawn(PLAYER, pad_centre + Vector3i(-1, 0, -1))
	body.take_damage(9999)
	_em.begin_mission(data)
	_em._block_pad(0)
	var pad: Array = data.hangar_pad_cells(pad_centre)
	var all_blocked := true
	for cell in pad:
		var t = _grid.get_tile(cell)
		if t and t.passable:
			all_blocked = false
	_check(all_blocked, "every pad tile is impassable while the ship is down")
	_check(not (on_pad.grid_pos in pad) and _grid.get_tile(on_pad.grid_pos).occupant == on_pad,
		"a soldier on the pad is moved off it (%s), holding the new tile" % on_pad.grid_pos)
	_check(_grid.chebyshev_dist(on_pad.grid_pos, pad_centre) == load("res://scripts/map_data.gd").HANGAR_PAD_RADIUS + 1,
		"to the nearest tile off the pad")
	_check(not (body.grid_pos in pad), "a body on the pad is moved off too (%s)" % body.grid_pos)
	_check(_grid.find_path(on_pad.grid_pos, pad_centre, 99).is_empty(), "nothing can path onto the pad")
	_em._unblock_pad(0)
	var all_open := true
	for cell in pad:
		var t = _grid.get_tile(cell)
		if t and not t.passable:
			all_open = false
	_check(all_open, "and it opens again when the ship leaves")
	_em.reset()
	_free([on_pad, body])


func _light(tiles: Array) -> void:
	for t in tiles:
		var tile = _grid.get_tile(t)
		if tile:
			tile.light_value = 100.0


func _spawn(scene_path: String, at: Vector3i):
	var unit = load(scene_path).instantiate()
	unit.position = _grid.grid_to_world(at)
	root.add_child(unit)
	await process_frame
	return unit


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
