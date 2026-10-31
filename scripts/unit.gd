class_name Unit
extends Node3D
## Base unit: stats, HP/AP/ammo state, shared actions. Sec 4.2 AP economy.

signal hp_changed(unit: Unit)
signal ap_changed(unit: Unit)
## The rounds in hand or in reserve changed, whatever changed them, on every peer:
## a replicated value comes through the same setters. For the model's ammo readout.
signal ammo_changed(unit: Unit)
## The unit left the fight: ACTIVE -> DOWNED, or ACTIVE -> DEAD for a type that
## dies outright (GDD §4.4). Kept meaning "out of action" rather than "downed
## specifically", because every listener (a squad blackboard releasing claims, a
## robot paying out salvage) cares that the unit stopped fighting, not how.
signal downed(unit: Unit)
## The unit became a corpse: from ACTIVE (killed outright) or from DOWNED (bled
## out, finished off, third down). Fires after `downed` on an outright kill.
signal died(unit: Unit)
## A DOWNED unit was brought back up (Unit.revive_at).
signal revived(unit: Unit)
## What this unit is carrying, or who is carrying it, changed (pick up / drop /
## auto-drop). Fired on every peer, for the HUD.
signal carry_changed(unit: Unit)
signal moved(unit: Unit)
## Fired once per TILE of a walk, after `grid_pos` has been updated to it — where
## `moved` fires once, when the whole walk has settled. For the things that care
## about where a unit has BEEN rather than where it stopped: hangar discovery
## (ExtractionManager) is the first.
signal stepped(unit: Unit)

## AP per tile of movement (rework doc Sec 4.1). FLAT, for every unit regardless
## of stats: Fitness buys a bigger pool, not cheaper steps, and a diagonal costs
## the same one AP a cardinal does because the grid is eight-way at uniform cost
## (Sec 4.0 — GridManager.get_reachable_tiles is a BFS for exactly this reason).
##
## The only things that raise it are injury (see `move_ap_per_tile`) and the
## worm and its mass, which override it outright — see `WormUnit.move_ap_per_tile`
## and `WormUnit.AP_POOL` for why, and for the tier ladder the override buys.
const MOVE_AP_PER_TILE := 1
const TURN_TIME := 0.09  # seconds to swing toward the next tile

# Rounds per burst. One trigger pull is still one Combat.resolve_shot — one hit
# roll, one damage number, one round of ammo — so this is purely how many
# kicks and impacts that shot draws, and changing it cannot unbalance anything.
#
# Raised from 3-5 to buy the muzzle flash more time on screen. The flash lasts
# one BURST_CADENCE (0.11 s) a round, so the only dial that makes a burst read
# as a burst is how many times it repeats.
const BURST_MIN := 4
const BURST_MAX := 6
# On a hit, this many rounds are thrown wide anyway so the burst reads as a
# burst; the rest converge. On a miss every round misses. Kept below BURST_MIN
# so a hit always lands visibly more rounds on target than it throws away.
const BURST_STRAY_MAX := 2

@export var stats: UnitStats

## Which side this unit is on. THE input to every hostility decision — see
## `is_hostile_to`, and `Faction` for why this replaced a boolean.
@export var faction: Faction.Id = Faction.Id.ALIENS

## "This is a PlayerUnit" — a soldier a human drives. Derived and READ-ONLY, for
## the paths that genuinely mean "the player's own unit" rather than "on the
## player's side": the squad-wipe tally, input handling, the HUD. Those are about
## who is holding the mouse, not about who shoots whom.
##
## It used to be `faction == CONTRACTORS`, and the two stop coinciding with the
## extraction work: the door gun (EXTRACTION_PLAN Phase 5) and an escorted VIP
## (Phase 6) are Contractor-side units nobody controls. A question that means
## "is this on the squad's side" asks `faction` (or `is_hostile_to`) instead —
## see the audit note in turn_manager.gd's `_check_end_conditions`.
##
## Answered by a virtual (`_is_player_unit`) rather than `self is PlayerUnit`:
## naming the subclass from its own base would make unit.gd and player_unit.gd a
## compile-time cycle for no benefit.
##
## Read-only on purpose: it used to be the field that got assigned, so making it
## unassignable is what guarantees no path still sets sides the old way.
var is_player_controlled: bool:
	get: return _is_player_unit()


## Overridden to true by PlayerUnit, and nowhere else. See `is_player_controlled`.
func _is_player_unit() -> bool:
	return false

## Which human peer this unit belongs to in co-op — orthogonal to `faction`,
## which is still just "whose side." 0 means host/unowned: every AlienUnit,
## and any PlayerUnit before squad assignment has run. Assigned once, at squad
## spawn (see main.gd), by the host; never touched client-side.
@export var owner_peer_id: int = 0

## True on a peer whose local player is the human sitting at this unit's
## controls. In singleplayer (no multiplayer peer active) every unit reads as
## locally owned, so this is safe to gate input on unconditionally rather than
## branching the whole input path on "are we networked at all."
func is_owned_by_local_player() -> bool:
	if not multiplayer.has_multiplayer_peer():
		return true
	return owner_peer_id == multiplayer.get_unique_id()

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
var ammo: int:
	set(value):
		if value != ammo:
			ammo = value
			ammo_changed.emit(self)
# Spare rounds beyond the loaded magazine. -1 means unlimited (never
# decremented by do_reload) — see WeaponData.starting_reserve. Assigning it means
# "this many rounds, freshly packed": it re-deals `reserve_mags` into full ones.
var reserve: int = -1:
	set(value):
		if value != reserve:
			reserve = value
			var weapon := stats.active_weapon() if stats else null
			reserve_mags = weapon.packed_mags(value) if weapon else PackedInt32Array()
			ammo_changed.emit(self)
## The rounds in each spare magazine, fullest first, empties kept: `reserve` split
## into what a reload actually swaps. Empty for a reserve that is not magazines
## (unlimited, or the Shotgun's loose shells), which reloads from `reserve` alone.
var reserve_mags := PackedInt32Array():
	set(value):
		if value != reserve_mags:
			reserve_mags = value
			ammo_changed.emit(self)

## Where a unit stands between fighting and gone (GDD §4.4).
##   ACTIVE  in the fight: in the pool, a target, a body that blocks a tile.
##   DOWNED  out of the fight but not dead — revivable, carriable, bleeding out.
##           Only a unit that `can_be_downed` (PlayerUnit) ever gets here.
##   DEAD    a corpse, or (WormUnit.dissolve) a unit that left the board. A
##           corpse stays on the map, holds no tile, takes no damage, and can be
##           carried (and, extraction plan Phase 3, looted).
##
## Transitions, and the only functions that make them (all host-side):
##   ACTIVE -> DOWNED  take_damage, at 0 HP, when can_be_downed and this is not
##                     the third down (`MAX_DOWNS`)
##   ACTIVE -> DEAD    take_damage at 0 HP otherwise, via die()
##   DOWNED -> DEAD    take_damage / bleed_out_tick emptying `downed_hp`, via die()
##   DOWNED -> ACTIVE  revive_at
enum LifeState { ACTIVE, DOWNED, DEAD }

## THE life-state field, and the one that replicates. Written only through
## `_set_life_state` (and WormUnit.dissolve), so every change also runs the
## presentation for it — see `_present_life_state`.
var life_state: LifeState = LifeState.ACTIVE

# --- Downed bar, death and carrying (GDD §4.4, extraction plan 2.1–2.3) -------

## Whether this unit goes DOWNED at 0 HP rather than dying. True on PlayerUnit
## only (set in its `_init`): GDD §4.4 "Downed applies to player contractors
## only" — mercs, aliens and robots die outright, with no bleed-out. A plain var
## rather than a virtual so a future escorted VIP (Phase 6) can opt in or out per
## spawn without a subclass.
var can_be_downed: bool = false

## The downed bar's size as a fraction of max HP: "the same size as their max HP,
## for now" (GDD §4.4). Named so a medical upgrade or a tougher class has one
## number to move.
const DOWNED_BAR_FRACTION := 1.0
## What the downed bar loses at the start of every round: 1/5 of max HP, so a full
## bar is five rounds to live (GDD §4.4 default). Rounded UP (`bleed_amount`), so
## a small soldier never bleeds slower than the fraction says.
const DOWNED_DRAIN_FRACTION := 0.2
## The down that kills: the THIRD time a soldier goes down in one mission they die
## on the spot instead (GDD §4.4). Counted from 1, so 3 means two survivable downs.
const MAX_DOWNS := 3
## The HP a revive brings a soldier back up at, as a fraction of max HP, rounded
## UP (GDD §4.4 default 25%). Low on purpose: revived is "back on their feet",
## not "back in the fight at full strength".
const REVIVE_HP_FRACTION := 0.25
## The chance a LANDED hit on a carrier who is not in cover from it goes into the
## carried body instead (GDD §4.4). A carrier in cover from the shot never has
## the body hit; a carried corpse is never hit (see `redirects_hit_to_carried`).
const CARRY_REDIRECT_CHANCE := 0.25

## The downed bar (GDD §4.4). Starts full at deployment and is NOT refilled by a
## revive: whatever it lost stays lost, so a second down starts from what the
## first left. Drains each round start (`bleed_out_tick`) and takes damage dealt
## to a downed unit; empty -> DEAD. Mission-scoped for free: a unit is spawned
## fresh per mission, which is when this is initialised.
var downed_hp: int = 0
## Times this unit has gone down this mission. Survives a revive (GDD §4.4
## "Revived soldiers keep their down count"); the MAX_DOWNS-th down kills.
var down_count: int = 0

