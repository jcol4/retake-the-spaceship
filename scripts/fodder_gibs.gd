class_name FodderGibs
extends Node3D
## A Fodder body coming apart as it dies: the parts GibPlanner picked are cut
## off the mesh as it is posed at the moment of death, thrown as small rigid
## bodies, and left on the deck as static meshes once they settle. The body
## they came off falls as a Ragdoll that is missing them.
##
## PURELY VISUAL, exactly like Ragdoll (read its class comment): no tile, cover,
## sight line, path or rule ever reads any of this. Every body lives on
## Ragdoll.LAYER, which no game query includes — sight and lighting ray layer 1,
## picking 1/2, cover 3. The MASK includes layer 1 (and cover, 4) only so a part
## lands on the deck and stops at a wall: a mask decides what this body bumps
## into, never what a ray finds.
##
## Owned by UnitVisual, as its child, so a deck unload or a ship lift that frees
## the unit frees its parts with it. `clear` (a rewind) takes everything away;
## Ragdoll.clear restores the folded bones.
##
## How a part is cut, decided by the spike (see the GDD death section):
##   * the corpse: the part's root bone is drawn at Ragdoll.SEVERED_SCALE, which
##     folds its whole subtree into the joint; Ragdoll builds no bodies there;
##   * the part: ONE engine bake of the whole posed mesh
##     (bake_mesh_from_current_skeleton_pose keeps vertex order), then the
##     triangles whose vertices are mostly weighted to the part's subtree are
##     copied out (`_part_tris`, worked out once per mesh and cached);
##   * the seam: a dark stump cap on both sides, a spray and a floor decal.
## When the bake is unavailable (headless builds register no skins) the parts
## still fly, as bodies with no mesh.

## Ragdoll's layer: nothing the game asks about.
const LAYER := Ragdoll.LAYER
## Deck and walls (1), cover blocks (4), ragdolls and other parts, catch floors.
const MASK := 1 | 4 | Ragdoll.LAYER | Ragdoll.CATCH_LAYER

## Parts simulating at once, across every death. A death whose parts would go
## past it keeps only as many as fit (none: it falls whole).
const MAX_LIVE := 16
## Settled parts left lying on the decks. Past it the oldest is freed.
const MAX_KEPT := 40
static var live_count := 0
## Settled parts, oldest first: [mesh, decal-or-null] per entry.
static var _kept: Array = []

const SETTLE_DRIFT := 0.01
const SETTLE_WINDOW := 0.25
const SETTLE_WINDOWS := 2
const MIN_TIME := 0.6
## A part still moving after this long is frozen where it is.
const MAX_TIME := 2.5

## kg per part. Light enough to fly, heavy enough to land rather than skitter.
const MASS := {&"head": 4.5, &"arm_l": 3.5, &"arm_r": 3.5, &"leg_l": 9.0, &"leg_r": 9.0}
## How much of a part's speed goes straight up, so it arcs instead of skidding.
const LIFT := 0.45
const LINEAR_DAMP := 0.1
const ANGULAR_DAMP := 0.8
## Fraction of a vertex's skin weight that must be in a part for a triangle to
## go with it (averaged over its three corners).
const CUT_WEIGHT := 0.5

const BLOOD := Color(0.30, 0.015, 0.02)
## The cut faces: darker than the spray, and matte, so they read as a wound
## rather than a red ball.
const STUMP := Color(0.14, 0.01, 0.012)
const DECAL_SIZE := Vector3(1.3, 0.6, 1.3)
const PART_DECAL_SIZE := Vector3(0.5, 0.4, 0.5)

## mesh instance id -> {part root bone -> [{verts, index} per surface]}
static var _cut_cache: Dictionary = {}
static var _stump_mat: StandardMaterial3D = null
static var _decal_tex: Texture2D = null

## Per part: {part, body, mesh, root, speed, spin, settled, still, window, marks}
var _parts: Array = []
var _stumps: Array[Node] = []
var _catch: StaticBody3D = null
var _plan: Dictionary = {}
var _rng := RandomNumberGenerator.new()
var _time := 0.0
var _kicked := false
var _skel: Skeleton3D = null


