class_name DoorGunUnit
extends EnemyUnit
## The landed ship's door gunner (GDD §7.4, extraction plan Phase 5): "a landed
## ship carries a gunner who joins the initiative pool (hidden Initiative, like
## an enemy) and fires on hostiles near the ramp. Enemies can disable it with
## enough damage, and it stays down for the rest of that landing (a re-called
## ship brings a fresh gunner). The ship itself cannot be damaged."
##
## WHY A UNIT, AND WHY THIS ONE. The Dropship is deliberately not a Unit (nothing
## can target it, see dropship.gd), so whatever fights from it has to be one: it
## needs a place in the draw pool, HP that the damage system already prices, and
## to be something hostile AI finds through `hostiles()` like any other target.
## `EnemyUnit` rather than `Unit` for the same reason NestUnit gives — TurnManager
## awaits `take_turn` on an EnemyUnit and waits for player input on anything else,
## and the action log hangs off EnemyUnit's `action_logged`. Nothing else of the
## alien state machine is used: `take_turn` is overridden whole and every stimulus
## hook (`rouse`, `hear_noise`, `come_under_fire`, the beam callback) is a no-op.
## A gunner bolted to a hull has nowhere to investigate and nobody to alert.
##
## CREW- AND FACTION-AGNOSTIC. Which side it is on is `faction`, set by whoever
## spawns it from the calling crew (ExtractionManager.spawn_door_gun —
## CONTRACTORS for the player's ship, a merc crew's own faction in extraction
## plan Phase 8). Everything it does is asked through `hostiles()`, so a merc
## ship's gunner shoots the squad by the same code that has the player's gunner
## shoot aliens.
##
## NEVER A SQUAD MEMBER. It is not a PlayerUnit (`is_player_controlled` is
## false), not in the "player_units" or "enemy_units" groups, belongs to no crew
## for extraction (`ExtractionManager.crew_of` says NO_CREW), and leaves no body:
## see `leaves_body` and the loot overrides at the bottom. So it never counts
## toward a wipe, never boards, never shows in a debrief, is never driven by
## input or by the `--auto` harness (main.gd `_auto_play` only drives PlayerUnits).
##
## Placeholder art: a boxy machine silhouette from UnitVisual's placeholder set,
## raised onto the hull roof where the Dropship's door_gun_mount is. The tile it
## STANDS on is the pad cell under that mount (MapData.hangar_gun_cell).

## Group every live door gun is in — what the HUD and the tests look them up by.
## Deliberately NOT "enemy_units": that group is the aliens' and robots' alert
## network (EnemyUnit._propagate_alert, AlienHivemind.escalate), and a gunner is
## in neither.
const GROUP := "door_guns"

## Tiles from the extraction square a hostile may be and still be engaged —
## Chebyshev distance to the NEAREST of the square's nine cells. GDD §7.4 says
## "fires on hostiles near the ramp", and this is what near means: 6 covers the
## square, the pad's flanks and the approach into a 9x9+ bay, without letting a
## ship parked in one corner of a hangar snipe down the corridor outside it.
## Placeholder (GDD §12.1 open question #2).
const RANGE_FROM_SQUARE := 6

## Snap shots per activation. Two, priced as Shoot through `ap_pool` below so a
## torso-crit stun (TurnManager zeroes `ap`) still costs it the activation like
## anyone else. An LMG gunner laying down two bursts a round is a real threat to
## anything crossing the square, which is the point of it.
const SHOTS_PER_ACTIVATION := 2