## The body this unit is carrying, and the unit carrying THIS one. Always set as a
## pair (`_link_carry`), host-side; clients rebuild them from the two replicated
## node paths below (`_sync_carry_from_paths`). A carried body shares its carrier's
## tile (`grid_pos` follows every step of a walk), holds no occupancy, and is
## hidden as a placeholder for carry art (extraction plan art list).
var carrying: Unit = null
var carried_by: Unit = null
## Replicated stand-ins for the two links above: a Node cannot cross the wire,
## its path can. Empty NodePath means none.
var carrying_path: NodePath = NodePath()
var carried_by_path: NodePath = NodePath()

## The rounds in the weapon NOT in hand. `ammo`/`reserve` always describe the
## weapon being fired (UnitStats.active_weapon), so drawing the sidearm swaps
## these two pairs rather than teaching every ammo read about two guns — the
## HUD, can_shoot, reload and the replication list all keep working unchanged,
## and each gun keeps its own magazine and reserve (extraction plan 2.5).
var stowed_ammo: int = 0
var stowed_reserve: int = 0
var stowed_reserve_mags := PackedInt32Array()

## The soldier's own choice of gun (GDD §4.3 "Switch weapon", 1 AP): true = the
## pistol. Carrying a body forces the pistol whatever this says
## (`_apply_carry`); putting the body down hands back whichever gun this names,
## so a soldier who chose the pistol keeps it. Replicated.
var sidearm_selected: bool = false

## Boarded a landed ship (GDD §7.4) and left the board: safe, out of every group
## anything targets or counts, waiting to fly. Set on every peer by
## ExtractionManager._take_aboard; nothing ever clears it in a mission.
var aboard: bool = false

## GDD §7.5: four inventory slots, every item one slot. EQUIPPED gear is not
## inventory and takes none — the primary, the pistol, fitted attachments and
## grenades live on `stats` / PlayerUnit, not here. The cap binds what a LIVING
## unit can take (`has_free_slot`); a corpse can hold more, since dying turns
## its equipped gear into items on top of what it carried (`_stow_gear_as_items`).
const INVENTORY_SLOTS := 4

## What this unit carries. Host-authoritative: changed only through `add_item`,
## `remove_item` and the death conversion, each of which refreshes
## `inventory_codes`, the replicated stand-in (an Object cannot cross the wire,
## its ItemPresets code can). Clients rebuild this from the codes in
## `_after_replication`.
var inventory: Array[ItemData] = []
var inventory_codes: PackedStringArray = PackedStringArray()
## Fired on every peer when `inventory` changes (host: as it changes; client: as
## the codes land). The HUD's pack line and loot panel listen.
signal inventory_changed(unit: Unit)
## Set once a corpse's equipped gear has been converted to items, so it happens
## exactly once however `die` is reached.
var _gear_stowed := false

## Client-side: the life state this peer last PRESENTED. Lets `_after_replication`
## see a transition arrive and play it (collapse, tint, stand up) — the host plays
## its own as it makes them, through the same `_present_life_state`.
var _shown_life_state: LifeState = LifeState.ACTIVE
## Client-side: the AP/ammo the HUD was last told about (via `ap_changed`). The
## synchronizer writes these straight into the vars, which fires nothing, so
## `_after_replication` compares against this to know when to announce them.
var _shown_ap_ammo: Vector3i = Vector3i(-1, -1, -1)
## Client-side: the beam (on, facing) this peer last lit tiles for. The host
## recomputes the lighting as it turns and walks units; a client only sees the
## results land, so `_after_replication` recomputes when the beam has moved.
var _shown_beam: Vector2 = Vector2(-1.0, 0.0)
## Collision layer the click/LOS body had before it was hidden by being carried.
var _body_layer: int = -1
## Placeholder "carrying a body" marker on the carrier — see `_show_carry_marker`.
var _carry_marker: MeshInstance3D = null

## "Out of action", for the ~115 call sites that only ever needed to know that:
## the draw pool, `hostiles()`, `allies()`, every AI loop guard, the mission
## tally. Derived from `life_state` so none of them had to change when downed
## and dead became two states — a downed soldier and a corpse are equally not
## going to act, not a target, and not in the pool. Only code that must tell the
## two apart (revive, pick up, loot) reads `life_state` itself.
##
## READ-ONLY. It used to be the assigned field, and an assignment that silently
## wrote nothing (a getter with no setter stores to a shadow the getter ignores)
## would be a bug nobody saw — so the setter refuses loudly instead.
var is_downed: bool:
	get: return life_state != LifeState.ACTIVE
	set(_value):
		push_error("Unit.is_downed is derived from life_state and read-only — assign life_state instead")
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
## Set by `cancel_walk`; `move_along` stops at the next tile boundary on it.
var _walk_cancelled: bool = false
var _walking: bool = false
## A new goal for the walk in flight, taken up at its next tile (E9).
var _redirected: bool = false
var _redirect_goal: Vector3i
## `--auto` only: this soldier is thinking against an AP budget (see `_on_the_clock`).
var auto_budget: bool = false
## Host-only. AP already spent on the attack that opened a fight from
## exploration, taken out of this unit's first combat activation (plan B.7, E8).
var pre_spent_ap: int = 0
## Host-only. This unit opened the fight with a Suppress, which is its whole
## first activation: it sits the opening round out of the pool (E21).
var opening_suppress: bool = false
## Tick playback (plan B.12.2): while a timeline plays, whether this unit is drawn
## follows its MODEL's tile rather than its final one, and so does whether its
## animations play (see is_instant).
var _display_mode: bool = false
var _display_visible: bool = true
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

# With no display there is nothing to animate, so walks and bursts resolve
# instantly. Keeps the `--auto` headless smoke test fast.
var _headless: bool = false
## Whether this unit's sprite is currently drawn. Written by MapBuilder from the
## compartment graph: units are rendered only in rooms holding a player unit.
## Deliberately coarser than a per-unit line-of-sight test — a room is a unit of
## space the player can reason about, where a raycast result is not.
var _rendered: bool = true

# The shot the muzzle frame is about to draw an impact for.
var _pending_shot: Combat.ShotResult = null
var _pending_target: Unit = null
# Which round of the burst is next, and which of them miss regardless of the
# result. Decided up front so the pattern is fixed before the first round.
var _burst_round: int = 0
var _burst_strays: Array[int] = []
var _name_label: Label3D = null
var _sync: MultiplayerSynchronizer = null  # co-op only; see _setup_replication


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
	# A tick's AI pass is decided as logic only, every unit alike (plan B.12):
	# what it looks like is played back afterwards from the recorded timeline.
	if TurnManager.resolving_tick:
		return true
	if _display_mode:
		return _headless or not _display_visible
	return _headless or not _rendered


## Called by MapBuilder when the revealed set changes. Hides the sprite, which
## also stops it being awaited — see is_instant.
func set_rendered(rendered: bool) -> void:
	if rendered == _rendered:
		return
	_rendered = rendered
	if _display_mode:
		return  # playback owns the sprite until it ends (end_display)
	visual.visible = rendered
	# After `_rendered` is set, so the visual is no longer instant and plays.
	if rendered:
		visual.refresh()


## Tick playback (plan B.12.2): playback decides who is drawn, slot by slot, from
## where each MODEL is. Touches only the sprite, never `_rendered`, which is the
## logic's own answer.
func begin_display() -> void:
	_display_mode = true
	_display_visible = _rendered


func set_display_visible(on: bool) -> void:
	if on == _display_visible:
		return
	_display_visible = on
	visual.visible = on
	if on:
		visual.refresh()


## Puts the sprite back on the unit and back under `_rendered`.
func end_display() -> void:
	_display_mode = false
	visual.position = Vector3.ZERO
	visual.rotation = Vector3.ZERO
	visual.visible = _rendered
	if _rendered:
		visual.refresh()


## Appends one event about this unit to the tick being decided (plan B.12).
func _record(kind: String, data: Dictionary = {}) -> void:
	if not TurnManager.resolving_tick:
		return
	data["unit"] = self
	data["kind"] = kind
	TurnManager.record(data)


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	if stats == null:
		stats = UnitStats.new()
	current_hp = stats.max_hp()
	downed_hp = downed_bar_max()
	ammo = stats.mag_size
	reserve = stats.weapon.effective_reserve() if stats.weapon else 0
	# A spawner may hand a unit its starting inventory before it enters the tree
	# (main.gd gives mercs theirs); the wire form has to match from the outset.
	inventory_codes = ItemPresets.codes_of(inventory)
	grid_pos = GridManager.world_to_grid(global_position)
	global_position = GridManager.grid_to_world(grid_pos)
	GridManager.set_occupant(grid_pos, self)
	_name_label = get_node_or_null("NameLabel")
	if _name_label:
		_name_label.text = stats.display_name
	sync_gun_model()
	visual.setup()
	visual.muzzle.connect(_on_muzzle)
	GridManager.cover_destroyed.connect(_on_cover_destroyed)
	refresh_cover_pose()  # a unit may spawn already in cover
	visual.set_flashlight_enabled(has_flashlight and flashlight_on)
	if multiplayer.has_multiplayer_peer():
		# The host always simulates every unit — aliens as much as a
		# squadmate's own mercs — so the host (peer 1, Godot's well-known
		# server id) is this node's authority everywhere, regardless of
		# `owner_peer_id` (which only gates who's ALLOWED to issue it a
		# command — see PlayerUnit._issue).
		set_multiplayer_authority(1)
		_setup_replication()
		moved.connect(_on_moved_broadcast_grid_pos)
		print("[NET] %s ready at %s, authority=%d owner_peer_id=%d local_id=%d is_server=%s" % [
			stats.display_name if stats else name, get_path(), get_multiplayer_authority(),
			owner_peer_id, multiplayer.get_unique_id(), multiplayer.is_server()])


