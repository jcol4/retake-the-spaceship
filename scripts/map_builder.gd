class_name MapBuilder
extends Node3D
## Turns a MapData into scene nodes: grid tiles, collision, meshes, cover and
## light fixtures. This is the only half of the map pipeline that needs a scene
## tree — generation and validation both run on MapData alone.

const WALL_HEIGHT := 3.0
const PLATFORM_HEIGHT := 3.0

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

## Cell position -> that wall's MeshInstance3D. Only the mesh is kept, because
## only the mesh is ever hidden — see _apply_wall_occlusion.
var _wall_meshes: Dictionary = {}
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
	_occlusion_step = Vector3i.ZERO  # forces a recompute against the new layout
	_revealed.clear()
	_last_revealed.clear()
	if _fade_tween:
		_fade_tween.kill()
	_fading_out = []
	_fading_in = []
	_fade_tween = null
	GridManager.clear()
	for pos: Vector3i in data.cells:
		_build_cell(pos, data.get_cell(pos))
	# After every cell, because an edge prop registers itself against the tiles on
	# BOTH sides and those tiles have to exist first.
	for entry: Array in data.cover_edge_list():
		_add_cover_edge(entry[0], entry[1], entry[2])
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
			_add_wall(pos, world)
			return
		MapData.Terrain.PLATFORM:
			# The block is solid; the walkable tile is its top surface.
			GridManager.add_tile(data.walkable_pos(pos), world + Vector3(0, PLATFORM_HEIGHT, 0))
			_add_platform(world)
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


func _add_wall(pos: Vector3i, world: Vector3) -> void:
	var body := _add_box_body(world, Vector3(GridManager.TILE_SIZE, WALL_HEIGHT, GridManager.TILE_SIZE), _wall_mat, 1)
	# Kept so wall occlusion can hide this mesh without touching its collision.
	_wall_meshes[pos] = body.get_node("Mesh")


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
## When walls become .glb module instances (Phase 8) the only thing that changes
## here is what `_wall_meshes` holds — the module root instead of the "Mesh"
## child. Nothing in the rule below reads the node's type.
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


func _apply_wall_occlusion(step: Vector3i) -> void:
	var fading_out: Array[MeshInstance3D] = []
	var fading_in: Array[MeshInstance3D] = []
	for pos: Vector3i in _wall_meshes:
		var mesh: MeshInstance3D = _wall_meshes[pos]
		var hide := _hides_interior(pos, step)
		if hide == not mesh.visible:
			continue  # already where it needs to be
		if hide:
			fading_out.append(mesh)
		else:
			mesh.visible = true
			fading_in.append(mesh)

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
