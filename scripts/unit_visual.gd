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
## Short moves walk. See WALK_SPEED and Unit.move_along for when.
const WALK := &"walk"
const CROUCH := &"crouch_idle"
const OVERWATCH := &"overwatch_hold"

# Firing is two animations driven by play_burst rather than one per shot type:
# the burst length is rolled per shot, and no fixed animation can match a count
# it does not know. AIM_HOLD is the weapon up and steady either side of the
# burst; SHOOT_RECOIL is one round's kick, replayed from the start once per round.
const AIM_HOLD := &"aim_hold"
const SHOOT_RECOIL := &"shoot_recoil"
# Transitions. Not stances and not actions: each is a one-shot bridging one
# stance into another, played through play_stance_exit. All degrade to a hard
# cut, at zero time cost, when the art is absent.
const RUN_STOP := &"run_stop"
const STAND_TO_CROUCH := &"stand_to_crouch"
const CROUCH_TO_STAND := &"crouch_to_stand"
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

# Frames where each boot lands during the run cycle, evenly spaced half a cycle
# apart. Carried over from the measured Mixamo run: the cadence is a property of
# a soldier moving at 4.5 m/s, not of how the character is drawn, so the sprite
# walk cycle is authored to match these rather than the other way round.
const FOOTSTEP_OFFSET := 0.10
const FOOTSTEP_GAP := 0.333

# Seconds of plain idle between attempts at an IDLE_FIDGET. Rolled fresh each
# time rather than fixed, which matters most with several units on screen: a
# constant gap would have a nest of swarm units convulsing in lockstep, and
# nothing reads as scripted faster than that.
const FIDGET_GAP_MIN := 12.0
const FIDGET_GAP_MAX := 35.0

