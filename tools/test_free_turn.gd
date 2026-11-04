extends SceneTree
## The free-turn layer (UnitVisual "Free turn", AimModifier): a unit faces any
## angle, the model draws the turn on springs, the gun points where the rules
## say it does once settled, and the rules beam never reads the lag.
##
## Deliberately NOT headless: a headless run builds no model, and every check
## here is about the model. Run it with a window:
##
##   godot --path . --script res://tools/test_free_turn.gd
##
## Scripts are load()ed and locals stay untyped: a --script tool is compiled before
## the class registry and the autoloads exist. See test_cerberus.gd.

const PLAYER := "res://scenes/player_unit.tscn"
## Floor in the deck's open middle room (maps/worm_test_deck.txt).
const ANCHOR := Vector3i(7, 0, 6)
## Seconds of game time that settle every spring with room to spare.
const SETTLE := 1.6
const DEG := PI / 180.0

var _failures := 0
var _grid: Node
var _lighting: Node
var _burst_target := Vector3.ZERO


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		print("free turn: needs a window (see the header)")
		quit(1)
		return
	_grid = root.get_node("GridManager")
	_lighting = root.get_node("LightingManager")
	var map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(map)
	for _i in 3:
		await process_frame
	for node in root.get_tree().get_nodes_in_group("units"):
		_grid.set_occupant(node.grid_pos, null)
		node.remove_from_group("units")
		node.free()
	# Springs run on frame delta, so a faster clock settles them sooner with the
	# same result.
	Engine.time_scale = 4.0

	var unit = await _spawn(PLAYER, ANCHOR)
	var v = unit.visual
	_check(not unit.is_instant(), "the test soldier is drawn (springs run only for a drawn unit)")
	_check(v.can_twist(), "the merc's rig binds an AimModifier")
	await _settle()
	# Frozen on one frame of idle: the idle sways the gun a few degrees, and every
	# check below is about the turn layer, not the clip under it.
	for p in v._players:
		p.pause()

	await _check_small_turn_twists(unit, v)
	await _check_big_turn_moves_feet(unit, v)
	await _check_gun_tracks_any_angle(unit, v)
	await _check_rules_beam_ignores_lag(unit, v)
	await _check_hands_stay_on_gun(unit, v)
	await _check_square_pose(unit, v)
	await _check_pitch(unit, v)
	_check_snap(unit, v)
	await _check_barrel_on_target(unit, v)

	Engine.time_scale = 1.0
	print("")
	if _failures == 0:
		print("free turn: ALL CHECKS PASSED")
		quit(0)
	else:
		print("free turn: %d CHECK(S) FAILED" % _failures)
		quit(1)


## Inside the deadzone the legs hold and the waist takes the turn.
func _check_small_turn_twists(unit, v) -> void:
	var body_before: float = v._body_yaw
	unit.rotation.y += 30.0 * DEG
	await _settle()
	_check(absf(wrapf(v._body_yaw - body_before, -PI, PI)) < 1.0 * DEG,
		"a 30 degree turn leaves the feet where they were")
	_check(absf(v._applied_twist() - 30.0 * DEG) < 1.5 * DEG,
		"and the spine twists the whole 30 (%.1f)" % (v._applied_twist() / DEG))


## Past the deadzone the legs come all the way round and the twist unwinds.
func _check_big_turn_moves_feet(unit, v) -> void:
	unit.rotation.y += 120.0 * DEG
	await _settle()
	_check(absf(wrapf(v._body_yaw - v._presented_yaw(), -PI, PI)) < 2.0 * DEG,
		"a 120 degree turn brings the feet onto the new facing")
	_check(absf(v._applied_twist()) < 2.0 * DEG, "and leaves no twist behind")


