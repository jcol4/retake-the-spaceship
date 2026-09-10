class_name UnitVisual
extends Node3D
## Owns a unit's sprite layers and their animation state. Unit code drives this
## by intent ("play the shoot action"), never by clip name, which is what let the
## rigged 3D characters be swapped out for hand-drawn sprites without `Unit`
## changing at all.
##
## Four `AnimatedSprite3D` layers by default — body, head, helmet, weapon — but
## the set is data-driven (`layers`), because whether vertical aiming comes back
## as an independently-posed arm layer is still open. Adding a fifth layer must
## cost art and nothing else.
##
## Works with no authored art: `_build_placeholders` draws a readable stand-in
## per layer and direction, and actions resolve on a timer of the length the
## real animation will eventually take. That is the path every unit takes today,
## and it keeps action pacing identical across the swap — the same guarantee the
## no-AnimationPlayer fallback used to give.

## Fired at the shot's muzzle-flash frame. Drives the VFX tracer, so the beam
## leaves the barrel when the arm is up rather than the instant the order was
## given.
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
# every pose then resolves through the `_low` suffix (see COVER_LOW). A separate
# `crouch_idle` existed only because the mocap set shipped one, and it competed
# with `idle_low` for the same job — a hunker resolved through it fell back to
# standing-in-the-open and read as having done nothing.

# Firing is two animations driven by play_burst rather than one per shot type:
# the burst length is rolled per shot, and no fixed animation can match a count
# it does not know. AIM_HOLD is the weapon up and steady either side of the
# burst; the three-phase BEGIN/FIRE/END set below is what actually plays.
const AIM_HOLD := &"aim_hold"
## The three phases of a burst, authored as three actions. BEGIN is the rifle
## coming up to the shoulder, FIRE is one round's kick replayed from the start
## once per round, END is lowering back out of the aim.
##
## Each degrades independently: a character with only FIRE art still fires, it
## just cuts to the kick and back. The timers below run either way, so burst
## pacing does not move as art lands — the same guarantee the rest of the
## fallback system gives.
const BEGIN_SHOOT := &"begin_shoot"
const FIRE_SHOOT := &"fire_shoot"
const END_SHOOT := &"end_shoot"
# Transitions. Not stances and not actions: a one-shot bridging one stance into
# another, played through play_stance_exit. Degrades to a hard cut, at zero time
# cost, when the art is absent.
#
# One of them, where the mocap set had a bridge between every pair of stances.
# The crouch pair went with the crouch stance; going down into cover and standing
# back up are both cuts now.
const RUN_STOP := &"run_stop"
const MELEE := &"melee"
const RELOAD := &"reload"
const GRENADE := &"throw_grenade"
const INTERACT := &"interact"
const HIT_REACT := &"hit_react"
const DOWNED := &"downed"
## Alien-side only: played once when an alien wakes, by EnemyUnit's state machine
## rather than by anything the player ordered.
const ALERT_SCREAM := &"alert_scream"
## Idle variation, played at random intervals while IDLE holds. Not an action and
## not a stance: a one-shot the unit slips into on its own, with nothing in the
## game waiting on it. See _fidget_loop for why that decides how it is played.
const IDLE_FIDGET := &"idle_fidget"

# When each boot lands during the run cycle, evenly spaced half a cycle apart.
# The GAP is a property of a soldier moving at 4.5 m/s rather than of how the
# character is drawn, so the run cycle is authored to match it and not the other
# way round: two steps per cycle at 0.333 s makes the cycle 0.666 s, which at
# build_sprite_frames.gd's 12 fps is the eight frames a cycle is drawn in.
#
# The OFFSET is the authoring contract that follows from that: zero, meaning
# FRAME 0 IS A CONTACT and so is frame 4. It was 0.10 while the run was a Mixamo
# clip, which recorded nothing about a soldier — only where that take's frame 0
# happened to fall relative to the first footplant. A drawn cycle starts on a
# contact, so the offset that made sense for the mocap is now just a 1.2-frame
# error between the boot landing and the sound.
const FOOTSTEP_OFFSET := 0.0
const FOOTSTEP_GAP := 0.333

# Seconds of plain idle between attempts at an IDLE_FIDGET. Rolled fresh each
# time rather than fixed, which matters most with several units on screen: a
# constant gap would have a nest of swarm units convulsing in lockstep, and
# nothing reads as scripted faster than that.
const FIDGET_GAP_MIN := 12.0
const FIDGET_GAP_MAX := 35.0

## How long each action occupies, so pacing is identical with or without authored
## art. Read as a stand-in when the art is missing, and as the AUTHORING CONTRACT
## when it is drawn — build_sprite_frames.gd derives `speed` as frames/duration
## from the same table, so a pose drawn in any number of frames still takes
## exactly this long.
##
## The values arrived here as the old 3D soldier's measured clip lengths, which
## is why some of them are oddly precise. They are kept not because a mocap take
## has any authority over a drawn one, but because the game's turn rhythm was
## tuned against them and none of it has been re-tuned. Same treatment as
## Unit.move_speed and FOOTSTEP_OFFSET: the number is now OWNED rather than
## inherited, and it is the dial to turn if an action feels wrong — changing one
## is a pacing decision, not a correction.
const FALLBACK_TIME := {
	BEGIN_SHOOT: RAISE_TIME,
	FIRE_SHOOT: BURST_CADENCE,
	END_SHOOT: SETTLE_TIME,
	MELEE: 1.20,
	RELOAD: 3.75,
	GRENADE: 1.00,
	INTERACT: 1.00,
	HIT_REACT: 0.47,
	DOWNED: 0.80,
	ALERT_SCREAM: 2.80,
}
const DEFAULT_FALLBACK_TIME := 0.4

# Burst timing. RAISE_TIME is the beat where the weapon comes up and steadies
# before the first round — without it the shot reads as going off the instant the
# order was given. BURST_CADENCE is the gap between rounds, short enough that the
# kick has not fully recovered when the next lands, which is what makes a burst
# look continuous. SETTLE is the weapon held on target afterwards.
#
# 0.45 s, raised from 0.18. At 0.18 the beat was only ever dead air: it was long
# enough to stop a shot reading as instantaneous, but far too short to SHOW a
# rifle being shouldered — a 0.18 s raise is two frames at the rate everything
# else is drawn at, which is a cut with an extra image in it, not a movement.
# Deliberate shouldering is the read this wants, and it costs about a quarter of
# a second per shot in turn pacing. That cost is the reason this is a constant
# with a comment rather than a number: it is the dial to turn if combat starts
# feeling slow.
const RAISE_TIME := 0.45
const BURST_CADENCE := 0.11
const SETTLE_TIME := 0.20

## The same two beats when the shot is fired FROM COVER, where the phases are a
## step out from behind the crate and a duck back behind it rather than a rifle
## coming up on the spot. Longer because there is further to travel — a 0.45 s
## step-out would read as a teleport with a lean in the middle.
##
## Applied only when the cover art actually resolved, so a character part-way
## through being drawn keeps standing-shot pacing for the phases it has no cover
## art for. Must equal build_sprite_frames.gd's ONE_SHOT_TIME entries for
## `begin_shoot_low` and `end_shoot_low`, for the reason stated there.
const COVER_RAISE_TIME := 0.75
const COVER_SETTLE_TIME := 0.45