## GDD §12.1 #2 "Gunner stats are TBD" — these are the placeholders (decision
## log, Phase 5). HP 30 is a soldier and a half; it is ARMORED (the ammo
## classification, UnitStats.armored) and its plating takes ARMOR off every hit,
## with at least MIN_DAMAGE_THROUGH_ARMOR always getting through — the same rule
## the robots' plating follows (CerberusUnit.damage_taken).
const MAX_HP := 30
const ARMOR := 2
const MIN_DAMAGE_THROUGH_ARMOR := 1
## A trained crewman behind a mounted gun: a soldier's Reflexes (so a soldier's
## Shoot price), a little less Perception than a soldier's 50 — it is the ship's
## gunner, not a marksman — and average Luck.
const PERCEPTION := 40
const REFLEXES := 50
const LUCK := 30
## Initiative 50 + 0.2 x 50 + 5 = 65: in among the squad's ~62-68, so it acts
## somewhere in the middle of a round rather than reliably first or last. HIDDEN
## from the player like any non-PlayerUnit's (the HUD prints Initiative only for
## PlayerUnits, hud.gd `_refresh`).
const BASE_INITIATIVE := 50
const EQUIPMENT_INITIATIVE := 5
## The weapon is the LMG's numbers (WeaponPresets.DATA[LMG]: accuracy 28, damage
## 9, no range falloff) on a belt fed from the ship: unlimited reserve, and the
## magazine is topped back up after every burst (`_top_up`), so it never stops to
## reload. NOT a roster gun (id -1), so it is never an item anywhere.
const WEAPON_ACCURACY := 28
const WEAPON_DAMAGE := 9
const WEAPON_MAG := 6
const WEAPON_NOISE := 5

## Metres the model and label are raised by: the Dropship's roof, where the mount is.
const ROOF_HEIGHT := Dropship.HULL_SIZE.y
## Placeholder model and its self-lit status light: green while manned, dark once
## disabled (the "mesh stays and goes dark" of the decision log).
const VARIANT := &"door_gun"
const STATUS_ACTIVE := Color(0.35, 1.0, 0.45)
const STATUS_DISABLED := Color(0.04, 0.04, 0.05)
const LABEL_ACTIVE := Color(0.55, 0.95, 0.6)
const LABEL_DISABLED := Color(0.55, 0.55, 0.58)

## The crew whose ship this is (ExtractionRules crew ids). Read only for the log
## and by Phase 8; sides are `faction`.
var crew_id: int = ExtractionRules.PLAYER_CREW
## The hangar it is mounted at, and that hangar's extraction square — what
## `RANGE_FROM_SQUARE` is measured from.
var hangar_index: int = -1
var square: Array[Vector3i] = []


## Geometry its own sightlines ignore (GridManager.has_line_of_sight): the landed
## ship's sight-and-light blocker (GDD §7.2). The gun is mounted ON the hull, so
## the hull hides the bay behind it from everyone else but never from the gun —
## and never the gun from whoever it sees.
func los_exclusions() -> Array[RID]:
	var out: Array[RID] = []
	var blocker := ExtractionManager.ship_blocker(hangar_index)
	if blocker != null:
		out.append(blocker.get_rid())
	return out


func _init() -> void:
	# EnemyUnit's constructor has already run (aliens' faction, no flashlight);
	# CONTRACTORS is only the default here — `make` sets the calling crew's.
	faction = Faction.Id.CONTRACTORS
	has_flashlight = false
	add_to_group("units")
	add_to_group(GROUP)
	_build_nodes()


## The children a Unit scene would carry, built in code because the gunner has no
## scene of its own: the Visual (UnitVisual, the machine placeholder for
## VARIANT, raised to the roof) and a NameLabel. No click Body: nobody ever
## targets it by clicking — the squad never shoots its own gunner, and hostile AI
## picks targets through `hostiles()`, not through picking.
func _build_nodes() -> void:
	var visual_node := UnitVisual.new()
	visual_node.name = "Visual"
	visual_node.variant = VARIANT
	visual_node.placeholder_style = &"machine"
	visual_node.layers = [&"body", &"head", &"weapon", &"status"]
	visual_node.has_light = false
	visual_node.position = Vector3(0.0, ROOF_HEIGHT, 0.0)
	add_child(visual_node)
	var label := Label3D.new()
	label.name = "NameLabel"
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = Vector3(0.0, ROOF_HEIGHT + 1.4, 0.0)
	add_child(label)


## A gunner for `crew`'s ship at `hangar_index`, on `tile`, fighting for
## `faction_id`, covering `square_cells`. Named `node_name` BEFORE it enters the
## tree — co-op addresses units by path, and both peers build their own copy (see
## ExtractionManager.spawn_door_gun). Add it under the units' parent yourself.
## Deterministic: nothing here rolls, so two peers build the same gunner.
static func make(node_name: String, crew: int, faction_id: Faction.Id, index: int,
		tile: Vector3i, square_cells: Array, display_name: String = "Door gun") -> DoorGunUnit:
	var gun := DoorGunUnit.new()
	gun.name = node_name
	gun.crew_id = crew
	gun.faction = faction_id
	gun.hangar_index = index
	gun.square.assign(square_cells)
	gun.stats = make_stats(display_name)
	gun.position = GridManager.grid_to_world(tile)
	return gun


