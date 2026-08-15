class_name Unit
extends Node3D
## Base unit: stats, HP/AP/ammo state, shared actions. Sec 4.2 AP economy.

signal hp_changed(unit: Unit)
signal ap_changed(unit: Unit)
signal downed(unit: Unit)
signal moved(unit: Unit)

## AP per tile of movement (rework doc Sec 4.1). FLAT, for every unit regardless
## of stats: Fitness buys a bigger pool, not cheaper steps, and a diagonal costs
## the same one AP a cardinal does because the grid is eight-way at uniform cost
## (Sec 4.0 — GridManager.get_reachable_tiles is a BFS for exactly this reason).
##
## The only thing that raises it is injury; see `move_ap_per_tile`.
const MOVE_AP_PER_TILE := 1
const TURN_TIME := 0.09  # seconds to swing toward the next tile

# Rounds per burst. One trigger pull is still one Combat.resolve_shot — one hit
# roll, one damage number, one round of ammo — so this is purely how many
# tracers that shot draws, and changing it cannot unbalance anything.
const BURST_MIN := 3
const BURST_MAX := 5
# On a hit, this many rounds are thrown wide anyway so the burst reads as a
# burst; the rest converge. On a miss every round misses. Kept below BURST_MIN
# so a hit always lands visibly more rounds on target than it throws away.
const BURST_STRAY_MAX := 2

@export var stats: UnitStats

## Which side this unit is on. THE input to every hostility decision — see
## `is_hostile_to`, and `Faction` for why this replaced a boolean.
@export var faction: Faction.Id = Faction.Id.ALIENS

## Kept as a derived, READ-ONLY convenience for the paths that genuinely mean
## "the player's own unit" rather than "not an enemy" — input handling, the HUD,
## the win/loss tally, room rendering. Those are about who is holding the mouse,
## not about who shoots whom, and rewriting them in terms of factions would say
## less rather than more.
##
## Read-only on purpose: it used to be the field that got assigned, so making it
## unassignable is what guarantees no path still sets sides the old way.
var is_player_controlled: bool:
	get: return faction == Faction.Id.CONTRACTORS
## Metres per second while walking a path. Cosmetic ONLY — the tile budget and
## the AP economy know nothing about it, so no value here can affect balance.
##
## 4.5 is the soldier's, carried over unchanged from the 3D rig it was measured
## against. It is now the AUTHORING CONTRACT rather than a derived value: the
## sprite run cycle is drawn to read correctly at 4.5 m/s, instead of the speed
## being fitted to a clip that already existed. Slower types override it here.
@export var move_speed: float = 4.5

## Whether this unit only ever has ONE gait, and it is the walk.
##
## The default gait rule — run unless the move is a single tile — assumes a
## character who owns both cycles and chooses between them. A shambler owns
## exactly one: the brawler is animated to a walk and nothing else, and there is
## no sprint it is holding back. Setting this makes `move_speed` the speed of
## that walk rather than of a run, so the one number still means "how fast this
## thing crosses the deck".
##
## Note what this is NOT: a slow flag. It changes which CYCLE plays and which
## settle follows it, and a walk is already at rest when it ends, so a shambler
## arrives without the skid a runner needs. Dropping `move_speed` alone would
## have left it sprinting in place at a crawl.
@export var walks_only: bool = false

@onready var visual: UnitVisual = $Visual

var grid_pos: Vector3i
var current_hp: int
var ap: int = 0
var ammo: int
# Spare rounds beyond the loaded magazine. -1 means unlimited (never
# decremented by do_reload) — see WeaponData.starting_reserve.
var reserve: int = -1
var is_downed: bool = false
var hunkered: bool = false
var on_overwatch: bool = false
## AP the unit committed to its reserved shot (rework doc Sec 4.4). Recorded but
## NOT yet read by the accuracy math — the reserve-to-penalty formula is the
## rework's one genuinely open item (Sec 6 item 1), so the reaction shot still
## takes Combat.OVERWATCH_PENALTY's flat -30% until that lands. Written here now
## so the number the player committed exists to be scaled against when it does.
var overwatch_reserve: int = 0

## AP committed to the reserved shot. Read by `Combat.overwatch_penalty_for`:
## the more of the activation a unit spends watching an angle, the better it
## covers it. Reset in `begin_activation` along with `on_overwatch`.
##
## Suppression (XCOM-style), as a pair of links rather than a flag, because both
## ends have to be reachable: the pinned unit needs to know whose fire to break
## from, and the shooter needs to know who to fire on if they run.
##
## `suppressed_by` is the unit pinning THIS one; `suppressing` is the unit THIS
## one is pinning. Exactly one suppression per shooter — a second one replaces
## the first, since there is one weapon and it can only be pointed one way.
var suppressed_by: Unit = null
var suppressing: Unit = null
## Rounds a burst of suppressing fire puts downrange. Three, and they are spent
## up front rather than per reaction shot: the cost of pinning someone is paid
## when you commit to it, whether or not they ever break cover.
const SUPPRESS_AMMO_COST := 3
## AP taken off the pinned unit's next activation, floored so it always gets
## something. Being pinned costs you time as well as aim — this is the half of
## suppression that an AI cannot simply choose to ignore by not shooting.
## 3 rather than 2, scaled with the 1.5x AP pool: the penalty is meant to cost a
## pinned unit a recognisable slice of its activation, and a flat 2 against a
## bigger pool would have quietly demoted it to a rounding error.
const SUPPRESSED_AP_PENALTY := 3
## Seconds between bursts of covering fire while suppression holds. Purely
## cosmetic: the rounds were already paid for and these bursts resolve no shot,
## roll nothing and cannot hit anyone. It is what makes a pinned unit read as
## pinned instead of as a unit standing still with a debuff icon.
const SUPPRESSION_BURST_GAP := 3.0
const SUPPRESSION_BURST_ROUNDS := 3
var stunned: bool = false  # set by an incoming torso crit; burns this unit's next activation
var is_busy: bool = false  # animating a move or a shot — reject new orders
## Turn number this unit last walked on, for motion-based detection (the security
## robots' sensors read movement where the aliens read light). -1 so a unit that
## has never moved is never mistaken for one that just did.
var last_moved_turn: int = -1