## The WALK stance is still used, but only by `walks_only` units (the brawler),
## which carry their own speed in Unit.move_speed rather than a shared
## constant. The soldier/merc has no walk cycle — that was a Mixamo mocap
## placeholder that was never drawn and is not being drawn — so he has one
## gait, RUN, at any distance. See Unit.move_along.

# --- Direction ---------------------------------------------------------------
#
# Sprite direction is the unit's yaw MINUS the camera's, quantised into eight
# 45-degree buckets. Subtracting the camera is what makes this work under a rig
# whose yaw snaps: a quarter turn moves every bucket by exactly two steps, so the
# snap costs no additional art — but it DOES change every character's apparent
# facing without any unit having turned, which is why _sync_direction is driven
# off the rig's yaw_changed signal as well as off unit facing.

## Screen-space directions, indexed by bucket. EIGHT, matching the eight
## directions a unit may step and face (GridManager.STEPS, Unit._yaw_toward), so
## no reachable facing is without art.
##
## They are named for where they point ON SCREEN, not in the world, and the two
## differ by the rig's 45-degree yaw (camera_rig.gd START_YAW): the four world
## grid AXES project to the four screen DIAGONALS, and the four world diagonals
## project to the screen cardinals. So a unit facing world -Z reads as `ne`,
## up-and-right, rather than straight up.
##
## Bucket 0 is up-right; the index rises with yaw, which — given Godot's -Z
## forward and +X screen-right — runs anticlockwise on screen. This is the same
## order, and must stay the same order, as render_sprites.py's DIRECTIONS, which
## is the index-to-Blender-angle table the PNGs are rendered from.
const DIRECTIONS: Array[StringName] = [
	&"ne", &"n", &"nw", &"w", &"sw", &"s", &"se", &"e",
]

## Three of the eight buckets are another bucket flipped. Only the five that face
## screen-right or straight up/down need authoring; the three left-facing ones
## are those mirrored. Entries are [source direction, flip_h].
##
## A pose that is NOT symmetric — anything armed, where flipping moves the rifle
## to the wrong shoulder — can be authored for all eight instead: if the sprite
## set contains art for the mirrored direction itself, _resolve uses it unflipped
## and this table never applies. That is the path the merc takes; see
## tools/build_sprite_frames.gd.
const MIRROR := {
	&"nw": [&"ne", true],
	&"w": [&"e", true],
	&"sw": [&"se", true],
}

## Cover pose families. A unit using cover resolves every pose through the
## matching suffix FIRST — `idle` becomes `idle_low`, `begin_shoot` becomes
## `begin_shoot_low` — and falls back to the plain pose wherever that art does
## not exist. See `_bases`.
##
## This is why cover needed no new stances and no new branches in `Unit`: the
## unit still asks for "idle" and "a burst", and which art that means is decided
## in one place. It also means the art can land one pose at a time — today only
## `idle_low` is drawn, and the step-out and step-back degrade to the standing
## versions until they are.
const COVER_LOW := &"low"
const COVER_HIGH := &"high"

## Rotates the bucket window so each bucket is CENTRED on a drawn direction
## rather than straddling two. Without it a unit facing a world axis would sit
## exactly on the boundary between two buckets and flicker between them under
## floating-point noise.
##
## Still PI/4 at eight buckets, and not by coincidence: the reachable relative
## yaws are the rig's -45 degrees plus any multiple of the 45-degree bucket
## width, so the same offset that centred four 90-degree buckets centres eight
## 45-degree ones.
const BUCKET_OFFSET := PI / 4.0

## Layers, back to front. Data-driven rather than four hardcoded nodes so an arm
## layer (or anything else) can be added in art alone.
@export var layers: Array[StringName] = [&"body", &"head", &"helmet", &"weapon"]

## Art variant, and the directory the `SpriteFrames` are looked up in. Gear swaps
## are a reassignment of this — see `set_variant`.
@export var variant: StringName = &"soldier"

## World height of a layer's full canvas, in metres. Replaces a shared
## `pixel_size`: each layer derives its own as `canvas_height / texture_height`,
## so layers drawn at DIFFERENT resolutions still register with one another and
## still land on the same pivot. That is what lets 256-px authored art composite
## against the 64-px code placeholder without either being rescaled by hand.
##
## 1.92 is what the old `CANVAS` 64 x `pixel_size` 0.03 came to, so the
## placeholder's on-screen size is unchanged.
@export var canvas_height: float = 1.92

## Where the art's origin sits in the canvas, as a fraction: the FEET, not the
## centre. Every layer shares it, which is what keeps a helmet on a head across a
## gear swap.
##
## Exported rather than a constant because it is a property of the CANVAS, like
## `canvas_height` beside it, and the placeholder and the authored art no longer
## agree on it. The placeholder is drawn with the feet flush to the bottom edge,
## so 1.0 is right for it and is the default. Rendered art cannot be: the sprite
## camera is tilted, so the floor projects to a DIAGONAL through the world origin
## rather than to a horizontal line under the boots, and a foot planted toward
## the camera falls below the frame. `render_sprites.py` answers that with
## FLOOR_MARGIN metres of floor below the origin, which moves the anchor up off
## the bottom edge by exactly that fraction -- see that file for the arithmetic.
@export var foot_anchor: Vector2 = Vector2(0.5, 1.0)

## Whether this character carries the rig-mounted light (Sec 5.2). Aliens do not.
@export var has_light: bool = true

## Multiplied into the tile-light tint, so two factions can share one sprite set
## and still be told apart at XCOM camera distance. White (identity) by default.
##
## MULTIPLIED rather than assigned, which is the whole reason it is safe: a
## tinted unit standing in the dark still reads dark, so the tint cannot quietly
## undo the rule that a unit which LOOKS lit is one the rules also treat as lit
## (see `_apply_tile_light`).
##
## A stopgap that is honest about being one — the rival mercs wear the player's
## own rendered art recoloured, because that art is literally already called
## `merc` (`variant = &"merc"`). A real second sprite set replaces this; until
## then a flat multiply beats shipping two identical-looking factions.
@export var faction_tint: Color = Color.WHITE

## TEST HOOK for shaders/gritty_fallout.gdshader — assign the material here (or
## shaders/gritty_fallout_test.tres directly) to see it on every layer of this
## unit. Left null it changes nothing; this is scaffolding for eyeballing the
## look, not the real place a shipped filter would be wired in.
@export var test_shader: ShaderMaterial = null

## Which family of shapes the placeholder generator draws for this character.
## `organic` is the standing biped everything started as; `machine` is the
## hard-edged, geometric read the security robots are specified with
## (security-robots/design-choices/faction-identity.md) — the point being that a
## player can tell the factions apart by silhouette alone in a dark corridor,
## which is where most fights happen. Has no effect once authored art exists.
@export var placeholder_style: StringName = &"organic"

