extends Node3D
## The tile overlays: the move range's border, the path preview with its cost at
## the cursor, the shootable-target markers with their hit chances, and the
## grenade's reach and burst.
##
## THE MOVE RANGE IS TWO BORDERS, XCOM-style, and no fill. Blue rings the tiles a
## soldier can walk to and still take a base Shoot from (reloading first if the
## magazine is empty); yellow rings the rest of what the pool can reach, where the
## walk is the activation's last real act. Movement is priced per tile
## (Unit.MOVE_AP_PER_TILE), so the line between them is not a fixed Run/Sprint
## split but wherever the soldier's own shot price lands against its pool — a
## Reflexes discount, a heavy weapon or a wounded leg each move it honestly. The
## exact price of any one tile is the cursor label's to say.

const BORDER_SHADER := preload("res://shaders/move_border.gdshader")
# Path and destination stay white so they read inside either border.
const PATH_COLOR := Color(1.0, 1.0, 1.0, 0.8)
const DEST_COLOR := Color(1.0, 1.0, 1.0, 0.9)
const TARGET_COLOR := Color(1.0, 0.25, 0.2, 0.6)
# Grenade throw: a green band for reach, a brighter core for the burst footprint.
# Deliberately nothing like the move bands — the two are armed from adjacent
# buttons and a player must never mistake one overlay for the other.
const THROW_COLOR := Color(0.3, 0.9, 0.5, 0.30)
const BLAST_COLOR := Color(0.55, 1.0, 0.75, 0.65)
const TARGET_TEXT_COLOR := Color(1.0, 0.55, 0.45)
## The cursor label out of combat, where a walk has no zone to colour it by.
const COST_TEXT_COLOR := Color(0.85, 0.9, 1.0)
## The cursor label in combat, matching the border the destination sits inside —
## so "8 AP · 2 left" in yellow says outright that the shot is gone.
const COST_TEXT_BLUE := Color(0.5, 0.82, 1.0)
const COST_TEXT_YELLOW := Color(1.0, 0.82, 0.3)
## Screen pixels between the pointer's tip and the bottom of the cost label.
const COST_LABEL_GAP := 14.0
## Over the HUD (layer 1) and PixelView's world (-1): it is the pointer's own
## readout, so nothing may sit on top of it.
const COST_LABEL_LAYER := 2

# Stacked Y offsets so the layers never z-fight each other or the floor.
const RANGE_Y := 0.05
const PATH_Y := 0.08
const DEST_Y := 0.09
const TARGET_Y := 0.06
const TARGET_LABEL_Y := 2.6

# Rim bits, the shader's INSTANCE_CUSTOM layout (shaders/move_border.gdshader).
# Sides in bit order north, east, south, west; each corner names the two sides
# it joins and the diagonal between them.
const _SIDES: Array[Vector3i] = [Vector3i(0, 0, -1), Vector3i(1, 0, 0), Vector3i(0, 0, 1), Vector3i(-1, 0, 0)]
const _CORNERS := [  # [side index a, side index b, diagonal] for NE, SE, SW, NW
	[0, 1, Vector3i(1, 0, -1)], [2, 1, Vector3i(1, 0, 1)],
	[2, 3, Vector3i(-1, 0, 1)], [0, 3, Vector3i(-1, 0, -1)],
]
const _ZONE_BLUE := 0.0
const _ZONE_YELLOW := 1.0

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
## Screen-space, pinned above the mouse pointer rather than floated over the
## destination tile: the number belongs to where the player is looking, and a
## world label drifts off the pointer as the camera tilts or the tile sits on a
## stair.
var _cost_label: Label
var _dest_quad: MeshInstance3D
## One MultiMesh for both borders — see shaders/move_border.gdshader.
var _border: MultiMeshInstance3D
## AP a destination has to leave for the base shot (show_move_range), or -1 when
## no shot is possible from anywhere. What colours the cost label by zone.
var _shot_reserve := -1


func _ready() -> void:
	add_to_group("highlights")
	_dest_quad = _make_quad(DEST_COLOR, DEST_SIZE)
	_target_label = _make_label(TARGET_TEXT_COLOR)
	_border = _make_border()
	_cost_label = _make_cost_label()
	set_process(false)  # only while the cost label is up


