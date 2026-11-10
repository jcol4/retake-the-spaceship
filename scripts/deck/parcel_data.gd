@tool
class_name ParcelData
extends Resource

const ZONE_HANGAR := 7
@export var display_name: String
@export_enum("Habitation", "Medical", "Engineering", "Command", "Cargo", "Utility", "None", "Hangar") var zone: int
@export var room_type: StringName
@export var size := Vector2i(8, 10)
@export var terrain: PackedByteArray
@export var sockets_ok: Array[Vector3i] = []
@export var cover_edges: Dictionary = {}
@export var pieces: Array[DeckPiece] = []
@export var lights: Array[DeckLight] = []
@export var markers: Array[DeckMarker] = []
@export var allow_mirror := true
@export_range(0.001, 1000) var weight := 1.0
@export var tags: PackedStringArray
