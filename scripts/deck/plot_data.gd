@tool
class_name PlotData
extends Resource

@export var display_name: String
@export_enum("Small", "Medium", "Large") var deck_size: int
@export var size := Vector2i(72, 48)
@export var terrain: PackedByteArray
@export var corridor_rects: Array[Rect2i] = []
## Parallel to corridor_rects; absent entries default to CORRIDOR.
@export var corridor_types: Array[StringName] = []
@export var slots: Array[PlotSlot] = []
@export var pieces: Array[DeckPiece] = []
@export var lights: Array[DeckLight] = []
@export var markers: Array[DeckMarker] = []
@export var cover_edges: Dictionary = {}
## Only for starter/test plots that intentionally lack a full zone catalog.
@export var test_only := false
