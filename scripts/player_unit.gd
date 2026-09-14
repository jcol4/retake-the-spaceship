class_name PlayerUnit
extends Unit
## Input handling while this unit is the active (pool-drawn) unit.
## The HUD sets `pending_action`; clicks in the world resolve it.

enum Mode { NONE, MOVE, SHOOT, AIMED_SHOT, SUPPRESS, FACE, GRENADE }

## The payloads Throw Grenade (Sec 4.2) can pick between, chosen from the popup
## `grenade_target_picked` opens — same shape as Aimed Shot's zone menu, just
## picking a payload instead of a body-part zone. One throwable slot
## (`grenade_charges`) covers either: EMP is not a second, always-available
## charge stacked on top of Frag, it is one of the two things the single charge
## can be spent on.
enum GrenadeType { EMP, FRAG }

# EMP grenade (security-robots/design-choices/armor-and-destruction.md). The
# faction's counter-lever, and the reason a robot-heavy mission rewards a
# different loadout than an alien-heavy one: it does no damage at all, but it
# takes a machine's Armor off for a window and burns its next activation.
#
# Frag is the GDD's other sketched payload (Sec 6.1.1) — ordinary AoE damage,
# plus the cover-breaker bonus damage every explosive gets against cover.
#
# Implemented as a throw rather than as an equipped weapon because it is neither
# — it is the Throw Grenade action of Sec 4.2, the first item to actually use it,
# and it is priced as one (UnitStats.Action.GRENADE) rather than carrying an AP
# cost of its own.
const THROW_RANGE := 6  # tiles, Chebyshev
const BLAST_RADIUS := 1  # 3x3, centred on the tile clicked
const EMP_STUN_TURNS := 2  # roster default; each unit's own resistance scales it
## Sec 6.1.1's cover-breaker bonus is TBD roster-wide (GDD open item 8); this is
## a placeholder in the same spirit as the rest of the faction's unset numbers,
## not a considered balance figure.
const FRAG_DAMAGE := 8

signal action_logged(text: String)
# Fired instead of firing immediately when a valid target is clicked while
# Aimed Shot is armed (Sec 4.2/6.5) — the HUD catches this to pop up its
# Fallout-VATS-style zone menu; `fire_aimed_shot` below does the actual shot
# once the player picks a zone from it.
signal aimed_shot_target_picked(target: Unit)
# Same pattern, one throw earlier: a tile clicked while Grenade is armed opens
# the EMP/Frag payload menu instead of throwing immediately; `_try_throw_grenade`
# below does the actual throw once the player picks one.
signal grenade_target_picked(target: Vector3i)

# Sentinel for "the cursor isn't over a walkable tile". Floor -9999 can never
# collide with a real grid key.
const NO_TILE := Vector3i(0, -9999, 0)

# Indexed by MapData.Side, for the combat log.
const _SIDE_WORD := ["east", "south", "west", "north"]

var mode: Mode = Mode.NONE
## Grenades this soldier deployed with. One each in the alpha: enough that the
## squad can open a window on the fight's hardest target, not enough to answer
## every armored unit on a deck — which is what keeps positioning the primary
## plan and the grenade the thing that rescues it. One throw, EMP or Frag —
## see GrenadeType.
var grenade_charges: int = 1
## Destination tile -> tiles walked to reach it. Move is priced per tile now
## (rework doc Sec 4.1), so this doubles as the AP cost of every candidate
## destination once multiplied by `move_ap_per_tile()` — there is no Run band and
## no Sprint band any more, just a single reachable set the unit can afford.
var _move_costs: Dictionary = {}
var _hover_tile: Vector3i = NO_TILE
## Cached while EMP is armed. Each entry costs a raycast, and the set cannot
## change while the mode is up — a unit cannot move without disarming first — so
## recomputing it per frame would be ~170 rays a frame for an answer that is
## already known.
var _throw_tiles: Array[Vector3i] = []
var _preview_path: Array[Vector3i] = []
var _preview_cost: int = 0


func _init() -> void:
	faction = Faction.Id.CONTRACTORS