# --- Placeholder art ---------------------------------------------------------

## The PLACEHOLDER's source canvas, in pixels — not a constraint on authored art,
## which may be any square size (see _apply_frame_scale). Square so a rotation of
## the art never changes the pivot. `_placeholder_texture` draws in these
## coordinates, so changing it means redrawing every stand-in.
const CANVAS := 64

## Darkest a sprite is allowed to get. Sprites are UNSHADED and tinted from the
## tile's light_value instead of being lit, so this is the floor of that tint:
## far enough down to read as "in the dark", not so far the unit is lost.
const MIN_TINT := 0.35

## Layers the tile-light tint is NOT applied to. A status light is a light — it
## is the thing emitting, not the thing being lit — and dimming it in a dark room
## would put out the one readability aid the security robots have in exactly the
## conditions it exists for.
const SELF_LIT_LAYERS: Array[StringName] = [&"status"]

## Where a shot leaves the weapon, relative to the unit: shoulder height, and
## forward of the body so a tracer does not visibly start inside the chest.
## Derived from unit yaw in world space rather than from a per-direction table,
## because the muzzle is a world point and the camera must not move it.
const MUZZLE_HEIGHT := 1.4
const MUZZLE_REACH := 0.3
## Height the rig light is mounted at. A fixed offset now: it used to ride a
## helmet bone, and a sprite has no bones — but the light was never character
## art, it is a detection mechanic (aimed_light.gd).
const LIGHT_HEIGHT := 1.6

## Where the rifle's lamp is, and which way its barrel points, per animation
## frame. Written by `tools/render_sprites.py --markers` from two locator
## spheres on the bore line, and expressed in the UNIT'S OWN FRAME in Godot
## axes — so one table of N frames serves all eight facings, and the light can
## follow it at any continuous yaw rather than snapping to a bucket.
##
## THIS IS WHAT A SPRITE GETS INSTEAD OF A BONE. The old rig hung the light off
## a helmet bone; drawn art has none, and a fixed offset could only ever be
## right in one frame of one facing. Measured off the model instead — the
## markers are never rendered, see MARKER_MATERIAL in render_sprites.py for why
## reading the object beats colour-keying a magenta blob back out of the art.
##
## A pose with no entry gets no beam, which is the same graceful nothing a
## character with no art for a pose already gets. Only `idle` is exported today.
const MUZZLE_MARKER_PATH := "res://assets/sprites/muzzle_%s.json"

var _sprites: Dictionary = {}  # layer StringName -> AnimatedSprite3D
var _frames: Dictionary = {}  # layer StringName -> SpriteFrames
var _light: SpotLight3D = null
var _light_mount: Marker3D = null
## pose StringName -> {muzzle: Array[Vector3], direction: Array[Vector3],
## mean_direction: Vector3}, all in the unit's own frame. Only `mean_direction`
## is read today — it aims the light, and through it the rules. The per-frame
## arrays are what a swaying effect would need and are kept exported against
## that, but nothing sways now: see aimed_light.gd `bore_direction`.
var _bore: Dictionary = {}
## `<pose>_<direction>` StringName -> Array[Vector2] of canvas positions, which
## is what actually places the lamp on screen.
var _canvas: Dictionary = {}
## Metres the body layer's canvas spans. Cached because the lamp's placement
## needs it every frame and `_frame_size` walks animations to find it.
var _canvas_metres := Vector2.ZERO
var _unit: Node3D = null
## Cached: _sync_direction runs every frame per unit, and a group lookup there
## would be the most-called line in the game for no reason.
var _rig: Node3D = null

var _stance: StringName = IDLE
var _action: StringName = &""
var _direction := 0
## True once real authored art is found. Decides whether an action's length comes
## from the animation or from FALLBACK_TIME — see play_action.
var _authored := false
var _stepping: bool = false
var _fidgeting: bool = false
## COVER_LOW, COVER_HIGH, or "" for a unit not using cover. Written by the unit
## (Unit.refresh_cover_pose), read by `_bases` on every resolve.
var _cover: StringName = &""
## Tint for the self-lit `status` layer, if this character has one. White until
## a unit says otherwise — see CerberusUnit._refresh_status_light.
var _status_color := Color.WHITE

## Parsed marker tables, keyed by variant. STATIC because every unit of a
## variant reads the identical table, and a squad of six parsing the same JSON
## six times is waste that scales with squad size.
static var _marker_cache: Dictionary = {}


func _ready() -> void:
	# Children are ready before their parent, so Unit._ready can rely on these.
	_unit = get_parent() as Node3D
	_build_layers()
	# Before _build_light, which aims the light off it.
	_read_markers()
	if has_light:
		_build_light()
	_rig = get_tree().get_first_node_in_group("camera_rig") as Node3D
	if _rig:
		_rig.yaw_changed.connect(_on_camera_yaw_changed)
	if LightingManager:
		LightingManager.lighting_changed.connect(_apply_tile_light)
	_sync_direction()


## Whether playback should resolve with no time on the clock. Delegated to the
## unit rather than cached, because the answer changes DURING a move: a unit that
## walks into the squad's view stops being fast-forwarded partway through. One
## authority for it, in Unit.is_instant, keeps the two halves from disagreeing.
func _instant() -> bool:
	return _unit.is_instant() if _unit and _unit.has_method("is_instant") else false


func setup() -> void:
	_play(IDLE)
	_apply_tile_light()
	# Started here as well as from set_stance so a unit fidgets from the moment it
	# spawns. Aliens spend most of a mission asleep at their nests, which is
	# precisely when the player is looking at one standing still.
	_maybe_start_fidget()


# --- Layer construction ------------------------------------------------------


func _build_layers() -> void:
	# Nothing to draw with no display, and the placeholder generator would paint
	# 90 textures per layer per unit for a screen nobody is looking at. Every
	# consumer already handles an empty layer set: _has_any returns false, which
	# is the same answer a character with no art for a pose gives.
	if DisplayServer.get_name() == "headless":
		return
	for layer in layers:
		var frames := _load_frames(layer)
		if frames == null:
			frames = _placeholder_frames(layer)
		else:
			_authored = true
		_frames[layer] = frames
		var sprite := AnimatedSprite3D.new()
		sprite.name = String(layer).capitalize()
		sprite.sprite_frames = frames
		# Scale and pivot both derive from this layer's own texture size, which IS
		# the pivot contract: every layer resolves to the same world height with
		# its origin on `foot_anchor`, so reassigning one layer's frames can never
		# shift it against the others no matter what resolution it was drawn at.
		_apply_frame_scale(sprite, frames)
		# Always face the viewer, upright. Direction is carried by WHICH art is
		# shown, never by turning the quad — that is the whole point of drawing
		# eight of them.
		sprite.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
		# UNSHADED so hand-painted shading is not fought by the realtime lights;
		# the tile's light_value drives `modulate` instead, which keeps the screen
		# agreeing with the accuracy and detection rules.
		sprite.shaded = false
		sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
		sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		if test_shader:
			_apply_test_shader(sprite)
		add_child(sprite)
		_sprites[layer] = sprite


