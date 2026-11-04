class_name ShipModel
extends RefCounted
## The hangar's ship art (tools/export_ships.py): the squad's dropship and the
## bay's wrecks, fitted to whatever space the rules reserved for them.
##
## Every .glb comes out of the export the same way — nose along -Z, centred
## across, belly (or a wreck's buried nose) at the origin's floor — so fitting is
## one uniform scale that keeps the model inside `size`, and nothing about a
## model's own dimensions reaches the rules. Visual only: callers keep their
## collision exactly as it was.

const DROPSHIP := "res://assets/models/ships/dropship.glb"
const WRECKS: Array[String] = [
	"res://assets/models/ships/wreck_a.glb",
	"res://assets/models/ships/wreck_b.glb",
	"res://assets/models/ships/wreck_c.glb",
	"res://assets/models/ships/wreck_d.glb",
]


## A wrapper holding the model at `path`, scaled uniformly to fit inside `size`
## (across, up, along) and centred on the wrapper's origin across and along,
## its floor at the wrapper's. `min_height` then stretches it up alone, for a
## flat model standing in for something taller. Null when the model is missing,
## so a caller can keep its placeholder.
##
## `may_turn` lets the model be laid a quarter turn round inside the wrapper
## when that fits it larger: a wreck has no facing the rules care about, and the
## pack's fighters are often wider across the wings than they are long.
##
## The fitted bounds, in the wrapper's parent space, are left as the wrapper's
## `fitted_aabb` meta, for a caller hanging parts (a ramp) off the model's ends.
static func fitted(path: String, size: Vector3, min_height := 0.0, may_turn := false) -> Node3D:
	if not ResourceLoader.exists(path):
		return null
	var scene := load(path) as PackedScene
	if scene == null:
		return null
	var model := scene.instantiate() as Node3D
	var box := _local_aabb(model, Transform3D.IDENTITY)
	if box.size.x <= 0.0 or box.size.z <= 0.0:
		model.free()
		return null
	var s := _scale_to_fit(box.size, size)
	var turned := false
	if may_turn:
		var turned_size := Vector3(box.size.z, box.size.y, box.size.x)
		var s_turned := _scale_to_fit(turned_size, size)
		if s_turned > s:
			s = s_turned
			turned = true
	var up := s
	if box.size.y > 0.0 and box.size.y * up < min_height:
		up = minf(min_height, size.y) / box.size.y
	var wrapper := Node3D.new()
	wrapper.name = "ShipModel"
	wrapper.add_child(model)
	wrapper.scale = Vector3(s, up, s)
	var centre := Vector3(box.get_center().x, 0.0, box.get_center().z)
	var extent := box.size
	if turned:
		model.rotation.y = PI / 2.0
		centre = Basis(Vector3.UP, PI / 2.0) * centre
		extent = Vector3(box.size.z, box.size.y, box.size.x)
	model.position = -centre
	var low := Vector3(-extent.x / 2.0, box.position.y, -extent.z / 2.0)
	wrapper.set_meta("fitted_aabb", AABB(low * wrapper.scale, extent * wrapper.scale))
	return wrapper


## The uniform scale that keeps a model of `extent` inside `size`.
static func _scale_to_fit(extent: Vector3, size: Vector3) -> float:
	var s := minf(size.x / extent.x, size.z / extent.z)
	if extent.y > 0.0:
		s = minf(s, size.y / extent.y)
	return s


## The bounds of every mesh under `node`, in the space `xform` maps `node` into.
## Walked by hand because the model is not in the tree yet, so there are no
## global transforms to read.
static func _local_aabb(node: Node, xform: Transform3D) -> AABB:
	var out := AABB()
	var any := false
	if node is MeshInstance3D and (node as MeshInstance3D).mesh:
		out = xform * (node as MeshInstance3D).mesh.get_aabb()
		any = true
	for child in node.get_children():
		var child_xform := xform * (child as Node3D).transform if child is Node3D else xform
		var sub := _local_aabb(child, child_xform)
		if sub.size == Vector3.ZERO:
			continue
		out = sub if not any else out.merge(sub)
		any = true
	return out
