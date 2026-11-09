class_name ModuleCatalog
extends RefCounted
## Room-tile kit pieces, read from every assets/room_tiles/<kit>/<kit>.json
## manifest. The manifest is where all mapping lives — which kit file fills
## which socket, at what scale, yaw and offset — so the kit's own files are
## used as shipped, never renamed or edited.
##
## A piece's wrapper (see `instance`) has its origin on the socket and its +Z
## on the room side, whatever the kit authored, so MapBuilder and the prop
## scripts place every kit the same way. Kit art is visual only: collision,
## lights and cameras are stripped on load, and the callers keep building
## their own collision exactly as they did for the placeholder boxes.
##
## Variant choice is a pure function of the hash the caller passes in. Co-op
## peers build the same deck from the seed alone, so nothing here may touch
## an RNG.
##
## One shared instance (`shared`), because loading and cleaning a kit's
## scenes is the expensive part and a mission restart rebuilds the deck.
##
## Beyond file/socket/scale/yaw/pitch/offset, a piece may carry:
## - `parts`: more models drawn as one piece (a workbench is a table plus a
##   computer), each with its own file, scale (default 1), yaw, pitch and
##   offset in wrapper space.
## - A piece's or part's file may be a full res:// path into another kit; it
##   then takes that kit's materials. Point only into a kit that is always
##   there (the MegaKit), so each downloaded pack can be removed on its own.
## - `tint` [r, g, b]: multiplies every surface's albedo, texture kept (a red
##   fuel barrel from a grey one). `paint` [r, g, b] replaces the albedo with
##   that flat colour, texture dropped (a white medical bed from a coloured
##   one). Either also works on a part.
## A material spec may name its textures by full res:// path, so two kits that
## share a texture sheet keep one copy of it, and may add an `emission` map.

const ROOT := "res://assets/room_tiles/"
## Node classes removed from an instanced kit scene before it is used.
const STRIPPED := ["CollisionObject3D", "CollisionShape3D", "CollisionPolygon3D", "Light3D", "Camera3D"]

static var _shared: ModuleCatalog

## socket -> Array of piece Dictionaries, in manifest order.
var _by_socket: Dictionary = {}
## piece id -> piece Dictionary.
var _by_id: Dictionary = {}
## piece id (or "<id>#<part>") -> cleaned, re-materialled PackedScene.
var _scenes: Dictionary = {}
## piece id -> Array of [Mesh, Transform3D] in wrapper space; see `mesh_parts`.
var _parts: Dictionary = {}
## "<kit>/<material name>" -> the Material built from that kit's textures.
var _materials: Dictionary = {}
## "<mesh instance id>|<tint>|<paint>" -> its copy carrying the kit's own
## materials, recoloured as the piece asks.
var _fixed_meshes: Dictionary = {}
## "<material instance id>|<tint>|<paint>" -> the recoloured copy.
var _recoloured: Dictionary = {}


static func shared() -> ModuleCatalog:
	if _shared == null:
		_shared = ModuleCatalog.new()
		_shared._load_manifests()
	return _shared


## Stable variant hash for a socket. Every caller goes through this so that
## the same inputs give the same piece on every peer and every rebuild.
static func hash_of(parts: Array) -> int:
	return hash(parts) & 0x7fffffff


func has_socket(socket: String) -> bool:
	return _by_socket.has(socket)


func piece(id: String) -> Dictionary:
	return _by_id.get(id, {})


## A weighted pick among `socket`'s pieces that pass `accept` (all of them
## when it is not given), or an empty Dictionary when none does — the caller
## then draws its placeholder.
func pick(socket: String, h: int, accept: Callable = Callable()) -> Dictionary:
	var pool: Array = []
	var total := 0
	for p: Dictionary in _by_socket.get(socket, []):
		if accept.is_valid() and not accept.call(p):
			continue
		pool.append(p)
		total += int(p.weight)
	if pool.is_empty():
		return {}
	var roll := posmod(h, total)
	for p: Dictionary in pool:
		roll -= int(p.weight)
		if roll < 0:
			return p
	return pool[-1]


