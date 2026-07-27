class_name PlayerUnit
extends Unit
## Input handling while this unit is the active (pool-drawn) unit.
## The HUD sets `pending_action`; clicks in the world resolve it.

enum Mode { NONE, MOVE, SHOOT, BARRAGE }

signal action_logged(text: String)

# Sentinel for "the cursor isn't over a walkable tile". Floor -9999 can never
# collide with a real grid key.
const NO_TILE := Vector3i(0, -9999, 0)

var mode: Mode = Mode.NONE
# Move is one action whose cost depends on how far the destination is: the
# inner band is a 1 AP run, the outer band a 2 AP sprint (Sec 4.2).
var _run_tiles: Array[Vector3i] = []
var _sprint_tiles: Array[Vector3i] = []
var _hover_tile: Vector3i = NO_TILE
var _preview_path: Array[Vector3i] = []
var _preview_cost: int = 0


func _init() -> void:
	is_player_controlled = true


func _ready() -> void:
	super()
	set_process(false)  # only polled while a move mode is armed


func set_mode(new_mode: Mode) -> void:
	if is_busy:
		return
	mode = new_mode
	_hover_tile = NO_TILE
	_preview_path = []
	_preview_cost = 0
	_run_tiles = []
	_sprint_tiles = []
	var highlights := get_tree().get_first_node_in_group("highlights")
	if highlights:
		highlights.clear_highlights()
	match mode:
		Mode.MOVE:
			_run_tiles = GridManager.get_reachable_tiles(grid_pos, stats.move_run())
			if ap >= 2:
				# Only offer the sprint band when the second AP is actually there.
				_sprint_tiles = _outer_band(
					_run_tiles, GridManager.get_reachable_tiles(grid_pos, stats.move_sprint()))
			if highlights:
				highlights.show_move_range(_run_tiles, _sprint_tiles)
		Mode.SHOOT, Mode.BARRAGE:
			if highlights:
				_show_targets(highlights)
	set_process(mode != Mode.NONE)


func _outer_band(inner: Array[Vector3i], full: Array[Vector3i]) -> Array[Vector3i]:
	var seen := {}
	for tile in inner:
		seen[tile] = true
	var out: Array[Vector3i] = []
	for tile in full:
		if not seen.has(tile):
			out.append(tile)
	return out


func _cost_for(tile: Vector3i) -> int:
	# 0 means "not a legal destination", including affordable-range tiles the
	# unit lacks the AP for, since those bands are never populated.
	if tile in _run_tiles:
		return 1
	if tile in _sprint_tiles:
		return 2
	return 0


func _show_targets(highlights: Node) -> void:
	# Every hostile this unit can actually put a shot on right now — the same
	# line-of-sight test _try_shoot enforces — labelled with its hit chance.
	var tiles: Array[Vector3i] = []
	var accuracies: Array[int] = []
	var action := Combat.ShotAction.SHOOT if mode == Mode.SHOOT else Combat.ShotAction.BARRAGE
	for node in get_tree().get_nodes_in_group("enemy_units"):
		var enemy := node as Unit
		if enemy == null or enemy.is_downed:
			continue
		if not GridManager.has_line_of_sight(self, enemy):
			continue
		tiles.append(enemy.grid_pos)
		accuracies.append(Combat.compute_accuracy(self, enemy, action))
	highlights.show_targets(tiles, accuracies)


func _range_for(cost: int) -> int:
	return stats.move_run() if cost == 1 else stats.move_sprint()


func _process(_delta: float) -> void:
	# Re-raycast every frame rather than on mouse motion alone: panning or
	# orbiting the camera slides something different under a stationary cursor.
	if not _accepting_input():
		return
	var highlights := get_tree().get_first_node_in_group("highlights")
	if highlights == null:
		return
	match mode:
		Mode.MOVE:
			_update_path_preview(highlights)
		Mode.SHOOT, Mode.BARRAGE:
			_update_target_hover(highlights)


func _update_path_preview(highlights: Node) -> void:
	var tile := _tile_under_mouse()
	if tile == _hover_tile:
		return
	_hover_tile = tile
	_preview_path = []
	_preview_cost = _cost_for(tile)
	if _preview_cost > 0:
		_preview_path = GridManager.find_path(grid_pos, tile, _range_for(_preview_cost))
	highlights.show_path(_preview_path, _preview_cost)


func _update_target_hover(highlights: Node) -> void:
	var tile := NO_TILE
	var hit := _raycast_mouse()
	if not hit.is_empty():
		var unit := _unit_from_collider(hit["collider"])
		if unit and not unit.is_player_controlled and not unit.is_downed:
			tile = unit.grid_pos
	if tile == _hover_tile:
		return
	_hover_tile = tile
	highlights.set_hovered_target(tile)


