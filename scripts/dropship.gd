class_name Dropship
extends Node3D
## The ship that inserts the squad and lifts it out (GDD §7.1, §7.4). Placeholder
## art: a box hull and a hinged ramp, until the dropship model on the art list
## exists.
##
## Deliberately NOT a Unit. "The ship itself cannot be damaged" (§7.4) is
## enforced by there being nothing to hit: no "units" group membership means no
## targeting query ever returns it, and no layer-2 body means no click picks it.
## The hull this node draws has no collision either. What a landed ship DOES do
## is block line of sight and light across its reserved space (GDD §7.2) — that
## is a separate, static blocker (`make_blocker`) that ExtractionManager puts on
## the pad for exactly as long as the ship is LANDED, independent of this node's
## descent and lift-off animation. The door gun that DOES fight (extraction plan
## Phase 5) is a separate unit mounted at `door_gun_mount`.
##
## Scene-only. Every timer — when it lands, how long it waits, when it leaves —
## lives in ExtractionRules; this node only plays the moves it is told to.

## Tiles across the reserved ship space (MapData.HANGAR_PAD_RADIUS): 5.
const PAD_TILES := MapData.HANGAR_PAD_RADIUS * 2 + 1
## Hull footprint: just inside the reserved pad, so the pad's ring marking still
## shows round the edge when it is down. Derived from the pad, so a bigger ship
## space is a bigger hull with no other change; the real model replaces the box
## and should fit the same footprint.
const HULL_SIZE := Vector3(PAD_TILES * 1.5 - 0.5, 3.0, PAD_TILES * 1.5 - 0.5)
## The ramp, hinged on the hull's ramp-side bottom edge. Long enough at a ~25°
## rest angle to reach the first row of the extraction square.
const RAMP_SIZE := Vector3(3.0, 0.12, 2.2)
## Height of the landed ship's sight-and-light blocker (`make_blocker`): a full
## bulkhead's (MapBuilder.WALL_HEIGHT), so it occludes exactly what a wall does.
const BLOCKER_HEIGHT := 3.0
const RAMP_DOWN_ANGLE := deg_to_rad(25.0)
## Metres above the pad it descends from and climbs back to. Above the camera's
## usual framing so it arrives from off-screen rather than popping in.
const HOVER_HEIGHT := 16.0
const DESCEND_TIME := 1.8
const RAMP_TIME := 0.6
const TAKEOFF_TIME := 1.5

## Where the Phase 5 door gun attaches: on the ramp-side corner of the hull's
## roof, looking out over the square. A Marker3D so a gunner can simply be
## parented to it (or read its global transform) without this node knowing it.
var door_gun_mount: Marker3D

var _hull: MeshInstance3D
var _ramp_pivot: Node3D
var _ramp_down := false
## The pad this ship lands on and lifts off from, in world space (see `place`).
var _pad_world := Vector3.ZERO


func _init() -> void:
	name = "Dropship"
	_build()


func _build() -> void:
	var hull_mat := StandardMaterial3D.new()
	hull_mat.albedo_color = Color(0.32, 0.36, 0.34)
	_hull = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = HULL_SIZE
	_hull.mesh = box
	_hull.material_override = hull_mat
	_hull.position = Vector3(0, HULL_SIZE.y / 2.0, 0)
	add_child(_hull)

	# Built facing local +Z; `place` turns the whole ship to its hangar's ramp side.
	_ramp_pivot = Node3D.new()
	_ramp_pivot.name = "RampPivot"
	_ramp_pivot.position = Vector3(0, RAMP_SIZE.y, HULL_SIZE.z / 2.0)
	add_child(_ramp_pivot)
	var ramp_mat := StandardMaterial3D.new()
	ramp_mat.albedo_color = Color(0.85, 0.6, 0.15)
	var ramp := MeshInstance3D.new()
	var ramp_box := BoxMesh.new()
	ramp_box.size = RAMP_SIZE
	ramp.mesh = ramp_box
	ramp.material_override = ramp_mat
	# Hinged on its near edge: the mesh hangs off the pivot along +Z.
	ramp.position = Vector3(0, 0, RAMP_SIZE.z / 2.0)
	_ramp_pivot.add_child(ramp)
	_set_ramp(false)

	door_gun_mount = Marker3D.new()
	door_gun_mount.name = "DoorGunMount"
	# Over the centre of the pad's ramp-side right corner TILE
	# (MapData.hangar_gun_cell): R tiles right and R tiles forward of the centre.
	var corner := MapData.HANGAR_PAD_RADIUS * 1.5
	door_gun_mount.position = Vector3(corner, HULL_SIZE.y, corner)
	add_child(door_gun_mount)


