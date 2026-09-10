class_name MapBuilder
extends Node3D
## Turns a MapData into scene nodes: grid tiles, collision, meshes, cover and
## light fixtures. This is the only half of the map pipeline that needs a scene
## tree — generation and validation both run on MapData alone.

const WALL_HEIGHT := 3.0
const PLATFORM_HEIGHT := 3.0

## Modules built by tools/export_room_modules.py from the Rhino/Blender kit in
## assets/room_tiles/source/ (see that script's docstring for the pipeline and
## assets/room_tiles/modules/ for the .glb output), used at their own native
## scale — no stretching, and each with its thickness measured live off the
## mesh (see _module_thickness) rather than hardcoded, so a re-export that
## changes the art can't silently drift out of sync with the hug offset
## below. `DoorClosed`/`DoorOpen`, `WallCorner` and the damaged variants exist
## in modules/ but aren't wired in: corners are not a separate piece any more
## (see LONG_TILES/SHORT_TILES), a DOOR cell is a plain opening with no
## module at all (see _build_wall_runs), and nothing yet marks a WALL run as
## damaged. A 3+-way junction or an isolated single wall cell (no matching
## art) falls back to the flat placeholder box.
const WALL_MODULES := {
	"straight": preload("res://assets/room_tiles/modules/WallStraight.glb"),
	"short": preload("res://assets/room_tiles/modules/WallEnd.glb"),
}

## Each module's own unrotated length axis: true if its length runs along
## local X at rotation 0 (WallStraight), false if along local Z (WallEnd —
## the short wall was authored rotated 90° from the long one in its own
## source file; confirmed directly in Godot, not assumed — see
## _rotation_for). The two pieces do NOT share a rotation convention, so
## placing either one along a given grid axis takes whichever rotation
## actually points ITS OWN length that way.
const MODULE_LENGTH_ALONG_X := {
	"straight": true,
	"short": false,
}

## Tiles each module's authored length covers (length ÷ TILE_SIZE): the
## "basic wall" runs 7.5m = 5 tiles, the "short wall" 4.5m = 3 tiles. Both are
## generic building blocks for _pack_tiles now, not a run piece vs. a
## dead-end cap — a 3-tile piece can land anywhere a run's length calls for
## one.
const LONG_TILES := 5
const SHORT_TILES := 3

enum WallShape { STRAIGHT_X, STRAIGHT_Z, CORNER, END, OTHER }

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
## MapData.Spawn kind -> Array[Vector3i], for the four security-robot types. One
## dictionary rather than four named arrays because the roster is expected to
## change and the spawner iterates it either way.
var cerberus_spawns: Dictionary = {}

## Cell position -> that wall's visual root (a MeshInstance3D for the
## placeholder box, or a module instance's root Node3D for a wall built from
## assets/room_tiles/modules/). Only the visual is kept, because only the
## visual is ever hidden — see _apply_wall_occlusion. A whole straight run
## shares one instance across every cell it covers (see _build_wall_runs), so
## several keys here can point at the same node.
var _wall_meshes: Dictionary = {}
## WALL cells already given a visual by _build_wall_runs, so _build_cell's
## per-cell pass knows to skip them rather than double-build a box underneath.
var _handled_walls: Dictionary = {}
## module_key -> measured thickness (see _module_thickness), memoised per
## build() so each module's mesh is only instantiated-and-measured once
## rather than once per piece placed.
var _thickness_cache: Dictionary = {}
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
var _fade_tween: Tween = null
var _fading_out: Array[MeshInstance3D] = []
var _fading_in: Array[MeshInstance3D] = []

