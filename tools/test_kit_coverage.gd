extends SceneTree
## Kit coverage: builds every maps/*.txt deck and generated seeds 1-50 with the
## room-tile kits (ModuleCatalog) and checks that the art changed nothing the
## rules can see and left nothing grey.
##
##   godot --headless --path . --script res://tools/test_kit_coverage.gd
##
## Per deck:
##   - no WALL cell fell back to the placeholder box (the kit has no gap for
##     walls: 1-tile runs take a squashed panel);
##   - every WALL cell still has its own layer-1 collision box;
##   - no kit piece carries a physics body, light or camera;
##   - every wall face piece is registered with occlusion under some WALL cell.
## Per generated seed, the deck is built twice and must make the same piece
## choices both times. And once, per kit piece: its size in wrapper space keeps
## the height bands and wall depths the rules are read from.
##
## Untyped like the other tools/ scripts: a --script tool compiles before the
## autoloads register.

const SEEDS := 50
const TILE := 1.5
const WALL_HEIGHT := 3.0
## Cover tier heights (CoverObject.TIER_HEIGHT) and how far art may miss them.
const LIGHT := 1.0
const HEAVY := 1.4
const HEIGHT_SLACK := 0.05
## Wall art limits: into the walkable tile, and into the wall cell.
const INTO_ROOM := 0.25
const INTO_WALL := 0.6
const DOOR_HEADROOM := 2.2
const STRIPPED := ["CollisionObject3D", "CollisionShape3D", "CollisionPolygon3D", "Light3D", "Camera3D"]

var _failures := 0
var _map


func _initialize() -> void:
	_map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(_map)
	await process_frame

	_check_pieces()
	for file in DirAccess.get_files_at("res://maps"):
		if file.get_extension() == "txt":
			_map.build_layout("res://maps/" + file)
			await process_frame
			_check_deck(file)
	for s in range(1, SEEDS + 1):
		_map.build_generated(s)
		await process_frame
		var first: PackedStringArray = _map.piece_log.duplicate()
		_check_deck("seed %d" % s)
		_map.build_generated(s)
		await process_frame
		_check(_map.piece_log == first, "seed %d: the same piece choices on a second build (%d)" % [s, first.size()])

	print("")
	if _failures == 0:
		print("kit coverage: ALL CHECKS PASSED")
		quit(0)
	else:
		print("kit coverage: %d CHECK(S) FAILED" % _failures)
		quit(1)


func _check_deck(label: String) -> void:
	var data = _map.data
	var walls := 0
	for pos in data.cells:
		if data.terrain_at(pos) == 2:  # MapData.Terrain.WALL
			walls += 1
	_check(_map.placeholder_walls.is_empty(),
		"%s: no WALL cell fell back to the placeholder (%d of %d did: %s)" % [
			label, _map.placeholder_walls.size(), walls, _map.placeholder_walls.keys().slice(0, 5)])

	var collided := {}
	var registered := {}
	for cell_nodes in _map._wall_meshes.values():
		for node in cell_nodes:
			registered[node] = true
	var stray: Array[String] = []
	var unregistered := 0
	for child in _map.get_children():
		if child is StaticBody3D and child.collision_layer == 1:
			var shape = child.get_child(0) as CollisionShape3D
			if shape and shape.shape is BoxShape3D \
					and shape.shape.size.is_equal_approx(Vector3(TILE, WALL_HEIGHT, TILE)):
				var p: Vector3 = child.global_position
				collided[Vector3i(roundi(p.x / TILE), 0, roundi(p.z / TILE))] = true
		if child.get_node_or_null("Pivot") != null:
			_find_stripped(child, stray)
			if String(child.name).begins_with("wall_") and not registered.has(child):
				unregistered += 1
	# Kit art under cover bodies, loot crates and terminals, too.
	for wrapper in _map.find_children("Pivot", "Node3D", true, false):
		_find_stripped(wrapper, stray)

	var missing := 0
	for pos in data.cells:
		if data.terrain_at(pos) == 2 and not collided.has(Vector3i(pos.x, 0, pos.z)):
			missing += 1
	_check(missing == 0, "%s: every WALL cell has its layer-1 collision box (%d missing)" % [label, missing])
	_check(stray.is_empty(), "%s: no kit piece carries physics, lights or cameras %s" % [label, stray.slice(0, 5)])
	_check(unregistered == 0, "%s: every wall face piece is registered with occlusion (%d not)" % [label, unregistered])


