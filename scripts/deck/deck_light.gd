@tool
class_name DeckLight
extends Resource

enum Preset { OVERHEAD, MONITOR, FLICKER, WALL_LAMP, ALARM }
@export_enum("Overhead", "Monitor", "Flicker", "Wall lamp", "Alarm") var preset: int
@export var cell: Vector2i
@export_range(-1, 3) var wall_side := -1
@export var overrides: Dictionary = {}
@export var use_room_color := true
@export var chance := PackedFloat32Array([1, 1, 1, 1])
@export var group: StringName
@export_range(0.001, 1000) var weight := 1.0