# VATS-style body-part injury tracking (Sec 4.2/6.5). Each part accumulates the
# raw damage Aimed Shots land on it; crossing its threshold flags it injured for
# the rest of the mission (or until `heal_injury` is called by a future medical-
# resource action — not wired up to any action/UI yet).
const PART_HP_FRACTION := {
	Combat.BodyPart.TORSO: 0.50,
	Combat.BodyPart.HEAD: 0.25,
	Combat.BodyPart.ARM_L: 0.35, Combat.BodyPart.ARM_R: 0.35,
	Combat.BodyPart.LEG_L: 0.35, Combat.BodyPart.LEG_R: 0.35,
}
const LEG_INJURY_SPEED_PENALTY := 0.33  # per injured leg, fraction of move range lost
const ARM_RANGED_ACC_PENALTY := 15  # per injured arm
const ARM_MELEE_ACC_PENALTY := 25  # per injured arm
const ARM_MELEE_DMG_MULT := 0.6  # per injured arm, multiplicative (40% cut each)

var _body_part_damage: Dictionary = {}  # Combat.BodyPart -> int accumulated
var _injured_parts: Dictionary = {}  # Combat.BodyPart -> bool

# Sec 5.2: a free (0 AP) toggle. Aliens rely on their own senses rather than a
# rig-mounted light, so EnemyUnit sets has_flashlight false in _init().
var has_flashlight: bool = true
var flashlight_on: bool = true

# With no display there is nothing to animate, so walks and tracers resolve
# instantly. Keeps the `--auto` headless smoke test fast.
var _headless: bool = false
## Whether this unit's sprite is currently drawn. Written by MapBuilder from the
## compartment graph: units are rendered only in rooms holding a player unit.
## Deliberately coarser than a per-unit line-of-sight test — a room is a unit of
## space the player can reason about, where a raycast result is not.
var _rendered: bool = true

# The shot the muzzle-flash frame is about to draw a tracer for.
var _pending_shot: Combat.ShotResult = null
var _pending_target: Unit = null
# Which round of the burst is next, and which of them miss regardless of the
# result. Decided up front so the pattern is fixed before the first tracer.
var _burst_round: int = 0
var _burst_strays: Array[int] = []
var _name_label: Label3D = null


## Whether this unit's actions should resolve with no time on the clock.
##
## Asked FRESH at each action rather than answered once at spawn, which is the
## whole point: turn resolution awaits animations, so an unseen enemy's
## activation would otherwise burn its full wall-clock time against a completely
## static screen. Fast-forwarding it is the XCOM behaviour, and it comes out of
## the path the headless smoke test already used rather than a new one.
##
## The combat log still narrates units resolved this way. That leak is accepted:
## the log is slated for removal once the game runs smoothly, so suppressing it
## would be work spent on something being deleted.
func is_instant() -> bool:
	return _headless or not _rendered


## Called by MapBuilder when the revealed set changes. Hides the sprite, which
## also stops it being awaited — see is_instant.
func set_rendered(rendered: bool) -> void:
	if rendered == _rendered:
		return
	_rendered = rendered
	visual.visible = rendered


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	if stats == null:
		stats = UnitStats.new()
	current_hp = stats.max_hp()
	ammo = stats.mag_size
	reserve = stats.weapon.starting_reserve if stats.weapon else 0
	grid_pos = GridManager.world_to_grid(global_position)
	global_position = GridManager.grid_to_world(grid_pos)
	GridManager.set_occupant(grid_pos, self)
	_name_label = get_node_or_null("NameLabel")
	if _name_label:
		_name_label.text = stats.display_name
	visual.setup()
	visual.muzzle.connect(_on_muzzle)
	GridManager.cover_destroyed.connect(_on_cover_destroyed)
	refresh_cover_pose()  # a unit may spawn already in cover
	visual.set_flashlight_enabled(has_flashlight and flashlight_on)


func begin_activation() -> void:
	ap = ap_pool()
	# Being pinned costs AP before anything else is decided. Floored at 1 rather
	# than allowed to reach zero: a unit that loses its whole turn to suppression
	# would make the action strictly better than the stun a torso crit buys, for
	# a fraction of the setup.
	if is_suppressed():
		ap = maxi(1, ap - SUPPRESSED_AP_PENALTY)
	# THIS unit's own suppression ends when it comes back round to act — the
	# XCOM rule. Holding someone down is what it did INSTEAD of its last turn, so
	# it cannot still be doing it during this one.
	release_suppression()
	# Sec 6.3 / 4.2: both clear on this unit's next activation.
	hunkered = false
	on_overwatch = false
	overwatch_reserve = 0
	# Ordered after the clear, and it is the whole of what standing back up is:
	# `cover_pose` reads `hunkered`, so settling now resolves to the low idle for
	# a unit still behind a crate and to the standing one for a unit that was
	# only down because it hunkered. There is no rise-from-crouch transition —
	# see do_hunker for why going down has none either.
	settle_idle()
	ap_changed.emit(self)


func spend_ap(cost: int) -> void:
	ap = maxi(ap - cost, 0)
	ap_changed.emit(self)


