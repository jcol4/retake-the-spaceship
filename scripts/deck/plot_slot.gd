@tool
class_name PlotSlot
extends Resource

@export var rect: Rect2i
@export_enum("Habitation", "Medical", "Engineering", "Command", "Cargo", "Utility", "None", "Hangar") var zone: int
@export var sockets: Array[Vector3i] = []
@export var required_type: StringName