## Property replication for everything a client needs to actually SEE this
## unit doing something: position/facing for the sprite, HP/AP for the HUD,
## ammo for the loadout screen, downed/hunkered/overwatch for pose and
## targeting. `grid_pos` is deliberately NOT in here — see
## `_on_moved_broadcast_grid_pos`, which pushes it explicitly (with an
## occupancy update) only once a move actually settles, rather than every
## in-transit frame.
##
## Hidden from every peer to begin with, on the host: this node exists here the
## moment it spawns, but a client builds its own copy only after the host's
## layout arrives, and state streamed at a path the client can't resolve yet is
## simply lost. `show_to_peer` opens it up once that client reports ready (see
## main.gd's `_rpc_client_ready`); a unit spawned AFTER that (a worm shed from a
## pile) opens straight up for whoever is already in `SteamLobby.ready_peers`.
func _setup_replication() -> void:
	var sync := MultiplayerSynchronizer.new()
	# Fixed name, for the same reason main.gd names the units themselves: the
	# synchronizer is addressed by path across peers, and an engine-generated
	# "@MultiplayerSynchronizer@<n>" differs on every peer, so the client could
	# never resolve the host's and no unit state replicated at all.
	sync.name = "Sync"
	var config := SceneReplicationConfig.new()
	# `life_state`, not `is_downed`: the latter is derived from it (and refuses
	# assignment), so the synchronizer writing it would do nothing.
	# The downed bar, the down count, both carry links (as paths — see
	# `carrying_path`) and the stowed weapon's rounds are the extraction plan 2.1–2.5
	# additions; `_after_replication` turns the links and life-state changes back
	# into visuals on the client.
	for prop in ["global_position", "rotation:y", "current_hp", "ap", "life_state",
			"ammo", "reserve", "reserve_mags", "hunkered", "on_overwatch", "flashlight_on",
			"downed_hp", "down_count", "carrying_path", "carried_by_path",
			"stowed_ammo", "stowed_reserve", "stowed_reserve_mags",
			"inventory_codes", "sidearm_selected"]:
		var path := NodePath(".:%s" % prop)
		config.add_property(path)
		config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	sync.replication_config = config
	if multiplayer.is_server():
		sync.public_visibility = false
		for peer_id in SteamLobby.ready_peers:
			sync.set_visibility_for(peer_id, true)
	_sync = sync
	sync.synchronized.connect(_after_replication)
	add_child(sync)


## Client-side, after each synchronized batch: the base class's own derived state
## first (life-state presentation, carry links), then the subclass hook.
func _after_replication() -> void:
	if life_state != LifeState.ACTIVE or _shown_life_state != LifeState.ACTIVE:
		# A body holds no tile, so its grid_pos is free to simply follow the
		# streamed position — which is how a carried body's tile, and a dropped
		# one's, reach this peer with no RPC of their own. Also on the batch that
		# REVIVES it: a revive may stand it up on a neighbouring tile, and
		# `_present_life_state` below claims occupancy at `grid_pos`.
		grid_pos = GridManager.world_to_grid(global_position)
	if life_state != _shown_life_state:
		var old := _shown_life_state
		_shown_life_state = life_state
		_present_life_state(old)
	_sync_carry_from_paths()
	# The gun in hand also follows the soldier's own pick, which arrives on its
	# own (a switch changes no carry link).
	_apply_drawn()
	# The pack (extraction plan 3.1) arrives as codes; rebuilt only when they
	# differ, since REPLICATION_MODE_ALWAYS re-sends them every batch.
	if inventory_codes != ItemPresets.codes_of(inventory):
		inventory = ItemPresets.items_from(inventory_codes)
		inventory_changed.emit(self)
	# The HUD gates every AP-priced button on `ap`, and refreshes on `ap_changed`.
	# Without this a client's buttons sat on the AP from before the activation's
	# refill (usually 0, all greyed) until some free action — Flashlight, Face —
	# happened to call `_refresh` by hand.
	var ap_ammo := Vector3i(ap, ammo, reserve)
	if ap_ammo != _shown_ap_ammo:
		_shown_ap_ammo = ap_ammo
		ap_changed.emit(self)
	# Snapped so a turn in progress recomputes a handful of times rather than on
	# every batch; the settled facing always lands on a fresh value.
	var beam := Vector2(1.0 if has_flashlight and flashlight_on else 0.0, snappedf(rotation.y, 0.05))
	if beam != _shown_beam:
		var was_lit := _shown_beam.x > 0.0
		_shown_beam = beam
		if beam.x > 0.0 or was_lit:
			LightingManager.recompute_dynamic()
	_on_replicated()


## Client-side: runs after each batch of synchronized properties lands. For
## subclasses whose visuals are derived from a replicated value rather than set
## alongside it (WormUnit's pile size from `current_hp`).
func _on_replicated() -> void:
	pass


func show_to_peer(peer_id: int) -> void:
	if _sync:
		_sync.set_visibility_for(peer_id, true)


## `grid_pos` drives GridManager occupancy (pathfinding/LOS for every OTHER
## peer's clicks), so a client needs it kept current for units it doesn't
## itself move — not just the visual `global_position` the synchronizer above
## already streams. `moved` only fires once a walk fully settles (see
## move_along), so this is a single authoritative correction per move rather
## than a fight with mid-walk occupancy the client has no stake in anyway.
func _on_moved_broadcast_grid_pos(_unit: Unit) -> void:
	if multiplayer.is_server():
		print("[NET] host broadcasting grid_pos for %s -> %s" % [stats.display_name, grid_pos])
		_rpc_sync_grid_pos.rpc(grid_pos)


@rpc("authority", "call_remote", "reliable")
func _rpc_sync_grid_pos(new_grid_pos: Vector3i) -> void:
	print("[NET] client received grid_pos for %s -> %s (was %s)" % [stats.display_name, new_grid_pos, grid_pos])
	if new_grid_pos == grid_pos:
		return
	GridManager.set_occupant(grid_pos, null)
	grid_pos = new_grid_pos
	GridManager.set_occupant(grid_pos, self)
	# The beam is cast from `grid_pos`, so it has only now arrived where the
	# host lit it from (see `_shown_beam`).
	if has_flashlight and flashlight_on:
		LightingManager.recompute_dynamic()


func begin_activation() -> void:
	# An attack that opened the fight from exploration is paid for here (E8).
	ap = ExplorationRules.opening_ap(ap_pool(), pre_spent_ap)
	pre_spent_ap = 0
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


## THE way a player action is paid for (plan A.5). In turn mode it is AP, exactly
## `spend_ap`. In exploration (GDD §4.7.3) the same price goes on the step clock
## instead — a soldier's AP price in steps, so no second table exists — and
## acting is also what lets go of an overwatch held since the last fight (B.8).
func pay(cost: int) -> void:
	if _on_the_clock():
		stand_down()
		TurnManager.add_steps(cost)
		ap_changed.emit(self)
		return
	spend_ap(cost)


## Lets go of an overwatch held out of combat (plan B.8), pose included.
func stand_down() -> void:
	if on_overwatch:
		on_overwatch = false
		overwatch_reserve = 0
		settle_idle()


## Whether `pay(cost)` is affordable: AP in turn mode, always in exploration,
## where a price is time rather than a budget.
func can_afford(cost: int) -> bool:
	return _on_the_clock() or ap >= cost


## Whether this unit's prices go on the step clock. Only a soldier, only out of
## combat: AI acts inside a tick with AP from `begin_activation`, and its turn loops
## (`while ap > 0`) rely on AP going down. `auto_budget` puts an `--auto` soldier in
## the same position, on a synthetic pool per think (main.gd, plan D.1).
func _on_the_clock() -> bool:
	return TurnManager.in_exploration() and is_player_controlled and not auto_budget


## Stops a walk in flight at the tile it is stepping onto (E7). The arrival tail
## still runs, so the walker settles, takes cover and emits `moved` as usual.
func cancel_walk() -> void:
	if _walking:
		_walk_cancelled = true


func is_walking() -> bool:
	return _walking


## Re-aims a walk in flight at `goal`, from the tile it reaches next (E9). No stop
## and no skid: the soldier just turns at the boundary. `move_along` does the path.
func redirect_walk(goal: Vector3i) -> void:
	if _walking:
		_redirected = true
		_redirect_goal = goal


## Whether this walker may step onto `tile` right now: on the map, passable, and
## nobody else standing there. A tile this unit already holds is its own.
func _can_enter(tile: Vector3i) -> bool:
	var t: GridTileData = GridManager.get_tile(tile)
	if t == null or not t.passable:
		return false
	return t.occupant == null or t.occupant == self


