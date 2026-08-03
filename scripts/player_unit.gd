class_name PlayerUnit
extends Unit
## Input handling while this unit is the active (pool-drawn) unit.
## The HUD sets `pending_action`; clicks in the world resolve it.

enum Mode { NONE, MOVE, SHOOT, AIMED_SHOT, FACE, EMP }

# EMP grenade (security-robots/design-choices/armor-and-destruction.md). The
# faction's counter-lever, and the reason a robot-heavy mission rewards a
# different loadout than an alien-heavy one: it does no damage at all, but it
# takes a machine's Armor off for a window and burns its next activation.
#
# Implemented as a throw rather than as an equipped weapon because it is neither
# — it is the Throw Grenade action of Sec 4.2, the first item to actually use it.
const EMP_AP_COST := 1
const EMP_THROW_RANGE := 6  # tiles, Chebyshev
const EMP_BLAST_RADIUS := 1  # 3x3, centred on the tile clicked
const EMP_STUN_TURNS := 2  # roster default; each unit's own resistance scales it

signal action_logged(text: String)
# Fired instead of firing immediately when a valid target is clicked while
# Aimed Shot is armed (Sec 4.2/6.5) — the HUD catches this to pop up its
# Fallout-VATS-style zone menu; `fire_aimed_shot` below does the actual shot
# once the player picks a zone from it.
signal aimed_shot_target_picked(target: Unit)

# Sentinel for "the cursor isn't over a walkable tile". Floor -9999 can never
# collide with a real grid key.
const NO_TILE := Vector3i(0, -9999, 0)

# Indexed by MapData.Side, for the combat log.
const _SIDE_WORD := ["east", "south", "west", "north"]

var mode: Mode = Mode.NONE
## Grenades this soldier deployed with. One each in the alpha: enough that the
## squad can open a window on the fight's hardest target, not enough to answer
## every armored unit on a deck — which is what keeps positioning the primary
## plan and EMP the thing that rescues it.
var emp_charges: int = 1
# Move is one action whose cost depends on how far the destination is: the
# inner band is a 1 AP run, the outer band a 2 AP sprint (Sec 4.2).
var _run_tiles: Array[Vector3i] = []
var _sprint_tiles: Array[Vector3i] = []
var _hover_tile: Vector3i = NO_TILE
## Cached while EMP is armed. Each entry costs a raycast, and the set cannot
## change while the mode is up — a unit cannot move without disarming first — so
## recomputing it per frame would be ~170 rays a frame for an answer that is
## already known.
var _throw_tiles: Array[Vector3i] = []
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
	_throw_tiles = []
	var highlights := get_tree().get_first_node_in_group("highlights")
	if highlights:
		highlights.clear_highlights()
	match mode:
		Mode.MOVE:
			_run_tiles = GridManager.get_reachable_tiles(grid_pos, move_run())
			if ap >= 2:
				# Only offer the sprint band when the second AP is actually there.
				_sprint_tiles = _outer_band(
					_run_tiles, GridManager.get_reachable_tiles(grid_pos, move_sprint()))
			if highlights:
				highlights.show_move_range(_run_tiles, _sprint_tiles)
		Mode.SHOOT, Mode.AIMED_SHOT:
			if highlights:
				_show_targets(highlights)
		Mode.EMP:
			_throw_tiles = _throwable_tiles()
			if highlights:
				highlights.show_throw_range(_throw_tiles)
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
	# Aimed Shot previews against the Torso baseline; the per-zone breakdown
	# only appears once a target is actually picked (Sec 4.2/6.5's VATS menu).
	var tiles: Array[Vector3i] = []
	var accuracies: Array[int] = []
	var action := Combat.ShotAction.SHOOT if mode == Mode.SHOOT else Combat.ShotAction.AIMED_SHOT
	for node in get_tree().get_nodes_in_group("enemy_units"):
		var enemy := node as Unit
		if enemy == null or enemy.is_downed:
			continue
		if not GridManager.has_line_of_sight(self, enemy):
			continue
		tiles.append(enemy.grid_pos)
		accuracies.append(Combat.compute_accuracy(self, enemy, action, Combat.BodyPart.TORSO))
	highlights.show_targets(tiles, accuracies)


func _range_for(cost: int) -> int:
	return move_run() if cost == 1 else move_sprint()


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
		Mode.SHOOT, Mode.AIMED_SHOT:
			_update_target_hover(highlights)
		Mode.EMP:
			_update_blast_preview(highlights)


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


