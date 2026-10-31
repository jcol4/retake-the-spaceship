class_name PlayerUnit
extends Unit
## Input handling while this unit is the active (pool-drawn) unit.
## The HUD sets `pending_action`; clicks in the world resolve it.

## REVIVE and PICK_UP (extraction plan 2.6) are target modes over BODIES: the
## next click picks a downed or dead squadmate within reach, rather than a hostile
## or a tile. Appended, so no existing value moves.
enum Mode { NONE, MOVE, SHOOT, AIMED_SHOT, SUPPRESS, FACE, GRENADE, REVIVE, PICK_UP }

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
## The host refused a command this peer sent (`_reject`). The HUD says why; the
## one thing a click can run into that it could not have seen (plan C.2).
signal command_rejected(reason: String)

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
## Campaign (extraction plan 4.2): the SoldierRecord this soldier was spawned from
## ("" for a soldier spawned outside a campaign — tests, the screenshot tool). Set
## by main.gd before add_child on every peer; the debrief maps units back to the
## roster through it.
var record_id: String = ""
## The grenades drawn from the campaign stock for this mission (CampaignEconomy:
## grenades are stocked gear, allotted per soldier in the hub). Kept apart from
## `grenade_charges`, which counts down as they are thrown, so the debrief can tell
## "thrown" from "brought home".
var deployed_grenades: int = 1
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
## How long a walk may be out of combat: more than any deck, since a walk's price
## is time rather than a budget (plan B.5).
const EXPLORE_PATH_CAP := 999
var _loadout_weapon_id: int = -1  # host's record of the deployed pick; see show_to_peer
var _loadout_attachment_ids := PackedInt32Array()  # ...and the attachments fitted to it
var _loadout_ammo_id: int = -1  # ...and the ammo loaded in it


func _init() -> void:
	faction = Faction.Id.CONTRACTORS
	# GDD §4.4: the squad's soldiers are the only units with a downed state —
	# everything else dies outright at 0 HP.
	can_be_downed = true


## The one override of Unit._is_player_unit — what `is_player_controlled` means.
func _is_player_unit() -> bool:
	return true


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
	# Every soldier deploys with the sidearm (extraction plan 2.5): equipped gear,
	# no inventory slot, holstered — its rounds sit in `stowed_ammo`/`_reserve`
	# until a carry draws it. Built on every peer: it is fixed gear, so nothing
	# about it needs to cross the wire beyond the replicated round counts.
	if stats.sidearm == null:
		stats.sidearm = WeaponPresets.make_sidearm()
	stowed_ammo = stats.sidearm.effective_mag_size()
	stowed_reserve = stats.sidearm.effective_reserve()
	stowed_reserve_mags = stats.sidearm.packed_mags(stowed_reserve)
	# Host-side changes arrive through these; a client's through _on_replicated.
	for changed: Signal in [hp_changed, downed, died, revived, ammo_changed]:
		changed.connect(_refresh_status_lights.unbind(1))
	_refresh_status_lights()
	TurnManager.mode_changed.connect(_on_mode_changed)
	TurnManager.unit_selected.connect(_on_unit_selected)


## Armed modes do not survive a change of loop: exploration's soldier arms Move by
## itself, and turn mode's waits for a button.
func _on_mode_changed(_new_mode: int) -> void:
	set_mode(Mode.NONE)


## Exploration (plan A.6): the soldier this peer just selected arms Move, and the
## one it left drops whatever it had armed.
func _on_unit_selected(unit: Unit) -> void:
	if unit == self or mode != Mode.NONE:
		set_mode(Mode.NONE)


func _on_replicated() -> void:
	super()
	_refresh_status_lights()


## The suit's status lights (UnitVisual.set_status_lights): the HP bracket on the
## back, the downs taken on the chest, and the primary's magazine and spare mags.
## Squad soldiers only — the rival crew wears the same suit, with them dark.
func _refresh_status_lights() -> void:
	var drawn := stats.sidearm_drawn
	var mag_size := maxi(1, stats.weapon.effective_mag_size()) if stats.weapon else 1
	var rounds := stowed_ammo if drawn else ammo
	var spare_rounds := stowed_reserve if drawn else reserve
	var spare_mags := stowed_reserve_mags if drawn else reserve_mags
	visual.set_status_lights(float(current_hp) / maxi(1, stats.max_hp()), down_count,
		life_state == LifeState.DOWNED, life_state == LifeState.DEAD,
		float(rounds) / mag_size, _spare_mag_fractions(spare_rounds, spare_mags, mag_size))


## How full each spare magazine is, fullest first, for the pips. A reserve that is
## not magazines reads as if it were: loose shells as reloads' worth, the last one
## part full, and an unlimited reserve as every pip full.
func _spare_mag_fractions(spare_rounds: int, spare_mags: PackedInt32Array, mag_size: int) -> Array:
	var fractions := []
	if spare_rounds < 0:
		fractions.resize(UnitVisual.MAG_PIP_NODES.size())
		fractions.fill(1.0)
	elif spare_mags.is_empty():
		for i in ceili(float(spare_rounds) / mag_size):
			fractions.append(minf(float(spare_rounds - i * mag_size) / mag_size, 1.0))
	else:
		for mag in spare_mags:
			fractions.append(float(mag) / mag_size)
	return fractions