## Cuts `plan`'s parts off `skel` as it is posed now and builds their bodies
## (not yet pushed — that waits a physics tick, see Ragdoll's 1 kg note).
## Returns the root bones of the parts that came off, for Ragdoll.start; empty
## when nothing did (the rig has no "gib" block, or the budget is spent), and
## the caller should free this node.
##
## MUST run before Ragdoll.start: the bake reads the pose the body died in,
## and start folds the severed bones away.
func sever(skel: Skeleton3D, plan: Dictionary, floor_y: float, rng_seed: int) -> PackedInt32Array:
	_skel = skel
	_plan = plan
	_rng.seed = rng_seed
	var severed := PackedInt32Array()
	var parts := Ragdoll.gib_parts(skel)
	if parts.is_empty():
		return severed
	var wanted: Array = []
	for e: Dictionary in plan.get("parts", []):
		if parts.has(e.part):
			wanted.append(e)
	var room := MAX_LIVE - live_count
	if wanted.size() > room:
		wanted = wanted.slice(0, maxi(room, 0))
	if wanted.is_empty():
		return severed

	# One bake per mesh, its arrays fetched once and shared by every part.
	var meshes: Array[MeshInstance3D] = []
	var baked: Array = []
	for n in skel.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.skin == null or not (mi.mesh is ArrayMesh) or not mi.visible:
			continue
		var b: ArrayMesh = mi.bake_mesh_from_current_skeleton_pose() if _can_bake() else null
		var surfaces: Array = []
		if b != null:
			for s in b.get_surface_count():
				surfaces.append(b.surface_get_arrays(s))
		meshes.append(mi)
		baked.append(surfaces)

	for e: Dictionary in wanted:
		var root: int = parts[e.part].bone
		var frame := _ortho(skel.global_transform * skel.get_bone_global_pose(root))
		var mesh := _cut(skel, meshes, baked, root, frame)
		var body := _make_body(e.part, frame, mesh, float(parts[e.part].stump))
		_parts.append({"part": e.part, "body": body, "mesh": body.get_node_or_null("mesh"),
			"root": root, "speed": float(e.speed), "spin": float(e.spin), "settled": false,
			"still": 0, "window": 0.0, "marks": Vector3.INF})
		severed.append(root)
		live_count += 1
		_add_corpse_stump(skel, root, float(parts[e.part].stump))
		_spray(frame.origin)
	# Parts of one body start out touching; they never knock each other apart.
	for i in _parts.size():
		for j in range(i + 1, _parts.size()):
			(_parts[i].body as RigidBody3D).add_collision_exception_with(_parts[j].body)
	_build_catch(skel.global_position, floor_y)
	_add_decal(Vector3(skel.global_position.x, floor_y, skel.global_position.z), DECAL_SIZE)
	return severed


## Keeps the parts from colliding with the ragdoll they came off — they start
## out overlapping it at the joint, and the solver's first act would be to blow
## them apart. Call right after Ragdoll.start.
func keep_apart(ragdoll_bodies: Array) -> void:
	for p: Dictionary in _parts:
		for b: Node in ragdoll_bodies:
			if b is PhysicsBody3D:
				(p.body as RigidBody3D).add_collision_exception_with(b)


## How many parts are still in the air.
func live_parts() -> int:
	return _parts.filter(func(p: Dictionary) -> bool: return not p.settled).size()


## The bodies still simulating (tests).
func part_bodies() -> Array:
	var out := []
	for p: Dictionary in _parts:
		if not p.settled and is_instance_valid(p.body):
			out.append(p.body)
	return out


## Takes it all away — parts, stumps, decals — for a rewind or a model rebuild.
## The bones come back with Ragdoll.clear.
func clear() -> void:
	_release()
	for s in _stumps:
		if is_instance_valid(s):
			s.queue_free()
	_stumps.clear()
	queue_free()


func _exit_tree() -> void:
	_release()


## Hands back the live budget for every part still in the air.
func _release() -> void:
	for p: Dictionary in _parts:
		if not p.settled:
			p.settled = true
			live_count = maxi(live_count - 1, 0)


# --- Cutting ---------------------------------------------------------------------