func move_along(path: Array[Vector3i]) -> void:
	# Walks the path one tile at a time. This is a coroutine — callers MUST
	# `await` it, or the unit will still be sliding when the next action
	# resolves. The unit holds no tile mid-walk (only one unit ever moves at a
	# time), so dying to overwatch part-way leaves no tile wrongly reserved.
	if path.is_empty():
		return
	GridManager.set_occupant(grid_pos, null)
	last_moved_turn = TurnManager.turn_number
	is_busy = true
	# A one-tile hop walks rather than runs, where the character has both gaits:
	# a soldier crossing a single tile does not break into a sprint. Everything
	# else the deceleration system used to decide here died with the 3D rig —
	# a sprite has no stride to skate, so a tile is a tile.
	# `walks_only` overrides the length test rather than extending it: a shambler
	# walks a ten-tile path for the same reason it walks a one-tile one, which is
	# that it has no other gait.
	var walking := visual.has_walk() and (walks_only or path.size() == 1)
	# WALK_SPEED is the SOLDIER's walk — the speed his cycle was measured at — so
	# it is the right answer only for a unit that is walking as its slow option.
	# A unit whose walk is its only gait carries its own, and that is what
	# `move_speed` means for it.
	var speed := move_speed if walks_only else (UnitVisual.WALK_SPEED if walking else move_speed)
	# Cleared for the duration of the move: a unit crossing the deck is not using
	# the cover it started behind, and leaving the family set would have it run
	# the whole way in a crouch the moment `run_low` art exists.
	visual.set_cover_pose(&"")
	visual.set_stance(UnitVisual.WALK if walking else UnitVisual.RUN)
	var was_hidden := is_instant()
	for step in path:
		# Visibility is re-read per tile, which is what makes a unit that walks
		# into the squad's line of sight animate the REST of its move instead of
		# popping across the deck. The loop already does per-tile work for
		# lighting and overwatch, so this drops in alongside it.
		var hidden := is_instant()
		if was_hidden and not hidden:
			# Handover. Re-assert the stance from the top rather than trying to
			# join a one-shot that has been running invisibly: a walk cycle can be
			# picked up mid-stride, a reload cannot.
			visual.set_stance(UnitVisual.WALK if walking else UnitVisual.RUN)
		was_hidden = hidden
		await _step_to(GridManager.grid_to_world(step), speed)
		grid_pos = step
		if is_downed:
			break
		_trip_alarm_here()
		if has_flashlight and flashlight_on:
			# Keeps the beacon tracking mid-sprint, so an overwatcher's shot
			# below judges light as it actually was at the moment it fired.
			LightingManager.recompute_dynamic()
		# Suppression resolves BEFORE overwatch: the suppressor already had its
		# angle held on this specific unit, where an overwatcher is reacting to
		# movement in general. Both can fire on the same step.
		await TurnManager.check_suppression_break(self)
		if is_downed:
			break
		await TurnManager.check_overwatch(self)
		if is_downed:
			break
	is_busy = false
	if is_downed:
		return  # the collapse is already playing — don't stand it back up
	# Grid state is settled before the transition plays out: the unit owns its
	# destination tile from the moment it arrives, and what is left is purely
	# cosmetic — nothing downstream waits on it to know where the unit is.
	GridManager.set_occupant(grid_pos, self)
	global_position = GridManager.grid_to_world(grid_pos)
	# Turn out over whatever this tile has to hide behind before settling. MUST
	# precede the settle rather than follow it: `cover_pose` is facing-dependent,
	# so a unit that settled first would pose plain and then visibly snap into the
	# crouch a moment later.
	await snap_to_cover()
	if walking:
		# A walk is already at rest by the time it ends, so it settles straight
		# into idle rather than through a stop.
		settle_idle()
	else:
		# Refreshed before the stop plays, so arriving at a crate resolves as
		# `run_stop_low` — getting INTO cover — the moment that art exists, and
		# falls through to the plain skid until then.
		refresh_cover_pose()
		await visual.play_stance_exit(UnitVisual.RUN_STOP, UnitVisual.IDLE)
	moved.emit(self)


## Sets off an alarm panel this unit has just stepped onto (Sec 6 trigger 2).
##
## Aliens are exempt, and it is not a courtesy: the panel is ship security, so
## the things that live here are what it is FOR. A shambler wandering across one
## and calling in the whole deck on itself would be nonsense, and would also make
## the trap fire long before the squad ever reached it.
##
## Fires once. Clearing the flag is what stops a corridor becoming a siren the
## player can re-trigger by pacing, or — worse — that a patrolling robot re-trips
## every turn on its way back to its post.
func _trip_alarm_here() -> void:
	if faction == Faction.Id.ALIENS:
		return
	var tile: GridTileData = GridManager.get_tile(grid_pos)
	if tile == null or not tile.alarm:
		return
	tile.alarm = false
	AlienHivemind.report_alarm(grid_pos, self)


func _step_to(target: Vector3, speed: float) -> void:
	var dist := global_position.distance_to(target)
	if dist < 0.001:
		return
	if is_instant():
		global_position = target
		return
	var seconds := dist / speed
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "global_position", target, seconds)
	_tween_yaw(tween, target, seconds)
	await tween.finished


## Adds the turn toward `target` to a parallel movement tween, `seconds` long.
##
## Both guards are about that parallel: `finished` waits for the LONGEST branch,
## so a fixed 0.09s turn would hold up any leg shorter than that.
func _tween_yaw(tween: Tween, target: Vector3, seconds: float) -> void:
	var yaw := _yaw_toward(target)
	if is_nan(yaw) or absf(yaw - rotation.y) < 0.001:
		return  # already facing it: every leg of a straight path
	tween.tween_property(self, "rotation:y", yaw, minf(TURN_TIME, seconds))


