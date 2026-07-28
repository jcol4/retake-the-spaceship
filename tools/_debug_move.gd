extends SceneTree
## Traces one unit's walk down a path: per-frame speed, and which clip is
## playing while it is covered. What it is for is the handover from the run to
## the deceleration -- that clip strides out 2.83 m of its own, so the unit has
## to be crossing that ground while it plays or the feet skate.
##
## Read the SPEED column: it should hold near move_speed, drop once to the
## clip's entry speed, then fall to zero AT the destination, never after it.
##
##   godot --headless --path . --script res://tools/_debug_move.gd
##
## Runs headless but forces the animated path on -- Unit._instant would
## otherwise teleport each step and there would be nothing to measure.

const TILES := [1, 2, 3, 6]

var _unit = null
var _prev := Vector3.ZERO
var _clip := ""
var _tracing := false
var _target_z := 0.0
# Resolved at runtime, never named directly: a --script tool is compiled before
# the autoloads are registered, so a bare `GridManager` fails to compile.
var _grid = null


func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/player_unit.tscn")
	_unit = packed.instantiate()
	root.add_child(_unit)
	_run()


func _run() -> void:
	await process_frame
	_grid = root.get_node("GridManager")
	# The unit spawned into a headless display and put itself on the instant
	# path; undo that for both halves (the unit tweens, the visual animates).
	_unit._instant = false
	_unit.flashlight_on = false
	_unit.has_flashlight = false
	_unit.visual.setup(false)
	var visual = _unit.visual
	print("[move] stop travel=%.3fm  rate=%.3f  walk<%.3fm  clip=%.3fs" % [
		visual.run_stop_travel(), visual.run_stop_rate(_unit.move_speed),
		visual.run_stop_travel(), visual.run_stop_time_at(9.9)])

	for count in TILES:
		var path: Array[Vector3i] = []
		for i in count:
			path.append(Vector3i(0, 0, i + 1))
		_unit.global_position = _grid.grid_to_world(Vector3i.ZERO)
		_unit.grid_pos = Vector3i.ZERO
		var target: Vector3 = _grid.grid_to_world(path[count - 1])
		_target_z = target.z
		print("\n=== %d tile(s), %.3fm" % [count, target.z])
		_prev = _unit.global_position
		_clip = ""
		_tracing = true
		await _unit.move_along(path)
		_tracing = false
		print("  landed at %.4f (want %.4f), off by %.1f mm" % [
			_unit.global_position.z, target.z,
			absf(_unit.global_position.z - target.z) * 1000.0])
	quit()


func _process(delta: float) -> bool:
	if not _tracing:
		return false
	var pos = _unit.global_position
	var anim = _unit.visual.anim
	var clip := str(anim.current_animation)
	var speed: float = pos.distance_to(_prev) / maxf(delta, 0.0001)
	if clip != _clip:
		print("  -> %-10s at %.3fm, %.3fm still to go" % [
			clip, pos.z, _target_z - pos.z])
		_clip = clip
	print("    z=%6.3f  speed=%5.2f  %s" % [pos.z, speed, clip])
	_prev = pos
	return false
