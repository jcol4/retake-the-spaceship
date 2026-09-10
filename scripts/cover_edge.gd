class_name CoverEdge
extends RefCounted
## One piece of cover, living on the boundary between two tiles (Sec 6.1, XCOM
## model). A unit stands ON a tile and is protected from shots crossing an edge
## that carries one of these.
##
## Shared by BOTH tiles the edge separates — GridManager stores the same object
## against the east side of one and the west side of the other. That sharing is
## the whole reason this is a class rather than a pair of fields: two copies
## would give one crate two independent HP pools, and shooting it from one side
## would leave it intact from the other.

const LIGHT_HP := 20
const HEAVY_HP := 50

## MapData.Cover. Drops a tier when destroyed rather than vanishing — see
## GridManager.damage_cover_edge.
var type: int = MapData.Cover.NONE
var hp: int = 0
var node: Node3D = null  # the visual prop, told to restyle itself on a tier change

## Set only for a block-cover piece (MapBuilder.CoverBlock / MapData.obstacles)
## registered via GridManager.register_cover_block — a WHOLE tile footprint
## rather than one boundary, shared across every side of its perimeter so one
## shot anywhere on it damages the same pool. `footprint`/`deck` are what
## GridManager needs to reopen the tiles on destruction; `registrations` is
## every [pos, side] this same edge was stored at, so destruction can find and
## clear all of them, not just the one that happened to land the killing shot.
var is_block: bool = false
var footprint: Rect2i = Rect2i()
var deck: int = 0
var registrations: Array = []


static func hp_for(cover_type: int) -> int:
	return HEAVY_HP if cover_type == MapData.Cover.HEAVY else LIGHT_HP


func is_intact() -> bool:
	return type != MapData.Cover.NONE