func _yaw_toward(world_pos: Vector3) -> float:
	# Godot forward is -Z. Returns the short way round rather than unwinding
	# through a full turn, or NAN when the point is directly underfoot.
	#
	# QUANTISED to the eight grid directions, and that is a hard requirement
	# rather than a tidiness one: a character is drawn in eight directions
	# (UnitVisual.DIRECTIONS), so a unit holding a yaw between two of them has no
	# art to show and the sprite layer hides itself. Movement already produces
	# quantised yaws — GridManager.STEPS sees to that — but `face_toward` is
	# driven by a raw mouse click, and that is the case this catches.
	var delta := world_pos - global_position
	if absf(delta.x) <= 0.001 and absf(delta.z) <= 0.001:
		return NAN
	var target := snappedf(atan2(-delta.x, -delta.z), PI / 4.0)
	return rotation.y + wrapf(target - rotation.y, -PI, PI)


func face_toward(world_pos: Vector3) -> void:
	# Turn in place. Coroutine — callers MUST `await`. Matters beyond looking
	# right: the flashlight cone rotates with facing (Sec 5.2), so which tiles
	# this unit lights, and therefore which aliens notice it, follow from here.
	var yaw := _yaw_toward(world_pos)
	if is_nan(yaw):
		return
	if is_instant():
		rotation.y = yaw
	else:
		is_busy = true
		var tween := create_tween()
		tween.tween_property(self, "rotation:y", yaw, TURN_TIME * 2.0)
		await tween.finished
		is_busy = false
	# Which cover a unit is using follows from where it looks (MIN_FACING_DOT), so
	# a turn in place can put it into cover or take it out of one without it
	# having moved a tile. This is also what gets fire_at right: it turns onto its
	# target before the burst, so the step-out plays for the cover the unit is
	# actually shooting over.
	refresh_cover_pose()
	if has_flashlight and flashlight_on:
		# Same guard move_along uses: the cone has swung, so what it lights (and
		# what notices being lit) has to be recomputed before anything else acts.
		LightingManager.recompute_dynamic()


## What actually gets through this unit's plating, given a raw damage roll. The
## armor hook (security robots: `CerberusUnit.damage_taken`), sited here so it
## applies to every damage source rather than only to gunfire, and so the
## unarmored default costs one function call and no branching.
func damage_taken(amount: int) -> int:
	return amount


## Whether the light on this unit's tile is a term in accuracy rolls it takes
## part in. False only for the security robots, whose sensors do not read light
## at all — see CerberusUnit.light_agnostic and Combat.compute_accuracy.
func light_agnostic() -> bool:
	return false


## The cover penalty THIS unit's weapon respects, as a shooter. Overridden by a
## unit whose weapon partly ignores cover (Sagittarii); read by
## Combat.compute_accuracy so the HUD's preview and the shot itself agree.
func cover_penalty_for(cover_type: int) -> int:
	return Combat.cover_penalty(cover_type)


# --- Cover posture -----------------------------------------------------------
#
# COSMETIC ONLY. Cover's effect on a shot is decided by the tile edge the shot
# crosses (Combat.compute_accuracy via GridManager.cover_type_on), and nothing
# below is an input to it. A unit gets its cover bonus whether or not it is
# posed as if using cover, which is what makes it safe to let the art land one
# pose at a time.

## Cover tier -> the UnitVisual pose family that tier is drawn as. Light cover is
## crouched behind; heavy is stood pressed against the edge of it.
##
## TEMPORARY: heavy is pointed at COVER_LOW rather than COVER_HIGH so both tiers
## exercise the crouched art while the cover set is being proved out. Restore
## `UnitVisual.COVER_HIGH` on the HEAVY row to get the two distinct stances back.
const COVER_FAMILY := {
	MapData.Cover.LIGHT: UnitVisual.COVER_LOW,
	MapData.Cover.HEAVY: UnitVisual.COVER_LOW,
}

## How far toward a covered side the unit must already be looking for that cover
## to be the one it hugs.
##
## The gate is what keeps this from being a gameplay change. Facing drives the
## flashlight cone and the cone drives what notices the unit (Sec 5.2), so
## turning a unit to face out of its cover would move detection — instead the
## unit hugs cover only where its own facing already points out over it, and a
## soldier standing beside a crate looking down the wall stays posed plain.
##
## 0.7: facing is quantised to eight directions and cover sides are the four
## cardinals, so the reachable dot products are 0, ±0.707 and ±1. This admits the
## cardinal itself and the two diagonals either side of it, and nothing else.
const MIN_FACING_DOT := 0.7


## Which covered side this unit is using, or -1 for none. The side it is most
## looking OUT over — a soldier uses the crate the threat is on the far side of
## — with ties going to the heavier cover.
func _best_cover_side() -> int:
	var forward := Vector3(-sin(rotation.y), 0.0, -cos(rotation.y))
	var best := -1
	var best_score := -1.0
	var best_tier := MapData.Cover.NONE
	for side in GridManager.covered_sides(grid_pos):
		var score := forward.dot(Vector3(MapData.SIDE_STEP[side]))
		if score < MIN_FACING_DOT:
			continue
		var tier := GridManager.cover_type_on(grid_pos, side)
		if score > best_score or (is_equal_approx(score, best_score) and tier > best_tier):
			best = side
			best_score = score
			best_tier = tier
	return best


## The covered side to turn out over on arrival, or -1 for none. Heaviest cover
## first, then whichever needs the SMALLEST turn — so a unit that ran east into a
## corner covered on two sides keeps looking the way it was already going rather
## than spinning to an equally good crate behind it.
##
## Deliberately ungated, unlike `_best_cover_side`: that one asks "is this unit
## using cover", and the answer has to be no for a soldier facing the wrong way.
## This one asks "which cover should it turn to use", where facing is the thing
## being decided rather than an input to it.
func _cover_side_to_face() -> int:
	var forward := Vector3(-sin(rotation.y), 0.0, -cos(rotation.y))
	var best := -1
	var best_tier := MapData.Cover.NONE
	var best_score := -INF
	for side in GridManager.covered_sides(grid_pos):
		var tier := GridManager.cover_type_on(grid_pos, side)
		var score := forward.dot(Vector3(MapData.SIDE_STEP[side]))
		if tier > best_tier or (tier == best_tier and score > best_score):
			best = side
			best_tier = tier
			best_score = score
	return best


