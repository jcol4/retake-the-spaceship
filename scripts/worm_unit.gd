class_name WormUnit
extends SwarmUnit
## The worm, and the mass it piles into. Design:
## docs/design/factions/aliens/design-choices/worm-mass.md
##
## ONE NODE TYPE, NOT TWO. A "worm mass" is a WormUnit with more HP — there is
## no second scene and no promotion step, and that is a decision rather than a
## shortcut. A separate mass node would mean freeing and spawning nodes on every
## merge, and `TurnManager.pool` is a turn-start snapshot: a freed entry in it is
## a crash, and removing a worm through the ordinary damage path would emit
## `SecurityNetwork.report_evidence(CORPSE)` and litter the deck with corpses
## nobody killed. Growing in place means only the ABSORBED node ever disappears.
##
## HP IS THE ONLY STATE. `worm_count()` is `ceil(current_hp / 5)` and everything
## else — damage, pace, sprite, melee accuracy — derives from that. Nothing
## caches a count, so there is no pair of numbers that can disagree:
##
##   damage   2 x count       10 worms one-shots most of the roster
##   HP       5 x count       the worm's own 5 HP, up to sixteen times
##   pace     1-4 tiles       by tier, out of a flat 12 AP pool
##
## Shooting a mass therefore makes it weaker, slower AND smaller on the same
## hit, which is the whole counterplay loop and the reason HP is the root.
##
## TWO DELIBERATE BREAKS with the rest of the faction, both inherited from the
## old single worm and both still true:
##
## PACE IS A PRICE PER TILE, NOT A POOL (Sec 4.1 makes movement flat at 1 AP a
## tile, but the pool floors at 6, so no stat block can hold a unit under six
## tiles a turn — not a pace for something half a metre long). The mass keeps
## that inversion and uses it to buy its tiers: a flat 12 AP pool divided by a
## per-tier price, which is the only arrangement that lands exactly on 1, 2, 3
## and 4 tiles.
##
## IT FEELS FOOTSTEPS. The faction's rule is no special senses; the worm is the
## named exception. It senses any hostile that MOVED within `tremor_range` on its
## own deck since its last activation, lit or not, seen or not. Standing still is
## the counterplay and it is a real one. Contact is always felt.
##
## THE THIRD BREAK IS NEW AND IS NOT INHERITED. From count 2 upward the mass has
## no attack action at all: it walks through you. That deletes the fodder tier's
## "close OR swing, never both" — the one turn of warning `SwarmUnit` is built
## around — and it is deleted knowingly. See `_trample_along`.

## Worms per unit of HP. The worm's own `base_hp`, and the size of the step the
## pile shrinks by when it is shot.
const HP_PER_WORM := 5

## Damage a single worm contributes to a trample or a bite.
const DAMAGE_PER_WORM := 2

## The pile stops accepting arrivals here. A worm reaching a full mass seeds its
## own alongside instead, which is how a tide becomes a front rather than one
## very angry tile.
const MAX_WORMS := 16

## At or above this the mass stops gathering and commits to its quarry: 10 worms
## is 20 damage against a 19-21 HP soldier, so it has enough to kill and spends
## itself. Below it, a worm is worth more walking to the pile than biting.
const TERMINAL_WORMS := 10

## Flat, and overridden rather than bought with Fitness. 12 is the smallest pool
## that divides cleanly into 1, 2, 3 and 4 tiles; buying it with Fitness 80
## instead would leak +6 HP into a unit whose HP is meant to be 5 x count and
## nothing else.
const AP_POOL := 12

## Count at which each tier begins, and the tiles a turn it buys. Index is the
## tier; `TIER_FLOOR[0]` is the lone worm.
const TIER_FLOOR := [1, 2, 6, 10, 14]
const TIER_TILES := [1, 1, 2, 3, 4]
const TIER_NAME := ["Worm", "Clutch", "Knot", "Swell", "Tide"]

