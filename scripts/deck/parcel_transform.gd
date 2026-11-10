@tool
class_name ParcelTransform
extends RefCounted
## Mirror local X first, then clockwise quarter turns in tile coordinates.

static func extent(size: Vector2i, rot: int) -> Vector2i:
	return size if posmod(rot, 2) == 0 else Vector2i(size.y, size.x)

static func apply(local: Vector2i, size: Vector2i, rot: int, mirror: bool) -> Vector2i:
	var p := local
	if mirror:
		p.x = size.x - 1 - p.x
	for i in posmod(rot, 4):
		p = Vector2i(size.y - 1 - p.y, p.x)
		size = Vector2i(size.y, size.x)
	return p

static func side(value: int, rot: int, mirror: bool) -> int:
	if value < 0:
		return -1
	if mirror and value in [MapData.Side.EAST, MapData.Side.WEST]:
		value = posmod(value + 2, 4)
	return posmod(value + rot, 4)

static func rotation(value: int, rot: int, mirror: bool) -> int:
	return posmod(( -value if mirror else value) + rot, 4)

static func rect(value: Rect2i, size: Vector2i, rot: int, mirror: bool) -> Rect2i:
	var a := apply(value.position, size, rot, mirror)
	var b := apply(value.end - Vector2i.ONE, size, rot, mirror)
	return Rect2i(a.min(b), a.max(b) - a.min(b) + Vector2i.ONE)

static func edge_cell(edge: int, index: int, size: Vector2i) -> Vector2i:
	match edge:
		MapData.Side.EAST: return Vector2i(size.x - 1, index)
		MapData.Side.SOUTH: return Vector2i(index, size.y - 1)
		MapData.Side.WEST: return Vector2i(0, index)
	return Vector2i(index, 0)

static func socket(value: Vector3i, size: Vector2i, rot: int, mirror: bool) -> Vector3i:
	var a := apply(edge_cell(value.x, value.y, size), size, rot, mirror)
	var b := apply(edge_cell(value.x, value.y + value.z - 1, size), size, rot, mirror)
	var s := side(value.x, rot, mirror)
	return Vector3i(s, mini(a.y, b.y) if s % 2 == 0 else mini(a.x, b.x), value.z)

static func offset(value: Vector3, rot: int, mirror: bool) -> Vector3:
	if mirror:
		value.x = -value.x
	for i in posmod(rot, 4):
		value = Vector3(-value.z, value.y, value.x)
	return value

## +Z faces into the room. The mount's back plane is exactly on the wall edge.
static func wall_transform(cell: Vector2i, wall_side: int, extra := Vector3.ZERO) -> Transform3D:
	var step := Vector3(MapData.SIDE_STEP[wall_side])
	extra -= step * extra.dot(step)
	var origin := Vector3(cell.x, 0, cell.y) * 1.5 + step * 0.75 + extra
	return Transform3D(Basis(Vector3.UP, atan2(-step.x, -step.z)), origin)