## Whether the engine bake can run here: headless builds register no skins,
## and the bake errors out on a skin with no skeleton.
static func _can_bake() -> bool:
	return DisplayServer.get_name() != "headless"


## The part under `root`, cut from each baked mesh into `frame`'s space, or null
## when nothing was baked.
func _cut(skel: Skeleton3D, meshes: Array[MeshInstance3D], baked: Array,
		root: int, frame: Transform3D) -> ArrayMesh:
	var out := ArrayMesh.new()
	var inv := frame.affine_inverse()
	for k in meshes.size():
		var mi := meshes[k]
		var b: Array = baked[k]
		if b.is_empty():
			continue
		var tris: Array = _part_tris(skel, mi, root)
		var xf := inv * mi.global_transform
		var nb := xf.basis.orthonormalized()
		for s in mini(b.size(), tris.size()):
			var cut: Dictionary = tris[s]
			var verts: PackedInt32Array = cut.verts
			if verts.is_empty():
				continue
			var src: Array = b[s]
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			var sv: PackedVector3Array = src[Mesh.ARRAY_VERTEX]
			var pos := PackedVector3Array()
			pos.resize(verts.size())
			for i in verts.size():
				pos[i] = xf * sv[verts[i]]
			arrays[Mesh.ARRAY_VERTEX] = pos
			var sn: Variant = src[Mesh.ARRAY_NORMAL]
			if sn is PackedVector3Array and (sn as PackedVector3Array).size() == sv.size():
				var nrm := PackedVector3Array()
				nrm.resize(verts.size())
				for i in verts.size():
					nrm[i] = (nb * (sn as PackedVector3Array)[verts[i]]).normalized()
				arrays[Mesh.ARRAY_NORMAL] = nrm
			var st: Variant = src[Mesh.ARRAY_TANGENT]
			if st is PackedFloat32Array and (st as PackedFloat32Array).size() == sv.size() * 4:
				var tan := PackedFloat32Array()
				tan.resize(verts.size() * 4)
				for i in verts.size():
					var o := verts[i] * 4
					var t := (nb * Vector3(st[o], st[o + 1], st[o + 2])).normalized()
					tan[i * 4] = t.x
					tan[i * 4 + 1] = t.y
					tan[i * 4 + 2] = t.z
					tan[i * 4 + 3] = st[o + 3]
				arrays[Mesh.ARRAY_TANGENT] = tan
			for slot in [Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2]:
				var su: Variant = src[slot]
				if su is PackedVector2Array and (su as PackedVector2Array).size() == sv.size():
					var uv := PackedVector2Array()
					uv.resize(verts.size())
					for i in verts.size():
						uv[i] = (su as PackedVector2Array)[verts[i]]
					arrays[slot] = uv
			arrays[Mesh.ARRAY_INDEX] = cut.index
			out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			# The bake carries no materials; the part wears the unit's own (so the
			# corpse tint reaches it too).
			out.surface_set_material(out.get_surface_count() - 1, mi.get_active_material(s))
	return out if out.get_surface_count() > 0 else null