## Art variant per tier. Swell and Tide share a sculpt and separate by scale —
## three sheets cover five tiers, and the count on the label carries the rest.
const TIER_VARIANT: Array[StringName] = [&"worm", &"worm_clutch", &"worm_knot", &"worm_tide", &"worm_tide"]

## The render canvas every worm sheet is framed to (render_sprites.py
## CANVAS_HEIGHT, mirrored here exactly as `worm_unit.tscn` mirrors it).
const CANVAS_HEIGHT := 2.56

## Where the art's lowest opaque row sits in each tier's sheet, by tier.
##
## MEASURED off the rendered PNGs, never derived — `render_sprites.py` prints
## each of these at the end of its run and they are copied in by hand.
##
## These are the renderer's "no-clip alternative", i.e. the MINIMUM opaque row,
## where every humanoid in the project uses the mean across idle facings. A pile
## lies along the deck, so almost all of its silhouette is depth rather than
## height, and a vertical billboard turns depth into height: anchoring on the
## mean would bury the pile under the floor. The renderer names the worm as
## exactly this case, and a pile is the same case, larger. `worm_unit.tscn`
## carries the single worm's 0.90781518 for the same reason.
##
## Index 0 duplicates the scene's value rather than reading it, because
## `set_variant` back to `&"worm"` has to restore it and the scene is not
## consulted again after `_ready`.
const TIER_FOOT_ANCHOR := [0.90781518, 0.93543150, 0.98307192, 1.0, 1.0]

## Smallest fraction of a tier's sculpt shown at that tier's floor. A Knot at 6
## worms draws at 82% of the 9-worm sculpt and grows to full across the tier, so
## three sheets read as sixteen sizes.
const TIER_MIN_SCALE := 0.82

## Loaded rather than preloaded: this script IS the scene's script, and a
## preload of the scene from inside it is a cyclic resource dependency.
const WORM_SCENE_PATH := "res://scenes/worm_unit.tscn"

## Tiles (Chebyshev, same deck) within which a hostile's movement is felt.
## Deliberately flat across tiers — a bigger pile feeling further is an obvious
## extension and is not taken yet.
@export var tremor_range: int = 4

## Where each hostile stood at this worm's last activation.
var _felt_at: Dictionary = {}
## Hostiles that moved within range since then. Rebuilt once per activation, so
## every sense check inside one activation gets the same answer.
var _tremors: Array[Unit] = []

## Turn on which this mass last grew. Growing costs the rest of the turn — see
## `take_turn` — so every tier change is followed by one activation of the pile
## sitting still at its new size.
var _grew_on_turn: int = -1

## Set by `dissolve`. The node is freed at the end of the frame, and anything
## still holding a reference to it must stop rather than keep driving it.
var _dissolved: bool = false

## Where this worm was told to gather, by its own sighting or a neighbour's call.
## Only consulted when there is no larger pile to walk to.
var _rally_hint: Vector3i
var _has_rally_hint: bool = false

## Last count the visual was built for, so `_apply_count` can skip the expensive
## half (a variant swap re-loads and re-scales every layer) on the common case
## where HP moved but the tier did not.
var _shown_tier: int = -1


func _ready() -> void:
	super()
	_apply_count()


# ---------------------------------------------------------------- derived size


## Worms in this pile. THE state — everything else is a function of it, and it
## is itself a function of HP, so damage and size can never disagree.
func worm_count() -> int:
	return clampi(ceili(current_hp / float(HP_PER_WORM)), 1, MAX_WORMS)


func tier() -> int:
	var worms := worm_count()
	for t in range(TIER_FLOOR.size() - 1, -1, -1):
		if worms >= TIER_FLOOR[t]:
			return t
	return 0


func tier_name() -> String:
	return TIER_NAME[tier()]


func tiles_per_turn() -> int:
	return TIER_TILES[tier()]


## True once this pile is worth calling a mass: it tramples instead of biting,
## and it is what the rest of the file branches on.
func is_mass() -> bool:
	return worm_count() > 1


func is_terminal() -> bool:
	return worm_count() >= TERMINAL_WORMS


func is_full() -> bool:
	return worm_count() >= MAX_WORMS