## Routes GOAP's narration into this unit's own log signal.
##
## Only ever used by the headless smoke test, which drives soldiers with the same
## planner the rival mercs use — see `main.gd._auto_play`. A human-played soldier
## never reaches this, because a human is the planner.
func report_action(text: String) -> void:
	action_logged.emit(text)


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
	_move_costs = {}
	_throw_tiles = []
	var highlights := get_tree().get_first_node_in_group("highlights")
	if highlights:
		highlights.clear_highlights()
	match mode:
		Mode.MOVE:
			# One band, bounded by what the pool actually affords. The old inner/
			# outer split existed because a move was one of two fixed-price
			# actions; now the price is the distance, so a second band would just
			# be an arbitrary line drawn across a continuous cost.
			_move_costs = GridManager.reachable_costs(grid_pos, move_tiles_affordable())
			if highlights:
				highlights.show_move_range(_move_costs, move_ap_per_tile(), ap)
		Mode.SHOOT, Mode.AIMED_SHOT, Mode.SUPPRESS:
			if highlights:
				_show_targets(highlights)
		Mode.GRENADE:
			_throw_tiles = _throwable_tiles()
			if highlights:
				highlights.show_throw_range(_throw_tiles)
	set_process(mode != Mode.NONE)


func _cost_for(tile: Vector3i) -> int:
	# 0 means "not a legal destination". Tiles the unit cannot afford are never in
	# `_move_costs` in the first place — the set is built against the affordable
	# radius — so absence covers both "out of range" and "out of AP".
	return move_cost_for(_move_costs.get(tile, 0))


func _show_targets(highlights: Node) -> void:
	# Every hostile this unit can actually put a shot on right now — the same
	# line-of-sight test _try_shoot enforces — labelled with its hit chance.
	# Aimed Shot previews against the Torso baseline; the per-zone breakdown
	# only appears once a target is actually picked (Sec 4.2/6.5's VATS menu).
	var tiles: Array[Vector3i] = []
	var accuracies: Array[int] = []
	var action := Combat.ShotAction.SHOOT if mode == Mode.SHOOT else Combat.ShotAction.AIMED_SHOT
	for enemy in hostiles():
		if not GridManager.has_line_of_sight(self, enemy):
			continue
		tiles.append(enemy.grid_pos)
		accuracies.append(Combat.compute_accuracy(self, enemy, action, Combat.BodyPart.TORSO))
	highlights.show_targets(tiles, accuracies)


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
		Mode.SHOOT, Mode.AIMED_SHOT, Mode.SUPPRESS:
			_update_target_hover(highlights)
		Mode.GRENADE:
			_update_blast_preview(highlights)


func _update_path_preview(highlights: Node) -> void:
	var tile := _tile_under_mouse()
	if tile == _hover_tile:
		return
	_hover_tile = tile
	_preview_path = []
	_preview_cost = _cost_for(tile)
	if _preview_cost > 0:
		_preview_path = GridManager.find_path(grid_pos, tile, move_tiles_affordable())
	# Sec 4.6: the preview reports what the move LEAVES, not just what it takes —
	# with a pool this is the number the next decision is made against.
	highlights.show_path(_preview_path, _preview_cost, ap - _preview_cost)


func _update_target_hover(highlights: Node) -> void:
	var tile := NO_TILE
	# Layer 2 (units) only, not 1|2 — a wall between the camera and the target
	# must not eat this pick. `_apply_wall_occlusion` (map_builder.gd) hides
	# only the MESH of a near wall and keeps its StaticBody3D live so LOS stays
	# honest, so a combined-mask raycast still hits the invisible wall first.
	# Same reasoning as `GridManager.tile_under_ray`'s projection fix.
	var hit := _raycast_mouse(2)
	if not hit.is_empty():
		var unit := _unit_from_collider(hit["collider"])
		if unit and is_hostile_to(unit) and not unit.is_downed:
			tile = unit.grid_pos
	if tile == _hover_tile:
		return
	_hover_tile = tile
	highlights.set_hovered_target(tile)