## The placeholder stat block (constants above). Fitness 0, so `base_hp` IS max
## HP (the nest's trick, AlienPresets.nest) — the AP pool is `ap_pool`'s business.
static func make_stats(display_name: String = "Door gun") -> UnitStats:
	var stats := UnitStats.new()
	stats.display_name = display_name
	stats.armored = true
	stats.perception = PERCEPTION
	stats.reflexes = REFLEXES
	stats.fitness = 0
	stats.luck = LUCK
	stats.base_hp = MAX_HP
	stats.base_initiative = BASE_INITIATIVE
	stats.equipment_initiative = EQUIPMENT_INITIATIVE
	# Nothing gets close enough to need it, and a gunner on a roof cannot swing.
	stats.melee_base_accuracy = 0
	stats.melee_damage = 0
	var w := WeaponData.new()
	w.display_name = "Door gun"
	w.base_accuracy = WEAPON_ACCURACY
	w.damage = WEAPON_DAMAGE
	w.mag_size = WEAPON_MAG
	w.starting_reserve = -1
	w.noise_radius = WEAPON_NOISE
	stats.weapon = w
	return stats


func _ready() -> void:
	super()
	visual.set_status_color(STATUS_ACTIVE)
	hp_changed.connect(func(_u: Unit) -> void: _refresh_label())
	_refresh_label()


# --- The activation -------------------------------------------------------------


## Exactly SHOTS_PER_ACTIVATION Shoots' worth, whatever Fitness would say.
func ap_pool() -> int:
	return SHOTS_PER_ACTIVATION * action_cost(UnitStats.Action.SHOOT)


## Never moves, never looks for anything to investigate: each Shoot it can pay
## for goes at the best target in its field of fire (`best_target`), re-chosen
## per shot so a kill frees the second burst for somebody else. Nothing in reach
## is a quiet activation — no line, so a quiet bay does not spam the log.
func take_turn() -> void:
	var shoot_cost := action_cost(UnitStats.Action.SHOOT)
	while ap >= shoot_cost and not is_downed and not TurnManager.mission_over:
		var quarry := best_target()
		if quarry == null:
			return
		spend_ap(shoot_cost)
		var was := quarry.life_state
		var result: Combat.ShotResult = await fire_at(quarry, Combat.ShotAction.SHOOT)
		_top_up()
		action_logged.emit("%s fires on %s (%d%% acc): %s" % [
			stats.display_name, quarry.stats.display_name, result.accuracy, Combat.describe(result)])
		_log_casualty(quarry, was)


## The belt: the magazine never runs dry (see WEAPON_MAG).
func _top_up() -> void:
	ammo = stats.mag_size


## Every hostile this gunner may engage right now: standing, within
## RANGE_FROM_SQUARE of the square, and in line of sight. Light does NOT gate
## the list — a gunner on a lit hull above a dark bay still knows where the
## muzzle flashes are — it prices the shot instead: the GDD §5.1 light modifier
## applies to every roll this unit makes (extraction plan A9, `light_agnostic`
## left false), so a target in the dark is a worse shot, and `best_target` ranks
## it lower for exactly that reason.
func targets_in_reach() -> Array[Unit]:
	var out: Array[Unit] = []
	for unit in hostiles():
		if covers(unit.grid_pos) and GridManager.has_line_of_sight(self, unit):
			out.append(unit)
	return out


## The target the next burst goes at, or null: highest hit chance first (light,
## cover, range, hunkering all fold in through Combat.compute_accuracy, exactly
## as the shot will roll), then whoever is nearest the square — the threat to
## the people boarding — then node name, so the choice never depends on group
## order and two runs on one seed agree.
func best_target() -> Unit:
	var best: Unit = null
	var best_acc := -1
	var best_dist := 999999
	for unit in targets_in_reach():
		var acc := Combat.compute_accuracy(self, unit, Combat.ShotAction.SHOOT)
		var dist := distance_to_square(unit.grid_pos, square)
		if best != null:
			if acc < best_acc:
				continue
			if acc == best_acc and (dist > best_dist
					or (dist == best_dist and String(unit.name) > String(best.name))):
				continue
		best = unit
		best_acc = acc
		best_dist = dist
	return best