## Every 7 degrees round the clock, settled, the gun points the same way
## relative to the facing as it does at rest: the twist carries the gun exactly.
func _check_gun_tracks_any_angle(unit, v) -> void:
	await _settle()
	var baseline := wrapf(_beam_yaw(v) - unit.rotation.y, -PI, PI)
	var worst := 0.0
	var start: float = unit.rotation.y
	for step in range(1, 52):
		unit.rotation.y = start + step * 7.0 * DEG
		await _settle(0.9)
		var off := absf(wrapf(_beam_yaw(v) - unit.rotation.y - baseline, -PI, PI))
		worst = maxf(worst, off)
	_check(worst < 2.0 * DEG,
		"at every 7 degree facing the settled gun is within 2 degrees of the aim (worst %.2f)" % (worst / DEG))


## The beam the rules light by answers with the SETTLED direction from the first
## frame of a turn, while the model is still swinging.
func _check_rules_beam_ignores_lag(unit, v) -> void:
	await _settle()
	unit.rotation.y += 75.0 * DEG
	# Same frame as the turn, before any _process: the model has been carried
	# round with its parent and not yet corrected. A recompute can run here.
	var instant := _yaw_of(v.aim_direction())
	await process_frame
	var mid := _yaw_of(v.aim_direction())
	var model_mid := _beam_yaw(v)
	await _settle()
	var settled := _yaw_of(v.aim_direction())
	_check(absf(wrapf(model_mid - settled, -PI, PI)) > 20.0 * DEG,
		"one frame into a 75 degree turn the drawn gun has not got there yet")
	_check(absf(wrapf(mid - settled, -PI, PI)) < 0.5 * DEG,
		"but the rules beam already points where it will settle (%.2f off)" % (absf(wrapf(mid - settled, -PI, PI)) / DEG))
	_check(absf(wrapf(instant - settled, -PI, PI)) < 0.5 * DEG,
		"including in the same frame as the turn (%.2f off)" % (absf(wrapf(instant - settled, -PI, PI)) / DEG))


## The gun rides the trigger hand and the support hand stays on its grip, at
## full twist.
func _check_hands_stay_on_gun(unit, v) -> void:
	await _settle()
	var skel = _skeleton(v)
	var grip = v._mount.find_child("grip_support", true, false) if v._mount else null
	# Read through attachments: they follow the DRAWN pose, after modifiers.
	# get_bone_global_pose outside the modification pass is the bare animation.
	var hand_l = _attach(skel, "hand.L")
	var hand_r = _attach(skel, "hand.R")
	var weapon = _attach(skel, "weapon")
	await process_frame
	var rest_l: float = hand_l.global_position.distance_to(grip.global_position) if grip else 0.0
	var rest_r: float = hand_r.global_position.distance_to(weapon.global_position)
	var rest_twist: float = v._applied_twist()
	unit.rotation.y += 40.0 * DEG
	await _settle()
	_check(absf(v._applied_twist() - rest_twist) > 35.0 * DEG, "the spine is twisted for this check")
	var now_r: float = hand_r.global_position.distance_to(weapon.global_position)
	_check(absf(now_r - rest_r) < 0.01,
		"the gun stays in the trigger hand (%.3f m moved)" % absf(now_r - rest_r))
	if grip:
		var now_l: float = hand_l.global_position.distance_to(grip.global_position)
		_check(absf(now_l - rest_l) < 0.01,
			"and the support hand stays on the grip (%.3f m moved)" % absf(now_l - rest_l))
	else:
		_check(false, "the mounted gun has a grip_support to check the support hand on")


## A pose that must face squarely brings the feet round even inside the deadzone.
func _check_square_pose(unit, v) -> void:
	await _settle()
	v._action = &"interact"
	unit.rotation.y += 30.0 * DEG
	await _settle()
	_check(absf(wrapf(v._body_yaw - v._presented_yaw(), -PI, PI)) < 2.0 * DEG,
		"during interact a 30 degree turn moves the feet, not the waist")
	v._action = &""
	await _settle()


