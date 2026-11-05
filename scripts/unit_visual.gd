class_name UnitVisual
extends Node3D
## Owns a unit's 3D model and its animation state. Unit code drives this by
## intent ("play the shoot action"), never by clip name, which is what let the
## prerendered sprites be swapped back out for real 3D characters without `Unit`
## changing at all.
##
## THE MODEL IS THE CHARACTER. `tools/export_models.py` exports each rigged
## .blend to `assets/models/<variant>.glb` with its actions renamed to the pose
## names below, so `idle` here is `idle` there. The model is a child of this
## node, which shares the unit's basis, so it turns with the unit at any yaw and
## its feet are on the floor because the mesh is — there is no facing bucket, no
## canvas and no foot anchor left to tune. That is the whole reason for the
## switch: a vertical sprite card could not know how far in front of the root a
## planted boot was, so feet floated or sank depending on facing.
##
## Works with no authored model: `_build_placeholder` assembles a readable
## stand-in from primitive meshes (one part per entry in `layers`), and actions
## resolve on a timer of the length the real animation takes. That is the path
## every character without a .glb takes, and it keeps action pacing identical
## across the swap.

## Fired at the shot's muzzle frame. Drives the shot SFX and the impact at the
## far end, so a round arrives when the arm is up rather than the instant the
## order was given.
signal muzzle

## Fired once per MELEE action, at the frame the blow connects (STRIKE_AT).
## Unit.melee_at lands the damage on it, so the target reels as the fist
## arrives rather than when the swing has finished recovering. Always fires,
## art or not, on screen or not — `_play_action` guarantees it.
signal strike

## Fired as each boot lands during the run stance. Hook for footstep SFX and a
## camera shake — half of "heavy" is impact feedback, not joint angles.
signal footstep

# Stances persist until something changes them. Actions are one-shots that hand
# back to the current stance when they finish.
const IDLE := &"idle"
const RUN := &"run"
## Used only by `walks_only` units (the brawler), which have no other gait.
## See Unit.move_along.
const WALK := &"walk"
const OVERWATCH := &"overwatch_hold"
# There is no standalone crouch. Being down low is a COVER FAMILY, not a stance:
# `Unit.cover_pose` answers `low` for a unit behind a crate or hunkered, and
# every pose then resolves through the `_low` suffix (see COVER_LOW).

# Firing is driven by play_burst rather than one animation per shot type: the
# burst length is rolled per shot, and no fixed animation can match a count it
# does not know. AIM_HOLD is the weapon up and steady; BEGIN/FIRE/END are the
# rifle coming up, one round's kick (replayed per round) and lowering back out.
# Each degrades independently to AIM_HOLD, and the timers run either way, so
# burst pacing does not move as art lands.
const AIM_HOLD := &"aim_hold"
const BEGIN_SHOOT := &"begin_shoot"
const FIRE_SHOOT := &"fire_shoot"
const END_SHOOT := &"end_shoot"
# Transition: a one-shot bridging one stance into another, played through
# play_stance_exit. Degrades to a hard cut, at zero time cost, when absent.
const RUN_STOP := &"run_stop"
const MELEE := &"melee"
const RELOAD := &"reload"
const GRENADE := &"throw_grenade"
const INTERACT := &"interact"
const HIT_REACT := &"hit_react"
const DOWNED := &"downed"
## The corpse: a held stance the unit settles into once DOWNED has played out,
## and never leaves. A STANCE rather than DOWNED's last frame, because anything
## that re-plays `_stance` (a variant swap, coming back into view) would
## otherwise stand the body back up.
const DEAD := &"dead"
## Alien-side only: played once when an alien wakes, by EnemyUnit's state machine
## rather than by anything the player ordered.
const ALERT_SCREAM := &"alert_scream"
## Idle variation, played at random intervals while IDLE holds. See _fidget_loop.
const IDLE_FIDGET := &"idle_fidget"
## Optional feet-stepping clips for a big turn on the spot. See `_maybe_turn_clip`
## for when they play and the authoring contract.
const TURN_LEFT := &"turn_l90"
const TURN_RIGHT := &"turn_r90"
const TURN_AROUND := &"turn_180"

# When each boot lands during the run cycle, half a cycle apart. The run is
# played at exactly 2 x FOOTSTEP_GAP a cycle (LOOP_TIME) with a contact on its
# first frame, so the sound lands with the boot.
const FOOTSTEP_OFFSET := 0.0
const FOOTSTEP_GAP := 0.333

# Seconds of plain idle between attempts at an IDLE_FIDGET, rolled fresh each
# time so a room of aliens does not convulse in lockstep.
const FIDGET_GAP_MIN := 12.0
const FIDGET_GAP_MAX := 35.0

## How long each action occupies, so pacing is identical with or without an
## authored model. These are the game's turn-rhythm numbers, not measurements of
## any clip: an authored animation is time-scaled to fit them (see `_duration`),
## so changing one is a pacing decision, not a correction.
const FALLBACK_TIME := {
	BEGIN_SHOOT: RAISE_TIME,
	FIRE_SHOOT: BURST_CADENCE,
	END_SHOOT: SETTLE_TIME,
	MELEE: 1.20,
	RELOAD: 3.75,
	# The merc's `grenade` action is 37 frames at the rig's 12 fps, `interact`
	# 30, `get_hit` 7 and `die` 12 — stated as divisions so the clips play at
	# the speed they were animated.
	GRENADE: 37 / 12.0,
	INTERACT: 30 / 12.0,
	HIT_REACT: 7 / 12.0,
	DOWNED: 12 / 12.0,
	ALERT_SCREAM: 2.80,
}
const DEFAULT_FALLBACK_TIME := 0.4

# Burst timing. RAISE_TIME is the rifle being shouldered before the first round;
# BURST_CADENCE is the gap between rounds; SETTLE is the weapon held on target
# afterwards. RAISE is the dial to turn if combat starts feeling slow.
const RAISE_TIME := 0.45
const BURST_CADENCE := 0.11
const SETTLE_TIME := 0.20

## The same two beats when the shot is fired FROM COVER, where the phases are a
## step out from behind the crate and a duck back. Applied only when the cover
## animation actually resolved.
const COVER_RAISE_TIME := 0.75
const COVER_SETTLE_TIME := 0.45

## One-shot lengths per resolved pose, cover variants included. An animation is
## time-scaled to play in exactly this long; see `_duration`.
const ONE_SHOT_TIME := {
	BEGIN_SHOOT: RAISE_TIME, FIRE_SHOOT: BURST_CADENCE, END_SHOOT: SETTLE_TIME,
	&"begin_shoot_low": COVER_RAISE_TIME, &"end_shoot_low": COVER_SETTLE_TIME,
	&"begin_shoot_high": COVER_RAISE_TIME, &"end_shoot_high": COVER_SETTLE_TIME,
	MELEE: 1.20, RELOAD: 3.75, &"reload_low": 3.75, &"reload_high": 3.75,
	GRENADE: 37 / 12.0, INTERACT: 30 / 12.0,
	HIT_REACT: 7 / 12.0, &"hit_react_low": 7 / 12.0,
	DOWNED: 12 / 12.0, ALERT_SCREAM: 2.80,
	TURN_LEFT: 0.5, TURN_RIGHT: 0.5, TURN_AROUND: 0.7,
}

## Poses that cycle rather than play once and hold.
const LOOPING: Array[StringName] = [
	IDLE, RUN, WALK, OVERWATCH, AIM_HOLD, &"idle_low", &"idle_high", DEAD,
]

## Seconds ONE CYCLE of each looping stance takes. `run` is the one that is
## forced: two footsteps at FOOTSTEP_GAP. Stride length and move speed were
## tuned against these, so a faster or slower cycle is foot-skate.
const LOOP_TIME := {
	RUN: 2 * FOOTSTEP_GAP,
	WALK: 1.4,
	IDLE: 2.0,
	OVERWATCH: 32 / 12.0, AIM_HOLD: 1.6,
	&"idle_low": 2.4, &"idle_high": 2.4,
}
const DEFAULT_LOOP_TIME := 1.6

## Per-variant cycle times, for a gait tuned to its own unit's move speed.
const VARIANT_LOOP_TIME := {
	&"brawler": {WALK: 1.6},
	# 0.75 m/s crosses its one tile a turn in two seconds — one cycle.
	&"worm": {WALK: 2.0},
	# The civilian runs the merc's stride (tools/build_civilian_run.py) at a
	# third of his 4.5 m/s, so a third of the cadence keeps the feet planted.
	&"civilian": {RUN: 3 * 2 * FOOTSTEP_GAP},
	# The Mixamo zombie (tools/build_zombie_mixamo.py). Its run covers ~1.8 m a
	# cycle, played 1.5x fast: 0.8 s a cycle, so its move_speed (swarm_unit.tscn)
	# is 2.25 m/s to keep the feet planted — change the two together. The rest
	# are its clips' own lengths, or close: the neck bite plays whole at its
	# authored 4.2 s. Not loops, but `_duration` reads any pose from this table.
	# (Melee contact moments live in STRIKE_AT, below.)
	&"zombie": {RUN: 0.8, IDLE: 4.0, MELEE: 4.2, DOWNED: 3.0, ALERT_SCREAM: 2.8},
	# The security robot (assets/sec_robot_v2.blend, Mixamo clips retargeted by
	# tools/retarget_mixamo_robot.py). Its walk covers ~2.36 m a cycle, authored
	# at 1.42 s; played at 1.2 s so its move_speed (securus_unit.tscn) is
	# 1.95 m/s — change the two together. Idle and flinch play at their
	# authored 47 and 12 frames (the idle is tools/roboticize_robot.py's head
	# scan, IDLE_FRAMES). The hook punch is 26 frames (2.17 s) of guard,
	# wind-up, swing and recovery, played at 1.6 s; see STRIKE_AT for when it
	# connects.
	&"securus": {WALK: 1.2, IDLE: 47 / 12.0, MELEE: 1.6, HIT_REACT: 12 / 12.0, DOWNED: 12 / 12.0},
}

## When a variant's MELEE connects, as a fraction of the action's length:
## `strike` fires there and the damage lands with it. Absent means 1.0 — the
## end of the swing, which is right for every attack whose clip is all lunge
## and no recovery (and for the brawler and civilian, which swing their idle).
##
## MEASURED, not tuned: the frame the striking hand stops dead at full
## extension. Re-measure when the clip changes.
const STRIKE_AT := {
	# Right hook, re-timed by tools/roboticize_robot.py: held coiled on frames
	# 6-10, swings on 11-12, stops dead at full extension on 12 of the 27 keys
	# (26 intervals) -> 11 / 26. PUNCH_STRIKE_FRAME there.
	&"securus": 11.0 / 26.0,
}

## Crossfade between poses, in seconds. Short: the game's actions are brisk and
## a long blend reads as the unit being slow to respond.
const BLEND_TIME := 0.12

## Where the exported models live. `<variant>.glb` is the model; `<variant>.json`
## beside it is the sidecar export_models.py writes (per-pose yaw corrections,
## or for a worm pile the layout of its instances).
const MODEL_DIR := "res://assets/models/"

# --- Direction ---------------------------------------------------------------
#
# Facing is continuous (Unit._yaw_toward) and the model shows it through the
# free-turn layer below, so nothing here buckets facing. The eight-way table
# survives only because PlayerUnit.GRENADE_RELEASE_OFFSET is written in
# buckets, and tools/test_sprite_direction.gd pins the mapping.

## Screen-space directions, indexed by bucket, at the camera's start yaw.
const DIRECTIONS: Array[StringName] = [
	&"ne", &"n", &"nw", &"w", &"sw", &"s", &"se", &"e",
]

## Rotates the bucket window so each bucket is centred on a direction rather
## than straddling two.
const BUCKET_OFFSET := PI / 4.0

## Cover pose families. A unit using cover resolves every pose through the
## matching suffix FIRST — `idle` becomes `idle_low` — and falls back to the
## plain pose wherever that animation does not exist. See `_bases`.
const COVER_LOW := &"low"
const COVER_HIGH := &"high"

## Parts of the PLACEHOLDER, back to front. Ignored once a model exists for the
## variant: an authored model is one piece.
@export var layers: Array[StringName] = [&"body", &"head", &"helmet", &"weapon"]

## Which model to show: `assets/models/<variant>.glb`, or a pile layout
## `<variant>.json`. A gear swap is a reassignment of this — see `set_variant`.
@export var variant: StringName = &"soldier"