func set_mode(new_mode: Mode) -> void:
	var exploring := TurnManager.in_exploration()
	# Out of combat a walking soldier can be re-ordered (E9), so disarming and Move
	# stay open mid-walk; anything else still waits for the action on screen.
	if is_busy and not (exploring and new_mode in [Mode.NONE, Mode.MOVE]):
		return
	# Nothing is ever "unarmed" for the soldier selected out of combat: a click on
	# the deck is a walk there (plan B.5).
	var selected := TurnManager.active_unit == self
	if exploring and selected and new_mode == Mode.NONE and is_owned_by_local_player():
		new_mode = Mode.MOVE
	mode = new_mode
	_hover_tile = NO_TILE
	_preview_path = []
	_preview_cost = 0
	_move_costs = {}
	_throw_tiles = []
	# Only the soldier this peer has selected owns the overlay. Out of combat two
	# soldiers run commands at once, and a co-op partner's walk on the host's copy
	# must not wipe the preview the host is looking at. In turn mode the only
	# soldier running a command is the drawn one.
	var highlights: Node = get_tree().get_first_node_in_group("highlights") if selected else null
	if highlights:
		highlights.clear_highlights()
	match mode:
		Mode.MOVE:
			# No area overlay out of combat (E13): a walk has no budget to show the
			# edge of, only a path to the cursor with its step and round cost.
			if not exploring:
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
		Mode.REVIVE, Mode.PICK_UP:
			# The bodies the click could land on, marked like targets. No hover
			# label: there is no hit chance to show, and the button already says
			# the price.
			if highlights:
				var tiles: Array[Vector3i] = []
				var blanks: Array[int] = []
				for body in body_targets(mode):
					if not tiles.has(body.grid_pos):
						tiles.append(body.grid_pos)
						blanks.append(0)
				highlights.show_targets(tiles, blanks)
	set_process(mode != Mode.NONE)


## The bodies a REVIVE or PICK_UP click could pick right now: every unit the
## matching rule (`revive_blocker` / `pick_up_blocker`) accepts. Any owner's —
## cross-player rescue is the rule (GDD §7.6). The HUD also uses this to decide
## whether the two buttons are worth showing.
func body_targets(for_mode: Mode) -> Array[Unit]:
	var out: Array[Unit] = []
	for node in get_tree().get_nodes_in_group("units"):
		var body := node as Unit
		if body == null or body.life_state == LifeState.ACTIVE:
			continue
		var why := revive_blocker(body) if for_mode == Mode.REVIVE else pick_up_blocker(body)
		if why == "":
			out.append(body)
	return out


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
	if TurnManager.in_exploration():
		_preview_cost = 0
		if tile != NO_TILE and _can_enter(tile) and GridManager.open_destination(tile, self):
			_preview_path = GridManager.find_path(grid_pos, tile, EXPLORE_PATH_CAP)
			_preview_cost = _preview_path.size() * move_ap_per_tile()
		highlights.show_explore_path(_preview_path, _preview_cost,
			ExplorationRules.rounds_passed(TurnManager.steps, _preview_cost))
		return
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
	if not can_afford(action_cost(UnitStats.Action.GRENADE)) or grenade_charges <= 0 or is_busy:
		return
	if not _can_throw_grenade_at(target):
		action_logged.emit("%s: no throwing line to %s" % [stats.display_name, target])
		return
	grenade_target_picked.emit(target)


