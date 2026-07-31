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


static func hp_for(cover_type: int) -> int:
	return HEAVY_HP if cover_type == MapData.Cover.HEAVY else LIGHT_HP


func is_intact() -> bool:
	return type != MapData.Cover.NONE