## Stand-in durations, so action pacing is identical with or without authored
## art. These are the SOLDIER's measured clip lengths from the 3D pipeline that
## preceded the sprites — kept because they are what the game's turn rhythm was
## tuned against, and a sprite reload has no more reason to take a different
## length than a mocap one did.
const FALLBACK_TIME := {
	MELEE: 1.20,
	RELOAD: 1.20,
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
const RAISE_TIME := 0.18
const BURST_CADENCE := 0.11
const SETTLE_TIME := 0.20

## Metres per second for the WALK stance, replacing Unit.move_speed on the moves
## that take it. Inherited from the measured Walking clip.
const WALK_SPEED := 1.02

# --- Direction ---------------------------------------------------------------
#
# Sprite direction is the unit's yaw MINUS the camera's, quantised into eight
# 45-degree buckets. Subtracting the camera is what makes this work under a rig
# whose yaw snaps: a quarter turn moves every bucket by exactly two steps, so the
# snap costs no additional art — but it DOES change every character's apparent
# facing without any unit having turned, which is why _sync_direction is driven
# off the rig's yaw_changed signal as well as off unit facing.

## Screen-space directions, indexed by bucket. Bucket 0 is a unit facing directly
## away from the camera, and the index rises with yaw — which, given Godot's -Z
## forward and +X screen-right, runs anticlockwise on screen.
const DIRECTIONS: Array[StringName] = [&"n", &"nw", &"w", &"sw", &"s", &"se", &"e", &"ne"]

## The 5-drawn + 3-mirrored rule. Only the five right-facing directions are
## authored; the left-facing three are those flipped horizontally. Entries are
## [source direction, flip_h].
##
## A pose that is NOT symmetric — anything armed, where flipping moves the rifle
## to the wrong shoulder — can be authored for all eight instead: if the sprite
## set contains art for the mirrored direction itself, _sync_direction uses it
## unflipped and this table never applies.
const MIRROR := {
	&"nw": [&"ne", true],
	&"w": [&"e", true],
	&"sw": [&"se", true],
}

## Layers, back to front. Data-driven rather than four hardcoded nodes so an arm
## layer (or anything else) can be added in art alone.
@export var layers: Array[StringName] = [&"body", &"head", &"helmet", &"weapon"]

## Art variant, and the directory the `SpriteFrames` are looked up in. Gear swaps
## are a reassignment of this — see `set_variant`.
@export var variant: StringName = &"soldier"

## Metres per source pixel. Shared by every layer, along with `offset`, because
## the layers only stay registered with one another if they agree on both.
@export var pixel_size: float = 0.03

## Whether this character carries the rig-mounted light (Sec 5.2). Aliens do not.
@export var has_light: bool = true

# --- Placeholder art ---------------------------------------------------------

## Source canvas, in pixels. Square so a rotation of the art never changes the
## pivot, and 64 so pixel_size 0.03 puts a standing character at 1.92 m.
const CANVAS := 64
## Where the art's origin sits in the canvas: the FEET, not the centre. Every
## layer shares it, which is what keeps a helmet on a head across a gear swap.
const FOOT_ANCHOR := Vector2(0.5, 1.0)

## Darkest a sprite is allowed to get. Sprites are UNSHADED and tinted from the
## tile's light_value instead of being lit, so this is the floor of that tint:
## far enough down to read as "in the dark", not so far the unit is lost.
const MIN_TINT := 0.35

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

var _sprites: Dictionary = {}  # layer StringName -> AnimatedSprite3D
var _frames: Dictionary = {}  # layer StringName -> SpriteFrames
var _light: SpotLight3D = null
var _light_mount: Marker3D = null
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


func _ready() -> void:
	# Children are ready before their parent, so Unit._ready can rely on these.
	_unit = get_parent() as Node3D
	_build_layers()
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
		sprite.pixel_size = pixel_size
		# Every layer shares pixel_size and offset, which IS the pivot contract:
		# reassigning one layer's frames can never shift it against the others.
		sprite.offset = Vector2(0.0, CANVAS * FOOT_ANCHOR.y - CANVAS * 0.5)
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
		add_child(sprite)
		_sprites[layer] = sprite


## Authored art for one layer, or null while none exists. The naming convention is
## `[part]_[variant]_[animation]_[direction]_[frame].png` under assets/sprites,
## collected into one SpriteFrames per part+variant.
func _load_frames(layer: StringName) -> SpriteFrames:
	var path := "res://assets/sprites/%s_%s.tres" % [layer, variant]
	if not ResourceLoader.exists(path):
		return null
	return load(path) as SpriteFrames


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
		(_sprites[layer] as AnimatedSprite3D).sprite_frames = frames
	_play(_stance)


func _build_light() -> void:
	# A fixed offset on the unit, not a bone mount. Position follows this node and
	# orientation follows the unit — see aimed_light.gd for why those must differ.
	_light_mount = Marker3D.new()
	_light_mount.name = "LightMount"
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
	_light.light_volumetric_fog_energy = 3.0
	_light.shadow_enabled = true
	_light.shadow_blur = 0.6
	_light.spot_range = 9.0
	# Matches LightingManager.FLASHLIGHT_CONE_DEGREES (90, so half-angle 45):
	# what you see lit is what the unit can actually see by.
	_light.spot_angle = 45.0
	_light.spot_attenuation = 1.5
	_light.spot_angle_attenuation = 2.5
	add_child(_light)

	var beam := MeshInstance3D.new()
	beam.name = "Beam"
	beam.set_script(load("res://scripts/flashlight_beam.gd"))
	_light.add_child(beam)


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
	return wrapi(roundi(relative_yaw / (TAU / DIRECTIONS.size())), 0, DIRECTIONS.size())


func _bucket(relative_yaw: float) -> int:
	return direction_bucket(relative_yaw)


## The animation name and flip for `base` in the current direction, resolving the
## 5-drawn + 3-mirrored rule. Returns [name, flip_h].
func _resolve(layer: StringName, base: StringName) -> Array:
	var frames: SpriteFrames = _frames[layer]
	var dir: StringName = DIRECTIONS[_direction]
	var direct := &"%s_%s" % [base, dir]
	# An asymmetric pose authored for all eight wins over the mirror table.
	if frames.has_animation(direct):
		return [direct, false]
	if MIRROR.has(dir):
		var m: Array = MIRROR[dir]
		var mirrored := &"%s_%s" % [base, m[0]]
		if frames.has_animation(mirrored):
			return [mirrored, m[1]]
	return [&"", false]


# --- Playback ----------------------------------------------------------------


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


## Whether this character can walk a short move rather than run it. False for
## anything with no walk art, which keeps those units on the single gait they
## have.
func has_walk() -> bool:
	return not _instant() and _has_any(WALK)


func play_burst(rounds: int) -> void:
	# Coroutine — callers MUST await. Weapon comes up, fires `rounds` rounds on a
	# fixed cadence, holds, then hands back to the stance. One `muzzle` per round.
	if _instant():
		for _i in rounds:
			muzzle.emit()
		return
	_action = SHOOT_RECOIL
	_play(AIM_HOLD)
	await get_tree().create_timer(RAISE_TIME).timeout
	for _i in rounds:
		# Restarted from frame 0 rather than merely played: play() on the
		# animation already running is a no-op, so every round after the first
		# would silently skip its kick.
		_play(SHOOT_RECOIL, true)
		muzzle.emit()
		await get_tree().create_timer(BURST_CADENCE).timeout
	_play(AIM_HOLD)
	await get_tree().create_timer(SETTLE_TIME).timeout
	_action = &""
	_play(_stance)


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
	for layer in layers:
		var sprite: AnimatedSprite3D = _sprites.get(layer)
		if sprite == null:
			continue
		var resolved := _resolve(layer, base)
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
	var tint := Color(level, level, level)
	for layer in layers:
		var sprite: AnimatedSprite3D = _sprites.get(layer)
		if sprite:
			sprite.modulate = tint


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
}
## Poses the placeholder draws crouched rather than standing, so hunkering and
## overwatch are visibly different from standing there.
const PLACEHOLDER_CROUCHED := [CROUCH, STAND_TO_CROUCH, CROUCH_TO_STAND, OVERWATCH]
## Every pose the placeholder generates art for — the full vocabulary above, so
## no caller can ask for something that does not exist.
const PLACEHOLDER_POSES := [
	IDLE, RUN, WALK, CROUCH, OVERWATCH, AIM_HOLD, SHOOT_RECOIL, RUN_STOP,
	STAND_TO_CROUCH, CROUCH_TO_STAND, MELEE, RELOAD, GRENADE, INTERACT,
	HIT_REACT, DOWNED, ALERT_SCREAM, IDLE_FIDGET,
]