## Tiles this soldier can put a grenade on: in range, on the grid, and in line of
## sight, so a throw cannot be lobbed through a bulkhead into the next
## compartment. Unlike a move, the tile may be OCCUPIED — the whole point is to
## land it on the machine standing there. Same shell for both payloads
## (GrenadeType) — which one is being thrown is picked after the tile is.
func _throwable_tiles() -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for dz in range(-THROW_RANGE, THROW_RANGE + 1):
		for dx in range(-THROW_RANGE, THROW_RANGE + 1):
			var tile := grid_pos + Vector3i(dx, 0, dz)
			if _can_throw_grenade_at(tile):
				out.append(tile)
	return out


## The single source of truth for "is this tile a legal grenade target" — used
## both to build the cached `_throw_tiles` overlay above and, critically, by
## `_try_pick_grenade_target`/`_try_throw_grenade` themselves. Those run on
## whichever peer is authoritative for this unit (see `_issue`/`_rpc_command`),
## which in co-op is the HOST's copy — a copy whose `_throw_tiles` cache was
## never populated, because the host's own UI never armed Grenade mode for a
## squadmate's merc. Re-deriving it live instead of trusting the cache is what
## keeps a client's throw from being rejected as "no line" every time.
func _can_throw_grenade_at(target: Vector3i) -> bool:
	var delta := target - grid_pos
	if absi(delta.x) > THROW_RANGE or absi(delta.z) > THROW_RANGE:
		return false
	if not GridManager.has_tile(target):
		return false
	return GridManager.has_clear_line(self,
			global_position + Vector3(0, 1.4, 0),
			GridManager.grid_to_world(target) + Vector3(0, 0.9, 0))


func _blast_tiles(centre: Vector3i) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for dz in range(-BLAST_RADIUS, BLAST_RADIUS + 1):
		for dx in range(-BLAST_RADIUS, BLAST_RADIUS + 1):
			var tile := centre + Vector3i(dx, 0, dz)
			if GridManager.has_tile(tile):
				out.append(tile)
	return out


## The `throw_grenade` animation (art_src/merc_anim.blend, action `grenade`)
## releases the grenade 135 degrees off from wherever the merc is actually
## drawn facing — a cross-body motion baked into the pose itself, not a
## whole-rig authoring offset like `run`'s (render_sprites.py
## BUCKET_ZERO_DEGREES), which is why the fix belongs here rather than in the
## render pipeline: the body still has to visibly face a real direction, it is
## only the release point that is thrown off.
##
## So a grenade actually meant for `target` cannot face `target` directly —
## `_try_throw_grenade` must face this instead, three of the eight buckets
## (unit_visual.gd DIRECTIONS) short of it, so the animation's own offset lands
## the throw back where it was aimed. 3 buckets rather than a signed "left/right"
## note because that is what's unambiguous: `direction_bucket` is a strictly
## increasing function of `rotation.y`, so "3 buckets short" is exactly
## `-3 * (TAU / DIRECTIONS.size())` of yaw with no separate sign to get wrong,
## and it round-trips through the same eight facings every other pose does.
##
## Judge this against a THROWN GRENADE actually landing on the clicked tile in
## game, never against the rendered PNGs alone — render_sprites.py's own
## BUCKET_ZERO_DEGREES warns that an offset like this is self-consistent at any
## sign and only shows up wrong on a moving (or in this case, thrown) unit.
const GRENADE_RELEASE_OFFSET := 3.0 * (TAU / 8.0)  # 8 == UnitVisual.DIRECTIONS.size()