## A wrapper Node3D for `p`: origin on the socket, +Z toward the room, with
## the piece's scale, yaw and offset applied on a "Pivot" child inside it. The
## caller is free to position, rotate and scale the wrapper itself — a wall
## run stretches it along X, for instance — without undoing any of that.
func instance(p: Dictionary) -> Node3D:
	var wrapper := Node3D.new()
	wrapper.name = p.id
	var pivot := Node3D.new()
	pivot.name = "Pivot"
	pivot.transform = p.transform
	pivot.add_child(_scene(p).instantiate())
	wrapper.add_child(pivot)
	# Each part beside the Pivot, in wrapper space, so a part never inherits
	# the main model's scale.
	var parts: Array = p.get("parts", [])
	for i in parts.size():
		var holder := Node3D.new()
		holder.name = "Part%d" % i
		holder.transform = parts[i].transform
		holder.add_child(_part_scene(p, i).instantiate())
		wrapper.add_child(holder)
	return wrapper


## `p`'s meshes with their transforms in wrapper space, for callers that draw
## one piece many times through a MultiMeshInstance3D (floors).
func mesh_parts(p: Dictionary) -> Array:
	if _parts.has(p.id):
		return _parts[p.id]
	var out: Array = []
	var inst := instance(p)
	_collect_parts(inst, Transform3D.IDENTITY, out)
	inst.free()
	_parts[p.id] = out
	return out


func _collect_parts(node: Node, parent_xf: Transform3D, out: Array) -> void:
	var xf := parent_xf
	if node is Node3D:
		xf = parent_xf * (node as Node3D).transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		out.append([(node as MeshInstance3D).mesh, xf])
	for child in node.get_children():
		_collect_parts(child, xf, out)


func _load_manifests() -> void:
	for kit in DirAccess.get_directories_at(ROOT):
		var path := "%s%s/%s.json" % [ROOT, kit, kit]
		if not FileAccess.file_exists(path):
			continue
		var json: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if not (json is Dictionary):
			push_error("ModuleCatalog: can't parse " + path)
			continue
		var kit_dir := ROOT + kit + "/"
		var kit_scale := _vec(json.get("scale", [1, 1, 1]))
		var tex_dir := kit_dir + String(json.get("textures", "")) + "/"
		for name: String in json.get("materials", {}):
			_materials["%s/%s" % [kit, name]] = _build_material(name, json.materials[name], tex_dir)
		for entry: Dictionary in json.get("pieces", []):
			var p := entry.duplicate()
			p.kit = kit
			p.path = _file(kit_dir, String(entry.file))
			# Materials come from the kit the file lives in, which for a res://
			# path into another kit is not the manifest's own.
			p.material_kit = _kit_of(p.path, kit)
			p.weight = int(entry.get("weight", 1))
			p.transform = _transform(entry, kit_scale)
			var parts: Array = []
			for part: Dictionary in entry.get("parts", []):
				var part_path := _file(kit_dir, String(part.file))
				parts.append({"path": part_path, "kit": _kit_of(part_path, kit), "transform": _transform(part, Vector3.ONE),
					"tint": part.get("tint", []), "paint": part.get("paint", [])})
			p.parts = parts
			if _by_id.has(p.id):
				push_error("ModuleCatalog: duplicate piece id " + p.id)
				continue
			_by_id[p.id] = p
			if not _by_socket.has(p.socket):
				_by_socket[p.socket] = []
			_by_socket[p.socket].append(p)