## Whether `pos` is inside this gunner's field of fire (RANGE_FROM_SQUARE).
func covers(pos: Vector3i) -> bool:
	return distance_to_square(pos, square) <= RANGE_FROM_SQUARE


## Chebyshev distance from `pos` to the nearest cell of `cells`. Static and
## engine-free, so a test can check the rule without a board.
static func distance_to_square(pos: Vector3i, cells: Array) -> int:
	var best := 999999
	for cell: Vector3i in cells:
		best = mini(best, maxi(absi(cell.x - pos.x), absi(cell.z - pos.z)))
	return best


# --- No senses, no alerts -------------------------------------------------------
# The awareness state machine is EnemyUnit's, and a mounted gun has none of it:
# it does not investigate, wake, or pass an alert on. Overridden to nothing so no
# stimulus can flip `alert_state` (and with it the label and a scream clip).


func rouse(_at: Vector3i) -> void:
	pass


func hear_noise(_at: Vector3i) -> void:
	pass


func come_under_fire(_shooter: Unit) -> void:
	pass


func settle() -> void:
	pass


func _on_lighting_changed() -> void:
	pass


# --- Armor, and what being disabled looks like ------------------------------------


func damage_taken(amount: int) -> int:
	if amount <= 0:
		return 0
	return maxi(MIN_DAMAGE_THROUGH_ARMOR, amount - ARMOR)


## DISABLED rather than downed or a corpse. It cannot be downed at all (only a
## PlayerUnit can), so 0 HP is `die()` and DEAD like any non-soldier — but it is
## presented as a gun that has gone quiet, not a body: the model stays where it
## is, upright on the roof, dark (the corpse tint plus a dead status light), and
## the label says DISABLED. No collapse clip and no name-label hiding, which is
## all the base presentation would add. Nothing revives it (nothing can: revive
## wants `can_be_downed`), so the only way out of this state is the takeoff that
## frees it (`retire`). Runs on every peer, like the base.
func _present_life_state(old: LifeState) -> void:
	if old == LifeState.ACTIVE and life_state != LifeState.ACTIVE:
		var tile: GridTileData = GridManager.get_tile(grid_pos)
		if tile and tile.occupant == self:
			GridManager.set_occupant(grid_pos, null)
		visual.set_dead_tint(true)
		visual.set_status_color(STATUS_DISABLED)
	_refresh_label()


func _on_replicated() -> void:
	_refresh_label()


## "Door gun 24/30", or "Door gun — DISABLED". Replaces EnemyUnit's alert-glyph
## label: a gunner has no alert state worth reading, and its HP is the one thing
## the player wants from it.
func _refresh_label() -> void:
	if _name_label == null:
		return
	_name_label.visible = true
	if life_state == LifeState.ACTIVE:
		_name_label.text = "%s %d/%d" % [stats.display_name, current_hp, stats.max_hp()]
		_name_label.modulate = LABEL_ACTIVE
	else:
		_name_label.text = "%s — DISABLED" % stats.display_name
		_name_label.modulate = LABEL_DISABLED


func is_disabled() -> bool:
	return life_state != LifeState.ACTIVE


# --- Not a body, not loot ---------------------------------------------------------


## A disabled gun is part of the ship, not a corpse on the deck: never in
## `Unit.bodies_on`, never lootable, never carriable (it cannot be downed, which
## already rules that out — `is_carriable` wants `can_be_downed`).
func leaves_body() -> bool:
	return false


func loot_blocker(_looter: Unit) -> String:
	return "part of the ship"


func loot_items() -> Array[ItemData]:
	return []


func _equipped_gear_items() -> Array[ItemData]:
	return []


## Takes it off the board for good: out of every group (so the next round's pool
## snapshot, `hostiles()` and every other group scan stop seeing it at once —
## `queue_free` alone waits for the end of the frame, and the round can start
## again before that), out of the current pool, off its tile, then freed. Runs on
## every peer, from ExtractionManager's departure presentation.
func retire() -> void:
	remove_from_group("units")
	remove_from_group(GROUP)
	TurnManager.pool.erase(self)
	if TurnManager.active_unit == self:
		TurnManager.active_unit = null
	var tile: GridTileData = GridManager.get_tile(grid_pos)
	if tile and tile.occupant == self:
		GridManager.set_occupant(grid_pos, null)
	queue_free()
