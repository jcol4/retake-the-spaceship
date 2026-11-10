@tool
class_name DeckMarker
extends Resource

enum Kind { ENEMY, PATROL, NEST_SPOT, LOOT, PLAYER, PAD }
@export_enum("Enemy", "Patrol", "Nest spot", "Loot", "Player", "Pad") var kind: int
@export var cell: Vector2i
@export var pinned_spawn := -1
@export var loot_table: StringName
@export_enum("East", "South", "West", "North") var ramp_side: int
@export var chance := PackedFloat32Array([1, 1, 1, 1])
@export var group: StringName
@export_range(0.001, 1000) var weight := 1.0