## For each surface of `mi`, the triangles that go with the part under `root`:
## {verts: source vertex per new vertex, index: the part's own index buffer}.
## Depends only on the mesh's skin weights, never the pose, so it is worked out
## once per mesh and part and cached.
static func _part_tris(skel: Skeleton3D, mi: MeshInstance3D, root: int) -> Array:
	var key := mi.mesh.get_instance_id()
	var per_mesh: Dictionary = _cut_cache.get(key, {})
	if per_mesh.has(root):
		return per_mesh[root]
	var in_part := {}
	for bi in Ragdoll.part_bones(skel, root):
		in_part[bi] = true
	# Skin bind -> whether it drives a bone in the part. Mixamo binds by name.
	var skin := mi.skin
	var bind_in := PackedByteArray()
	bind_in.resize(skin.get_bind_count())
	for i in skin.get_bind_count():
		var bone := skin.get_bind_bone(i)
		var bname := skin.get_bind_name(i)
		if bname != &"":
			bone = skel.find_bone(bname)
		bind_in[i] = 1 if in_part.has(bone) else 0
	var am := mi.mesh as ArrayMesh
	var out: Array = []
	for s in am.get_surface_count():
		var a := am.surface_get_arrays(s)
		var bones: PackedInt32Array = a[Mesh.ARRAY_BONES] if a[Mesh.ARRAY_BONES] != null else PackedInt32Array()
		var weights: PackedFloat32Array = a[Mesh.ARRAY_WEIGHTS] if a[Mesh.ARRAY_WEIGHTS] != null else PackedFloat32Array()
		var nv := (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		var per := bones.size() / maxi(nv, 1)
		var w := PackedFloat32Array()
		w.resize(nv)
		if per > 0:
			for v in nv:
				var sum := 0.0
				for k in per:
					var bi := bones[v * per + k]
					if bi < bind_in.size() and bind_in[bi] == 1:
						sum += weights[v * per + k]
				w[v] = sum
		var src_index: PackedInt32Array = a[Mesh.ARRAY_INDEX] if a[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var remap := {}
		var verts := PackedInt32Array()
		var index := PackedInt32Array()
		var tri := 0
		while tri + 2 < src_index.size():
			var i0 := src_index[tri]
			var i1 := src_index[tri + 1]
			var i2 := src_index[tri + 2]
			tri += 3
			if (w[i0] + w[i1] + w[i2]) / 3.0 < CUT_WEIGHT:
				continue
			for vi in [i0, i1, i2]:
				if not remap.has(vi):
					remap[vi] = verts.size()
					verts.append(vi)
				index.append(remap[vi])
		out.append({"verts": verts, "index": index})
	per_mesh[root] = out
	_cut_cache[key] = per_mesh
	return out


# --- Bodies ------------------------------------------------------------------------


func _make_body(part: StringName, frame: Transform3D, mesh: ArrayMesh, stump_r: float) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.name = "gib_" + String(part)
	body.top_level = true
	body.mass = MASS.get(part, 4.0)
	body.collision_layer = LAYER
	body.collision_mask = MASK
	body.linear_damp = LINEAR_DAMP
	body.angular_damp = ANGULAR_DAMP
	var mat := PhysicsMaterial.new()
	mat.friction = 0.9
	mat.bounce = 0.1
	body.physics_material_override = mat
	var box := BoxShape3D.new()
	var cs := CollisionShape3D.new()
	var aabb := AABB(Vector3.ZERO, Vector3.ZERO)
	if mesh != null:
		aabb = mesh.get_aabb()
		var mi := MeshInstance3D.new()
		mi.name = "mesh"
		mi.mesh = mesh
		body.add_child(mi)
		# The part's own end of the cut, at its root bone's head (the body origin).
		mi.add_child(_stump_sphere(stump_r))
	else:
		# No bake (headless): a box the size of the stump, so the part still falls.
		aabb = AABB(Vector3(-stump_r, 0, -stump_r), Vector3(stump_r, stump_r * 3.0, stump_r) * 2.0)
	box.size = aabb.size.max(Vector3.ONE * 0.08)
	cs.shape = box
	cs.position = aabb.get_center()
	body.add_child(cs)
	add_child(body)
	body.global_transform = frame
	return body


## Pushes every part on its first physics tick (an impulse in the frame a body is
## made lands on the default 1 kg mass — Ragdoll's note).
func _kick() -> void:
	var radial: bool = _plan.get("radial", false)
	var from: Vector3 = _plan.get("from", Vector3.ZERO)
	var dir: Vector3 = _plan.get("dir", Vector3.ZERO)
	for p: Dictionary in _parts:
		var body := p.body as RigidBody3D
		var d := dir
		if radial:
			d = body.global_position - from
			d.y = maxf(d.y, 0.0)
			d = d.normalized() if d.length() > 0.01 else dir
		# A little scatter, so two parts going the same way do not fly together.
		d = (d + Vector3(_rng.randf_range(-0.25, 0.25), 0, _rng.randf_range(-0.25, 0.25))).normalized()
		var speed: float = p.speed
		body.linear_velocity = d * speed + Vector3.UP * speed * LIFT
		body.angular_velocity = Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1),
			_rng.randf_range(-1, 1)).normalized() * float(p.spin)


