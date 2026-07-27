class_name GridTileData
extends RefCounted
## One tile's data. Grid key is Vector3i(x, floor, z) — see design doc Sec 10.3.

enum CoverType { NONE, LIGHT, HEAVY }

var passable: bool = true
var cover_type: CoverType = CoverType.NONE
var cover_hp: int = 0
var occupant: Node3D = null
var light_value: float = 0.0  # 0-100, written by LightingManager (Sec 5)
var world_pos: Vector3 = Vector3.ZERO  # world-space center of this tile
var cover_node: Node3D = null  # visual cover object, freed on destruction