## Turns the unit to look out over the cover it has arrived at, XCOM-style.
## Coroutine — callers MUST `await`. A no-op on a tile with no cover, which
## leaves the unit facing the way it was travelling.
##
## Unlike everything else in this section this is NOT cosmetic, and it is worth
## being blunt about why: facing aims the flashlight, the flashlight decides what
## is lit, and what is lit decides both which aliens notice this unit and how
## accurate the shots into that light are (Sec 5.2). Moving into cover therefore
## now changes what the squad can see and what can see it.
##
## Routed through `face_toward` precisely so none of that is bypassed — it
## recomputes the lighting exactly as any other turn does, rather than writing
## `rotation.y` behind the system's back and leaving the light pointing at where
## the unit used to look.
func snap_to_cover() -> void:
	var side := _cover_side_to_face()
	if side < 0:
		return
	await face_toward(GridManager.grid_to_world(grid_pos + MapData.SIDE_STEP[side]))


## The pose family this unit's tile, cover, facing and posture put it in, or ""
## for none.
func cover_pose() -> StringName:
	# A body on the deck is its own read and must not be posed as using cover.
	if is_downed:
		return &""
	var family: StringName = &""
	var side := _best_cover_side()
	if side >= 0:
		family = COVER_FAMILY.get(GridManager.cover_type_on(grid_pos, side), &"")
	# Hunkering is NOT excluded here, unlike downing — and in the open it SUPPLIES
	# the family rather than merely surviving it. Being down low is the whole of
	# what the action is, and `idle_low` is the art for a soldier down low, crate
	# or no crate; without this line a hunker on an uncovered tile resolves to the
	# standing idle and reads as having done nothing.
	#
	# Cover the unit is actually behind still wins, so hunkering never demotes a
	# high pose to a low one. This is cosmetic only either way: the accuracy
	# penalty is Combat's HUNKER_PENALTY off the `hunkered` flag, and the cover
	# bonus is a property of the tile edge a shot crosses, so no answer here can
	# move a number.
	if family == &"" and hunkered:
		return UnitVisual.COVER_LOW
	return family


## Recomputes the cover posture and pushes it to the sprite. Cheap, and safe to
## call at any point — it re-resolves what is on screen without restarting it.
func refresh_cover_pose() -> void:
	visual.set_cover_pose(cover_pose())


## Settles into idle in whatever posture the unit's current tile and facing call
## for. THE one answer to "what does standing still look like right now" — every
## path that ends in a unit at rest goes through here, so a new resting state can
## never be added that forgets about cover.
func settle_idle() -> void:
	refresh_cover_pose()
	visual.set_stance(UnitVisual.IDLE)


func _on_cover_destroyed(pos: Vector3i, side: int, _tier: int) -> void:
	# An edge is shared by the two tiles it separates, and the signal names only
	# one of them — so a unit on the far side is equally affected and has to check
	# both. Without this a soldier whose crate is shot apart keeps crouching
	# behind a piece of cover that no longer exists.
	if pos != grid_pos and pos + MapData.SIDE_STEP[side] != grid_pos:
		return
	if is_downed:
		return
	refresh_cover_pose()


## Returns the damage that actually landed, after `damage_taken` — callers use it
## to report what happened rather than what was rolled, so an armored target's
## log line does not claim 12 damage when 4 got through.
func take_damage(amount: int) -> int:
	amount = damage_taken(amount)
	current_hp = maxi(current_hp - amount, 0)
	hp_changed.emit(self)
	if current_hp == 0 and not is_downed:
		is_downed = true
		on_overwatch = false
		stunned = false
		# A corpse holds nobody down. `is_suppressed` also guards against a dead
		# suppressor, so this is belt-and-braces — but it clears the back-link too,
		# which that guard cannot.
		release_suppression()
		GridManager.set_occupant(grid_pos, null)
		if _name_label:
			_name_label.visible = false
		# Deliberately not awaited: the unit is out of the fight the moment its
		# HP hits zero, and the shooter's own activation shouldn't stall on the
		# collapse playing out. (ActiveMarker self-hides off is_downed.)
		visual.play_action(UnitVisual.DOWNED)
		# A body is evidence a Proctor can find long after the fight that made it
		# (security-robots/design-choices/detection-and-network-alert.md). Reported
		# for every unit, robots included: a wrecked machine is as much a sign
		# something came through here as a corpse is.
		SecurityNetwork.report_evidence(grid_pos, SecurityNetwork.Evidence.CORPSE)
		downed.emit(self)
	elif not is_downed:
		# No flinch: a unit that survives a hit just holds whatever idle its tile
		# and facing call for. Deliberate and temporary — HIT_REACT exists in the
		# vocabulary and there is placeholder art for it, but there is no authored
		# merc flinch yet, so playing it would resolve through the fallback chain
		# to a pose that reads as nothing happening while still costing the beat
		# FALLBACK_TIME charges for it. Settling is at least honest about that.
		#
		# Restoring it is one line: swap this for the play_action call. Do that
		# once `hit_react` is drawn, and draw `hit_react_low` alongside it — a
		# soldier flinching behind a crate should not stand up to do it.
		settle_idle()
	return amount