func _physics_process(delta: float) -> void:
	if _parts.is_empty():
		return
	if not _kicked:
		_kicked = true
		_kick()
		return
	_time += delta
	var any_live := false
	for p: Dictionary in _parts:
		if p.settled:
			continue
		var body := p.body as RigidBody3D
		if not is_instance_valid(body):
			p.settled = true
			live_count = maxi(live_count - 1, 0)
			continue
		p.window += delta
		if p.window >= SETTLE_WINDOW:
			p.window = 0.0
			var moved: bool = body.global_position.distance_to(p.marks) > SETTLE_DRIFT
			p.marks = body.global_position
			p.still = 0 if moved else int(p.still) + 1
		if (_time >= MIN_TIME and int(p.still) >= SETTLE_WINDOWS) or _time >= MAX_TIME:
			_settle_part(p)
		else:
			any_live = true
	if not any_live and _catch != null:
		_catch.queue_free()
		_catch = null


## The part stops being physics: its mesh stays where it lies, its body is freed,
## and it joins the kept list (oldest past MAX_KEPT is freed).
func _settle_part(p: Dictionary) -> void:
	p.settled = true
	live_count = maxi(live_count - 1, 0)
	var body := p.body as RigidBody3D
	var mesh := p.mesh as Node3D
	var decal: Decal = null
	if mesh != null and is_instance_valid(mesh):
		mesh.reparent(self, true)
		mesh.top_level = true
		var floor_y := _catch.global_position.y + 0.2 if _catch != null else body.global_position.y
		decal = _add_decal(Vector3(body.global_position.x, floor_y, body.global_position.z), PART_DECAL_SIZE)
		_kept.append([mesh, decal])
		_trim_kept()
	body.queue_free()


static func _trim_kept() -> void:
	_kept = _kept.filter(func(e: Array) -> bool: return is_instance_valid(e[0]))
	while _kept.size() > MAX_KEPT:
		var e: Array = _kept.pop_front()
		for n: Variant in e:
			if n != null and is_instance_valid(n):
				(n as Node).queue_free()


## How many settled parts are lying about (tests).
static func kept_count() -> int:
	_kept = _kept.filter(func(e: Array) -> bool: return is_instance_valid(e[0]) \
		and not (e[0] as Node).is_queued_for_deletion())
	return _kept.size()


## A floor under the parts that only ragdolls and parts touch (Ragdoll's catch,
## wider): a deck with no ground collision still has somewhere to land them.
func _build_catch(at: Vector3, floor_y: float) -> void:
	_catch = StaticBody3D.new()
	_catch.name = "gib_catch"
	_catch.top_level = true
	_catch.collision_layer = Ragdoll.CATCH_LAYER
	_catch.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(6.0, 0.4, 6.0)
	cs.shape = box
	_catch.add_child(cs)
	add_child(_catch)
	_catch.global_position = Vector3(at.x, floor_y - 0.2, at.z)


# --- Blood ---------------------------------------------------------------------------


## The corpse's end of the cut: a dark cap on the parent bone, at the joint the
## part folded into. Rides the ragdoll through a BoneAttachment3D.
func _add_corpse_stump(skel: Skeleton3D, root: int, r: float) -> void:
	var parent := skel.get_bone_parent(root)
	if parent < 0:
		return
	var att := BoneAttachment3D.new()
	att.name = "gib_stump_%d" % root
	att.bone_idx = parent
	skel.add_child(att)
	var parent_g := skel.global_transform * skel.get_bone_global_pose(parent)
	var joint := (skel.global_transform * skel.get_bone_global_pose(root)).origin
	var cap := _stump_sphere(r)
	att.add_child(cap)
	# The attachment carries the skeleton's scale; this undoes it for the cap.
	cap.transform = parent_g.affine_inverse() * Transform3D(Basis.IDENTITY, joint)
	_stumps.append(att)


static func _stump_sphere(r: float) -> MeshInstance3D:
	if _stump_mat == null:
		_stump_mat = StandardMaterial3D.new()
		_stump_mat.albedo_color = STUMP
		_stump_mat.roughness = 0.6
	var mi := MeshInstance3D.new()
	mi.name = "stump"
	var sm := SphereMesh.new()
	sm.radius = r * 0.85
	sm.height = r * 0.9
	sm.radial_segments = 10
	sm.rings = 5
	sm.material = _stump_mat
	mi.mesh = sm
	return mi