# ------------------------------------------------------------------- AP prices


func ap_pool() -> int:
	return AP_POOL


func move_ap_per_tile() -> int:
	return AP_POOL / tiles_per_turn()


## The bite — the LONE worm's attack — costs the whole pool, exactly as it did
## before the mass existed: it closes or it bites, never both.
##
## Stated here rather than derived from Reflexes, and that is the point. The
## swarm's Reflexes 40 exists solely to buy a 5 AP claw against a 6 AP pool and
## has to be re-pinned every time `K_REFLEXES` moves (see AlienPresets.swarm).
## "The bite costs the turn" is a RULE for this unit, not a tuning outcome, so it
## is written as one.
##
## A mass never reaches this: it has no melee action, and its trample is paid for
## with the tile it was going to step on anyway.
func action_cost(action: UnitStats.Action) -> int:
	if action == UnitStats.Action.MELEE:
		return AP_POOL
	return super(action)


## Many mouths. A one-shot that lands barely half the time is a coin flip the
## player cannot plan around, and a Tide that whiffs is an anticlimax.
## TUNABLE — invented for the design doc, not yet felt on screen.
func melee_accuracy_bonus(_target: Unit) -> int:
	return mini(DAMAGE_PER_WORM * worm_count(), 30)


# ----------------------------------------------------------- count -> presence


## Pushes the derived numbers onto the places the rest of the engine reads them.
## Called on spawn and after anything that moves HP.
func _apply_count() -> void:
	var worms := worm_count()
	# `Combat.resolve_melee` reads this at swing time, so the trample scales by
	# assignment and needs no hook in Combat at all.
	stats.melee_damage = DAMAGE_PER_WORM * worms
	# Max HP tracks the pile so the HUD reads "38 / 40" rather than "38 / 5".
	stats.base_hp = HP_PER_WORM * worms
	_refresh_label()
	var t := tier()
	if t == _shown_tier:
		return
	_shown_tier = t
	if visual == null:
		return
	# Ordered: `set_variant` re-derives pixel size from `canvas_height`, so the
	# height has to be in place before the swap, not after.
	var floor_count: int = TIER_FLOOR[t]
	var ceil_count: int = MAX_WORMS if t == TIER_FLOOR.size() - 1 else TIER_FLOOR[t + 1] - 1
	var span := ceil_count - floor_count
	var f := 0.0 if span <= 0 else float(worms - floor_count) / float(span)
	visual.canvas_height = CANVAS_HEIGHT * lerpf(TIER_MIN_SCALE, 1.0, f)
	# Both BEFORE the swap: `set_variant` re-derives pixel size and pivot from
	# these two, so setting either afterwards leaves the sprite scaled to the
	# tier it just left.
	visual.foot_anchor = Vector2(0.5, TIER_FOOT_ANCHOR[t])
	visual.set_variant(TIER_VARIANT[t])


func _refresh_label() -> void:
	super()
	if _name_label == null:
		return
	# The count in writing, because sprite size is not a number a player can read
	# precisely enough to decide whether to spend a grenade.
	if is_mass():
		_name_label.text = "%s x%d%s" % [
			tier_name(), worm_count(), STATE_GLYPH[alert_state]]


func take_damage(amount: int) -> int:
	var dealt := super(amount)
	if not is_downed:
		_apply_count()
	return dealt


# --------------------------------------------------------------------- senses


func take_turn() -> void:
	if _dissolved:
		return
	# Growing costs the rest of the turn. Without this a Knot joined by its sixth
	# worm acts at Swell pace and Swell damage in the same turn the player
	# watched it grow; with it, every tier change is followed by one activation
	# of the pile sitting still at its new size.
	if _grew_on_turn == TurnManager.turn_number:
		ap = 0
		action_logged.emit("%s swells to %d and settles" % [tier_name(), worm_count()])
		return
	_feel_tremors()
	await super()