## Wires the test shader onto one sprite. material_override replaces the
## sprite's material entirely — Godot does NOT feed AnimatedSprite3D's frame
## texture into a custom shader automatically, no matter what a uniform is
## named, so this pushes it in by hand on every frame change. A DUPLICATED
## material per sprite, because a shared one would have every layer showing
## whichever sprite last wrote texture_albedo.
func _apply_test_shader(sprite: AnimatedSprite3D) -> void:
	var mat: ShaderMaterial = test_shader.duplicate()
	sprite.material_override = mat
	var push_texture := func() -> void:
		if sprite.sprite_frames and sprite.animation != &"" and sprite.sprite_frames.has_animation(sprite.animation):
			mat.set_shader_parameter("texture_albedo",
				sprite.sprite_frames.get_frame_texture(sprite.animation, sprite.frame))
	sprite.frame_changed.connect(push_texture)
	sprite.animation_changed.connect(push_texture)
	push_texture.call()


## Authored art for one layer, or null while none exists. The naming convention is
## `[part]_[variant]_[animation]_[direction]_[frame].png` under assets/sprites,
## collected into one SpriteFrames per part+variant.
func _load_frames(layer: StringName) -> SpriteFrames:
	var path := "res://assets/sprites/%s_%s.tres" % [layer, variant]
	if not ResourceLoader.exists(path):
		return null
	return load(path) as SpriteFrames


## Sizes one layer from its own art, so resolution is a property of the PNG
## rather than a number that has to be kept in sync by hand. A 64-px placeholder
## and a 256-px authored sheet both come out `canvas_height` metres tall with
## their origin at the feet.
##
## Reads the first frame it can find: a set whose frames disagree on size would
## need a per-frame pivot, which is a problem no art has posed yet.
func _apply_frame_scale(sprite: AnimatedSprite3D, frames: SpriteFrames) -> void:
	var size := _frame_size(frames)
	sprite.pixel_size = canvas_height / size.y
	sprite.offset = Vector2(
		size.x * (0.5 - foot_anchor.x),
		size.y * (foot_anchor.y - 0.5))


## Pixel size of the art in `frames`, falling back to the placeholder canvas when
## there are no frames to measure.
func _frame_size(frames: SpriteFrames) -> Vector2:
	for name in frames.get_animation_names():
		if frames.get_frame_count(name) == 0:
			continue
		var tex := frames.get_frame_texture(name, 0)
		if tex:
			return tex.get_size()
	return Vector2(CANVAS, CANVAS)


## Reassigns every layer's art — a gear swap is exactly this and nothing else,
## because the pivot contract above guarantees the new art lands where the old
## art was.
func set_variant(new_variant: StringName) -> void:
	variant = new_variant
	for layer in layers:
		var frames := _load_frames(layer)
		if frames == null:
			frames = _placeholder_frames(layer)
		else:
			_authored = true
		_frames[layer] = frames
		var sprite := _sprites[layer] as AnimatedSprite3D
		sprite.sprite_frames = frames
		# Re-derived, not carried over: the incoming art may be a different
		# resolution from what this layer was showing.
		_apply_frame_scale(sprite, frames)
	# New art brings its own barrel with it.
	_read_markers()
	_play(_stance)


func _build_light() -> void:
	# A fixed offset on the unit, not a bone mount. Position follows this node and
	# orientation follows the unit — see aimed_light.gd for why those must differ.
	_light_mount = Marker3D.new()
	_light_mount.name = "LightMount"
	# Detached from the unit's rotation, because `muzzle_world` answers in
	# camera-relative screen space rather than in the unit's own frame; the
	# turntable would otherwise be applied to it twice. _update_light_rig reimposes
	# the position every frame, same pattern as aimed_light.gd itself.
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
	# THE VISIBLE CONE. main.tscn has volumetric_fog_enabled with a density of
	# 0.01, so this is the whole of the shaft between the barrel and the pool —
	# no mesh, no shader, and no possibility of drifting out of line with the
	# floor, because the cone IS this light. Walls occlude it for free, since
	# the light already casts shadows.
	#
	# This was 0 for a while, and the reason it was is worth keeping: mounted at
	# the body's centre it read as a haze hugging the model rather than as a
	# beam. That was a POSITION problem, not a technique one. The mount now
	# tracks the measured muzzle (see _update_light_rig), so the same setting
	# now scatters from the gun.
	#
	# This is the dial for how present the shaft is. Prefer it over raising the
	# environment's fog DENSITY, which would haze the whole ship rather than
	# this one beam. 1.0 is Godot's default; 3.0 was the setting that read as a
	# haze on the model back when the light was mounted at the chest.
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

	# Aimed down the measured bore rather than down the unit's -Z, using the
	# STABLE cycle mean — see aimed_light.gd `bore_direction` for why the rules
	# must not be given a direction that sways.
	_light.set("bore_direction", stable_bore())


## Pulls both marker tables for the current variant, and re-measures the canvas
## so the lamp's placement is derived from the art's own resolution.
func _read_markers() -> void:
	var tables := _load_markers(variant)
	_canvas = tables.get("canvas", {})
	_bore = tables.get("bore", {})
	var sprite: AnimatedSprite3D = _sprites.get(&"body")
	if sprite and sprite.sprite_frames:
		_canvas_metres = _frame_size(sprite.sprite_frames) * sprite.pixel_size


## The bore direction the light and the rules both aim by, in the unit's own
## frame: one stable vector per pose, never the swaying per-frame one — see
## aimed_light.gd `bore_direction` for why the rules must not be given a
## direction that moves within a cycle.
##
## RETURNED UNCLAMPED, however far off the unit's facing the barrel points, and
## the run cycle is why that is worth stating. A merc runs with the rifle across
## his chest, so `run` measures 73 degrees off his direction of travel. That was
## gated for a while — a 35-degree ceiling that admitted every standing pose and
## rejected only the run — on the grounds that swinging the detection cone
## three-quarters of a right angle sideways is a real change to how stealth
## plays. It is, and the gate came out anyway: the light visibly leaving the gun
## was judged to matter more than the cone pointing where the player is walking.
##
## So a running merc lights the wall to his left rather than the corridor ahead,
## and lighting_manager.gd agrees with the screen about it. That is a property
## of running, not a bug — move fast and you cannot see where you are going.
## Reinstating the ceiling is a two-line change here if it plays badly.
##
## Falls back to straight ahead only for a pose with no table at all, and for
## any character without a measured barrel — every character but the merc.
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