func move_along(path: Array[Vector3i]) -> void:
	# Walks the path one tile at a time. This is a coroutine — callers MUST
	# `await` it, or the unit will still be sliding when the next action
	# resolves.
	#
	# Occupancy is claimed PER STEP (plan A.1): the tile ahead is taken as the
	# unit starts into it, and the one behind let go as it arrives. That used to
	# be "hold no tile at all and reclaim on arrival", which was only sound while
	# one unit ever moved at a time — exploration and co-op both break that, and
	# two walkers crossing must never end up on one square.
	if path.is_empty():
		return
	last_moved_turn = TurnManager.turn_number
	is_busy = true
	_walking = true
	_walk_cancelled = false
	_redirected = false
	TurnManager.register_walk(self)
	# `walks_only` units (a shambler, say) have no other gait — they walk a
	# ten-tile path for the same reason they'd walk a one-tile one. Everyone
	# else runs regardless of distance: the soldier's short-hop walk cycle was
	# never more than a Mixamo mocap placeholder, was never drawn, and is not
	# being drawn — a tile is a tile, and the run is the only gait he has.
	var walking := walks_only
	var speed := move_speed
	# Cleared for the duration of the move: a unit crossing the deck is not using
	# the cover it started behind, and leaving the family set would have it run
	# the whole way in a crouch the moment `run_low` art exists.
	visual.set_cover_pose(&"")
	visual.set_stance(UnitVisual.WALK if walking else UnitVisual.RUN)
	var was_hidden := is_instant()
	var goal: Vector3i = path[-1]
	var repathed := false
	var i := 0
	while i < path.size():
		var step: Vector3i = path[i]
		# The goal is closed to anyone but the unit that reserved it (A.2), so a
		# walker whose last tile somebody else is bound for stops one short.
		if i == path.size() - 1 and not GridManager.open_destination(step, self):
			break
		if not _can_enter(step):
			# Somebody has stepped into the way since the path was planned (E18).
			# One fresh route from here, no longer than what is left of this one
			# in turn mode (it was paid for by the tile); else stop where we stand.
			if repathed:
				break
			repathed = true
			var cap := 999 if TurnManager.in_exploration() else path.size() - i
			var fresh := GridManager.find_path(grid_pos, goal, cap)
			if fresh.is_empty() or fresh[-1] != goal:
				break
			path = fresh
			i = 0
			continue
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
		GridManager.set_occupant(step, self)
		var from_yaw := rotation.y
		await _step_to(GridManager.grid_to_world(step), speed)
		# Never a soldier's: their walk is real time, and one finishing the tile it
		# was on as the tick began is not part of what the tick decided.
		if not is_player_controlled:
			_record(ExplorationRules.EV_STEP, {"from": grid_pos, "to": step,
				"from_yaw": from_yaw, "yaw": rotation.y})
		GridManager.release_occupant(grid_pos, self)
		grid_pos = step
		i += 1
		# The carried body shares the tile, every tile of the way (GDD §4.4), so
		# a carrier dropped mid-walk drops it exactly where they fell.
		_carry_follow()
		stepped.emit(self)
		if is_downed:
			# Downed while stepping (a concurrent shot in exploration): a body
			# holds no tile, including the one it was claiming.
			GridManager.release_occupant(grid_pos, self)
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
		await TurnManager.after_step(self)
		if is_downed or _walk_cancelled:
			break
		if _redirected:
			_redirected = false
			goal = _redirect_goal
			path = GridManager.find_path(grid_pos, goal, 999)
			repathed = false
			i = 0
	is_busy = false
	_walking = false
	_walk_cancelled = false
	_redirected = false
	GridManager.release_reservation(self)
	if is_downed:
		TurnManager.unregister_walk(self)
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
	TurnManager.unregister_walk(self)
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
		# A tick's AI still turns as it walks: its facing is rules state (the
		# beam it casts) and playback needs it. A hidden unit's never mattered.
		if TurnManager.resolving_tick:
			var yaw := _yaw_toward(target)
			if not is_nan(yaw):
				rotation.y = yaw
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
	_record(ExplorationRules.EV_TURN, {"from_yaw": rotation.y, "yaw": yaw})
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


## Puts the primary weapon's gun model in the visual's hands. Called at spawn
## and whenever the weapon is swapped (PlayerUnit._equip). A weapon with no
## model leaves the model's own default gun.
func sync_gun_model() -> void:
	# `visual` is @onready: a loadout applied before the unit enters the tree is
	# picked up by the call in _ready instead.
	if visual and stats and stats.weapon:
		visual.set_gun(WeaponPresets.gun_model(stats.weapon.id))


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
##
## The three life states take damage three ways (GDD §4.4):
##   ACTIVE  off `current_hp`; at 0 the unit goes DOWNED or, for a type that
##           cannot be downed or on its MAX_DOWNS-th down, DEAD.
##   DOWNED  off `downed_hp` (armor still applies — it is the same body); at 0,
##           DEAD. This is what an alien finishing prey, a stray grenade, a
##           redirected round and the bleed all come off.
##   DEAD    nothing. A corpse cannot be damaged, so the return is 0 and no log
##           line can claim otherwise.
func take_damage(amount: int) -> int:
	if life_state == LifeState.DEAD:
		return 0
	amount = damage_taken(amount)
	if life_state == LifeState.DOWNED:
		downed_hp = maxi(downed_hp - amount, 0)
		hp_changed.emit(self)
		if downed_hp == 0:
			die()
		return amount
	current_hp = maxi(current_hp - amount, 0)
	hp_changed.emit(self)
	if current_hp == 0:
		if can_be_downed:
			down_count += 1
		if can_be_downed and down_count < MAX_DOWNS:
			_go_down()
		else:
			# Killed outright: a type with no downed state (mercs, aliens, robots —
			# GDD §4.4/§11.10), or a soldier's third down.
			die()
	elif not is_busy:
		# Flinch, then hand back to idle. Settled FIRST so the cover family is
		# current: a soldier hit behind a crate resolves `hit_react_low` and
		# flinches without standing up to do it.
		#
		# Not awaited, for the same reason DOWNED is not — see play_hit_react.
		# And not turned toward the shooter: facing aims the flashlight, so a
		# turn here would change what is lit, and a hit must stay cosmetic.
		#
		# Gated on `is_busy` because the busy case is a unit hit MID-MOVE, by
		# overwatch or suppression fire on its path. `move_along` owns the stance
		# until it arrives, so that unit keeps its run cycle and flinches not at
		# all — settling here used to leave it sliding the rest of the path in
		# the idle pose.
		settle_idle()
		visual.play_hit_react()
	return amount


## The downed bar's full size: max HP, scaled by DOWNED_BAR_FRACTION.
func downed_bar_max() -> int:
	return maxi(1, roundi(stats.max_hp() * DOWNED_BAR_FRACTION))


## What one round's bleed takes off the downed bar: ceil(max HP / 5) by default.
func bleed_amount() -> int:
	return maxi(1, ceili(stats.max_hp() * DOWNED_DRAIN_FRACTION))


## The round-start bleed (GDD §4.4), called by TurnManager for every DOWNED unit
## as a round begins, host-side. Not routed through `take_damage` because it is
## not damage: armor does not stop bleeding, and nothing should flinch or report
## being shot. Returns true if this tick killed the unit.
func bleed_out_tick() -> bool:
	if life_state != LifeState.DOWNED or not bleeds_out():
		return false
	downed_hp = maxi(downed_hp - bleed_amount(), 0)
	hp_changed.emit(self)
	if downed_hp == 0:
		die()
		return true
	return false


## Whether this unit's downed bar drains at round start. True for every soldier;
## the Recover VIP overrides it false (extraction plan A10: "stable, not
## bleeding"). TurnManager's drain asks this too, so a stable body logs nothing.
func bleeds_out() -> bool:
	return true


## ACTIVE -> DOWNED. The unit leaves the fight (`_leave_fight`) with its body on
## the deck: revivable, carriable, bleeding.
func _go_down() -> void:
	_leave_fight()
	_set_life_state(LifeState.DOWNED)
	downed.emit(self)


## -> DEAD, from either other state. THE way a unit dies, whatever killed it.
##
## The body stays where it is as a corpse — on the deck, or over its carrier's
## shoulder if it was being carried (a carried soldier who bleeds out stays
## carried, and goes home as a recovered body). Its gear stays on it: extraction
## plan Phase 3 makes a corpse lootable, and Phase 4 credits one carried out.
## Placeholder look: the downed pose, tinted (UnitVisual.set_dead_tint).
func die() -> void:
	if life_state == LifeState.DEAD:
		return
	var was_active := life_state == LifeState.ACTIVE
	if was_active:
		_leave_fight()
	_set_life_state(LifeState.DEAD)
	# Extraction plan 3.2: a corpse is a loot source, and what is lootable off it
	# is its pack PLUS its equipped gear as items. Converted here, once, so the
	# rest of the game only ever has to read `inventory` — the loot panel, a
	# carried corpse's recovery (MissionResult.loot), Phase 4's credit for it.
	_stow_gear_as_items()
	if was_active:
		downed.emit(self)
	died.emit(self)


## Everything that stops when a unit drops out of the fight, whether onto the deck
## or dead outright. Host-side game state only; how it LOOKS is
## `_present_life_state`, which every peer runs.
func _leave_fight() -> void:
	GridManager.release_reservation(self)
	on_overwatch = false
	stunned = false
	hunkered = false
	# A corpse holds nobody down. `is_suppressed` also guards against a dead
	# suppressor, so this is belt-and-braces — but it clears the back-link too,
	# which that guard cannot.
	release_suppression()
	# GDD §4.4: a carrier who goes down (or dies) drops what they were carrying,
	# on their own tile.
	if carrying != null:
		drop_carried()
	# A body is evidence a Proctor can find long after the fight that made it
	# (security-robots/design-choices/detection-and-network-alert.md). Reported
	# for every unit, robots included: a wrecked machine is as much a sign
	# something came through here as a corpse is.
	SecurityNetwork.report_evidence(grid_pos, SecurityNetwork.Evidence.CORPSE)


## Writes `life_state` and presents the change on this peer. Clients get the
## same presentation from `_after_replication` when the new state arrives.
func _set_life_state(new_state: LifeState) -> void:
	var old := life_state
	life_state = new_state
	_shown_life_state = new_state
	_present_life_state(old)
	if new_state != LifeState.ACTIVE:
		TurnManager.notify_unit_down(self)