func _try_throw_grenade(target: Vector3i, type: GrenadeType) -> void:
	var cost := action_cost(UnitStats.Action.GRENADE)
	if not can_afford(cost) or grenade_charges <= 0 or is_busy:
		return
	# Re-validated live (see `_can_throw_grenade_at`) rather than against the
	# cached overlay: this may be running on the host's copy of the unit, not
	# the clicking peer's, so the local `_throw_tiles` cache can't be trusted.
	if not _can_throw_grenade_at(target):
		action_logged.emit("%s: no throwing line to %s" % [stats.display_name, target])
		return
	grenade_charges -= 1
	_pay_attack(cost)
	set_mode(Mode.NONE)
	# Faces short of the target on purpose — see GRENADE_RELEASE_OFFSET. The
	# flash still lands exactly on `target`; only which way the merc is drawn
	# facing while it happens is adjusted.
	await face_toward(_grenade_face_position(target))
	# Busy for the throw, so a switch to turn mode (which this throw has just
	# asked for) waits for the blast rather than drawing over it.
	is_busy = true
	await visual.play_action(UnitVisual.GRENADE)
	is_busy = false
	show_impact(GridManager.grid_to_world(target) + Vector3(0, 0.9, 0), true)
	# An explosion is loud, and the robots' sound channel is the one thing about
	# them a grenade does NOT bypass: throwing it announces where you are.
	SecurityNetwork.report_noise(target, self)
	match type:
		GrenadeType.EMP: _resolve_emp_throw(target)
		GrenadeType.FRAG: _resolve_frag_throw(target)
	await _check_activation_end()


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
	var downed_by_blast: Array[Unit] = []
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
			downed_by_blast.append(victim)
			action_logged.emit("%s is DOWN!" % victim.stats.display_name)
	# GDD §4.4: "Stray area damage (grenades) hits downed soldiers regardless." A
	# body holds no tile, so `occupant` above never finds one — they are looked up
	# per tile instead, carried ones included (a blast does not care whose
	# shoulder they are on). Snapshotted first so a soldier who went down to THIS
	# blast above is not hit a second time as a body. Corpses take nothing.
	for tile in _blast_tiles(target):
		for body in bodies_on(tile, true):
			if body.life_state != LifeState.DOWNED or body in downed_by_blast:
				continue
			var dealt := body.take_damage(FRAG_DAMAGE)
			caught += 1
			action_logged.emit("%s takes %d to the downed bar from the blast%s" % [
				body.stats.display_name, dealt,
				" — and is DEAD" if body.life_state == LifeState.DEAD else ""])
	if caught == 0:
		action_logged.emit("The frag grenade catches nothing")


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("select_unit"):
		return
	if _click_selects():
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
	if mode in [Mode.REVIVE, Mode.PICK_UP]:
		# Ahead of the general raycast, which needs SOMETHING under the cursor:
		# a body's own collider (layer 2, units only, like Shoot's pick), else
		# whatever body is on the tile the cursor projects to — bodies hold no
		# tile, so a soldier standing over one would otherwise hide it.
		var body := _body_under_mouse()
		if body != null:
			_issue(&"try_revive" if mode == Mode.REVIVE else &"try_pick_up", [body])
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


## Out of combat a click on another of this player's soldiers selects them rather
## than ordering this one (plan B.11). Asked only of the current selection, so one
## click is one answer, and even mid-walk. Target modes keep the click: they may
## mean a body or a hostile, and a squadmate is not what they are aiming at.
func _click_selects() -> bool:
	if not TurnManager.in_exploration() or TurnManager.active_unit != self:
		return false
	if mode != Mode.MOVE and mode != Mode.NONE:
		return false
	var hit := _raycast_mouse(2)
	if hit.is_empty():
		return false
	var unit := _unit_from_collider(hit["collider"])
	if unit == null or unit == self or not unit.is_player_controlled \
			or not unit.is_owned_by_local_player() or unit.is_downed:
		return false
	TurnManager.select(unit)
	get_viewport().set_input_as_handled()
	return true


## Every method a click or HUD button can trigger on this unit. `_rpc_command`
## dispatches by NAME (see below), so this allowlist is what stops a peer
## sending an arbitrary method name and getting it `callv`'d.
const _COMMANDS := [
	"_try_move", "_do_shoot", "_try_suppress", "_try_throw_grenade", "_try_face",
	"try_hunker", "try_overwatch", "try_reload", "try_toggle_flashlight", "fire_aimed_shot",
	"try_call_ship", "try_board_ship", "try_extract", "try_switch_weapon",
	"try_revive", "try_pick_up", "try_drop",
	"try_loot", "try_drop_item",
	"try_operate_terminal",
	"try_wait",
]


## Every player command funnels through here instead of being called directly,
## so that in co-op a client's own click sends the request to the HOST's copy
## of this same unit — the one Combat/GridManager/RNG actually simulate —
## rather than mutating a copy nobody else will ever see. Single-player, and
## the host acting on its own units, skip the round trip and just run it.
func _issue(method: StringName, args: Array = []) -> void:
	# The one gate a host's own click passes through, where a client's is
	# `_rpc_command`. Turn mode needs none: the HUD only drives the drawn unit.
	if TurnManager.in_exploration() and multiplayer.is_server() \
			and TurnManager.may_act(self, _local_peer(), method) != "":
		return
	if not multiplayer.has_multiplayer_peer() or multiplayer.is_server():
		print("[NET] %s running '%s' locally (server=%s)" % [stats.display_name, method, multiplayer.has_multiplayer_peer() and multiplayer.is_server()])
		await callv(method, args)  # `await` is a no-op if the callee isn't a coroutine
	else:
		print("[NET] %s sending '%s' to host (owner_peer_id=%d, local_id=%d)" % [
			stats.display_name, method, owner_peer_id, multiplayer.get_unique_id()])
		# A Node can't cross the wire — it arrives as an EncodedObjectAsID
		# holding THIS peer's instance id, which means nothing on the host and
		# fails the typed `target: Unit` parameter outright. Send its path
		# instead; unit names are fixed at spawn (main.gd), so it resolves to
		# the same unit on the host.
		var wire_args := args.map(func(a: Variant) -> Variant: return a.get_path() if a is Node else a)
		_rpc_command.rpc_id(1, method, wire_args)


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
	var why := TurnManager.may_act(self, sender, method)
	if why != "":
		push_warning("%s: rejected '%s' from peer %d — %s" % [
			stats.display_name, method, sender, why])
		return
	# Undo `_issue`'s Node -> NodePath encoding. No command takes a real
	# NodePath argument, so every one of these is a unit reference.
	var resolved: Array = []
	for arg: Variant in args:
		if arg is NodePath:
			var node := get_tree().root.get_node_or_null(arg)
			if node == null:
				push_warning("%s: rejected '%s' — no node at %s" % [stats.display_name, method, arg])
				return
			resolved.append(node)
		else:
			resolved.append(arg)
	print("[NET] host executing '%s' for %s" % [method, stats.display_name])
	callv(method, resolved)