var _wall_mat: StandardMaterial3D
var _wall_fade_out_mat: StandardMaterial3D
var _wall_fade_in_mat: StandardMaterial3D
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
	_wall_meshes.clear()
	_handled_walls.clear()
	_thickness_cache.clear()
	_occlusion_step = Vector3i.ZERO  # forces a recompute against the new layout
	_revealed.clear()
	_last_revealed.clear()
	if _fade_tween:
		_fade_tween.kill()
	_fading_out = []
	_fading_in = []
	_fade_tween = null
	GridManager.clear()
	# Ahead of the per-cell pass: a run or a door span has to be recognised as a
	# whole before any of its cells are visited individually, or there is no
	# "whole" left to chunk into fixed-length modules — see _build_wall_runs.
	_build_wall_runs()
	for pos: Vector3i in data.cells:
		_build_cell(pos, data.get_cell(pos))
	# After every cell, because an edge prop registers itself against the tiles on
	# BOTH sides and those tiles have to exist first.
	for entry: Array in data.cover_edge_list():
		_add_cover_edge(entry[0], entry[1], entry[2])
	for entry: Array in data.obstacles:
		_add_cover_block(entry[0], entry[1])
	for link: Array in data.stair_links:
		GridManager.add_stair_link(link[0], link[1])
	player_spawns = data.spawns(MapData.Spawn.PLAYER)
	enemy_spawns = data.spawns(MapData.Spawn.ENEMY)
	swarm_spawns = data.spawns(MapData.Spawn.SWARM)
	brawler_spawns = data.spawns(MapData.Spawn.BRAWLER)
	merc_spawns = data.spawns(MapData.Spawn.MERC)
	hunter_spawns = data.spawns(MapData.Spawn.HUNTER)
	cerberus_spawns.clear()
	for kind: int in MapData.CERBERUS_SPAWNS:
		cerberus_spawns[kind] = data.spawns(kind)
	build_ground_collision()
	LightingManager.recompute_base()


func _build_cell(pos: Vector3i, cell: MapData.Cell) -> void:
	var world := cell_to_world(pos)
	match cell.terrain:
		MapData.Terrain.VOID:
			return
		MapData.Terrain.WALL:
			_add_wall_collision(world)  # every WALL cell blocks LOS, however it's drawn
			if not _handled_walls.has(pos):
				# _build_wall_runs couldn't cover it with a real module — a
				# leftover remainder _pack_tiles couldn't express exactly in
				# LONG_TILES/SHORT_TILES pieces (see its docstring), a 3+-way
				# junction, or an isolated wall cell. Same placeholder box
				# either way; there is no art for any of these.
				_wall_meshes[pos] = _add_wall_placeholder(world)
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
	_add_floor_quad(world, _stair_mat if cell.stair else _floor_mat)
	if cell.fixture == MapData.Fixture.ALARM:
		# Not a light. Recorded on the tile so `Unit.move_along` can trip it by
		# walking, which is the only way it ever fires.
		var t: GridTileData = GridManager.get_tile(pos)
		if t:
			t.alarm = true
	elif cell.fixture != MapData.Fixture.NONE:
		_add_light(world, cell.fixture)


func cell_to_world(pos: Vector3i) -> Vector3:
	# Cell space -> world. Deck 0 sits at y = 0; a cell's world position is the
	# *base* of whatever is built on it, not the tile a unit stands on.
	return Vector3(pos.x * GridManager.TILE_SIZE, pos.y * GridManager.FLOOR_HEIGHT, pos.z * GridManager.TILE_SIZE)


func _make_materials() -> void:
	_wall_mat = _mat(Color(0.25, 0.27, 0.32))
	# Two fading variants of the wall material, not one per wall. A yaw snap
	# moves every wall in the same direction at the same moment, so at most two
	# alphas are ever in flight: everything on its way out shares one, everything
	# on its way in shares the other. DEPTH_PRE_PASS rather than plain ALPHA so a
	# half-faded bulkhead still writes depth and does not let the floor behind it
	# sort through.
	_wall_fade_out_mat = _fade_mat(_wall_mat.albedo_color)
	_wall_fade_in_mat = _fade_mat(_wall_mat.albedo_color)
	_floor_mat = _mat(Color(0.42, 0.44, 0.48))
	_platform_mat = _mat(Color(0.35, 0.38, 0.45))
	_stair_mat = _mat(Color(0.55, 0.5, 0.3))
	_cover_light_mat = _mat(Color(0.55, 0.42, 0.25))
	_cover_heavy_mat = _mat(Color(0.3, 0.35, 0.3))


