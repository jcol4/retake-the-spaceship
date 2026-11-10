class_name MapBuilder
extends Node3D
## Turns a MapData into scene nodes: grid tiles, collision, meshes, cover and
## light fixtures. This is the only half of the map pipeline that needs a scene
## tree — generation and validation both run on MapData alone.

const WALL_HEIGHT := 3.0
const PLATFORM_HEIGHT := 3.0

## Art comes from the room-tile kits in ModuleCatalog (manifests under
## assets/room_tiles/<kit>/). Every socket below falls back to today's
## placeholder when no kit has a piece for it, and collision never comes from
## the art: walls, cover and wrecks build their own boxes either way.
##
## Walls are drawn from EDGES, not cells: every side of a floor, door or
## obstacle cell that touches a WALL cell is a face socket (see
## _build_wall_faces), collinear faces join into runs, and each run is filled
## with kit pieces. Every WALL cell also gets a dark shell (see
## _build_wall_shells): a cap at wall height and side quads wherever no face
## covers it, so a bulkhead reads as solid from any yaw.

## How far a wall piece may be stretched or squeezed along its run so a whole
## number of pieces fills the run exactly. With 2-tile pieces this covers every
## run of 2 or more; a 1-tile run takes a `squash` piece at half length.
const RUN_FIT := 0.25
## Caps sit this far above the wall tops so the two never z-fight.
const CAP_LIFT := 0.01
## A platform's floor sits this far above the platform box's own top face.
const PLATFORM_FLOOR_LIFT := 0.01
const CAP_COLOR := Color(0.09, 0.1, 0.12)
## A door frame's clear opening is this much wider than its DOOR run, so its
## jambs stay just inside the flanking wall cells rather than coplanar with
## the jamb faces drawn there.
const DOOR_CLEARANCE := 0.02
## The widest a scaled door frame's jamb may be, so it never pokes out of the
## wall cell it sits in (one tile, less a margin).
const MAX_JAMB := 1.45

# How far behind a wall to look for floor before calling that wall an obstruction.
# 1 is deliberate, not a first guess: a wall that directly fronts a floor tile IS
# the near-side boundary of a room, and a wall backed by anything else (another
# wall, or the void outside the hull) is far-side structure that has to stay up or
# the deck opens onto nothing. Raising this hides more of the near approach, which
# only becomes wanted if the camera pitch is flattened well below 35 degrees.
const OCCLUSION_DEPTH := 1

## Seconds for a wall to fade out or in after the near side changes. A hard cut
## at the same instant the whole deck swings is two changes at once and reads as
## a glitch; a fade separates them.
const OCCLUSION_FADE := 0.2

# The eight grid steps, indexed by octant of atan2(x, z) — so index 0 is +z and
# the index rises anticlockwise in 45-degree steps. Used to snap a camera yaw onto
# the grid; see _away_step.
const OCCLUSION_STEPS: Array[Vector3i] = [
	Vector3i(0, 0, 1), Vector3i(1, 0, 1), Vector3i(1, 0, 0), Vector3i(1, 0, -1),
	Vector3i(0, 0, -1), Vector3i(-1, 0, -1), Vector3i(-1, 0, 0), Vector3i(-1, 0, 1),
]

var data: MapData
var player_spawns: Array[Vector3i] = []
var enemy_spawns: Array[Vector3i] = []
var swarm_spawns: Array[Vector3i] = []
var brawler_spawns: Array[Vector3i] = []
var merc_spawns: Array[Vector3i] = []
var hunter_spawns: Array[Vector3i] = []
var worm_spawns: Array[Vector3i] = []
## Vector3i -> worms standing there, from the map's `[worms]` section. A spawn
## missing from this is a single worm; see `MapData.worms_at`, which is the one
## place that default lives.
var worm_counts: Dictionary = {}
var nest_spawns: Array[Vector3i] = []
## MapData.Spawn kind -> Array[Vector3i], for the four security-robot types. One
## dictionary rather than four named arrays because the roster is expected to
## change and the spawner iterates it either way.
var cerberus_spawns: Dictionary = {}

## Cell position -> Array of every visual node drawn for that WALL cell: its
## face pieces, its shell and any door frame it flanks. Only visuals are kept,
## because only visuals are ever hidden — see _apply_wall_occlusion. A face
## piece spans several cells, so the same node can sit under several keys.
## Cells whose shell went into the shared MultiMesh (they can never hide; see
## _build_wall_shells) and that have no face are absent.
var _wall_meshes: Dictionary = {}
## WALL cells drawn as the placeholder box because no kit piece fitted, for
## tools/test_kit_coverage.gd.
var placeholder_walls: Dictionary = {}
## Every kit piece placed, as "<socket>:<id>@<where>", in build order — so a
## test can check that one seed gives the same choices twice.
var piece_log: PackedStringArray = []
## [floor cell, side] of every wall lamp hung so far, so a room's own lamps
## never land on a spot a doorway lamp already holds.
var _lamp_spots: Dictionary = {}
var _catalog: ModuleCatalog
## Which grid step currently leads away from the camera. ZERO means "not resolved
## yet", which is also the state on a freshly built map.
var _occlusion_step := Vector3i.ZERO
## Region indices currently holding a player unit, plus the corridors touching
## them. Recomputed each frame; the occlusion pass only re-runs when it changes.
var _revealed: Dictionary = {}
## What `_revealed` was when the wall pass last ran, so that pass can be skipped
## while it would produce the same answer.
var _last_revealed: Dictionary = {}
## Room index the cursor is currently over, or -1. A UI convenience distinct
## from `_revealed`: it opens the near-side wall so the player can see the
## shape of a room they are about to move into, but it is deliberately NOT
## folded into `_revealed` itself, because that dictionary also gates
## `_apply_unit_visibility` — hovering must never be a way to spot an enemy
## you have not actually earned sight of with a unit.
var _hover_room := -1
## What `_hover_room` was when the wall pass last ran, mirroring `_last_revealed`.
var _last_hover_room := -1
## Units a standing soldier has had in line of sight this round (unit -> true).
## They stay drawn until a round ends with nobody seeing them (`_forget_unseen`),
## so a merc ducking behind a crate for one step does not blink out and back.
var _spotted: Dictionary = {}
## Tile -> whether a standing soldier sees it. Valid only while the soldiers stand
## where `_sight_key` says and no cover has been blown off since.
var _sight_cache: Dictionary = {}
var _sight_key: Array = []
var _fade_tween: Tween = null
## Wall nodes mid-fade, and the GeometryInstance3Ds under them whose
## `transparency` the fade drives.
var _fading_out: Array[Node3D] = []
var _fading_in: Array[Node3D] = []
var _fade_out_geo: Array[GeometryInstance3D] = []
var _fade_in_geo: Array[GeometryInstance3D] = []
## Shell meshes by side mask; see _shell_mesh.
var _shell_meshes: Dictionary = {}

## Fog of war over the LAYOUT (see _update_fog). Off for tools that review map
## art without a squad on the deck.
var fog_of_war := true
## Regions the squad has ever stood in or seen into (region -> true). Unlike
## `_revealed` this only grows, until the next build.
var _explored: Dictionary = {}
## Cell -> sorted Array[int] of the regions it is drawn with: a walkable cell's
## own region, and for anything else the nearest regions (see _compute_cell_regions).
var _cell_regions: Dictionary = {}
## Region -> Array[Vector3i] of its GRID tiles, for the sight half of the reveal.
var _region_tiles: Dictionary = {}
## Region key ("3,7") -> the Node3D every visual drawn with those regions sits under.
var _fog_groups: Dictionary = {}
## Fog group -> its regions; shown once any of them is explored.
var _fog_group_regions: Dictionary = {}
## Visual node -> regions, for nodes whose position cannot say which room they
## belong to: batched MultiMeshes (origin at the world origin) and wall faces
## (which belong to the room they face, not to both sides of the wall).
var _fog_explicit: Dictionary = {}
## LightSource -> regions. Lights stay where they are (leaving the tree would
## unregister them from LightingManager), so the fog hides them in place: an
## unexplored room's lamp otherwise throws a pool of light that maps it.
var _fog_lights: Dictionary = {}
## The squad positions the sight reveal last ran against.
var _fog_sight_key: Array = []
## Regions the sight reveal has still to try, and how far into the first one's
## tiles it has got (see _reveal_seen).
var _fog_pending: Array[int] = []
var _fog_tile_index := 0
## Out-of-sight dimming, fog of war's second half: explored floor where an enemy
## would NOT be drawn is drawn darker and drained of colour (out_of_sight.gdshader).
## Without it a room seen through a doorway is lit and drawn edge to edge, reads
## as all-clear, and a horde standing behind its crate seems to be missing rather
## than unseen. The rule is `unit_visible_at`'s, tile by tile: outside every room
## a soldier stands in, and out of every standing soldier's line of sight.
var _dim_mesh: MultiMeshInstance3D
## The squad, revealed and explored state the current dimming answers to.
var _dim_key: Array = []
## Tiles still to test against `_dim_key`, and the out-of-sight set they build. The
## set on screen is swapped for the new one only once every tile is tested, so a
## walk never flickers half-old, half-new.
var _dim_pending: Array[Vector3i] = []
var _dim_next: Array[Vector3i] = []
const SIGHT_DIM_SHADER := preload("res://shaders/out_of_sight.gdshader")
## Above the floor and under every overlay (HighlightManager's lowest is 0.05).
const SIGHT_DIM_LIFT := 0.03
## Microseconds of sight tests the reveal may spend per frame.
const FOG_SIGHT_BUDGET_USEC := 2500
var _building := false

var _wall_mat: StandardMaterial3D
var _cap_mat: StandardMaterial3D
var _floor_mat: StandardMaterial3D
var _platform_mat: StandardMaterial3D
var _stair_mat: StandardMaterial3D
var _cover_light_mat: StandardMaterial3D
var _cover_heavy_mat: StandardMaterial3D