## How a life-state change LOOKS, on every peer: the collapse, the corpse tint,
## standing back up — and the tile it frees or retakes, since every peer keeps
## its own occupancy grid.
func _present_life_state(old: LifeState) -> void:
	if life_state != LifeState.ACTIVE and old != life_state:
		_record(ExplorationRules.EV_DOWN, {"dead": life_state == LifeState.DEAD,
			"was_active": old == LifeState.ACTIVE})
	if old == LifeState.ACTIVE and life_state != LifeState.ACTIVE:
		# Bodies hold no tile. Guarded on still being the occupant, because a unit
		# downed MID-walk holds none (move_along) and somebody else may be there.
		var tile: GridTileData = GridManager.get_tile(grid_pos)
		if tile and tile.occupant == self:
			GridManager.set_occupant(grid_pos, null)
		if _name_label:
			_name_label.visible = false
		# The rig light goes down with the soldier: LightingManager already skips a
		# downed unit's beam, and leaving the model's own lamp lit would show a
		# beam that lights nothing. Comes back on with a revive (below).
		visual.set_flashlight_enabled(false)
		# Deliberately not awaited: the unit is out of the fight the moment its
		# HP hits zero, and the shooter's own activation shouldn't stall on the
		# collapse playing out. (ActiveMarker self-hides off is_downed.)
		visual.play_action(UnitVisual.DOWNED)
	if life_state == LifeState.DEAD:
		visual.set_dead_tint(true)
	if life_state == LifeState.ACTIVE and old != LifeState.ACTIVE:
		GridManager.set_occupant(grid_pos, self)
		global_position = GridManager.grid_to_world(grid_pos)
		if _name_label:
			_name_label.visible = true
		visual.set_flashlight_enabled(has_flashlight and flashlight_on)
		# No stand-up animation exists (extraction plan art list), so standing back
		# up is a cut to the idle — the same answer do_hunker gives for the same
		# missing transition.
		settle_idle()


# --- Revive (GDD §4.4, extraction plan 2.2) ------------------------------------


## "No tile" for `revive_tile_for`. A floor index no deck has.
const NO_REVIVE_TILE := Vector3i(-99999, -99999, -99999)


## The tile a revive would stand `body` up on if THIS unit did it, or
## NO_REVIVE_TILE.
##
## The body's own tile when it is free. Bodies hold no occupancy, so somebody may
## be standing on it — the reviver very often, having walked onto it. Then the
## free tile adjacent to the REVIVER nearest the body, ties broken in neighbour
## order so every peer picks the same one; none free -> no revive (plan A3).
func revive_tile_for(body: Unit) -> Vector3i:
	if body == null:
		return NO_REVIVE_TILE
	if GridManager.is_free(body.grid_pos):
		return body.grid_pos
	var best := NO_REVIVE_TILE
	var best_dist := 999999
	for n in GridManager.neighbors(grid_pos):
		if not GridManager.is_free(n):
			continue
		var d := GridManager.chebyshev_dist(n, body.grid_pos)
		if d < best_dist:
			best_dist = d
			best = n
	return best


## Whether `tile` is within this unit's reach for a revive, pick up or (Phase 3)
## loot: movement-adjacent (GridManager.is_melee_adjacent — what a step could
## reach, through no wall corner), or the tile it is standing on, since a body
## holds no tile and a soldier can be standing right over one.
func within_reach(tile: Vector3i) -> bool:
	return tile == grid_pos or GridManager.is_melee_adjacent(grid_pos, tile)


## Why THIS unit cannot revive `body` right now, or "" if it can. Rules only — AP
## is the caller's (PlayerUnit.try_revive prices it). Any downed contractor
## qualifies, whoever OWNS it (GDD §7.6 cross-player rescue): ownership is the
## acting unit's question, asked by `_rpc_command`, never the target's.
func revive_blocker(body: Unit) -> String:
	if life_state != LifeState.ACTIVE:
		return "not able"
	if carrying != null:
		return "hands full"
	if body == null or body == self or body.life_state != LifeState.DOWNED:
		return "nobody downed there"
	if is_hostile_to(body):
		return "not one of ours"
	if not body.can_be_revived():
		# The Recover VIP (extraction plan Phase 6): carried out, never stood up.
		return "can't be revived — carry them out"
	if body.carried_by != null:
		# Put them down first (free): reviving someone still slung over a shoulder
		# has nowhere sensible to stand them.
		return "being carried"
	if not within_reach(body.grid_pos):
		return "out of reach"
	if revive_tile_for(body) == NO_REVIVE_TILE:
		return "no room to stand them up"
	return ""


## Brings a DOWNED unit back up on `tile` (GDD §4.4). Host-side; validated by the
## caller (`revive_blocker`). Back at ceil(REVIVE_HP_FRACTION x max HP), with the
## down count AND the downed bar untouched — a revive refills neither.
##
## Joins the pool NEXT round: TurnManager's pool is a snapshot that already
## dropped this unit when it went down — or would keep it, if it went down and
## came back up inside one activation before the next draw — so it is erased
## here too.
func revive_at(tile: Vector3i) -> void:
	if life_state != LifeState.DOWNED:
		return
	current_hp = maxi(1, ceili(stats.max_hp() * REVIVE_HP_FRACTION))
	grid_pos = tile
	TurnManager.pool.erase(self)
	_set_life_state(LifeState.ACTIVE)
	hp_changed.emit(self)
	revived.emit(self)


# --- Carrying (GDD §4.4, extraction plan 2.3) ----------------------------------


## Whether a revive can stand this body back up (revive_blocker asks the BODY).
## Soldiers — the units that go down rather than die — can; the Recover VIP
## (VipUnit, extraction plan Phase 6) overrides it false.
func can_be_revived() -> bool:
	return can_be_downed


## Whether hostile AI may deliberately finish this body off when it lies DOWNED
## (`downed_targets`, the GDD §4.4 per-faction policy). True for soldiers; the
## Recover VIP overrides it false (decisions log, Phase 6). Stray damage is not
## targeting and still lands either way.
func is_finish_target() -> bool:
	return true


## Whether this unit can be lifted: a downed or dead CONTRACTOR soldier nobody is
## carrying. "Contractor soldier" is `can_be_downed` for now. The Recover VIP
## overrides this (VipUnit, extraction plan Phase 6); a merc corpse would too, if
## carrying one is ever wanted.
func is_carriable() -> bool:
	return life_state != LifeState.ACTIVE and carried_by == null and can_be_downed


## Why THIS unit cannot pick up `body`, or "". Rules only; AP is the caller's.
## Like revive, any owner's body qualifies (GDD §7.6).
func pick_up_blocker(body: Unit) -> String:
	if life_state != LifeState.ACTIVE:
		return "not able"
	if carrying != null:
		return "already carrying someone"
	if body == null or body == self or not body.is_carriable() or is_hostile_to(body):
		return "nobody to carry there"
	if not within_reach(body.grid_pos):
		return "out of reach"
	return ""


## Lifts `body` (host-side; validated by `pick_up_blocker`). The body moves onto
## this unit's tile and is hidden; the sidearm comes out (`_apply_carry`).
func pick_up(body: Unit) -> void:
	_link_carry(body)
	_carry_follow()


## Puts down whatever this unit carries, on its own tile. Free (GDD §4.4), and
## also what happens automatically when a carrier goes down or dies. Returns the
## body, or null if nothing was carried.
func drop_carried() -> Unit:
	var body := carrying
	if body == null:
		return null
	body.grid_pos = grid_pos
	body.global_position = GridManager.grid_to_world(grid_pos)
	_link_carry(null)
	return body


## Sets (or with null, clears) the carry pair on both ends, host-side, and keeps
## everything that hangs off it in step: the replicated paths, the weapon in hand
## and the rounds in it, the visuals, the signal.
func _link_carry(body: Unit) -> void:
	var old := carrying
	if old != null:
		old.carried_by = null
		old.carried_by_path = NodePath()
	carrying = body
	carrying_path = body.get_path() if body != null and body.is_inside_tree() else NodePath()
	if body != null:
		body.carried_by = self
		body.carried_by_path = get_path() if is_inside_tree() else NodePath()
	var was_drawn := stats.sidearm_drawn
	_apply_carry()
	if stats.sidearm_drawn != was_drawn:
		_swap_weapon_rounds()
	if old != null and old != body:
		old._apply_carry()
		old.carry_changed.emit(old)
	if body != null:
		body._apply_carry()
		body.carry_changed.emit(body)
	carry_changed.emit(self)


## Swaps the rounds in hand with the stowed weapon's (see `stowed_ammo`). Host-side
## only, and only on an actual draw/holster: the swapped values replicate.
func _swap_weapon_rounds() -> void:
	var a := ammo
	ammo = stowed_ammo
	stowed_ammo = a
	var r := reserve
	var m := reserve_mags
	reserve = stowed_reserve
	reserve_mags = stowed_reserve_mags  # after `reserve`, which re-deals them
	stowed_reserve = r
	stowed_reserve_mags = m
	ap_changed.emit(self)  # the HUD reads ammo off the same refresh
	ammo_changed.emit(self)  # the setters fired with the stowed pair half swapped


## Which gun is in hand, from the two things that decide it: carrying a body
## forces the pistol, otherwise it is the soldier's own pick (`sidearm_selected`).
## Every peer derives it the same way from replicated state.
func _apply_drawn() -> void:
	stats.sidearm_drawn = stats.sidearm != null and (carrying != null or sidearm_selected)


## Why this unit cannot switch weapons now, or "" (GDD §4.3). Only a soldier with
## a sidearm has two guns; a carrier's hands decide for them.
func switch_weapon_blocker() -> String:
	if stats.sidearm == null:
		return "no sidearm"
	if life_state != LifeState.ACTIVE:
		return "not able"
	if carrying != null:
		return "hands full — pistol only while carrying"
	return ""