## Whether this unit will engage `other`. THE hostility test — every targeting
## path, and Overwatch's trigger, goes through here rather than comparing sides
## by hand, so which relationships exist is stated in exactly one file.
##
## Asked of the OBSERVER, since `Faction.HOSTILE_TO` allows one-way
## relationships: `a.is_hostile_to(b)` and `b.is_hostile_to(a)` are two questions
## and may legitimately disagree.
func is_hostile_to(other: Unit) -> bool:
	return other != null and Faction.is_hostile(faction, other.faction)


## Every other living unit on this unit's own side. The counterpart to
## `hostiles`, and the thing squad reasoning is built on — "is there anybody left
## to exploit the window I am about to open".
func allies() -> Array[Unit]:
	var out: Array[Unit] = []
	for node in get_tree().get_nodes_in_group("units"):
		var other := node as Unit
		if other != null and other != self and not other.is_downed and other.faction == faction:
			out.append(other)
	return out


## Every living unit this one would engage. Replaces the `player_units` /
## `enemy_units` group lookups that hostility used to be read off, which could
## only ever describe a two-sided fight.
func hostiles() -> Array[Unit]:
	var out: Array[Unit] = []
	for node in get_tree().get_nodes_in_group("units"):
		var other := node as Unit
		if other != null and not other.is_downed and is_hostile_to(other):
			out.append(other)
	return out


## Narrates something this unit did, for the combat log.
##
## A no-op on the base class, overridden by the types that own an
## `action_logged` signal. Exists so the GOAP action library — which is written
## against `Unit` and must serve three factions — can report what it did without
## knowing which subclass it is driving, or whether that subclass logs at all.
func report_action(_text: String) -> void:
	pass


## Damage this unit does to a cover edge it deliberately fires ON, as opposed to
## the incidental chipping every shot causes (Sec 6.1.1). Its own weapon damage
## by default; the Cerberus cover-breaker overrides it upward, which is the whole
## of what makes that unit a cover-breaker.
func cover_breaking_damage() -> int:
	return stats.weapon_damage


## Whether this unit has taken enough damage to start caring about its own skin.
## Half its Max HP, which is also where the Sec 4.2.1 torso injury threshold
## sits — a soldier that has lost half of itself is the same soldier the injury
## system already considers to be in trouble.
func is_hurt() -> bool:
	return current_hp * 2 <= stats.max_hp()


func is_suppressed() -> bool:
	# The link is only real while the shooter is: a dead suppressor holds nobody
	# down, and checking here rather than hunting for every way a unit can die
	# means no path can leave a corpse pinning somebody.
	return suppressed_by != null and not suppressed_by.is_downed


## Needs a full burst in the magazine, not just a round. Suppression is volume
## of fire — a soldier with two bullets left cannot lay any down.
func can_suppress() -> bool:
	return ammo >= SUPPRESS_AMMO_COST


## Sec 4.2 + the coordinated-AI doc's `Suppress` action. ENDS the activation, as
## Hunker and Overwatch do, and for the same reason `_end_activation_ap` gives:
## the unit is committing the rest of its turn to holding an angle.
##
## Coroutine — callers MUST await. The burst that opens it is played rather than
## implied, so suppression starts on screen the way any other shot does.
func do_suppress(target: Unit) -> void:
	if target == null or target.is_downed:
		return
	ammo -= SUPPRESS_AMMO_COST
	# Replace whatever this unit was pinning before. One weapon, one direction.
	release_suppression()
	suppressing = target
	target.suppressed_by = self
	_end_activation_ap()
	is_busy = true
	await face_toward(target.global_position)
	await visual.play_burst(SUPPRESSION_BURST_ROUNDS)
	is_busy = false
	# Deliberately NOT awaited: the covering fire runs for as long as the
	# suppression does, which is until this unit's next activation — awaiting it
	# would hang the turn loop forever.
	_suppression_fire_loop()


## Cosmetic covering fire, one burst every SUPPRESSION_BURST_GAP seconds for as
## long as this unit is holding someone down.
##
## Resolves NOTHING. It spends no ammo, rolls no accuracy and deals no damage —
## the three rounds and the single decision were paid for in `do_suppress`, and
## a loop that fired real shots on a wall-clock timer would let a unit kill
## things between activations.
##
## Skipped entirely when the unit is off screen or headless (`is_instant`), where
## there is nobody to show it to and the timer would just burn turn time.
func _suppression_fire_loop() -> void:
	while suppressing != null and not is_downed and is_inside_tree():
		if is_instant():
			return
		await get_tree().create_timer(SUPPRESSION_BURST_GAP).timeout
		# Re-checked after the wait: three seconds is long enough for the
		# suppression to have ended, or for either party to have died.
		if suppressing == null or is_downed or is_busy or not is_inside_tree():
			return
		await visual.play_burst(SUPPRESSION_BURST_ROUNDS)


## Drops the suppression this unit is APPLYING, if any. Safe to call at any time
## and on a unit suppressing nobody.
func release_suppression() -> void:
	if suppressing == null:
		return
	if suppressing.suppressed_by == self:
		suppressing.suppressed_by = null
	suppressing = null


func can_shoot() -> bool:
	return ammo > 0


func can_reload() -> bool:
	return ammo < stats.mag_size and (reserve < 0 or reserve > 0)


## This unit's AP pool for one activation. Wraps `stats` so a type that wants a
## pool its stat block does not describe has one place to say so.
func ap_pool() -> int:
	return stats.ap_pool()


func action_cost(action: UnitStats.Action) -> int:
	return stats.action_cost(action)


func aimed_shot_cost(body_part: int) -> int:
	return Combat.aimed_shot_ap_cost(body_part, stats.reflexes)


## The cheapest zone this unit could aim at — the Torso, always. What gates the
## Aimed Shot BUTTON, since the zone is not picked until after it is pressed.
func min_aimed_shot_cost() -> int:
	return aimed_shot_cost(Combat.BodyPart.TORSO)


