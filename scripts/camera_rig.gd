extends Node3D
## Orbit camera rig: pivot rotates on middle-mouse drag or Q/E, WASD pans,
## wheel zooms. Pitch clamped 35-75 degrees from horizontal (Sec 10.2),
## bird's-eye default.

const PITCH_MIN := deg_to_rad(35.0)
const PITCH_MAX := deg_to_rad(75.0)
const ORBIT_SPEED := 0.01
const KEY_ORBIT_SPEED := deg_to_rad(90.0)  # radians/second while Q or E is held
const PAN_SPEED := 12.0
const ZOOM_STEP := 1.5
const ZOOM_MIN := 5.0
const ZOOM_MAX := 30.0

@onready var arm: SpringArm3D = $SpringArm3D

var _orbiting := false


func _ready() -> void:
	rotation.x = -deg_to_rad(65.0)  # bird's-eye on load


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			_orbiting = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			arm.spring_length = clampf(arm.spring_length - ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			arm.spring_length = clampf(arm.spring_length + ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)
	elif event is InputEventMouseMotion and _orbiting:
		rotation.y -= event.relative.x * ORBIT_SPEED
		rotation.x = clampf(rotation.x - event.relative.y * ORBIT_SPEED, -PITCH_MAX, -PITCH_MIN)


func _process(delta: float) -> void:
	var orbit := 0.0
	if Input.is_action_pressed("camera_orbit_left"):
		orbit += 1.0
	if Input.is_action_pressed("camera_orbit_right"):
		orbit -= 1.0
	if orbit != 0.0:
		# Same sign convention as a left/right middle-mouse drag.
		rotation.y += orbit * KEY_ORBIT_SPEED * delta

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
		var forward := Vector3(-sin(rotation.y), 0, -cos(rotation.y))
		var right := Vector3(cos(rotation.y), 0, -sin(rotation.y))
		global_position += (right * pan.x + forward * -pan.y) * PAN_SPEED * delta


func focus_on(world_pos: Vector3) -> void:
	global_position = Vector3(world_pos.x, global_position.y, world_pos.z)
