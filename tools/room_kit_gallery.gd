extends SceneTree
## Renders every room-kit piece in the furniture sockets (ROOM_ASSETS_SOURCING.md)
## from the tactical camera's angle, on a tiled floor with each piece's footprint
## outlined, so a placeholder can be judged at play distance before MapBuilder
## ever places it. One PNG per socket.
##
##   godot --path . --script res://tools/room_kit_gallery.gd
##   godot --path . --script res://tools/room_kit_gallery.gd -- --sockets=furniture_bunk,cover_light --out=C:/tmp/gallery
##
## Windowed, not --headless: a headless run renders nothing. Footprint outlines
## are coloured by tier (light yellow, heavy red, dressing/clutter blue, wall
## green, door grey); wall pieces get a stub of wall behind them; the grey
## capsule in each block's corner is a 1.8 m person for scale. Sockets default to
## every furniture-convention socket the catalog knows (see PREFIXES), plus the
## two cover sockets.
##
## Each socket's pieces sit in a square-ish block rather than one long row: the
## tactical camera looks along a diagonal, so a row along X would cross the frame
## corner to corner and leave the pieces tiny.
##
## Untyped like the other tools/ scripts: a --script tool compiles before the
## autoloads register.

const TILE := 1.5
const PITCH := 0.6154797  # atan(1 / sqrt(2)), CameraRig.PITCH
const YAW := PI / 4.0  # CameraRig.START_YAW
const PREFIXES := ["furniture_", "hazard_", "dressing_", "decal_", "terminal_wall", "power_switch",
	"elevator_door", "cover_light", "cover_heavy"]
const TIER_COLOR := {
	"light": Color(1.0, 0.85, 0.2), "heavy": Color(1.0, 0.3, 0.25), "dressing": Color(0.35, 0.6, 1.0),
	"clutter": Color(0.35, 0.6, 1.0), "wall": Color(0.3, 0.9, 0.4), "door": Color(0.7, 0.7, 0.7)}
## Tiles between neighbouring footprints in a block.
const GAP := 1
## Metres between socket blocks: far enough that no block shows in another's shot.
const BLOCK_SPACING := 80.0

var _out := "user://room_kit_gallery"
var _sockets: Array = []
var _shots: Array = []  # [path, Camera3D, AABB]
var _frame := 0


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.substr(6)
		elif arg.begins_with("--sockets="):
			_sockets = Array(arg.substr(10).split(","))
	var catalog = load("res://scripts/module_catalog.gd").shared()
	if _sockets.is_empty():
		for socket in catalog._by_socket.keys():
			for prefix in PREFIXES:
				if String(socket).begins_with(prefix):
					_sockets.append(socket)
					break
		_sockets.sort()
	DirAccess.make_dir_recursive_absolute(_out)
	_build_stage()
	for i in _sockets.size():
		var origin := Vector3(0, 0, i * BLOCK_SPACING)
		var box := _lay_block(catalog, _sockets[i], origin)
		var cam := Camera3D.new()
		cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		cam.rotation = Vector3(-PITCH, YAW, 0.0)
		cam.far = 400.0
		root.add_child(cam)
		_shots.append([_out.path_join("%02d_%s.png" % [i, _sockets[i]]), cam, box])
	print("room_kit_gallery: %d sockets -> %s" % [_sockets.size(), ProjectSettings.globalize_path(_out)])


## One socket's pieces in a block of rows from `origin`, columns as wide as its
## widest footprint. Returns the block's bounds.
func _lay_block(catalog, socket: String, origin: Vector3) -> AABB:
	var pieces: Array = catalog._by_socket.get(socket, [])
	var cell := Vector2i(1, 1)
	for p in pieces:
		var fp: Array = p.get("footprint", [1, 1])
		cell = Vector2i(maxi(cell.x, int(fp[0])), maxi(cell.y, int(fp[1])))
	var cols := maxi(1, ceili(sqrt(float(pieces.size()) * cell.y / cell.x)))
	var pitch := Vector2((cell.x + GAP) * TILE, (cell.y + GAP) * TILE + 0.6)
	var rows := ceili(float(pieces.size()) / cols)
	_floor(origin - Vector3(2 * TILE, 0, 2 * TILE), Vector2i(cols * (cell.x + GAP) + 4, rows * (cell.y + GAP) + 4))
	_label(socket, origin + Vector3(-0.5, 0.05, -1.2), 96, Color.WHITE)
	_person(origin + Vector3(-1.0, 0, -0.2))
	var box := AABB(origin + Vector3(-1.5, 0, -1.6), Vector3(0.1, 3.0, 0.1))
	for i in pieces.size():
		var p: Dictionary = pieces[i]
		var fp: Array = p.get("footprint", [1, 1])
		var size := Vector2(float(fp[0]), float(fp[1])) * TILE
		var centre := origin + Vector3((i % cols) * pitch.x + size.x / 2.0, 0, (i / cols) * pitch.y + size.y / 2.0)
		# The cover pieces predate `tier`; their socket says it.
		var tier := String(p.get("tier", "heavy" if socket == "cover_heavy" else "light"))
		_outline(centre, size, TIER_COLOR.get(tier, Color.WHITE))
		var node: Node3D = catalog.instance(p)
		root.add_child(node)
		if tier == "wall":
			# Wall pieces hang from a wall face on the footprint's back edge.
			node.position = centre - Vector3(0, 0, size.y / 2.0)
			_wall_stub(node.position, size.x)
		else:
			node.position = centre
		_label("%s (%s)" % [p.id, tier], centre + Vector3(0, 0.03, size.y / 2.0 + 0.3), 56,
			TIER_COLOR.get(tier, Color.WHITE))
		box = box.expand(centre + Vector3(size.x / 2.0, 3.0, size.y / 2.0 + 0.6))
		box = box.expand(centre - Vector3(size.x / 2.0, 0, size.y / 2.0))
	return box