## Pre-mission weapon and attachment pick (LoadoutMenu). `attachment_ids` is
## AttachmentPresets ids, -1 for an empty slot; `ammo_id` an AmmoPresets id, -1
## for Standard. Lives on the unit rather than the
## menu because an RPC is addressed by node path: the menu is a nameless
## overlay that gets an engine-generated name — different on each peer — and is
## freed the moment its peer hits Deploy, so the host's copy is usually gone
## by the time a client's pick arrives.
func choose_loadout(weapon_id: int, attachment_ids := PackedInt32Array(), ammo_id := -1) -> void:
	if not multiplayer.has_multiplayer_peer() or multiplayer.is_server():
		_apply_loadout(weapon_id, attachment_ids, ammo_id)
	else:
		_rpc_request_loadout.rpc_id(1, weapon_id, attachment_ids, ammo_id)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_loadout(weapon_id: int, attachment_ids: PackedInt32Array, ammo_id: int) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if owner_peer_id != 0 and sender != owner_peer_id:
		push_warning("%s: rejected loadout pick from peer %d (owned by %d)" % [
			stats.display_name, sender, owner_peer_id])
		return
	_apply_loadout(weapon_id, attachment_ids, ammo_id)


## `stats.weapon` isn't a synchronized property (ammo/reserve are), so the host
## pushes the pick back out explicitly — otherwise every client keeps showing
## the class default: wrong name, wrong accuracy preview, wrong range.
func _apply_loadout(weapon_id: int, attachment_ids: PackedInt32Array, ammo_id: int) -> void:
	_loadout_weapon_id = weapon_id
	_loadout_attachment_ids = attachment_ids
	_loadout_ammo_id = ammo_id
	_equip(weapon_id, attachment_ids, ammo_id)
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		_rpc_sync_loadout.rpc(weapon_id, attachment_ids, ammo_id)


## Swaps in the weapon and refills to ITS magazine and reserve — the attachments
## are already counted, so an Extended Mag deploys full.
func _equip(weapon_id: int, attachment_ids: PackedInt32Array, ammo_id: int) -> void:
	stats.weapon = WeaponPresets.make(weapon_id, attachment_ids, ammo_id)
	ammo = stats.mag_size
	reserve = stats.weapon.effective_reserve()
	# Dealt here too: a new gun can carry the same total in a different mag size,
	# which `reserve` alone would see as no change.
	reserve_mags = stats.weapon.packed_mags(reserve)
	sync_gun_model()


## The host can deploy before a client has even built this unit, and the
## broadcast in `_apply_loadout` is lost if so — replay it when that client
## reports ready.
func show_to_peer(peer_id: int) -> void:
	super(peer_id)
	if _loadout_weapon_id >= 0:
		_rpc_sync_loadout.rpc_id(peer_id, _loadout_weapon_id, _loadout_attachment_ids, _loadout_ammo_id)


@rpc("authority", "call_remote", "reliable")
func _rpc_sync_loadout(weapon_id: int, attachment_ids: PackedInt32Array, ammo_id: int) -> void:
	_equip(weapon_id, attachment_ids, ammo_id)


func _accepting_input() -> bool:
	# `is_owned_by_local_player` is a no-op true in single-player (see Unit) —
	# this is the entire client-side enforcement that a co-op squadmate can't
	# drive your mercs: their copy of this same node just never accepts input.
	#
	# `active_unit` means "drawn" in turn mode and "this peer's selection" out of
	# combat, and either way is what stops every soldier answering one click.
	if TurnManager.active_unit != self or is_downed or not is_owned_by_local_player():
		return false
	if TurnManager.in_exploration():
		return TurnManager.may_act(self, _local_peer(), &"_try_move" if mode == Mode.MOVE else &"") == ""
	return not is_busy


## This peer's id as `TurnManager.may_act` reads it.
func _local_peer() -> int:
	return multiplayer.get_unique_id() if multiplayer.has_multiplayer_peer() else owner_peer_id


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
	if TurnManager.in_exploration():
		await _explore_move(target)
		return
	var path := GridManager.find_path(grid_pos, target, move_tiles_affordable())
	if path.is_empty() or path[-1] != target:
		return
	var cost := move_cost_for(path.size())
	if not can_afford(cost):
		return
	pay(cost)  # before the walk, so the HUD greys the buttons immediately
	set_mode(Mode.NONE)
	await move_along(path)
	action_logged.emit("%s moved to %s (%d tiles, %d AP)" % [
		stats.display_name, target, path.size(), cost])
	await _check_activation_end()


