extends Node3D
## Ring + bobbing arrow marking the unit currently drawn from the initiative
## pool. Self-contained: polls TurnManager so the unit scene needs no wiring.

const BOB_HEIGHT := 0.15
const BOB_SPEED := 3.0
const PULSE_SPEED := 2.5
const PULSE_AMOUNT := 0.08

@onready var _ring: MeshInstance3D = $Ring
@onready var _arrow: MeshInstance3D = $Arrow
@onready var _unit: Unit = get_parent() as Unit

var _arrow_base_y: float
var _ring_base_scale: Vector3
var _time := 0.0


func _ready() -> void:
	_arrow_base_y = _arrow.position.y
	_ring_base_scale = _ring.scale
	visible = false


func _process(delta: float) -> void:
	var active := _unit != null and not _unit.is_downed and TurnManager.active_unit == _unit
	visible = active
	if not active:
		return
	_time += delta
	_arrow.position.y = _arrow_base_y + sin(_time * BOB_SPEED) * BOB_HEIGHT
	var pulse := 1.0 + PULSE_AMOUNT * sin(_time * PULSE_SPEED)
	# Y untouched: the ring is squashed flat by its authored scale.
	_ring.scale = _ring_base_scale * Vector3(pulse, 1.0, pulse)
