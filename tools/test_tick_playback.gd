extends SceneTree
## Tick playback and its display layer (EXPLORATION_PLAN.md B.12).
##
## Deliberately NOT headless, like test_room_visibility.gd: a headless run builds no
## model and skips playback outright, and the beam's aim comes from the model. Run it
## with a window:
##
##   godot --path . --script res://tools/test_tick_playback.gd
##
## Scripts are load()ed and locals stay untyped: a --script tool is compiled before
## the class registry and the autoloads exist. See test_cerberus.gd.

const PLAYER := "res://scenes/player_unit.tscn"
const ENEMY := "res://scenes/enemy_unit.tscn"
## Floor in the deck's open middle room (maps/worm_test_deck.txt).
const ANCHOR := Vector3i(7, 0, 6)
const PER_ROUND := 20

var _failures := 0
var _grid: Node
var _turns: Node
var _lighting: Node
var R  # ExplorationRules
var _rules_changes := 0
var _display_changes := 0


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		print("tick playback: needs a window (see the header)")
		quit(1)
		return
	_grid = root.get_node("GridManager")
	_turns = root.get_node("TurnManager")
	_lighting = root.get_node("LightingManager")
	R = load("res://scripts/exploration_rules.gd")
	var map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(map)
	for _i in 3:
		await process_frame
	for node in root.get_tree().get_nodes_in_group("units"):
		_grid.set_occupant(node.grid_pos, null)
		node.remove_from_group("units")
		node.free()
	_lighting.lighting_changed.connect(func() -> void: _rules_changes += 1)
	_lighting.display_lighting_changed.connect(func() -> void: _display_changes += 1)

	await _check_display_layer()
	await _check_playback_runs()

	print("")
	if _failures == 0:
		print("tick playback: ALL CHECKS PASSED")
		quit(0)
	else:
		print("tick playback: %d CHECK(S) FAILED" % _failures)
		quit(1)


## B.12.1: the display layer follows the model, matches the rules for the same tile
## and aim, and touches nothing the rules read.
func _check_display_layer() -> void:
	var a = await _spawn(PLAYER, ANCHOR)
	_lighting.recompute_dynamic()
	var rules := _snapshot()
	var before := _rules_changes

	# Model on its root: both layers cast the same beam from the same place.
	_lighting.begin_display()
	var same := true
	for tile: Vector3i in rules:
		if absf(_lighting.display_light(tile) - rules[tile]) > 0.01:
			same = false
	_check(same, "with every model on its root the display layer equals the rules layer")
	_check(_rules_changes == before, "and begin_display emits no lighting_changed")

	# Model somewhere else: the drawn light moves, the rules' does not.
	var shown_before := _display_changes
	a.begin_display()
	a.visual.global_position = _grid.grid_to_world(ANCHOR + Vector3i(3, 0, 3))
	await process_frame
	_lighting.recompute_display()
	_check(_display_changes == shown_before + 1, "recompute_display announces the drawn light")
	_check(_rules_changes == before, "and never the rules' lighting_changed")
	_check(_snapshot() == rules, "and leaves every tile's light_value untouched")
	var moved := false
	for tile: Vector3i in rules:
		if absf(_lighting.display_light(tile) - rules[tile]) > 0.01:
			moved = true
	_check(moved, "while the drawn light has moved with the model")

	# The last slot leaves the model home; dropping the layer is then seamless.
	a.end_display()
	_check(a.visual.position == Vector3.ZERO and a.visual.rotation == Vector3.ZERO, "end_display re-zeroes the model")
	await process_frame
	_lighting.recompute_display()
	same = true
	for tile: Vector3i in rules:
		if absf(_lighting.display_light(tile) - rules[tile]) > 0.01:
			same = false
	_check(same, "and with the model home again the layers agree: no jump at the end")
	_lighting.end_display()
	_check(not _lighting.is_displaying() and absf(_lighting.display_light(ANCHOR) - rules[ANCHOR]) < 0.01,
		"after which display_light reads light_value")
	_free([a])
	await process_frame


## The whole path on real models: a tick walks a patrol, the model starts where the
## unit started and ends on its root, and the rules were final throughout.
func _check_playback_runs() -> void:
	_turns.clear_out_mode = false
	_turns.exploration_enabled = true
	var a = await _spawn(PLAYER, ANCHOR)
	var e = await _spawn(ENEMY, ANCHOR + Vector3i(6, 0, 0))
	# Dark and blind on both sides: a beam on the patrol would be contact, and this
	# case is about a tick that passes quietly.
	a.toggle_flashlight()
	e.detection_range = 0
	_turns.start_mission()
	for _i in 3:
		await process_frame
	var dest: Vector3i = ANCHOR + Vector3i(6, 0, -3)
	e.rouse(dest)
	var start_world: Vector3 = _grid.grid_to_world(e.grid_pos)
	var seen_start := [false]
	var seen_mid := [false]
	# Sampled each frame: the root jumps at once, and the model has to take its time.
	var sampling := [true]
	var sample := func() -> void:
		while sampling[0]:
			await process_frame
			if not sampling[0]:
				return
			if _turns.resolving_tick:
				continue
			if e._display_mode:
				if e.visual.global_position.distance_to(start_world) < 0.2:
					seen_start[0] = true
				if e.visual.global_position.distance_to(e.global_position) > 0.2:
					seen_mid[0] = true
	sample.call()
	_turns.add_steps(PER_ROUND)
	await _turns.settle_clock()
	sampling[0] = false
	_check(e.grid_pos != ANCHOR + Vector3i(6, 0, 0), "sanity: the patrol moved (at %s)" % e.grid_pos)
	_check(seen_mid[0], "the model trails its root during playback")
	_check(seen_start[0], "starting from where the unit started")
	_check(not e._display_mode and e.visual.position == Vector3.ZERO, "and is back on its root when the tick ends")
	_check(not _lighting.is_displaying(), "with the display layer dropped")
	_check(not _turns._ticking, "and the tick finished only after playback")
	_turns.abandon()
	_free([a, e])
	await process_frame


func _snapshot() -> Dictionary:
	var out := {}
	for tile: Vector3i in _grid.tiles:
		out[tile] = _grid.get_tile(tile).light_value
	return out


func _spawn(scene_path: String, at: Vector3i):
	var unit = load(scene_path).instantiate()
	unit.position = _grid.grid_to_world(at)
	root.add_child(unit)
	await process_frame
	await physics_frame
	return unit


func _free(units: Array) -> void:
	for unit in units:
		if is_instance_valid(unit):
			_grid.set_occupant(unit.grid_pos, null)
			unit.remove_from_group("units")
			unit.queue_free()


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