func _mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	return m


func _fade_mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
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


## The flat placeholder box, for any WALL cell the module classifier can't
## place with real art (a 3+-way junction, or an isolated single wall cell —
## see WallShape.OTHER in _classify_wall). Visual only; _add_wall_collision
## supplies the matching collision separately.
func _add_wall_placeholder(world: Vector3) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(GridManager.TILE_SIZE, WALL_HEIGHT, GridManager.TILE_SIZE)
	mesh_instance.mesh = box_mesh
	mesh_instance.material_override = _wall_mat
	add_child(mesh_instance)
	mesh_instance.global_position = world + Vector3(0, WALL_HEIGHT / 2.0, 0)
	return mesh_instance


func _add_wall(pos: Vector3i, world: Vector3) -> void:
	_add_wall_collision(world)
	_wall_meshes[pos] = _add_wall_placeholder(world)


## One instance of a WALL_MODULES piece, positioned at `world` (a cell's
## tile-centre — see cell_to_world) plus `offset` (the "hug" shift — see
## _hug_direction), rotated to run along the grid axis `along_x` names.
## Modules are exported with their own origin already at floor level and at
## native scale (see tools/export_room_modules.py), so no vertical offset or
## stretch is needed here the way _add_box_body needs one for a centre-origin
## BoxMesh.
func _instance_module(module_key: String, world: Vector3, offset: Vector3, along_x: bool) -> Node3D:
	var inst: Node3D = WALL_MODULES[module_key].instantiate()
	add_child(inst)
	inst.global_position = world + offset
	inst.rotation.y = _rotation_for(module_key, along_x)
	return inst


## Which Y-rotation makes `module_key`'s own length axis run along the grid
## axis `along_x` names. A module authored with its length on local X needs
## no rotation to run along world X (0.0) and a quarter turn to run along
## world Z (PI/2); one authored along local Z is the other way around — see
## MODULE_LENGTH_ALONG_X.
func _rotation_for(module_key: String, along_x: bool) -> float:
	var native_along_x: bool = MODULE_LENGTH_ALONG_X[module_key]
	return 0.0 if along_x == native_along_x else PI / 2.0


## Which of a WALL cell's four orthogonal neighbours continue the same
## bulkhead line, indexed by Side (map_data.gd: EAST=0, SOUTH=1, WEST=2,
## NORTH=3). DOOR counts alongside WALL: a doorway interrupts a wall run
## without ending it, so a WALL cell next to one must still read as a
## straight-run cell, not as a dead end capping against open air.
func _wall_neighbors(pos: Vector3i) -> Array[bool]:
	var out: Array[bool] = []
	for side in [MapData.Side.EAST, MapData.Side.SOUTH, MapData.Side.WEST, MapData.Side.NORTH]:
		var t := data.terrain_at(pos + MapData.SIDE_STEP[side])
		out.append(t == MapData.Terrain.WALL or t == MapData.Terrain.DOOR)
	return out