## Where to face so the anim's own throw lands on `target` — see
## GRENADE_RELEASE_OFFSET. Returns a point out along the compensated yaw rather
## than a yaw directly, so the caller can hand it straight to `face_toward`
## and get the same turn/tween/cover-refresh handling every other facing change
## goes through.
func _grenade_face_position(target: Vector3i) -> Vector3:
	var true_yaw := _yaw_toward(GridManager.grid_to_world(target))
	if is_nan(true_yaw):
		return global_position  # degenerate (target under our own feet); face_toward no-ops
	var face_yaw := true_yaw - GRENADE_RELEASE_OFFSET
	return global_position + Vector3(-sin(face_yaw), 0.0, -cos(face_yaw)) * 5.0


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
##
## Units are still picked by raycast, because a sprite is a thing on screen and
## hitting it should mean hitting it. Only the fallback — the bare deck — uses
## projection, so a throw can be aimed at a tile a wall would otherwise hide.
## Whether the throw is legal is unchanged: `_throw_tiles` still requires a clear
## line from the thrower.
func _tile_under_mouse_any() -> Vector3i:
	var hit := _raycast_mouse()
	if not hit.is_empty():
		var unit := _unit_from_collider(hit["collider"])
		if unit:
			return unit.grid_pos
	return _tile_under_mouse()


## Opens the payload menu (Sec 4.2/6.5-style) rather than throwing immediately —
## mirrors `_try_shoot`'s AIMED_SHOT branch, including staying LOCAL rather than
## going through `_issue`: this only pops up UI on the clicking peer, and
## `_try_throw_grenade` below re-validates everything for real once a payload is
## picked.
func _try_pick_grenade_target(target: Vector3i) -> void:
	if ap < action_cost(UnitStats.Action.GRENADE) or grenade_charges <= 0 or is_busy:
		return
	if not _can_throw_grenade_at(target):
		action_logged.emit("%s: no throwing line to %s" % [stats.display_name, target])
		return
	grenade_target_picked.emit(target)


func _try_throw_grenade(target: Vector3i, type: GrenadeType) -> void:
	var cost := action_cost(UnitStats.Action.GRENADE)
	if ap < cost or grenade_charges <= 0 or is_busy:
		return
	# Re-validated live (see `_can_throw_grenade_at`) rather than against the
	# cached overlay: this may be running on the host's copy of the unit, not
	# the clicking peer's, so the local `_throw_tiles` cache can't be trusted.
	if not _can_throw_grenade_at(target):
		action_logged.emit("%s: no throwing line to %s" % [stats.display_name, target])
		return
	grenade_charges -= 1
	spend_ap(cost)
	set_mode(Mode.NONE)
	# Faces short of the target on purpose — see GRENADE_RELEASE_OFFSET. The
	# flash still lands exactly on `target`; only which way the merc is drawn
	# facing while it happens is adjusted.
	await face_toward(_grenade_face_position(target))
	await visual.play_action(UnitVisual.GRENADE)
	var vfx := get_tree().get_first_node_in_group("vfx")
	if vfx and not is_instant():
		vfx.impact(GridManager.grid_to_world(target) + Vector3(0, 0.9, 0), true)
	# An explosion is loud, and the robots' sound channel is the one thing about
	# them a grenade does NOT bypass: throwing it announces where you are.
	SecurityNetwork.report_noise(target, self)
	match type:
		GrenadeType.EMP: _resolve_emp_throw(target)
		GrenadeType.FRAG: _resolve_frag_throw(target)
	_check_activation_end()


func _resolve_emp_throw(target: Vector3i) -> void:
	action_logged.emit("%s throws an EMP grenade at %s" % [stats.display_name, target])
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