## Swaps primary and pistol (host-side; validated by `switch_weapon_blocker`,
## priced by the caller at UnitStats.Action.SWITCH_WEAPON). Each gun keeps its
## own magazine and reserve (`_swap_weapon_rounds`).
func switch_weapon() -> void:
	var was_drawn := stats.sidearm_drawn
	sidearm_selected = not sidearm_selected
	_apply_drawn()
	if stats.sidearm_drawn != was_drawn:
		_swap_weapon_rounds()


## Keeps the carried body on this unit's tile. Called per step of a walk.
func _carry_follow() -> void:
	if carrying == null:
		return
	carrying.grid_pos = grid_pos
	carrying.global_position = global_position


## What carrying LOOKS like and which gun is in hand, on every peer, from this
## unit's own two links. Placeholders throughout (extraction plan art list):
##   carried  hidden, and its click/LOS body switched off so it neither eats a
##            click meant for its carrier nor stands in a line of fire;
##   carrier  a slung-body marker on the back, the body's name on its label, and
##            the sidearm drawn (UnitStats.sidearm_drawn). The rifle stays on the
##            model, and the rifle poses play — no pistol art yet.
func _apply_carry() -> void:
	_apply_drawn()
	_show_carry_marker(carrying != null)
	if _name_label and life_state == LifeState.ACTIVE:
		_name_label.text = stats.display_name if carrying == null \
			else "%s [+%s]" % [stats.display_name, carrying.stats.display_name]
	visible = carried_by == null
	var body := get_node_or_null("Body") as CollisionObject3D
	if body:
		if carried_by != null:
			if _body_layer < 0:
				_body_layer = body.collision_layer
			body.collision_layer = 0
		elif _body_layer >= 0:
			body.collision_layer = _body_layer
			_body_layer = -1


## Client-side: rebuilds the carry links from the replicated paths, and presents
## any change. The ammo swap already happened on the host and arrives as values.
func _sync_carry_from_paths() -> void:
	var want_carrying: Unit = null
	if not carrying_path.is_empty():
		want_carrying = get_node_or_null(carrying_path) as Unit
	var want_carrier: Unit = null
	if not carried_by_path.is_empty():
		want_carrier = get_node_or_null(carried_by_path) as Unit
	if want_carrying == carrying and want_carrier == carried_by:
		return
	carrying = want_carrying
	carried_by = want_carrier
	_apply_carry()
	carry_changed.emit(self)


func _show_carry_marker(on: bool) -> void:
	if not on:
		if _carry_marker:
			_carry_marker.visible = false
		return
	if _carry_marker == null:
		# A body bag across the back: a dark box at shoulder height. Enough to
		# read "this soldier has their hands full" from the camera.
		_carry_marker = MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.9, 0.32, 0.4)
		_carry_marker.mesh = box
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.35, 0.3, 0.22)
		_carry_marker.material_override = mat
		_carry_marker.position = Vector3(0, 1.45, 0.25)
		add_child(_carry_marker)
	_carry_marker.visible = true


## Whether a landed hit from `shooter` on THIS unit goes into the body it carries
## instead (GDD §4.4). Never when this unit was in cover from the shot
## (Combat.target_in_cover — the body is behind the cover with the carrier);
## never into a corpse (it takes no damage, and letting it soak hits would make a
## corpse armour); otherwise CARRY_REDIRECT_CHANCE. Rolls the global RNG, so a
## seeded caller gets a repeatable answer.
func redirects_hit_to_carried(shooter: Unit, result: Combat.ShotResult) -> bool:
	if carrying == null or carrying.life_state != LifeState.DOWNED:
		return false
	if Combat.target_in_cover(shooter, result):
		return false
	return randf() < CARRY_REDIRECT_CHANCE


## Moves this unit to `tile` with no walk: no AP, no overwatch, no alarms. Host
## side. For the game moving a unit rather than the unit moving — a ship landing
## on top of it (ExtractionManager). Keeps occupancy right for a standing unit
## (and tells clients, as a settled move does) and carries a carried body along.
func relocate_to(tile: Vector3i) -> void:
	if life_state == LifeState.ACTIVE:
		var t: GridTileData = GridManager.get_tile(grid_pos)
		if t and t.occupant == self:
			GridManager.set_occupant(grid_pos, null)
		grid_pos = tile
		GridManager.set_occupant(grid_pos, self)
		if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
			_rpc_sync_grid_pos.rpc(grid_pos)
	else:
		grid_pos = tile
	global_position = GridManager.grid_to_world(grid_pos)
	_carry_follow()


## Every downed, uncarried unit this one is hostile to — the candidates for
## finishing off — or nothing at all for a faction whose DOWNED_POLICY is NEVER
## (extraction plan 2.4). `hostiles()` stays the list of LIVE threats; this is
## the other list, and which of the two a unit reads first is its faction's call.
func downed_targets() -> Array[Unit]:
	var out: Array[Unit] = []
	if Faction.downed_policy(faction) == Faction.DownedPolicy.NEVER:
		return out
	for node in get_tree().get_nodes_in_group("units"):
		var other := node as Unit
		if other != null and other.life_state == LifeState.DOWNED \
				and other.carried_by == null and other.is_finish_target() and is_hostile_to(other):
			out.append(other)
	return out


## Every body (DOWNED or DEAD unit) lying on `tile`. Bodies hold no occupancy, so
## this is how anything finds one — a click, a grenade. A carried body shares its
## carrier's tile and is only included with `include_carried`. Skips a unit on
## its way out of the tree (a dissolved worm is DEAD but is not a body).
func bodies_on(tile: Vector3i, include_carried := false) -> Array[Unit]:
	var out: Array[Unit] = []
	for node in get_tree().get_nodes_in_group("units"):
		var other := node as Unit
		if other == null or other.life_state == LifeState.ACTIVE or other.grid_pos != tile:
			continue
		if other.carried_by != null and not include_carried:
			continue
		if other.is_queued_for_deletion() or not other.leaves_body():
			continue
		out.append(other)
	return out


## Whether this unit, out of the fight, is a BODY on the deck — something
## `bodies_on` finds and a revive, pick-up or loot could be aimed at. True for
## everything that falls; false for a disabled door gun (DoorGunUnit), which is
## part of the ship rather than a corpse lying under it.
func leaves_body() -> bool:
	return true



# --- Inventory and looting (GDD §7.5, extraction plan 3.1–3.2) -------------------


func free_slots() -> int:
	return maxi(0, INVENTORY_SLOTS - inventory.size())


func has_free_slot() -> bool:
	return inventory.size() < INVENTORY_SLOTS


## Puts `item` in this unit's pack. Host-side. Refused (false) when the pack is
## full, unless `ignore_cap` — which only the corpse conversion and a spawner
## seeding a pack use; nothing a player does can overfill a living soldier.
func add_item(item: ItemData, ignore_cap := false) -> bool:
	if item == null or (not ignore_cap and not has_free_slot()):
		return false
	inventory.append(item)
	_inventory_changed()
	return true


## Takes the item at `index` out of the pack and returns it, or null.
func remove_item(index: int) -> ItemData:
	if index < 0 or index >= inventory.size():
		return null
	var item: ItemData = inventory[index]
	inventory.remove_at(index)
	_inventory_changed()
	return item


## Index of the first item with this code, or -1.
func find_item_code(code: String) -> int:
	for i in inventory.size():
		if inventory[i].code == code:
			return i
	return -1


func has_item_code(code: String) -> bool:
	return find_item_code(code) >= 0


func _inventory_changed() -> void:
	inventory_codes = ItemPresets.codes_of(inventory)
	inventory_changed.emit(self)


## The equipped gear a corpse gives up as items (extraction plan 3.2): the primary
## — with its attachments and ammo, as one item — for any unit carrying a roster
## gun. Aliens' and robots' built-in weapons are not roster guns and yield
## nothing. PlayerUnit adds its grenades. The sidearm is deliberately NOT here:
## every soldier is issued one (decisions log), so looting it would spend a slot
## on something nobody is short of.
func _equipped_gear_items() -> Array[ItemData]:
	var out: Array[ItemData] = []
	var weapon_item := ItemPresets.make_weapon_from(stats.weapon if stats else null)
	if weapon_item != null:
		out.append(weapon_item)
	return out


func _stow_gear_as_items() -> void:
	if _gear_stowed:
		return
	_gear_stowed = true
	var gear := _equipped_gear_items()
	if gear.is_empty():
		return
	inventory.append_array(gear)
	_inventory_changed()


# The LOOT SOURCE interface. A loot source is anything `PlayerUnit.try_loot` can
# take from: a corpse (this), a LootContainer, a pile. Duck-typed rather than a
# shared base class, because a corpse is a Unit and a container is a prop and
# neither should inherit the other's baggage. Every source answers:
#   loot_items() -> Array[ItemData]   what is on it, in panel order
#   loot_take(index) -> ItemData      host-side: removes and returns one item
#   loot_tile() -> Vector3i           where it is, for reach
#   loot_name() -> String             what the panel calls it


## Why `looter` cannot loot THIS unit, or "". GDD §4.4/§11.10: corpses are
## lootable — a dead soldier of either player's (GDD §7.6 cross-player rule: the
## owner is never asked), a dead merc, a robot wreck with its Salvage. A DOWNED
## friendly is not (decisions log: the GDD names corpses, and stripping a
## squadmate who is still bleeding is a revive's job, not a looter's). A carried
## corpse is put down first, as with a revive.
func loot_blocker(looter: Unit) -> String:
	if life_state != LifeState.DEAD:
		return "not a corpse"
	if carried_by != null:
		return "being carried"
	if is_queued_for_deletion():
		return "gone"
	if looter == null or not looter.within_reach(grid_pos):
		return "out of reach"
	return ""