func _feel_tremors() -> void:
	_tremors.clear()
	for unit in hostiles():
		var was: Variant = _felt_at.get(unit)
		_felt_at[unit] = unit.grid_pos
		if was == null or was == unit.grid_pos or unit.grid_pos.y != grid_pos.y:
			continue
		if GridManager.chebyshev_dist(grid_pos, unit.grid_pos) <= tremor_range:
			_tremors.append(unit)


func _can_see(unit: Unit) -> bool:
	if super(unit):
		return true
	if unit == null or unit.is_downed:
		return false
	return GridManager.is_melee_adjacent(grid_pos, unit.grid_pos) or unit in _tremors


func _melee_verb() -> String:
	return "bit"


# ------------------------------------------------------------------- the rally


## Every living worm sharing this one's compartment, itself included.
##
## Compartment-scoped for the same reason alerts are (EnemyUnit._propagate_alert):
## a closed door has to stop worms gathering exactly as it stops a scream, or
## isolating rooms stops being the strategy the design says it is. Falls back to
## the whole deck only where the room graph does not describe a tile.
func _worms_here() -> Array[WormUnit]:
	var out: Array[WormUnit] = []
	var here := _room_here()
	for node in get_tree().get_nodes_in_group("enemy_units"):
		var worm := node as WormUnit
		if worm == null or worm.is_downed or worm._dissolved:
			continue
		if here >= 0:
			var there := worm._room_here()
			if there >= 0 and there != here:
				continue
		out.append(worm)
	return out


## Which of two piles the other one should walk to. Bigger wins; ties break on
## instance id so that two identical worms cannot each decide the OTHER is the
## rally and walk past one another forever.
static func _outranks(a: WormUnit, b: WormUnit) -> bool:
	if a.worm_count() != b.worm_count():
		return a.worm_count() > b.worm_count()
	return a.get_instance_id() < b.get_instance_id()


## The biggest pile in the compartment. Returns self when this IS the biggest,
## which is what makes a rally point hold still and be gathered ONTO.
func _rally_pile() -> WormUnit:
	var best: WormUnit = self
	for worm in _worms_here():
		if worm != self and not worm.is_full() and _outranks(worm, best):
			best = worm
	return best


## Rouses every worm in the compartment and tells it where to gather.
##
## Deliberately NOT routed through `_propagate_alert`: that hands out
## `last_known_pos` — where the PLAYER was — and worms converging on the player
## arrive from every side at once and read as noise. Worms converging on each
## other produce one growing, visible, shootable blob the player can point at.
func _call_the_pile() -> void:
	var gather := _rally_pile().grid_pos
	for worm in _worms_here():
		if worm == self:
			continue
		worm._rally_hint = gather
		worm._has_rally_hint = true
		if worm.alert_state == EnemyUnit.AlertState.UNAWARE:
			worm.rouse(gather)


func _enter_combat(new_target: Unit, reason: String) -> void:
	super(new_target, reason)
	_call_the_pile()


# --------------------------------------------------------------- the turn loop


## Three questions in order, and the order IS the behaviour:
##
##   1. Is there a bigger pile to join?   -> walk to it, trampling what is in the way
##   2. Am I the pile, with worms coming? -> hold, and call the rest in
##   3. Otherwise                          -> spend myself on the quarry
##
## A mass at or above terminal skips straight to 3: it has enough to kill, so
## gathering further is worth less than killing now.
func _combat_turn() -> void:
	if _dissolved:
		return
	var quarry := acquire_target()
	if quarry == null:
		return

	if not is_terminal():
		var pile := _rally_pile()
		if pile != self:
			await _advance_on(pile.grid_pos, true)
			if not _dissolved:
				_try_merge()
			return
		if _worms_here().size() > 1:
			# This IS the rally and the compartment still has worms in it. Hold
			# still and keep calling: a rally point that wanders is not one.
			_call_the_pile()
			ap = 0
			action_logged.emit("%s holds and calls the deck" % _display())
			return

	# Terminal, or the last worms in the compartment with nothing left to gather.
	if is_mass():
		# Path ONTO the quarry's tile rather than short of it — the step onto it
		# is the attack, and `_trample_along` spends it as one.
		await _advance_on(quarry.grid_pos, false)
		if not _dissolved:
			_try_merge()
	else:
		# One worm, alone: the old creature, entirely unchanged. Crawl at the
		# target, bite once adjacent, close OR bite never both.
		await super()