## A move out of combat (plan B.5): no budget, no AP, and the steps are paid per
## tile inside the walk (TurnManager.after_step) rather than up front. The goal is
## reserved at click time, so a second walker can never be sent to the same square
## (E4, E15). A new order on a walking soldier takes effect at the next tile (E9).
func _explore_move(target: Vector3i) -> void:
	if target == NO_TILE or not _can_enter(target):
		return
	if not GridManager.reserve(target, self):
		_reject("tile taken")
		return
	if is_walking():
		redirect_walk(target)
		return
	var path := GridManager.find_path(grid_pos, target, EXPLORE_PATH_CAP)
	if path.is_empty():
		GridManager.release_reservation(self)
		return
	set_mode(Mode.NONE)
	await move_along(path)
	# Re-armed, because any preview still up is priced from where the walk began.
	set_mode(Mode.NONE)
	action_logged.emit("%s moved to %s" % [stats.display_name, grid_pos])
	await _check_activation_end()


## Tells the peer that sent a command the host refused it, and why (plan C.2). A
## plain signal when that peer is this one. Generic on purpose: any command the
## host turns down for a reason the click could not have known can use it.
func _reject(reason: String) -> void:
	if owner_peer_id != 0 and owner_peer_id != _local_peer() \
			and owner_peer_id in multiplayer.get_peers():
		_rpc_command_rejected.rpc_id(owner_peer_id, reason)
	else:
		command_rejected.emit(reason)


@rpc("authority", "call_remote", "reliable")
func _rpc_command_rejected(reason: String) -> void:
	command_rejected.emit(reason)


## Wait (plan B.10): the round passes now, for everybody. On a soldier only so it
## can ride the `_issue` -> `_rpc_command` path — it is not this soldier acting, so
## it goes straight to the clock rather than through `pay`, and an overwatch held
## survives it (E26). That is what lets a squad sit in an ambush.
func try_wait() -> void:
	await TurnManager.wait_round()


## Pays for an attack. Out of combat the price is not steps: the attack starts the
## fight (plan B.7), and it comes out of this soldier's first activation (E8). An
## attack is also acting, so it lets go of any overwatch held (B.8).
func _pay_attack(cost: int) -> void:
	if _on_the_clock():
		stand_down()
		TurnManager.notify_attack(self, cost)
		return
	spend_ap(cost)


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
		if not can_afford(min_aimed_shot_cost()) or not can_shoot():
			return
		if not GridManager.has_line_of_sight(self, target):
			action_logged.emit("%s: no line of sight to %s" % [stats.display_name, target.stats.display_name])
			return
		aimed_shot_target_picked.emit(target)
		return
	_issue(&"_do_shoot", [target])


func _do_shoot(target: Unit) -> void:
	var cost := action_cost(UnitStats.Action.SHOOT)
	if not can_afford(cost) or not can_shoot():
		return
	if not GridManager.has_line_of_sight(self, target):
		action_logged.emit("%s: no line of sight to %s" % [stats.display_name, target.stats.display_name])
		return
	_pay_attack(cost)
	var result: Combat.ShotResult = await fire_at(target, Combat.ShotAction.SHOOT)
	action_logged.emit("%s fired at %s (%d%% acc): %s" % [stats.display_name, target.stats.display_name, result.accuracy, Combat.describe(result)])
	_log_shot_aftermath(target, result)
	set_mode(Mode.NONE)
	await _check_activation_end()


func fire_aimed_shot(target: Unit, body_part: int) -> void:
	# Called by the HUD once the player picks a zone from the VATS-style menu
	# opened after `aimed_shot_target_picked`. Re-validates everything, since
	# AP/LOS/ammo could all have changed while that menu was up — and the price
	# is per zone (Sec 4.3a), so the zone picked is what decides affordability,
	# not the Torso baseline `_try_shoot` gated on.
	var cost := aimed_shot_cost(body_part)
	if not can_afford(cost) or not can_shoot() or target.is_downed:
		return
	if not GridManager.has_line_of_sight(self, target):
		action_logged.emit("%s: no line of sight to %s" % [stats.display_name, target.stats.display_name])
		return
	_pay_attack(cost)
	var result: Combat.ShotResult = await fire_at(target, Combat.ShotAction.AIMED_SHOT, body_part)
	var zone_tag := " [%s]" % Combat.body_part_name(body_part)
	action_logged.emit("%s fired at %s%s (%d%% acc): %s" % [stats.display_name, target.stats.display_name, zone_tag, result.accuracy, Combat.describe(result)])
	if result.newly_injured:
		action_logged.emit("%s's %s is INJURED!" % [target.stats.display_name, Combat.body_part_name(body_part)])
	if result.stunned:
		action_logged.emit("%s is STUNNED!" % target.stats.display_name)
	_log_shot_aftermath(target, result)
	set_mode(Mode.NONE)
	await _check_activation_end()


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
	if not can_afford(cost) or not can_suppress() or target.is_downed or is_busy:
		return
	if not GridManager.has_line_of_sight(self, target):
		action_logged.emit("%s: no line of sight to %s" % [stats.display_name, target.stats.display_name])
		return
	set_mode(Mode.NONE)
	# An opening Suppress is the suppressor's whole first activation (E21).
	if _on_the_clock():
		stand_down()
		TurnManager.notify_attack(self, 0, true)
	await do_suppress(target)
	action_logged.emit("%s lays down suppressing fire on %s (%d rounds)" % [
		stats.display_name, target.stats.display_name, Unit.SUPPRESS_AMMO_COST])
	await _check_activation_end()


