extends SceneTree
## The corner-peek lean (GDD §6.1.2) as it is drawn: decided with the shot,
## recorded in the tick's EV_SHOT, and replayed by TickPlayback on the model.
##
## Deliberately NOT headless, like test_tick_playback.gd: a headless run builds no
## model and skips playback outright. Run it with a window:
##
##   godot --path . --script res://tools/test_lean_playback.gd
##
## maps/test_deck.txt: (13,11) has the wall end flush on its east side and leans
## to (13,12), one tile SOUTH (+z), to see (17,12).
##
## Scripts are load()ed and locals stay untyped: a --script tool is compiled before
## the class registry and the autoloads exist. See test_cerberus.gd.

const PLAYER := "res://scenes/player_unit.tscn"
const ENEMY := "res://scenes/enemy_unit.tscn"
const CORNER := Vector3i(13, 0, 11)
const PAST := Vector3i(17, 0, 12)
## Beside the corner, so its room is revealed and the shooter's model is drawn.
const WITNESS := Vector3i(12, 0, 11)
const LEAN := Vector3i(0, 0, 1)

var _failures := 0
var _grid: Node
var _turns: Node
var R  # ExplorationRules


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		print("lean playback: needs a window (see the header)")
		quit(1)
		return
	_grid = root.get_node("GridManager")
	_turns = root.get_node("TurnManager")
	R = load("res://scripts/exploration_rules.gd")
	var map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(map)
	await process_frame
	map.build_layout("res://maps/test_deck.txt")
	for _i in 3:
		await process_frame
	await physics_frame
	await physics_frame
	for node in get_nodes_in_group("units"):
		_grid.set_occupant(node.grid_pos, null)
		node.remove_from_group("units")
		node.free()

	var shooter = await _spawn(ENEMY, CORNER)
	var target = await _spawn(PLAYER, PAST)
	var witness = await _spawn(PLAYER, WITNESS)
	for _i in 3:
		await process_frame

	var events := await _check_recorded(shooter, target)
	await _check_replayed(shooter, events)
	await _check_live(shooter, target)

	print("")
	if _failures == 0:
		print("lean playback: ALL CHECKS PASSED")
		quit(0)
	else:
		print("lean playback: %d CHECK(S) FAILED" % _failures)
		quit(1)


## Decided as logic in a tick: the shot is recorded with its lean, and nothing is
## drawn out of place — the instant path never moves the model.
func _check_recorded(shooter, target) -> Array:
	var root_before: Vector3 = shooter.global_position
	_turns._timeline.clear()
	_turns.resolving_tick = true
	await shooter.fire_at(target, load("res://scripts/combat.gd").ShotAction.SHOOT)
	_turns.resolving_tick = false
	var events: Array = _turns._timeline.duplicate()
	_turns._timeline.clear()
	var shot: Dictionary = {}
	for e: Dictionary in events:
		if e["kind"] == R.EV_SHOT:
			shot = e
	_check(not shot.is_empty(), "the tick recorded the shot")
	_check(shot.get("lean") == LEAN, "with its lean toward (13,12) (%s)" % [shot.get("lean")])
	_check(shooter.global_position == root_before, "the unit's root never moved")
	_check(shooter.visual.position == Vector3.ZERO, "and an instant shot left the model on it")
	return events


## Played back: the model slides ~0.55 m toward the lean tile, fires, and comes
## back, and playback hands it back on its root.
func _check_replayed(shooter, events: Array) -> void:
	var peak := await _sample_lean(shooter, func() -> void:
		await load("res://scripts/tick_playback.gd").new().play(events, self))
	_check(peak.z > 0.45 and peak.z < 0.65 and absf(peak.x) < 0.05,
		"replayed, the model leans out toward (13,12) (peak offset %s)" % [peak])
	_check(not shooter._display_mode and shooter.visual.position == Vector3.ZERO,
		"and is back on its root when playback ends (%s)" % [shooter.visual.position])


## Fired live (turn mode, drawn): the same lean, and back again afterwards.
func _check_live(shooter, target) -> void:
	_check(not shooter.is_instant(), "sanity: the shooter is drawn")
	var peak := await _sample_lean(shooter, func() -> void:
		await shooter.fire_at(target, load("res://scripts/combat.gd").ShotAction.SHOOT))
	_check(peak.z > 0.45 and peak.z < 0.65, "a live shot leans out too (peak offset %s)" % [peak])
	_check(shooter.visual.position.is_zero_approx(), "and slides back (%s)" % [shooter.visual.position])


## Runs `action` while sampling, every frame, how far the shooter's model sits
## from its root in WORLD space; returns the largest offset seen.
func _sample_lean(shooter, action: Callable) -> Vector3:
	var peak := [Vector3.ZERO]
	var sampling := [true]
	var sample := func() -> void:
		while sampling[0]:
			await process_frame
			var off: Vector3 = shooter.visual.global_position - shooter.global_position
			off.y = 0.0
			if off.length() > peak[0].length():
				peak[0] = off
	sample.call()
	await action.call()
	sampling[0] = false
	await process_frame
	return peak[0]


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
