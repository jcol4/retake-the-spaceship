@tool
class_name DeckPiece
extends Resource

@export var piece_id: StringName
@export var cell: Vector2i
@export_range(0, 3) var rot: int
@export_range(-1, 3) var wall_side: int = -1
@export var offset: Vector3
@export var yaw_deg: float
@export var stack_on: int = -1
@export var cover_override: int = -1
@export var chance := PackedFloat32Array([1, 1, 1, 1])
@export var group: StringName
@export_range(0.001, 1000) var weight := 1.0