## Droplets per spray, how long one lasts, and how fast they leave.
const SPRAY_DROPS := 20
const SPRAY_TIME := 0.7
const SPRAY_SPEED := Vector2(1.0, 2.6)
static var _drop_mesh: SphereMesh = null

## Live sprays: {mm: MultiMeshInstance3D, pos, vel: PackedVector3Array, t: float}
var _sprays: Array = []


## A short spray where a part comes off. Hand-rolled on a MultiMesh rather than
## CPUParticles3D, which seeds its particles from the engine's GLOBAL generator
## (even with use_fixed_seed) — the one seeded runs replay, so a particle burst
## would shift every gameplay roll after a gib. tools/test_gibs.gd checks this.
func _spray(at: Vector3) -> void:
	if _drop_mesh == null:
		_drop_mesh = SphereMesh.new()
		_drop_mesh.radius = 0.018
		_drop_mesh.height = 0.036
		_drop_mesh.radial_segments = 4
		_drop_mesh.rings = 2
		var m := StandardMaterial3D.new()
		m.albedo_color = BLOOD
		_drop_mesh.material = m
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _drop_mesh
	mm.instance_count = SPRAY_DROPS
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "spray"
	mmi.top_level = true
	mmi.multimesh = mm
	add_child(mmi)
	mmi.global_transform = Transform3D.IDENTITY
	var pos := PackedVector3Array()
	var vel := PackedVector3Array()
	pos.resize(SPRAY_DROPS)
	vel.resize(SPRAY_DROPS)
	for i in SPRAY_DROPS:
		pos[i] = at
		# Up and out, within about 70° of straight up.
		var a := _rng.randf() * TAU
		var tilt := _rng.randf() * deg_to_rad(70.0)
		vel[i] = Vector3(cos(a) * sin(tilt), cos(tilt), sin(a) * sin(tilt)) \
			* _rng.randf_range(SPRAY_SPEED.x, SPRAY_SPEED.y)
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * _rng.randf_range(0.5, 1.0)), at))
	_sprays.append({"mm": mmi, "pos": pos, "vel": vel, "t": 0.0})


func _process(delta: float) -> void:
	if _sprays.is_empty():
		return
	for s: Dictionary in _sprays:
		s.t += delta
		var mmi := s.mm as MultiMeshInstance3D
		if s.t >= SPRAY_TIME:
			mmi.queue_free()
			continue
		var pos: PackedVector3Array = s.pos
		var vel: PackedVector3Array = s.vel
		var mm := mmi.multimesh
		for i in pos.size():
			vel[i] += Vector3(0, -9.8, 0) * delta
			pos[i] += vel[i] * delta
			var t := mm.get_instance_transform(i)
			t.origin = pos[i]
			mm.set_instance_transform(i, t)
		s.pos = pos
		s.vel = vel
	_sprays = _sprays.filter(func(s: Dictionary) -> bool: return s.t < SPRAY_TIME)


func _add_decal(at: Vector3, size: Vector3) -> Decal:
	if _decal_tex == null:
		var g := Gradient.new()
		g.set_color(0, Color(BLOOD, 0.9))
		g.set_color(1, Color(BLOOD, 0.0))
		g.add_point(0.55, Color(BLOOD, 0.75))
		var t := GradientTexture2D.new()
		t.gradient = g
		t.fill = GradientTexture2D.FILL_RADIAL
		t.fill_from = Vector2(0.5, 0.5)
		t.fill_to = Vector2(0.5, 0.0)
		t.width = 64
		t.height = 64
		_decal_tex = t
	var d := Decal.new()
	d.name = "blood"
	d.top_level = true
	d.texture_albedo = _decal_tex
	d.size = size
	add_child(d)
	d.global_transform = Transform3D(Basis(Vector3.UP, _rng.randf() * TAU), at)
	return d


static func _ortho(t: Transform3D) -> Transform3D:
	return Transform3D(t.basis.orthonormalized(), t.origin)