## What one tile costs THIS unit right now. MOVE_AP_PER_TILE for everybody
## intact; more for a unit walking on an injured leg.
##
## This is where Sec 4.2.1's "-33% movement range per injured leg" now lives.
## That penalty used to scale a Run/Sprint tile allowance, and the allowance is
## what the flat-AP rework deleted — so the same 33% is inverted into the cost of
## a step instead of the number of them. It stays a MOVEMENT penalty either way,
## which is the point: routing it through the AP pool instead would have quietly
## made a leg wound cost the unit shots and reloads as well.
##
## Integer AP per tile means the realised cut is coarser than 33%: one leg lands
## on 2 AP/tile (half range, not a third off) and two legs on 3. That is the Sec
## 4.3b cost rule doing its job — costs round up — and the two-leg case comes out
## almost exactly on the old number anyway.
func move_ap_per_tile() -> int:
	var legs := _injured_leg_count()
	if legs == 0:
		return MOVE_AP_PER_TILE
	return ceili(MOVE_AP_PER_TILE / maxf(1.0 - LEG_INJURY_SPEED_PENALTY * legs, 0.01))


## How many tiles this unit can still afford to walk.
func move_tiles_affordable() -> int:
	return ap / move_ap_per_tile()


func move_cost_for(tiles: int) -> int:
	return tiles * move_ap_per_tile()


func ranged_accuracy_penalty() -> int:
	return ARM_RANGED_ACC_PENALTY * _injured_arm_count()


func melee_accuracy_penalty() -> int:
	return ARM_MELEE_ACC_PENALTY * _injured_arm_count()


## Situational accuracy this unit gains against a specific target in melee. Zero
## for everyone except the Agile Hunter, whose ambush bonus (Sec 11.5) is the one
## case where WHO is being struck changes how well the swing lands.
##
## Sited beside `melee_accuracy_penalty` and read from the same place in
## `Combat.compute_melee_accuracy`, so the bonus reaches the previewed number and
## the rolled one through one code path rather than two that can disagree.
func melee_accuracy_bonus(_target: Unit) -> int:
	return 0


func melee_damage_multiplier() -> float:
	return pow(ARM_MELEE_DMG_MULT, _injured_arm_count())


func is_part_injured(part: int) -> bool:
	return _injured_parts.get(part, false)


func injured_summary() -> String:
	var names: Array[String] = []
	for part in _injured_parts:
		if _injured_parts[part]:
			names.append(Combat.body_part_name(part))
	return ", ".join(names) if not names.is_empty() else "None"


func apply_body_part_damage(part: int, amount: int) -> bool:
	# Accumulates raw damage against this part's own threshold (Sec 4.2/6.5).
	# Returns true the first time this hit pushes it over the threshold —
	# callers use that to log "X's Y is injured!" only once, on the hit that did it.
	_body_part_damage[part] = _body_part_damage.get(part, 0) + amount
	if _injured_parts.get(part, false):
		return false
	if _body_part_damage[part] >= _body_part_threshold(part):
		_injured_parts[part] = true
		return true
	return false


func heal_injury(part: int) -> void:
	# Hook for a future medical-resource action (GDD Sec 4.4) — not yet wired to
	# any action or UI. Clears the injury and resets its damage counter.
	_injured_parts[part] = false
	_body_part_damage[part] = 0


func _body_part_threshold(part: int) -> int:
	return maxi(1, roundi(stats.max_hp() * PART_HP_FRACTION.get(part, 0.35)))


func _injured_leg_count() -> int:
	var n := 0
	if is_part_injured(Combat.BodyPart.LEG_L):
		n += 1
	if is_part_injured(Combat.BodyPart.LEG_R):
		n += 1
	return n


func _injured_arm_count() -> int:
	var n := 0
	if is_part_injured(Combat.BodyPart.ARM_L):
		n += 1
	if is_part_injured(Combat.BodyPart.ARM_R):
		n += 1
	return n


func fire_at(target: Unit, action: Combat.ShotAction, body_part: int = Combat.BodyPart.TORSO) -> Combat.ShotResult:
	# Coroutine — callers MUST `await`. Damage lands when the shot animation
	# finishes, so the target drops in time with the effect, not before it.
	# Swing onto the target before anything else. The weapon points where the
	# body faces, so firing without this sprays the burst off toward whatever
	# direction the last move left — and face_toward also swings the flashlight,
	# which changes what is lit before the shot resolves.
	await face_toward(target.global_position)
	# No vertical aim. A sprite has no spine to tilt, so a shot at a target on
	# another deck reads flatter than it did; if that comes back it will be
	# per-pitch-band art on an arm layer, not a bone solve.
	ammo -= 1
	var result := Combat.resolve_shot(self, target, action, body_part)
	is_busy = true
	var rounds := randi_range(BURST_MIN, BURST_MAX)
	_pending_shot = result
	_pending_target = target
	_burst_round = 0
	_burst_strays = _pick_strays(rounds, result.hit)
	await visual.play_burst(rounds)  # emits `muzzle` once per round
	_pending_shot = null
	_pending_target = null
	if result.hit:
		# The raw roll is kept because two different consumers want two different
		# numbers: HP takes what got through the target's armor, while a component
		# pool (Securus's head) takes the roll itself — a weak point the unit's own
		# plating covers would not be one. `result.damage` ends up holding what
		# actually landed, so every log line reports the real figure.
		var raw := result.damage
		result.damage = target.take_damage(raw)
		result.absorbed = raw - result.damage
		if action == Combat.ShotAction.AIMED_SHOT and not target.is_downed:
			result.newly_injured = target.apply_body_part_damage(body_part, raw)
			if result.stunned:
				target.stunned = true
	# Sec 5.4: gunfire is loud, and it leaves brass. The first is what the robot
	# faction shares with the (deferred) alien sound channel; the second is what
	# only a Proctor ever reads, turns later.
	SecurityNetwork.report_noise(grid_pos, self)
	SecurityNetwork.report_evidence(grid_pos, SecurityNetwork.Evidence.BRASS)
	is_busy = false
	return result


