class_name GridTileData
extends RefCounted
## One tile's data. Grid key is Vector3i(x, floor, z) — see design doc Sec 10.3.

var passable: bool = true
## MapData.Side -> CoverEdge, for the sides of this tile that carry cover.
## Missing keys mean an open edge; there is deliberately no per-tile cover value
## any more, because cover is a property of a boundary and a tile has four.
var cover_edges: Dictionary = {}
var occupant: Node3D = null
var light_value: float = 0.0  # 0-100, written by LightingManager (Sec 5)
var world_pos: Vector3 = Vector3.ZERO  # world-space center of this tile
## An alarm panel (Sec 6 trigger 2). Tripped by walking onto the tile, and it
## fires ONCE — the flag is cleared when it goes off, so a corridor cannot be
## turned into a repeating siren by pacing over it.
var alarm: bool = false