## Tiles this soldier can put a grenade on: in range, on the grid, and in line of
## sight, so a throw cannot be lobbed through a bulkhead into the next
## compartment. Unlike a move, the tile may be OCCUPIED — the whole point is to
## land it on the machine standing there.
func _throwable_tiles() -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for dz in range(-EMP_THROW_RANGE, EMP_THROW_RANGE + 1):
		for dx in range(-EMP_THROW_RANGE, EMP_THROW_RANGE + 1):
			var tile := grid_pos + Vector3i(dx, 0, dz)
			if not GridManager.has_tile(tile):
				continue
			if not GridManager.has_clear_line(self,
					global_position + Vector3(0, 1.4, 0),
					GridManager.grid_to_world(tile) + Vector3(0, 0.9, 0)):
				continue
			out.append(tile)
	return out


func _blast_tiles(centre: Vector3i) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for dz in range(-EMP_BLAST_RADIUS, EMP_BLAST_RADIUS + 1):
		for dx in range(-EMP_BLAST_RADIUS, EMP_BLAST_RADIUS + 1):
			var tile := centre + Vector3i(dx, 0, dz)
			if GridManager.has_tile(tile):
				out.append(tile)
	return out


func _update_blast_preview(highlights: Node) -> void:
	var tile := _tile_under_mouse_any()
	if tile == _hover_tile:
		return
	_hover_tile = tile
	var blast: Array[Vector3i] = []
	if tile != NO_TILE and tile in _throw_tiles:
		blast = _blast_tiles(tile)
	highlights.show_throw_range(_throw_tiles, blast)


## Like `_tile_under_mouse`, but a unit standing on the tile does not disqualify
## it — a grenade is aimed AT things, where a move is aimed at empty deck.
func _tile_under_mouse_any() -> Vector3i:
	var hit := _raycast_mouse()
	if hit.is_empty():
		return NO_TILE
	var unit := _unit_from_collider(hit["collider"])
	return unit.grid_pos if unit else GridManager.world_to_grid(hit["position"])


func _try_throw_emp(target: Vector3i) -> void:
	if ap < EMP_AP_COST or emp_charges <= 0 or is_busy:
		return
	# Re-validated against the same cached set the overlay was drawn from, so what
	# the player clicked and what they were shown can never disagree.
	if not (target in _throw_tiles):
		action_logged.emit("%s: no throwing line to %s" % [stats.display_name, target])
		return
	emp_charges -= 1
	spend_ap(EMP_AP_COST)
	set_mode(Mode.NONE)
	await face_toward(GridManager.grid_to_world(target))
	await visual.play_action(UnitVisual.GRENADE)
	var vfx := get_tree().get_first_node_in_group("vfx")
	if vfx and not is_instant():
		vfx.impact(GridManager.grid_to_world(target) + Vector3(0, 0.9, 0), true)
	action_logged.emit("%s throws an EMP grenade at %s" % [stats.display_name, target])
	# An explosion is loud, and the robots' sound channel is the one thing about
	# them a grenade does NOT bypass: throwing it announces where you are.
	SecurityNetwork.report_noise(target, self)
	var caught := 0
	for tile in _blast_tiles(target):
		var t: GridTileData = GridManager.get_tile(tile)
		if t == null:
			continue
		var robot := t.occupant as CerberusUnit
		if robot == null or robot.is_downed:
			continue
		robot.apply_emp(EMP_STUN_TURNS)
		caught += 1
	if caught == 0:
		# Deliberately not refunded. The charge is spent on the throw, not on the
		# outcome, which is what makes range and timing a real decision.
		action_logged.emit("The EMP burst catches nothing")
	_check_activation_end()


