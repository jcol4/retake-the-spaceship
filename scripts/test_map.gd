extends Node3D
## Hand-authored test map, defined as an ASCII layout and built at _ready().
## Three rooms: player squad room (left), central room with cover, enemy room
## (right) containing a raised platform reached by a stair tile.
##
## Legend: . floor   # wall   l light cover   h heavy cover
##         P player spawn   E enemy spawn   R raised platform (floor 1)
##         s stair tile (links to the platform tile directly north of it)
##         o overhead light   m monitor/terminal light   f flickering light

const LAYOUT := [
	"####################",
	"#....#...o....#....#",
	"#.P..#....m...#..E.#",
	"#....#........#....#",
	"#.P..#..l.....#....#",
	"#....#........#....#",
	"#....#...h....#..E.#",
	"#.....f.......#....#",
	"#....#..l.....#....#",
	"#....#........#RR..#",
	"#.P..#........#RR..#",
	"#....#........#s.Em#",
	"#....#.............#",
	"####################",
]

const WALL_HEIGHT := 3.0
const PLATFORM_HEIGHT := 3.0

var player_spawns: Array[Vector3i] = []
var enemy_spawns: Array[Vector3i] = []

var _wall_mat: StandardMaterial3D
var _floor_mat: StandardMaterial3D
var _platform_mat: StandardMaterial3D
var _stair_mat: StandardMaterial3D
var _cover_light_mat: StandardMaterial3D
var _cover_heavy_mat: StandardMaterial3D


func _ready() -> void:
	_make_materials()
	GridManager.clear()
	for z in LAYOUT.size():
		var row: String = LAYOUT[z]
		for x in row.length():
			_build_cell(x, z, row[x])
	_link_stairs()
	build_ground_collision()
	LightingManager.recompute_base()


func _build_cell(x: int, z: int, ch: String) -> void:
	var world := Vector3(x * GridManager.TILE_SIZE, 0, z * GridManager.TILE_SIZE)
	match ch:
		"#":
			_add_wall(world)
		".", "P", "E", "s":
			GridManager.add_tile(Vector3i(x, 0, z), world)
			_add_floor_quad(world, _stair_mat if ch == "s" else _floor_mat)
			if ch == "P":
				player_spawns.append(Vector3i(x, 0, z))
			elif ch == "E":
				enemy_spawns.append(Vector3i(x, 0, z))
		"l", "h":
			GridManager.add_tile(Vector3i(x, 0, z), world)
			_add_floor_quad(world, _floor_mat)
			_add_cover(world, ch == "h")
		"R":
			var top := world + Vector3(0, PLATFORM_HEIGHT, 0)
			GridManager.add_tile(Vector3i(x, 1, z), top)
			_add_platform(world)
		"o", "m", "f":
			GridManager.add_tile(Vector3i(x, 0, z), world)
			_add_floor_quad(world, _floor_mat)
			_add_light(world, ch)


func _link_stairs() -> void:
	# Stair tile links to the floor-1 platform tile directly north (z-1) of it.
	for z in LAYOUT.size():
		var row: String = LAYOUT[z]
		for x in row.length():
			if row[x] == "s" and GridManager.has_tile(Vector3i(x, 1, z - 1)):
				GridManager.add_stair_link(Vector3i(x, 0, z), Vector3i(x, 1, z - 1))


func _make_materials() -> void:
	_wall_mat = _mat(Color(0.25, 0.27, 0.32))
	_floor_mat = _mat(Color(0.42, 0.44, 0.48))
	_platform_mat = _mat(Color(0.35, 0.38, 0.45))
	_stair_mat = _mat(Color(0.55, 0.5, 0.3))
	_cover_light_mat = _mat(Color(0.55, 0.42, 0.25))
	_cover_heavy_mat = _mat(Color(0.3, 0.35, 0.3))


func _mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	return m


func _add_box_body(world: Vector3, size: Vector3, mat: StandardMaterial3D, layer: int) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = layer
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Mesh"
	var box_mesh := BoxMesh.new()
	box_mesh.size = size
	mesh_instance.mesh = box_mesh
	mesh_instance.material_override = mat
	body.add_child(shape)
	body.add_child(mesh_instance)
	add_child(body)
	body.global_position = world + Vector3(0, size.y / 2.0, 0)
	return body


func _add_wall(world: Vector3) -> void:
	_add_box_body(world, Vector3(GridManager.TILE_SIZE, WALL_HEIGHT, GridManager.TILE_SIZE), _wall_mat, 1)


func _add_platform(world: Vector3) -> void:
	_add_box_body(world, Vector3(GridManager.TILE_SIZE, PLATFORM_HEIGHT, GridManager.TILE_SIZE), _platform_mat, 1)


func _add_cover(world: Vector3, heavy: bool) -> void:
	# Cover collides on layer 4 only — LOS rays (mask 1) pass over it, the
	# accuracy penalty represents it instead. Sec 6.1.
	var height := 1.4 if heavy else 1.0
	var size := Vector3(GridManager.TILE_SIZE * 0.85, height, GridManager.TILE_SIZE * 0.85)
	var body := _add_box_body(world, size, _cover_heavy_mat if heavy else _cover_light_mat, 4)
	body.set_script(load("res://scripts/cover_object.gd"))
	body.set("is_heavy", heavy)
	body.call("register_with_grid")


func _add_light(world: Vector3, kind: String) -> void:
	# Sec 5.3 fixtures. Mounted at ceiling-ish height; occlusion is handled by
	# LightingManager's raycast against wall geometry, same as unit LOS.
	var source := LightSource.new()
	match kind:
		"o":  # overhead — bright, wide, always on
			source.light_range = 6.0
			source.intensity = 90.0
			source.light_color = Color(1.0, 1.0, 1.0)
		"m":  # monitor/terminal — dim, short-range
			source.light_range = 2.5
			source.intensity = 45.0
			source.light_color = Color(0.4, 0.75, 1.0)
		"f":  # flickering overhead — fluctuates turn-to-turn (Sec 5.3)
			source.light_range = 6.0
			source.intensity = 90.0
			source.light_color = Color(0.85, 0.92, 1.0)
			source.flickers = true
			source.flicker_min = 25.0
			source.flicker_max = 90.0
	add_child(source)
	source.global_position = world + Vector3(0, 2.0, 0)
	source.register_with_grid()


func _add_floor_quad(world: Vector3, mat: StandardMaterial3D) -> void:
	var mesh_instance := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(GridManager.TILE_SIZE, GridManager.TILE_SIZE)
	mesh_instance.mesh = plane
	mesh_instance.material_override = mat
	add_child(mesh_instance)
	mesh_instance.global_position = world  # visual only; clicks hit the shared ground body


func build_ground_collision() -> void:
	# Single large ground body for click raycasts (layer 1). Sits slightly
	# below wall bases so it never blocks eye-height LOS rays.
	var width := LAYOUT[0].length() * GridManager.TILE_SIZE
	var depth := LAYOUT.size() * GridManager.TILE_SIZE
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(width, 0.1, depth)
	shape.shape = box
	body.add_child(shape)
	add_child(body)
	body.global_position = Vector3(width / 2.0 - GridManager.TILE_SIZE / 2.0, -0.05, depth / 2.0 - GridManager.TILE_SIZE / 2.0)