func build(map_data: MapData) -> void:
	data = map_data
	# Findable by units that need the compartment graph at runtime rather than at
	# spawn. The robots are handed a zone once and hold a post; the aliens roam,
	# so they have to ask which room they are standing in NOW — see
	# EnemyUnit._propagate_alert.
	if not is_in_group("map"):
		add_to_group("map")
	# Free whatever a PREVIOUS build left behind. Everything under this node is
	# generated — walls, floors, cover props, lights — so clearing the lot is the
	# whole cleanup.
	#
	# Its absence was a real bug with a nasty signature: `GridManager.clear()`
	# below wipes the logical grid, so a rebuilt deck LOOKED correct in every
	# tile query while the old deck's collision bodies were still physically in
	# the scene. Raycasts — line of sight, lighting occlusion — kept hitting
	# walls from a map that no longer existed. It cost an afternoon: a stale wall
	# from a 20x14 deck sat inside a 40x26 one and read convincingly as "heavy
	# cover blocks line of sight", which is not true and never was.
	#
	# Harmless while `build` was called exactly once per session. Not harmless
	# for a mission restart, a deck reload, or a test that stages a second map.
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_make_materials()
	_catalog = ModuleCatalog.shared()
	_wall_meshes.clear()
	placeholder_walls.clear()
	piece_log = PackedStringArray()
	_lamp_spots.clear()
	_occlusion_step = Vector3i.ZERO  # forces a recompute against the new layout
	_revealed.clear()
	_last_revealed.clear()
	_spotted.clear()
	_sight_cache.clear()
	_sight_key = []
	_explored.clear()
	_fog_groups.clear()
	_fog_group_regions.clear()
	_fog_explicit.clear()
	_fog_lights.clear()
	_fog_sight_key = []
	_fog_pending.clear()
	_fog_tile_index = 0
	_dim_mesh = null
	_dim_key = []
	_dim_pending.clear()
	_dim_next.clear()
	_building = true
	data.compute_rooms()
	_compute_cell_regions()
	if not child_entered_tree.is_connected(_on_child_entered):
		child_entered_tree.connect(_on_child_entered)
	if not TurnManager.turn_ending.is_connected(_forget_unseen):
		TurnManager.turn_ending.connect(_forget_unseen)
	if not GridManager.cover_destroyed.is_connected(_on_cover_destroyed):
		GridManager.cover_destroyed.connect(_on_cover_destroyed)
	if _fade_tween:
		_fade_tween.kill()
	_fading_out = []
	_fading_in = []
	_fade_out_geo = []
	_fade_in_geo = []
	_fade_tween = null
	GridManager.clear()
	# Corner peeking and corner cover ask the map's own world whether a tile
	# edge blocks sight (GridManager.sight_blocked_on).
	GridManager.world_node = self
	# Visuals first, each pass over the whole deck: floors and wall runs are
	# batched or joined across cells, so neither can be drawn one cell at a time.
	# Faces before shells, because a shell leaves out the sides a face covers and
	# skips the cells that fell back to a placeholder box.
	_build_floors()
	_build_wall_faces()
	_build_wall_shells()
	_build_door_frames()
	for pos: Vector3i in data.cells:
		_build_cell(pos, data.get_cell(pos))
	if data.seed != 0 and not data.authored_layout:
		_build_wall_lamps()
	# After every cell, because an edge prop registers itself against the tiles on
	# BOTH sides and those tiles have to exist first.
	for entry: Array in data.cover_edge_list():
		_add_cover_edge(entry[0], entry[1], entry[2])
	for entry: Array in data.obstacles:
		_add_cover_block(entry[0], entry[1], StringName(entry[2]) if entry.size() > 2 else &"crate", float(entry[3]) if entry.size() > 3 else 1.0, String(entry[4]) if entry.size() > 4 else "", int(entry[5]) if entry.size() > 5 else 0)
	for entry: Array in data.dressing:
		var p := _catalog.piece(String(entry[0]))
		if p.is_empty(): continue
		var node := _catalog.instance(p)
		add_child(node)
		node.transform = entry[1]
	for entry: Array in data.wall_pieces:
		var p := _catalog.piece(String(entry[0]))
		if p.is_empty(): continue
		var node := _catalog.instance(p)
		add_child(node)
		node.transform = ParcelTransform.wall_transform(Vector2i(entry[1].x, entry[1].z), entry[2], entry[3] if entry.size() > 3 else Vector3.ZERO)
	for footprint: Rect2i in data.wrecks:
		_add_wreck(footprint)
	for link: Array in data.stair_links:
		GridManager.add_stair_link(link[0], link[1])
	for h: MapData.Hangar in data.hangars:
		_add_hangar_markings(h)
	# Loot crates (extraction plan 3.2), after the tiles exist: each one makes its
	# own tile impassable, and the old deck's crates and piles were freed with
	# the rest of this node's children above.
	LootManager.build_from(self, data)
	player_spawns = data.spawns(MapData.Spawn.PLAYER)
	enemy_spawns = data.spawns(MapData.Spawn.ENEMY)
	swarm_spawns = data.spawns(MapData.Spawn.SWARM)
	brawler_spawns = data.spawns(MapData.Spawn.BRAWLER)
	merc_spawns = data.spawns(MapData.Spawn.MERC)
	hunter_spawns = data.spawns(MapData.Spawn.HUNTER)
	worm_spawns = data.spawns(MapData.Spawn.WORM)
	worm_counts = data.worm_counts.duplicate()
	nest_spawns = data.spawns(MapData.Spawn.NEST)
	cerberus_spawns.clear()
	for kind: int in MapData.CERBERUS_SPAWNS:
		cerberus_spawns[kind] = data.spawns(kind)
	build_ground_collision()
	_assign_fog()
	var systems := RoomSystems.new()
	systems.name = "RoomSystems"
	add_child(systems)
	systems.setup(self)
	# The squad watches its own landing: the insertion bay is known ground.
	var insertion := data.insertion_hangar()
	if insertion != null and data.room_index_at(insertion.pad_center) >= 0:
		_explored[data.room_index_at(insertion.pad_center)] = true
	_apply_fog()
	# After _assign_fog, which would otherwise file it under a room's fog group.
	_build_sight_dim()
	_building = false
	LightingManager.recompute_base()


func _build_cell(pos: Vector3i, cell: MapData.Cell) -> void:
	var world := cell_to_world(pos)
	match cell.terrain:
		MapData.Terrain.VOID:
			return
		MapData.Terrain.WALL:
			# Drawn by the wall passes in build(); every WALL cell blocks LOS,
			# however it's drawn.
			_add_wall_collision(world)
			return
		MapData.Terrain.PLATFORM:
			# The block is solid; the walkable tile is its top surface.
			GridManager.add_tile(data.walkable_pos(pos), world + Vector3(0, PLATFORM_HEIGHT, 0))
			_add_platform(world)
			return
		MapData.Terrain.OBSTACLE:
			# No GridManager.add_tile: identical to WALL, this is what makes the
			# tile unwalkable. The mesh+collision for the whole footprint is
			# built once from data.obstacles (see build()), not per cell, since
			# one furniture piece spans several of these.
			return
	GridManager.add_tile(pos, world)
	if cell.fixture == MapData.Fixture.ALARM:
		# Not a light. Recorded on the tile so `Unit.move_along` can trip it by
		# walking, which is the only way it ever fires.
		var t: GridTileData = GridManager.get_tile(pos)
		if t:
			t.alarm = true
		if data.light_specs.has(pos): _add_light(pos, cell.fixture)
	elif cell.fixture != MapData.Fixture.NONE:
		_add_light(pos, cell.fixture)


func cell_to_world(pos: Vector3i) -> Vector3:
	# Cell space -> world. Deck 0 sits at y = 0; a cell's world position is the
	# *base* of whatever is built on it, not the tile a unit stands on.
	return Vector3(pos.x * GridManager.TILE_SIZE, pos.y * GridManager.FLOOR_HEIGHT, pos.z * GridManager.TILE_SIZE)


func _make_materials() -> void:
	_wall_mat = _mat(Color(0.25, 0.27, 0.32))
	_cap_mat = _mat(CAP_COLOR)
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
	shape.name = "Shape"  # CoverObject.set_tier resizes this alongside the mesh
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


## Invisible collision only — layer 1, sized to fill exactly one WALL cell.
## Every WALL cell gets one of these regardless of how it is drawn, because
## LOS (GridManager.has_line_of_sight) and lighting occlusion (has_clear_line)
## both raycast layer 1: a wall drawn by a module spanning five tiles must
## still block a shot at each of those five tiles individually.
func _add_wall_collision(world: Vector3) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(GridManager.TILE_SIZE, WALL_HEIGHT, GridManager.TILE_SIZE)
	shape.shape = box
	body.add_child(shape)
	add_child(body)
	body.global_position = world + Vector3(0, WALL_HEIGHT / 2.0, 0)


## The placeholder box for a WALL cell no kit piece could draw. Visual only;
## _add_wall_collision supplies the matching collision separately.
func _add_wall_placeholder(world: Vector3) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(GridManager.TILE_SIZE, WALL_HEIGHT, GridManager.TILE_SIZE)
	mesh_instance.mesh = box_mesh
	mesh_instance.material_override = _wall_mat
	add_child(mesh_instance)
	mesh_instance.global_position = world + Vector3(0, WALL_HEIGHT / 2.0, 0)
	return mesh_instance


func _add_placeholder_wall(pos: Vector3i) -> void:
	if placeholder_walls.has(pos):
		return
	placeholder_walls[pos] = true
	_register_wall(pos, _add_wall_placeholder(cell_to_world(pos)))


func _register_wall(pos: Vector3i, node: Node3D) -> void:
	if not _wall_meshes.has(pos):
		_wall_meshes[pos] = []
	_wall_meshes[pos].append(node)


## Variant hash for a socket on this deck: the deck seed plus whatever names
## the socket. Never `_rng` or randi() — co-op peers rebuild the deck from the
## seed alone and must land on the same pieces.
func _socket_hash(parts: Array) -> int:
	return ModuleCatalog.hash_of([data.seed] + parts)


## A kit piece's wrapper (origin on the socket, +Z toward the room), added
## under this builder and logged for the determinism check.
func _place_piece(p: Dictionary, where: String) -> Node3D:
	var inst := _catalog.instance(p)
	add_child(inst)
	piece_log.append("%s:%s@%s" % [p.socket, p.id, where])
	return inst


## One MultiMeshInstance3D per mesh in `parts` ([Mesh, Transform3D] pairs, as
## ModuleCatalog.mesh_parts gives them), drawn once per transform in `xforms`.
## `regions` is what the fog draws them with: a batch never spans two keys.
func _add_multimesh(parts: Array, xforms: Array, shadows: bool, regions: Array, material: Material = null) -> void:
	for part: Array in parts:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = part[0]
		mm.instance_count = xforms.size()
		for i in xforms.size():
			mm.set_instance_transform(i, xforms[i] * part[1])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = material
		if not shadows:
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi)
		_fog_explicit[mmi] = regions


## One kit floor tile per non-VOID cell — under walls and obstacles too, since
## kit walls and cover don't fill their cells — batched into one
## MultiMeshInstance3D per piece: a 72x48 deck is 3,456 cells. A platform's
## floor goes on its top. Stair cells take the `stair_floor` socket so they stay
## visibly different. Visual only; clicks hit the shared ground body.
func _build_floors() -> void:
	var by_piece: Dictionary = {}  # [piece id, regions] -> Array[Transform3D]
	for pos: Vector3i in data.cells:
		var cell: MapData.Cell = data.get_cell(pos)
		if cell.terrain == MapData.Terrain.VOID:
			continue
		var world := cell_to_world(pos)
		if cell.terrain == MapData.Terrain.PLATFORM:
			world.y += PLATFORM_HEIGHT + PLATFORM_FLOOR_LIFT
		var socket := "stair_floor" if cell.stair else "floor"
		var p := _catalog.pick(socket, _socket_hash([socket, pos]))
		if p.is_empty():
			_add_floor_quad(world, _stair_mat if cell.stair else _floor_mat)
			continue
		piece_log.append("%s:%s@%s" % [socket, p.id, pos])
		var key := [p.id, _cell_regions.get(pos, []), RoomTypes.floor_of(data.room_type_at(pos))]
		if not by_piece.has(key):
			by_piece[key] = []
		by_piece[key].append(Transform3D(Basis.IDENTITY, world))
	for key: Array in by_piece:
		var material: Material = null
		if not String(key[2]).is_empty():
			material = load("res://assets/room_tiles/floors/floor_%s.tres" % key[2])
		_add_multimesh(_catalog.mesh_parts(_catalog.piece(key[0])), by_piece[key], false, key[1], material)


