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
# The model turns with the unit, so nothing here buckets facing any more. The
# eight-way table survives because game rules still speak in it (Unit snaps to
# 45 degrees; PlayerUnit.GRENADE_RELEASE_OFFSET counts buckets), and
# tools/test_sprite_direction.gd pins the mapping.

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

## Uniform scale on the model. 1.0 is true size, which every export is authored
## at; the worm mass uses it to grow within a tier (WormUnit._apply_count).
@export var model_scale: float = 1.0:
	set(value):
		model_scale = value
		if _model:
			_model.scale = Vector3.ONE * model_scale

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

## How much brighter than white the muzzle flash is drawn. Above 1 so it clears
## main.tscn's glow_hdr_threshold (1.1) and blooms; the flash is the brightest
## thing in frame in a dark corridor, and it must stay so.
const FLASH_GAIN := 1.8
const FLASH_COLOR := Color(1.0, 0.78, 0.45)
## Drawn size against authored size — render_sprites.py FLASH_SCALE, which is
## what the flash was judged at when it was a sprite.
const FLASH_SCALE := 0.5
const FLASH_SHADER := preload("res://shaders/muzzle_flash.gdshader")
## The node in the merc's model that IS the muzzle flash. Its origin sits on the
## barrel tip, so it doubles as the muzzle marker for the rig light.
const FLASH_NODE := "muzzle_flash"

## Where a shot leaves the weapon, relative to the unit: shoulder height, and
## forward of the body. Derived from unit yaw rather than from the model, because
## LOS and the shot VFX read it and it is a rules point, not art.
const MUZZLE_HEIGHT := 1.4
const MUZZLE_REACH := 0.3
## Height the rig light is mounted at when the model has no muzzle to mount on.
const LIGHT_HEIGHT := 1.6

## Where the rifle's bore points, per pose, in the unit's own frame — written by
## `tools/render_sprites.py --markers`. Only `mean_direction` is read: it aims
## the light, and through it the rules, so it must not sway within a cycle.
const MUZZLE_MARKER_PATH := "res://assets/sprites/muzzle_%s.json"

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
var _flash: MeshInstance3D = null
## Placeholder only: the node posed to crouch or lie down, and the status light.
var _pose_root: Node3D = null
var _status_material: StandardMaterial3D = null
## This unit's own material copies that carry the darkness floor, re-scaled
## whenever the lighting changes.
var _floor_materials: Array[BaseMaterial3D] = []

var _light: SpotLight3D = null
var _light_mount: Marker3D = null
## pose StringName -> {muzzle, direction, mean_direction}, in the unit's frame.
var _bore: Dictionary = {}
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

## Parsed bore tables, keyed by variant — every unit of a variant reads the same.
static var _marker_cache: Dictionary = {}


func _ready() -> void:
	# Children are ready before their parent, so Unit._ready can rely on these.
	_unit = get_parent() as Node3D
	_build_model()
	# Before _build_light, which aims the light off it.
	_read_markers()
	if has_light:
		_build_light()
	if LightingManager:
		LightingManager.lighting_changed.connect(_apply_floor)


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
	_flash = null
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
	_apply_floor()


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
	_flash = inst.find_child(FLASH_NODE, true, false) as MeshInstance3D
	if _flash:
		_dress_flash(_flash)
		_flash.visible = false
	_dress_surfaces(inst)
	return true


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


## The flash is authored as a mesh scaled down to nothing over `fire_shoot`, with
## emission set for an offline render. Redrawn here as light (see
## shaders/muzzle_flash.gdshader), and at FLASH_SCALE of its authored size.
##
## The scale is applied in the shader, because the flash node's own scale is
## what `fire_shoot` animates. The mesh origin is the muzzle point, so the
## shrink is toward the barrel tip and the flash stays registered on it.
func _dress_flash(flash: MeshInstance3D) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = FLASH_SHADER
	mat.set_shader_parameter("color", FLASH_COLOR)
	mat.set_shader_parameter("gain", FLASH_GAIN)
	mat.set_shader_parameter("size", FLASH_SCALE)
	var extent := flash.mesh.get_aabb()
	mat.set_shader_parameter("reach", maxf(extent.position.abs().length(),
		extent.end.abs().length()))
	flash.material_override = mat
	flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Per-unit copies of the model's materials, carrying the faction tint and the
