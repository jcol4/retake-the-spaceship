extends SceneTree
## Throwaway: prints which walls the occlusion pass hides, at each of the four
## isometric yaws, as an ASCII picture to eyeball against maps/test_deck.txt.
##
##   godot --headless --path . --script res://tools/_debug_occlusion.gd
##
## Builds test_map.tscn directly rather than main.tscn: nothing here needs the
## real squad or the loadout screen, and MapBuilder._process only reads the
## camera's BASIS, so a camera parked at the origin with the right rotation is a
## complete stand-in for the real rig.
##
## What it DOES need is a player unit, because the occlusion rule is now
## room-aware: a wall opens only when the floor behind it belongs to a region the
## squad is standing in. Move STAND_IN between the rooms to see that — the deck
## should open around it and stay sealed everywhere else.
##
## Everything is untyped and called dynamically — naming MapBuilder or MapData in
## a type hint would compile map_builder.gd before the autoloads register and the
## tool would never load.

const YAWS := [45.0, 135.0, 225.0, 315.0]
const PITCH := -35.264  # atan(1/sqrt(2)), true iso
## Middle room. Try Vector3i(2, 0, 2) for the left one, Vector3i(17, 0, 2) right.
const STAND_IN := Vector3i(9, 0, 6)


func _initialize() -> void:
	var map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(map)

	# A real squad member, because the occlusion pass is room-aware now: it reads
	# the player_units group and opens only the region a unit is standing in.
	# The scene is instantiated rather than faked so the tool keeps telling the
	# truth about what the game does.
	var stand_in = load("res://scenes/player_unit.tscn").instantiate()
	stand_in.position = root.get_node("GridManager").grid_to_world(STAND_IN)
	root.add_child(stand_in)

	var cam := Camera3D.new()
	root.add_child(cam)
	cam.make_current()
	await process_frame

	for yaw in YAWS:
		cam.rotation = Vector3(deg_to_rad(PITCH), deg_to_rad(yaw), 0.0)
		# Two frames: one for _process to see the new basis, one for the
		# visibility writes to have landed before they are read back.
		await process_frame
		await process_frame
		_dump(map, yaw)

	quit()


func _dump(map, yaw: float) -> void:
	var walls: Dictionary = map._wall_meshes
	var data = map.data
	var hidden := 0
	var lines: Array[String] = []
	for z in data.size.y:
		var row := ""
		for x in data.size.x:
			var pos := Vector3i(x, 0, z)
			if walls.has(pos):
				if walls[pos].visible:
					row += "#"
				else:
					row += "~"
					hidden += 1
			elif pos == STAND_IN:
				row += "@"
			elif data.is_walkable(pos):
				row += "."
			else:
				row += " "
		lines.append(row)
	print("\n=== yaw %.0f°  step %s  revealed %s  —  %d of %d walls hidden (~)" % [
		yaw, map._occlusion_step, map._revealed.keys(), hidden, walls.size()])
	for line in lines:
		print("  " + line)
