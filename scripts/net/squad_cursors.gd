class_name SquadCursors
extends Node3D
## A co-op mission's view of where the other players are pointing (see main.gd):
## sends this player's mouse out, and draws a pointer in each partner's colour.
##
## A cursor crosses the wire as a point on the deck, not a screen position. Each
## player orbits their own camera, so the same pixel is a different place on
## another player's screen.

const SEND_INTERVAL := 1.0 / 15.0
## With no word for this long (a partner in a loading screen, or gone), the pointer
## goes rather than sitting frozen where they last were.
const STALE_AFTER := 1.0
## How quickly a pointer closes on its latest position, smoothing over the gaps
## between updates. Higher is snappier.
const FOLLOW_SPEED := 18.0
const POINTER_HEIGHT := 0.6
const POINTER_RADIUS := 0.25
## The gap between the deck and the pointer's tip.
const POINTER_LIFT := 0.1

## Peer id -> {node, material, target, on_deck, age}.
var _pointers: Dictionary = {}
var _send_timer := 0.0


func _ready() -> void:
	CoopPlayers.cursor_received.connect(_on_cursor_received)


func _process(delta: float) -> void:
	_send_timer -= delta
	if _send_timer <= 0.0:
		_send_timer = SEND_INTERVAL
		_send_local_cursor()
	for peer_id: int in _pointers:
		var pointer: Dictionary = _pointers[peer_id]
		pointer["age"] += delta
		var node: MeshInstance3D = pointer["node"]
		var show_it: bool = pointer["on_deck"] and pointer["age"] < STALE_AFTER
		# Coming back into view it appears where it is, not gliding in from where
		# it was last seen.
		if show_it and not node.visible:
			node.global_position = pointer["target"]
		elif show_it:
			node.global_position = node.global_position.lerp(
				pointer["target"], minf(1.0, FOLLOW_SPEED * delta))
		node.visible = show_it


func _send_local_cursor() -> void:
	var viewport := get_viewport()
	var camera := viewport.get_camera_3d()
	var mouse := viewport.get_mouse_position()
	if camera == null or viewport.gui_get_hovered_control() != null \
			or not viewport.get_visible_rect().has_point(mouse):
		CoopPlayers.send_cursor(Vector3.ZERO, false)
		return
	var from := camera.project_ray_origin(mouse)
	var dir := camera.project_ray_normal(mouse)
	var tile := GridManager.tile_under_ray(from, dir)
	if not GridManager.has_tile(tile):
		CoopPlayers.send_cursor(Vector3.ZERO, false)
		return
	# The exact point rather than the tile's centre, so it moves like a cursor.
	var distance := (tile.y * GridManager.FLOOR_HEIGHT - from.y) / dir.y
	CoopPlayers.send_cursor(from + dir * distance, true)


func _on_cursor_received(peer_id: int, at: Vector3, on_deck: bool) -> void:
	if not _pointers.has(peer_id):
		_pointers[peer_id] = _build_pointer()
	var pointer: Dictionary = _pointers[peer_id]
	pointer["target"] = at + Vector3.UP * (POINTER_LIFT + POINTER_HEIGHT * 0.5)
	pointer["on_deck"] = on_deck
	pointer["age"] = 0.0
	pointer["material"].albedo_color = CoopPlayers.color_of(peer_id)


func _build_pointer() -> Dictionary:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.0
	mesh.bottom_radius = POINTER_RADIUS
	mesh.height = POINTER_HEIGHT
	mesh.radial_segments = 4
	mesh.rings = 1
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# Drawn over the walls: the point of a pointer is to be seen, and on this
	# camera a wall stands between it and half the floor.
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	material.render_priority = 1
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.rotation.x = PI  # point down
	node.visible = false
	add_child(node)
	return {"node": node, "material": material, "target": Vector3.ZERO, "on_deck": false, "age": 0.0}