func _build_stage() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.09, 0.09, 0.1)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.75, 0.78, 0.82)
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-55.0), deg_to_rad(30.0), 0.0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 300.0
	root.add_child(sun)


## A checker of tiles from `corner`, so a piece's size reads against the grid.
func _floor(corner: Vector3, tiles: Vector2i) -> void:
	var quad := PlaneMesh.new()
	quad.size = Vector2(TILE, TILE)
	for parity in 2:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = quad
		var at: Array = []
		for tz in tiles.y:
			for tx in tiles.x:
				if (tx + tz) % 2 == parity:
					at.append(corner + Vector3((tx + 0.5) * TILE, 0, (tz + 0.5) * TILE))
		mm.instance_count = at.size()
		for i in at.size():
			mm.set_instance_transform(i, Transform3D(Basis(), at[i]))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = _flat(Color(0.2, 0.21, 0.23) if parity == 0 else Color(0.25, 0.26, 0.28))
		root.add_child(mmi)


func _flat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.9
	return m


func _outline(centre: Vector3, size: Vector2, c: Color) -> void:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	const W := 0.05
	for edge in [[Vector3(0, 0, -size.y / 2.0), Vector3(size.x, 0.01, W)], [Vector3(0, 0, size.y / 2.0), Vector3(size.x, 0.01, W)],
			[Vector3(-size.x / 2.0, 0, 0), Vector3(W, 0.01, size.y)], [Vector3(size.x / 2.0, 0, 0), Vector3(W, 0.01, size.y)]]:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = edge[1]
		mi.mesh = bm
		mi.material_override = m
		mi.position = centre + edge[0] + Vector3(0, 0.01, 0)
		root.add_child(mi)


func _wall_stub(face: Vector3, width: float) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(width, 3.0, 0.3)
	mi.mesh = bm
	mi.material_override = _flat(Color(0.32, 0.33, 0.36))
	mi.position = face + Vector3(0, 1.5, -0.15)
	root.add_child(mi)


func _person(at: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = 0.25
	cm.height = 1.8
	mi.mesh = cm
	mi.material_override = _flat(Color(0.55, 0.55, 0.55))
	mi.position = at + Vector3(0, 0.9, 0)
	root.add_child(mi)


func _label(text: String, at: Vector3, size: int, c: Color) -> void:
	var l := Label3D.new()
	l.text = text
	l.font_size = size
	l.pixel_size = 0.004
	l.modulate = c
	l.outline_size = 14
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.position = at
	root.add_child(l)


## Sizes and centres orthographic `cam` (at the tactical rig's pitch and yaw) so
## `box` fills the frame. Run at shot time: the window's real aspect is only
## known once it is open, and the game's settings may have resized it.
func _frame_camera(cam: Camera3D, box: AABB) -> void:
	var basis := cam.global_transform.basis
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for i in 8:
		var p := box.get_endpoint(i)
		var v := Vector2(basis.x.dot(p), basis.y.dot(p))
		lo = lo.min(v)
		hi = hi.max(v)
	var vp := root.get_visible_rect().size
	var aspect := vp.x / maxf(vp.y, 1.0)
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.size = maxf(hi.y - lo.y, (hi.x - lo.x) / aspect) * 1.05
	var mid := (lo + hi) / 2.0
	# Back along the view axis from the box's own depth, not the origin's: a
	# block far down +Z would otherwise land behind the camera.
	var depth := basis.z.dot(box.get_center())
	cam.global_position = basis.x * mid.x + basis.y * mid.y + basis.z * (depth + 150.0)


func _process(_delta: float) -> bool:
	if _shots.is_empty():
		return true
	_frame += 1
	if _frame == 1:
		var cam: Camera3D = _shots[0][1]
		_frame_camera(cam, _shots[0][2])
		cam.make_current()
		return false
	if _frame < 6:  # let the camera and shadows settle
		return false
	var shot: Array = _shots.pop_front()
	root.get_texture().get_image().save_png(shot[0])
	print("  wrote ", ProjectSettings.globalize_path(shot[0]))
	_frame = 0
	if _shots.is_empty():
		quit(0)
	return false