func _unhandled_input(event: InputEvent) -> void:
	if not _accepting_input():
		return
	if not event.is_action_pressed("select_unit"):
		return
	var hit := _raycast_mouse()
	if hit.is_empty():
		return
	var unit := _unit_from_collider(hit["collider"])
	if unit and not unit.is_player_controlled and mode in [Mode.SHOOT, Mode.BARRAGE]:
		_try_shoot(unit)
	elif unit == null and mode == Mode.MOVE:
		_try_move(GridManager.world_to_grid(hit["position"]))


func _accepting_input() -> bool:
	return TurnManager.active_unit == self and not is_downed and not is_busy


func _raycast_mouse() -> Dictionary:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return {}
	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	var from := camera.project_ray_origin(mouse_pos)
	var to := from + camera.project_ray_normal(mouse_pos) * 500.0
	var query := PhysicsRayQueryParameters3D.create(from, to, 1 | 2)
	return get_world_3d().direct_space_state.intersect_ray(query)


func _tile_under_mouse() -> Vector3i:
	var hit := _raycast_mouse()
	# A unit under the cursor means no destination — clear the preview.
	if hit.is_empty() or _unit_from_collider(hit["collider"]) != null:
		return NO_TILE
	return GridManager.world_to_grid(hit["position"])


func _unit_from_collider(collider: Object) -> Unit:
	var node := collider as Node
	while node:
		if node is Unit:
			return node
		node = node.get_parent()
	return null


func _try_move(target: Vector3i) -> void:
	var cost := _cost_for(target)
	if cost == 0 or ap < cost:
		return
	var path := _preview_path
	if path.is_empty() or path[-1] != target:
		path = GridManager.find_path(grid_pos, target, _range_for(cost))
	if path.is_empty():
		return
	var verb := "moved" if cost == 1 else "sprinted"
	spend_ap(cost)  # before the walk, so the HUD greys the buttons immediately
	set_mode(Mode.NONE)
	await move_along(path)
	action_logged.emit("%s %s to %s (%d AP)" % [stats.display_name, verb, target, cost])
	_check_activation_end()


func _try_shoot(target: Unit) -> void:
	var cost := 1 if mode == Mode.SHOOT else 2
	if ap < cost or not can_shoot():
		return
	if not GridManager.has_line_of_sight(self, target):
		action_logged.emit("%s: no line of sight to %s" % [stats.display_name, target.stats.display_name])
		return
	var action := Combat.ShotAction.SHOOT if mode == Mode.SHOOT else Combat.ShotAction.BARRAGE
	spend_ap(cost)
	var result: Combat.ShotResult = await fire_at(target, action)
	action_logged.emit("%s fired at %s (%d%% acc): %s" % [stats.display_name, target.stats.display_name, result.accuracy, Combat.describe(result)])
	if target.is_downed:
		action_logged.emit("%s is DOWN!" % target.stats.display_name)
	if result.had_cover:
		var t: GridTileData = GridManager.get_tile(result.cover_tile)
		if t and t.cover_type == GridTileData.CoverType.NONE:
			action_logged.emit("Cover at %s destroyed — now impassable rubble!" % result.cover_tile)
	set_mode(Mode.NONE)
	_check_activation_end()


func try_hunker() -> void:
	if ap < 1 or is_busy:
		return
	do_hunker()
	spend_ap(1)
	set_mode(Mode.NONE)
	action_logged.emit("%s hunkered down" % stats.display_name)
	_check_activation_end()


func try_overwatch() -> void:
	if ap < 2 or is_busy or not can_shoot():
		return
	do_overwatch()
	spend_ap(2)
	set_mode(Mode.NONE)
	action_logged.emit("%s is on overwatch" % stats.display_name)
	_check_activation_end()


func try_toggle_flashlight() -> void:
	# Free action (0 AP, Sec 4.2) — no AP spend, doesn't end the activation.
	if is_busy:
		return
	toggle_flashlight()
	action_logged.emit("%s switched their flashlight %s" % [stats.display_name, "on" if flashlight_on else "off"])


func try_reload() -> void:
	if ap < 1 or is_busy:
		return
	spend_ap(1)  # before the animation, so the HUD greys the buttons immediately
	set_mode(Mode.NONE)
	await do_reload()
	action_logged.emit("%s reloaded" % stats.display_name)
	_check_activation_end()


func _check_activation_end() -> void:
	if ap <= 0:
		end_activation()


func end_activation() -> void:
	if is_busy:
		return
	set_mode(Mode.NONE)
	TurnManager.end_activation(self)
