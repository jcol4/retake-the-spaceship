extends SceneTree
## Throwaway: parks a camera side-on to the first soldier, at a sane distance
## and with no fill light, so the flashlight beam can be judged on its own.
##   godot --path . --script res://tools/_debug_beam.gd
## SHOT_PATH, SHOT_DELAY, BEAM_OFF (camera offset "x,y,z") honoured.

var _elapsed := 0.0
var _delay := 2.5
var _settle := 0
var _placed := false
var _done := false


func _initialize() -> void:
	if OS.has_environment("SHOT_DELAY"):
		_delay = float(OS.get_environment("SHOT_DELAY"))
	change_scene_to_file.call_deferred("res://scenes/main.tscn")


func _process(_delta: float) -> bool:
	_elapsed += _delta
	if _done or _elapsed < _delay:
		return false
	if not _placed:
		_placed = true
		_place()
		return false
	if _settle < 2:
		_settle += 1
		return false
	_done = true
	var image := root.get_texture().get_image()
	print("[beam] err=", image.save_png(OS.get_environment("SHOT_PATH")))
	quit()
	return true


func _place() -> void:
	var units := root.get_tree().get_nodes_in_group("player_units")
	if units.is_empty():
		print("[beam] no player units")
		quit()
		return
	# The last spawn: the one with a long run of clear floor in front of it, so
	# the beam gets to fade out rather than splashing straight onto a wall.
	var unit: Node3D = units[units.size() - 1]
	if OS.has_environment("BEAM_UNIT"):
		unit = units[int(OS.get_environment("BEAM_UNIT"))]
	var off := Vector3(3.2, 5.0, -5.0)
	if OS.has_environment("BEAM_OFF"):
		var parts := OS.get_environment("BEAM_OFF").split(",")
		off = Vector3(float(parts[0]), float(parts[1]), float(parts[2]))
	# Aim at the middle of the beam, not the soldier, so the whole ray is framed.
	var focus := unit.global_position + Vector3(0.0, 0.8, -4.5)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.global_position = unit.global_position + off
	cam.look_at(focus)
	cam.fov = 55.0
	cam.make_current()
	print("[beam] cam at ", cam.global_position, " looking at ", focus)