func _unhandled_input(event: InputEvent) -> void:
	if not _accepting_input():
		return
	if not event.is_action_pressed("select_unit"):
		return
	var hit := _raycast_mouse()
	if hit.is_empty():
		return
	if mode == Mode.EMP:
		# Ahead of the unit lookup, like FACE: landing it on the machine itself is
		# the normal way to use this.
		_try_throw_emp(_tile_under_mouse_any())
		return
	if mode == Mode.FACE:
		# Deliberately ahead of the unit lookup: aiming the beam *at* something is
		# the main reason to use this, so clicking an alien has to be allowed.
		_try_face(hit["position"])
		return
	var unit := _unit_from_collider(hit["collider"])
	if unit and not unit.is_player_controlled and mode in [Mode.SHOOT, Mode.AIMED_SHOT]:
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
	if mode == Mode.AIMED_SHOT:
		# Doesn't fire yet — Aimed Shot needs a zone first. The HUD listens for
		# this and opens the VATS-style menu; `fire_aimed_shot` below finishes
		# the job once the player picks one.
		if ap < 2 or not can_shoot():
			return
		if not GridManager.has_line_of_sight(self, target):
			action_logged.emit("%s: no line of sight to %s" % [stats.display_name, target.stats.display_name])
			return
		aimed_shot_target_picked.emit(target)
		return
	if ap < 1 or not can_shoot():
		return
	if not GridManager.has_line_of_sight(self, target):
		action_logged.emit("%s: no line of sight to %s" % [stats.display_name, target.stats.display_name])
		return
	spend_ap(1)
	var result: Combat.ShotResult = await fire_at(target, Combat.ShotAction.SHOOT)
	action_logged.emit("%s fired at %s (%d%% acc): %s" % [stats.display_name, target.stats.display_name, result.accuracy, Combat.describe(result)])
	_log_shot_aftermath(target, result)
	set_mode(Mode.NONE)
	_check_activation_end()


func fire_aimed_shot(target: Unit, body_part: int) -> void:
	# Called by the HUD once the player picks a zone from the VATS-style menu
	# opened after `aimed_shot_target_picked`. Re-validates everything, since
	# AP/LOS/ammo could all have changed while that menu was up.
	if ap < 2 or not can_shoot() or target.is_downed:
		return
	if not GridManager.has_line_of_sight(self, target):
		action_logged.emit("%s: no line of sight to %s" % [stats.display_name, target.stats.display_name])
		return
	spend_ap(2)
	var result: Combat.ShotResult = await fire_at(target, Combat.ShotAction.AIMED_SHOT, body_part)
	var zone_tag := " [%s]" % Combat.body_part_name(body_part)
	action_logged.emit("%s fired at %s%s (%d%% acc): %s" % [stats.display_name, target.stats.display_name, zone_tag, result.accuracy, Combat.describe(result)])
	if result.newly_injured:
		action_logged.emit("%s's %s is INJURED!" % [target.stats.display_name, Combat.body_part_name(body_part)])
	if result.stunned:
		action_logged.emit("%s is STUNNED!" % target.stats.display_name)
	_log_shot_aftermath(target, result)
	set_mode(Mode.NONE)
	_check_activation_end()


func _log_shot_aftermath(target: Unit, result: Combat.ShotResult) -> void:
	if target.is_downed:
		action_logged.emit("%s is DOWN!" % target.stats.display_name)
	if result.had_cover and result.cover_broken:
		# No "impassable rubble" any more: the tile was always passable under the
		# edge model, and heavy cover degrades to light rather than vanishing.
		var now := GridManager.cover_type_on(result.cover_tile, result.cover_side)
		var where := "%s side of %s" % [_SIDE_WORD[result.cover_side], result.cover_tile]
		if now == MapData.Cover.NONE:
			action_logged.emit("Cover on the %s is destroyed!" % where)
		else:
			action_logged.emit("Heavy cover on the %s is shot down to light cover" % where)


func try_hunker() -> void:
	if ap < 1 or is_busy:
		return
	do_hunker()
	spend_ap(1)
	set_mode(Mode.NONE)
	action_logged.emit("%s hunkered down" % stats.display_name)
	_check_activation_end()


func try_overwatch() -> void:
	if ap < 1 or is_busy or not can_shoot():
		return
	do_overwatch()
	spend_ap(1)
	set_mode(Mode.NONE)
	action_logged.emit("%s is on overwatch" % stats.display_name)
	_check_activation_end()


func _try_face(world_pos: Vector3) -> void:
	# Free action (0 AP, Sec 4.2), like the flashlight toggle, and for the same
	# reason: sweeping a beam to find out what's in a room must not compete with
	# shooting what's found. Doesn't end the activation.
	if is_busy:
		return
	set_mode(Mode.NONE)
	await face_toward(world_pos)
	action_logged.emit("%s turned to face %s" % [
		stats.display_name, GridManager.world_to_grid(world_pos)])


func try_toggle_flashlight() -> void:
	# Free action (0 AP, Sec 4.2) — no AP spend, doesn't end the activation.
	if is_busy:
		return
	toggle_flashlight()
	action_logged.emit("%s switched their flashlight %s" % [stats.display_name, "on" if flashlight_on else "off"])


func try_reload() -> void:
	if ap < 1 or is_busy or not can_reload():
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
