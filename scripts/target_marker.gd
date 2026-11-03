class_name TargetMarker
extends Node3D
## The red ring + bobbing arrow over the hostile picked for a shot (XCOM-style
## targeting; see PlayerUnit.target_picked). The same shape and motion as
## ActiveMarker, so "this one is yours" and "this one is the target" read as one
## visual language in two colours.
##
## Owned by the HUD rather than parented to the target: it follows `target` each
## frame, so a target that dies and is freed takes nothing with it.

const ActiveMarker := preload("res://scripts/active_marker.gd")
const COLOR := Color(1.0, 0.18, 0.15)
## Mirrors the ring and arrow in player_unit.tscn's ActiveMarker.
const RING_OUTER := 0.64
const RING_Y := 0.04
const RING_SQUASH := 0.3
const ARROW_Y := 2.75

var target: Unit = null

var _ring: MeshInstance3D
var _arrow: MeshInstance3D
var _time := 0.0


func _ready() -> void:
	_ring = MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.outer_radius = RING_OUTER
	_ring.mesh = torus
	_ring.position.y = RING_Y
	_ring.scale = Vector3(1.0, RING_SQUASH, 1.0)
	_ring.material_override = _unshaded(Color(COLOR, ActiveMarker.RING_ALPHA))
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ring)

	_arrow = MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.22
	cone.height = 0.4
	cone.radial_segments = 4
	cone.rings = 1
	_arrow.mesh = cone
	_arrow.position.y = ARROW_Y
	_arrow.rotation.x = PI  # point down at the target
	_arrow.material_override = _unshaded(COLOR.lightened(ActiveMarker.ARROW_LIGHTEN))
	_arrow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_arrow)
	visible = false


func _process(delta: float) -> void:
	var shown := target != null and is_instance_valid(target) and not target.is_downed \
		and target.is_inside_tree()
	visible = shown
	if not shown:
		return
	global_position = target.global_position
	_time += delta
	_arrow.position.y = ARROW_Y + sin(_time * ActiveMarker.BOB_SPEED) * ActiveMarker.BOB_HEIGHT
	var pulse := 1.0 + ActiveMarker.PULSE_AMOUNT * sin(_time * ActiveMarker.PULSE_SPEED)
	_ring.scale = Vector3(pulse, RING_SQUASH, pulse)


func _unshaded(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	if color.a < 1.0:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return mat