func _vec(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


## Scale, then pitch about +X, then yaw about +Y, then offset — the order every
## manifest note describes.
func _transform(entry: Dictionary, default_scale: Vector3) -> Transform3D:
	var basis := Basis(Vector3.UP, deg_to_rad(float(entry.get("yaw", 0.0)))) \
		* Basis(Vector3.RIGHT, deg_to_rad(float(entry.get("pitch", 0.0)))) \
		* Basis.from_scale(_vec(entry.scale) if entry.has("scale") else default_scale)
	return Transform3D(basis, _vec(entry.get("offset", [0, 0, 0])))


## A manifest file name: relative to `dir` unless it is already a res:// path.
func _file(dir: String, name: String) -> String:
	return name if name.begins_with("res://") else dir + name


## The kit a res://assets/room_tiles/<kit>/... path belongs to, so a part taken
## from another kit gets that kit's materials.
func _kit_of(path: String, fallback: String) -> String:
	if not path.begins_with(ROOT):
		return fallback
	return path.trim_prefix(ROOT).get_slice("/", 0)


## One kit material, rebuilt from the textures the manifest names. The kit's
## glTFs reference their PNGs by bare file name next to each glTF, and the
## download keeps them in a separate Textures folder, so the imported
## materials arrive untextured; these replace them by name.
func _build_material(name: String, spec: Dictionary, tex_dir: String) -> Material:
	var m: BaseMaterial3D = ORMMaterial3D.new() if spec.has("orm") else StandardMaterial3D.new()
	m.resource_name = name
	m.albedo_texture = load(_file(tex_dir, String(spec.albedo)))
	if spec.has("orm"):
		(m as ORMMaterial3D).orm_texture = load(_file(tex_dir, String(spec.orm)))
	else:
		m.roughness = 0.5
	if spec.has("normal"):
		m.normal_enabled = true
		m.normal_texture = load(_file(tex_dir, String(spec.normal)))
	if spec.has("emission"):
		# Additive over a black emission colour: the map alone decides what glows.
		m.emission_enabled = true
		m.emission_texture = load(_file(tex_dir, String(spec.emission)))
	return m


## `p`'s scene, cleaned and re-materialled once and then packed, so every
## later instance is a plain instantiate().
func _scene(p: Dictionary) -> PackedScene:
	if not _scenes.has(p.id):
		_scenes[p.id] = _packed(p.path, p.material_kit, p.get("tint", []), p.get("paint", []))
	return _scenes[p.id]


func _part_scene(p: Dictionary, i: int) -> PackedScene:
	var key := "%s#%d" % [p.id, i]
	if not _scenes.has(key):
		var part: Dictionary = p.parts[i]
		_scenes[key] = _packed(part.path, part.kit, part.tint, part.paint)
	return _scenes[key]


func _packed(path: String, kit: String, tint: Array, paint: Array) -> PackedScene:
	var root: Node = (load(path) as PackedScene).instantiate()
	_clean(root, kit, tint, paint)
	var packed := PackedScene.new()
	packed.pack(root)
	root.free()
	return packed


func _clean(node: Node, kit: String, tint: Array, paint: Array) -> void:
	for child in node.get_children():
		if STRIPPED.any(func(c: String) -> bool: return child.is_class(c)):
			node.remove_child(child)
			child.free()
			continue
		_clean(child, kit, tint, paint)
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		(node as MeshInstance3D).mesh = _fixed_mesh((node as MeshInstance3D).mesh, kit, tint, paint)


func _fixed_mesh(mesh: Mesh, kit: String, tint: Array, paint: Array) -> Mesh:
	var key := "%d|%s|%s" % [mesh.get_instance_id(), tint, paint]
	if _fixed_meshes.has(key):
		return _fixed_meshes[key]
	var copy: Mesh = mesh.duplicate()
	for s in copy.get_surface_count():
		var mat := copy.surface_get_material(s)
		if mat != null and _materials.has("%s/%s" % [kit, mat.resource_name]):
			mat = _materials["%s/%s" % [kit, mat.resource_name]]
		if not tint.is_empty() or not paint.is_empty():
			mat = _recolour(mat, tint, paint)
		copy.surface_set_material(s, mat)
	_fixed_meshes[key] = copy
	return copy


## A copy of `mat` with its albedo multiplied by `tint`, or replaced by the
## flat colour `paint` (texture dropped). Cached, so every piece asking for the
## same recolour of the same material shares one.
func _recolour(mat: Material, tint: Array, paint: Array) -> Material:
	var key := "%d|%s|%s" % [mat.get_instance_id() if mat != null else 0, tint, paint]
	if _recoloured.has(key):
		return _recoloured[key]
	var out: BaseMaterial3D
	if mat is BaseMaterial3D:
		out = mat.duplicate()
	else:
		out = StandardMaterial3D.new()  # untinted imports or shader materials: a plain stand-in
	if not paint.is_empty():
		out.albedo_texture = null
		out.albedo_color = Color(float(paint[0]), float(paint[1]), float(paint[2]))
	if not tint.is_empty():
		out.albedo_color *= Color(float(tint[0]), float(tint[1]), float(tint[2]))
	_recoloured[key] = out
	return out