## Ordinary AoE damage, plus Sec 6.1.1's cover-breaker bonus. Unlike EMP this
## does not discriminate by faction or by unit type — an explosive in a 3x3
## does not check whose side you are on — so a soldier who throws this into
## melee range with an ally standing in it catches them too.
func _resolve_frag_throw(target: Vector3i) -> void:
	action_logged.emit("%s throws a frag grenade at %s" % [stats.display_name, target])
	var caught := 0
	for tile in _blast_tiles(target):
		var t: GridTileData = GridManager.get_tile(tile)
		if t == null:
			continue
		var victim := t.occupant as Unit
		if victim == null or victim.is_downed:
			continue
		var dealt := victim.take_damage(FRAG_DAMAGE)
		action_logged.emit("%s takes %d damage from the blast" % [victim.stats.display_name, dealt])
		# Same edge-lookup a shot uses (Combat.defending_cover), just centred on
		# the blast rather than on a shooter — whichever side of the victim's
		# tile faces the explosion is the side that eats the cover-breaker bonus.
		var defence := Combat.defending_cover(target, victim.grid_pos)
		if defence[0] != MapData.Cover.NONE:
			GridManager.damage_cover_edge(victim.grid_pos, defence[1], FRAG_DAMAGE)
		caught += 1
		if victim.is_downed:
			action_logged.emit("%s is DOWN!" % victim.stats.display_name)
	if caught == 0:
		action_logged.emit("The frag grenade catches nothing")


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("select_unit"):
		return
	if not _accepting_input():
		print("[NET] %s ignored a click: active_unit=%s is_downed=%s is_busy=%s owned_locally=%s" % [
			stats.display_name,
			TurnManager.active_unit.stats.display_name if TurnManager.active_unit else "null",
			is_downed, is_busy, is_owned_by_local_player()])
		return
	# Handled BEFORE the raycast, and that is the fix: a move click used to need
	# the ray to land on something, then took the tile it landed on. A wall in the
	# way therefore resolved to the wall's own tile — never a legal destination —
	# so the click did nothing at all. Projection needs no hit.
	if mode == Mode.MOVE:
		_issue(&"_try_move", [_tile_under_mouse()])
		return
	if mode in [Mode.SHOOT, Mode.AIMED_SHOT, Mode.SUPPRESS]:
		# Layer 2 (units) only, same reasoning as `_update_target_hover`: a wall
		# with its mesh hidden but its collider still live must not eat a click
		# on the hostile standing behind it.
		var unit_hit := _raycast_mouse(2)
		if unit_hit.is_empty():
			return
		var unit := _unit_from_collider(unit_hit["collider"])
		if unit and is_hostile_to(unit):
			# Called directly rather than via `_issue`: Aimed Shot's branch below
			# only opens a local zone menu (see `aimed_shot_target_picked`) and
			# must run on THIS peer, not get routed to the host. The branches
			# that actually mutate shared state (fire, suppress) issue their own
			# requests — see `_try_shoot`/`_try_suppress` below.
			_try_shoot(unit)
		return
	var hit := _raycast_mouse()
	if hit.is_empty():
		return
	if mode == Mode.GRENADE:
		# Ahead of the unit lookup, like FACE: landing it on the machine itself is
		# the normal way to use this. Local, not `_issue` — same reasoning as the
		# AIMED_SHOT branch above: this only opens a menu, it doesn't throw yet.
		_try_pick_grenade_target(_tile_under_mouse_any())
		return
	if mode == Mode.FACE:
		# Deliberately ahead of the unit lookup: aiming the beam *at* something is
		# the main reason to use this, so clicking an alien has to be allowed.
		_issue(&"_try_face", [hit["position"]])


## Every method a click or HUD button can trigger on this unit. `_rpc_command`
## dispatches by NAME (see below), so this allowlist is what stops a peer
## sending an arbitrary method name and getting it `callv`'d.
const _COMMANDS := [
	"_try_move", "_do_shoot", "_try_suppress", "_try_throw_grenade", "_try_face",
	"try_hunker", "try_overwatch", "try_reload", "try_toggle_flashlight", "fire_aimed_shot",
]