## darkness floor.
##
## Metallic is zeroed. No character is metal-skinned, but the glTF round trip
## brings every material in at metallic 0.5 on a packed metal/roughness map —
## the source .blends leave Metallic unplugged — which laid a grey sheen over
## pale surfaces that the sprite renders never had.
func _dress_surfaces(root: Node) -> void:
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if mesh.mesh == null or mesh == _flash:
			continue  # a recoloured merc still fires a white flash
		for s in mesh.mesh.get_surface_count():
			var src := mesh.get_active_material(s) as BaseMaterial3D
			if src == null:
				continue
			var mat := src.duplicate() as BaseMaterial3D
			mat.albedo_color *= faction_tint
			mat.metallic = 0.0
			mat.metallic_texture = null
			_add_floor(mat)
			mesh.set_surface_override_material(s, mat)


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
		var tile: GridTileData = GridManager.get_tile(_unit.get("grid_pos"))
		lit = clampf(tile.light_value / 100.0, 0.0, 1.0) if tile else 0.0
	var energy := MIN_BRIGHTNESS * (1.0 - lit)
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
	remove_child(_model)
	_model.free()
	_model = null
	_build_model()
	_read_markers()
	_play(_action if _action != &"" else _stance, true)


func _build_light() -> void:
	# Position follows the muzzle, orientation follows the unit — see
	# aimed_light.gd for why those must differ.
	_light_mount = Marker3D.new()
	_light_mount.name = "LightMount"
	# Detached from the unit's rotation because `muzzle_world` answers in world
	# space; _update_light_rig reimposes the position every frame.
	_light_mount.top_level = true
	_light_mount.position = Vector3(0.0, LIGHT_HEIGHT, 0.0)
	add_child(_light_mount)

	_light = SpotLight3D.new()
	_light.name = "Flashlight"
	_light.set_script(load("res://scripts/aimed_light.gd"))
	_light.set("origin_path", NodePath("../LightMount"))
	# This node shares the unit's basis, so it is the facing source.
	_light.set("facing_path", NodePath(".."))
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
	add_child(_light)
	_light.set("bore_direction", stable_bore())


func _read_markers() -> void:
	_bore = _load_markers(variant)


## The bore direction the light and the rules both aim by, in the unit's own
## frame: one stable vector per pose, never a per-frame one — see aimed_light.gd
## `bore_direction`. Unclamped, so a running merc (rifle across his chest) lights
## the wall to his left and lighting_manager.gd agrees with the screen about it.
##
## Straight ahead for a pose with no table, and for any character without a
## measured barrel — every character but the merc.
func stable_bore() -> Vector3:
	var entry: Variant = _bore.get(_bore_pose())
	if entry is Dictionary:
		var mean: Variant = (entry as Dictionary).get("mean_direction")
		if mean is Vector3 and (mean as Vector3).length_squared() > 0.5:
			return mean
	return Vector3(0.0, 0.0, -1.0)


## The same vector in WORLD space, for LightingManager — which must aim its cone
## at exactly what the light on screen is aiming at.
func aim_direction() -> Vector3:
	return (global_transform.basis * stable_bore()).normalized()


## Where the lamp sits right now, in world space: the model's barrel tip, which
## rides the weapon bone through every animation. The mounting point for the
## SpotLight3D, and therefore where the visible cone starts.
func muzzle_world() -> Vector3:
	if _flash and _flash.is_inside_tree():
		return _flash.global_position
	return global_position + Vector3(0.0, LIGHT_HEIGHT, 0.0)


func _bore_pose() -> StringName:
	return _current if _current != &"" else _stance


func _update_light_rig() -> void:
	if _light_mount:
		_light_mount.global_position = muzzle_world()
	if _light:
		# Which pose is playing decides which stable bore applies.
		_light.set("bore_direction", stable_bore())


## The bore tables for `art_variant`, parsed once per variant per run. Returns
## {<pose>: {muzzle, direction, mean_direction}}.
static func _load_markers(art_variant: StringName) -> Dictionary:
	if _marker_cache.has(art_variant):
		return _marker_cache[art_variant]
	var path: String = MUZZLE_MARKER_PATH % art_variant
	var document: Variant = null
	# FileAccess in the editor and wherever the .json ships raw; the JSON
	# resource importer otherwise.
	if FileAccess.file_exists(path):
		document = JSON.parse_string(FileAccess.get_file_as_string(path))
	elif ResourceLoader.exists(path):
		var res: Variant = load(path)
		document = res.data if res is JSON else null
	var out: Dictionary = {}
	if document is Dictionary:
		var bore: Variant = (document as Dictionary).get("bore", {})
		if bore is Dictionary:
			for pose: String in (bore as Dictionary):
				var entry: Dictionary = (bore as Dictionary)[pose]
				out[StringName(pose)] = {
					"muzzle": _to_vectors(entry.get("muzzle", [])),
					"direction": _to_vectors(entry.get("direction", [])),
					"mean_direction": _to_vector(entry.get("mean_direction")),
				}
	_marker_cache[art_variant] = out
	return out


static func _to_vectors(rows: Array) -> Array:
	var out: Array = []
	for row: Variant in rows:
		out.append(_to_vector(row))
	return out