## Whether `pos`'s sides toward a WALL are seen from the room: floor and
## doorways, and obstacle cells too, because kit cover doesn't fill its cell and
## the wall behind a crate shows around it.
func _faces_walls(pos: Vector3i) -> bool:
	return data.terrain_at(pos) in [MapData.Terrain.FLOOR, MapData.Terrain.DOOR, MapData.Terrain.OBSTACLE]


## Every side of a face cell (_faces_walls) whose neighbour is WALL is a face
## socket: the middle of that boundary, facing the face cell. Collinear sockets
## on consecutive cells join into one run, and _fill_face_run fills each run
## along its whole length.
func _build_wall_faces() -> void:
	var lines: Dictionary = {}  # Vector3i(side, deck, coord across) -> Array[int] coords along
	for pos: Vector3i in data.cells:
		if not _faces_walls(pos):
			continue
		for side: int in 4:
			if data.terrain_at(pos + MapData.SIDE_STEP[side]) != MapData.Terrain.WALL:
				continue
			var key := Vector3i(side, pos.y, _across(pos, side))
			if not lines.has(key):
				lines[key] = []
			lines[key].append(_along(pos, side))
	for key: Vector3i in lines:
		var coords: Array = lines[key]
		coords.sort()
		var lo: int = coords[0]
		for i in range(1, coords.size() + 1):
			if i < coords.size() and coords[i] == coords[i - 1] + 1:
				continue
			_fill_face_run(key.x, _on_line(key, lo), coords[i - 1] - lo + 1)
			if i < coords.size():
				lo = coords[i]


## The grid step a face run on `side` advances by: along X for a wall to the
## north or south, along Z for one to the east or west.
func _run_step(side: int) -> Vector3i:
	return Vector3i(1, 0, 0) if MapData.SIDE_STEP[side].z != 0 else Vector3i(0, 0, 1)


func _along(pos: Vector3i, side: int) -> int:
	return pos.x if MapData.SIDE_STEP[side].z != 0 else pos.z


func _across(pos: Vector3i, side: int) -> int:
	return pos.z if MapData.SIDE_STEP[side].z != 0 else pos.x


## The face cell at `along` on the run line `key` (see _build_wall_faces).
func _on_line(key: Vector3i, along: int) -> Vector3i:
	return Vector3i(along, key.y, key.z) if MapData.SIDE_STEP[key.x].z != 0 \
		else Vector3i(key.z, key.y, along)


## Fills one run of `n` face sockets, starting at face cell `first`, with one
## wall variant — picked per run, so a stretch of wall reads as one surface.
## The pieces are stretched or squeezed by up to RUN_FIT so a whole number of
## them spans the run exactly, and a 1-tile run takes a `squash` piece at half
## length. Each piece registers with every WALL cell it covers, so occlusion
## hides it only when all of them hide. A run no piece can fill falls back to
## the placeholder box on each of its WALL cells.
func _fill_face_run(side: int, first: Vector3i, n: int) -> void:
	var step: Vector3i = MapData.SIDE_STEP[side]
	var along := _run_step(side)
	var h := _socket_hash(["wall_face", first, side])
	var widths: Array = []
	var p := _catalog.pick("wall_face", h,
		func(q: Dictionary) -> bool: return not _fit_run(n, int(q.tiles)).is_empty())
	if not p.is_empty():
		widths = _fit_run(n, int(p.tiles))
	elif n == 1:
		p = _catalog.pick("wall_face", h, func(q: Dictionary) -> bool: return q.get("squash", false))
		widths = [1.0]
	if p.is_empty():
		for i in n:
			_add_placeholder_wall(first + along * i + step)
		return
	var yaw := atan2(float(-step.x), float(-step.z))
	var start := 0.0
	for w: float in widths:
		var node := _place_piece(p, "%s/%d+%.2f" % [first, side, start])
		# Tiles from `first`'s centre to the piece's middle, along the run.
		var centre := start + w / 2.0 - 0.5
		node.global_position = cell_to_world(first) + Vector3(along) * (centre * GridManager.TILE_SIZE) \
			+ Vector3(step) * (GridManager.TILE_SIZE / 2.0)
		node.rotation.y = yaw
		node.scale = Vector3(w / float(p.tiles), 1.0, 1.0)
		var faced: Array[Vector3i] = []
		for i in range(floori(start + 0.001), ceili(start + w - 0.001)):
			_register_wall(first + along * i + step, node)
			faced.append(first + along * i)
		# The room this face looks into, not both sides of the wall: the far
		# side's face is drawn by its own run, with its own room.
		_fog_explicit[node] = _regions_of_cells(faced)
		start += w


## How a run of `n` tiles splits into pieces `length` tiles long: the piece
## count needing the least stretch or squeeze, within RUN_FIT, as each piece's
## width in tiles — or empty when no count fits. A kit with several lengths
## for one variant would pack longest-first here; this kit has one.
func _fit_run(n: int, length: int) -> Array:
	var best := 0
	var best_err := INF
	for k: int in [n / length, n / length + 1]:
		if k < 1:
			continue
		var f := float(n) / float(k * length)
		if absf(f - 1.0) > RUN_FIT + 0.0001:
			continue
		if absf(log(f)) < best_err:
			best = k
			best_err = absf(log(f))
	var out: Array = []
	for i in best:
		out.append(float(n) / best)
	return out


## Every WALL cell not drawn as a placeholder gets a dark shell: a cap at wall
## height (kit walls are built for first person and have no top) and a side
## quad on each side no face covers — toward the void outside the hull, and
## toward other WALL cells, so a neighbour hidden by occlusion leaves this one
## looking solid rather than hollow.
##
## A cell with no walkable cell among its 8 neighbours can never be hidden
## (_hides_interior only looks one step past a wall, diagonals included), so
## those share one MultiMeshInstance3D per side mask. The rest are individual
## nodes registered with occlusion, or they'd float when their faces hide.
func _build_wall_shells() -> void:
	var batched: Dictionary = {}  # [side mask, regions] -> Array[Transform3D]
	for pos: Vector3i in data.cells:
		if data.terrain_at(pos) != MapData.Terrain.WALL or placeholder_walls.has(pos):
			continue
		var mask := 0
		for side: int in 4:
			if data.terrain_at(pos + MapData.SIDE_STEP[side]) in [MapData.Terrain.VOID, MapData.Terrain.WALL]:
				mask |= 1 << side
		var world := cell_to_world(pos)
		if not _can_hide(pos):
			var key := [mask, _cell_regions.get(pos, [])]
			if not batched.has(key):
				batched[key] = []
			batched[key].append(Transform3D(Basis.IDENTITY, world))
			continue
		var shell := MeshInstance3D.new()
		shell.mesh = _shell_mesh(mask)
		add_child(shell)
		shell.global_position = world
		_register_wall(pos, shell)
	for key: Array in batched:
		_add_multimesh([[_shell_mesh(key[0]), Transform3D.IDENTITY]], batched[key], true, key[1])


## Whether occlusion could ever hide WALL cell `pos` — the same look one step
## past it, in all eight directions, that _hides_interior makes.
func _can_hide(pos: Vector3i) -> bool:
	for step: Vector3i in OCCLUSION_STEPS:
		for i in range(1, OCCLUSION_DEPTH + 1):
			if data.is_walkable(pos + step * i):
				return true
	return false


## A cell's shell: the cap, plus a side quad for each Side bit set in `mask`.
## Origin at the cell's floor centre. One mesh per mask, shared.
func _shell_mesh(mask: int) -> Mesh:
	if _shell_meshes.has(mask):
		return _shell_meshes[mask]
	var half := GridManager.TILE_SIZE / 2.0
	var top := WALL_HEIGHT + CAP_LIFT
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_quad(st, Vector3.UP, [Vector3(-half, top, -half), Vector3(half, top, -half),
		Vector3(half, top, half), Vector3(-half, top, half)])
	for side: int in 4:
		if mask & (1 << side) == 0:
			continue
		var n := Vector3(MapData.SIDE_STEP[side])
		var t := Vector3(-n.z, 0.0, n.x) * half
		var c := n * half
		_quad(st, n, [c - t, c + t, c + t + Vector3(0, top, 0), c - t + Vector3(0, top, 0)])
	var mesh := st.commit()
	mesh.surface_set_material(0, _cap_mat)
	_shell_meshes[mask] = mesh
	return mesh


## Two triangles over `corners` (a loop, either direction), wound so the
## quad's front faces `normal` — Godot culls by clockwise front faces.
func _quad(st: SurfaceTool, normal: Vector3, corners: Array) -> void:
	var a: Vector3 = corners[0]
	if (corners[1] - a).cross(corners[2] - a).dot(normal) > 0.0:
		corners.reverse()
		a = corners[0]
	for i: int in [0, 1, 2, 0, 2, 3]:
		st.set_normal(normal)
		st.add_vertex(corners[i])


## A kit frame centred on each DOOR run, on the wall line, scaled across so its
## clear opening spans the run (plus DOOR_CLEARANCE): the jambs land in the
## flanking wall cells, and only the lintel, above the opening's top, crosses
## the DOOR tiles. The doorway itself stays open. A frame whose jambs would be
## wider than MAX_JAMB at that scale is passed over; with none left, the run
## stays a plain opening, which is the placeholder look.
func _build_door_frames() -> void:
	var seen: Dictionary = {}
	for pos: Vector3i in data.cells:
		if data.terrain_at(pos) != MapData.Terrain.DOOR or seen.has(pos):
			continue
		var along := _door_axis(pos)
		var lo := pos
		while data.terrain_at(lo - along) == MapData.Terrain.DOOR:
			lo -= along
		var hi := pos
		while data.terrain_at(hi + along) == MapData.Terrain.DOOR:
			hi += along
		var n := 1 + absi(_coord(hi, along) - _coord(lo, along))
		for i in n:
			seen[lo + along * i] = true
		_add_door_lamps(lo, hi, along)
		var width := n * GridManager.TILE_SIZE + DOOR_CLEARANCE
		var p := _catalog.pick("door_frame", _socket_hash(["door_frame", lo]),
			func(q: Dictionary) -> bool: return _jamb_width(q, width) <= MAX_JAMB)
		if p.is_empty():
			continue
		var node := _place_piece(p, str(lo))
		node.global_position = (cell_to_world(lo) + cell_to_world(hi)) / 2.0
		node.rotation.y = 0.0 if along.x != 0 else PI / 2.0
		node.scale = Vector3(width / float(p.opening[0]), 1.0, 1.0)
		for flank: Vector3i in [lo - along, hi + along]:
			if data.terrain_at(flank) == MapData.Terrain.WALL:
				_register_wall(flank, node)