func _display() -> String:
	return "%s x%d" % [tier_name(), worm_count()] if is_mass() else stats.display_name


## Walks toward `dest`, trampling what it meets. `stop_short` drops the final
## tile, for closing on a pile rather than onto it.
func _advance_on(dest: Vector3i, stop_short: bool) -> void:
	var full_path := GridManager.find_path(grid_pos, dest, 999, true, self)
	if stop_short and not full_path.is_empty():
		full_path.resize(full_path.size() - 1)
	var budget := _move_budget()
	if full_path.is_empty() or budget < 1:
		ap = 0
		return
	await _trample_along(full_path.slice(0, mini(budget, full_path.size())))


## The whole of the mass's attack, and the reason it has no attack action.
##
## Walks the path a tile at a time. A tile with a hostile on it is not stepped
## onto — the step is spent AS the blow instead, at the tile's ordinary price.
## If that kills, `Unit.take_damage` has already cleared the tile's occupant, so
## the corpse stops blocking and the pile rolls on with whatever it has left. If
## it does not kill, the body held and the activation is over.
##
## Movement is flushed in runs rather than per tile so `move_along` still owns
## the animation, the stance and — the part that matters — the per-tile
## `check_overwatch` and `check_suppression_break` calls. A Tide crossing four
## tiles into a prepared squad eats up to four reserved shots on the way in, and
## every one that lands cuts the damage it arrives with.
func _trample_along(path: Array[Vector3i]) -> void:
	var pending: Array[Vector3i] = []
	for step in path:
		var blocker := _hostile_on(step)
		if blocker == null:
			pending.append(step)
			continue
		if not pending.is_empty():
			await move_along(pending)
			pending.clear()
			if is_downed or _dissolved:
				return
		if ap < move_ap_per_tile():
			ap = 0
			return
		spend_ap(move_ap_per_tile())
		await _trample(blocker)
		if is_downed or _dissolved:
			return
		if not blocker.is_downed:
			ap = 0  # the body in front of it held; that was the whole activation
			return
		pending.append(step)  # the tile is clear now — roll on
	if not pending.is_empty():
		await move_along(pending)


func _hostile_on(pos: Vector3i) -> Unit:
	var tile: GridTileData = GridManager.get_tile(pos)
	if tile == null:
		return null
	var occupant := tile.occupant as Unit
	if occupant == null or occupant.is_downed or not is_hostile_to(occupant):
		return null
	return occupant


## Resolves a trample. Deliberately NOT `melee_at`: that plays `UnitVisual.MELEE`
## and there is no melee art, because there is no melee action — the trample IS
## the walk cycle. Everything else about a swing is kept, so accuracy, crit,
## armor, the log line and the "you were attacked" stimulus all behave as they do
## anywhere else on the board.
func _trample(target: Unit) -> void:
	var result := Combat.resolve_melee(self, target)
	if result.hit:
		if not is_instant():
			var vfx := get_tree().get_first_node_in_group("vfx")
			if vfx:
				vfx.impact(target.global_position, result.crit)
		var raw := result.damage
		result.damage = target.take_damage(raw)
		result.absorbed = raw - result.damage
	_report_incoming(target)
	action_logged.emit("%s rolls over %s (%d%% acc): %s" % [
		_display(), target.stats.display_name, result.accuracy, Combat.describe(result),
	])
	if target.is_downed:
		action_logged.emit("%s is DOWN!" % target.stats.display_name)


# --------------------------------------------------------------- merge & decay


## Absorbs any adjacent worm this one outranks. Run at the end of a move, which
## is the only moment two piles can newly become neighbours.
func _try_merge() -> void:
	for worm in _worms_here():
		if worm == self or worm._dissolved or is_full():
			continue
		if not GridManager.is_melee_adjacent(grid_pos, worm.grid_pos):
			continue
		if _outranks(self, worm):
			absorb(worm)
		else:
			worm.absorb(self)
			return  # this node is gone; stop touching it