func try_hunker() -> void:
	# Unavailable out of combat (E21): it protects against nothing until a fight
	# starts, and the fight's own first draw is where it belongs.
	if TurnManager.in_exploration():
		return
	if not can_afford(action_cost(UnitStats.Action.HUNKER)) or is_busy:
		return
	# No spend_ap here: hunkering ends the activation, and do_hunker burns the
	# whole remaining AP itself so the AI cannot take the pose more cheaply than
	# the player does. See Unit._end_activation_ap.
	do_hunker()
	set_mode(Mode.NONE)
	action_logged.emit("%s hunkered down" % stats.display_name)
	await _check_activation_end()


func try_overwatch() -> void:
	var cost := action_cost(UnitStats.Action.OVERWATCH)
	if not can_afford(cost) or is_busy or not can_shoot():
		return
	do_overwatch()  # pays the fixed cost, then burns any remainder — see try_hunker above
	set_mode(Mode.NONE)
	action_logged.emit("%s is on overwatch (%d AP reserved)" % [
		stats.display_name, overwatch_reserve])
	await _check_activation_end()


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
	pay(0)  # free, but acting: out of combat that lets go of an overwatch (B.8)
	toggle_flashlight()
	action_logged.emit("%s switched their flashlight %s" % [stats.display_name, "on" if flashlight_on else "off"])


func try_reload() -> void:
	var cost := action_cost(UnitStats.Action.RELOAD)
	if not can_afford(cost) or is_busy or not can_reload():
		return
	pay(cost)  # before the animation, so the HUD greys the buttons immediately
	set_mode(Mode.NONE)
	await do_reload()
	action_logged.emit("%s reloaded" % stats.display_name)
	await _check_activation_end()


## Calls the ship to the hangar this soldier is standing in (GDD §7.3): 1 AP
## flat (UnitStats.FLAT_AP_COST), from anywhere in a discovered bay. Every rule —
## discovered, unclaimed, not cooling down, no other ship of ours inbound — is
## ExtractionManager's / ExtractionRules', asked here before anything is spent,
## so a refused call costs nothing. Either co-op player may make it: the crew is
## the whole squad (GDD §7.6), and `_rpc_command` only checks that the sender owns
## THIS soldier.
func try_call_ship() -> void:
	var cost := action_cost(UnitStats.Action.CALL_SHIP)
	if not can_afford(cost) or is_busy or is_downed:
		return
	if ExtractionManager.callable_hangar_for(self) < 0:
		action_logged.emit("%s: no hangar here to call the ship to" % stats.display_name)
		return
	pay(cost)
	set_mode(Mode.NONE)
	ExtractionManager.call_ship(self)
	action_logged.emit("%s calls in the ship (%d AP)" % [stats.display_name, cost])
	await _check_activation_end()


## Walks up the ramp of our landed ship from its square (GDD §7.4), with whatever
## body this soldier carries: 1 AP flat, and the soldier is OFF THE BOARD — safe,
## certain to leave with the ship — so the activation ends here. Does not end the
## mission (that is `try_extract`). Either co-op player's soldier may board.
func try_board_ship() -> void:
	var cost := action_cost(UnitStats.Action.BOARD_SHIP)
	if not can_afford(cost) or is_busy or is_downed:
		return
	if ExtractionManager.board_hangar_for(self) < 0:
		action_logged.emit("%s: no ship of ours to board from here" % stats.display_name)
		return
	pay(cost)
	set_mode(Mode.NONE)
	ExtractionManager.board(self)
	action_logged.emit("%s boards the ship (%d AP)" % [stats.display_name, cost])
	end_activation()
	await TurnManager.settle_clock()
	TurnManager.squad_changed()


## The word to the pilot (GDD §7.4): our ship leaves NOW with everyone aboard and
## everyone alive in its square, and the mission ends. 0 AP, from ANYWHERE — this
## soldier need not be in the square, so the one still holding the door can call
## it once the rest are in. Valid only with our own ship down and at least one of
## ours aboard or in the square (ExtractionRules.extract_blocker), so a squad can
## never leave on a rival's ship. Whoever is outside is left behind; the HUD asks
## first.
func try_extract() -> void:
	if is_busy or is_downed:
		return
	var why := ExtractionManager.extract_blocker(self)
	if why != "":
		action_logged.emit("%s: can't extract — %s" % [stats.display_name, why])
		return
	set_mode(Mode.NONE)
	action_logged.emit("%s gives the word: extract!" % stats.display_name)
	ExtractionManager.extract(self)