## A wall lamp either side of the doorway lo..hi, on both rooms' sides of the
## wall, so a doorway is marked by a pair of lamps from whichever room it is
## seen. Each lamp hangs on the face of a WALL cell flanking the run, slid to
## the half of it away from the door: the frame's jamb covers up to
## DOOR_LAMP_CLEAR of the face next to the opening. Where the doorway opens
## straight into a corridor, the flank has no face on that side, and the lamp
## goes on the corridor's own wall beside the opening instead. Lamps light the
## doorway itself (DOOR_LAMP_RANGE tiles), so they are real LightSources like
## every other, but shadowless: a deck has many doors.
func _add_door_lamps(lo: Vector3i, hi: Vector3i, along: Vector3i) -> void:
	var across := Vector3i(along.z, 0, along.x)
	var room_on_face := GridManager.TILE_SIZE - DOOR_LAMP_CLEAR - DOOR_LAMP_MARGIN
	for end: Vector3i in [lo, hi]:
		var out := -along if end == lo else along
		var flank := end + out
		if data.terrain_at(flank) != MapData.Terrain.WALL:
			continue
		for d: Vector3i in [across, -across]:
			var cell := flank + d
			var side := MapData.SIDE_STEP.find(-d)
			# From the face's middle to the middle of the clear part, away from the door.
			var slide := Vector3(out) * (GridManager.TILE_SIZE / 2.0 - DOOR_LAMP_MARGIN - room_on_face / 2.0)
			if not _wall_sides(cell).has(side):
				cell = end + d
				side = MapData.SIDE_STEP.find(out)
				slide = Vector3.ZERO
				if not _wall_sides(cell).has(side):
					continue
			var source := LightSource.new()
			source.light_range = DOOR_LAMP_RANGE
			source.intensity = DOOR_LAMP_INTENSITY
			source.light_color = Color(0.85, 0.92, 1.0)
			source.casts_shadows = false
			_add_wall_lamp(source, cell, side, slide)


## The wall line a DOOR cell sits in: along X when a WALL or DOOR flanks it to
## the east or west, else along Z.
func _door_axis(pos: Vector3i) -> Vector3i:
	for side: int in [MapData.Side.EAST, MapData.Side.WEST]:
		if data.terrain_at(pos + MapData.SIDE_STEP[side]) in [MapData.Terrain.WALL, MapData.Terrain.DOOR]:
			return Vector3i(1, 0, 0)
	return Vector3i(0, 0, 1)


func _coord(pos: Vector3i, along: Vector3i) -> int:
	return pos.x if along.x != 0 else pos.z


## How wide each of door frame `p`'s jambs is once its opening is scaled to
## `width` metres.
func _jamb_width(p: Dictionary, width: float) -> float:
	return (float(p.outer_width) - float(p.opening[0])) / 2.0 * width / float(p.opening[0])


func _add_platform(world: Vector3) -> void:
	_add_box_body(world, Vector3(GridManager.TILE_SIZE, PLATFORM_HEIGHT, GridManager.TILE_SIZE), _platform_mat, 1)


## Thickness of an edge prop across the boundary it sits on. Thin on purpose:
## the prop must straddle the line between two tiles without reaching either
## tile's centre, which is what keeps it from ever being depth-coincident with a
## unit sprite standing there.
const COVER_THICKNESS := 0.3
## Length along the boundary, as a fraction of a tile. Short of 1.0 so the gap at
## each end reads as a corner rather than as a continuous wall.
const COVER_SPAN := 0.9


func _add_cover_edge(pos: Vector3i, side: int, cover_type: int) -> void:
	# Cover collides on layer 4 only — LOS rays (mask 1) pass over it, and the
	# accuracy penalty represents it instead. Sec 6.1.
	var step: Vector3i = MapData.SIDE_STEP[side]
	# The boundary itself: half a tile from the centre, along the edge's normal.
	var world := cell_to_world(pos) + Vector3(step) * (GridManager.TILE_SIZE * 0.5)
	var height: float = CoverObject.TIER_HEIGHT[cover_type]
	var along := GridManager.TILE_SIZE * COVER_SPAN
	var size := Vector3(COVER_THICKNESS, height, along) if step.x != 0 \
		else Vector3(along, height, COVER_THICKNESS)
	var heavy := cover_type == MapData.Cover.HEAVY
	var body := _add_box_body(world, size, _cover_heavy_mat if heavy else _cover_light_mat, 4)
	body.set_script(load("res://scripts/cover_object.gd"))
	body.call("register_with_grid", pos, side, cover_type)


## One block-cover piece (MapData.obstacles): a box spanning the whole
## footprint, blocking movement by never getting a GridManager tile (see the
## OBSTACLE branch above) and giving its neighbours the usual accuracy bonus
## via GridManager.register_cover_block — one shared HP pool across the whole
## footprint, not one independent pool per edge. Collision is layer 4, same as
## ordinary edge cover: neither tier blocks line of sight (Sec 6.1), only
## movement, so this is not built like a wall.
func _add_cover_block(footprint: Rect2i, tier: int, kind: StringName = &"crate", hp_scale := 1.0, piece_id := "", rot := 0) -> void:
	var first := cell_to_world(Vector3i(footprint.position.x, 0, footprint.position.y))
	var last := cell_to_world(Vector3i(footprint.position.x + footprint.size.x - 1, 0, footprint.position.y + footprint.size.y - 1))
	var center := (first + last) / 2.0
	var size := Vector3(
		footprint.size.x * GridManager.TILE_SIZE,
		CoverObject.TIER_HEIGHT[tier],
		footprint.size.y * GridManager.TILE_SIZE,
	)
	var mat := _cover_heavy_mat if tier == MapData.Cover.HEAVY else _cover_light_mat
	var body := _add_box_body(center, size, mat, 5 if tier == MapData.Cover.HEAVY and kind != &"crate" else 4)
	body.set_script(load("res://scripts/cover_block.gd"))
	body.set("kind", kind)
	# No floor material: _build_floors already drew floor under the footprint,
	# so a destroyed block has nothing to lay down.
	body.call("setup", footprint, 0, tier, null, GridManager.TILE_SIZE, GridManager.FLOOR_HEIGHT)
	_dress_cover_block(body, footprint, tier, kind, piece_id, rot)
	var edge := GridManager.register_cover_block(footprint, 0, tier, body)
	edge.hp = 8 if kind in [&"fuel_tank", &"gas", &"panel"] else maxi(1, roundi(edge.hp * hp_scale))


## Swaps a cover block's placeholder box for kit cover: one piece per footprint
## cell (or `per_cell` copies in a 2x2 grid inside it), each turned a quarter
## turn by hash so a row of crates doesn't repeat exactly. The body and its
## BoxShape3D stay exactly as they were — only the "Mesh" child goes — and the
## art is parented to the body, so CoverBlock.on_destroyed frees it with the rest.
func _dress_cover_block(body: StaticBody3D, footprint: Rect2i, tier: int, kind: StringName = &"crate", piece_id := "", rot := 0) -> void:
	if piece_id != "":
		var exact := _catalog.piece(piece_id)
		if exact.is_empty():
			push_error("Unknown authored piece: " + piece_id)
			return
		body.get_node("Mesh").queue_free()
		var node := _catalog.instance(exact)
		body.add_child(node)
		node.position = Vector3(0, -CoverObject.TIER_HEIGHT[tier] / 2.0, 0)
		node.rotation.y = -rot * PI / 2.0
		piece_log.append("authored:%s@%s" % [piece_id, footprint])
		return
	var furniture_socket := ("hazard_" if kind in [&"fuel_tank", &"gas", &"panel"] else "furniture_") + String(kind)
	var furniture := _catalog.pick(furniture_socket, _socket_hash([kind, footprint]), func(p: Dictionary) -> bool:
		var a: Array = p.get("footprint", [1, 1])
		var matching := Vector2i(a[0], a[1]) == footprint.size or Vector2i(a[1], a[0]) == footprint.size
		return matching and p.get("tier", "light") == ("heavy" if tier == MapData.Cover.HEAVY else "light"))
	if not furniture.is_empty():
		var mesh := body.get_node("Mesh")
		body.remove_child(mesh)
		mesh.free()
		var node := _catalog.instance(furniture)
		body.add_child(node)
		node.global_position = body.global_position - Vector3(0, CoverObject.TIER_HEIGHT[tier] / 2.0, 0)
		var a: Array = furniture.get("footprint", [1, 1])
		if Vector2i(a[0], a[1]) != footprint.size:
			node.rotation.y = PI / 2.0
		piece_log.append("%s:%s@%s" % [furniture_socket, furniture.id, footprint])
		return
	var socket := "cover_heavy" if tier == MapData.Cover.HEAVY else "cover_light"
	var p := _catalog.pick(socket, _socket_hash([socket, footprint]))
	if p.is_empty():
		return
	var mesh := body.get_node("Mesh")
	body.remove_child(mesh)
	mesh.free()
	var copies := int(p.get("per_cell", 1))
	var spread := GridManager.TILE_SIZE / 4.0
	for z in range(footprint.position.y, footprint.end.y):
		for x in range(footprint.position.x, footprint.end.x):
			var cell := Vector3i(x, 0, z)
			for i in copies:
				var node := _catalog.instance(p)
				body.add_child(node)
				var offset := Vector3.ZERO
				if copies > 1:
					offset = Vector3((i % 2) * 2 - 1, 0, (i / 2) * 2 - 1) * spread
				node.global_position = cell_to_world(cell) + offset
				node.rotation.y = posmod(_socket_hash([socket, cell, i]), 4) * PI / 2.0
	piece_log.append("%s:%s@%s" % [socket, p.id, footprint])


## One hangar wreck (MapData.wrecks): a box body over the whole footprint,
## drawn as one of ShipModel.WRECKS. Unlike a cover block it is collision LAYER
## 1 at full wall height, so it blocks line of sight and light exactly as a
## bulkhead does (both raycast layer 1), and its neighbours get HEAVY cover from
## it that never wears down (CoverEdge.indestructible). Its cells get no
## GridManager tile — the OBSTACLE branch of `_build_cell` — which is what makes
## it impassable.
##
## Only the box's "Mesh" child is swapped for the ship, as _dress_cover_block
## does: the body and its BoxShape3D are the rules' wreck, and stay. The ship is
## laid whichever way round fits it largest, flipped end for end by hash, and
## kept WRECK_MARGIN inside the footprint so no part of it hangs over a walkable
## tile. With the model missing, the dark box stays.
const WRECK_COLOR := Color(0.2, 0.19, 0.18)
const WRECK_MARGIN := 0.15


