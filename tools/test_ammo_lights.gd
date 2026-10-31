extends SceneTree
## Separate spare magazines, and the model's ammo readout: the primary's bar and
## the spare-magazine pips.
##   godot --headless --path . --script res://tools/test_ammo_lights.gd
##
## Headless builds no model, so this reads what the unit hands UnitVisual, through
## the real shot, reload and weapon-switch paths. Windowed, those same values drive
## the meshes; test_unit_models.gd pins that the exports carry them.
##
## Covers:
##   - a fresh soldier: a full bar, and a full pip per spare magazine;
##   - the colour at every size of magazine in the roster;
##   - spending a round reaches the readout with no other call;
##   - a reload swaps the fullest mag in and puts the old one back, losing nothing;
##   - any swap is allowed, even a worse one, but not with a full gun or dry spares;
##   - a magazine attachment enlarges every spare, keeping the count;
##   - the Shotgun's loose shells still top up from a pool, and read as reloads;
##   - the sidearm keeps its own magazines, and the readout stays on the primary.

const PLAYER := "res://scenes/player_unit.tscn"

## WeaponPresets.WeaponId by value (see test_suppression.gd).
const ASSAULT_RIFLE := 0
const SHOTGUN := 1
const EXTENDED_MAG_NAME := "EXTENDED_MAG"

const PALE_YELLOW := Color(1.0, 0.92, 0.55)
const ORANGE := Color(1.0, 0.48, 0.05)
const RED := Color(1.0, 0.1, 0.05)

var _failures := 0
var _grid: Node


func _initialize() -> void:
	_grid = root.get_node_or_null("GridManager")
	var map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(map)
	await process_frame

	await _check_fresh_soldier()
	_check_colors()
	await _check_spending()
	await _check_reload_swaps()
	await _check_any_swap_allowed()
	await _check_attachment_enlarges()
	await _check_shotgun()
	await _check_sidearm()

	print("")
	if _failures == 0:
		print("ammo lights: ALL CHECKS PASSED")
		quit(0)
	else:
		print("ammo lights: %d CHECK(S) FAILED" % _failures)
		quit(1)


func _check_fresh_soldier() -> void:
	var unit = await _soldier()
	var lights: Dictionary = unit.visual._status_lights
	_check(is_equal_approx(lights.mag, 1.0), "a fresh soldier's bar is full")
	_check(unit.reserve_mags == PackedInt32Array([3, 3, 3, 3, 3]),
		"an Assault Rifle deploys with 5 full spare mags (got %s)" % unit.reserve_mags)
	_check(lights.spare_mags == [1.0, 1.0, 1.0, 1.0, 1.0], "with a full pip for each")
	await _free(unit)


func _check_colors() -> void:
	var visual_script = load("res://scripts/unit_visual.gd")
	# rounds left, magazine size, colour
	for row: Array in [
			[3, 3, PALE_YELLOW], [2, 3, ORANGE], [1, 3, RED],
			[4, 4, PALE_YELLOW], [3, 4, PALE_YELLOW], [2, 4, ORANGE], [1, 4, RED],
			[6, 6, PALE_YELLOW], [5, 6, PALE_YELLOW], [4, 6, ORANGE], [3, 6, ORANGE],
			[2, 6, RED], [1, 6, RED],
			[8, 8, PALE_YELLOW], [6, 8, PALE_YELLOW], [5, 8, ORANGE], [3, 8, ORANGE],
			[2, 8, RED], [1, 8, RED]]:
		var color: Color = visual_script._ammo_color(float(row[0]) / row[1])
		_check(color.is_equal_approx(row[2]), "%d of %d rounds shows %s" % [row[0], row[1], row[2]])


func _check_spending() -> void:
	var unit = await _soldier()
	unit.ammo -= 1
	_check(is_equal_approx(unit.visual._status_lights.mag, 2.0 / 3.0),
		"spending a round shortens the bar")
	unit.ammo = 0
	_check(is_equal_approx(unit.visual._status_lights.mag, 0.0), "an empty magazine empties the bar")
	await _free(unit)