## Where the lamp sits on screen right now, in world space. This is where the
## SpotLight3D is mounted, and therefore where the visible cone starts.
##
## FROM THE CANVAS, NOT FROM THE 3D MARKER, and the difference is not a detail.
## Under this camera a point's screen height mixes its world height with its
## horizontal depth (screen up is (-0.408, 0.408, 0.816)), and the render baked
## that mixture into the canvas. A billboard cannot reproduce it: the quad is
## flat and always faces the viewer, so the depth term is simply gone. Place the
## lamp at its true 3D position and it lands about 0.15 m BELOW the drawn barrel
## — physically right, visibly wrong, which is the gap this replaced.
##
## The 3D bore is still exactly right for the light's DIRECTION, which is a
## rotation and carries no such error.
func muzzle_world() -> Vector3:
	var sprite: AnimatedSprite3D = _sprites.get(&"body")
	var here := _canvas_frame()
	if sprite == null or here == Vector2.ZERO:
		return global_position + Vector3(0.0, LIGHT_HEIGHT, 0.0)
	var u := here.x
	# A mirrored pose shows the art flipped, so the marker flips with it.
	if sprite.flip_h:
		u = 1.0 - u
	# Canvas fraction -> metres out from the sprite's own origin, which
	# `foot_anchor` places at the feet. The sprite is a FIXED_Y billboard, so its
	# right IS the camera's horizontal right and its up IS world up — exactly the
	# pair this offset decomposes onto.
	var dx := (u - foot_anchor.x) * _canvas_metres.x
	var dy := (foot_anchor.y - here.y) * _canvas_metres.y
	var right := _rig.global_transform.basis.x.normalized() if _rig else Vector3.RIGHT
	return global_position + right * dx + Vector3.UP * dy


## This frame's canvas position for the lamp, or ZERO when the pose has none.
func _canvas_frame() -> Vector2:
	var sprite: AnimatedSprite3D = _sprites.get(&"body")
	if sprite == null:
		return Vector2.ZERO
	var track: Variant = _canvas.get(sprite.animation)
	if not (track is Array) or (track as Array).is_empty():
		return Vector2.ZERO
	var entries: Array = track
	return entries[clampi(sprite.frame, 0, entries.size() - 1)]


## Which pose's bore table applies. The bore is keyed by POSE, not by the
## `<pose>_<direction>` animation name, because it lives in the unit's own frame
## and so does not vary with facing — see MUZZLE_MARKER_PATH.
func _bore_pose() -> StringName:
	var sprite: AnimatedSprite3D = _sprites.get(&"body")
	if sprite == null:
		return _stance
	var text := String(sprite.animation)
	for dir: StringName in DIRECTIONS:
		var suffix := "_" + String(dir)
		if text.ends_with(suffix):
			return StringName(text.substr(0, text.length() - suffix.length()))
	return StringName(text)


## Keeps the light sitting on the drawn muzzle and pointing down the measured
## bore. That is the whole per-frame job now: the visible cone is the light's
## own volumetric scattering, so there is no second thing to keep in step with
## it and no way for the shaft and the floor pool to disagree.
func _update_light_rig() -> void:
	if _light_mount:
		# GLOBAL, because `muzzle_world` answers in camera-relative screen space
		# and the mount's parent turns with the unit. `top_level` in _build_light
		# is what makes this the whole story rather than half of it.
		_light_mount.global_position = muzzle_world()
	if _light:
		# Refreshed per frame rather than once at build: which pose is playing
		# decides which stable bore applies, and no pose is playing yet when the
		# light is built. Cheap — one vector write.
		_light.set("bore_direction", stable_bore())


## The marker tables for `art_variant`, parsed once per variant per run and
## turned into vectors here rather than on every frame that reads one. Returns
## {canvas: {<pose>_<dir>: Array[Vector2]}, bore: {<pose>: {...}}}.
static func _load_markers(art_variant: StringName) -> Dictionary:
	if _marker_cache.has(art_variant):
		return _marker_cache[art_variant]
	var path: String = MUZZLE_MARKER_PATH % art_variant
	var document: Variant = null
	# FileAccess in the editor and wherever the .json ships raw; the JSON
	# resource importer otherwise. Trying both means the table resolves either
	# way rather than only under whichever the project happens to be set to.
	if FileAccess.file_exists(path):
		document = JSON.parse_string(FileAccess.get_file_as_string(path))
	elif ResourceLoader.exists(path):
		var res: Variant = load(path)
		document = res.data if res is JSON else null
	var bore_out: Dictionary = {}
	var canvas_out: Dictionary = {}
	if document is Dictionary:
		var bore: Variant = (document as Dictionary).get("bore", {})
		if bore is Dictionary:
			for pose: String in (bore as Dictionary):
				var entry: Dictionary = (bore as Dictionary)[pose]
				bore_out[StringName(pose)] = {
					"muzzle": _to_vectors(entry.get("muzzle", [])),
					"direction": _to_vectors(entry.get("direction", [])),
					"mean_direction": _to_vector(entry.get("mean_direction")),
				}
		var frames: Variant = (document as Dictionary).get("frames", {})
		if frames is Dictionary:
			for anim: String in (frames as Dictionary):
				var rows: Array = (frames as Dictionary)[anim]
				var track: Array = []
				for row: Variant in rows:
					track.append(Vector2(float(row[0]), float(row[1]))
						if row is Array and (row as Array).size() == 2 else Vector2.ZERO)
				canvas_out[StringName(anim)] = track
	var out := {"canvas": canvas_out, "bore": bore_out}
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


# --- Direction ---------------------------------------------------------------


func _on_camera_yaw_changed(_yaw: float) -> void:
	_sync_direction()


func _process(_delta: float) -> void:
	# Unit facing is tweened rather than signalled, so it is polled. One float
	# compare and a bucket calculation per unit per frame.
	_sync_direction()
	# Polled for the same reason, and additionally because the bore moves WITHIN
	# a pose: the answer changes on every sprite frame, not just when the facing
	# does.
	_update_light_rig()


## Re-buckets every layer in lockstep. Called on unit facing changes and on
## camera yaw changes, because either one moves the direction the player sees.
func _sync_direction() -> void:
	if _unit == null:
		return
	var bucket := _bucket(_unit.rotation.y - _camera_yaw())
	if bucket == _direction and not _sprites.is_empty():
		return
	_direction = bucket
	_play(_action if _action != &"" else _stance)


func _camera_yaw() -> float:
	return _rig.rotation.y if _rig else 0.0


## Static so the mapping can be checked without a scene — see
## tools/test_sprite_direction.gd.
static func direction_bucket(relative_yaw: float) -> int:
	return wrapi(roundi((relative_yaw + BUCKET_OFFSET) / (TAU / DIRECTIONS.size())),
		0, DIRECTIONS.size())


func _bucket(relative_yaw: float) -> int:
	return direction_bucket(relative_yaw)


## The poses to try for `base`, most specific first: the current cover family's
## variant, then the plain pose.
##
## This is the whole cover-art mechanism. Because it is a FALLBACK CHAIN rather
## than a lookup, a cover variant that has not been drawn costs nothing and
## changes nothing — the plain pose answers instead, exactly as it does for a
## unit standing in the open.
func _bases(base: StringName) -> Array[StringName]:
	if _cover == &"":
		return [base]
	return [&"%s_%s" % [base, _cover], base]