func _add_wreck(footprint: Rect2i) -> void:
	var first := cell_to_world(Vector3i(footprint.position.x, 0, footprint.position.y))
	var last := cell_to_world(Vector3i(footprint.position.x + footprint.size.x - 1, 0,
		footprint.position.y + footprint.size.y - 1))
	var size := Vector3(footprint.size.x * GridManager.TILE_SIZE, WALL_HEIGHT,
		footprint.size.y * GridManager.TILE_SIZE)
	var body := _add_box_body((first + last) / 2.0, size, _mat(WRECK_COLOR), 1)
	body.name = "Wreck_%d_%d" % [footprint.position.x, footprint.position.y]
	_dress_wreck(body, size, footprint)
	var edge := GridManager.register_cover_block(footprint, 0, MapData.Cover.HEAVY, body)
	edge.indestructible = true


func _dress_wreck(body: StaticBody3D, size: Vector3, footprint: Rect2i) -> void:
	if data.wreck_specs.has(footprint):
		var spec: Array = data.wreck_specs[footprint]
		var piece := _catalog.piece(String(spec[0]))
		if not piece.is_empty():
			var mesh := body.get_node("Mesh")
			body.remove_child(mesh)
			mesh.free()
			var node := _catalog.instance(piece)
			body.add_child(node)
			node.position.y = -size.y / 2
			node.rotation.y = -int(spec[1]) * PI / 2
			piece_log.append("authored_wreck:%s@%s" % [spec[0], footprint])
		return
	var h := _socket_hash(["wreck", footprint])
	var path: String = ShipModel.WRECKS[posmod(h, ShipModel.WRECKS.size())]
	var room := size - Vector3(WRECK_MARGIN * 2.0, 0.0, WRECK_MARGIN * 2.0)
	var ship := ShipModel.fitted(path, room, 0.0, true)
	if ship == null:
		return
	var mesh := body.get_node("Mesh")
	body.remove_child(mesh)
	mesh.free()
	body.add_child(ship)
	ship.position = Vector3(0, -size.y / 2.0, 0)  # the body sits at mid-height
	# End for end by hash: a half turn keeps the fit.
	ship.rotation.y = PI if posmod(h >> 4, 2) == 1 else 0.0
	piece_log.append("wreck:%s@%s" % [path.get_file().get_basename(), footprint])


## Hangar floor markings (GDD §7.2), placeholder art until the hangar room module
## on the art list exists: a dark pad where the ship sets down with a lighter
## inner ring, and a hazard-yellow decal on the 3x3 extraction square so the
## tiles that decide who goes home are legible at a glance from the first round.
##
## Decals only — no tile, no collision, no occupancy — so a hangar plays exactly
## like any other floor until a ship is involved. The square's brighter "ship is
## here, get in" highlight is HighlightManager's, shown only while landed.
const HANGAR_PAD_COLOR := Color(0.16, 0.17, 0.2)
const HANGAR_PAD_RING_COLOR := Color(0.85, 0.55, 0.15)
const HANGAR_SQUARE_COLOR := Color(0.95, 0.8, 0.15, 0.35)
## Height of the decals above the floor quad, under HighlightManager's lowest
## layer (RANGE_Y 0.05) so a move range still draws on top of them.
const HANGAR_DECAL_Y := 0.02
## The pad ring is the pad scaled down by this, drawn first so the darker
## pad face on top leaves a coloured border — one quad cheaper than four edges.
const HANGAR_RING_INSET := 0.92


func _add_hangar_markings(h: MapData.Hangar) -> void:
	var pad_size := float(MapData.HANGAR_PAD_RADIUS * 2 + 1) * GridManager.TILE_SIZE
	var pad_world := cell_to_world(h.pad_center)
	_add_decal(pad_world + Vector3(0, HANGAR_DECAL_Y, 0), pad_size, _decal_mat(HANGAR_PAD_RING_COLOR))
	_add_decal(pad_world + Vector3(0, HANGAR_DECAL_Y + 0.005, 0), pad_size * HANGAR_RING_INSET,
		_decal_mat(HANGAR_PAD_COLOR))
	var square_size := float(MapData.HANGAR_SQUARE_RADIUS * 2 + 1) * GridManager.TILE_SIZE
	var square_centre := h.pad_center + MapData.SIDE_STEP[h.ramp_side] * MapData.HANGAR_SQUARE_OFFSET
	_add_decal(cell_to_world(square_centre) + Vector3(0, HANGAR_DECAL_Y, 0), square_size,
		_decal_mat(HANGAR_SQUARE_COLOR))


func _add_decal(world: Vector3, size: float, mat: StandardMaterial3D) -> void:
	var mesh_instance := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(size, size)
	mesh_instance.mesh = plane
	mesh_instance.material_override = mat
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mesh_instance)
	mesh_instance.global_position = world


func _decal_mat(color: Color) -> StandardMaterial3D:
	var m := _mat(color)
	if color.a < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m


## Where a Dropship for hangar `h` sits once landed: the pad centre at floor
## level, turned so its ramp faces `h.ramp_side`. ExtractionManager parents the
## ship to this builder (it is level geometry, freed with the deck on a rebuild).
func pad_world_position(h: MapData.Hangar) -> Vector3:
	return cell_to_world(h.pad_center)


## Sec 5.3 fixtures. Occlusion is handled by LightingManager's raycast against
## wall geometry, same as unit LOS. The deck has no ceiling, so an overhead or
## flickering fixture is hung on the nearest wall of its room instead
## (_wall_mount, _add_wall_lamp); a monitor's glow, and a fixture whose room
## has no wall face, keep the old mount in mid-air above the cell.
func _add_light(pos: Vector3i, fixture: int) -> void:
	var source := LightSource.new()
	if data.light_specs.has(pos):
		var spec: Dictionary = data.light_specs[pos]
		source.intensity = 45.0 if spec.preset == DeckLight.Preset.MONITOR else 90.0
		source.light_range = 2.5 if spec.preset == DeckLight.Preset.MONITOR else 6.0
		source.flickers = spec.preset == DeckLight.Preset.FLICKER
		source.use_room_color = false
		for property: Dictionary in source.get_property_list():
			if property.usage & PROPERTY_USAGE_EDITOR and spec.overrides.has(property.name):
				source.set(property.name, spec.overrides[property.name])
		add_child(source)
		if spec.wall_side >= 0:
			source.transform = ParcelTransform.wall_transform(Vector2i(pos.x, pos.z), spec.wall_side)
			# Source -Z points into the room for the tilted spotlight.
			source.rotate_y(PI)
			source.position.y = WALL_LAMP_HEIGHT
		else:
			source.position = cell_to_world(pos) + Vector3(0, 2, 0)
		source.register_with_grid()
		return
	match fixture:
		MapData.Fixture.OVERHEAD:  # bright, wide, always on
			source.light_range = 6.0
			source.intensity = 90.0
			source.light_color = Color(1.0, 1.0, 1.0)
		MapData.Fixture.MONITOR:  # terminal glow — dim, short-range
			source.light_range = 2.5
			source.intensity = 45.0
			source.light_color = Color(0.4, 0.75, 1.0)
		MapData.Fixture.FLICKER:  # flicker disabled — burns steady like an overhead
			source.light_range = 6.0
			source.intensity = 90.0
			source.light_color = Color(0.85, 0.92, 1.0)
	if fixture != MapData.Fixture.MONITOR:
		var mount := _wall_mount(pos)
		if not mount.is_empty():
			_add_wall_lamp(source, mount[0], mount[1])
			return
	add_child(source)
	source.global_position = cell_to_world(pos) + Vector3(0, 2.0, 0)
	source.register_with_grid()


## Wall lamps hang with their middle this high up the 3.0 m wall face.
const WALL_LAMP_HEIGHT := 2.4
## How far in front of the wall face a lamp's light sits: inside the floor cell,
## so the rules light from that tile and the fog files it with that room.
const WALL_LAMP_STANDOFF := 0.25
## A wall lamp's beam, in degrees below the horizontal into the room, its
## half-angle, and how hard its rim is (LightSource.spot_edge): a flashlight
## cone that leaves a defined pool on the floor in front of the lamp. Its top
## edge (PITCH + SPOT_ANGLE) must stay below the horizontal: the camera always
## looks down from 35 degrees above, so a beam that never rises can never point
## at it, whatever the yaw. Visual only — the rules' light_value falloff
## doesn't know the cone's shape.
const WALL_LAMP_PITCH := -55.0
const WALL_LAMP_SPOT_ANGLE := 40.0
const WALL_LAMP_SPOT_EDGE := 3.0
## The beam's brightness and distance falloff (LightSource.beam_energy_scale,
## beam_falloff): a narrow cone spreads its light over less floor, so it is
## drawn brighter and carried further than the rules' intensity alone gives.
const WALL_LAMP_BEAM_ENERGY := 2.2
const WALL_LAMP_BEAM_FALLOFF := 1.5
## Generated decks: one lamp per this many cells of a room, at least one and at
## most WALL_LAMP_MAX. Dimmer and shorter than an overhead fixture (90 over 6
## tiles), so a lamp lights the stretch of room in front of it and leaves dark
## floor between lamps: past 3 tiles a lamp adds under EnemyUnit's 25 sight
## threshold on top of the ambient floor.
const WALL_LAMP_AREA := 30
const WALL_LAMP_MAX := 4
const WALL_LAMP_RANGE := 5.0
const WALL_LAMP_INTENSITY := 60.0
## Doorway lamps (_add_door_lamps): enough to light the doorway and a step
## either side of it, little more.
const DOOR_LAMP_RANGE := 3.0
const DOOR_LAMP_INTENSITY := 45.0
## How much of a flanking wall face, from the opening, a door frame's jamb may
## cover (Door_Frame_A's at a 2-tile door is 0.59 m), and the gap kept between
## a doorway lamp's panel and the far end of the face.
const DOOR_LAMP_CLEAR := 0.59
const DOOR_LAMP_MARGIN := 0.04


## Sides of floor cell `pos` that face a WALL cell, in Side order.
func _wall_sides(pos: Vector3i) -> Array[int]:
	var out: Array[int] = []
	if data.terrain_at(pos) != MapData.Terrain.FLOOR:
		return out
	for side: int in 4:
		if data.terrain_at(pos + MapData.SIDE_STEP[side]) == MapData.Terrain.WALL:
			out.append(side)
	return out