## Takes `other`'s worms into this pile.
##
## HP is what moves, not a count: a worm that arrives wounded brings less than a
## whole worm with it, which falls straight out of HP being the only state. The
## pile is capped by spilling the remainder back — `other` survives at whatever
## would not fit, and seeds the next mass alongside this one.
func absorb(other: WormUnit) -> void:
	if other == null or other == self or other._dissolved or other.is_downed:
		return
	var room := (MAX_WORMS * HP_PER_WORM) - current_hp
	if room <= 0:
		return
	var taken := mini(other.current_hp, room)
	current_hp += taken
	other.current_hp -= taken
	_grew_on_turn = TurnManager.turn_number
	_apply_count()
	hp_changed.emit(self)
	if other.current_hp > 0:
		# Overflow: the pile is full, so what did not fit stays on the board as
		# its own worm. This is how a tide becomes a front.
		other._apply_count()
		other.hp_changed.emit(other)
		action_logged.emit("%s is full — %s spills alongside it" % [_display(), other._display()])
		return
	action_logged.emit("%s joins the pile — %s" % [other._display(), _display()])
	other.dissolve()


## Leaves the board WITHOUT dying.
##
## `is_downed` is set because every scan on the board reads it — the draw pool,
## `hostiles()`, `allies()`, the mission end check — and this unit is genuinely
## no longer one of them. What is deliberately skipped is the rest of
## `take_damage`'s death path: no `downed` signal, no collapse animation, and
## above all no `SecurityNetwork.report_evidence(CORPSE)`. Nothing died here, and
## a Proctor finding sixteen bodies in a room where a pile merely formed would be
## reading evidence of a massacre that never happened.
func dissolve() -> void:
	if _dissolved:
		return
	_dissolved = true
	is_downed = true
	ap = 0
	GridManager.set_occupant(grid_pos, null)
	if _name_label:
		_name_label.visible = false
	visible = false
	queue_free()


## UNAWARE upkeep: a settled pile sheds a worm a turn until it is singles again.
##
## This is what makes "kill the lights and back off" a real answer to a forming
## tide rather than a delay, and it keeps a stalled mission from ending as one
## 80 HP blob the board can never recover granularity from.
func _idle_turn() -> void:
	if not is_mass():
		return
	var shed := mini(HP_PER_WORM, current_hp - HP_PER_WORM)
	if shed <= 0:
		return
	var spot := _free_neighbour()
	if spot == NO_TILE:
		return  # nowhere to spill; the pile holds until something moves
	current_hp -= shed
	_apply_count()
	hp_changed.emit(self)
	_spawn_worm_at(spot, shed)
	action_logged.emit("%s loosens — one worm crawls off" % _display())


## Sentinel for "no tile", rather than a null returned as Variant. A tile is a
## Vector3i everywhere else on the board and this keeps it one here too; the
## y-coordinate is a deck index, so a large negative one names no real deck.
const NO_TILE := Vector3i(-99999, -99999, -99999)


func _free_neighbour() -> Vector3i:
	for step in GridManager.STEPS:
		var pos: Vector3i = grid_pos + step
		if GridManager.is_free(pos):
			return pos
	return NO_TILE


func _spawn_worm_at(pos: Vector3i, hp: int) -> void:
	var scene := load(WORM_SCENE_PATH) as PackedScene
	if scene == null:
		return
	var worm: WormUnit = scene.instantiate()
	worm.stats = AlienPresets.worm("%s'" % stats.display_name)
	worm.position = GridManager.grid_to_world(pos)
	# The combat log is wired per unit by whoever spawned the first worms
	# (`main.gd`), and a unit that crawls off a pile has no such sponsor. Copying
	# this pile's own connections is what keeps a shed worm's lines in the log
	# without this file needing to know who is listening.
	get_parent().add_child(worm)
	for connection in action_logged.get_connections():
		worm.action_logged.connect(connection["callable"])
	worm.current_hp = hp
	worm._apply_count()
