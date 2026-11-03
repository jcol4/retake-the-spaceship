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

const ROOT := "res://assets/room_tiles/"
## Node classes removed from an instanced kit scene before it is used.
const STRIPPED := ["CollisionObject3D", "CollisionShape3D", "CollisionPolygon3D", "Light3D", "Camera3D"]

static var _shared: ModuleCatalog

## socket -> Array of piece Dictionaries, in manifest order.
var _by_socket: Dictionary = {}
## piece id -> piece Dictionary.
var _by_id: Dictionary = {}
## piece id -> cleaned, re-materialled PackedScene.
var _scenes: Dictionary = {}
## piece id -> Array of [Mesh, Transform3D] in wrapper space; see `mesh_parts`.
var _parts: Dictionary = {}
## "<kit>/<material name>" -> the Material built from that kit's textures.
var _materials: Dictionary = {}
## Imported mesh instance id -> its copy carrying the kit's own materials.
var _fixed_meshes: Dictionary = {}


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
			p.path = kit_dir + String(entry.file)
			p.weight = int(entry.get("weight", 1))
			var basis := Basis(Vector3.UP, deg_to_rad(float(entry.get("yaw", 0.0)))) \
				* Basis(Vector3.RIGHT, deg_to_rad(float(entry.get("pitch", 0.0)))) \
				* Basis.from_scale(_vec(entry.scale) if entry.has("scale") else kit_scale)
			p.transform = Transform3D(basis, _vec(entry.get("offset", [0, 0, 0])))
			if _by_id.has(p.id):
				push_error("ModuleCatalog: duplicate piece id " + p.id)
				continue
			_by_id[p.id] = p
			if not _by_socket.has(p.socket):
				_by_socket[p.socket] = []
			_by_socket[p.socket].append(p)


func _vec(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


## One kit material, rebuilt from the textures the manifest names. The kit's
## glTFs reference their PNGs by bare file name next to each glTF, and the
## download keeps them in a separate Textures folder, so the imported
## materials arrive untextured; these replace them by name.
func _build_material(name: String, spec: Dictionary, tex_dir: String) -> Material:
	var m: BaseMaterial3D = ORMMaterial3D.new() if spec.has("orm") else StandardMaterial3D.new()
	m.resource_name = name
	m.albedo_texture = load(tex_dir + String(spec.albedo))
	if spec.has("orm"):
		(m as ORMMaterial3D).orm_texture = load(tex_dir + String(spec.orm))
	else:
		m.roughness = 0.5
	if spec.has("normal"):
		m.normal_enabled = true
		m.normal_texture = load(tex_dir + String(spec.normal))
	return m


## `p`'s scene, cleaned and re-materialled once and then packed, so every
## later instance is a plain instantiate().
func _scene(p: Dictionary) -> PackedScene:
	if _scenes.has(p.id):
		return _scenes[p.id]
	var root: Node = (load(p.path) as PackedScene).instantiate()
	_clean(root, root, p.kit)
	var packed := PackedScene.new()
	packed.pack(root)
	root.free()
	_scenes[p.id] = packed
	return packed


func _clean(node: Node, root: Node, kit: String) -> void:
	for child in node.get_children():
		if STRIPPED.any(func(c: String) -> bool: return child.is_class(c)):
			node.remove_child(child)
			child.free()
			continue
		_clean(child, root, kit)
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		(node as MeshInstance3D).mesh = _fixed_mesh((node as MeshInstance3D).mesh, kit)


func _fixed_mesh(mesh: Mesh, kit: String) -> Mesh:
	var key := mesh.get_instance_id()
	if _fixed_meshes.has(key):
		return _fixed_meshes[key]
	var copy: Mesh = mesh.duplicate()
	for s in copy.get_surface_count():
		var mat := copy.surface_get_material(s)
		if mat != null and _materials.has("%s/%s" % [kit, mat.resource_name]):
			copy.surface_set_material(s, _materials["%s/%s" % [kit, mat.resource_name]])
	_fixed_meshes[key] = copy
	return copy