func _pick_strays(rounds: int, hit: bool) -> Array[int]:
	# A miss throws everything wide. A hit still throws one or two away, because
	# a burst where every round lands in the same spot reads as a single shot.
	var strays: Array[int] = []
	if not hit:
		for i in rounds:
			strays.append(i)
		return strays
	var pool: Array[int] = []
	for i in rounds:
		pool.append(i)
	pool.shuffle()
	return pool.slice(0, randi_range(1, BURST_STRAY_MAX))


func melee_at(target: Unit) -> Combat.ShotResult:
	# Coroutine — callers MUST `await`. Mirrors fire_at: damage lands when the
	# animation finishes, so the target reacts in time with the swing rather than
	# before it. No ammo is spent and no tracer is drawn — nothing left the unit.
	var result := Combat.resolve_melee(self, target)
	is_busy = true
	await visual.play_action(UnitVisual.MELEE)
	if result.hit:
		if not is_instant():
			var vfx := get_tree().get_first_node_in_group("vfx")
			if vfx:
				vfx.impact(target.global_position, result.crit)
		var raw := result.damage
		result.damage = target.take_damage(raw)
		result.absorbed = raw - result.damage
	is_busy = false
	return result


func _on_muzzle() -> void:
	# One of these per round of the burst, fired by UnitVisual.play_burst.
	if is_instant() or _pending_shot == null or _pending_target == null:
		return
	var round_index := _burst_round
	_burst_round += 1
	var vfx := get_tree().get_first_node_in_group("vfx")
	if vfx == null:
		return
	# Origin is the barrel tip as the animation currently has it, not the middle
	# of the unit — the rifle is held off to the right, so a centreline tracer
	# visibly left the chest.
	var from := visual.muzzle_origin()
	var lands := _pending_shot.hit and round_index not in _burst_strays
	vfx.tracer(from, _pending_target.global_position, lands, _pending_shot.crit)
	vfx.muzzle_flash(from)


## Sec 6.3. ENDS the activation: see `_end_activation_ap` for why the leftover AP
## goes with it.
func do_hunker() -> void:
	hunkered = true
	_end_activation_ap()
	# The hunker IS a pose, not a move into one. `cover_pose` answers COVER_LOW
	# for any hunkered unit, so settling into idle resolves to `idle_low` whether
	# or not there is a crate to get behind — one line, and the same one every
	# other resting state goes through.
	#
	# No stand-to-crouch transition: that was the 3D rig's, where a Mixamo clip
	# existed to bridge two mocap stances. The drawn set has no `stand_to_crouch`
	# and is not getting one, so the drop is a cut, and do_hunker stays a plain
	# function with nothing to await.
	settle_idle()


## Sec 4.2. ENDS the activation, as `do_hunker` does — see `_end_activation_ap`.
##
## `reserve_ap` is how much of what is left the unit commits to the reserved shot
## (rework doc Sec 4.4), replacing the old flat 1 AP price. Callers pass -1 for
## "all of it", which is the sane default AND now a real choice: the reserve
## scales the reaction shot's accuracy (`Combat.overwatch_penalty_for`), so
## reserving late in an activation with 1 AP left covers an angle far worse than
## committing a full turn to it.
func do_overwatch(reserve_ap: int = -1) -> void:
	on_overwatch = true
	overwatch_reserve = ap if reserve_ap < 0 else clampi(reserve_ap, 1, ap)
	_end_activation_ap()
	# Holding an angle from behind a crate is a different pose from holding one in
	# the open. Falls through to the plain hold until `overwatch_hold_low` exists.
	refresh_cover_pose()
	visual.set_stance(UnitVisual.OVERWATCH)


## Burns whatever AP is left, because the action that called it ends the unit's
## turn outright rather than costing a fixed slice of it.
##
## Hunker and Overwatch are both "I am done, and I am spending the rest of this
## turn watching" — reserving an angle you then walk away from is not a reserved
## angle, and neither is ducking behind a crate to pop out and shoot on the same
## activation. So the listed cost is a FLOOR, not the price: any remainder is
## forfeited. Under the granular pool that remainder is a much bigger number than
## it was at 2 AP, which is the whole reason both actions are worth taking LAST.
##
## Lives on Unit, called by the two actions themselves rather than by their
## callers, so no path can take the posture without ending the turn — not the
## HUD, not the security-robot AI. Both sides then stop on their own: the AI
## loops all run `while ap > 0`, and PlayerUnit._check_activation_end closes the
## activation on the zero. Routed through `spend_ap` so `ap_changed` still fires
## and the HUD greys out immediately.
func _end_activation_ap() -> void:
	spend_ap(ap)


func do_reload() -> void:
	# Coroutine, unlike the other two — callers MUST `await`, or the unit will
	# still be reloading on screen when its next action resolves. Draws from
	# `reserve` (spare rounds beyond the loaded mag); reserve < 0 means
	# unlimited, so it's never decremented — see WeaponData.starting_reserve.
	var needed := stats.mag_size - ammo
	var drawn := needed
	if reserve >= 0:
		drawn = mini(needed, reserve)
		reserve -= drawn
	ammo += drawn
	is_busy = true
	await visual.play_action(UnitVisual.RELOAD)
	is_busy = false


func toggle_flashlight() -> void:
	# Free action (0 AP, Sec 4.2) — on for detection range, off to stay dark.
	if not has_flashlight:
		return
	flashlight_on = not flashlight_on
	visual.set_flashlight_enabled(flashlight_on)
	LightingManager.recompute_dynamic()