## The animation name and flip for `base` in the current direction, resolving the
## cover chain and then the 5-drawn + 3-mirrored rule. Returns
## [name, flip_h, resolved_base] — the third being WHICH candidate answered, so
## play_burst can tell a step-out from a shoulder-and-fire.
func _resolve(layer: StringName, base: StringName) -> Array:
	var frames: SpriteFrames = _frames[layer]
	var dir: StringName = DIRECTIONS[_direction]
	# Cover art in ANY form beats plain art, mirrored included: showing the crate
	# pose flipped is right, and showing the standing pose unflipped is not.
	for candidate in _bases(base):
		var direct := &"%s_%s" % [candidate, dir]
		# An asymmetric pose authored for all eight wins over the mirror table.
		if frames.has_animation(direct):
			return [direct, false, candidate]
		if MIRROR.has(dir):
			var m: Array = MIRROR[dir]
			var mirrored := &"%s_%s" % [candidate, m[0]]
			if frames.has_animation(mirrored):
				return [mirrored, m[1], candidate]
	return [&"", false, &""]


## Which candidate `base` actually resolved to, or "" if nothing did. Equal to
## `base` when the plain pose answered and to the suffixed name when a cover
## variant did.
func _resolved_base(base: StringName) -> StringName:
	for layer in layers:
		if not _frames.has(layer):
			continue
		var resolved := _resolve(layer, base)
		if resolved[0] != &"":
			return resolved[2]
	return &""


# --- Playback ----------------------------------------------------------------


## Sets which cover family every subsequent pose resolves through. A cosmetic
## switch only: the cover BONUS is a property of the tile edge the shot crosses
## (GridManager.cover_type_on), never of what the unit is doing on screen, so no
## value here can move an accuracy number.
func set_cover_pose(family: StringName) -> void:
	if family == _cover:
		return
	_cover = family
	# Re-resolved rather than restarted: the pose NAME on screen is unchanged, so
	# a unit that steps into cover mid-idle swaps art without its cycle jumping
	# back to frame 0. Restart is what `_play`'s second argument is for, and this
	# is deliberately not that case.
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
	# one is still on screen.
	# Shooting does NOT come through here — see play_burst. This drives the
	# one-shots that fire no rounds, so nothing here emits `muzzle`.
	if _instant():
		return
	_action = action
	_play(action)
	# With placeholder art an animation is a single held frame, so waiting on
	# animation_finished would either return instantly or never. Holding for the
	# length the authored animation will take is what keeps every timing-dependent
	# caller behaving the same before and after the art exists.
	if _authored and _has_any(action):
		await _await_animation(action)
	else:
		await get_tree().create_timer(
			FALLBACK_TIME.get(action, DEFAULT_FALLBACK_TIME)).timeout
	_action = &""
	# DOWNED holds its last frame; every other action returns to the stance.
	if action != DOWNED:
		_play(_stance)


## Plays a one-shot that bridges the current stance into `next`, then settles
## there. Coroutine — callers MUST await.
##
## Unlike play_action, missing art costs NO time: it falls straight through to
## the stance. That makes this safe to call before the art has been drawn, and
## means an absent transition degrades to a hard cut rather than to a mysterious
## pause on every move.
func play_stance_exit(action: StringName, next: StringName) -> void:
	if _instant() or not _has_any(action):
		set_stance(next)
		return
	# Assigned rather than passed to set_stance: writing the field directly
	# records where to land WITHOUT playing it, so the exit animation is what
	# shows on screen. play_action's tail then settles into whatever _stance has
	# become.
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
	# which art answered: a step out of cover takes longer than shouldering a
	# rifle on the spot. Empty means neither the cover variant nor the plain pose
	# exists, and the phase degrades to AIM_HOLD as it always has.
	var begin := _resolved_base(BEGIN_SHOOT)
	var end := _resolved_base(END_SHOOT)
	# Each phase falls back to AIM_HOLD, so a character missing the raise or the
	# lower still holds the weapon up for that beat rather than skipping it. The
	# timers run regardless, which is what keeps burst pacing — and therefore
	# turn pacing — identical across characters with different amounts of art.
	_play(BEGIN_SHOOT if begin != &"" else AIM_HOLD)
	await get_tree().create_timer(
		_phase_time(BEGIN_SHOOT, begin, RAISE_TIME, COVER_RAISE_TIME)).timeout
	# FIRE has no cover variant BY DESIGN, and that is the point of the whole
	# arrangement: the unit has already stepped out, so it fires exactly as it
	# does in the open. One set of kick art serves both, which halves what has to
	# be drawn to make cover read.
	for _i in rounds:
		# Restarted from frame 0 rather than merely played: play() on the
		# animation already running is a no-op, so every round after the first
		# would silently skip its kick.
		_play(FIRE_SHOOT, true)
		muzzle.emit()
		await get_tree().create_timer(BURST_CADENCE).timeout
	_play(END_SHOOT if end != &"" else AIM_HOLD)
	await get_tree().create_timer(
		_phase_time(END_SHOOT, end, SETTLE_TIME, COVER_SETTLE_TIME)).timeout
	_action = &""
	_play(_stance)


## How long a burst phase holds: the cover length when a cover variant answered
## for it, the plain length otherwise. Decided per PHASE rather than per shot, so
## a character with `begin_shoot_low` drawn but not `end_shoot_low` gets the long
## step-out and the short settle — which is what its art actually shows.
func _phase_time(base: StringName, resolved: StringName, plain: float,
		in_cover: float) -> float:
	return in_cover if resolved != &"" and resolved != base else plain


## Where a shot leaves the weapon, in world space.
##
## Derived from the UNIT's yaw rather than from the sprite's screen direction, on
## purpose: the muzzle is a point in the world that LOS and the tracer both read,
## and rotating the camera must not move it. A per-direction table would be an
## art refinement on top of this, not a replacement for it.
func muzzle_origin() -> Vector3:
	var yaw: float = _unit.rotation.y if _unit else 0.0
	var forward := Vector3(-sin(yaw), 0.0, -cos(yaw))
	return global_position + forward * MUZZLE_REACH + Vector3(0.0, MUZZLE_HEIGHT, 0.0)


func _has_any(base: StringName) -> bool:
	for layer in layers:
		if _resolve(layer, base)[0] != &"":
			return true
	return false