func _process(_delta: float) -> void:
	# Every frame, not on input: the label rides the pointer between the frames
	# where the hovered tile (and so the path) actually changes.
	_place_cost_label()


## The move range as two XCOM-style borders: blue round every tile from which a
## base Shoot is still affordable after the walk, yellow round the rest of the
## reach.
##
## `origin` is the unit's own tile, which reachable_costs leaves out but which is
## inside the range (else every border would carry a hole round the soldier).
## `tile_costs` maps each reachable tile to the TILES walked to reach it
## (GridManager.reachable_costs); `ap_per_tile` converts that to AP, so a wounded
## leg shrinks both borders honestly. `shot_reserve` is the AP the soldier must
## still hold to fire on arrival — PlayerUnit.shot_ready_cost, reload included
## when the magazine is dry — or -1 if it cannot fire at all, which leaves only
## the yellow border.
func show_move_range(origin: Vector3i, tile_costs: Dictionary, ap_per_tile: int,
		ap_available: int, shot_reserve: int) -> void:
	_hide_all(_range_pool)
	_hide_all(_blast_pool)
	_shot_reserve = shot_reserve
	var reach := {}
	var blue := {}
	# Ground nobody has mapped is left out of both: a border would trace the
	# room's shape. The tiles are still legal to walk to, and the path preview
	# still answers for the one under the cursor.
	var map := get_tree().get_first_node_in_group("map")
	for tile: Vector3i in tile_costs:
		if map != null and not map.is_explored_tile(tile):
			continue
		reach[tile] = true
		if shot_reserve >= 0 and tile_costs[tile] * ap_per_tile + shot_reserve <= ap_available:
			blue[tile] = true
	if reach.is_empty():
		_border.visible = false
		return
	reach[origin] = true
	if shot_reserve >= 0 and shot_reserve <= ap_available:
		blue[origin] = true
	_build_border(reach, blue)


## One shader instance per rim tile: blue tiles rimmed against everything not
## blue, yellow tiles against everything out of reach. A yellow tile next to a
## blue one draws nothing on that side, so where the two meet there is exactly
## one line, the blue one, and along a wall the line simply changes colour where
## the zones do.
func _build_border(reach: Dictionary, blue: Dictionary) -> void:
	var rims: Array[Vector3i] = []
	var masks: Array[Color] = []
	for tile: Vector3i in reach:
		var is_blue := blue.has(tile)
		var zone := blue if is_blue else reach
		var edges := 0
		var corners := 0
		var inside: Array[bool] = []
		for i in _SIDES.size():
			inside.append(zone.has(tile + _SIDES[i]))
			if not inside[i]:
				edges |= 1 << i
		for i in _CORNERS.size():
			var c: Array = _CORNERS[i]
			if inside[c[0]] and inside[c[1]] and not zone.has(tile + (c[2] as Vector3i)):
				corners |= 1 << i
		if edges == 0 and corners == 0:
			continue
		rims.append(tile)
		masks.append(Color(edges, corners, _ZONE_BLUE if is_blue else _ZONE_YELLOW, 0.0))
	var mm := _border.multimesh
	mm.instance_count = rims.size()
	for i in rims.size():
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY,
			GridManager.grid_to_world(rims[i]) + Vector3(0, RANGE_Y, 0)))
		mm.set_instance_custom_data(i, masks[i])
	_border.visible = not rims.is_empty()


func show_path(path: Array[Vector3i], ap_cost: int, ap_left: int) -> void:
	# `path` excludes the unit's own tile (see GridManager.find_path); the last
	# entry is the destination and gets the bigger marker.
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
		# not say whether this move still leaves a shot; the colour says that.
		var can_shoot := _shot_reserve >= 0 and ap_left >= _shot_reserve
		_show_cost_label("%d AP  ·  %d left" % [ap_cost, ap_left],
			COST_TEXT_BLUE if can_shoot else COST_TEXT_YELLOW)


## A walk out of combat (exploration plan B.5): the same path markers, priced in
## time rather than AP. Nothing is spent or left, so the label says how many steps
## it is and how many rounds it will pass.
func show_explore_path(path: Array[Vector3i], steps: int, rounds: int) -> void:
	show_path(path, 0, 0)
	if path.is_empty():
		return
	_show_cost_label("%d steps  ·  %d round%s" % [steps, rounds, "" if rounds == 1 else "s"],
		COST_TEXT_COLOR)