## Where a fixture at `pos` hangs, as [floor cell, side]: on `pos` itself when
## it touches a wall, else on the nearest floor cell that does, by a breadth-
## first walk that stays inside the room. Empty when the walk finds none.
func _wall_mount(pos: Vector3i) -> Array:
	var room := data.room_index_at(pos)
	var seen := {pos: true}
	var frontier: Array[Vector3i] = [pos]
	while not frontier.is_empty():
		var next: Array[Vector3i] = []
		for cell in frontier:
			var sides := _wall_sides(cell)
			if not sides.is_empty():
				return [cell, sides[posmod(_socket_hash(["wall_light", cell]), sides.size())]]
			for step: Vector3i in MapData.SIDE_STEP:
				var n := cell + step
				if seen.has(n) or data.terrain_at(n) != MapData.Terrain.FLOOR or data.room_index_at(n) != room:
					continue
				seen[n] = true
				next.append(n)
		frontier = next
	return []


## Generated decks carry no fixtures, so every room that is not a corridor gets
## wall lamps of its own, spread out: the first on a hashed wall cell, each
## next one on the wall cell farthest from those already lit. Hand-authored
## decks are left with the fixtures they were drawn with.
func _build_wall_lamps() -> void:
	var spots: Dictionary = {}  # room -> Array of [floor cell, side]
	var area: Dictionary = {}  # room -> cells
	for pos: Vector3i in data.room_of:
		var room: int = data.room_of[pos]
		if data.corridors.has(room):
			continue
		area[room] = area.get(room, 0) + 1
		for side: int in _wall_sides(pos):
			if _lamp_spots.has([pos, side]):
				continue
			if not spots.has(room):
				spots[room] = []
			spots[room].append([pos, side])
	for room: int in spots:
		var candidates: Array = spots[room]
		var want := mini(clampi(area[room] / WALL_LAMP_AREA, 1, WALL_LAMP_MAX), candidates.size())
		var lit: Array = [candidates[posmod(_socket_hash(["wall_lamps", room]), candidates.size())]]
		while lit.size() < want:
			var best: Array = []
			var best_dist := -1
			for spot: Array in candidates:
				var dist := 1 << 30
				for other: Array in lit:
					dist = mini(dist, GridManager.chebyshev_dist(spot[0], other[0]))
				if dist > best_dist:
					best_dist = dist
					best = spot
			lit.append(best)
		for spot: Array in lit:
			var source := LightSource.new()
			source.light_range = WALL_LAMP_RANGE
			source.intensity = WALL_LAMP_INTENSITY
			source.light_color = Color(0.85, 0.92, 1.0)
			_add_wall_lamp(source, spot[0], spot[1])


## Hangs `source` on the wall at `side` of floor cell `cell`: the light sits
## WALL_LAMP_STANDOFF in front of the face with a narrow, hard-edged beam
## tilted down into the room, and a small housing (_make_lamp_housing) goes on
## the face behind it — a flashlight-like point the beam visibly comes from,
## where the kit's light panels read as glowing white squares. The housing is
## the light's child, so the fog hides the two together, and it is registered
## with the WALL cell it hangs on, so occlusion fades it with that wall instead
## of leaving it floating in front of the cutaway.
##
## `slide` moves the lamp along the wall from the middle of the face, in metres.
func _add_wall_lamp(source: LightSource, cell: Vector3i, side: int,
		slide := Vector3.ZERO) -> void:
	source.room_index = data.room_index_at(cell)
	var step: Vector3i = MapData.SIDE_STEP[side]
	_lamp_spots[[cell, side]] = true
	source.beam_pitch = WALL_LAMP_PITCH
	source.spot_angle = WALL_LAMP_SPOT_ANGLE
	source.spot_edge = WALL_LAMP_SPOT_EDGE
	source.beam_energy_scale = WALL_LAMP_BEAM_ENERGY
	source.beam_falloff = WALL_LAMP_BEAM_FALLOFF
	add_child(source)
	source.global_position = cell_to_world(cell) + Vector3(0, WALL_LAMP_HEIGHT, 0) + slide \
		+ Vector3(step) * (GridManager.TILE_SIZE / 2.0 - WALL_LAMP_STANDOFF)
	# -Z, the way the beam points, faces away from the wall.
	source.rotation.y = atan2(float(step.x), float(step.z))
	var housing := _make_lamp_housing()
	source.add_child(housing)
	# Back against the face, which is WALL_LAMP_STANDOFF behind the light (+Z).
	housing.position = Vector3(0, 0, WALL_LAMP_STANDOFF - LAMP_HOUSING_SIZE.z / 2.0)
	_register_wall(cell + step, housing)
	source.register_with_grid()


## A wall lamp's housing, in metres: across the wall, up it, out from it.
const LAMP_HOUSING_SIZE := Vector3(0.24, 0.12, 0.2)
## The lens on the housing's underside, as a fraction of the housing's footprint.
const LAMP_LENS_FRACTION := 0.7
## Emission strength of the lens: over the environment's glow threshold, so it
## blooms as a small hot point.
const LAMP_LENS_ENERGY := 3.0
static var _housing_material: StandardMaterial3D
static var _lens_material: StandardMaterial3D


## A dark metal box with a small glowing lens on its underside, centred on the
## node's origin; the caller backs it onto the wall.
func _make_lamp_housing() -> Node3D:
	if _housing_material == null:
		_housing_material = StandardMaterial3D.new()
		_housing_material.albedo_color = Color(0.16, 0.17, 0.19)
		_housing_material.metallic = 0.6
		_housing_material.roughness = 0.5
		_lens_material = StandardMaterial3D.new()
		_lens_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_lens_material.albedo_color = Color(0.85, 0.92, 1.0)
		_lens_material.emission_enabled = true
		_lens_material.emission = Color(0.85, 0.92, 1.0)
		_lens_material.emission_energy_multiplier = LAMP_LENS_ENERGY
	var housing := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = LAMP_HOUSING_SIZE
	housing.mesh = box
	housing.material_override = _housing_material
	housing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var lens := MeshInstance3D.new()
	var plane := PlaneMesh.new()  # faces +Y; flipped below to face down
	plane.size = Vector2(LAMP_HOUSING_SIZE.x, LAMP_HOUSING_SIZE.z) * LAMP_LENS_FRACTION
	lens.mesh = plane
	lens.material_override = _lens_material
	lens.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	lens.rotation.x = PI
	lens.position.y = -LAMP_HOUSING_SIZE.y / 2.0 - 0.002
	housing.add_child(lens)
	return housing


func _add_floor_quad(world: Vector3, mat: StandardMaterial3D) -> void:
	var mesh_instance := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(GridManager.TILE_SIZE, GridManager.TILE_SIZE)
	mesh_instance.mesh = plane
	mesh_instance.material_override = mat
	add_child(mesh_instance)
	mesh_instance.global_position = world  # visual only; clicks hit the shared ground body


## Wall occlusion (MIGRATION_PLAN.md Phase 4).
##
## A camera that snaps between four yaws cannot be orbited past a bulkhead, so
## the near-side walls of a compartment would otherwise sit permanently between
## the player and the room. A wall is hidden when BOTH hold:
##
##   1. the cell one step further from the camera is walkable floor — that set is
##      exactly the near-side boundary of each compartment, and a wall backed by
##      another wall or by the void outside the hull is far-side structure that
##      has to stay up or the deck opens onto nothing; and
##   2. that floor belongs to a REVEALED region — one holding a player unit, a
##      corridor joined to one, OR the single room the cursor is currently
##      hovering (`_hover_room`, set in `_room_under_cursor`).
##
## Rule 2 is what the geometric placeholder could not do: it knows an empty room
## has no interior worth opening, so the far side of the deck stays sealed and
## the cutaway reads as the squad's own field of view rather than as x-ray. It
## needs the compartment graph, which MapData.compute_rooms now derives for
## hand-authored decks as well as generated ones.
##
## The cursor half of rule 2 is a UI convenience, not fog of war: it is folded
## into `_hides_interior` directly rather than into `_revealed`, so hovering a
## room opens its wall but does NOT feed `_apply_unit_visibility` — a peek
## must never be a way to spot an enemy no unit has actually seen.
##
## Platforms and cover props are deliberately left alone. Platform tops are
## walkable, so hiding one would leave units standing on nothing, and cover is
## short enough to read past at this pitch — hiding it would remove the exact
## silhouette that says a unit is behind it.
##
## Only the MESH is hidden. The StaticBody3D and its shape stay live, because LOS
## (GridManager.has_line_of_sight) and lighting occlusion (has_clear_line) both
## raycast layer 1 map geometry: a wall you can see past must still be a wall you
## cannot shoot through, or the screen starts disagreeing with the rules.
##
## A WALL cell's visuals are its kit face pieces, its shell (cap and sides),
## any door frame it flanks, or the placeholder box; `_wall_meshes` lists them
## all per cell, so hiding the cell hides every piece of its art.
func _process(_delta: float) -> void:
	if data == null:
		return
	_revealed = _revealed_regions()
	_update_fog()
	_update_sight_dim()
	# Ahead of the camera check, and every frame rather than only on a change.
	#
	# Ahead, because which units are drawn decides whether their activations are
	# fast-forwarded, and that is turn PACING — it must not depend on a camera
	# existing. Every frame, because an enemy walking into a revealed room changes
	# what should be drawn without changing the revealed set at all.
	_apply_unit_visibility()

	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return  # main.tscn builds the map before the rig exists; retried next frame
	_hover_room = _room_under_cursor(cam)
	if fog_of_war and not _explored.has(_hover_room):
		_hover_room = -1  # opening a wall onto an undrawn room shows only a hole
	var step := _away_step(-cam.global_transform.basis.z)
	# One Vector3i compare per frame while nothing is moving. The wall pass below
	# is heavier, so it is only paid when its answer changes.
	if step == _occlusion_step and _revealed == _last_revealed and _hover_room == _last_hover_room:
		return
	_occlusion_step = step
	_last_revealed = _revealed.duplicate()
	_last_hover_room = _hover_room
	_apply_wall_occlusion(step)


## The compartment the mouse is currently over, or -1 off the map entirely.
## Plane-projection rather than a physics raycast, for the same reason
## GridManager.tile_under_ray exists at all: a wall between the camera and the
## floor must not be able to hide the very room it is a candidate to open.
func _room_under_cursor(cam: Camera3D) -> int:
	var mouse := get_viewport().get_mouse_position()
	var tile := GridManager.tile_under_ray(
		cam.project_ray_origin(mouse), cam.project_ray_normal(mouse))
	if not GridManager.has_tile(tile):
		return -1
	return data.room_index_at(tile)


## Q12: a unit's sprite is drawn in a room holding a player unit — and, beyond
## those rooms, wherever a standing soldier has line of sight (GDD Sec 10.6), held
## for the rest of the round once seen (`_spotted`).
##
## The room is the base rule because it is a piece of space the player can hold
## in their head — "they are in the next compartment". Sight on top of it is what
## the room rule alone got wrong: anything that can shoot the squad can be seen
## by it, and an enemy firing down a corridor from two rooms off was undrawn.
## The round-long memory is what keeps a per-unit ray from flickering.
##
## This does more than hide sprites: an undrawn unit reports `is_instant` and so
## resolves its whole activation with no time on the clock, instead of making the
## player wait out animations against a static screen. See Unit.is_instant.
func _apply_unit_visibility() -> void:
	for node in get_tree().get_nodes_in_group("units"):
		var unit := node as Unit
		if unit:
			unit.set_rendered(unit_visible_at(unit, unit.grid_pos))


