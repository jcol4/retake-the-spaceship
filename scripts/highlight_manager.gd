extends Node3D
## Pools flat quad meshes for the tile overlays: the move range graded by AP cost,
## the path preview and its cost drawn on top, and the shootable-target markers
## with their hit chances.
##
## The range used to be TWO bands, blue for a 1 AP run and yellow for the 2 AP
## sprint, because a move was one of two fixed-price actions. Movement is priced
## per tile now (Unit.MOVE_AP_PER_TILE), so the cost is continuous and the bands
## are gone: one set of quads, lerped CHEAP_COLOR -> DEAR_COLOR by what each tile
## costs against the pool. That keeps the old overlay's at-a-glance "near is
## cheap, far is dear" read while giving every candidate destination its own
## price rather than rounding all of them into two buckets.

const CHEAP_COLOR := Color(0.2, 0.7, 1.0, 0.45)
const DEAR_COLOR := Color(1.0, 0.78, 0.1, 0.38)
# Path and destination stay white so they read against either band.
const PATH_COLOR := Color(1.0, 1.0, 1.0, 0.8)
const DEST_COLOR := Color(1.0, 1.0, 1.0, 0.9)
const TARGET_COLOR := Color(1.0, 0.25, 0.2, 0.6)
# Grenade throw: a green band for reach, a brighter core for the burst footprint.
# Deliberately nothing like the move bands — the two are armed from adjacent
# buttons and a player must never mistake one overlay for the other.
const THROW_COLOR := Color(0.3, 0.9, 0.5, 0.30)
const BLAST_COLOR := Color(0.55, 1.0, 0.75, 0.65)
const TARGET_TEXT_COLOR := Color(1.0, 0.55, 0.45)
const COST_TEXT_COLOR := Color(0.55, 0.85, 1.0)
## The path label when the move would leave the unit with nothing — the read the
## player most needs before committing, since a move that empties the pool ends
## the activation.
const COST_TEXT_COLOR_SPENT := Color(1.0, 0.85, 0.3)
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

var _range_pool: Array[MeshInstance3D] = []
var _blast_pool: Array[MeshInstance3D] = []
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
	_cost_label = _make_label(COST_TEXT_COLOR)


## `tile_costs` maps each reachable tile to the number of TILES walked to reach
## it (GridManager.reachable_costs); `ap_per_tile` converts that to AP, and
## `ap_available` is what the unit has to spend — the two together are what grade
## the band, so a unit with an injured leg sees its shorter reach priced honestly
## rather than redrawn at the same colours.
func show_move_range(tile_costs: Dictionary, ap_per_tile: int, ap_available: int) -> void:
	_hide_all(_range_pool)
	_hide_all(_blast_pool)
	var i := 0
	for tile: Vector3i in tile_costs:
		var cost: int = tile_costs[tile] * ap_per_tile
		# Against the pool, not against the reachable radius: the gradient then
		# means "fraction of what you have left", which is the question the player
		# is actually asking, and it stays stable as AP drains within a turn.
		var dearness := float(cost) / float(maxi(ap_available, 1))
		var color := CHEAP_COLOR.lerp(DEAR_COLOR, clampf(dearness, 0.0, 1.0))
		var quad := _at(_range_pool, i, color, RANGE_SIZE)
		quad.global_position = GridManager.grid_to_world(tile) + Vector3(0, RANGE_Y, 0)
		_tint_by_light(quad, color, tile)
		quad.visible = true
		i += 1


func _tint_by_light(quad: MeshInstance3D, base_color: Color, tile: Vector3i) -> void:
	# Sec 4.0: the preview shows light level per tile, so routing through
	# darkness is a visible, deliberate choice rather than a hidden number.
	var t: GridTileData = GridManager.get_tile(tile)
	var lit := t.light_value / 100.0 if t else 1.0
	var mat := quad.material_override as StandardMaterial3D
	mat.albedo_color = base_color.darkened((1.0 - lit) * DARK_TINT_STRENGTH)


func show_path(path: Array[Vector3i], ap_cost: int, ap_left: int) -> void:
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
		# Sec 4.6: what it costs AND what it leaves. The remainder is the number
		# the next decision is made against — under a pool, "4 AP" on its own does
		# not say whether this move still leaves a shot.
		_cost_label.text = "%d AP  ·  %d left" % [ap_cost, ap_left]
		_cost_label.modulate = COST_TEXT_COLOR_SPENT if ap_left <= 0 else COST_TEXT_COLOR
		_cost_label.global_position = dest + Vector3(0, COST_LABEL_Y, 0)
		_cost_label.visible = true


## Where a grenade can land, and what the burst would cover if thrown at the tile
## under the cursor.
##
## Reuses the move-range pool rather than adding a third: only one mode is ever
## armed at a time, so the pool is free, and the colours are set per call anyway
## (see `_tint_by_light`, which already rewrites albedo on every reuse). Green
## rather than the move range's blue/amber gradient, because "I can throw here"
## and "I can walk here" must never be confused at a glance.
func show_throw_range(tiles: Array[Vector3i], blast: Array[Vector3i] = []) -> void:
	_hide_all(_range_pool)
	_hide_all(_blast_pool)
	for i in tiles.size():
		var quad := _at(_range_pool, i, THROW_COLOR, RANGE_SIZE)
		quad.global_position = GridManager.grid_to_world(tiles[i]) + Vector3(0, RANGE_Y, 0)
		_recolor(quad, THROW_COLOR)
		quad.visible = true
	for i in blast.size():
		var quad := _at(_blast_pool, i, BLAST_COLOR, RANGE_SIZE)
		# Above the range band, so the burst footprint reads on top of it.
		quad.global_position = GridManager.grid_to_world(blast[i]) + Vector3(0, PATH_Y, 0)
		_recolor(quad, BLAST_COLOR)
		quad.visible = true


func _recolor(quad: MeshInstance3D, color: Color) -> void:
	(quad.material_override as StandardMaterial3D).albedo_color = color


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
	_hide_all(_range_pool)
	_hide_all(_blast_pool)
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
