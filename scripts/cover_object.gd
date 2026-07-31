class_name CoverObject
extends StaticBody3D
## The visual prop for one piece of edge cover, straddling the boundary between
## two tiles. Registers itself with the grid at map load; GridManager owns the HP
## and the tier — this node only reacts to what that decides (Sec 6.1.1).
##
## Deliberately does NOT touch tile passability any more. Under the edge model a
## unit stands on the tile the crate is bolted to the side of, which is what fixes
## sprite depth sorting: a prop on a boundary is never depth-coincident with a
## unit at a tile centre, so the order is consistent at every camera yaw.

## Prop height by MapData.Cover tier. Chosen against the 35-degree camera pitch:
## at this range a 1.0-1.4 m prop on the camera-near edge crosses a unit sprite's
## legs and clears its head, so the silhouette itself reads as "in cover" without
## a single UI element. Rubble is low enough to read as spent.
const TIER_HEIGHT := {
	MapData.Cover.HEAVY: 1.4,
	MapData.Cover.LIGHT: 1.0,
	MapData.Cover.NONE: 0.35,
}
const TIER_COLOR := {
	MapData.Cover.HEAVY: Color(0.30, 0.35, 0.30),
	MapData.Cover.LIGHT: Color(0.55, 0.42, 0.25),
	MapData.Cover.NONE: Color(0.30, 0.28, 0.26),
}

var tile: Vector3i
var side: int = -1
var tier: int = MapData.Cover.NONE


func register_with_grid(at: Vector3i, on_side: int, cover_type: int) -> void:
	tile = at
	side = on_side
	tier = cover_type
	GridManager.add_cover_edge(at, on_side, cover_type, self)


## Called by GridManager.damage_cover_edge when the tier changes, including
## heavy dropping to light. Rebuilding the box rather than scaling it keeps the
## collision shape honest, which matters because the prop is what the eye reads
## the rule off.
func set_tier(cover_type: int) -> void:
	tier = cover_type
	var mesh := get_node_or_null("Mesh") as MeshInstance3D
	var shape := get_node_or_null("Shape") as CollisionShape3D
	if mesh == null or shape == null:
		return
	var box := mesh.mesh as BoxMesh
	var height: float = TIER_HEIGHT[cover_type]
	var base := global_position.y - box.size.y / 2.0
	box.size = Vector3(box.size.x, height, box.size.z)
	(shape.shape as BoxShape3D).size = box.size
	global_position.y = base + height / 2.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = TIER_COLOR[cover_type]
	mesh.material_override = mat
