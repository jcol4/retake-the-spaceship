extends SceneTree
## Inventory of a room-tile kit: loads every imported glTF under KIT_DIR and
## prints, per file, its AABB (min and size, metres, kit units unscaled), mesh
## and surface counts, material names, and any non-mesh nodes. The numbers it
## prints are what the kit manifest's scale, sizes and offsets are worked out
## from, so run it after `godot --headless --path . --import`.
##
##   godot --headless --path . --script res://tools/inventory_kit.gd
##   godot --headless --path . --script res://tools/inventory_kit.gd -- --kit=quaternius_scifi
##
## Untyped like the other tools/ scripts: a --script tool compiles before the
## autoloads register.

const ROOT := "res://assets/room_tiles/"

var _kit := "quaternius_scifi"


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--kit="):
			_kit = arg.substr(6)
	var files: Array = []
	_collect(ROOT + _kit, files)
	files.sort()
	print("kit %s: %d glTF files" % [_kit, files.size()])
	print("file | aabb min | aabb size | meshes | surfaces | materials | other nodes")
	for path in files:
		_report(path)
	quit(0)


func _collect(dir_path: String, out: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		push_error("no such folder: " + dir_path)
		return
	for sub in dir.get_directories():
		_collect(dir_path + "/" + sub, out)
	for f in dir.get_files():
		if f.get_extension() in ["gltf", "glb"]:
			out.append(dir_path + "/" + f)


func _report(path: String) -> void:
	var packed = load(path)
	if packed == null:
		print("%s | LOAD FAILED" % path)
		return
	var scene: Node = packed.instantiate()
	var stats := {"meshes": 0, "surfaces": 0, "materials": {}, "other": [], "aabb": AABB(), "has_aabb": false}
	_walk(scene, Transform3D.IDENTITY, stats, true)
	var box: AABB = stats.aabb
	print("%s | (%.3f, %.3f, %.3f) | (%.3f, %.3f, %.3f) | %d | %d | %s | %s" % [
		path.trim_prefix(ROOT + _kit + "/"),
		box.position.x, box.position.y, box.position.z,
		box.size.x, box.size.y, box.size.z,
		stats.meshes, stats.surfaces,
		",".join(PackedStringArray(stats.materials.keys())),
		",".join(PackedStringArray(stats.other)) if not stats.other.is_empty() else "-"])
	if path.get_file().begins_with("Door_Frame"):
		_report_opening(scene)
	scene.free()


## A door frame's clear opening, which its AABB can't give: the half-width is
## the nearest geometry to x = 0 across a slice at y = OPENING_SLICE_Y, and the
## top is the lowest geometry above that slice crossing x = 0. The manifest
## scales a frame so this opening, not its outer width, matches the DOOR run.
const OPENING_SLICE_Y := 1.0


func _report_opening(scene: Node) -> void:
	var tris := PackedVector3Array()
	_collect_tris(scene, Transform3D.IDENTITY, tris)
	var half := INF
	var top := INF
	for i in range(0, tris.size(), 3):
		for e in 3:
			var a: Vector3 = tris[i + e]
			var b: Vector3 = tris[i + (e + 1) % 3]
			if (a.y - OPENING_SLICE_Y) * (b.y - OPENING_SLICE_Y) <= 0.0 and a.y != b.y:
				var p := a.lerp(b, (OPENING_SLICE_Y - a.y) / (b.y - a.y))
				half = minf(half, absf(p.x))
			if a.x * b.x <= 0.0 and a.x != b.x:
				var q := a.lerp(b, -a.x / (b.x - a.x))
				if q.y > OPENING_SLICE_Y:
					top = minf(top, q.y)
	print("    opening: width %.3f, top %.3f" % [half * 2.0, top])


func _collect_tris(node: Node, parent_xf: Transform3D, out: PackedVector3Array) -> void:
	var xf := parent_xf
	if node is Node3D:
		xf = parent_xf * (node as Node3D).transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var mesh: Mesh = (node as MeshInstance3D).mesh
		for s in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(s)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			if idx.is_empty():
				for v in verts:
					out.append(xf * v)
			else:
				for i in idx:
					out.append(xf * verts[i])
	for child in node.get_children():
		_collect_tris(child, xf, out)


func _walk(node: Node, parent_xf: Transform3D, stats: Dictionary, is_root: bool) -> void:
	var xf := parent_xf
	if node is Node3D:
		xf = parent_xf * (node as Node3D).transform
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			stats.meshes += 1
			stats.surfaces += mi.mesh.get_surface_count()
			for s in mi.mesh.get_surface_count():
				var mat: Material = mi.get_active_material(s)
				stats.materials[mat.resource_name if mat != null and mat.resource_name != "" else "<unnamed>"] = true
			var box: AABB = xf * mi.mesh.get_aabb()
			stats.aabb = box if not stats.has_aabb else stats.aabb.merge(box)
			stats.has_aabb = true
	elif not is_root and node.get_class() != "Node3D":
		stats.other.append("%s:%s" % [node.name, node.get_class()])
	for child in node.get_children():
		_walk(child, xf, stats, false)