## Every player command funnels through here instead of being called directly,
## so that in co-op a client's own click sends the request to the HOST's copy
## of this same unit — the one Combat/GridManager/RNG actually simulate —
## rather than mutating a copy nobody else will ever see. Single-player, and
## the host acting on its own units, skip the round trip and just run it.
func _issue(method: StringName, args: Array = []) -> void:
	if not multiplayer.has_multiplayer_peer() or multiplayer.is_server():
		print("[NET] %s running '%s' locally (server=%s)" % [stats.display_name, method, multiplayer.has_multiplayer_peer() and multiplayer.is_server()])
		await callv(method, args)  # `await` is a no-op if the callee isn't a coroutine
	else:
		print("[NET] %s sending '%s' to host (owner_peer_id=%d, local_id=%d)" % [
			stats.display_name, method, owner_peer_id, multiplayer.get_unique_id()])
		_rpc_command.rpc_id(1, method, args)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_command(method: StringName, args: Array) -> void:
	print("[NET] host received '%s' for %s from peer %d" % [method, stats.display_name, multiplayer.get_remote_sender_id()])
	if not multiplayer.is_server():
		print("[NET] ...but this peer isn't the server — dropped")
		return
	if method not in _COMMANDS:
		push_warning("%s: rejected unknown command '%s'" % [stats.display_name, method])
		return
	var sender := multiplayer.get_remote_sender_id()
	if owner_peer_id != 0 and sender != owner_peer_id:
		push_warning("%s: rejected '%s' from peer %d (owned by %d)" % [
			stats.display_name, method, sender, owner_peer_id])
		return
	if TurnManager.active_unit != self:
		push_warning("%s: rejected '%s' — not this unit's activation (active_unit=%s)" % [
			stats.display_name, method, TurnManager.active_unit.stats.display_name if TurnManager.active_unit else "null"])
		return
	print("[NET] host executing '%s' for %s" % [method, stats.display_name])
	callv(method, args)


func _accepting_input() -> bool:
	# `is_owned_by_local_player` is a no-op true in single-player (see Unit) —
	# this is the entire client-side enforcement that a co-op squadmate can't
	# drive your mercs: their copy of this same node just never accepts input.
	return TurnManager.active_unit == self and not is_downed and not is_busy \
			and is_owned_by_local_player()


func _raycast_mouse(mask: int = 1 | 2) -> Dictionary:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return {}
	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	var from := camera.project_ray_origin(mouse_pos)
	var to := from + camera.project_ray_normal(mouse_pos) * 500.0
	var query := PhysicsRayQueryParameters3D.create(from, to, mask)
	return get_world_3d().direct_space_state.intersect_ray(query)


## The tile the cursor is over, found by projection rather than by raycast — so
## a wall between the camera and the tile no longer eats the pick. See
## GridManager.tile_under_ray.
##
## The old version also returned NO_TILE whenever a unit was under the cursor, to
## clear the preview. That rule is now redundant rather than dropped: a tile with
## somebody standing on it is not in `_move_costs` (the flood excludes occupied
## tiles), so `_cost_for` answers 0 and the preview clears for exactly the same
## reason it did before.
func _tile_under_mouse() -> Vector3i:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return NO_TILE
	var mouse := get_viewport().get_mouse_position()
	var tile := GridManager.tile_under_ray(
		camera.project_ray_origin(mouse), camera.project_ray_normal(mouse))
	return tile if GridManager.has_tile(tile) else NO_TILE


func _unit_from_collider(collider: Object) -> Unit:
	var node := collider as Node
	while node:
		if node is Unit:
			return node
		node = node.get_parent()
	return null


## Recomputes the path fresh rather than trusting `_preview_path`/`_move_costs`
## (see `_cost_for`): those are the CLICKING peer's cached UI state, but in
## co-op this runs on the host's copy of the unit, whose own cache was never
## populated for a squadmate's merc. A pathfind per click is cheap enough that
## there's no reason to keep the cache-dependent fast path around at all.
func _try_move(target: Vector3i) -> void:
	var path := GridManager.find_path(grid_pos, target, move_tiles_affordable())
	if path.is_empty() or path[-1] != target:
		return
	var cost := move_cost_for(path.size())
	if ap < cost:
		return
	spend_ap(cost)  # before the walk, so the HUD greys the buttons immediately
	set_mode(Mode.NONE)
	await move_along(path)
	action_logged.emit("%s moved to %s (%d tiles, %d AP)" % [
		stats.display_name, target, path.size(), cost])
	_check_activation_end()


