extends SceneTree
## Prints the node tree Godot's glTF importer produced, so scenes can reference
## the real generated node names instead of guessed ones.
##   godot --headless --script res://tools/dump_glb.gd

func _initialize() -> void:
	for path in ["res://assets/soldier_mixamo.glb", "res://assets/rifle.glb"]:
		print("=== ", path)
		var packed: PackedScene = load(path)
		if packed == null:
			print("  FAILED TO LOAD")
			continue
		_dump(packed.instantiate(), 1)
	quit()


func _dump(node: Node, depth: int) -> void:
	var pad := "  ".repeat(depth)
	print(pad, node.name, "  [", node.get_class(), "]")
	var player := node as AnimationPlayer
	if player:
		for anim_name in player.get_animation_list():
			var anim: Animation = player.get_animation(anim_name)
			print(pad, "  - ", anim_name, "  ", "%.2fs" % anim.length,
				"  loop=", anim.loop_mode)
	if node is Skeleton3D:
		var names: Array[String] = []
		for i in node.get_bone_count():
			names.append(node.get_bone_name(i))
		print(pad, "  bones(", node.get_bone_count(), "): ", ", ".join(names))
	for child in node.get_children():
		_dump(child, depth + 1)