## Whether `unit` standing on `tile` is drawn: a revealed region, already spotted
## this round, or in a standing soldier's sight — which spots it. Unit.move_along
## asks this of each tile ahead, so a walk into view animates from that step
## rather than waiting for the next frame's pass.
func unit_visible_at(unit: Unit, tile: Vector3i) -> bool:
	if data == null:
		return true
	if unit.is_player_controlled or _revealed.has(data.room_index_at(tile)):
		return true
	if _spotted.has(unit):
		return true
	if not squad_sees_tile(tile):
		return false
	# A tick's AI pass is decided on roots already at their final tiles: spotting
	# from there would draw a model before playback walks it into view (B.12.2).
	if not TurnManager.resolving_tick:
		_spotted[unit] = true
	return true


## Whether any standing soldier has line of sight to `tile`, by the same rays the
## rules shoot along (GridManager.tiles_have_sight), either end free to lean.
## Cached per tile until a soldier moves or cover is destroyed.
func squad_sees_tile(tile: Vector3i) -> bool:
	var soldiers: Array[Unit] = []
	var key: Array = []
	for node in get_tree().get_nodes_in_group("player_units"):
		var soldier := node as Unit
		if soldier == null or soldier.is_downed or not soldier.is_inside_tree():
			continue
		soldiers.append(soldier)
		key.append(soldier.grid_pos)
	if key != _sight_key:
		_sight_key = key
		_sight_cache.clear()
	if _sight_cache.has(tile):
		return _sight_cache[tile]
	var seen := false
	for soldier in soldiers:
		if soldier.grid_pos == tile or GridManager.tiles_have_sight(self, soldier.grid_pos, tile, true, true):
			seen = true
			break
	_sight_cache[tile] = seen
	return seen


## The round-end half of the spotted memory: whoever no soldier can see any more
## is forgotten, and undrawn from the next frame.
func _forget_unseen(_turn: int) -> void:
	for unit in _spotted.keys():
		if not is_instance_valid(unit) or unit.is_downed or not squad_sees_tile(unit.grid_pos):
			_spotted.erase(unit)


func _on_cover_destroyed(_pos: Vector3i, _side: int, _now: int) -> void:
	_sight_cache.clear()
	_fog_sight_key = []
	_dim_key = []


## The dimming's one node: a MultiMesh of floor quads, one draw call however
## much of the deck is out of sight. Headless runs get none — it is only a
## picture, and testing every explored tile on every step would slow every
## test that walks a soldier.
func _build_sight_dim() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var quad := QuadMesh.new()
	quad.orientation = PlaneMesh.FACE_Y
	quad.size = Vector2(GridManager.TILE_SIZE, GridManager.TILE_SIZE)
	var material := ShaderMaterial.new()
	material.shader = SIGHT_DIM_SHADER
	quad.material = material
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = quad
	_dim_mesh = MultiMeshInstance3D.new()
	_dim_mesh.name = "OutOfSight"
	_dim_mesh.multimesh = multimesh
	_dim_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_dim_mesh.visible = false
	add_child(_dim_mesh)


## Re-tests the explored floor whenever what decides it changes — a soldier steps,
## goes down, a room is revealed or explored, cover is blown off — spread across
## frames under FOG_SIGHT_BUDGET_USEC like the reveal, and sharing its per-tile
## sight cache. Skipped while a tick is being decided: the roots are already at
## their final tiles then, and the dimming would jump ahead of the playback.
func _update_sight_dim() -> void:
	if _dim_mesh == null:
		return
	if not fog_of_war:
		_dim_mesh.visible = false
		return
	if TurnManager.resolving_tick:
		return
	var squad: Array = []
	for node in get_tree().get_nodes_in_group("player_units"):
		var soldier := node as Unit
		if soldier != null and not soldier.is_downed and soldier.is_inside_tree():
			squad.append(soldier.grid_pos)
	var key: Array = [squad, _revealed.keys(), _explored.keys()]
	if key != _dim_key:
		_dim_key = key
		_dim_next.clear()
		_dim_pending.clear()
		for region: int in _explored:
			if not _revealed.has(region):
				_dim_pending.append_array(_region_tiles.get(region, []))
		if _dim_pending.is_empty():
			_show_sight_dim()
			return
	if _dim_pending.is_empty():
		return
	var deadline := Time.get_ticks_usec() + FOG_SIGHT_BUDGET_USEC
	while not _dim_pending.is_empty() and Time.get_ticks_usec() < deadline:
		var tile: Vector3i = _dim_pending.pop_back()
		if not squad_sees_tile(tile):
			_dim_next.append(tile)
	if _dim_pending.is_empty():
		_show_sight_dim()


func _show_sight_dim() -> void:
	var multimesh := _dim_mesh.multimesh
	multimesh.instance_count = _dim_next.size()
	for i in _dim_next.size():
		multimesh.set_instance_transform(i, Transform3D(Basis(),
			GridManager.grid_to_world(_dim_next[i]) + Vector3(0.0, SIGHT_DIM_LIFT, 0.0)))
	_dim_mesh.visible = not _dim_next.is_empty()


## Fog of war over the layout: a region's floor, walls and props are drawn only
## once a soldier has stood in it or seen into it, and stay drawn for the rest of
## the mission. Squad-wide, so in co-op one player's scout maps the deck for both.
##
## Only VISUALS hide, exactly as with wall occlusion: collision stays live, so
## LOS, lighting and clicks are unchanged — an undrawn room is still a room.
##
## Distinct from `_revealed`, which is where the squad is NOW and drives which
## units are drawn. Explored ground is the map the squad has made; it does not
## say who is standing on it.
func _update_fog() -> void:
	if not fog_of_war:
		return
	var grew := false
	for region: int in _revealed:
		if not _explored.has(region):
			_explored[region] = true
			grew = true
	# A tick's AI pass is decided on roots already at their final tiles; seeing
	# from there would reveal a room before playback walks the soldier into view.
	if not TurnManager.resolving_tick:
		var key: Array = []
		for node in get_tree().get_nodes_in_group("player_units"):
			var soldier := node as Unit
			if soldier != null and not soldier.is_downed and soldier.is_inside_tree():
				key.append(soldier.grid_pos)
		if grew or key != _fog_sight_key:
			_fog_sight_key = key
			_queue_frontier()
		if _reveal_seen():
			grew = true
	if grew:
		_apply_fog()


## Starts the sight reveal over: every unexplored region touching explored
## ground. Only those can be seen into — sight into a room runs through the
## doorway first, and the doorway is its own region.
func _queue_frontier() -> void:
	_fog_pending.clear()
	_fog_tile_index = 0
	for region: int in _explored:
		for near in data.touching_regions(region):
			if not _explored.has(near) and not _fog_pending.has(near):
				_fog_pending.append(near)


## Works through `_fog_pending`, exploring each region a standing soldier can
## see a tile of and queueing the regions beyond it, so a straight corridor
## reveals the room at its far end. An unseen room costs a sight test per tile,
## and a large deck's frontier ran to 40 ms in one step of a walk — so the work
## is spread across frames under FOG_SIGHT_BUDGET_USEC, and a room appears a few
## frames after it comes into view. Headless runs finish it at once, so a test
## can assert one frame later. Whether anything was newly explored.
func _reveal_seen() -> bool:
	var any := false
	var budgeted := DisplayServer.get_name() != "headless"
	var deadline := Time.get_ticks_usec() + FOG_SIGHT_BUDGET_USEC
	while not _fog_pending.is_empty() and (not budgeted or Time.get_ticks_usec() < deadline):
		var region: int = _fog_pending[0]
		var tiles: Array = _region_tiles.get(region, [])
		if _explored.has(region) or _fog_tile_index >= tiles.size():
			_fog_pending.pop_front()
			_fog_tile_index = 0
		elif squad_sees_tile(tiles[_fog_tile_index]):
			_explored[region] = true
			any = true
			_fog_pending.pop_front()
			_fog_tile_index = 0
			for near in data.touching_regions(region):
				if not _explored.has(near) and not _fog_pending.has(near):
					_fog_pending.append(near)
		else:
			_fog_tile_index += 1
	return any


func _apply_fog() -> void:
	for group: Node3D in _fog_group_regions:
		group.visible = _fog_shows(_fog_group_regions[group])
	for light: Node3D in _fog_lights:
		if is_instance_valid(light):
			light.visible = _fog_shows(_fog_lights[light])


func _fog_shows(regions: Array) -> bool:
	if not fog_of_war:
		return true
	for region: int in regions:
		if _explored.has(region):
			return true
	return false


## Whether `grid_pos` is ground the squad has mapped. Overlays ask this so a move
## range or a throw band does not trace the shape of a room nobody has seen.
func is_explored_tile(grid_pos: Vector3i) -> bool:
	return not fog_of_war or data == null or _explored.has(data.room_index_at(grid_pos))


## Draw-with regions for every built cell, by a breadth-first flood out from the
## walkable cells: each wall or obstacle cell takes the regions nearest to it,
## all of them on a tie. A bulkhead between two rooms is therefore drawn when
## either is, so an explored room is always closed by its walls, and a thick
## hull is drawn by whichever room it encloses rather than standing in the dark
## tracing the whole ship.
func _compute_cell_regions() -> void:
	_cell_regions.clear()
	_region_tiles.clear()
	var frontier: Array[Vector3i] = []
	for pos: Vector3i in data.room_of:
		var region: int = data.room_of[pos]
		_cell_regions[pos] = [region]
		frontier.append(pos)
		if not _region_tiles.has(region):
			_region_tiles[region] = []
		_region_tiles[region].append(data.walkable_pos(pos))
	while not frontier.is_empty():
		var ring: Dictionary = {}  # cell -> Array[int]
		for pos in frontier:
			for step: Vector3i in OCCLUSION_STEPS:
				var near := pos + step
				if _cell_regions.has(near) or data.terrain_at(near) == MapData.Terrain.VOID:
					continue
				if not ring.has(near):
					ring[near] = []
				for region: int in _cell_regions[pos]:
					if not ring[near].has(region):
						ring[near].append(region)
		frontier = []
		for pos: Vector3i in ring:
			ring[pos].sort()
			_cell_regions[pos] = ring[pos]
			frontier.append(pos)


func _regions_of_cells(cells: Array) -> Array:
	var out: Array = []
	for pos: Vector3i in cells:
		for region: int in _cell_regions.get(pos, []):
			if not out.has(region):
				out.append(region)
	out.sort()
	return out