## Classifies a WALL cell by which neighbours continue the bulkhead line, the
## way a standard tile autotiler would: two OPPOSITE such neighbours is a
## straight run cell (STRAIGHT_X/STRAIGHT_Z below); two PERPENDICULAR ones is
## a corner, carrying the two Sides the wall continues toward; exactly one is
## a dead end, carrying the one Side it continues toward; anything else (a 3-
## or 4-way junction, or an isolated wall cell with no continuation at all)
## has no matching module and falls back to the placeholder box.
##
## A corner or a dead end is NOT a separate piece — WallCorner is retired,
## and a dead end is just wherever a run of ordinary LONG_TILES/SHORT_TILES
## pieces happens to stop. _continues_axis below is what lets a run swallow
## either kind of cell as an ordinary tile of its own length; see that
## function and _build_wall_runs for why a corner cell deliberately ends up
## covered by BOTH the runs that meet there.
func _classify_wall(pos: Vector3i) -> Dictionary:
	var nb := _wall_neighbors(pos)
	var e: bool = nb[MapData.Side.EAST]
	var s: bool = nb[MapData.Side.SOUTH]
	var w: bool = nb[MapData.Side.WEST]
	var n: bool = nb[MapData.Side.NORTH]
	var count := int(e) + int(s) + int(w) + int(n)
	if count == 2 and e and w:
		return {"shape": WallShape.STRAIGHT_X}
	if count == 2 and n and s:
		return {"shape": WallShape.STRAIGHT_Z}
	if count == 2:
		var dir_a: int = MapData.Side.NORTH if n else MapData.Side.SOUTH
		var dir_b: int = MapData.Side.EAST if e else MapData.Side.WEST
		return {"shape": WallShape.CORNER, "dir_a": dir_a, "dir_b": dir_b}
	if count == 1:
		var toward: int = MapData.Side.EAST if e else (MapData.Side.SOUTH if s else (MapData.Side.WEST if w else MapData.Side.NORTH))
		return {"shape": WallShape.END, "toward": toward}
	return {"shape": WallShape.OTHER}


## Whether `pos` continues a run along the grid axis `along_x` names: a WALL
## cell whose own classification has a leg on THAT axis specifically — a
## matching STRAIGHT cell (both legs on this axis), a CORNER (always has one
## leg per axis, so it always counts on both), or an END whose lone leg
## happens to point along this axis. WallShape.OTHER (a 3+-way junction, or
## an isolated cell) never counts, on either axis — no module fits it, so a
## run must not try to swallow it.
func _continues_axis(pos: Vector3i, along_x: bool) -> bool:
	if data.terrain_at(pos) != MapData.Terrain.WALL:
		return false
	var shape: Dictionary = _classify_wall(pos)
	match shape.shape:
		WallShape.STRAIGHT_X:
			return along_x
		WallShape.STRAIGHT_Z:
			return not along_x
		WallShape.CORNER:
			return true
		WallShape.END:
			var toward_along_x: bool = shape.toward == MapData.Side.EAST or shape.toward == MapData.Side.WEST
			return toward_along_x == along_x
		_:
			return false


## Places every door span (see _place_spans) and every WALL run along both
## grid axes, packing each run's full length into LONG_TILES/SHORT_TILES
## pieces (see _pack_tiles) at native module scale — no stretching. Must run
## before the per-cell pass in `build()`: a run has to be recognised as a
## whole, and packed, before any single cell of it can be drawn.
##
## A cell is checked against BOTH axes independently, rather than being
## claimed by whichever axis reaches it first: a corner cell genuinely
## belongs to two runs — the one bending through it and the one bending away
## — and with WallCorner retired, the only way to cover a corner at all is to
## let each adjoining run's own packing include it as an ordinary tile at its
## end. That means a corner cell gets two overlapping module instances, one
## from each run — deliberate, not a bug, per the fix this replaced (a
## dedicated corner piece whose two legs could never match an arbitrary
## room's actual corner dimensions). `seen` is tracked per axis for the same
## reason: a cell fully handled by its X-run must still be free to also be
## handled by its Z-run.
func _build_wall_runs() -> void:
	var seen := {true: {}, false: {}}
	for pos: Vector3i in data.cells:
		if data.terrain_at(pos) != MapData.Terrain.WALL:
			continue
		for along_x in [true, false]:
			if not seen[along_x].has(pos) and _continues_axis(pos, along_x):
				_handle_run(pos, along_x, seen[along_x])


## The full extent of the maximal run through `pos` along axis `along_x`,
## scanning BOTH directions rather than assuming `pos` is already the run's
## start — `data.cells`' iteration order happens to visit most runs
## start-first (raster order), but a floating divider open at both ends has
## no "first" cell that isn't itself one of the two WallShape.END cells
## bracketing it, and scanning both ways is what covers that case too.
func _run_bounds(pos: Vector3i, along_x: bool) -> Array[Vector3i]:
	var step := Vector3i(1, 0, 0) if along_x else Vector3i(0, 0, 1)
	var start := pos
	while _continues_axis(start - step, along_x):
		start -= step
	var end := pos
	while _continues_axis(end + step, along_x):
		end += step
	return [start, end]