## Drives every layer from one call, which is what keeps them in lockstep: they
## are started in the same frame with the same animation name and the same
## restart flag, so no layer can drift a frame behind another.
func _play(base: StringName, restart: bool = false) -> void:
	if _instant():
		return
	# A pose no layer has ANY art for falls through to IDLE rather than being
	# asked for as-is. Without this, a single-layer character missing (say)
	# `downed` entirely does not just skip the pose — every layer resolves to
	# nothing and the whole character goes invisible for as long as the pose
	# is on screen, which for DOWNED is forever. This only catches the total
	# loss: a pose that IS drawn for at least one layer still hides the
	# layers that lack it individually below, which is a deliberate look (a
	# downed body correctly loses its helmet) rather than a gap to paper over.
	var effective_base := base if base == IDLE or _has_any(base) else IDLE
	for layer in layers:
		var sprite: AnimatedSprite3D = _sprites.get(layer)
		if sprite == null:
			continue
		var resolved := _resolve(layer, effective_base)
		var name: StringName = resolved[0]
		if name == &"":
			sprite.visible = false  # this layer has nothing to show for this pose
			continue
		sprite.visible = true
		sprite.flip_h = resolved[1]
		if restart or sprite.animation != name:
			sprite.play(name)
			if restart:
				sprite.set_frame_and_progress(0, 0.0)


func _await_animation(base: StringName) -> void:
	# Waited on ONE layer — whichever has art for this pose. Every layer was
	# started in the same frame with the same length, so one finishing is all of
	# them finishing.
	for layer in layers:
		var name: StringName = _resolve(layer, base)[0]
		if name == &"":
			continue
		var sprite: AnimatedSprite3D = _sprites[layer]
		while sprite.is_playing() and sprite.animation == name:
			await sprite.animation_finished
		return


# --- Lighting ----------------------------------------------------------------


## Tints every layer by the light on the unit's own tile. This is the sprite
## equivalent of being lit, and it is deliberately driven from the same
## light_value that Combat.light_modifier and alien detection read: a unit that
## looks dark must be one the rules also treat as dark.
func _apply_tile_light() -> void:
	if _unit == null:
		return
	var tile: GridTileData = GridManager.get_tile(_unit.get("grid_pos"))
	var lit := clampf(tile.light_value / 100.0, 0.0, 1.0) if tile else 1.0
	var level := lerpf(MIN_TINT, 1.0, lit)
	var tint := Color(level, level, level) * faction_tint
	for layer in layers:
		var sprite: AnimatedSprite3D = _sprites.get(layer)
		if sprite:
			sprite.modulate = _status_color if layer in SELF_LIT_LAYERS else tint


## Recolours the self-lit `status` layer. The security robots' one concession to
## readability: a machine's posture cannot be read off its body language the way
## an alien's can, so the state is a colour instead. A no-op for a character with
## no status layer, which is every character that is not a robot.
func set_status_color(color: Color) -> void:
	_status_color = color
	var sprite: AnimatedSprite3D = _sprites.get(&"status")
	if sprite:
		sprite.modulate = color


# --- Idle behaviour ----------------------------------------------------------


func _footstep_loop() -> void:
	_stepping = true
	await get_tree().create_timer(FOOTSTEP_OFFSET).timeout
	while _stance == RUN and is_inside_tree():
		footstep.emit()
		await get_tree().create_timer(FOOTSTEP_GAP).timeout
	_stepping = false


func _maybe_start_fidget() -> void:
	# Silently does nothing for a character with no fidget art. Same shape as
	# everything else here: the code is written once and the art decides whether
	# it applies.
	if _instant() or _fidgeting or not _has_any(IDLE_FIDGET):
		return
	_fidget_loop()  # deliberately not awaited: runs until the stance leaves IDLE


func _fidget_loop() -> void:
	## Slips an idle variation in at random intervals. Not awaited by anything —
	## a fidget is scenery, and no game state may ever depend on one.
	##
	## Played directly rather than through play_action, and that is the whole
	## design. play_action sets `_action`, which makes set_stance record-but-not-
	## play until the one-shot finishes — correct for a reload, disastrous here,
	## because IDLE is the default stance and a long fidget would routinely be in
	## flight when a move order arrives. The unit would then slide to its
	## destination still convulsing. Leaving `_action` empty means any real stance
	## change cuts the fidget off mid-frame and wins, which is exactly the
	## priority a decoration should have.
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
		await _await_animation(IDLE_FIDGET)
		if is_inside_tree() and _stance == IDLE and _action == &"":
			_play(IDLE)
	_fidgeting = false


# --- Placeholder art ---------------------------------------------------------
#
# Drawn in code rather than shipped as PNGs, so there are no stand-in assets to
# mistake for real ones later and nothing to delete when the art lands. Every
# pose and direction the game asks for exists, which means the whole system —
# layering, bucketing, mirroring, gear swap, lockstep playback — is exercisable
# now, and dropping real SpriteFrames into assets/sprites/ replaces it silently.


## Base colour per layer, so the four are told apart at a glance.
const PLACEHOLDER_COLOR := {
	&"body": Color(0.32, 0.36, 0.30),
	&"head": Color(0.78, 0.62, 0.50),
	&"helmet": Color(0.22, 0.25, 0.28),
	&"weapon": Color(0.15, 0.15, 0.17),
	&"status": Color(1.0, 1.0, 1.0),  # tinted per alert state; see set_status_color
}

## Machine-style overrides. Cold greys against the organic set's warmer, dirtier
## palette, so faction reads off colour as well as off shape.
const PLACEHOLDER_MACHINE_COLOR := {
	&"body": Color(0.40, 0.44, 0.50),
	&"head": Color(0.20, 0.22, 0.26),
	&"weapon": Color(0.14, 0.15, 0.18),
}

## Per-variant silhouette for the machine style, in canvas pixels. Four robots
## that differ only in colour would be four of the same unit as far as a player
## glancing at a dark corridor is concerned, so each gets a proportion it owns:
## a squat armored post, a wide heavy weapons platform, a small hovering drone,
## and something a head taller than a soldier.
##
##   width/height — chassis box
##   hover        — pixels of clear air under it, so the drone reads as flying
##   head         — sensor housing edge; 0 draws none
##   shoulder     — width of the plate that swings with facing, 0 draws none
const PLACEHOLDER_MACHINE_SPEC := {
	&"auxilium": {"width": 20, "height": 26, "hover": 0, "head": 9, "shoulder": 5},
	&"sagittarii": {"width": 28, "height": 30, "hover": 0, "head": 8, "shoulder": 8},
	&"proctor": {"width": 14, "height": 14, "hover": 20, "head": 6, "shoulder": 0},
	&"securus": {"width": 24, "height": 42, "hover": 0, "head": 12, "shoulder": 7},
}
const PLACEHOLDER_MACHINE_DEFAULT := {"width": 20, "height": 28, "hover": 0, "head": 9, "shoulder": 5}
## Poses the placeholder draws crouched rather than standing, so overwatch is
## visibly different from standing there.
const PLACEHOLDER_CROUCHED := [OVERWATCH]
## Every pose the placeholder generates art for — the full vocabulary above, so
## no caller can ask for something that does not exist.
const PLACEHOLDER_POSES := [
	IDLE, RUN, WALK, OVERWATCH, AIM_HOLD,
	BEGIN_SHOOT, FIRE_SHOOT, END_SHOOT, RUN_STOP,
	MELEE, RELOAD, GRENADE, INTERACT,
	HIT_REACT, DOWNED, ALERT_SCREAM, IDLE_FIDGET,
]