## The regions whatever stands at `world` is drawn with. A platform's props sit
## a deck up from the cell that holds the region, so that is tried second.
func _regions_at_world(world: Vector3) -> Array:
	var cell := Vector3i(roundi(world.x / GridManager.TILE_SIZE),
		floori(world.y / GridManager.FLOOR_HEIGHT + 0.01), roundi(world.z / GridManager.TILE_SIZE))
	return _cell_regions.get(cell, _cell_regions.get(cell - MapData.DECK_OFFSET, []))


## Sits at this builder's origin, so a node moved under it keeps its local
## transform as is — which also works before the builder is in the tree.
func _fog_group(regions: Array) -> Node3D:
	var key := ",".join(regions.map(func(r: int) -> String: return str(r)))
	var group: Node3D = _fog_groups.get(key)
	if group == null:
		group = Node3D.new()
		group.name = "Fog_" + key.replace(",", "_")
		add_child(group)
		_fog_groups[key] = group
		_fog_group_regions[group] = regions.duplicate()
	return group


## Files every visual node built so far under the fog group for its regions.
## Lights are hidden in place instead (`_fog_lights`), and collision-only bodies,
## which draw nothing, stay put. A node no region claims
## (a stray outside every flood) is left drawn rather than lost.
func _assign_fog() -> void:
	var wall_cells: Dictionary = {}  # node -> Array[Vector3i]
	for pos: Vector3i in _wall_meshes:
		for node: Node3D in _wall_meshes[pos]:
			if not wall_cells.has(node):
				wall_cells[node] = []
			wall_cells[node].append(pos)
	for child in get_children():
		var node := child as Node3D
		if node is LightSource:
			var lit := _regions_at_world(node.position)
			if not lit.is_empty():
				_fog_lights[node] = lit
			continue
		if node == null or _fog_group_regions.has(node) or not _draws(node):
			continue
		var regions: Array
		if _fog_explicit.has(node):
			regions = _fog_explicit[node]
		elif wall_cells.has(node):
			regions = _regions_of_cells(wall_cells[node])
		else:
			regions = _regions_at_world(node.position)
		if not regions.is_empty():
			node.reparent(_fog_group(regions), false)
	_fog_explicit.clear()


func _draws(node: Node) -> bool:
	return node is VisualInstance3D \
		or not node.find_children("*", "VisualInstance3D", true, false).is_empty()


## Props placed after the build — a loot pile from a body, the objective
## terminal — join the fog like the rest. Deferred, because a node cannot be
## moved while it is still entering the tree. The Dropship is deliberately not
## among them: it flies in from outside the deck.
func _on_child_entered(node: Node) -> void:
	if _building or not (node is LootContainer or node is TerminalProp):
		return
	_adopt_into_fog.call_deferred(node)


func _adopt_into_fog(node: Node3D) -> void:
	if not is_instance_valid(node) or node.get_parent() != self:
		return
	var regions := _regions_at_world(node.position)
	if not regions.is_empty():
		node.reparent(_fog_group(regions), false)
		_apply_fog()


## Regions a player unit is standing in, plus every corridor joined to one.
##
## Corridors ride along because a doorway is its own region under
## MapData.compute_rooms: without this a squad standing in a room would leave the
## doorway they are about to walk through sealed, which reads as a bug rather
## than as fog of war.
func _revealed_regions() -> Dictionary:
	var out: Dictionary = {}
	for node in get_tree().get_nodes_in_group("player_units"):
		var unit := node as Unit
		if unit == null or unit.is_downed:
			continue
		var index := data.room_index_at(unit.grid_pos)
		if index < 0:
			continue
		out[index] = true
		# Touching, not `linked_rooms`: a generated deck's links skip the corridor
		# between two rooms, so through them no corridor was ever revealed and an
		# enemy standing in one fought the squad undrawn — and so with no time on
		# the clock (Unit.is_instant).
		for linked in data.touching_regions(index):
			if linked in data.corridors:
				out[linked] = true
	return out


## Which SecurityZone a tile belongs to (security-robots/design-choices/
## detection-and-network-alert.md). A zone is the unit an alert broadcasts across,
## and it is meant to be COARSER than a room — "everything behind one checkpoint".
##
## The alpha derives it as one compartment plus the doorways touching it, which is
## the coarsest partition the derived room graph actually supports: every room on
## a deck connects to every other through corridors, so unioning across them
## collapses the whole level into one zone and a single tripped sentry alerts the
## map. A doorway resolves to the lowest-indexed compartment it joins, so a robot
## standing in one still answers to a real place rather than to a one-tile region
## of its own.
##
## Authored zones are the intended follow-up and need no code here:
## `CerberusUnit.security_zone` is exported, so a hand-placed level can already
## overwrite whatever this returns.
## Which COMPARTMENT a tile belongs to, or -1 for none.
##
## Distinct from `zone_at` above, and the difference is the whole reason both
## exist: a security zone is deliberately coarser than a room ("everything behind
## one checkpoint") because that is the scope a robot network broadcasts across.
## The aliens' alerts are scoped to a room/nest cluster instead (Sec 11.2), which
## is tighter — and tighter is the point, because it is what makes shutting a
## door on a compartment actually contain what is inside it.
func room_at(grid_pos: Vector3i) -> int:
	return data.room_index_at(grid_pos) if data != null else -1


## Whether a unit standing on `grid_pos` would be drawn — the same test
## `_apply_unit_visibility` runs on a unit's root. Tick playback asks it of where
## a MODEL is (exploration plan B.12.2).
func is_revealed_tile(grid_pos: Vector3i) -> bool:
	return data != null and _revealed.has(data.room_index_at(grid_pos))


func zone_at(grid_pos: Vector3i) -> int:
	if data == null:
		return SecurityNetwork.NO_ZONE
	var index := data.room_index_at(grid_pos)
	if index < 0:
		return SecurityNetwork.NO_ZONE
	if not (index in data.corridors):
		return index
	var best := SecurityNetwork.NO_ZONE
	for linked in data.linked_rooms(index):
		if linked == index or linked in data.corridors:
			continue
		if best == SecurityNetwork.NO_ZONE or linked < best:
			best = linked
	return best


## The grid step leading away from the camera: the camera's look direction,
## flattened and snapped to the nearest of the eight grid directions.
##
## Snapping rather than reading a fixed angle is what makes this work both before
## and after the camera becomes orthographic with quarter-turn yaws (Phase 1) —
## under free orbit it re-buckets as the yaw sweeps, and under snapped yaws a snap
## simply IS a bucket change.
func _away_step(look: Vector3) -> Vector3i:
	var flat := Vector3(look.x, 0.0, look.z)
	if flat.length() < 0.001:
		return Vector3i.ZERO  # straight down: nothing is in front of anything
	return OCCLUSION_STEPS[wrapi(roundi(atan2(flat.x, flat.z) / (PI / 4.0)), 0, 8)]


## Groups `_wall_meshes` by NODE rather than by cell first: a face piece spans
## several cells and can only be hidden or shown as a whole. A node is hidden
## only when EVERY cell it belongs to wants it hidden — biasing toward staying
## visible on a split verdict is the safe direction, since a wall that should
## have hidden but didn't is a solved problem (open the door), while one that
## hid when it should not have opens the deck onto nothing.
func _wall_nodes_by_hide(step: Vector3i) -> Dictionary:
	var positions_by_node: Dictionary = {}
	for pos: Vector3i in _wall_meshes:
		for node: Node3D in _wall_meshes[pos]:
			if not positions_by_node.has(node):
				positions_by_node[node] = []
			positions_by_node[node].append(pos)
	var out: Dictionary = {}
	for node: Node3D in positions_by_node:
		var hide := true
		for pos: Vector3i in positions_by_node[node]:
			if not _hides_interior(pos, step):
				hide = false
				break
		out[node] = hide
	return out


## Fades walls by GeometryInstance3D.transparency on every mesh under each
## node, so a kit piece with several meshes and materials fades exactly as the
## placeholder box does, with no material swapped in or out.
func _apply_wall_occlusion(step: Vector3i) -> void:
	var fading_out: Array[Node3D] = []
	var fading_in: Array[Node3D] = []
	var by_hide := _wall_nodes_by_hide(step)
	for node: Node3D in by_hide:
		var hide: bool = by_hide[node]
		if hide == not node.visible:
			continue  # already where it needs to be
		if hide:
			fading_out.append(node)
		else:
			node.visible = true
			fading_in.append(node)

	if fading_out.is_empty() and fading_in.is_empty():
		return
	if _fade_tween:
		# A snap arriving mid-fade: land the old one before starting the new, or
		# walls caught between the two passes stay part-transparent.
		_fade_tween.kill()
		_settle_fade()
	_fading_out = fading_out
	_fading_in = fading_in
	_fade_out_geo = _geometry_under(fading_out)
	_fade_in_geo = _geometry_under(fading_in)
	if _instant_fade():
		_settle_fade()
		return
	_set_fade(0.0)
	_fade_tween = create_tween()
	_fade_tween.tween_method(_set_fade, 0.0, 1.0, OCCLUSION_FADE)
	_fade_tween.finished.connect(_settle_fade)


func _geometry_under(nodes: Array[Node3D]) -> Array[GeometryInstance3D]:
	var out: Array[GeometryInstance3D] = []
	for node in nodes:
		if node is GeometryInstance3D:
			out.append(node)
		for child in node.find_children("*", "GeometryInstance3D", true, false):
			out.append(child)
	return out


func _instant_fade() -> bool:
	# Nothing to fade across with no frames being drawn, and the headless smoke
	# test should not spend wall-clock time on a cosmetic transition.
	return DisplayServer.get_name() == "headless"


func _set_fade(t: float) -> void:
	for geo in _fade_out_geo:
		geo.transparency = t
	for geo in _fade_in_geo:
		geo.transparency = 1.0 - t


## Hides the walls that faded out and returns every faded mesh to fully
## opaque. Called on completion AND on interruption, so a wall is never left
## part-transparent when it is not currently animating.
func _settle_fade() -> void:
	for node in _fading_out:
		node.visible = false
	for geo in _fade_out_geo + _fade_in_geo:
		geo.transparency = 0.0
	_fading_out = []
	_fading_in = []
	_fade_out_geo = []
	_fade_in_geo = []
	_fade_tween = null


func _hides_interior(pos: Vector3i, step: Vector3i) -> bool:
	if step == Vector3i.ZERO:
		return false
	for i in range(1, OCCLUSION_DEPTH + 1):
		var behind := pos + step * i
		if not data.is_walkable(behind):
			continue
		var room := data.room_index_at(behind)
		if _revealed.has(room) or (_hover_room >= 0 and room == _hover_room):
			return true
	return false


func build_ground_collision() -> void:
	# Single large ground body for click raycasts (layer 1). Sits slightly
	# below wall bases so it never blocks eye-height LOS rays.
	var width := data.size.x * GridManager.TILE_SIZE
	var depth := data.size.y * GridManager.TILE_SIZE
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