## Which gun to put in the model's hands: `assets/models/guns/<gun>.glb`. Empty
## takes the gun the model was animated with (its sidecar's `gun`). See
## `set_gun`, and MOUNT_NODE for what a gun has to look like to fit.
@export var gun: StringName = &""

## Uniform scale on the model. 1.0 is true size, which every export is authored
## at; the worm mass uses it to grow within a tier (WormUnit._apply_count).
@export var model_scale: float = 1.0:
	set(value):
		model_scale = value
		if _model:
			_model.scale = Vector3.ONE * model_scale

## Where in every LOOPING clip (idle, run...) this unit starts, as a fraction of
## the clip. One-shots always play from their first frame. A horde sets it per
## body so a room of the same model does not breathe and stride in lockstep.
var loop_phase: float = 0.0

## Whether this character carries the rig-mounted light (Sec 5.2). Aliens do not.
@export var has_light: bool = true

## Multiplied into every surface's albedo, so two factions can share one model
## and still be told apart at XCOM camera distance. White (identity) by default.
## A stopgap — the rival mercs wear the player's own model recoloured.
@export var faction_tint: Color = Color.WHITE

## Which family of shapes the placeholder is built from. `organic` is the
## standing biped; `machine` is the hard-edged read the security robots are
## specified with, so factions separate by silhouette in a dark corridor. Has no
## effect once a model exists.
@export var placeholder_style: StringName = &"organic"

## Whether this unit gets the MIN_BRIGHTNESS darkness floor. Off for fixtures
## like the nest: the floor exists so a unit in the dark stays findable, and on
## something that sits in the room it just glows against the unlit deck around it.
## Off for the Fodder too, by choice rather than as a fixture: on its pale skin the
## glow is a flat grey cut-out, and a horde you lose in the dark is the point.
@export var darkness_floor: bool = true

## Whether the beam's character hotspot (`_build_hotspot`, energy 60 on
## CHARACTER_LAYER) lights this unit. It is tuned to CLIP a character to full
## brightness, which pops dark gear out of the beam but blows a pale skin out to
## white, and the glow pass then blooms it into a gloss. Off, the unit is lit by
## the base beam exactly as the floor and walls are.
@export var takes_hotspot: bool = true

## Height of the placeholder figure, in metres — the old placeholder canvas.
const PLACEHOLDER_HEIGHT := 1.92
## Metres per placeholder "pixel": the machine specs below were drawn on a
## 64 px canvas PLACEHOLDER_HEIGHT tall, and keep their numbers.
const PLACEHOLDER_UNIT := PLACEHOLDER_HEIGHT / 64.0

## Fraction of its own colour a character surface emits on a fully DARK tile, so
## a unit in an unlit corner is a dim figure rather than a black hole — the job
## the sprites' MIN_TINT (0.35) did.
##
## Scaled down by the tile's light_value (see `_apply_floor`) and gone entirely
## at 100%. Applied flat, it lifted the shadowed side of a lit model nearly to
## its lit side: a pale texture (the nest's skin) lost its self-shadowing and
## read as ghostly under a flashlight. Where real light reaches the unit, real
## shading is all it gets. Driven by the same light_value the accuracy and
## detection rules read, so a unit that looks dark is one the rules treat as dark.
const MIN_BRIGHTNESS := 0.3

## The node in the merc's model marking the barrel tip, -Z down the bore. It is
## the old muzzle flash mesh, now hidden and read only for where it sits: the
## flash (MuzzleFlash, baked from assets/gun_vfx.blend) and the rig light both
## mount there.
const MUZZLE_NODE := "muzzle_flash"

## The node on the model's `weapon` bone a gun hangs from, at the trigger-hand
## grip. Every gun .glb is modelled to fit it: grip at the origin, barrel down
## -Z, top +Y, with a MUZZLE_NODE at the barrel tip and a `grip_support` where
## the left hand closes. The arm is baked to the animated gun's support grip, so
## a gun that moves `grip_support` leaves the left hand short of it.
## tools/standardize_gun_mount.py made the merc's.
const MOUNT_NODE := "weapon_mount"
const GUN_DIR := MODEL_DIR + "guns/"

## Inverted-hull outline, drawn as a second pass on every character surface in
## a darkened copy of that surface's own colour. See `_outline_for`.
const OUTLINE_SHADER := preload("res://shaders/outline.gdshader")
## Outline materials by the albedo they mirror, so every unit of a variant (and
## every surface sharing a texture and tint) shares one.
static var _outlines: Dictionary = {}

## Where a shot leaves the weapon, relative to the unit: shoulder height, and
## forward of the body. Derived from unit yaw rather than from the model, because
## LOS and the shot VFX read it and it is a rules point, not art.
const MUZZLE_HEIGHT := 1.4
const MUZZLE_REACH := 0.3
## Height the rig light is mounted at when the model has no muzzle to mount on.
const LIGHT_HEIGHT := 1.6
## Render layer 2, set on every character surface on top of the default layer 1:
## the flashlight's hotspot lights only this layer. See `_build_hotspot`.
const CHARACTER_LAYER := 1 << 1

## The model's container: turned by the pose's yaw correction and scaled by
## `model_scale`, so the imported scene itself is never touched.
var _model: Node3D = null
## One per model instance — a worm pile has several — all driven in lockstep.
var _players: Array[AnimationPlayer] = []
## Per player, the fraction of a cycle it runs ahead. Zero except in a pile,
## where sixteen worms in step would read as one drawing.
var _phases: Array[float] = []
## Poses this model can show. For a placeholder, every pose there is.
var _poses: Dictionary = {}
## pose -> degrees about Y, for an action authored facing somewhere else (the
## merc's `run`). From the export sidecar.
var _pose_yaw: Dictionary = {}
## The pose actually on screen, after cover and fallback resolution.
var _current: StringName = &""
## The model's barrel-tip marker (MUZZLE_NODE) and the flash mounted beside it.
var _muzzle: Node3D = null
var _flash: MuzzleFlash = null
## The model's MOUNT_NODE, or null for a model that holds no gun.
var _mount: Node3D = null
## The glowing eye's lens material and light, or null for a model with no
## EYE_NODE. See `_build_eye`.
var _eye_material: StandardMaterial3D = null
var _eye_light: OmniLight3D = null
## Placeholder only: the node posed to crouch or lie down, and the status light.
var _pose_root: Node3D = null
var _status_material: StandardMaterial3D = null
## This unit's own material copies that carry the darkness floor, re-scaled
## whenever the lighting changes.
var _floor_materials: Array[BaseMaterial3D] = []

var _light: SpotLight3D = null
## Kept apart from the light, which is rebuilt with the model on a variant swap.
var _light_on := true
var _unit: Node3D = null

var _stance: StringName = IDLE
var _action: StringName = &""
## True once a real model is found. Decides whether a hit flinch plays at all —
## see play_hit_react.
var _authored := false
var _stepping: bool = false
var _fidgeting: bool = false
## COVER_LOW, COVER_HIGH, or "" for a unit not using cover.
var _cover: StringName = &""
var _status_color := Color.WHITE


func _ready() -> void:
	# Children are ready before their parent, so Unit._ready can rely on these.
	_unit = get_parent() as Node3D
	_build_model()
	# After _build_model: the light mounts on the model's rifle.
	if has_light:
		_build_light()
	if LightingManager:
		LightingManager.lighting_changed.connect(_apply_floor)
		LightingManager.display_lighting_changed.connect(_apply_floor)


## Whether playback should resolve with no time on the clock. Delegated to the
## unit, because the answer changes DURING a move: a unit that walks into the
## squad's view stops being fast-forwarded partway through.
func _instant() -> bool:
	return _unit.is_instant() if _unit and _unit.has_method("is_instant") else false


func setup() -> void:
	_play(IDLE)
	_apply_floor()
	# Started here as well as from set_stance so a unit fidgets from the moment
	# it spawns.
	_maybe_start_fidget()


# --- Model construction ------------------------------------------------------


func _build_model() -> void:
	# Nothing to draw with no display. Every consumer handles an empty pose set:
	# _has_any returns false, the same answer a model missing a pose gives.
	if DisplayServer.get_name() == "headless":
		return
	_model = Node3D.new()
	_model.name = "Model"
	_model.scale = Vector3.ONE * model_scale
	add_child(_model)
	_players.clear()
	_phases.clear()
	_poses.clear()
	_pose_yaw.clear()
	_muzzle = null
	_flash = null
	_mount = null
	_eye_material = null
	_eye_light = null
	_aim_mod = null
	_health_band = null
	_band_glow = null
	_down_pips.clear()
	_pip_glows.clear()
	_ammo_bar = null
	_mag_pips.clear()
	_pose_root = null
	_status_material = null
	_floor_materials.clear()
	_current = &""
	var sidecar := _load_json(MODEL_DIR + String(variant) + ".json")
	if sidecar.has("pile_of"):
		_authored = _build_pile(sidecar)
	else:
		_authored = _build_single(sidecar)
	if not _authored:
		_build_placeholder()
	if _dead_tinted:
		_tint_materials(DEAD_TINT)  # a rebuilt corpse is still a corpse
	_apply_floor()


## PLACEHOLDER for a distinct corpse pose (extraction plan art list): a dead unit
## lies in the DOWNED pose like a downed one, and this greyed-out tint is the
## whole difference — enough to tell "can still be revived" from "can't" across
## the room. Multiplied into albedo, so it darkens whatever faction tint is there.
const DEAD_TINT := Color(0.42, 0.42, 0.46)
var _dead_tinted := false


## Tints the model as a corpse (or, with false, restores it — nothing does yet:
## death is permanent). Safe to call repeatedly and on a headless build, which
## has no model to tint.
func set_dead_tint(on: bool) -> void:
	if on == _dead_tinted:
		return
	_dead_tinted = on
	if on:
		_tint_materials(DEAD_TINT)
	else:
		_tint_materials(Color(1.0 / DEAD_TINT.r, 1.0 / DEAD_TINT.g, 1.0 / DEAD_TINT.b))
	_apply_eye()


# --- The glowing eye -----------------------------------------------------------
#
# A model that has an EYE_NODE (an Empty on its head bone in the .blend, placed
# by tools/add_eye_socket.py — the security robot's camera lens) gets a lit red
# lens there and a small light that throws red on whatever is close: the read,
# across a dark deck, that one of the things is looking at you. It rides the
# head through every animation and the ragdoll, and goes dark with the body.

const EYE_NODE := "eye"
const EYE_COLOR := Color(1.0, 0.06, 0.03)
## Lens radius, in the model's own units (the robot's rig is scaled 0.93).
const EYE_RADIUS := 0.032
## Well over the environment's glow_hdr_threshold (main.tscn), so it blooms.
const EYE_EMISSION := 6.0
## Kept low: at 0.8 / 1.4 m it washed the whole chest red and the eye stopped
## reading as a point. This is a spill on the deck and the shoulders.
const EYE_LIGHT_ENERGY := 0.35
const EYE_LIGHT_RANGE := 1.0
## How far in front of the lens the light sits, metres, along the facing.
const EYE_LIGHT_LEAD := 0.25


func _build_eye(inst: Node) -> void:
	var socket := inst.find_child(EYE_NODE, true, false) as Node3D
	if socket == null:
		return
	var lens := MeshInstance3D.new()
	lens.name = "EyeLens"
	var sphere := SphereMesh.new()
	sphere.radius = EYE_RADIUS
	sphere.height = EYE_RADIUS * 2.0
	sphere.radial_segments = 12
	sphere.rings = 6
	lens.mesh = sphere
	lens.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_eye_material = _glow_material()
	lens.material_override = _eye_material
	socket.add_child(lens)
	_eye_light = OmniLight3D.new()
	_eye_light.name = "EyeGlow"
	_eye_light.light_color = EYE_COLOR
	_eye_light.omni_range = EYE_LIGHT_RANGE
	_eye_light.omni_attenuation = 2.0
	_eye_light.shadow_enabled = false
	_eye_light.light_specular = 0.0
	_eye_light.light_volumetric_fog_energy = 0.0
	socket.add_child(_eye_light)
	# In front of the face, so it lights what the robot looks at and not the
	# inside of its own head. The socket's axes are the head bone's, so "in
	# front" (model -Z) is carried into them through the REST pose — the bone
	# attachment has not been posed yet while the model is being built.
	var socket_in_model := _rest_in(socket, inst)
	var ahead := socket_in_model.basis.inverse() * Vector3(0, 0, -1)
	_eye_light.position = ahead.normalized() * EYE_LIGHT_LEAD / socket_in_model.basis.get_scale().x
	_apply_eye()