## A burst at something above the muzzle pitches the gun up onto it.
func _check_pitch(unit, v) -> void:
	await _settle()
	var level := _pitch_of(v)
	var fwd := Vector3(-sin(unit.rotation.y), 0.0, -cos(unit.rotation.y))
	v.set_aim_point(v.global_position + fwd * 4.0 + Vector3(0.0, 1.4 + 2.5, 0.0))
	await _settle()
	var up := _pitch_of(v)
	v.clear_aim_point()
	await _settle()
	_check(up - level > 20.0 * DEG, "aiming at a point 2.5 m above the muzzle raises the gun (%.1f deg)" % ((up - level) / DEG))
	_check(absf(_pitch_of(v) - level) < 1.0 * DEG, "and clearing the aim point levels it again")


## A unit coming into view shows its facing at once, with no swing.
func _check_snap(unit, v) -> void:
	unit.rotation.y += 150.0 * DEG
	v.refresh()
	_check(absf(wrapf(v._body_yaw - v._presented_yaw(), -PI, PI)) < 0.01,
		"refresh puts the model straight onto the facing")


## During a burst the BARREL'S LINE runs through the target, not merely
## parallel to the facing: a gun at the right shoulder pointing straight ahead
## misses the target by the shoulder's offset. Live animation (the raise, the
## kick), several odd angles and heights. Judged at each round's `muzzle`, the
## moment it leaves, at real speed and in the game's own order: the turn, then
## the burst (Unit.fire_at).
func _check_barrel_on_target(unit, v) -> void:
	Engine.time_scale = 1.0
	for p in v._players:
		p.play()
	var misses: Array[float] = []
	# `_burst_target`, a member: a lambda captures locals by value, so a local
	# reassigned per case would stay ZERO inside it.
	var on_round := func() -> void:
		misses.append(_miss(v, _burst_target))
	v.muzzle.connect(on_round)
	for case: Array in [[37.0, 6.0, 1.2], [-115.0, 3.0, 1.2], [160.0, 9.0, 3.5], [12.0, 14.0, 1.2]]:
		await _settle()
		var yaw: float = unit.rotation.y + case[0] * DEG
		_burst_target = v.global_position + Vector3(-sin(yaw), 0.0, -cos(yaw)) * case[1] \
			+ Vector3(0.0, case[2], 0.0)
		misses.clear()
		await unit.face_toward(_burst_target)
		v.set_aim_point(_burst_target)
		await v.play_burst(6, false)
		v.clear_aim_point()
		var worst: float = misses.max() if not misses.is_empty() else INF
		# 3 cm: inside the target's chest at any range on the deck.
		_check(misses.size() == 6 and worst < 0.03,
			"firing %+d deg at %.0f m (%.1f m up), every round leaves on a line through the target (worst miss %.3f m)"
			% [int(case[0]), case[1], case[2], worst])
	v.muzzle.disconnect(on_round)
	Engine.time_scale = 4.0


## How far `target` lies off the line the barrel points down, metres.
func _miss(v, target: Vector3) -> float:
	var tip: Vector3 = v._flash.global_position
	var bore: Vector3 = (-v._flash.global_transform.basis.z).normalized()
	var to := target - tip
	return (to - bore * to.dot(bore)).length()


func _beam_yaw(v) -> float:
	return _yaw_of(-v._light.global_transform.basis.z)


func _pitch_of(v) -> float:
	var d: Vector3 = (-v._light.global_transform.basis.z).normalized()
	return asin(clampf(d.y, -1.0, 1.0))


static func _yaw_of(d: Vector3) -> float:
	return atan2(-d.x, -d.z)


func _skeleton(v):
	for n in v._model.find_children("*", "Skeleton3D", true, false):
		return n
	return null


func _attach(skel, bone: String):
	var a = BoneAttachment3D.new()
	a.bone_name = bone
	skel.add_child(a)
	return a


func _settle(seconds := SETTLE) -> void:
	await create_timer(seconds).timeout
	await process_frame


func _spawn(scene_path: String, at: Vector3i):
	var unit = load(scene_path).instantiate()
	unit.position = _grid.grid_to_world(at)
	root.add_child(unit)
	await process_frame
	await physics_frame
	return unit


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