## The landed ship's sight-and-light blocker (GDD §7.2): a static body on
## collision layer 1 — what LOS (GridManager.has_line_of_sight) and lighting
## occlusion (has_clear_line) raycast — filling the reserved pad to bulkhead
## height. Built facing local +Z (the ramp side) and turned like the ship.
##
## L-shaped rather than a box: the door gunner's corner tile
## (MapData.hangar_gun_cell) is left out. The gunner stands there, and with the
## corner inside the blocker every ray TO it would hit the hull first — nothing
## could ever shoot the gun, which must be able to be disabled (§7.4). Two boxes:
## everything but the corner's column, and that column short of the corner.
static func make_blocker(pad_world: Vector3, ramp_side: int) -> StaticBody3D:
	const T := 1.5  # GridManager.TILE_SIZE, spelled out: this file stays scene-free
	var r := MapData.HANGAR_PAD_RADIUS
	var body := StaticBody3D.new()
	body.name = "ShipBlocker"
	body.collision_layer = 1
	body.collision_mask = 0
	# Columns x in [-r, r-1] (local), every row.
	var a := CollisionShape3D.new()
	var box_a := BoxShape3D.new()
	box_a.size = Vector3(2 * r * T, BLOCKER_HEIGHT, (2 * r + 1) * T)
	a.shape = box_a
	a.position = Vector3(-T / 2.0, BLOCKER_HEIGHT / 2.0, 0)
	body.add_child(a)
	# Column x = r, rows z in [-r, r-1]: everything in it but the corner.
	var b := CollisionShape3D.new()
	var box_b := BoxShape3D.new()
	box_b.size = Vector3(T, BLOCKER_HEIGHT, 2 * r * T)
	b.shape = box_b
	b.position = Vector3(r * T, BLOCKER_HEIGHT / 2.0, -T / 2.0)
	body.add_child(b)
	var step: Vector3i = MapData.SIDE_STEP[ramp_side]
	body.rotation.y = atan2(float(step.x), float(step.z))
	body.position = pad_world
	return body


## Positions the ship over `pad_world` with its ramp facing `ramp_side`
## (MapData.Side), starting up at HOVER_HEIGHT ready to `descend`.
func place(pad_world: Vector3, ramp_side: int, landed: bool = false) -> void:
	var step: Vector3i = MapData.SIDE_STEP[ramp_side]
	rotation.y = atan2(float(step.x), float(step.z))
	global_position = pad_world + Vector3(0, 0.0 if landed else HOVER_HEIGHT, 0)
	_pad_world = pad_world


func descend() -> void:
	if _instant():
		global_position = _pad_world
		return
	var tween := create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "global_position", _pad_world, DESCEND_TIME)
	await tween.finished


func lower_ramp() -> void:
	await _swing_ramp(true)


func raise_ramp() -> void:
	await _swing_ramp(false)


func take_off() -> void:
	if _ramp_down:
		await raise_ramp()
	if _instant():
		global_position = _pad_world + Vector3(0, HOVER_HEIGHT, 0)
		return
	var tween := create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_property(self, "global_position", _pad_world + Vector3(0, HOVER_HEIGHT, 0), TAKEOFF_TIME)
	await tween.finished


func is_ramp_down() -> bool:
	return _ramp_down


func _swing_ramp(down: bool) -> void:
	_ramp_down = down
	if _instant():
		_set_ramp(down)
		return
	var tween := create_tween()
	tween.tween_property(_ramp_pivot, "rotation:x", _ramp_angle(down), RAMP_TIME)
	await tween.finished


func _set_ramp(down: bool) -> void:
	_ramp_pivot.rotation.x = _ramp_angle(down)


## Up is folded flat against the hull (a quarter turn back); down rests at
## RAMP_DOWN_ANGLE below horizontal, foot on the deck.
func _ramp_angle(down: bool) -> float:
	return RAMP_DOWN_ANGLE if down else -PI / 2.0


## No frames are drawn headless, so a cinematic there is wall-clock time spent on
## nothing — the same rule MapBuilder._instant_fade and Unit.is_instant follow.
func _instant() -> bool:
	return DisplayServer.get_name() == "headless" or not is_inside_tree()