func _check_reload_swaps() -> void:
	var unit = await _soldier()
	unit.ammo = 1
	await unit.do_reload()
	_check(unit.ammo == 3, "a reload loads a full mag (got %d)" % unit.ammo)
	_check(unit.reserve_mags == PackedInt32Array([3, 3, 3, 3, 1]),
		"the 1-round mag goes back on the vest (got %s)" % unit.reserve_mags)
	_check(unit.reserve == 13, "and reserve moves by what the gun gained (got %d)" % unit.reserve)
	_check(is_equal_approx(unit.visual._status_lights.spare_mags[-1], 1.0 / 3.0),
		"its pip reads a third full")

	unit.ammo = 0
	await unit.do_reload()
	_check(unit.reserve_mags == PackedInt32Array([3, 3, 3, 1, 0]),
		"an empty mag stays, sorted last (got %s)" % unit.reserve_mags)
	_check(is_equal_approx(unit.visual._status_lights.spare_mags[-1], 0.0), "with its pip dark")

	unit.ammo = 2
	await unit.do_reload()
	_check(unit.reserve_mags == PackedInt32Array([3, 3, 2, 1, 0]),
		"the fullest is always the one loaded (got %s)" % unit.reserve_mags)
	await _free(unit)


func _check_any_swap_allowed() -> void:
	var unit = await _soldier()
	unit.ammo = 2
	unit.reserve = 1
	_check(unit.reserve_mags == PackedInt32Array([1]), "assigning reserve re-deals the mags")
	_check(unit.can_reload(), "a swap that leaves the gun with less is allowed")
	await unit.do_reload()
	_check(unit.ammo == 1 and unit.reserve_mags == PackedInt32Array([2]),
		"and goes through (%d in the gun, %s spare)" % [unit.ammo, unit.reserve_mags])

	unit.ammo = 3
	_check(not unit.can_reload(), "a full gun cannot reload")
	unit.ammo = 1
	unit.reserve = 0
	_check(not unit.can_reload(), "nor can one whose spares hold nothing")
	unit.reserve = -1
	_check(unit.reserve_mags.is_empty() and unit.can_reload(), "an unlimited reserve has no mags")
	await unit.do_reload()
	_check(unit.ammo == 3 and unit.reserve == -1, "and refills without drawing anything down")
	_check(unit.visual._status_lights.spare_mags.size() == 6, "lighting every pip")
	await _free(unit)


func _check_attachment_enlarges() -> void:
	var unit = await _soldier()
	var attachments = load("res://scripts/attachment_presets.gd")
	unit.call("_equip", ASSAULT_RIFLE,
		PackedInt32Array([attachments.AttachmentId[EXTENDED_MAG_NAME]]), -1)
	_check(unit.ammo == 4 and unit.reserve_mags == PackedInt32Array([4, 4, 4, 4, 4]),
		"an Extended Mag means 5 spares of 4 (got %d, %s)" % [unit.ammo, unit.reserve_mags])
	await _free(unit)


func _check_shotgun() -> void:
	var unit = await _soldier()
	unit.call("_equip", SHOTGUN, PackedInt32Array(), -1)
	_check(unit.reserve == 15 and unit.reserve_mags.is_empty(), "the Shotgun has loose shells, no mags")
	_check(unit.visual._status_lights.spare_mags == [1.0, 1.0, 0.5],
		"reading as 2 reloads and a half (got %s)" % [unit.visual._status_lights.spare_mags])
	unit.ammo = 4
	await unit.do_reload()
	_check(unit.ammo == 6 and unit.reserve == 13, "a reload tops up what it needs from the pool")
	await _free(unit)


func _check_sidearm() -> void:
	var unit = await _soldier()
	unit.ammo = 2
	unit.reserve = 6
	var before: Dictionary = unit.visual._status_lights.duplicate()
	unit.switch_weapon()
	_check(unit.stats.sidearm_drawn, "the fixture really drew the sidearm")
	_check(unit.reserve_mags == PackedInt32Array([8, 8]), "the pistol has its own 2 spares of 8")
	_check(unit.visual._status_lights == before, "drawing the sidearm leaves the readout on the primary")
	unit.ammo = 3
	await unit.do_reload()
	_check(unit.ammo == 8 and unit.reserve_mags == PackedInt32Array([8, 3]), "the pistol swaps mags too")
	_check(unit.visual._status_lights == before, "without touching the primary's readout")
	unit.switch_weapon()
	_check(unit.ammo == 2 and unit.reserve_mags == PackedInt32Array([3, 3]),
		"holstering brings the primary's mags back")
	_check(unit.visual._status_lights == before, "and its readout as it was left")
	await _free(unit)


func _soldier():
	var unit = load(PLAYER).instantiate()
	unit.position = _grid.grid_to_world(Vector3i(7, 0, 6))
	root.add_child(unit)
	await process_frame
	unit.call("_equip", ASSAULT_RIFLE, PackedInt32Array(), -1)
	return unit


func _free(unit) -> void:
	unit.queue_free()
	await process_frame


func _check(ok: bool, what: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		_failures += 1
