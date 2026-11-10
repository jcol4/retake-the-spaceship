extends SceneTree
## Robot and Fodder playback across visibility handovers and loop boundaries.
## godot --headless --path . --script res://tools/test_walk_refresh.gd

class TestUnit extends Node3D:
	var instant := false
	func is_instant() -> bool:
		return instant

var _failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_check_gait(&"securus", &"walk", 0.0, 1.0)
	for gait: StringName in [&"walk", &"run"]:
		for tempo in [1.0, 1.3, 1.55]:
			_check_gait(&"zombie_2", gait, 0.37, tempo)
	print("walk refresh: %s" % ("ALL CHECKS PASSED" if _failed == 0 else "%d FAILED" % _failed))
	quit(1 if _failed else 0)


func _check_gait(variant: StringName, gait: StringName, phase_offset: float, tempo: float) -> void:
	var unit := TestUnit.new()
	root.add_child(unit)
	var visual: Node3D = load("res://scripts/unit_visual.gd").new()
	visual.variant = variant
	visual.loop_phase = phase_offset
	visual.has_light = false
	unit.add_child(visual)
	var model := (load("res://assets/models/%s.glb" % variant) as PackedScene).instantiate()
	visual.add_child(model)
	visual._adopt_players(model, 0.0)
	var player: AnimationPlayer = visual._players[0]
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	visual.set_stance_local(gait)
	player.advance(0.0)
	visual.set_tempo(tempo)
	var length := player.get_animation(gait).length
	for phase in [0.13, 0.49, 0.83, 0.99]:
		player.seek(length * phase, true)
		var before := player.current_animation_position
		unit.instant = true
		visual.refresh()
		unit.instant = false
		visual.refresh()
		_check(is_equal_approx(player.current_animation_position, before),
			"visibility refresh preserves walking phase %.2f" % phase)
		visual.set_stance_local(gait)
		_check(is_equal_approx(player.current_animation_position, before),
			"reasserting walk at a tile boundary preserves phase")
	player.seek(length * 0.99, true)
	player.advance(0.03 / tempo)
	_check(player.is_playing() and player.current_animation_position < length * 0.1,
		"walk continues smoothly through the loop boundary")
	player.stop()
	visual.refresh()
	_check(player.is_playing(), "refresh resumes a stopped walk player")
	# A stance changed while hidden must still replace the previously drawn walk.
	unit.instant = true
	visual.set_stance_local(&"idle")
	unit.instant = false
	visual.refresh()
	_check(player.current_animation == &"idle", "refresh applies a stance changed while hidden")
	visual._action = &"melee"
	visual.refresh()
	player.advance(0.02)
	visual.refresh()
	_check(is_zero_approx(player.current_animation_position), "one-shot refresh still restarts")
	# Check the actual baked bone tracks, not just the player's looping flag.
	var animation := player.get_animation(gait)
	for track in animation.get_track_count():
		var count := animation.track_get_key_count(track)
		if count < 2:
			continue
		var first: Variant = animation.track_get_key_value(track, 0)
		var last: Variant = animation.track_get_key_value(track, count - 1)
		var matches := true
		if first is Quaternion:
			matches = absf(first.normalized().dot(last.normalized())) > 0.99999
		elif first is Vector3:
			matches = first.distance_to(last) < 0.0001
		_check(matches, "%s %s closes bone track %s" % [variant, gait, animation.track_get_path(track)])
	unit.free()


func _check(ok: bool, message: String) -> void:
	if not ok:
		push_error(message)
		_failed += 1

