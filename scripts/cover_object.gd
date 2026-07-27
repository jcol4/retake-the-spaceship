class_name CoverObject
extends StaticBody3D
## A cover block on one tile. Registers itself with the grid at map load;
## GridManager.damage_cover handles HP — this node only handles visuals.
## Sec 6.1.1: Light 20 HP, Heavy 50 HP; at 0 HP becomes impassable rubble.

const LIGHT_HP := 20
const HEAVY_HP := 50

@export var is_heavy: bool = false


func register_with_grid() -> void:
	var pos := GridManager.world_to_grid(global_position)
	var tile: GridTileData = GridManager.get_tile(pos)
	if tile == null:
		tile = GridManager.add_tile(pos, global_position)
	tile.cover_type = GridTileData.CoverType.HEAVY if is_heavy else GridTileData.CoverType.LIGHT
	tile.cover_hp = HEAVY_HP if is_heavy else LIGHT_HP
	tile.passable = false  # units shoot over/around cover, never stand in it
	tile.cover_node = self


func become_rubble() -> void:
	# Stay impassable, lose height, go grey — reads as debris.
	var mesh: MeshInstance3D = get_node_or_null("Mesh")
	if mesh:
		mesh.scale.y = 0.35
		mesh.position.y *= 0.35
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.3, 0.28, 0.26)
		mesh.material_override = mat
