extends Node3D
## Isometric camera rig: fixed orthographic projection at a fixed pitch. The yaw
## has two modes, toggled with L:
##   * free (default): any angle. Holding Q/E spins smoothly, and middle-mouse
##     drag orbits — horizontal drag turns the yaw, vertical drag raises or
##     lowers the camera (pitch, clamped to MIN_PITCH..MAX_PITCH).
##   * locked: snapped to one of four quarter turns at the true-isometric
##     PITCH, Q/E step between them. Switching to locked eases to the nearest
##     quarter turn and back to PITCH.
## WASD pans, scroll wheel zooms, in both modes.
##
## Locked mode keeps the one authored angle that pre-rendered sprite art is
## drawn against. What the free-orbit camera used to solve — a bulkhead
## standing between the player and the room — is MapBuilder's wall occlusion
## pass.
##
## Zoom (Camera3D.size) does have input, within a fixed range: MIN_ZOOM_SIZE is
## the one-true-scale the sprite renderer authors against (see camera_rig.tscn
## and render_sprites.py's GAME_CAMERA_SIZE), MAX_ZOOM_SIZE is picked so scrolling
## all the way out fits a full room like maps/merc_duel_deck.txt (30x16 tiles) on
## screen at once. Sprites are pre-rendered images, not tile-scale pixel art, so
## scaling them down for the wider view just softens them a little — no LOD or
## re-render needed.

## Emitted whenever the yaw changes, including every frame of a snap tween.
## Sprite direction is the unit's yaw MINUS this one, so a snap re-buckets every
## character on screen even though nothing turned. Polling that per sprite would
## work; a signal keeps the knowledge in one place.
signal yaw_changed(yaw: float)

## True isometric: atan(1/sqrt(2)). At this pitch a tile's world-space square
## projects to a 2:1 diamond, which is the proportion the sprite art is drawn
## against — so this is an authoring contract, not a preference.
const PITCH := atan(1.0 / sqrt(2.0))
const START_YAW := deg_to_rad(45.0)

## Quarter turns, so the eight sprite direction buckets shift by exactly two
## steps per snap and no additional art is needed to cover the new angles.
const SNAP_STEP := PI / 2.0
## Tweened rather than cut so the player keeps their bearings across a snap.
const SNAP_TIME := 0.25

## Free mode: radians per second while Q/E is held, and radians per screen
## pixel of middle-mouse drag.
const FREE_ROTATE_SPEED := deg_to_rad(120.0)
const DRAG_ROTATE_SENSITIVITY := 0.008
## Free mode pitch range for vertical middle-mouse drag (degrees above the
## horizontal). The floor keeps the camera well above the horizontal so
## MapBuilder's wall lamps (beams that never rise) still can't point at it;
## the ceiling stops short of straight down so yaw stays meaningful.
const MIN_PITCH := deg_to_rad(20.0)
const MAX_PITCH := deg_to_rad(75.0)

const PAN_SPEED := 12.0

## The sprite-authoring scale (see camera_rig.tscn) — the closest the player
## can scroll in, and where the camera starts.
const MIN_ZOOM_SIZE := 10.5
## Fits maps/merc_duel_deck.txt (30x16 tiles, walls included) on screen at
## once at a 16:9-or-wider aspect. Derived from the rig's fixed pitch — the
## diamond is the same at every one of the four snapped yaws, so SNAP_STEP does
## not enter it: an
## isometric view's visible ground diamond has width:height = sqrt(3):1, so
## the binding constraint is height. For that room (45m x 24m), the diamond's
## screen height comes out to ~28.2 world units; a little headroom rounds it
## up to 30 so the wall ring isn't clipped exactly at the edge.
const MAX_ZOOM_SIZE := 30.0
## World units of Camera3D.size per scroll notch.
const ZOOM_STEP := 1.5
## Camera3D.size units per second the live size closes toward _zoom_target.
## Scrolling nudges the target rather than the live size directly, so a burst
## of notches reads as one continuous motion instead of a jump per tick.
const ZOOM_SMOOTH := 10.0

var _snap_tween: Tween = null
var _snap_target := START_YAW
var _last_yaw := INF
var _zoom_target := MIN_ZOOM_SIZE
## False: quarter-turn snaps. True: continuous yaw and pitch. Toggled by L.
var free_rotation := true
var _dragging := false

@onready var _camera: Camera3D = $Camera3D


func _ready() -> void:
	# Every UnitVisual finds the rig through this group to derive its sprite
	# direction, and there is exactly one rig.
	add_to_group("camera_rig")
	rotation = Vector3(-PITCH, START_YAW, 0.0)
	_zoom_target = _camera.size
	_make_audio_listener()


## Positional audio listens from the RIG PIVOT, not from the Camera3D.
##
## Godot defaults the listener to the current Camera3D, which is wrong here in a
## way that is specific to this rig being orthographic. The camera sits 18 m back
## along local +Z (see camera_rig.tscn) purely to keep geometry off the near
## plane, and zoom is driven by `Camera3D.size` rather than by moving it — so the
## camera's distance to the action is a constant 18 m that NEVER CHANGES, however
## far in the player scrolls. Every sound would sit at the same attenuated
## distance forever, and scrolling in on a firefight would not bring it closer.
##
## The pivot is the point the rig is focused on, on the deck. Listening from
## there gives distance falloff that tracks what the player is actually looking
## at, and left/right panning that matches the framing.
func _make_audio_listener() -> void:
	var listener := AudioListener3D.new()
	add_child(listener)
	listener.make_current()


