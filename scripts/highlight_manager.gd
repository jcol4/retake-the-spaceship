extends Node3D
## Pools flat quad meshes for the tile overlays: the two-band move range (blue
## for 1 AP, yellow for the 2 AP sprint band), the path preview and its AP cost
## drawn on top, and the shootable-target markers with their hit chances.

const RUN_COLOR := Color(0.2, 0.7, 1.0, 0.45)
const SPRINT_COLOR := Color(1.0, 0.78, 0.1, 0.38)
# Path and destination stay white so they read against either band.
const PATH_COLOR := Color(1.0, 1.0, 1.0, 0.8)
const DEST_COLOR := Color(1.0, 1.0, 1.0, 0.9)
const TARGET_COLOR := Color(1.0, 0.25, 0.2, 0.6)
const TARGET_TEXT_COLOR := Color(1.0, 0.55, 0.45)
const RUN_TEXT_COLOR := Color(0.55, 0.85, 1.0)
const SPRINT_TEXT_COLOR := Color(1.0, 0.85, 0.3)
const DARK_TINT_STRENGTH := 0.7  # max darken fraction at 0% tile light

# Stacked Y offsets so the layers never z-fight each other or the floor.
const RANGE_Y := 0.05
const PATH_Y := 0.08
const DEST_Y := 0.09
const TARGET_Y := 0.06
const TARGET_LABEL_Y := 2.6
const COST_LABEL_Y := 1.0

# Quad edge as a fraction of TILE_SIZE. Path pips are small so the range band
# still reads underneath them.
const RANGE_SIZE := 0.9
const PATH_SIZE := 0.4
const DEST_SIZE := 0.8
const TARGET_SIZE := 1.0

var _run_pool: Array[MeshInstance3D] = []
var _sprint_pool: Array[MeshInstance3D] = []
var _path_pool: Array[MeshInstance3D] = []
var _target_pool: Array[MeshInstance3D] = []
var _target_tiles: Array[Vector3i] = []
var _target_accuracies: Array[int] = []
var _target_label: Label3D
var _cost_label: Label3D
var _dest_quad: MeshInstance3D


func _ready() -> void:
	add_to_group("highlights")
	_dest_quad = _make_quad(DEST_COLOR, DEST_SIZE)
	_target_label = _make_label(TARGET_TEXT_COLOR)
	_cost_label = _make_label(RUN_TEXT_COLOR)


func show_move_range(run_tiles: Array[Vector3i], sprint_tiles: Array[Vector3i]) -> void:
	# `sprint_tiles` is the outer band only — the tiles that cost the second AP.
	# Pass it empty when the unit cannot afford 2 AP.
	_hide_all(_run_pool)
	_hide_all(_sprint_pool)
	for i in run_tiles.size():
		var quad := _at(_run_pool, i, RUN_COLOR, RANGE_SIZE)
		quad.global_position = GridManager.grid_to_world(run_tiles[i]) + Vector3(0, RANGE_Y, 0)
		_tint_by_light(quad, RUN_COLOR, run_tiles[i])
		quad.visible = true
	for i in sprint_tiles.size():
		var quad := _at(_sprint_pool, i, SPRINT_COLOR, RANGE_SIZE)
		quad.global_position = GridManager.grid_to_world(sprint_tiles[i]) + Vector3(0, RANGE_Y, 0)
		_tint_by_light(quad, SPRINT_COLOR, sprint_tiles[i])
		quad.visible = true


func _tint_by_light(quad: MeshInstance3D, base_color: Color, tile: Vector3i) -> void:
	# Sec 4.0: the preview shows light level per tile, so routing through
	# darkness is a visible, deliberate choice rather than a hidden number.
	var t: GridTileData = GridManager.get_tile(tile)
	var lit := t.light_value / 100.0 if t else 1.0
	var mat := quad.material_override as StandardMaterial3D
	mat.albedo_color = base_color.darkened((1.0 - lit) * DARK_TINT_STRENGTH)


func show_path(path: Array[Vector3i], ap_cost: int) -> void:
	# `path` excludes the unit's own tile (see GridManager.find_path); the last
	# entry is the destination and gets the bigger marker plus the AP cost.
	clear_path()
	if path.is_empty():
		return
	for i in path.size() - 1:
		var quad := _at(_path_pool, i, PATH_COLOR, PATH_SIZE)
		quad.global_position = GridManager.grid_to_world(path[i]) + Vector3(0, PATH_Y, 0)
		quad.visible = true
	var dest := GridManager.grid_to_world(path[-1])
	_dest_quad.global_position = dest + Vector3(0, DEST_Y, 0)
	_dest_quad.visible = true
	if ap_cost > 0:
		_cost_label.text = "%d AP" % ap_cost
		_cost_label.modulate = RUN_TEXT_COLOR if ap_cost == 1 else SPRINT_TEXT_COLOR
		_cost_label.global_position = dest + Vector3(0, COST_LABEL_Y, 0)
		_cost_label.visible = true


func show_targets(tiles: Array[Vector3i], accuracies: Array[int]) -> void:
	# Parallel arrays: accuracies[i] is the hit chance against the unit on
	# tiles[i], already resolved for the armed shot type. Every target gets a
	# marker; the hit chance itself is held back for set_hovered_target.
	clear_targets()
	_target_tiles = tiles
	_target_accuracies = accuracies
	for i in tiles.size():
		var quad := _at(_target_pool, i, TARGET_COLOR, TARGET_SIZE)
		quad.global_position = GridManager.grid_to_world(tiles[i]) + Vector3(0, TARGET_Y, 0)
		quad.visible = true


func set_hovered_target(tile: Vector3i) -> void:
	# One label at a time, following the cursor — a percentage over every
	# hostile at once buries the map. Pass a non-target tile to hide it.
	var index := _target_tiles.find(tile)
	if index == -1:
		_target_label.visible = false
		return
	_target_label.text = "%d%%" % _target_accuracies[index]
	_target_label.global_position = GridManager.grid_to_world(tile) + Vector3(0, TARGET_LABEL_Y, 0)
	_target_label.visible = true


func clear_targets() -> void:
	_hide_all(_target_pool)
	_target_tiles = []
	_target_accuracies = []
	_target_label.visible = false


func clear_path() -> void:
	_hide_all(_path_pool)
	_dest_quad.visible = false
	_cost_label.visible = false


func clear_highlights() -> void:
	_hide_all(_run_pool)
	_hide_all(_sprint_pool)
	clear_path()
	clear_targets()


func _at(pool: Array[MeshInstance3D], index: int, color: Color, size_factor: float) -> MeshInstance3D:
	while pool.size() <= index:
		pool.append(_make_quad(color, size_factor))
	return pool[index]


func _make_label(color: Color) -> Label3D:
	var label := Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true  # stays readable through cover and walls
	label.fixed_size = true  # constant on-screen size at any zoom
	label.font_size = 20
	label.outline_size = 5
	label.modulate = color
	label.outline_modulate = Color(0, 0, 0, 0.8)
	label.visible = false
	add_child(label)
	return label


func _hide_all(pool: Array[MeshInstance3D]) -> void:
	for quad in pool:
		quad.visible = false


func _make_quad(color: Color, size_factor: float) -> MeshInstance3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(GridManager.TILE_SIZE * size_factor, GridManager.TILE_SIZE * size_factor)
	var quad := MeshInstance3D.new()
	quad.mesh = mesh
	quad.material_override = material
	quad.visible = false
	add_child(quad)
	return quad