func _find_stripped(node: Node, out: Array[String]) -> void:
	for child in node.get_children():
		for c in STRIPPED:
			if child.is_class(c):
				out.append("%s:%s" % [child.get_path(), c])
		_find_stripped(child, out)


## Each piece's AABB in wrapper space (origin on the socket, +Z toward the
## room) against the bands the rules are read from.
func _check_pieces() -> void:
	var catalog = load("res://scripts/module_catalog.gd").shared()
	for socket in ["wall_face", "floor", "stair_floor", "door_frame", "cover_light", "cover_heavy", "crate", "terminal"]:
		_check(catalog.has_socket(socket), "the kit fills socket %s" % socket)
		for p in catalog._by_socket.get(socket, []):
			var box := _aabb(catalog.mesh_parts(p))
			var top := box.end.y
			match socket:
				"wall_face":
					_check(top <= WALL_HEIGHT + 0.01, "%s: no taller than the wall (%.3f)" % [p.id, top])
					_check(box.end.z <= INTO_ROOM, "%s: at most %.2f m into the room (%.3f)" % [p.id, INTO_ROOM, box.end.z])
					_check(-box.position.z <= INTO_WALL, "%s: at most %.2f m into the wall cell (%.3f)" % [p.id, INTO_WALL, -box.position.z])
					_check(is_equal_approx(box.size.x, p.tiles * TILE) or absf(box.size.x - p.tiles * TILE) < 0.05,
						"%s: %d tiles long (%.3f m)" % [p.id, p.tiles, box.size.x])
				"floor", "stair_floor":
					_check(top <= 0.35, "%s: a floor stays under the clutter band (%.3f)" % [p.id, top])
					_check(absf(box.size.x - TILE) < 0.02 and absf(box.size.z - TILE) < 0.02,
						"%s: one tile square (%.3f x %.3f)" % [p.id, box.size.x, box.size.z])
				"door_frame":
					var headroom: float = float(p.opening[1]) * p.transform.basis.get_scale().y
					_check(headroom >= DOOR_HEADROOM, "%s: opening clears %.1f m (%.3f)" % [p.id, DOOR_HEADROOM, headroom])
					_check(top <= WALL_HEIGHT + 0.005, "%s: no taller than the wall, so it stays under the caps (%.3f)" % [p.id, top])
				"cover_light":
					_check(absf(top - LIGHT) <= HEIGHT_SLACK, "%s: light cover height (%.3f)" % [p.id, top])
					_check(_fits_tile(p, box), "%s: inside its tile" % p.id)
				"cover_heavy":
					_check(absf(top - HEAVY) <= HEIGHT_SLACK, "%s: heavy cover height (%.3f)" % [p.id, top])
					_check(_fits_tile(p, box), "%s: inside its tile" % p.id)
				"crate":
					_check(top <= 0.8 + 0.01, "%s: inside the crate's 0.8 m (%.3f)" % [p.id, top])
					_check(box.size.x <= 1.1 + 0.01 and box.size.z <= 1.1 + 0.01, "%s: inside the crate's 1.1 m" % p.id)
				"terminal":
					_check(top <= 1.1 + 0.01, "%s: inside the terminal's 1.1 m (%.3f)" % [p.id, top])


## Whether a cover piece, at its per_cell layout, stays inside one tile.
func _fits_tile(p, box: AABB) -> bool:
	var copies := int(p.get("per_cell", 1))
	var reach := maxf(absf(box.position.x), absf(box.end.x))
	reach = maxf(reach, maxf(absf(box.position.z), absf(box.end.z)))
	if copies > 1:
		reach += TILE / 4.0
	return reach <= TILE / 2.0


func _aabb(parts: Array) -> AABB:
	var box := AABB()
	var first := true
	for part in parts:
		var b: AABB = part[1] * (part[0] as Mesh).get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box


func _check(ok: bool, what: String) -> void:
	if not ok:
		_failures += 1
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