func loot_items() -> Array[ItemData]:
	return inventory


func loot_take(index: int) -> ItemData:
	return remove_item(index)


func loot_tile() -> Vector3i:
	return grid_pos


func loot_name() -> String:
	return "%s's body" % stats.display_name


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


## Whether this unit would START a fight with `other`, given that it is hostile
## (extraction plan Phase 7). `is_hostile_to` says who may be shot. This says
## who this unit chooses to go after on its own initiative. They are the same for
## everyone except the rival mercs, who are professionals and pick fights with a
## third party only when it is worth it (MercUnit, CrossFactionRules.merc_engages).
## Being shot at bypasses this: a unit that fires on you has made the choice.
func will_engage(other: Unit) -> bool:
	return is_hostile_to(other)


## `hostiles()` narrowed to the ones this unit would choose to fight
## (`will_engage`). Use it where the question is "what should I shoot", and
## keep `hostiles()` where it is "what could shoot me" (overwatch lanes, threat).
func engageable_hostiles() -> Array[Unit]:
	var out: Array[Unit] = []
	for other in hostiles():
		if will_engage(other):
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
##
## And never while carrying (extraction plan A4): the only gun in hand is a
## pistol fired one-handed, and one-handed fire is not volume of fire. Gated here
## rather than at the button so the HUD, PlayerUnit and every GOAP Suppress
## action refuse it through the one check they all already make.
func can_suppress() -> bool:
	return ammo >= SUPPRESS_AMMO_COST and carrying == null


## Sec 4.2 + the coordinated-AI doc's `Suppress` action. ENDS the activation, as
## Hunker and Overwatch do, and for the same reason `_end_activation_ap` gives:
## the unit is committing the rest of its turn to holding an angle.
##
## Coroutine — callers MUST await. The burst that opens it is played rather than
## implied, so suppression starts on screen the way any other shot does.
func do_suppress(target: Unit) -> void:
	if target == null or target.is_downed or carrying != null:
		return
	ammo -= SUPPRESS_AMMO_COST
	# Replace whatever this unit was pinning before. One weapon, one direction.
	release_suppression()
	suppressing = target
	target.suppressed_by = self
	_end_activation_ap()
	is_busy = true
	await face_toward(target.global_position)
	_arm_covering_fire(target)
	await _play_armed_burst(SUPPRESSION_BURST_ROUNDS)
	_disarm_covering_fire()
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
## It does SHOW everything, though: same kick, same drawn muzzle flash, same
## impacts as any other burst, via `_arm_covering_fire`. The distinction is
## between what the shot resolves and what the shot looks like, and only the
## first one is empty — rounds going downrange with no effect is the mechanic.
##
## Skipped entirely when the unit is off screen or headless (`is_instant`), where
## there is nobody to show it to and the timer would just burn turn time — unless
## a co-op client is connected, whose view the host cannot see from here. Nothing
## waits on this loop, so the host keeping it ticking costs no turn time.
func _suppression_fire_loop() -> void:
	while suppressing != null and not is_downed and is_inside_tree():
		if is_instant() and not visual.mirrors():
			return
		await get_tree().create_timer(SUPPRESSION_BURST_GAP).timeout
		# Re-checked after the wait: three seconds is long enough for the
		# suppression to have ended, or for either party to have died.
		if suppressing == null or is_downed or is_busy or not is_inside_tree():
			return
		_arm_covering_fire(suppressing)
		await _play_armed_burst(SUPPRESSION_BURST_ROUNDS)
		_disarm_covering_fire()


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


## The flat-cost extraction actions (UnitStats.FLAT_AP_COST — revive, pick up,
## loot, call ship, dust-off) route through here exactly like Shoot does, and
## `stats.action_cost` returns them undiscounted. Callers never special-case
## them; a subclass overriding this should hand unknown actions to `super`.
func action_cost(action: UnitStats.Action) -> int:
	return stats.action_cost(action)


func aimed_shot_cost(body_part: int) -> int:
	return Combat.aimed_shot_ap_cost(body_part, stats.reflexes,
		stats.aimed_ap_modifier())


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


## Scales how far enemies can SEE this unit (EnemyUnit._can_see and the robots'
## override). Above 1 is a visual tell — a Laser Sight's dot.
func visibility_multiplier() -> float:
	var w := active_weapon()
	return w.visibility_multiplier() if w else 1.0


## How many tiles this unit's gunfire carries: the weapon's own radius with its
## attachments (a suppressor takes tiles off). The network's default covers the
## unarmed case, which should never fire anyway.
func gunfire_noise_radius() -> int:
	var w := active_weapon()
	return w.effective_noise_radius() if w else SecurityNetwork.NOISE_RADIUS


## The weapon in this unit's hands: the sidearm while carrying a body, otherwise
## the primary (extraction plan 2.5). Delegates to UnitStats.active_weapon, which
## every weapon getter and Combat read already go through.
func active_weapon() -> WeaponData:
	return stats.active_weapon()


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


## The parts injured right now, sorted (Combat.BodyPart values). What the campaign
## debrief writes back to a soldier's record (GDD §4.2.1: an injury lasts until
## the medical resource treats it, so it outlives the mission that caused it).
func injured_parts() -> Array[int]:
	var out: Array[int] = []
	for part in _injured_parts:
		if _injured_parts[part]:
			out.append(int(part))
	out.sort()
	return out


## Spawn-time: carries a soldier's untreated injuries (SoldierRecord.injuries)
## into the mission. Each part is set AT its threshold rather than merely flagged,
## so the damage counter agrees with the flag and `heal_injury` resets both. Needs
## `stats` (the threshold is a fraction of max HP); safe before add_child. Run on
## every peer from the same record, so a client's move preview prices the same
## injured legs the host simulates.
func apply_injuries(parts: Array) -> void:
	for part in parts:
		_injured_parts[int(part)] = true
		_body_part_damage[int(part)] = _body_part_threshold(int(part))


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


func fire_at(target: Unit, action: Combat.ShotAction, body_part: int = Combat.BodyPart.TORSO, charge_ammo: bool = true) -> Combat.ShotResult:
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
	# `charge_ammo` is false for the suppressing-fire break shot: those 3 rounds
	# were already spent up front in `do_suppress`, so this shot is drawn from
	# that paid-for burst rather than costing a fresh one.
	if charge_ammo:
		ammo -= 1
	var result := Combat.resolve_shot(self, target, action, body_part)
	is_busy = true
	var rounds := randi_range(BURST_MIN, BURST_MAX)
	_pending_shot = result
	_pending_target = target
	_burst_round = 0
	_burst_strays = _pick_strays(rounds, result.hit)
	_record(ExplorationRules.EV_SHOT, {"target": target, "hit": result.hit, "crit": result.crit,
		"rounds": rounds, "strays": PackedInt32Array(_burst_strays), "melee": false})
	await _play_armed_burst(rounds)  # emits `muzzle` once per round
	_pending_shot = null
	_pending_target = null
	if result.hit:
		# The raw roll is kept because two different consumers want two different
		# numbers: HP takes what got through the target's armor, while a component
		# pool (Securus's head) takes the roll itself — a weak point the unit's own
		# plating covers would not be one. `result.damage` ends up holding what
		# actually landed, so every log line reports the real figure.
		var raw := result.damage
		# GDD §4.4: a landed hit on a carrier may go into the body instead —
		# decided AFTER the hit is rolled against the carrier, so carrying never
		# changes how often a carrier is hit, only who a hit lands on.
		var victim := target
		if target.redirects_hit_to_carried(self, result):
			victim = target.carrying
			result.hit_carried = true
			result.redirect_note = "the round hits %s, slung over %s's shoulder" % [
				victim.stats.display_name, target.stats.display_name]
		result.damage = victim.take_damage(raw)
		result.absorbed = raw - result.damage
		# Body-part injury and stun are about the unit aimed AT; a round that went
		# into the body on its shoulder did neither to it.
		if action == Combat.ShotAction.AIMED_SHOT and not target.is_downed and victim == target:
			result.newly_injured = target.apply_body_part_damage(body_part, raw)
			if result.stunned:
				target.stunned = true
	_report_incoming(target)
	# Sec 5.4: gunfire is loud, and it leaves brass. The first is what the robot
	# faction shares with the (deferred) alien sound channel; the second is what
	# only a Proctor ever reads, turns later.
	SecurityNetwork.report_noise(grid_pos, self, gunfire_noise_radius())
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
	# before it. No ammo is spent and nothing travels — the only mark a swing
	# leaves is the impact flash where it connects.
	var result := Combat.resolve_melee(self, target)
	_record(ExplorationRules.EV_SHOT, {"target": target, "hit": result.hit, "crit": result.crit,
		"rounds": 0, "strays": PackedInt32Array(), "melee": true})
	is_busy = true
	await visual.play_action(UnitVisual.MELEE)
	if result.hit:
		show_impact(target.global_position, result.crit)
		var raw := result.damage
		result.damage = target.take_damage(raw)
		result.absorbed = raw - result.damage
	# Outside the `if result.hit`, like the one in `fire_at`: a swing that missed
	# still happened, and being swung at is the least ambiguous stimulus there is.
	_report_incoming(target)
	is_busy = false
	return result