func _placeholder_frames(layer: StringName) -> SpriteFrames:
	var frames := SpriteFrames.new()
	frames.remove_animation(&"default")
	for pose: StringName in PLACEHOLDER_POSES:
		# Only the five DRAWN directions — the mirror table supplies nw, w and sw
		# — so that table is genuinely exercised rather than bypassed by
		# generating all eight.
		for dir: StringName in [&"n", &"ne", &"e", &"se", &"s"]:
			var name := &"%s_%s" % [pose, dir]
			frames.add_animation(name)
			frames.set_animation_loop(name, pose in [IDLE, RUN, WALK, OVERWATCH, AIM_HOLD])
			frames.add_frame(name, _placeholder_texture(layer, pose, dir))
	return frames


func _placeholder_texture(layer: StringName, pose: StringName, dir: StringName) -> ImageTexture:
	var image := Image.create(CANVAS, CANVAS, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	var color: Color = PLACEHOLDER_COLOR.get(layer, Color(0.6, 0.6, 0.6))
	var prone := pose == DOWNED
	var crouched := pose in PLACEHOLDER_CROUCHED
	# How far the art leans toward the viewer, so the eight buckets are told apart
	# without reading a label: -1 is facing away, +1 is facing the camera.
	var lean: float = {&"n": -1.0, &"ne": -0.5, &"e": 0.0, &"se": 0.5, &"s": 1.0}.get(dir, 0.0)
	# Screen-right component, so a weapon sits on the correct side of the body.
	var side: float = {&"n": 0.0, &"ne": 0.7, &"e": 1.0, &"se": 0.7, &"s": 0.0}.get(dir, 0.0)

	if placeholder_style == &"machine":
		_draw_machine(image, layer, prone, crouched, lean, side)
		return ImageTexture.create_from_image(image)

	var floor_y := CANVAS - 2
	var height := 22 if crouched else 38
	if prone:
		# Flat on the deck: a downed unit must not read as a standing one.
		_box(image, 14, floor_y - 8, 36, 7, color)
		return ImageTexture.create_from_image(image)

	match layer:
		&"body":
			_box(image, CANVAS / 2 - 8, floor_y - height, 16, height, color)
			# A lighter front panel, offset toward the viewer: the fastest read of
			# which way a featureless block is facing.
			if lean > 0.0:
				_box(image, CANVAS / 2 - 6, floor_y - height + 4, 12, 10,
					color.lightened(0.35))
		&"head":
			_disc(image, CANVAS / 2 + int(side * 2.0), floor_y - height - 6, 6, color)
		&"helmet":
			_disc(image, CANVAS / 2 + int(side * 2.0), floor_y - height - 8, 7,
				color.darkened(0.1))
			# Visor, drawn only when the face is toward the camera.
			if lean > 0.0:
				_box(image, CANVAS / 2 - 4 + int(side * 2.0), floor_y - height - 7, 8, 3,
					Color(0.85, 0.2, 0.18))
		&"weapon":
			var x := CANVAS / 2 + int(side * 9.0) - 2
			_box(image, x, floor_y - height + 8, 4, 16, color)
	return ImageTexture.create_from_image(image)


## The machine silhouette. Everything here is a rectangle, and that is the point:
## the faction is specified as "built, not grown", so the stand-in has no discs,
## no taper and no rounded anything, and reads as the opposite of the alien
## placeholder even at the size a character occupies on screen.
func _draw_machine(image: Image, layer: StringName, prone: bool, crouched: bool,
		lean: float, side: float) -> void:
	var color: Color = PLACEHOLDER_MACHINE_COLOR.get(layer, PLACEHOLDER_COLOR.get(layer, Color(0.6, 0.6, 0.6)))
	var spec: Dictionary = PLACEHOLDER_MACHINE_SPEC.get(variant, PLACEHOLDER_MACHINE_DEFAULT)
	var floor_y := CANVAS - 2
	var width: int = spec["width"]
	var height: int = spec["height"]
	var hover: int = spec["hover"]

	if prone:
		# A wreck, not a body: wider than it is tall and flat on the deck, with no
		# hover left in whatever used to be flying.
		if layer == &"body":
			_box(image, CANVAS / 2 - width / 2 - 4, floor_y - 8, width + 8, 8, color.darkened(0.35))
		return

	# Crouching is a machine lowering itself onto its mounts rather than a body
	# folding, so it loses height and keeps its width.
	if crouched:
		height = maxi(10, height - 10)
	var top := floor_y - hover - height
	var cx := CANVAS / 2

	match layer:
		&"body":
			_box(image, cx - width / 2, top, width, height, color)
			# Plate that swings with facing — the fastest read of which way a box
			# is pointing, and the machine equivalent of the organic front panel.
			var shoulder: int = spec["shoulder"]
			if shoulder > 0:
				_box(image, cx - shoulder / 2 + int(side * (width / 2.0 - shoulder / 2.0)),
					top + 2, shoulder, height - 4, color.darkened(0.3))
			if lean > 0.0:
				_box(image, cx - width / 2 + 3, top + 3, width - 6, 6, color.lightened(0.25))
			if hover > 0:
				# Thruster wash under a hovering chassis, so it does not read as a
				# box someone left floating by mistake.
				_box(image, cx - 3, floor_y - hover + 2, 6, 3, color.darkened(0.5))
		&"head":
			var head: int = spec["head"]
			if head <= 0:
				return
			_box(image, cx - head / 2 + int(side * 2.0), top - head, head, head, color)
			# Sensor band, only when the face is toward the camera.
			if lean > 0.0:
				_box(image, cx - head / 2 + 1 + int(side * 2.0), top - head + 2, head - 2, 2,
					Color(0.9, 0.25, 0.2))
		&"weapon":
			# A barrel on the swinging side, longer and thinner than the soldier's
			# rifle block so it reads as mounted hardware rather than carried.
			var x := cx + int(side * (width / 2.0 + 1.0)) - 2
			_box(image, x, top + 4, 4, 18, color)
		&"status":
			# White here and tinted by set_status_color, so one drawn frame serves
			# every alert state. Two pips: one on the chest and one on the spine,
			# because a robot's state has to be readable from behind as well.
			_box(image, cx - 2 + int(side * 3.0), top + (4 if lean > 0.0 else 6), 4, 4, color)
			if lean <= 0.0:
				_box(image, cx - 1, top - 2, 3, 3, color)


func _box(image: Image, x: int, y: int, w: int, h: int, color: Color) -> void:
	for py in range(maxi(y, 0), mini(y + h, CANVAS)):
		for px in range(maxi(x, 0), mini(x + w, CANVAS)):
			image.set_pixel(px, py, color)


func _disc(image: Image, cx: int, cy: int, r: int, color: Color) -> void:
	for py in range(maxi(cy - r, 0), mini(cy + r + 1, CANVAS)):
		for px in range(maxi(cx - r, 0), mini(cx + r + 1, CANVAS)):
			if Vector2(px - cx, py - cy).length() <= float(r):
				image.set_pixel(px, py, color)