## Primary to pistol or back (GDD §4.3): 1 AP flat. Refused while carrying — the
## carrier's hands already decide (pistol) — and for anyone without a sidearm.
## Does not end the activation unless it spends the last point.
func try_switch_weapon() -> void:
	var cost := action_cost(UnitStats.Action.SWITCH_WEAPON)
	if not can_afford(cost) or is_busy or is_downed:
		return
	var why := switch_weapon_blocker()
	if why != "":
		action_logged.emit("%s: can't switch weapons — %s" % [stats.display_name, why])
		return
	pay(cost)
	set_mode(Mode.NONE)
	switch_weapon()
	action_logged.emit("%s switches to the %s (%d AP)" % [
		stats.display_name, stats.active_weapon().display_name if stats.active_weapon() else "weapon", cost])
	await _check_activation_end()


## The body a REVIVE / PICK_UP click means: the one whose collider the cursor is
## on, if it is a body this soldier could act on in the armed mode; else the
## first such body on the tile the cursor projects to. Null if neither.
func _body_under_mouse() -> Unit:
	var candidates := body_targets(mode)
	if candidates.is_empty():
		return null
	var hit := _raycast_mouse(2)
	if not hit.is_empty():
		var unit := _unit_from_collider(hit["collider"])
		if unit and unit in candidates:
			return unit
	var tile := _tile_under_mouse()
	for body in candidates:
		if body.grid_pos == tile:
			return body
	return null


# --- Downed squadmates (GDD §4.4, extraction plan 2.2–2.3) --------------------
#
# All three validate only THIS soldier — `_rpc_command` checks the sender owns
# it — and accept any contractor's body, whichever player owns it (GDD §7.6
# cross-player rescue). A revived soldier goes back to its own owner's control
# with nothing to do here: `owner_peer_id` was never touched.


## Revives `target` (3 AP flat). Every rule is `Unit.revive_blocker`'s, asked
## before anything is spent, so a refused revive costs nothing.
func try_revive(target: Unit) -> void:
	var cost := action_cost(UnitStats.Action.REVIVE)
	if not can_afford(cost) or is_busy or is_downed:
		return
	var why := revive_blocker(target)
	if why != "":
		action_logged.emit("%s: can't revive %s — %s" % [
			stats.display_name, target.stats.display_name if target else "that", why])
		return
	var tile := revive_tile_for(target)
	pay(cost)
	set_mode(Mode.NONE)
	await _kneel_over(target)
	target.revive_at(tile)
	action_logged.emit("%s revives %s (%d AP) — back up at %d HP, %d of %d downs used" % [
		stats.display_name, target.stats.display_name, cost, target.current_hp,
		target.down_count, MAX_DOWNS - 1])
	await _check_activation_end()


## Lifts `target` (2 AP flat): a downed squadmate or a corpse.
func try_pick_up(target: Unit) -> void:
	var cost := action_cost(UnitStats.Action.PICK_UP)
	if not can_afford(cost) or is_busy or is_downed:
		return
	var why := pick_up_blocker(target)
	if why != "":
		action_logged.emit("%s: can't pick up %s — %s" % [
			stats.display_name, target.stats.display_name if target else "that", why])
		return
	pay(cost)
	set_mode(Mode.NONE)
	await _kneel_over(target)
	pick_up(target)
	action_logged.emit("%s picks up %s%s (%d AP) — pistol drawn" % [
		stats.display_name, target.stats.display_name,
		"'s body" if target.life_state == LifeState.DEAD else "", cost])
	await _check_activation_end()


## Puts the carried body down on this tile. Free (GDD §4.4), and like the
## flashlight and dust-off it does not end the activation.
func try_drop() -> void:
	if is_busy or carrying == null:
		return
	pay(0)
	set_mode(Mode.NONE)
	var body := drop_carried()
	if body:
		action_logged.emit("%s puts %s down" % [stats.display_name, body.stats.display_name])


## Turns to the body and plays the interact one-shot (placeholder for revive and
## lift animations, extraction plan art list). Coroutine.
func _kneel_over(target: Unit) -> void:
	await _interact_at(target.grid_pos)


## The same one-shot aimed at a tile rather than a body: a crate, a pile.
func _interact_at(tile: Vector3i) -> void:
	if tile != grid_pos:
		await face_toward(GridManager.grid_to_world(tile))
	is_busy = true
	await visual.play_action(UnitVisual.INTERACT)
	is_busy = false


# --- Loot (GDD §7.5, extraction plan 3.2) ---------------------------------------
#
# Like revive and pick up, both validate only THIS soldier (`_rpc_command` checks
# the sender owns it) and accept any source whoever it belonged to — the other
# player's dead soldier included (GDD §7.6).


## A soldier's grenades are equipped gear (GDD §7.5): no slot while they fight,
## one GEAR item each once they are a corpse. They go to the corpse's pack, so the
## soldier has none left to throw — moot, but it keeps the gear in one place.
func _equipped_gear_items() -> Array[ItemData]:
	var out := super()
	for _i in grenade_charges:
		out.append(ItemPresets.make_grenade())
	grenade_charges = 0
	return out