func _show_cost_label(text: String, color: Color) -> void:
	_cost_label.text = text
	_cost_label.add_theme_color_override("font_color", color)
	_cost_label.visible = true
	_place_cost_label()
	set_process(true)


## Centred over the pointer's tip, and kept on screen.
func _place_cost_label() -> void:
	if not _cost_label.visible:
		return
	var size := _cost_label.get_combined_minimum_size()
	_cost_label.size = size
	var at := get_viewport().get_mouse_position() - Vector2(size.x * 0.5, size.y + COST_LABEL_GAP)
	var screen := get_viewport().get_visible_rect().size
	_cost_label.position = at.clamp(Vector2.ZERO, (screen - size).max(Vector2.ZERO))


## Where a grenade can land, and what the burst would cover if thrown at the tile
## under the cursor.
##
## Filled tiles, unlike the move range's borders: "I can throw here" and "I can
## walk here" must never be confused at a glance, and the two are armed from
## adjacent buttons. Green for the same reason.
func show_throw_range(tiles: Array[Vector3i], blast: Array[Vector3i] = []) -> void:
	_border.visible = false
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
	set_process(false)


func clear_highlights() -> void:
	_border.visible = false
	_shot_reserve = -1
	_hide_all(_range_pool)
	_hide_all(_blast_pool)
	clear_path()
	clear_targets()


## The extraction square of a hangar whose ship is down (GDD §7.4): the tiles
## that decide who goes home, lit for as long as the ship waits.
##
## Its own per-hangar quads, NOT a pool `clear_highlights` empties. Every mode
## change clears the move/target overlays; this must survive all of them, since
## it is state about the deck rather than about the active soldier's order. Keyed
## by hangar index so two landed ships (a merc crew's, Phase 8) are independent.
const SQUARE_COLOR := Color(1.0, 0.85, 0.2, 0.45)
const SQUARE_Y := 0.04  # under the move range (RANGE_Y), over the floor decal
var _square_quads: Dictionary = {}  # hangar index -> Array[MeshInstance3D]


func show_extraction_square(hangar_index: int, tiles: Array) -> void:
	clear_extraction_square(hangar_index)
	var quads: Array[MeshInstance3D] = []
	for tile: Vector3i in tiles:
		var quad := _make_quad(SQUARE_COLOR, RANGE_SIZE)
		quad.global_position = GridManager.grid_to_world(tile) + Vector3(0, SQUARE_Y, 0)
		quad.visible = true
		quads.append(quad)
	_square_quads[hangar_index] = quads


func clear_extraction_square(hangar_index: int) -> void:
	for quad: MeshInstance3D in _square_quads.get(hangar_index, []):
		quad.queue_free()
	_square_quads.erase(hangar_index)


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


func _make_cost_label() -> Label:
	var layer := CanvasLayer.new()
	layer.layer = COST_LABEL_LAYER
	add_child(layer)
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", 22)
	label.add_theme_constant_override("outline_size", 6)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	# A dark pill behind it: the pointer is usually over the white destination
	# marker or a lit floor, where outline alone loses the coloured text.
	var pill := StyleBoxFlat.new()
	pill.bg_color = Color(0.02, 0.03, 0.05, 0.72)
	pill.set_corner_radius_all(4)
	pill.content_margin_left = 8
	pill.content_margin_right = 8
	pill.content_margin_top = 2
	pill.content_margin_bottom = 3
	label.add_theme_stylebox_override("normal", pill)
	label.visible = false
	layer.add_child(label)
	return label


func _make_border() -> MultiMeshInstance3D:
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(GridManager.TILE_SIZE, GridManager.TILE_SIZE)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true  # before instance_count, which allocates the buffer
	mm.mesh = mesh
	var material := ShaderMaterial.new()
	material.shader = BORDER_SHADER
	material.set_shader_parameter("tile_size", GridManager.TILE_SIZE)
	var border := MultiMeshInstance3D.new()
	border.multimesh = mm
	border.material_override = material
	border.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	border.visible = false
	add_child(border)
	return border


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