## Tells `target` this unit just attacked it — the stimulus an attack creates in
## the unit it was aimed AT, as opposed to the noise it makes for everyone else.
## `SecurityNetwork.report_noise` is what the room hears; this is what the unit in
## the crosshairs feels, and they are deliberately different channels: the noise
## is positional and short-ranged, this one is personal and has no range at all.
##
## Called on a MISS as well as a hit, and on an attack that KILLS, because those
## are exactly the two cases a damage-driven implementation loses. Awareness hung
## entirely off sight, beams and noise until now, which meant being shot was in
## itself not a stimulus: a unit hit in the back by a shooter it could not see
## took the damage and stayed Unaware, and a shot that killed outright was the
## quietest thing on the deck.
##
## Duck-typed exactly like `report_noise`: only units with an awareness state
## machine can react, and player units are simply skipped.
func _report_incoming(target: Unit) -> void:
	if target != null and target.has_method("come_under_fire"):
		target.come_under_fire(self)


func _on_muzzle() -> void:
	# One of these per round of the burst, fired by UnitVisual.play_burst.
	#
	# Gated on the TARGET, not on the shot: covering fire arms one without the
	# other (see `_arm_covering_fire`), and it makes the same noise and shows the
	# same impacts as a real burst. A rifle going off looks like a rifle going
	# off — the only thing the roll decides is where the rounds end up.
	#
	# The FLASH is not fired from here and never was: UnitVisual.play_burst fires
	# it on the barrel (MuzzleFlash) alongside the signal that calls this.
	# Nothing here has to place it, and that is the whole reason the old
	# room-filling muzzle light is gone.
	if is_instant() or _pending_target == null:
		return
	var round_index := _burst_round
	_burst_round += 1
	var vfx := get_tree().get_first_node_in_group("vfx")
	if vfx == null:
		return
	# Origin is the barrel tip as the animation currently has it, not the middle
	# of the unit — the rifle is held off to the right, so a centreline shot
	# visibly left the chest. Still read per round now that no beam is drawn from
	# it: the scatter cone is built off the line of fire, and the sound is
	# positioned at the barrel.
	var from := visual.muzzle_origin()
	# No ShotResult means nothing was rolled, so nothing can land: every round of
	# a covering burst is thrown wide, which is exactly what suppressing fire is.
	# `shot_impact` already handles that case — a round that did not land leaves
	# no mark at the target.
	var lands := _pending_shot != null and _pending_shot.hit and round_index not in _burst_strays
	var crit := _pending_shot != null and _pending_shot.crit
	vfx.shot_impact(from, _pending_target.visual.global_position, lands, crit)
	# ONCE PER BURST, not once per round — unlike `shot_impact` above, which is
	# per-round because each round leaves its own separate mark.
	#
	# The sample is a whole burst (1.33 s of one) and rounds are BURST_CADENCE
	# apart (0.11 s), so playing it per round stacked 4-6 near-identical copies
	# of a full-length burst on top of each other every shot. That is the wrong
	# sound, and the incoherent summing added roughly +7 dB on top of it — enough
	# to swallow a -6 dB mix trim whole and leave the shot as loud as it started.
	#
	# Gated on the TARGET exactly as the impact above is: a covering burst that
	# rolls no shot still makes the noise a rifle makes. If per-round gunfire is
	# ever wanted, the SAMPLE has to change with it — a single crack, not a burst.
	if round_index == 0:
		Sfx.play("rifle_fire", from)


## Plays the burst armed by `fire_at` or `_arm_covering_fire`, and hands every
## ready client the same arming. The roll exists only on the host, so without it
## a client saw the rifle kick and nothing land; with it, the client's own
## `_on_muzzle` draws the impacts and plays the gunfire, gated on that client's
## own `is_instant`.
func _play_armed_burst(rounds: int) -> void:
	if visual.mirrors() and not TurnManager.resolving_tick:
		var target_path := _pending_target.get_path() if _pending_target else NodePath()
		var has_shot := _pending_shot != null
		var hit := has_shot and _pending_shot.hit
		var crit := has_shot and _pending_shot.crit
		var strays := PackedInt32Array(_burst_strays)
		for peer_id in SteamLobby.ready_peers:
			_rpc_play_armed_burst.rpc_id(peer_id, target_path, rounds, has_shot, hit, crit, strays)
	await visual.play_burst(rounds, false)


@rpc("authority", "call_remote", "reliable")
func _rpc_play_armed_burst(target_path: NodePath, rounds: int, has_shot: bool, hit: bool,
		crit: bool, strays: PackedInt32Array) -> void:
	# Only what `_on_muzzle` reads; the rest of the result stays on the host.
	var shot: Combat.ShotResult = null
	if has_shot:
		shot = Combat.ShotResult.new()
		shot.hit = hit
		shot.crit = crit
	_pending_shot = shot
	_pending_target = get_node_or_null(target_path) as Unit if not target_path.is_empty() else null
	_burst_round = 0
	_burst_strays.assign(strays)
	await visual.play_burst(rounds, false)
	# Unless a later burst took the arming over meanwhile — the suppression-break
	# case `_disarm_covering_fire` describes.
	if _pending_shot == shot:
		_pending_shot = null
		_pending_target = null


## Draws an attack the tick already resolved (exploration plan B.12): the burst
## with its recorded hit and strays, or the swing, and the target's flinch if it
## was hit and is still standing. No roll, no damage, no RPC — every peer plays
## the timeline itself. Coroutine.
func replay_attack(target: Unit, hit: bool, crit: bool, rounds: int,
		strays: PackedInt32Array, melee: bool) -> void:
	if melee:
		await visual.play_action_local(UnitVisual.MELEE)
		if hit:
			_show_impact(target.visual.global_position, crit)
	else:
		await _rpc_play_armed_burst(target.get_path(), rounds, true, hit, crit, strays)
	if hit and not target.is_downed:
		target.visual.play_hit_react_local()


## A hit landing at `at` — a swing connecting, a grenade going off. Sent to every
## ready client as well, each of which shows it only if it can see this unit.
func show_impact(at: Vector3, crit: bool) -> void:
	if visual.mirrors() and not TurnManager.resolving_tick:
		for peer_id in SteamLobby.ready_peers:
			_rpc_show_impact.rpc_id(peer_id, at, crit)
	_show_impact(at, crit)


@rpc("authority", "call_remote", "reliable")
func _rpc_show_impact(at: Vector3, crit: bool) -> void:
	_show_impact(at, crit)


func _show_impact(at: Vector3, crit: bool) -> void:
	if is_instant():
		return
	var vfx := get_tree().get_first_node_in_group("vfx")
	if vfx:
		vfx.impact(at, crit)


## Arms the muzzle hook for a burst that resolves NO shot — suppressing fire.
##
## Mirrors what `fire_at` sets up either side of its `play_burst`, minus the
## `ShotResult`, and that omission is the signal rather than an oversight:
## `_on_muzzle` reads a null shot as "these rounds were never going to hit
## anybody" and throws them all wide.
func _arm_covering_fire(target: Unit) -> void:
	_pending_shot = null
	_pending_target = target
	_burst_round = 0
	_burst_strays.clear()


## Clears the arming above, UNLESS a real shot has taken it over meanwhile.
##
## That is reachable, not defensive: the pinned unit breaking cover fires this
## suppressor's held shot (`TurnManager.check_suppression_break`), and the
## cosmetic burst it interrupted must not blank the break shot's impacts when it
## finishes a moment later.
func _disarm_covering_fire() -> void:
	if _pending_shot == null:
		_pending_target = null


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
## Priced identically to Shoot (`UnitStats.Action.OVERWATCH`, see BASE_AP_COST)
## rather than the old "commits whatever is left": `overwatch_reserve` is set to
## that fixed cost, not to the unit's whole remaining pool, so the reaction
## shot's accuracy (`Combat.overwatch_penalty_for`) reads the same regardless of
## when in the activation Overwatch is taken. The activation still ends outright
## once it is paid — `_end_activation_ap` forfeits anything left over, same as
## it always has.
func do_overwatch() -> void:
	var cost := action_cost(UnitStats.Action.OVERWATCH)
	# Paid BEFORE it is set: in exploration paying is acting, and acting lets go
	# of an overwatch (plan B.8) — this one must survive its own price (E22).
	pay(cost)
	on_overwatch = true
	overwatch_reserve = cost
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
	# Out of combat there is no activation to end, and no AP to forfeit.
	if _on_the_clock():
		return
	spend_ap(ap)


func do_reload() -> void:
	# Coroutine, unlike the other two — callers MUST `await`, or the unit will
	# still be reloading on screen when its next action resolves. A weapon on
	# magazines swaps one; anything else draws from `reserve` (spare rounds beyond
	# the loaded mag), where reserve < 0 means unlimited, so it's never decremented
	# — see WeaponData.starting_reserve.
	if not reserve_mags.is_empty():
		_swap_magazine()
	else:
		var needed := stats.mag_size - ammo
		var drawn := needed
		if reserve >= 0:
			drawn = mini(needed, reserve)
			reserve -= drawn
		ammo += drawn
	is_busy = true
	await visual.play_action(UnitVisual.RELOAD)
	is_busy = false


## Loads the fullest spare magazine, and the one coming out goes back on the vest
## with whatever it still holds. No round is lost, so `reserve` moves by exactly
## what the gun gained. Allowed even when it leaves the gun with less: can_reload
## asks only for a gun not full and a spare with rounds in it.
func _swap_magazine() -> void:
	var mags := reserve_mags
	var loaded := mags[0]
	mags[0] = ammo
	mags.sort()
	mags.reverse()
	reserve += ammo - loaded
	reserve_mags = mags  # after `reserve`, which re-deals them
	ammo = loaded


func toggle_flashlight() -> void:
	# Free action (0 AP, Sec 4.2) — on for detection range, off to stay dark.
	if not has_flashlight:
		return
	flashlight_on = not flashlight_on
	_record(ExplorationRules.EV_LIGHT, {"on": flashlight_on})
	visual.set_flashlight_enabled(flashlight_on)
	LightingManager.recompute_dynamic()