static func _to_vector(row: Variant) -> Vector3:
	if row is Array and (row as Array).size() == 3:
		return Vector3(float(row[0]), float(row[1]), float(row[2]))
	return Vector3.ZERO


func set_flashlight_enabled(on: bool) -> void:
	if _light:
		_light.visible = on


func _process(_delta: float) -> void:
	# Polled: the barrel moves on every animation frame.
	_update_light_rig()


## Re-asserts whatever the unit should be showing, for a unit coming back into
## view (Unit.set_rendered). Nothing plays while a unit is instant, so without
## this the model keeps whatever it showed when it went out of sight — which for
## a unit killed there is standing up rather than lying where it fell.
func refresh() -> void:
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


# --- Playback ----------------------------------------------------------------


## Sets which cover family every subsequent pose resolves through. Cosmetic only:
## the cover BONUS is a property of the tile edge the shot crosses, never of
## what the unit is doing on screen.
func set_cover_pose(family: StringName) -> void:
	if family == _cover:
		return
	_cover = family
	_play(_action if _action != &"" else _stance)


func set_stance(stance: StringName) -> void:
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
	if _instant():
		# Still recorded, so a unit killed out of sight is a body when it next
		# comes into view.
		if action == DOWNED:
			_settle_dead()
		return
	_action = action
	_play(action, true)
	# The same length with or without a model, which is what keeps every
	# timing-dependent caller behaving the same before and after art exists.
	var resolved := _resolved_base(action)
	await get_tree().create_timer(
		_duration(resolved) if resolved != &"" and _authored
			else FALLBACK_TIME.get(action, DEFAULT_FALLBACK_TIME)).timeout
	_action = &""
	# DOWNED hands over to the corpse; every other action returns to the stance.
	if action == DOWNED:
		_settle_dead()
	else:
		_play(_stance)


## Makes DEAD the stance, where the model has it. One without keeps DOWNED's
## last frame — asking for DEAD there would fall through `_play` to IDLE and
## stand the body up.
func _settle_dead() -> void:
	if _resolved_base(DEAD) == &"":
		return
	_stance = DEAD
	_play(DEAD)


## Plays the flinch for a hit the unit survived, through the cover chain like
## every other pose. Fire-and-forget: nothing about the fight may wait on the
## victim's reaction, so missing art costs NO time here. Skipped rather than
## stacked when another one-shot is already on screen.
func play_hit_react() -> void:
	if _instant() or _action != &"" or not (_authored and _has_any(HIT_REACT)):
		return
	await play_action(HIT_REACT)


## Plays a one-shot that bridges the current stance into `next`, then settles
## there. Coroutine — callers MUST await. Missing art costs NO time: it falls
## straight through to the stance, a hard cut rather than a mysterious pause.
func play_stance_exit(action: StringName, next: StringName) -> void:
	if _instant() or not _has_any(action):
		set_stance(next)
		return
	# Recorded WITHOUT playing it, so the exit animation is what shows; the tail
	# of play_action then settles into whatever _stance has become.
	_stance = next
	await play_action(action)


func play_burst(rounds: int) -> void:
	# Coroutine — callers MUST await. Weapon comes up, fires `rounds` rounds on a
	# fixed cadence, holds, then hands back to the stance. One `muzzle` per round.
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
	_play(BEGIN_SHOOT if begin != &"" else AIM_HOLD, true)
	await get_tree().create_timer(
		_phase_time(BEGIN_SHOOT, begin, RAISE_TIME, COVER_RAISE_TIME)).timeout
	# FIRE has no cover variant BY DESIGN: the unit has already stepped out, so
	# it fires exactly as it does in the open.
	for _i in rounds:
		# Restarted, so every round gets its own kick and its own flash.
		_play(FIRE_SHOOT, true)
		muzzle.emit()
		await get_tree().create_timer(BURST_CADENCE).timeout
	_play(END_SHOOT if end != &"" else AIM_HOLD, true)
	await get_tree().create_timer(
		_phase_time(END_SHOOT, end, SETTLE_TIME, COVER_SETTLE_TIME)).timeout
	_action = &""
	_play(_stance)


## How long a burst phase holds: the cover length when a cover variant answered
## for it, the plain length otherwise.
func _phase_time(base: StringName, resolved: StringName, plain: float,
		in_cover: float) -> float:
	return in_cover if resolved != &"" and resolved != base else plain


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
	if _instant():
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
	if _model:
		_model.rotation.y = deg_to_rad(_pose_yaw.get(pose, 0.0))
	if _flash:
		_flash.visible = pose == FIRE_SHOOT
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
		if restart or _phases[i] != 0.0:
			player.seek(_phases[i] * length, true)


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
func set_status_color(color: Color) -> void:
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
	inst.material_override = mat
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