## Packs one run's full bounds into LONG_TILES/SHORT_TILES pieces (see
## _pack_tiles) and places one module instance per piece, each hugging the
## same side of the run — see _hug_direction. Any remainder _pack_tiles
## can't express exactly (only possible for a 1, 2, 4 or 7-tile run; every
## other length is exact) is left uncovered and falls through to
## `_build_cell`'s per-cell placeholder box, the same graceful degradation an
## ordinary junction gets.
func _handle_run(pos: Vector3i, along_x: bool, seen: Dictionary) -> void:
	var bounds := _run_bounds(pos, along_x)
	var lo: Vector3i = bounds[0]
	var hi: Vector3i = bounds[1]
	var step := Vector3i(1, 0, 0) if along_x else Vector3i(0, 0, 1)
	var length := _coord_along(hi, step) - _coord_along(lo, step) + 1
	var hug_dir := _hug_direction(lo, hi, step, along_x)
	var cur := lo
	for tiles: int in _pack_tiles(length):
		var module_key := "straight" if tiles == LONG_TILES else "short"
		var piece_end := cur + step * (tiles - 1)
		var mid := (cell_to_world(cur) + cell_to_world(piece_end)) / 2.0
		var gap := (GridManager.TILE_SIZE - _module_thickness(module_key)) / 2.0
		var inst := _instance_module(module_key, mid, Vector3(hug_dir) * gap, along_x)
		var c := cur
		while true:
			seen[c] = true
			_handled_walls[c] = true
			_wall_meshes[c] = inst
			if c == piece_end:
				break
			c += step
		cur = piece_end + step


## Splits `length` tiles into LONG_TILES (5) and SHORT_TILES (3) pieces
## summing to as much of it as possible, preferring more/longer pieces when
## more than one combination covers it exactly. Any remainder (only possible
## for a length of 1, 2, 4 or 7 tiles — every other length is exactly
## representable, since gcd(3,5)=1) is left uncovered; the caller leaves
## those cells for the placeholder box rather than forcing a module to
## overhang or squeeze.
func _pack_tiles(length: int) -> Array[int]:
	var best: Array[int] = []
	var best_leftover := length
	for longs in range(length / LONG_TILES, -1, -1):
		var rest := length - longs * LONG_TILES
		var shorts := rest / SHORT_TILES
		var leftover := rest % SHORT_TILES
		if leftover < best_leftover:
			best_leftover = leftover
			best = []
			for _i in longs:
				best.append(LONG_TILES)
			for _i in shorts:
				best.append(SHORT_TILES)
			if best_leftover == 0:
				break
	return best


## Which way a run's pieces should shift off the tile-centre line they'd
## otherwise sit on, so their face touches the tile boundary they border
## instead of leaving a gap — every module's thickness is noticeably less
## than TILE_SIZE, so centring left visible floor showing past both faces.
## Returns a unit step (to be scaled by however much gap a given piece's own
## thickness leaves — see _handle_run) or ZERO to stay centred.
##
## Checked once per run, at whichever cell is nearest the run's middle,
## rather than at `lo` or `hi` themselves: either end may be a corner cell,
## and a corner's own two perpendicular neighbours are each either VOID or
## WALL (never floor) — that's what makes it a corner — so checking there
## would find no floor side at all. A run entirely made of corners (length 2,
## nothing straight between two bends) still falls back to this and finds
## nothing either, which just leaves it centred rather than guessing wrong.
## An interior partition with floor on both sides also resolves to ZERO
## here, for the same reason: nothing to prefer, so stay centred.
func _hug_direction(lo: Vector3i, hi: Vector3i, step: Vector3i, along_x: bool) -> Vector3i:
	var mid_coord := (_coord_along(lo, step) + _coord_along(hi, step)) / 2
	var rep := lo + step * (mid_coord - _coord_along(lo, step))
	var perp: Vector3i = MapData.SIDE_STEP[MapData.Side.NORTH] if along_x else MapData.SIDE_STEP[MapData.Side.EAST]
	var a := data.is_walkable(rep + perp)
	var b := data.is_walkable(rep - perp)
	if a and not b:
		return perp
	if b and not a:
		return -perp
	return Vector3i.ZERO


