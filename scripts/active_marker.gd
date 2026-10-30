extends Node3D
## Ring + bobbing arrow marking the unit currently drawn from the initiative
## pool, in its owner's colour (CoopPlayers). Self-contained: polls TurnManager and
## the owner so the unit scene needs no wiring.

const BOB_HEIGHT := 0.15
const BOB_SPEED := 3.0
const PULSE_SPEED := 2.5
const PULSE_AMOUNT := 0.08
const RING_ALPHA := 0.85
## The arrow is a touch paler than the ring.
const ARROW_LIGHTEN := 0.15

@onready var _ring: MeshInstance3D = $Ring
@onready var _arrow: MeshInstance3D = $Arrow
@onready var _unit: Unit = get_parent() as Unit

var _arrow_base_y: float
var _ring_base_scale: Vector3
var _time := 0.0
var _ring_material: StandardMaterial3D
var _arrow_material: StandardMaterial3D
var _color := Color.TRANSPARENT


func _ready() -> void:
	_arrow_base_y = _arrow.position.y
	_ring_base_scale = _ring.scale
	# Every soldier shares the scene's materials; two owners need two copies.
	_ring_material = _ring.get_surface_override_material(0).duplicate()
	_ring.set_surface_override_material(0, _ring_material)
	_arrow_material = _arrow.get_surface_override_material(0).duplicate()
	_arrow.set_surface_override_material(0, _arrow_material)
	visible = false


func _process(delta: float) -> void:
	var active := _unit != null and not _unit.is_downed and TurnManager.active_unit == _unit
	visible = active
	if not active:
		return
	_apply_color(CoopPlayers.color_of(_unit.owner_peer_id))
	_time += delta
	_arrow.position.y = _arrow_base_y + sin(_time * BOB_SPEED) * BOB_HEIGHT
	var pulse := 1.0 + PULSE_AMOUNT * sin(_time * PULSE_SPEED)
	# Y untouched: the ring is squashed flat by its authored scale.
	_ring.scale = _ring_base_scale * Vector3(pulse, 1.0, pulse)


## Read every frame rather than once: a squadmate who drops hands their soldiers
## to the host (main.gd), and the ring should follow.
func _apply_color(color: Color) -> void:
	if color == _color:
		return
	_color = color
	_ring_material.albedo_color = Color(color, RING_ALPHA)
	_arrow_material.albedo_color = color.lightened(ARROW_LIGHTEN)