## Drag motion and release go through _input, not _unhandled_input: once a
## drag has started, the cursor crossing a HUD control must neither stall the
## rotation nor swallow the release and leave the drag stuck on.
func _input(event: InputEvent) -> void:
	if not _dragging:
		return
	if event is InputEventMouseMotion:
		# Grab-the-deck feel: dragging right pulls the near side of the deck right.
		rotation.y -= event.relative.x * DRAG_ROTATE_SENSITIVITY
		# Dragging up raises the camera toward top-down; down lowers it.
		var pitch := clampf(-rotation.x - event.relative.y * DRAG_ROTATE_SENSITIVITY,
				MIN_PITCH, MAX_PITCH)
		rotation.x = -pitch
	elif event.is_action_released("camera_rotate_drag"):
		_dragging = false


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("camera_toggle_free_rotation"):
		set_free_rotation(not free_rotation)
	# Discrete presses, not held-key polling: a snap is a step, and holding Q
	# should not spin the deck. In free mode Q/E are polled in _process instead.
	elif not free_rotation and event.is_action_pressed("camera_snap_left"):
		snap_by(-1)
	elif not free_rotation and event.is_action_pressed("camera_snap_right"):
		snap_by(1)
	elif free_rotation and event.is_action_pressed("camera_rotate_drag"):
		_dragging = true
	elif event.is_action_pressed("camera_zoom_in"):
		_zoom_target = maxf(MIN_ZOOM_SIZE, _zoom_target - ZOOM_STEP)
	elif event.is_action_pressed("camera_zoom_out"):
		_zoom_target = minf(MAX_ZOOM_SIZE, _zoom_target + ZOOM_STEP)


## Turns `steps` quarter turns from wherever the current snap is heading.
## Stepping from the TARGET rather than the live rotation is what makes a
## double-tap mid-tween land two quarters round instead of one and a bit.
func snap_by(steps: int) -> void:
	_snap_target += steps * SNAP_STEP
	_tween_to_snap_target()


## Switches between quarter-turn snapping and continuous yaw/pitch. Leaving
## free mode eases to the quarter turn nearest the live yaw and back to the
## isometric PITCH, so the deck settles onto one of the four authored angles.
func set_free_rotation(enabled: bool) -> void:
	if enabled == free_rotation:
		return
	free_rotation = enabled
	_dragging = false
	if enabled:
		# Hand the live yaw over as-is: a snap still in flight stops where it is.
		if _snap_tween:
			_snap_tween.kill()
			_snap_tween = null
		return
	_snap_target = START_YAW + roundf((rotation.y - START_YAW) / SNAP_STEP) * SNAP_STEP
	_tween_to_snap_target()


func _tween_to_snap_target() -> void:
	if _snap_tween:
		_snap_tween.kill()
	# Snapped instantly with no display: the headless smoke test has no frames to
	# tween across, and nothing in the rules depends on the camera.
	if DisplayServer.get_name() == "headless":
		rotation.y = _snap_target
		if not free_rotation:
			rotation.x = -PITCH
		return
	_snap_tween = create_tween().set_parallel()
	_snap_tween.tween_property(self, "rotation:y", _snap_target, SNAP_TIME) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	# Locked mode always sits at the authored pitch; a free-mode snap_by call
	# (screenshot tooling) keeps whatever pitch the player chose.
	if not free_rotation:
		_snap_tween.tween_property(self, "rotation:x", -PITCH, SNAP_TIME) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)


func _process(delta: float) -> void:
	# One float compare per frame while the camera holds still. Emitted from here
	# rather than from the tween so ANY change to the yaw is announced, including
	# the instant headless snap above.
	if rotation.y != _last_yaw:
		_last_yaw = rotation.y
		yaw_changed.emit(rotation.y)

	if free_rotation:
		var spin := Input.get_axis("camera_snap_left", "camera_snap_right")
		if spin != 0.0:
			# Same sign as snap_by: Q (left) lowers the yaw, E raises it.
			rotation.y += spin * FREE_ROTATE_SPEED * delta

	if _camera.size != _zoom_target:
		_camera.size = move_toward(_camera.size, _zoom_target, ZOOM_SMOOTH * delta)

	var pan := Vector2.ZERO
	if Input.is_action_pressed("camera_pan_up"):
		pan.y -= 1
	if Input.is_action_pressed("camera_pan_down"):
		pan.y += 1
	if Input.is_action_pressed("camera_pan_left"):
		pan.x -= 1
	if Input.is_action_pressed("camera_pan_right"):
		pan.x += 1
	if pan != Vector2.ZERO:
		# Basis recomputed from the live yaw every frame, so pan stays
		# camera-relative across a snap without the snap having to know about it.
		var forward := Vector3(-sin(rotation.y), 0, -cos(rotation.y))
		var right := Vector3(cos(rotation.y), 0, -sin(rotation.y))
		global_position += (right * pan.x + forward * -pan.y) * PAN_SPEED * delta


func focus_on(world_pos: Vector3) -> void:
	global_position = Vector3(world_pos.x, global_position.y, world_pos.z)