## `module_key`'s thickness — its horizontal extent NOT along its own native
## length axis (see MODULE_LENGTH_ALONG_X) — measured fresh off the mesh
## rather than hardcoded, so a re-export in tools/export_room_modules.py
## can't silently drift out of sync with the hug offset in _handle_run.
## Memoised in _thickness_cache: this only needs to run once per module per
## build(), not once per piece placed.
func _module_thickness(module_key: String) -> float:
	if _thickness_cache.has(module_key):
		return _thickness_cache[module_key]
	var inst: Node3D = WALL_MODULES[module_key].instantiate()
	var aabb := AABB()
	var first := true
	for node in _mesh_instances(inst):
		var xformed: AABB = node.transform * node.get_aabb()
		aabb = xformed if first else aabb.merge(xformed)
		first = false
	inst.free()
	var thickness: float = aabb.size.z if MODULE_LENGTH_ALONG_X[module_key] else aabb.size.x
	_thickness_cache[module_key] = thickness
	return thickness


func _mesh_instances(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if root is MeshInstance3D:
		out.append(root)
	for child in root.get_children():
		out.append_array(_mesh_instances(child))
	return out


## `pos`'s coordinate along `step`'s axis, so two positions on the same
## straight line can be compared/ordered with a plain integer rather than
## vector geometry. `step` is always a unit step along X or Z (never both).
func _coord_along(pos: Vector3i, step: Vector3i) -> int:
	return pos.z if step.z != 0 else pos.x


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
func _add_cover_block(footprint: Rect2i, tier: int) -> void:
	var first := cell_to_world(Vector3i(footprint.position.x, 0, footprint.position.y))
	var last := cell_to_world(Vector3i(footprint.position.x + footprint.size.x - 1, 0, footprint.position.y + footprint.size.y - 1))
	var center := (first + last) / 2.0
	var size := Vector3(
		footprint.size.x * GridManager.TILE_SIZE,
		CoverObject.TIER_HEIGHT[tier],
		footprint.size.y * GridManager.TILE_SIZE,
	)
	var mat := _cover_heavy_mat if tier == MapData.Cover.HEAVY else _cover_light_mat
	var body := _add_box_body(center, size, mat, 4)
	body.set_script(load("res://scripts/cover_block.gd"))
	body.call("setup", footprint, 0, tier, _floor_mat, GridManager.TILE_SIZE, GridManager.FLOOR_HEIGHT)
	GridManager.register_cover_block(footprint, 0, tier, body)


func _add_light(world: Vector3, fixture: int) -> void:
	# Sec 5.3 fixtures. Mounted at ceiling-ish height; occlusion is handled by
	# LightingManager's raycast against wall geometry, same as unit LOS.
	var source := LightSource.new()
	match fixture:
		MapData.Fixture.OVERHEAD:  # bright, wide, always on
			source.light_range = 6.0
			source.intensity = 90.0
			source.light_color = Color(1.0, 1.0, 1.0)
		MapData.Fixture.MONITOR:  # terminal glow — dim, short-range
			source.light_range = 2.5
			source.intensity = 45.0
			source.light_color = Color(0.4, 0.75, 1.0)
		MapData.Fixture.FLICKER:  # fluctuates turn-to-turn (Sec 5.3)
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
## Now that walls ARE .glb module instances (Phase 8), `_wall_meshes` holds
## either kind — a bare MeshInstance3D for the placeholder box, or a module
## root for real art — and `_apply_wall_occlusion`/`_wall_nodes_by_hide` below
## are what actually branch on which one a given wall got.
func _process(_delta: float) -> void:
	if data == null:
		return
	_revealed = _revealed_regions()
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


## Q12: a unit's sprite is drawn only in a room holding a player unit.
##
## Deliberately coarser than GDD Sec 10.6's per-unit line-of-sight raycast. A
## room is a piece of space the player can hold in their head — "they are in the
## next compartment" — where a per-unit ray gives a flickering set with no shape
## to it. It also costs a dictionary lookup rather than a raycast per pair.
##
## This does more than hide sprites: an undrawn unit reports `is_instant` and so
## resolves its whole activation with no time on the clock, instead of making the
## player wait out animations against a static screen. See Unit.is_instant.
func _apply_unit_visibility() -> void:
	for node in get_tree().get_nodes_in_group("units"):
		var unit := node as Unit
		if unit:
			unit.set_rendered(_revealed.has(data.room_index_at(unit.grid_pos)))


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
		for linked in data.linked_rooms(index):
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


## Groups `_wall_meshes` by NODE rather than by cell first: a run built by
## _build_wall_runs shares one visual across every cell it covers, and that
## visual can only be hidden or shown as a whole. A run is hidden only when
## EVERY cell it covers wants it hidden — biasing toward staying visible on a
## split verdict is the safe direction, since a wall that should have hidden
## but didn't is a solved problem (open the door), while one that hid when it
## should not have opens the deck onto nothing.
func _wall_nodes_by_hide(step: Vector3i) -> Dictionary:
	var positions_by_node: Dictionary = {}
	for pos: Vector3i in _wall_meshes:
		var node: Node3D = _wall_meshes[pos]
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


func _apply_wall_occlusion(step: Vector3i) -> void:
	var fading_out: Array[MeshInstance3D] = []
	var fading_in: Array[MeshInstance3D] = []
	var by_hide := _wall_nodes_by_hide(step)
	for node: Node3D in by_hide:
		var hide: bool = by_hide[node]
		if hide == not node.visible:
			continue  # already where it needs to be
		# Only the placeholder box (a bare MeshInstance3D) fades — a module
		# instance can carry several MeshInstance3D children with several
		# materials between them, and material_override doesn't reach into
		# that. It pops instead; see MIGRATION_PLAN.md Phase 4 for the fade.
		if not (node is MeshInstance3D):
			node.visible = not hide
			continue
		if hide:
			fading_out.append(node)
		else:
			node.visible = true
			fading_in.append(node)

	if fading_out.is_empty() and fading_in.is_empty():
		return
	if _fade_tween:
		# A snap arriving mid-fade: land the old one before starting the new, or
		# walls caught between the two passes keep a stale material override.
		_fade_tween.kill()
		_settle_fade()
	for mesh in fading_out:
		mesh.material_override = _wall_fade_out_mat
	for mesh in fading_in:
		mesh.material_override = _wall_fade_in_mat
	_fading_out = fading_out
	_fading_in = fading_in
	if _instant_fade():
		_settle_fade()
		return
	_wall_fade_out_mat.albedo_color.a = 1.0
	_wall_fade_in_mat.albedo_color.a = 0.0
	_fade_tween = create_tween()
	_fade_tween.tween_method(_set_fade, 0.0, 1.0, OCCLUSION_FADE)
	_fade_tween.finished.connect(_settle_fade)


func _instant_fade() -> bool:
	# Nothing to fade across with no frames being drawn, and the headless smoke
	# test should not spend wall-clock time on a cosmetic transition.
	return DisplayServer.get_name() == "headless"


func _set_fade(t: float) -> void:
	_wall_fade_out_mat.albedo_color.a = 1.0 - t
	_wall_fade_in_mat.albedo_color.a = t


## Drops both sets back onto the shared opaque material and hides the ones that
## faded out. Called on completion AND on interruption, so a wall is never left
## holding a transparent override it is not currently animating.
func _settle_fade() -> void:
	for mesh in _fading_out:
		mesh.visible = false
		mesh.material_override = _wall_mat
	for mesh in _fading_in:
		mesh.material_override = _wall_mat
	_fading_out = []
	_fading_in = []
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