## Called directly (not via `_issue`) — the AIMED_SHOT branch only opens a
## local zone menu and has to run on the clicking peer, not the host. The two
## branches that actually mutate shared state issue their own requests.
func _try_shoot(target: Unit) -> void:
	if mode == Mode.SUPPRESS:
		_issue(&"_try_suppress", [target])
		return
	if mode == Mode.AIMED_SHOT:
		# Doesn't fire yet — Aimed Shot needs a zone first. The HUD listens for
		# this and opens the VATS-style menu; `fire_aimed_shot` below finishes
		# the job once the player picks one. Gated on the CHEAPEST zone, since
		# which one is being paid for is exactly what that menu is for. Purely
		# a read of locally-mirrored state to decide whether to open the menu —
		# `fire_aimed_shot` re-validates for real once a zone is picked.
		if ap < min_aimed_shot_cost() or not can_shoot():
			return
		if not GridManager.has_line_of_sight(self, target):
			action_logged.emit("%s: no line of sight to %s" % [stats.display_name, target.stats.display_name])
			return
		aimed_shot_target_picked.emit(target)
		return
	_issue(&"_do_shoot", [target])


func _do_shoot(target: Unit) -> void:
	var cost := action_cost(UnitStats.Action.SHOOT)
	if ap < cost or not can_shoot():
		return
	if not GridManager.has_line_of_sight(self, target):
		action_logged.emit("%s: no line of sight to %s" % [stats.display_name, target.stats.display_name])
		return
	spend_ap(cost)
	var result: Combat.ShotResult = await fire_at(target, Combat.ShotAction.SHOOT)
	action_logged.emit("%s fired at %s (%d%% acc): %s" % [stats.display_name, target.stats.display_name, result.accuracy, Combat.describe(result)])
	_log_shot_aftermath(target, result)
	set_mode(Mode.NONE)
	_check_activation_end()


func fire_aimed_shot(target: Unit, body_part: int) -> void:
	# Called by the HUD once the player picks a zone from the VATS-style menu
	# opened after `aimed_shot_target_picked`. Re-validates everything, since
	# AP/LOS/ammo could all have changed while that menu was up — and the price
	# is per zone (Sec 4.3a), so the zone picked is what decides affordability,
	# not the Torso baseline `_try_shoot` gated on.
	var cost := aimed_shot_cost(body_part)
	if ap < cost or not can_shoot() or target.is_downed:
		return
	if not GridManager.has_line_of_sight(self, target):
		action_logged.emit("%s: no line of sight to %s" % [stats.display_name, target.stats.display_name])
		return
	spend_ap(cost)
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


## Pins `target` under covering fire. Ends the activation, like Hunker and
## Overwatch — see Unit.do_suppress.
func _try_suppress(target: Unit) -> void:
	var cost := action_cost(UnitStats.Action.SUPPRESS)
	if ap < cost or not can_suppress() or target.is_downed or is_busy:
		return
	if not GridManager.has_line_of_sight(self, target):
		action_logged.emit("%s: no line of sight to %s" % [stats.display_name, target.stats.display_name])
		return
	set_mode(Mode.NONE)
	await do_suppress(target)
	action_logged.emit("%s lays down suppressing fire on %s (%d rounds)" % [
		stats.display_name, target.stats.display_name, Unit.SUPPRESS_AMMO_COST])
	_check_activation_end()


func try_hunker() -> void:
	if ap < action_cost(UnitStats.Action.HUNKER) or is_busy:
		return
	# No spend_ap here: hunkering ends the activation, and do_hunker burns the
	# whole remaining AP itself so the AI cannot take the pose more cheaply than
	# the player does. See Unit._end_activation_ap.
	do_hunker()
	set_mode(Mode.NONE)
	action_logged.emit("%s hunkered down" % stats.display_name)
	_check_activation_end()


func try_overwatch() -> void:
	var cost := action_cost(UnitStats.Action.OVERWATCH)
	if ap < cost or is_busy or not can_shoot():
		return
	do_overwatch()  # pays the fixed cost, then burns any remainder — see try_hunker above
	set_mode(Mode.NONE)
	action_logged.emit("%s is on overwatch (%d AP reserved)" % [
		stats.display_name, overwatch_reserve])
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
	var cost := action_cost(UnitStats.Action.RELOAD)
	if ap < cost or is_busy or not can_reload():
		return
	spend_ap(cost)  # before the animation, so the HUD greys the buttons immediately
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
