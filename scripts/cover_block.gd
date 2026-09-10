class_name CoverBlock
extends StaticBody3D
## The visual + collision for one tile-occupying cover piece (MapData.obstacles),
## as opposed to CoverObject's boundary-straddling prop. A block genuinely
## occupies its footprint — MapBuilder never gives those cells a GridManager
## tile, which is what makes them impassable — and it's what a unit takes
## cover BESIDE, not ON. GridManager owns the shared HP pool (see
## register_cover_block/damage_cover_edge); this node only reacts to what
## that decides, same division of labour as CoverObject.
##
## Collision is layer 4, same as ordinary edge cover, not layer 1 like a wall:
## neither cover tier blocks line of sight (Sec 6.1) — a block is an accuracy
## penalty you can be flanked around, not a sightline blocker, even though it
## blocks movement outright until destroyed.

var footprint: Rect2i
var deck: int = 0
var tier: int = MapData.Cover.NONE
var _floor_mat: StandardMaterial3D
var _tile_size: float
var _floor_height: float


## `floor_mat`/`tile_size`/`floor_height` are handed in at construction rather
## than read from an autoload, so this node never has to know it's being built
## by MapBuilder specifically — it only needs enough to draw one plane per
## reopened tile that matches the rest of the deck's floor.
func setup(box_footprint: Rect2i, box_deck: int, cover_tier: int, floor_mat: StandardMaterial3D, tile_size: float, floor_height: float) -> void:
	footprint = box_footprint
	deck = box_deck
	tier = cover_tier
	_floor_mat = floor_mat
	_tile_size = tile_size
	_floor_height = floor_height


## Called by GridManager._destroy_cover_block once this piece's shared HP pool
## hits zero. Removes the obstacle's own mesh/collision — it's rubble now, not
## a body a shot or a footstep should ever hit — and lays down a floor quad
## per newly-walkable cell so the reopened footprint doesn't just read as a
## hole in the deck.
func on_destroyed() -> void:
	for child in get_children():
		child.queue_free()
	collision_layer = 0
	for z in range(footprint.position.y, footprint.position.y + footprint.size.y):
		for x in range(footprint.position.x, footprint.position.x + footprint.size.x):
			_add_floor_quad(_cell_world(x, z))


## Cell (x, deck, z) -> world position, same formula as GridManager.grid_to_world's
## fallback and MapBuilder.cell_to_world — kept local rather than reached for
## either of those so this node stays a self-contained reaction to
## `on_destroyed()` with no dependency on which one built it.
func _cell_world(x: int, z: int) -> Vector3:
	return Vector3(x * _tile_size, deck * _floor_height, z * _tile_size)


func _add_floor_quad(world: Vector3) -> void:
	var mesh_instance := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(_tile_size, _tile_size)
	mesh_instance.mesh = plane
	mesh_instance.material_override = _floor_mat
	add_child(mesh_instance)
	mesh_instance.global_position = world