func _placeholder_frames(layer: StringName) -> SpriteFrames:
	var frames := SpriteFrames.new()
	frames.remove_animation(&"default")
	for pose: StringName in PLACEHOLDER_POSES:
		# Only the five authored directions, so the mirror table is genuinely
		# exercised rather than bypassed by drawing all eight.
		for dir: StringName in [&"n", &"ne", &"e", &"se", &"s"]:
			var name := &"%s_%s" % [pose, dir]
			frames.add_animation(name)
			frames.set_animation_loop(name, pose in [IDLE, RUN, WALK, CROUCH, OVERWATCH, AIM_HOLD])
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


func _box(image: Image, x: int, y: int, w: int, h: int, color: Color) -> void:
	for py in range(maxi(y, 0), mini(y + h, CANVAS)):
		for px in range(maxi(x, 0), mini(x + w, CANVAS)):
			image.set_pixel(px, py, color)


func _disc(image: Image, cx: int, cy: int, r: int, color: Color) -> void:
	for py in range(maxi(cy - r, 0), mini(cy + r + 1, CANVAS)):
		for px in range(maxi(cx - r, 0), mini(cx + r + 1, CANVAS)):
			if Vector2(px - cx, py - cy).length() <= float(r):
				image.set_pixel(px, py, color)