## `node`'s transform relative to `top` with every skeleton at rest: a bone
## attachment counts as sitting on its bone's rest, whatever it was last posed to.
static func _rest_in(node: Node3D, top: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != top:
		if n is BoneAttachment3D and n.get_parent() is Skeleton3D:
			var skel := n.get_parent() as Skeleton3D
			t = skel.get_bone_global_rest(skel.find_bone((n as BoneAttachment3D).bone_name)) * t
		elif n is Node3D:
			t = (n as Node3D).transform * t
		n = n.get_parent()
	return t


## Lit while the unit lives; a dark lens once it is dead.
func _apply_eye() -> void:
	if _eye_material == null:
		return
	var lit := not _dead_tinted
	_set_glow(_eye_material, EYE_COLOR, EYE_EMISSION if lit else 0.0)
	_eye_light.visible = lit


func _tint_materials(tint: Color) -> void:
	for mat in _floor_materials:
		mat.albedo_color *= tint
		mat.emission = mat.albedo_color


## One .glb. Returns false when the variant has none.
func _build_single(sidecar: Dictionary) -> bool:
	var scene := _load_scene(variant)
	if scene == null:
		return false
	var inst := scene.instantiate() as Node3D
	_model.add_child(inst)
	_adopt_players(inst, 0.0)
	var yaw: Variant = sidecar.get("pose_yaw_degrees", {})
	if yaw is Dictionary:
		for pose: String in yaw:
			_pose_yaw[StringName(pose)] = float(yaw[pose])
	# Before the muzzle lookup and dressing: the muzzle is on the gun, and the
	# gun is tinted and outlined like the rest of the model.
	_mount_gun(inst, gun if gun != &"" else StringName(sidecar.get("gun", "")))
	_muzzle = inst.find_child(MUZZLE_NODE, true, false) as Node3D
	if _muzzle:
		_muzzle.visible = false
	# Before dressing, which skips them: they glow, so no tint or outline.
	_find_status_lights(inst)
	_dress_surfaces(inst)
	# After dressing, which would otherwise tint and outline the flash too.
	_mount_flash()
	_build_eye(inst)  # likewise: a glow, not a surface
	_bind_aim(inst)
	return true


## Hangs `gun_name`'s .glb on the model's MOUNT_NODE. A model with no mount, or
## a gun with no .glb, is left empty-handed.
func _mount_gun(inst: Node, gun_name: StringName) -> void:
	_mount = inst.find_child(MOUNT_NODE, true, false) as Node3D
	var path := GUN_DIR + String(gun_name) + ".glb"
	if _mount == null or gun_name == &"" or not ResourceLoader.exists(path):
		return
	_mount.add_child((load(path) as PackedScene).instantiate())


## A worm mass: N copies of the single worm laid out by export_models.py, each a
## fraction of a cycle out of step. One shared asset, and the mass IS its worms.
func _build_pile(layout: Dictionary) -> bool:
	var scene := _load_scene(StringName(layout.get("pile_of", "")))
	if scene == null:
		return false
	for entry: Variant in layout.get("instances", []):
		if not (entry is Dictionary):
			continue
		var rows: Array = entry.get("basis", [])
		var o: Array = entry.get("origin", [0, 0, 0])
		var inst := scene.instantiate() as Node3D
		if rows.size() == 3:
			# Rows in the file; Basis takes columns.
			inst.transform = Transform3D(
				Basis(Vector3(rows[0][0], rows[1][0], rows[2][0]),
					Vector3(rows[0][1], rows[1][1], rows[2][1]),
					Vector3(rows[0][2], rows[1][2], rows[2][2])),
				Vector3(o[0], o[1], o[2]))
		_model.add_child(inst)
		_adopt_players(inst, float(entry.get("phase", 0.0)))
		_dress_surfaces(inst)
	# The pile's own pose list, not the worm's: a mass has no `melee`.
	var poses: Variant = layout.get("poses")
	if poses is Array:
		var allowed := {}
		for p: Variant in poses:
			allowed[StringName(p)] = true
		for p: StringName in _poses.keys():
			if not allowed.has(p):
				_poses.erase(p)
	return not _players.is_empty()


static func _load_scene(model: StringName) -> PackedScene:
	var path := MODEL_DIR + String(model) + ".glb"
	if model == &"" or not ResourceLoader.exists(path):
		return null
	return load(path) as PackedScene


static func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _adopt_players(inst: Node, phase: float) -> void:
	for node in inst.find_children("*", "AnimationPlayer", true, false):
		var player := node as AnimationPlayer
		for name in player.get_animation_list():
			_poses[StringName(name)] = true
			# The imported resource is shared by every unit of the variant, so
			# setting this is idempotent rather than per-unit.
			player.get_animation(name).loop_mode = Animation.LOOP_LINEAR \
				if StringName(name) in LOOPING else Animation.LOOP_NONE
		_players.append(player)
		_phases.append(phase)


## Hangs a MuzzleFlash on the rifle at the marker's rest transform. A sibling of
## the marker rather than its child: `fire_shoot` animates the marker's scale to
## nothing, which would take the flash with it before it ever showed.
func _mount_flash() -> void:
	var barrel := _muzzle.get_parent() as Node3D if _muzzle else null
	if barrel == null:
		return
	_flash = MuzzleFlash.new()
	_flash.name = "MuzzleFlash"
	barrel.add_child(_flash)
	_flash.transform = _muzzle.transform


## Per-unit copies of the model's materials, carrying the faction tint and the
## darkness floor.
##
## Metallic is zeroed. No character is metal-skinned, but the glTF round trip
## brings every material in at metallic 0.5 on a packed metal/roughness map —
## the source .blends leave Metallic unplugged — which laid a grey sheen over
## pale surfaces that the sprite renders never had.
##
## The roughness map is dropped too. The only models that carry one are the
## Mixamo ones (zombie, civilian, nest), and theirs is the Glossiness map wired
## in as roughness — the inverse — so matte skin rendered near-mirror and blew
## out to white under any nearby light. Without it the material's own roughness
## (1.0 on those) holds: fully matte, which is what that skin should read as.
func _dress_surfaces(root: Node) -> void:
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if mesh.mesh == null or mesh == _muzzle or mesh == _health_band \
				or mesh in _down_pips or mesh == _ammo_bar or mesh in _mag_pips:
			continue
		if takes_hotspot:
			mesh.layers |= CHARACTER_LAYER
		for s in mesh.mesh.get_surface_count():
			var src := mesh.get_active_material(s) as BaseMaterial3D
			if src == null:
				continue
			var mat := src.duplicate() as BaseMaterial3D
			mat.albedo_color *= faction_tint
			mat.metallic = 0.0
			mat.metallic_texture = null
			mat.roughness_texture = null
			_add_floor(mat)
			mat.next_pass = _outline_for(mat)
			mesh.set_surface_override_material(s, mat)


## The outline pass for `mat`: its albedo colour and texture (faction tint
## already multiplied in), which the shader samples at the same UV and darkens.
static func _outline_for(mat: BaseMaterial3D) -> ShaderMaterial:
	var key := [mat.albedo_texture, mat.albedo_color, mat.uv1_scale, mat.uv1_offset]
	var outline: ShaderMaterial = _outlines.get(key)
	if outline == null:
		outline = ShaderMaterial.new()
		outline.shader = OUTLINE_SHADER
		outline.set_shader_parameter("albedo_color", mat.albedo_color)
		if mat.albedo_texture:
			outline.set_shader_parameter("albedo_texture", mat.albedo_texture)
		outline.set_shader_parameter("uv1_scale", mat.uv1_scale)
		outline.set_shader_parameter("uv1_offset", mat.uv1_offset)
		_outlines[key] = outline
	return outline


## Makes `mat` able to emit its own colour, and registers it for `_apply_floor`
## to set how much.
func _add_floor(mat: BaseMaterial3D) -> void:
	mat.emission_enabled = true
	mat.emission = mat.albedo_color
	mat.emission_texture = mat.albedo_texture
	_floor_materials.append(mat)


## Sets the darkness floor from the light on the unit's own tile: MIN_BRIGHTNESS
## in the dark, nothing at 100% light. See MIN_BRIGHTNESS.
func _apply_floor() -> void:
	var lit := 0.0
	if _unit:
		# The tile the MODEL stands on, read through the display layer: during a
		# tick's playback the model is not where the unit's root already is.
		var tile: Vector3i = _unit.get("grid_pos")
		if LightingManager.is_displaying():
			tile = GridManager.world_to_grid(global_position)
		lit = clampf(LightingManager.display_light(tile) / 100.0, 0.0, 1.0)
	var energy := MIN_BRIGHTNESS * (1.0 - lit) if darkness_floor else 0.0
	for mat in _floor_materials:
		mat.emission_energy_multiplier = energy


## Swaps the model — a gear swap, or a worm mass changing tier.
func set_variant(new_variant: StringName) -> void:
	variant = new_variant
	# Headless builds no model at all, and a variant swap happens in the AI's own
	# turn (WormUnit grows its pile) and so in every headless test run.
	if _model == null:
		return
	# Freed NOW, not queued: WormUnit swaps in the same frame the first model was
	# built, and a queued free of meshes the renderer has not yet drawn once
	# leaves it reading their materials after they are gone.
	# A fallen body's physics pose lives on the old skeleton; the new model
	# rests in the authored corpse pose instead (`_stance` is already DEAD).
	_drop_ragdoll()
	remove_child(_model)
	_model.free()
	_model = null
	# The light rode the old rifle and went with it — unless it was the fallback
	# one hung on this node, which would otherwise be doubled.
	if is_instance_valid(_light):
		_light.free()
	_light = null
	_build_model()
	if has_light:
		_build_light()
	_play(_action if _action != &"" else _stance, true)


## Swaps the gun in the model's hands. The animation is untouched: every gun
## shares the grip, so the same poses hold any of them.
func set_gun(new_gun: StringName) -> void:
	if new_gun == gun:
		return
	gun = new_gun
	# A model with no mount (an alien, the placeholder) has nothing to swap, and
	# a rebuild would only restart its animation. Before _ready there is no
	# model yet either; _build_model reads `gun` when it gets there.
	if _mount != null:
		set_variant(variant)


## A plain SpotLight3D riding the rifle: placed on the barrel tip and pointed
## down the bore, so it follows the weapon bone through every animation with no
## per-frame bookkeeping. Rebuilt with the model, which owns the rifle.
##
## Hung off the muzzle marker's PARENT (the rifle mesh) at the marker's
## transform, not off the marker itself: `fire_shoot` animates its scale to
## nothing, which would collapse the light's basis mid-burst. The marker's -Z
## runs down the bore, which is also a light's forward, so its rotation carries
## straight over.
##
## A model with no muzzle, or the placeholder, gets the light at chest height
## pointing straight ahead.
##
## Carries a second, character-only light as a child — see `_build_hotspot`.
func _build_light() -> void:
	_light = SpotLight3D.new()
	_light.name = "Flashlight"
	_light.light_color = Color(0.94, 0.96, 1.0)
	_light.light_energy = 7.0
	# THE VISIBLE CONE: main.tscn has volumetric fog, so this is the whole of the
	# shaft between the barrel and the pool. The dial for how present it is.
	_light.light_volumetric_fog_energy = 2.0
	_light.shadow_enabled = true
	_light.shadow_blur = 0.6
	_light.spot_range = 9.0
	# Matches LightingManager.FLASHLIGHT_CONE_DEGREES (90, so half-angle 45):
	# what you see lit is what the unit can actually see by.
	_light.spot_angle = 45.0
	_light.spot_attenuation = 1.5
	_light.spot_angle_attenuation = 2.5
	_light.visible = _light_on
	_light.add_child(_build_hotspot())
	var barrel := _muzzle.get_parent() as Node3D if _muzzle else null
	if barrel:
		barrel.add_child(_light)
		_light.transform = Transform3D(_muzzle.transform.basis.orthonormalized(),
			_muzzle.transform.origin)
	else:
		add_child(_light)
		_light.position = Vector3(0.0, LIGHT_HEIGHT, 0.0)


## THE HARSH LOOK ON WHAT THE BEAM CATCHES, borrowed from the overhead fixtures
## (light_source.gd): a hot source with a steep falloff, so a character within
## two or three tiles blows out past 1.0 and clips to white (the environment
## has no tonemapper and glows above 1.1), fading to nothing extra by the far
## end of the beam. Stacked on the plain flashlight and culled to
## CHARACTER_LAYER, so the floor and walls keep the ordinary pool while mercs
## and creatures get the stark, hard-shadowed top light the fixtures give.
##
## The cull mask applies to its shadow casters too, so scenery does not shadow
## it: a character just behind a crate inside the cone still catches it. Rare
## at these ranges, and cheaper than a second light that lit everything.
func _build_hotspot() -> SpotLight3D:
	var hot := SpotLight3D.new()
	hot.name = "Hotspot"
	hot.light_color = _light.light_color
	# Energy and attenuation are a pair: clipping out to three tiles or so, then
	# the range window (spot_range, shared with the base light) fades it out.
	hot.light_energy = 60.0
	hot.spot_attenuation = 2.0
	hot.light_volumetric_fog_energy = 0.0  # the base light owns the shaft
	hot.light_cull_mask = CHARACTER_LAYER
	hot.shadow_enabled = true
	hot.shadow_blur = 0.1  # hard-edged, like the ceiling lights
	hot.spot_range = _light.spot_range
	hot.spot_angle = _light.spot_angle
	# Even across the disc and sharp at the rim, as the fixtures are.
	hot.spot_angle_attenuation = 1.0
	return hot


## Which way the beam points right now, in world space — LightingManager aims
## its cone by this, so the tiles the rules light are the ones lit on screen.
## Unit facing where there is no light (headless, or a character without one).
##
## CORRECTED FOR THE TURN STILL IN FLIGHT. The body lags the aim on purpose (the
## free-turn layer), so for a moment after every turn the gun, and the light on
## it, still points where the unit used to look. The rules must not read that
## lag: the light's own direction is turned on by however much of the turn the
## model has yet to show, which is exactly where it will point once settled.
## Settled, the correction is zero and this is the bare light, as it always was.
func aim_direction() -> Vector3:
	if _light and _light.is_inside_tree():
		var beam := -_light.global_transform.basis.z.normalized()
		return beam.rotated(Vector3.UP, _turn_pending())
	return -global_transform.basis.z.normalized()


## Whether the rig light is drawn on right now — what the display layer casts
## from during playback, where `flashlight_on` is already the final answer.
func light_shown() -> bool:
	return _light_on


func set_flashlight_enabled(on: bool) -> void:
	_mirror(&"_rpc_set_flashlight_enabled", [on])
	_set_flashlight_enabled(on)


func _set_flashlight_enabled(on: bool) -> void:
	_light_on = on
	if _light:
		_light.visible = on


## THE SUIT'S STATUS LIGHTS (tools/add_merc_lights.py): a band down the back in
## the colour of the soldier's HP bracket, and a pip on the right breast per down
## taken -- the third down kills, so the third pip lights on a corpse. Hidden
## until `set_status_lights` is first called, so a model that carries them but is
## not a squad soldier (the rival crew wears the same suit) never shows them.
const HEALTH_BAND_NODE := "health_band"
const DOWN_PIP_NODES: Array[String] = ["down_pip_1", "down_pip_2", "down_pip_3"]
## [HP fraction at or above which, band colour], highest first.
const HEALTH_BRACKETS := [
	[0.9, Color(0.2, 1.0, 0.8)],  # blue-green
	[0.7, Color(0.35, 1.0, 0.3)],  # green
	[0.4, Color(1.0, 0.62, 0.1)],  # amber
	[0.0, Color(1.0, 0.12, 0.08)],  # red
]
const DOWNED_BAND_COLOR := Color(1.0, 0.12, 0.08)
const PIP_COLOR := Color(1.0, 0.1, 0.06)
## A lit light's emission energy: enough to clear the environment's glow
## threshold for a soft halo.
const LIGHT_ENERGY := 1.6
## A dark lens, so an unlit pip or a dead band still reads as hardware.
const LIGHT_OFF_COLOR := Color(0.06, 0.06, 0.07)
## Seconds per pulse of the downed band, and how far it dims at the trough.
const DOWNED_PULSE_TIME := 1.4
const DOWNED_PULSE_LOW := 0.2
## The band's spill onto its surroundings: a dim, shadowless omni a hand's width
## off the band, in its colour. Kept faint -- a hint on the floor and the wall
## behind a soldier, not a lamp. Rides this bone, which the band mostly covers.
const BAND_GLOW_ENERGY := 0.175
const BAND_GLOW_RANGE := 0.75
const BAND_GLOW_OFFSET := 0.12
const GLOW_BONE := "chest"
## Each lit pip's spill: the same kind of light, much smaller.
const PIP_GLOW_ENERGY := 0.0875
const PIP_GLOW_RANGE := 0.375
const PIP_GLOW_OFFSET := 0.04
## THE AMMO READOUT. A bar on the primary's right side (tools/add_gun_ammo_bars.py)
## that drains toward the stock, and a pip on the back per spare magazine
## (tools/add_merc_lights.py), fullest at the bottom and dark once empty. Bar and
## pips share AMMO_BRACKETS, so a colour means the same amount in either. Always
## the primary: a soldier with the sidearm out still holds the primary's model,
## which is the gun the bar is on.
const AMMO_BAR_NODE := "ammo_bar"
const MAG_PIP_NODES: Array[String] = [
	"mag_pip_1", "mag_pip_2", "mag_pip_3", "mag_pip_4", "mag_pip_5", "mag_pip_6",
]
## [magazine fraction at or above which, colour], highest first. The cuts put
## every size of magazine through all three: a 3-round mag reads pale yellow,
## orange, red, then an empty bar shows nothing.
const AMMO_BRACKETS := [
	[0.7, Color(1.0, 0.92, 0.55)],  # pale yellow
	[0.35, Color(1.0, 0.48, 0.05)],  # orange
	[0.0, Color(1.0, 0.1, 0.05)],  # red
]
## At 1.0 rather than LIGHT_ENERGY: the environment has no tonemapper, so anything
## brighter clips, which would turn the orange yellow and the pale yellow white.
const AMMO_LIGHT_ENERGY := 1.0

var _ammo_bar: MeshInstance3D = null
var _ammo_bar_material: StandardMaterial3D = null
var _mag_pips: Array[MeshInstance3D] = []
var _mag_pip_materials: Array[StandardMaterial3D] = []

var _health_band: MeshInstance3D = null
var _band_glow: OmniLight3D = null
var _down_pips: Array[MeshInstance3D] = []
## One per pip, in step with `_down_pips`; null where the model has no chest bone.
var _pip_glows: Array[OmniLight3D] = []
var _band_material: StandardMaterial3D = null
var _pip_materials: Array[StandardMaterial3D] = []
var _band_pulse: Tween = null
## The last state handed to set_status_lights, kept so a model rebuild (gear or
## gun swap) comes back showing it. Empty: never set, lights hidden.
var _status_lights: Dictionary = {}


## Shows the status lights. `hp_fraction` picks the band's bracket while the
## soldier is up; downed, the band pulses red instead, and dead it goes dark.
## `downs` lights that many pips. `mag_fraction` sets the ammo bar, and
## `spare_mags` holds how full each spare magazine is, fullest first, one pip each;
## dead, both go dark. Cheap to call on every change: an unchanged state is
## ignored, so a running pulse is not restarted.
func set_status_lights(hp_fraction: float, downs: int, downed: bool, dead: bool,
		mag_fraction: float, spare_mags: Array) -> void:
	var state := {"hp": hp_fraction, "downs": downs, "downed": downed, "dead": dead,
		"mag": mag_fraction, "spare_mags": spare_mags}
	if state == _status_lights:
		return
	_status_lights = state
	_apply_status_lights()


## Picks the lights out of a freshly built model and gives each its own glow
## material, so every pip can be lit on its own.
func _find_status_lights(inst: Node) -> void:
	_health_band = inst.find_child(HEALTH_BAND_NODE, true, false) as MeshInstance3D
	_band_material = null
	_band_glow = null
	if _health_band:
		_band_material = _glow_material()
		_health_band.material_override = _band_material
		_band_glow = _build_glow(_health_band, BAND_GLOW_RANGE, BAND_GLOW_OFFSET)
	_down_pips.clear()
	_pip_materials.clear()
	_pip_glows.clear()
	for node_name in DOWN_PIP_NODES:
		var pip := inst.find_child(node_name, true, false) as MeshInstance3D
		if pip:
			var mat := _glow_material()
			pip.material_override = mat
			_down_pips.append(pip)
			_pip_materials.append(mat)
			_pip_glows.append(_build_glow(pip, PIP_GLOW_RANGE, PIP_GLOW_OFFSET))
	_ammo_bar = inst.find_child(AMMO_BAR_NODE, true, false) as MeshInstance3D
	_ammo_bar_material = null
	if _ammo_bar:
		_ammo_bar_material = _glow_material()
		_ammo_bar.material_override = _ammo_bar_material
	_mag_pips.clear()
	_mag_pip_materials.clear()
	for node_name in MAG_PIP_NODES:
		var pip := inst.find_child(node_name, true, false) as MeshInstance3D
		if pip:
			var mat := _glow_material()
			pip.material_override = mat
			_mag_pips.append(pip)
			_mag_pip_materials.append(mat)
	_apply_status_lights()


## Hangs a status light's spill on GLOW_BONE, just out from `mesh`'s middle. The
## lights are skinned, so their own nodes never move; the bone does. Placed from
## the rest pose: the mesh's centre, pushed `offset` out along the level line
## from the bone to it. Null on a model without the bone.
func _build_glow(mesh: MeshInstance3D, glow_range: float, offset: float) -> OmniLight3D:
	var skeleton := mesh.get_node_or_null(mesh.skeleton) as Skeleton3D
	var bone := skeleton.find_bone(GLOW_BONE) if skeleton else -1
	if bone < 0:
		return null
	var rest := skeleton.get_bone_global_rest(bone)
	var to_skeleton := skeleton.global_transform.affine_inverse() * mesh.global_transform
	var centre := to_skeleton * mesh.get_aabb().get_center()
	var out := centre - rest.origin
	out.y = 0.0
	var attach := BoneAttachment3D.new()
	attach.name = "%sGlowMount" % mesh.name
	attach.bone_name = GLOW_BONE
	skeleton.add_child(attach)
	var glow := OmniLight3D.new()
	glow.name = "%sGlow" % mesh.name
	glow.omni_range = glow_range
	glow.omni_attenuation = 2.0
	glow.shadow_enabled = false
	glow.light_volumetric_fog_energy = 0.0
	glow.light_specular = 0.0
	glow.position = rest.affine_inverse() * (centre + out.normalized() * offset)
	attach.add_child(glow)
	return glow


## The band and its glow together. `level` scales both, for the downed pulse.
func _set_band(color: Color, level: float) -> void:
	_set_glow(_band_material, color, LIGHT_ENERGY * level)
	if _band_glow:
		_band_glow.light_color = color
		_band_glow.light_energy = BAND_GLOW_ENERGY * level
		_band_glow.visible = level > 0.0


func _set_band_level(level: float) -> void:
	_set_band(_band_material.emission, level)


static func _glow_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.roughness = 1.0
	mat.metallic_specular = 0.0
	mat.emission_enabled = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


## Lit: all emission on a black body, so the colour is its own whatever light
## falls on it. Off: the dark lens.
static func _set_glow(mat: StandardMaterial3D, color: Color, energy: float) -> void:
	mat.albedo_color = Color.BLACK if energy > 0.0 else LIGHT_OFF_COLOR
	mat.emission = color
	mat.emission_energy_multiplier = energy


func _apply_status_lights() -> void:
	var shown := not _status_lights.is_empty()
	if _health_band:
		_health_band.visible = shown
	if _band_glow:
		_band_glow.visible = shown
	for pip in _down_pips:
		pip.visible = shown
	for glow in _pip_glows:
		if glow:
			glow.visible = shown
	if _band_pulse:
		_band_pulse.kill()
		_band_pulse = null
	_apply_ammo_lights()
	if not shown:
		return
	var dead: bool = _status_lights.dead
	if _band_material:
		if dead:
			_set_band(LIGHT_OFF_COLOR, 0.0)
		elif _status_lights.downed:
			_set_band(DOWNED_BAND_COLOR, 1.0)
			_band_pulse = create_tween().set_loops()
			_band_pulse.set_trans(Tween.TRANS_SINE)
			_band_pulse.tween_method(_set_band_level, 1.0, DOWNED_PULSE_LOW,
				DOWNED_PULSE_TIME / 2.0)
			_band_pulse.tween_method(_set_band_level, DOWNED_PULSE_LOW, 1.0,
				DOWNED_PULSE_TIME / 2.0)
		else:
			_set_band(_bracket_color(_status_lights.hp), 1.0)
	var downs: int = _status_lights.downs
	for i in _pip_materials.size():
		var lit := i < downs
		_set_glow(_pip_materials[i], PIP_COLOR if lit else LIGHT_OFF_COLOR,
			LIGHT_ENERGY if lit else 0.0)
		var glow := _pip_glows[i]
		if glow:
			glow.light_color = PIP_COLOR
			glow.light_energy = PIP_GLOW_ENERGY
			glow.visible = lit


## An empty bar is hidden outright rather than scaled to nothing: a zero scale is
## a degenerate basis to the renderer.
func _apply_ammo_lights() -> void:
	var shown := not _status_lights.is_empty()
	var dead: bool = shown and _status_lights.dead
	if _ammo_bar:
		var mag: float = _status_lights.mag if shown and not dead else 0.0
		_ammo_bar.visible = mag > 0.0
		if mag > 0.0:
			_ammo_bar.scale.z = minf(mag, 1.0)
			_set_glow(_ammo_bar_material, _ammo_color(mag), AMMO_LIGHT_ENERGY)
	var spare: Array = _status_lights.spare_mags if shown and not dead else []
	for i in _mag_pips.size():
		_mag_pips[i].visible = shown
		var fill: float = spare[i] if i < spare.size() else 0.0
		_set_glow(_mag_pip_materials[i], _ammo_color(fill) if fill > 0.0 else LIGHT_OFF_COLOR,
			AMMO_LIGHT_ENERGY if fill > 0.0 else 0.0)


static func _ammo_color(mag_fraction: float) -> Color:
	for bracket: Array in AMMO_BRACKETS:
		if mag_fraction >= bracket[0]:
			return bracket[1]
	return AMMO_BRACKETS[-1][1]


static func _bracket_color(hp_fraction: float) -> Color:
	for bracket: Array in HEALTH_BRACKETS:
		if hp_fraction >= bracket[0]:
			return bracket[1]
	return HEALTH_BRACKETS[-1][1]


## Re-asserts whatever the unit should be showing, for a unit coming back into
## view (Unit.set_rendered). Nothing plays while a unit is instant, so without
## this the model keeps whatever it showed when it went out of sight — which for
## a unit killed there is standing up rather than lying where it fell.
func refresh() -> void:
	snap_facing()
	_play(_action if _action != &"" else _stance, true)


## Static so the mapping can be checked without a scene — see
## tools/test_sprite_direction.gd.
static func direction_bucket(relative_yaw: float) -> int:
	return wrapi(roundi((relative_yaw + BUCKET_OFFSET) / (TAU / DIRECTIONS.size())),
		0, DIRECTIONS.size())


## The poses to try for `base`, most specific first: the current cover family's
## variant, then the plain pose. A cover animation that does not exist costs
## nothing — the plain pose answers instead.
func _bases(base: StringName) -> Array[StringName]:
	if _cover == &"":
		return [base]
	return [&"%s_%s" % [base, _cover], base]


## Which candidate `base` resolves to — the cover variant or the plain pose — or
## "" if the model has neither.
func _resolved_base(base: StringName) -> StringName:
	for candidate in _bases(base):
		if _poses.has(candidate):
			return candidate
	return &""


func _has_any(base: StringName) -> bool:
	return _resolved_base(base) != &""


## Seconds `pose` occupies on screen — a full cycle for a looping stance, the
## whole clip for a one-shot. The authored clip is time-scaled to this.
func _duration(pose: StringName) -> float:
	var per_variant: Dictionary = VARIANT_LOOP_TIME.get(variant, {})
	if per_variant.has(pose):
		return per_variant[pose]
	if pose in LOOPING:
		return LOOP_TIME.get(pose, DEFAULT_LOOP_TIME)
	return ONE_SHOT_TIME.get(pose, FALLBACK_TIME.get(pose, DEFAULT_FALLBACK_TIME))


# --- Co-op mirroring ---------------------------------------------------------
#
# Every action resolves on the host alone (PlayerUnit._issue), and the unit's
# synchronizer streams only where it is, never what it is doing — so a client's
# copy slid across the deck in idle and never fired, reloaded or flinched. Each
# public driver below therefore forwards itself to every ready client before it
# plays here, and the client runs the local-only `_` version, which is what the
# drivers call among themselves too so a nested call is never sent twice.
#
# Sent BEFORE the host's own `_instant` check: whether the HOST can see the unit
# says nothing about whether a client can, and the client answers that for
# itself through its own `_instant`.


## True on the host of a co-op session — the only peer that sends.
func mirrors() -> bool:
	return multiplayer.has_multiplayer_peer() and multiplayer.is_server() \
			and not SteamLobby.ready_peers.is_empty()


## Per ready peer rather than a broadcast, for the reason the unit's
## synchronizer starts hidden: a client that has not built this node yet cannot
## resolve the path. See SteamLobby.ready_peers.
func _mirror(rpc_method: StringName, args: Array = []) -> void:
	if not mirrors():
		return
	for peer_id in SteamLobby.ready_peers:
		callv(&"rpc_id", [peer_id, rpc_method] + args)


## A one-shot (an action, a flinch, a burst) is not sent while a tick is being
## decided: nothing plays on the host then either, and the whole tick reaches
## clients afterwards as one timeline (exploration plan C.9). State — stance,
## cover family, lamp, status light — still goes, since nothing replays it.
func _mirror_one_shot(rpc_method: StringName, args: Array = []) -> void:
	if TurnManager.resolving_tick:
		return
	_mirror(rpc_method, args)


@rpc("authority", "call_remote", "reliable")
func _rpc_set_cover_pose(family: StringName) -> void:
	_set_cover_pose(family)


@rpc("authority", "call_remote", "reliable")
func _rpc_set_stance(stance: StringName) -> void:
	_set_stance(stance)


# The client's await-free copies of the coroutines: nothing on a client waits on
# them, the host's own pacing already spaces the calls out.
@rpc("authority", "call_remote", "reliable")
func _rpc_play_action(action: StringName) -> void:
	_play_action(action)


@rpc("authority", "call_remote", "reliable")
func _rpc_play_hit_react() -> void:
	_play_hit_react()


@rpc("authority", "call_remote", "reliable")
func _rpc_play_stance_exit(action: StringName, next: StringName) -> void:
	_play_stance_exit(action, next)


@rpc("authority", "call_remote", "reliable")
func _rpc_play_burst(rounds: int) -> void:
	_play_burst(rounds)


# Idempotent, so the copy a client also sets for itself off the replicated
# `flashlight_on` and `life_state` costs nothing.
@rpc("authority", "call_remote", "reliable")
func _rpc_set_flashlight_enabled(on: bool) -> void:
	_set_flashlight_enabled(on)


@rpc("authority", "call_remote", "reliable")
func _rpc_set_status_color(color: Color) -> void:
	_set_status_color(color)


# --- Playback ----------------------------------------------------------------


## Sets which cover family every subsequent pose resolves through. Cosmetic only:
## the cover BONUS is a property of the tile edge the shot crosses, never of
## what the unit is doing on screen.
func set_cover_pose(family: StringName) -> void:
	_mirror(&"_rpc_set_cover_pose", [family])
	_set_cover_pose(family)


func _set_cover_pose(family: StringName) -> void:
	if family == _cover:
		return
	_cover = family
	_play(_action if _action != &"" else _stance)


func set_stance(stance: StringName) -> void:
	_mirror(&"_rpc_set_stance", [stance])
	_set_stance(stance)


func _set_stance(stance: StringName) -> void:
	# Recorded even when a one-shot is mid-flight; play_action hands back to
	# whatever the stance has become rather than to what it was on entry.
	_stance = stance
	if _action != &"":
		return
	_play(stance)
	if stance == RUN and not _stepping and not _instant():
		_footstep_loop()  # deliberately not awaited: runs until the stance ends
	elif stance == IDLE:
		_maybe_start_fidget()


func play_action(action: StringName) -> void:
	# Coroutine — callers MUST await, or the next game action resolves while this
	# one is still on screen. Shooting does NOT come through here — see
	# play_burst — so nothing here emits `muzzle`.
	#
	# DOWNED is not sent: a client plays its own collapse off the replicated
	# `life_state` (Unit._present_life_state), and a second copy would restart it.
	if action != DOWNED:
		_mirror_one_shot(&"_rpc_play_action", [action])
	await _play_action(action)


func _play_action(action: StringName) -> void:
	if _instant():
		# Still recorded, so a unit killed out of sight is a body when it next
		# comes into view.
		if action == DOWNED:
			_settle_dead()
		if action == MELEE:
			strike.emit()
		return
	_action = action
	_play(action, true)
	# The same length with or without a model, which is what keeps every
	# timing-dependent caller behaving the same before and after art exists.
	var resolved := _resolved_base(action)
	var length: float = _duration(resolved) if resolved != &"" and _authored \
			else FALLBACK_TIME.get(action, DEFAULT_FALLBACK_TIME)
	if action == MELEE:
		# Split at the contact frame. The placeholder swings on the same beat,
		# so the hit lands at the same moment with or without art.
		var contact := length * clampf(STRIKE_AT.get(variant, 1.0), 0.0, 1.0)
		await get_tree().create_timer(contact).timeout
		strike.emit()
		length -= contact
	if length > 0.0:
		await get_tree().create_timer(length).timeout
	_action = &""
	# DOWNED hands over to the corpse; every other action returns to the stance.
	if action == DOWNED:
		_settle_dead()
	else:
		_play(_stance)


## Makes DEAD the stance, where the model has it. One without keeps DOWNED's
## last frame — asking for DEAD there would fall through `_play` to IDLE and
## stand the body up.
##
## Either way the corpse pose becomes the STANCE, not just what is on screen:
## `refresh` (a unit coming back into view, a tick playback handing the model
## back) replays the stance, and one left at IDLE stood the body back up. A
## model with no DEAD rests on DOWNED, which `_play` holds at its last frame.
func _settle_dead() -> void:
	if _resolved_base(DEAD) == &"":
		_stance = DOWNED
		return
	_stance = DEAD
	_play(DEAD)


## Plays the flinch for a hit the unit survived, through the cover chain like
## every other pose. Fire-and-forget: nothing about the fight may wait on the
## victim's reaction, so missing art costs NO time here. Skipped rather than
## stacked when another one-shot is already on screen.
func play_hit_react() -> void:
	_mirror_one_shot(&"_rpc_play_hit_react")
	await _play_hit_react()


func _play_hit_react() -> void:
	if _instant() or _action != &"" or not (_authored and _has_any(HIT_REACT)):
		return
	await _play_action(HIT_REACT)


## Plays a one-shot that bridges the current stance into `next`, then settles
## there. Coroutine — callers MUST await. Missing art costs NO time: it falls
## straight through to the stance, a hard cut rather than a mysterious pause.
func play_stance_exit(action: StringName, next: StringName) -> void:
	_mirror_one_shot(&"_rpc_play_stance_exit", [action, next])
	await _play_stance_exit(action, next)


func _play_stance_exit(action: StringName, next: StringName) -> void:
	if _instant() or not _has_any(action):
		_set_stance(next)
		return
	# Recorded WITHOUT playing it, so the exit animation is what shows; the tail
	# of play_action then settles into whatever _stance has become.
	_stance = next
	await _play_action(action)


func play_burst(rounds: int, mirror: bool = true, raised: bool = false) -> void:
	# Coroutine — callers MUST await. Weapon comes up, fires `rounds` rounds on a
	# fixed cadence, holds, then hands back to the stance. One `muzzle` per round.
	# `mirror` false is for a caller that sends the burst itself, with what each
	# round hits — see Unit._play_armed_burst. `raised` skips the raise: the
	# weapon is already up (reaction fire — overwatch, a suppression break).
	if mirror:
		_mirror_one_shot(&"_rpc_play_burst", [rounds])
	await _play_burst(rounds, raised)


func _play_burst(rounds: int, raised := false) -> void:
	if _instant():
		for _i in rounds:
			muzzle.emit()
		return
	_action = FIRE_SHOOT
	# Resolved BEFORE the phase plays, because the length of the beat depends on
	# which animation answered: a step out of cover takes longer than
	# shouldering a rifle on the spot.
	var begin := _resolved_base(BEGIN_SHOOT)
	var end := _resolved_base(END_SHOOT)
	if raised:
		_play(AIM_HOLD, true)
	else:
		_play(BEGIN_SHOOT if begin != &"" else AIM_HOLD, true)
		await get_tree().create_timer(
			_phase_time(BEGIN_SHOOT, begin, RAISE_TIME, COVER_RAISE_TIME)).timeout
	await _hold_for_barrel()
	# FIRE has no cover variant BY DESIGN: the unit has already stepped out, so
	# it fires exactly as it does in the open.
	_barrel_frozen = true
	for _i in rounds:
		# Restarted, so every round gets its own kick and its own flash.
		_play(FIRE_SHOOT, true)
		if _flash:
			_flash.fire(BURST_CADENCE)
		muzzle.emit()
		await get_tree().create_timer(BURST_CADENCE).timeout
	_barrel_frozen = false
	_play(END_SHOOT if end != &"" else AIM_HOLD, true)
	await get_tree().create_timer(
		_phase_time(END_SHOOT, end, SETTLE_TIME, COVER_SETTLE_TIME)).timeout
	_action = &""
	_play(_stance)


## Holds the first round until the barrel's line is on the target (see
## `_aim_barrel`) AND the legs have finished turning, up to BARREL_HOLD_MAX.
## The legs matter because the correction freezes for the rounds: legs still
## coming round would carry the spine, and the frozen line, off the target.
## Returns at once when no loop is running (no aim point, or a model without a
## barrel or a spine to turn it with).
func _hold_for_barrel() -> void:
	var waited := 0.0
	while waited < BARREL_HOLD_MAX and is_inside_tree() and not _instant() \
			and _has_aim_point and can_twist() and _flash != null \
			and (_barrel_error > BARREL_ON_TARGET or _body_turning):
		await get_tree().process_frame
		waited += get_process_delta_time()


## How long a burst phase holds: the cover length when a cover variant answered
## for it, the plain length otherwise.
func _phase_time(base: StringName, resolved: StringName, plain: float,
		in_cover: float) -> float:
	return in_cover if resolved != &"" and resolved != base else plain


## Where a shot is DRAWN leaving the weapon: the muzzle flash's mount on the
## animated rifle, so a tracer starts at the flash. Falls back to
## `muzzle_origin` for a model with no muzzle marker. Cosmetic only -- anything
## that has to agree between peers or with LOS reads `muzzle_origin`.
func barrel_tip() -> Vector3:
	if _flash != null and _flash.is_inside_tree():
		return _flash.global_position
	return muzzle_origin()


## Where a shot leaves the weapon, in world space. Derived from the UNIT's yaw on
## purpose: LOS and the shot VFX both read it, and it must not move with the
## animation.
func muzzle_origin() -> Vector3:
	var yaw: float = _unit.rotation.y if _unit else 0.0
	var forward := Vector3(-sin(yaw), 0.0, -cos(yaw))
	return global_position + forward * MUZZLE_REACH + Vector3(0.0, MUZZLE_HEIGHT, 0.0)


## Drives every player from one call, which keeps a pile's instances in lockstep
## with each other (each at its own phase).
func _play(base: StringName, restart: bool = false) -> void:
	if _instant() or _ragdoll != null:
		# A body on the deck in a physics pose shows nothing else until it is
		# cleared (`clear_ragdoll`) — `refresh` would otherwise stand it back up.
		return
	# A pose the model has nothing for falls through to IDLE rather than being
	# asked for as-is — otherwise a model missing `downed` would freeze in
	# whatever it was doing, forever.
	var effective := base if base == IDLE or _has_any(base) else IDLE
	var pose := _resolved_base(effective)
	if pose == &"":
		return
	if pose == _current and not restart:
		return
	_current = pose
	if _pose_root:
		_pose_placeholder(pose)
		return
	_pose_yaw_rad = deg_to_rad(_pose_yaw.get(pose, 0.0))
	_apply_body()
	var duration := _duration(pose)
	# A round's kick restarts from its first frame with no blend — blending into
	# itself would smear the recoil into nothing.
	var blend := 0.0 if pose == FIRE_SHOOT else BLEND_TIME
	for i in _players.size():
		var player := _players[i]
		if not player.has_animation(pose):
			continue
		var length := player.get_animation(pose).length
		var speed := length / duration if duration > 0.0 and length > 0.01 else 1.0
		player.play(pose, blend, speed)
		var phase := _phases[i] + (loop_phase if pose in LOOPING else 0.0)
		if effective == DOWNED and _action != DOWNED:
			# DOWNED as a resting stance (`_settle_dead`), not the collapse: the
			# body is already on the deck, so show it there rather than falling again.
			player.seek(length, true)
		elif restart or phase != 0.0:
			player.seek(fposmod(phase, 1.0) * length, true)


# --- Free turn --------------------------------------------------------------------
#
# How a turn looks. The RULES facing is the unit's yaw (plus, during tick
# playback, this node's own local yaw), it can be any angle, and it is set
# instantly; nothing here reads or writes it. What this section draws is three
# layers chasing it, each on a critically damped spring (fast, no overshoot,
# and happy to have its target change mid-turn, which a tween is not):
#
#   aim   the upper body's yaw. Chases the rules facing quickly.
#   body  the legs' yaw, i.e. the whole model's. Holds still while the aim is
#         within BODY_DEADZONE of it, then turns all the way onto the aim, so a
#         small adjustment is a twist at the waist and a big one moves the feet.
#   head  the eyes, a touch ahead of the aim (HEAD_LEAD_MAX).
#
# The difference between aim and body is the spine twist, applied by an
# AimModifier on the model's skeleton. A rig with no spine to twist (a worm, the
# placeholder) gets no deadzone: its body is its aim. Running, the deadzone is
# off too, since legs that hold still while running are a moonwalk.
#
# `aim_direction` corrects the rules beam for whatever of the turn is still to
# come, so none of this can move what is lit.

## Spring stiffness per layer, 1/s. Roughly 4/omega seconds to settle.
const AIM_OMEGA := 20.0
const BODY_OMEGA := 9.0
const HEAD_OMEGA := 32.0
const PITCH_OMEGA := 14.0
## How far the aim may lead the legs before the feet move: about 45 degrees.
const BODY_DEADZONE := 0.785
## Most the spine may twist, about 70 degrees. Past it the upper body waits on
## the legs.
const MAX_TWIST := 1.22
## The legs' turn counts as done inside this, about 1.7 degrees.
const BODY_SETTLE := 0.03
## Most the head may lead the gun, about 35 degrees.
const HEAD_LEAD_MAX := 0.6
## Pitch limit onto a target above or below the muzzle, about 35 degrees.
const MAX_PITCH := 0.6
## The barrel loop (`_aim_barrel`): how fast it closes, 1/s, and the most yaw it
## may add on top of the twist, about 45 degrees. The merc's shooting pose needs
## about 28 of it.
const BARREL_RATE := 18.0
const MAX_BARREL_YAW := 0.8
## Closer than this (metres, flat) the bore-to-target angle is meaningless.
const BARREL_MIN_RANGE := 0.4
## The first round waits, after the raise, until the bore is within
## BARREL_ON_TARGET of the target line (about 0.1 degree), but never longer than
## BARREL_HOLD_MAX seconds. Only a big turn onto the target ever waits: the legs
## have not come round by the end of the raise.
const BARREL_ON_TARGET := 0.002
const BARREL_HOLD_MAX := 0.35
## Seconds to blend the twist in or out across a pose change.
const INFLUENCE_TIME := 0.15
## A leg turn at least this big (about 70 degrees) plays a turn clip, if the
## model has one.
const TURN_CLIP_MIN := 1.22

## Poses the body must face squarely in: authored motions aimed at something
## (a swing, a throw, a console) and everything on the floor. The twist fades
## out for these and the legs turn the whole way.
const SQUARE_POSES: Array[StringName] = [
	MELEE, GRENADE, INTERACT, DOWNED, DEAD, ALERT_SCREAM, RUN_STOP,
]

var _aim_mod: AimModifier = null
## World yaws, radians, each kept within PI of the facing it chases.
var _aim_yaw := 0.0
var _body_yaw := 0.0
var _head_yaw := 0.0
var _aim_vel := 0.0
var _body_vel := 0.0
var _head_vel := 0.0
var _pitch := 0.0
var _pitch_vel := 0.0
## Yaw the barrel loop adds on top of the twist, radians. See `_aim_barrel`.
var _barrel_yaw := 0.0
## How far the drawn bore was off the target line last frame, radians; 0 when
## the loop is not running. `_play_burst` holds its first round on it.
var _barrel_error := 0.0
## True from a burst's first round to its last: the loop holds its correction.
var _barrel_frozen := false
## The aim point is a moving target being tracked (Unit reaction fire): while
## the rounds go out the loop keeps following it in YAW, holding only the
## pitch, which is where the kick shows.
var _barrel_tracking := false
## True while the legs are turning onto the aim, until BODY_SETTLE.
var _body_turning := false
## 0..1, how much of the twist is applied. Follows `_twist_target`.
var _influence := 0.0
## False until the springs have been put on the facing once; until then the
## next frame snaps rather than swinging in from yaw 0.
var _facing_ready := false
## Where a burst is aimed, for the pitch. See set_aim_point.
var _aim_point := Vector3.ZERO
var _has_aim_point := false
## The current pose's authored yaw correction (export sidecar), radians.
var _pose_yaw_rad := 0.0
var _turn_clip_playing := false


## Hangs an AimModifier on the model's skeleton, if the rig has a spine it knows.
func _bind_aim(inst: Node) -> void:
	var skel: Skeleton3D = null
	for n in inst.find_children("*", "Skeleton3D", true, false):
		skel = n as Skeleton3D
		break
	if skel == null:
		return
	var mod := AimModifier.new()
	mod.name = "AimModifier"
	if not mod.bind(skel):
		mod.free()
		return
	skel.add_child(mod)
	_aim_mod = mod


## Whether this model can show a twist at the waist at all.
func can_twist() -> bool:
	return _aim_mod != null and _aim_mod.supported()


## Aims the upper body's pitch at `point` (world) for a burst. Cosmetic: the
## shot itself comes from `muzzle_origin`.
func set_aim_point(point: Vector3) -> void:
	_aim_point = point
	_has_aim_point = true


func clear_aim_point() -> void:
	_has_aim_point = false


## See `_barrel_tracking`. Cosmetic.
func set_barrel_tracking(on: bool) -> void:
	_barrel_tracking = on


## Whether the model is in its run or walk cycle right now.
func is_moving() -> bool:
	return _moving()


## Puts every layer straight onto the current facing, no swing. For a unit
## that was not drawn (it just came into view, spawned, was teleported) and so
## has no turn anyone saw begin.
func snap_facing() -> void:
	var yaw := _presented_yaw()
	_aim_yaw = yaw
	_body_yaw = yaw
	_head_yaw = yaw
	_aim_vel = 0.0
	_body_vel = 0.0
	_head_vel = 0.0
	_pitch = 0.0
	_pitch_vel = 0.0
	_barrel_yaw = 0.0
	_body_turning = false
	_influence = 1.0 if _twist_target() > 0.0 else 0.0
	_facing_ready = true
	_apply_body()


## The rules facing as this node shows it: the unit's yaw plus any local yaw
## playback has put on this node. World yaw, -Z forward.
func _presented_yaw() -> float:
	if not is_inside_tree():
		return rotation.y + (_unit.rotation.y if _unit else 0.0)
	var back := global_transform.basis.z
	return atan2(back.x, back.z)


## Turns the model by the legs' lag behind the facing (plus the pose's authored
## correction). `_model` is this node's child, so its local yaw is the gap.
func _apply_body() -> void:
	if _model == null or _ragdoll != null:
		return
	_model.rotation.y = _pose_yaw_rad + wrapf(_body_yaw - _presented_yaw(), -PI, PI)


## The twist the modifier is actually applying, radians.
func _applied_twist() -> float:
	if not can_twist():
		return 0.0
	return clampf(wrapf(_aim_yaw - _body_yaw, -PI, PI), -MAX_TWIST, MAX_TWIST) * _influence


## How much of the current turn the model has yet to show, radians. Measured
## against what is DRAWN, never against the springs' own state:
##   * the model's yaw is read off `_model` itself, because a rules turn moves
##     the model with its parent at once, before `_process` next corrects it,
##     and the lighting recompute that follows a turn runs in that gap;
##   * the twist is the one the modifier last APPLIED, since the skeleton runs
##     its modifiers later in the frame than `_process` sets them.
func _turn_pending() -> float:
	if not _facing_ready or _model == null:
		return 0.0
	var shown := _aim_mod.applied_twist if _aim_mod and _aim_mod.active else 0.0
	return -wrapf(_model.rotation.y - _pose_yaw_rad + shown, -PI, PI)


## 1 where the current pose may twist, 0 where it must face squarely.
func _twist_target() -> float:
	if not can_twist():
		return 0.0
	var pose := _action if _action != &"" else _stance
	return 0.0 if pose in SQUARE_POSES else 1.0


func _moving() -> bool:
	return _action == &"" and (_stance == RUN or _stance == WALK)


func _process(delta: float) -> void:
	if _model == null or _ragdoll != null:
		return
	if _instant() or not _facing_ready:
		snap_facing()
		return
	var facing := _presented_yaw()
	var a := _spring_angle(_aim_yaw, _aim_vel, facing, AIM_OMEGA, delta)
	_aim_yaw = a.x
	_aim_vel = a.y
	var h := _spring_angle(_head_yaw, _head_vel, facing, HEAD_OMEGA, delta)
	_head_yaw = h.x
	_head_vel = h.y
	_influence = move_toward(_influence, _twist_target(), delta / INFLUENCE_TIME)

	# Legs. The deadzone shrinks with the twist it relies on, so a pose that
	# must face squarely brings the feet the whole way round.
	var deadzone := 0.0 if _moving() else BODY_DEADZONE * _influence
	var gap := wrapf(_aim_yaw - _body_yaw, -PI, PI)
	if not _body_turning and absf(gap) > deadzone + 0.001:
		_body_turning = true
		_maybe_turn_clip(wrapf(facing - _body_yaw, -PI, PI))
	if _body_turning:
		var b := _spring_angle(_body_yaw, _body_vel, _aim_yaw, BODY_OMEGA, delta)
		_body_yaw = b.x
		_body_vel = b.y
		if absf(wrapf(_aim_yaw - _body_yaw, -PI, PI)) < BODY_SETTLE \
				and absf(wrapf(facing - _aim_yaw, -PI, PI)) < BODY_SETTLE:
			_body_turning = false
			_body_vel = 0.0
	else:
		_body_vel = 0.0
	_apply_body()

	_aim_barrel(delta)

	if _aim_mod:
		var twist := _applied_twist() + _barrel_yaw * _influence
		_aim_mod.twist = twist
		_aim_mod.aim_world_yaw = _body_yaw + twist
		_aim_mod.pitch = _pitch * _influence
		_aim_mod.head_lead = clampf(wrapf(_head_yaw - _aim_yaw, -PI, PI),
			-HEAD_LEAD_MAX, HEAD_LEAD_MAX) * _influence


## Puts the BARREL'S LINE through the aim point while one is set (a burst).
##
## Facing the target is not enough: the shooting clips hold the rifle at the
## right shoulder and well off the body's forward (about 28 degrees on the merc),
## so a body squared up to the target fires a line that passes metres wide of
## it. No fixed offset can fix that, because the raise, the kick and the cover
## variants each hold the gun differently. So this is a closed loop on what is
## DRAWN: every frame it measures the bore's yaw and pitch against the line from
## the barrel tip to the target and feeds the difference into the twist, which
## turns tip and bore together about the spine until the line runs through.
##
## FROZEN WHILE THE ROUNDS GO OUT (`_barrel_frozen`, set by `_play_burst`). Left
## running, the loop fights each round's kick and settles on the AVERAGE of the
## kick cycle, so every round leaves from the un-kicked pose low by the mean
## kick. Converged during the raise and held, the rounds leave on the line and
## the recoil plays on top of it, as recoil should.
##
## Cosmetic only. The shot resolves from `muzzle_origin`, and `aim_direction`
## takes the twist back out (`_turn_pending` subtracts whatever is shown), so the
## rules beam stays on the unit's facing.
##
## A model with no barrel marker gets the plain pitch toward the aim point from
## shoulder height instead. Without an aim point both terms ease back to zero.
func _aim_barrel(delta: float) -> void:
	var barrel_ok := _has_aim_point and can_twist() and _flash != null and _flash.is_inside_tree() \
		and _influence > 0.99
	_barrel_error = 0.0
	if barrel_ok:
		var tip := _flash.global_position
		var bore := (-_flash.global_transform.basis.z).normalized()
		var to := _aim_point - tip
		if Vector2(to.x, to.z).length() > BARREL_MIN_RANGE and absf(bore.y) < 0.95:
			var gain := 1.0 - exp(-BARREL_RATE * delta)
			var yaw_err := wrapf(atan2(-to.x, -to.z) - atan2(-bore.x, -bore.z), -PI, PI)
			var pitch_err := _elevation(to) - _elevation(bore)
			_barrel_error = Vector2(yaw_err, pitch_err).length()
			if _barrel_frozen:
				# Rounds going out: hold the aim, let the kick show on top — except
				# that a tracked runner is followed sideways, the kick being pitch.
				if _barrel_tracking:
					_barrel_yaw = clampf(_barrel_yaw + yaw_err * gain, -MAX_BARREL_YAW, MAX_BARREL_YAW)
				return
			_barrel_yaw = clampf(_barrel_yaw + yaw_err * gain, -MAX_BARREL_YAW, MAX_BARREL_YAW)
			_pitch = clampf(_pitch + pitch_err * gain, -MAX_PITCH, MAX_PITCH)
			_pitch_vel = 0.0
		return
	var target_pitch := 0.0
	if _has_aim_point:
		var d := _aim_point - (global_position + Vector3(0.0, MUZZLE_HEIGHT, 0.0))
		var flat := Vector2(d.x, d.z).length()
		if flat > 0.01:
			target_pitch = clampf(atan2(d.y, flat), -MAX_PITCH, MAX_PITCH)
	var p := _spring(_pitch, _pitch_vel, target_pitch, PITCH_OMEGA, delta)
	_pitch = p.x
	_pitch_vel = p.y
	_barrel_yaw *= exp(-PITCH_OMEGA * delta)


static func _elevation(d: Vector3) -> float:
	return atan2(d.y, Vector2(d.x, d.z).length())


## A turn of the legs big enough to need the feet to step. Plays TURN_LEFT,
## TURN_RIGHT or TURN_AROUND over the spring's rotation, where the model has
## one, as a decoration like the fidget: `_action` stays empty so nothing waits
## on it and any real pose cuts it off.
##
## AUTHORING CONTRACT: the clip steps the feet IN PLACE with no net rotation of
## the rig. The spring supplies the rotation; a clip that also turned the hips
## would turn the unit twice.
func _maybe_turn_clip(turn: float) -> void:
	if absf(turn) < TURN_CLIP_MIN or _turn_clip_playing or _moving() or _action != &"" \
			or not _authored or _instant():
		return
	var clip := TURN_AROUND if absf(turn) > 2.36 else (TURN_LEFT if turn > 0.0 else TURN_RIGHT)
	if not _has_any(clip):
		return
	_turn_clip_playing = true
	var stance := _stance
	_play(clip, true)
	await get_tree().create_timer(_duration(_resolved_base(clip))).timeout
	_turn_clip_playing = false
	if is_inside_tree() and _action == &"" and _stance == stance and _ragdoll == null:
		_play(_stance)


## One step of a critically damped spring from `x` (velocity `v`) toward
## `target`: the closed form, so it is stable at any frame time. -> (x, v).
static func _spring(x: float, v: float, target: float, omega: float, dt: float) -> Vector2:
	var e := x - target
	var k := exp(-omega * dt)
	var t := (v + omega * e) * dt
	return Vector2(target + (e + t) * k, (v - omega * t) * k)


## `_spring` for an angle: the short way round, and the result kept within PI
## of the target so the error never grows without bound.
static func _spring_angle(x: float, v: float, target: float, omega: float, dt: float) -> Vector2:
	return _spring(target + wrapf(x - target, -PI, PI), v, target, omega, dt)


# --- Ragdoll --------------------------------------------------------------------
#
# A unit that drops in view goes down as physics (Ragdoll): the round that
# dropped it decides which way. Visual only — see Ragdoll's class comment. A rig
# Ragdoll does not know, an unseen collapse, or too many falls at once take the
# authored DOWNED animation instead, exactly as before.


## Off switch: false puts every unit back on the authored collapse.
const RAGDOLL_ENABLED := true

var _ragdoll: Ragdoll = null


## The collapse — downed, or killed outright. `hit` is Unit.hit_record(). Not a
## coroutine and not mirrored: every peer runs it from the replicated
## `life_state` (Unit._present_life_state), with the replicated hit.
func collapse(hit: Dictionary) -> void:
	# Already falling: the burst that dropped it started the fall on the round
	# that did it (`take_round`), before the damage was applied.
	if _ragdoll != null:
		return
	if _start_ragdoll(hit):
		return
	play_action(DOWNED)


## One round of a burst striking this unit (Unit._on_muzzle), on every peer.
## Visual only. `doomed` is the shot that drops it: its first landing round
## starts the fall, so the body goes down WITH the gunfire rather than after
## the burst; every round after that jolts the falling body. A round into a
## unit that stays up changes nothing here — it flinches after the burst, as
## before. `part` is Combat.BodyPart for the round that was rolled, or -1.
func take_round(from: Vector3, doomed: bool, part: int, carry := Vector3.ZERO) -> void:
	if _ragdoll != null:
		if is_instance_valid(_ragdoll) and _ragdoll.is_simulating():
			_ragdoll.add_round(from, part)
		return
	if not doomed:
		return
	# `carry` is the speed a runner dropped mid-stride falls with (Unit reaction
	# fire), so it goes down forward rather than stopping dead and toppling.
	if _start_ragdoll({"kind": Ragdoll.HitKind.BULLET, "from": from,
			"part": part if part >= 0 else Combat.BodyPart.TORSO, "seed": _round_rng.randi(),
			"carry": carry}):
		# The light goes out with the soldier the moment it falls, not when the
		# burst's damage lands half a second later (Unit._present_life_state).
		_set_flashlight_enabled(false)


## Never the global generator: the burst plays mid-`fire_at`, and seeded runs
## replay the global sequence.
static var _round_rng := RandomNumberGenerator.new()


## Undoes a fall's physics pose (a revive, a playback rewind). The caller sets
## the stance that follows.
func clear_ragdoll() -> void:
	if _ragdoll == null:
		return
	if is_instance_valid(_ragdoll):
		_ragdoll.clear()
	_ragdoll = null
	_current = &""
	if _aim_mod:
		_aim_mod.active = true
	snap_facing()


func is_ragdolled() -> bool:
	return _ragdoll != null


func _start_ragdoll(hit: Dictionary) -> bool:
	# `_has_any(DOWNED)`: the ragdoll REPLACES an authored collapse. A model with
	# none (the nest shares the soldier's skeleton but never falls) keeps doing
	# what it always did.
	if not RAGDOLL_ENABLED or _ragdoll != null or _model == null or not _authored \
			or not _has_any(DOWNED) or _instant() or Ragdoll.active_count >= Ragdoll.MAX_ACTIVE:
		return false
	var skel: Skeleton3D = null
	for n in _model.find_children("*", "Skeleton3D", true, false):
		skel = n as Skeleton3D
		break
	if not Ragdoll.supports(skel):
		return false
	for player in _players:
		player.pause()
	# The body is physics from here: no twist on top of it, and `_process` stops
	# turning the model under it.
	if _aim_mod:
		_aim_mod.active = false
	_action = &""
	_ragdoll = Ragdoll.new()
	_ragdoll.name = "Ragdoll"
	add_child(_ragdoll)
	# The corpse stance, for whatever comes after the ragdoll (a model rebuild
	# drops it). `_play` is gated by now, so this only records it.
	_settle_dead()
	var floor_y := _unit.global_position.y if _unit else global_position.y
	_ragdoll.start(skel, hit, floor_y, _mount, _model)
	return true


## Frees a ragdoll outright, gun and all, with no restore — the model it posed
## is about to be freed too (`set_variant`).
func _drop_ragdoll() -> void:
	if _ragdoll != null and is_instance_valid(_ragdoll):
		_ragdoll.free()
	_ragdoll = null


## How long the authored collapse runs, which is what playback paces a fall on.
func _collapse_time() -> float:
	var resolved := _resolved_base(DOWNED)
	return _duration(resolved) if resolved != &"" and _authored \
		else FALLBACK_TIME.get(DOWNED, DEFAULT_FALLBACK_TIME)


# --- Tick playback (exploration plan B.12) --------------------------------------
#
# Local-only entry points for TickPlayback, which runs the same timeline on every
# peer by itself — so none of these mirror. The rules already happened; these
# only draw them.


func set_stance_local(stance: StringName) -> void:
	_set_stance(stance)


func set_cover_pose_local(family: StringName) -> void:
	_set_cover_pose(family)


func set_lamp_local(on: bool) -> void:
	_set_flashlight_enabled(on)


func play_action_local(action: StringName) -> void:
	await _play_action(action)


func play_hit_react_local() -> void:
	_play_hit_react()


## Undoes, for the screen only, a collapse the tick already decided, so playback
## can show it at its slot: back on its feet if it went down this tick
## (`was_active`), or still the downed body if it only died, untinted either way.
func replay_reset(was_active: bool) -> void:
	set_dead_tint(false)
	if was_active:
		clear_ragdoll()
		_action = &""
		_stance = IDLE
		_play(IDLE, true)


## The collapse at its slot: down if it was standing, and the corpse tint if this
## was a death. Coroutine.
func replay_down(was_active: bool, dead: bool) -> void:
	if was_active and _ragdoll != null:
		pass  # the burst's own rounds already dropped it (`take_round`)
	elif was_active:
		_set_flashlight_enabled(false)
		if _start_ragdoll(_unit.hit_record() if _unit and _unit.has_method("hit_record") else {}):
			# Playback is paced on the collapse; the fall takes as long as the
			# authored one would have, and carries on settling after.
			await get_tree().create_timer(_collapse_time()).timeout
		else:
			await _play_action(DOWNED)
	if dead:
		set_dead_tint(true)


# --- Idle behaviour ----------------------------------------------------------


func _footstep_loop() -> void:
	_stepping = true
	await get_tree().create_timer(FOOTSTEP_OFFSET).timeout
	while _stance == RUN and is_inside_tree():
		footstep.emit()
		await get_tree().create_timer(FOOTSTEP_GAP).timeout
	_stepping = false


func _maybe_start_fidget() -> void:
	# Silently does nothing for a model with no fidget.
	if _instant() or _fidgeting or not _authored or not _has_any(IDLE_FIDGET):
		return
	_fidget_loop()  # deliberately not awaited: runs until the stance leaves IDLE


## Slips an idle variation in at random intervals. Played directly rather than
## through play_action: that sets `_action`, which would make a move order wait
## for the fidget to finish. Leaving `_action` empty means any real stance change
## cuts the fidget off and wins, which is the priority a decoration should have.
func _fidget_loop() -> void:
	_fidgeting = true
	while _stance == IDLE and is_inside_tree():
		await get_tree().create_timer(
			randf_range(FIDGET_GAP_MIN, FIDGET_GAP_MAX)).timeout
		# Nothing from before the wait may be trusted: whole turns pass in it.
		if not is_inside_tree() or _stance != IDLE:
			break
		if _action != &"":
			continue  # a real one-shot owns the body; try again after the next gap
		_play(IDLE_FIDGET, true)
		await get_tree().create_timer(_duration(IDLE_FIDGET)).timeout
		if is_inside_tree() and _stance == IDLE and _action == &"":
			_play(IDLE)
	_fidgeting = false


# --- Status light ------------------------------------------------------------


## Recolours the self-lit `status` part. The security robots' one concession to
## readability: a machine's posture cannot be read off its body language the way
## an alien's can, so the state is a colour instead. A no-op for a character with
## no status part.
## Mirrored like the poses: what drives it (a robot's alert state, its EMP timer)
## lives on the host alone.
func set_status_color(color: Color) -> void:
	_mirror(&"_rpc_set_status_color", [color])
	_set_status_color(color)


func _set_status_color(color: Color) -> void:
	_status_color = color
	if _status_material:
		_status_material.albedo_color = color


# --- Placeholder -------------------------------------------------------------
#
# Built in code from primitive meshes, so there are no stand-in assets to
# mistake for real ones and nothing to delete when a model lands. Every pose
# "exists" (as a held posture), which keeps the whole playback system exercised,
# and dropping `<variant>.glb` into assets/models/ replaces it silently.

## Base colour per part, so they are told apart at a glance.
const PLACEHOLDER_COLOR := {
	&"body": Color(0.32, 0.36, 0.30),
	&"head": Color(0.78, 0.62, 0.50),
	&"helmet": Color(0.22, 0.25, 0.28),
	&"weapon": Color(0.15, 0.15, 0.17),
	&"status": Color(1.0, 1.0, 1.0),  # tinted per alert state; see set_status_color
}

## Machine-style overrides: cold greys against the organic set's warmer palette,
## so faction reads off colour as well as shape.
const PLACEHOLDER_MACHINE_COLOR := {
	&"body": Color(0.40, 0.44, 0.50),
	&"head": Color(0.20, 0.22, 0.26),
	&"weapon": Color(0.14, 0.15, 0.18),
}

## Per-variant machine proportions, in placeholder units (PLACEHOLDER_UNIT): a
## squat armored post, a wide weapons platform, a small hovering drone, and
## something a head taller than a soldier.
##
##   width/height — chassis box
##   hover        — clear air under it, so the drone reads as flying
##   head         — sensor housing edge; 0 draws none
##   shoulder     — width of the side plates, 0 draws none
const PLACEHOLDER_MACHINE_SPEC := {
	&"auxilium": {"width": 20, "height": 26, "hover": 0, "head": 9, "shoulder": 5},
	&"sagittarii": {"width": 28, "height": 30, "hover": 0, "head": 8, "shoulder": 8},
	&"proctor": {"width": 14, "height": 14, "hover": 20, "head": 6, "shoulder": 0},
	&"securus": {"width": 24, "height": 42, "hover": 0, "head": 12, "shoulder": 7},
	# The landed ship's door gun (DoorGunUnit, extraction plan Phase 5): a low
	# turret base with a sensor/gunner head, sat on the Dropship's roof. Squat on
	# purpose so it reads as part of the hull rather than as a figure up there.
	&"door_gun": {"width": 16, "height": 12, "hover": 0, "head": 8, "shoulder": 0},
}
const PLACEHOLDER_MACHINE_DEFAULT := {"width": 20, "height": 28, "hover": 0, "head": 9, "shoulder": 5}
## Poses the placeholder holds crouched, so overwatch is visibly different.
const PLACEHOLDER_CROUCHED := [OVERWATCH]
## Every pose the placeholder answers for — the full vocabulary, so no caller can
## ask for something that does not exist.
const PLACEHOLDER_POSES := [
	IDLE, RUN, WALK, OVERWATCH, AIM_HOLD,
	BEGIN_SHOOT, FIRE_SHOOT, END_SHOOT, RUN_STOP,
	MELEE, RELOAD, GRENADE, INTERACT,
	HIT_REACT, DOWNED, DEAD, ALERT_SCREAM, IDLE_FIDGET,
]


func _build_placeholder() -> void:
	for pose: StringName in PLACEHOLDER_POSES:
		_poses[pose] = true
	_pose_root = Node3D.new()
	_pose_root.name = "Placeholder"
	_model.add_child(_pose_root)
	if placeholder_style == &"machine":
		_build_machine()
	else:
		_build_organic()


## The standing biped. Forward is -Z, the unit's facing.
func _build_organic() -> void:
	var body_h := 1.35
	for layer in layers:
		var color: Color = PLACEHOLDER_COLOR.get(layer, Color(0.6, 0.6, 0.6))
		match layer:
			&"body":
				_part(_box_mesh(Vector3(0.46, body_h, 0.30)), color,
					Vector3(0.0, body_h / 2.0, 0.0))
				# A lighter chest panel on the front: the fastest read of which
				# way a featureless block is facing.
				_part(_box_mesh(Vector3(0.34, 0.30, 0.04)), color.lightened(0.35),
					Vector3(0.0, body_h - 0.30, -0.16))
			&"head":
				_part(_sphere_mesh(0.17), color, Vector3(0.0, body_h + 0.20, 0.0))
			&"helmet":
				_part(_sphere_mesh(0.20), color.darkened(0.1), Vector3(0.0, body_h + 0.25, 0.0))
				_part(_box_mesh(Vector3(0.24, 0.07, 0.04)), Color(0.85, 0.2, 0.18),
					Vector3(0.0, body_h + 0.22, -0.19))
			&"weapon":
				_part(_box_mesh(Vector3(0.08, 0.10, 0.60)), color,
					Vector3(0.28, body_h - 0.35, -0.22))
			&"status":
				_status_part(Vector3(0.0, body_h - 0.2, -0.17), Vector3(0.1, 0.1, 0.04))


## The machine silhouette. Every part a box, and that is the point: the faction
## is specified as "built, not grown".
func _build_machine() -> void:
	var spec: Dictionary = PLACEHOLDER_MACHINE_SPEC.get(variant, PLACEHOLDER_MACHINE_DEFAULT)
	var u := PLACEHOLDER_UNIT
	var width: float = spec["width"] * u
	var height: float = spec["height"] * u
	var hover: float = spec["hover"] * u
	var head: float = spec["head"] * u
	var shoulder: float = spec["shoulder"] * u
	var depth := width * 0.7
	var top := hover + height
	for layer in layers:
		var color: Color = PLACEHOLDER_MACHINE_COLOR.get(layer,
			PLACEHOLDER_COLOR.get(layer, Color(0.6, 0.6, 0.6)))
		match layer:
			&"body":
				_part(_box_mesh(Vector3(width, height, depth)), color,
					Vector3(0.0, hover + height / 2.0, 0.0))
				if shoulder > 0.0:
					for side in [-1.0, 1.0]:
						_part(_box_mesh(Vector3(shoulder, height - 4 * u, depth * 1.1)),
							color.darkened(0.3),
							Vector3(side * (width + shoulder) / 2.0, hover + height / 2.0, 0.0))
				_part(_box_mesh(Vector3(width - 6 * u, 6 * u, 0.04)), color.lightened(0.25),
					Vector3(0.0, top - 6 * u, -depth / 2.0 - 0.02))
				if hover > 0.0:
					# Thruster under a hovering chassis, so it does not read as a
					# box someone left floating by mistake.
					_part(_box_mesh(Vector3(6 * u, 3 * u, 6 * u)), color.darkened(0.5),
						Vector3(0.0, hover - 3 * u, 0.0))
			&"head":
				if head <= 0.0:
					continue
				_part(_box_mesh(Vector3(head, head, head)), color,
					Vector3(0.0, top + head / 2.0, 0.0))
				_part(_box_mesh(Vector3(head - 2 * u, 2 * u, 0.04)), Color(0.9, 0.25, 0.2),
					Vector3(0.0, top + head * 0.6, -head / 2.0 - 0.02))
			&"weapon":
				_part(_box_mesh(Vector3(4 * u, 4 * u, 18 * u)), color,
					Vector3(width / 2.0 + shoulder + 2 * u, top - 8 * u, -6 * u))
			&"status":
				# Front and back, because a robot's state has to be readable from
				# behind as well.
				_status_part(Vector3(0.0, top - 4 * u, -depth / 2.0 - 0.03), Vector3.ONE * 4 * u)
				_status_part(Vector3(0.0, top - 4 * u, depth / 2.0 + 0.03), Vector3.ONE * 3 * u)


func _part(mesh: Mesh, color: Color, at: Vector3) -> MeshInstance3D:
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color * faction_tint
	mat.roughness = 0.85
	_add_floor(mat)
	mat.next_pass = _outline_for(mat)
	inst.material_override = mat
	inst.layers |= CHARACTER_LAYER
	inst.position = at
	_pose_root.add_child(inst)
	return inst


## A self-lit part: unshaded, so its colour reads the same in the dark as in
## the light, and one material shared by every status part on the unit.
func _status_part(at: Vector3, size: Vector3) -> void:
	if _status_material == null:
		_status_material = StandardMaterial3D.new()
		_status_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_status_material.albedo_color = _status_color
	var inst := MeshInstance3D.new()
	inst.mesh = _box_mesh(size)
	inst.material_override = _status_material
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	inst.position = at
	_pose_root.add_child(inst)


static func _box_mesh(size: Vector3) -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = size
	return mesh


static func _sphere_mesh(radius: float) -> SphereMesh:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 16
	mesh.rings = 8
	return mesh


## Holds the placeholder in a posture for `pose`: flat on the deck when down,
## lowered when crouched, upright otherwise.
func _pose_placeholder(pose: StringName) -> void:
	_pose_root.rotation = Vector3.ZERO
	_pose_root.position = Vector3.ZERO
	_pose_root.scale = Vector3.ONE
	if pose in [DOWNED, DEAD]:
		# Onto its back, lifted by half its depth so it lies ON the deck.
		_pose_root.rotation.x = PI / 2.0
		_pose_root.position.y = 0.16
	elif pose in PLACEHOLDER_CROUCHED or _cover == COVER_LOW:
		_pose_root.scale.y = 0.62