## Every loot source THIS soldier could take from right now: containers and piles
## in reach (LootManager), and corpses in reach that have anything on them. In a
## stable order — containers by tile, then corpses by node name — so a panel index
## means the same thing on the clicking peer and on the host.
func loot_sources() -> Array:
	var out: Array = []
	if life_state != LifeState.ACTIVE:
		return out
	out.append_array(LootManager.sources_in_reach(self))
	var bodies: Array[Unit] = []
	for node in get_tree().get_nodes_in_group("units"):
		var body := node as Unit
		if body == null or body == self or body.loot_items().is_empty():
			continue
		if body.loot_blocker(self) == "":
			bodies.append(body)
	bodies.sort_custom(func(a: Unit, b: Unit) -> bool: return String(a.name) < String(b.name))
	out.append_array(bodies)
	return out


## Why THIS soldier cannot take item `index` from `source`, or "". Rules only; AP
## is the caller's.
func take_blocker(source: Object, index: int = 0) -> String:
	if source is Unit and source == self:
		return "that's your own pack"
	if life_state != LifeState.ACTIVE:
		return "not able"
	if source == null or not is_instance_valid(source) or not source.has_method("loot_take"):
		return "nothing to loot there"
	if source is Unit:
		var why: String = (source as Unit).loot_blocker(self)
		if why != "":
			return why
	elif not LootManager.in_reach(self, source):
		return "out of reach"
	var items: Array = source.loot_items()
	if index < 0 or index >= items.size():
		return "nothing there"
	if not has_free_slot():
		return "pack full (%d/%d)" % [inventory.size(), INVENTORY_SLOTS]
	return ""


## Takes item `index` from `source` (1 AP flat per item, extraction plan 3.2): a
## corpse, a container or a pile in reach, into a free slot. `expect_code`, when
## given, must match the item at `index` — a co-op client's panel names the item
## it saw, so a source that changed under the click takes nothing rather than the
## wrong thing. Every rule is asked before anything is spent.
func try_loot(source: Object, index: int, expect_code: String = "") -> void:
	var cost := action_cost(UnitStats.Action.LOOT)
	if not can_afford(cost) or is_busy or is_downed:
		return
	var why := take_blocker(source, index)
	if why == "" and expect_code != "" and source.loot_items()[index].code != expect_code:
		why = "it isn't there any more"
	if why != "":
		action_logged.emit("%s: can't loot — %s" % [stats.display_name, why])
		return
	pay(cost)
	set_mode(Mode.NONE)
	await _interact_at(source.loot_tile())
	var item: ItemData = LootManager.take(source, index)
	if item == null:
		return
	add_item(item)
	action_logged.emit("%s takes %s from %s (%d AP) — pack %d/%d" % [
		stats.display_name, item.display_name, source.loot_name(), cost,
		inventory.size(), INVENTORY_SLOTS])
	await _check_activation_end()


## Drops item `index` from the pack onto this tile, where it forms a lootable pile
## (plan A6). Free and does not end the activation, like putting down a body.
func try_drop_item(index: int) -> void:
	if is_busy or is_downed or index < 0 or index >= inventory.size():
		return
	pay(0)
	var item := remove_item(index)
	LootManager.drop_to_pile(grid_pos, item)
	action_logged.emit("%s drops %s" % [stats.display_name, item.display_name])


# --- Hold the terminal (GDD §7.5, extraction plan Phase 6) -------------------------


## Starts — or restarts, after it was left and paused — the Hold contract's console
## from beside it (OPERATE_TERMINAL, flat AP). Every rule is
## `ObjectiveManager.operate_blocker`'s, asked before anything is spent. Like the
## other interactions it validates only THIS soldier (`_rpc_command`), so either
## co-op player's soldier can start it, and holding it is anyone's (any soldier
## beside it at a round start counts — TerminalRules).
func try_operate_terminal() -> void:
	var cost := action_cost(UnitStats.Action.OPERATE_TERMINAL)
	if not can_afford(cost) or is_busy or is_downed:
		return
	var why := ObjectiveManager.operate_blocker(self)
	if why != "":
		action_logged.emit("%s: can't operate the terminal — %s" % [stats.display_name, why])
		return
	pay(cost)
	set_mode(Mode.NONE)
	await _interact_at(ObjectiveManager.terminal().tile)
	ObjectiveManager.operate_terminal(self)
	await _check_activation_end()


## The end of a command. In turn mode it closes the activation on the last AP. Out
## of combat there is no activation to close: any round the command's price crossed
## ticks here, after the action has landed (E6). Coroutine.
func _check_activation_end() -> void:
	if TurnManager.in_exploration():
		await TurnManager.settle_clock()
		return
	if ap <= 0:
		end_activation()


func end_activation() -> void:
	if is_busy:
		return
	set_mode(Mode.NONE)
	TurnManager.end_activation(self)
