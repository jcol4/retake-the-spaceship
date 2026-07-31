extends Node3D
## Isometric camera rig: fixed orthographic projection at a fixed pitch, with the
## yaw snapped to one of four quarter turns. Q/E step between them, WASD pans.
##
## Pitch and zoom both have no input at all. That is the point of the migration:
## the deck is drawn at one angle and one scale, so hand-drawn sprite art only
## ever has to be authored for that angle and that scale. What the free-orbit
## camera used to solve — a bulkhead standing between the player and the room —
## is now MapBuilder's wall occlusion pass instead.

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

const PAN_SPEED := 12.0

var _snap_tween: Tween = null
var _snap_target := START_YAW
var _last_yaw := INF


func _ready() -> void:
	# Every UnitVisual finds the rig through this group to derive its sprite
	# direction, and there is exactly one rig.
	add_to_group("camera_rig")
	rotation = Vector3(-PITCH, START_YAW, 0.0)


func _unhandled_input(event: InputEvent) -> void:
	# Discrete presses, not held-key polling: a snap is a step, and holding Q
	# should not spin the deck.
	if event.is_action_pressed("camera_snap_left"):
		snap_by(1)
	elif event.is_action_pressed("camera_snap_right"):
		snap_by(-1)


## Turns `steps` quarter turns from wherever the current snap is heading.
## Stepping from the TARGET rather than the live rotation is what makes a
## double-tap mid-tween land two quarters round instead of one and a bit.
func snap_by(steps: int) -> void:
	_snap_target += steps * SNAP_STEP
	if _snap_tween:
		_snap_tween.kill()
	# Snapped instantly with no display: the headless smoke test has no frames to
	# tween across, and nothing in the rules depends on the camera.
	if DisplayServer.get_name() == "headless":
		rotation.y = _snap_target
		return
	_snap_tween = create_tween()
	_snap_tween.tween_property(self, "rotation:y", _snap_target, SNAP_TIME) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)


func _process(delta: float) -> void:
	# One float compare per frame while the camera holds still. Emitted from here
	# rather than from the tween so ANY change to the yaw is announced, including
	# the instant headless snap above.
	if rotation.y != _last_yaw:
		_last_yaw = rotation.y
		yaw_changed.emit(rotation.y)

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
