extends Node3D
## Rough shot VFX: a tracer per round, an impact flash where a round or a swing
## connects, and the muzzle light that floods the shooter's room on every round.
## Spawned nodes free themselves when their tween completes.
##
## The tracer (see TRACER_SPEED) is not the old beam come back. THERE IS NO BEAM
## any more: it was a stand-in from before the character art existed, saying "a
## shot travelled" because nothing on the shooter showed it.
##
## The muzzle light (see MUZZLE_LIGHT_ENERGY) IS a room-filling light again, but
## not the old one. That was a white, shadowless 25 m OmniLight3D standing in for
## a missing flash; it lit every room on screen through the walls, evenly, and
## read as the screen flickering rather than a gun going off. This one is the
## bodycam look: warm, one pulse per round with dark between, and SHADOWED, so
## the walls keep it in the shooter's room, it spills out of doorways, and every
## body and crate throws a long shadow away from the gun. It is meant to blow the
## nearest surfaces out — that is the drama — and the barrel flash still sits on
## top of it.
##
## Tracers and impacts say which rounds CONNECTED. That is target-end feedback,
## not shooter-end decoration, and it is shared with melee.

## What a round or a swing leaves where it connects, by what it connected with
## (Unit.hit_style). FLASH is the old glowing puff, kept for every body that has
## no style of its own yet; FLESH is a blood spray and mist (the zombie tier).
enum HitStyle { FLASH, FLESH }

## How long an impact flash takes to fade out.
const FADE_DURATION := 0.28
const HIT_COLOR := Color(1.0, 0.9, 0.45)
const CRIT_COLOR := Color(1.0, 0.35, 0.2)
const FLASH_RADIUS := 0.28
const CRIT_FLASH_RADIUS := 0.44

# Shots land centre-mass. Where they LEAVE from is passed in by the caller —
# Unit reads the barrel tip off the rifle's bone attachment, so the origin
# follows the weapon through the animation instead of being assumed.
const CHEST_HEIGHT := 0.9

# Burst scatter. Rounds that land are nudged off the aim point by up to this, so
# a burst doesn't stack every impact on one pixel and read as a single shot.
# Metres of lateral scatter at the target, so the group opens with range on its
# own without any angle maths.
const CONE_TIGHT := 0.16


## Tracers -- NOT the old beam. That was a static line standing in for a shooter
## with no art; this is a short streak that TRAVELS, one per round, and it does
## the job nothing else on screen does: shows where each round went, misses
## included. Speed is far below a real round's so the eye can follow it, and
## still fast enough that the impact it delays lands with the body's jolt.
const TRACER_SHADER := preload("res://shaders/tracer.gdshader")
const TRACER_SPEED := 140.0
const TRACER_LENGTH := 2.2
## How far a round that missed flies on when nothing stops it.
const MISS_RANGE := 30.0
## A missed burst goes wide as ONE group: a single point off the target, picked
## once per burst (`miss_group`), with every round inside MISS_GROUP of it.
## The centre sits MISS_MIN-MISS_MAX off the target's chest, so even the round
## nearest the body (MISS_MIN - MISS_GROUP = 0.55 m) is visibly a miss.
const MISS_MIN := 0.8
const MISS_MAX := 1.15
const MISS_GROUP := 0.25
## How far below level the group may sit, radians off the line of fire's
## horizontal. Anywhere above or beside the target, never down into the deck.
const MISS_BELOW := deg_to_rad(25.0)
## Solid geometry a miss stops on: walls and cover (map_builder, layer 1).
const SOLID_MASK := 1
## The first stretch of a miss is not raycast, so the shooter's own cover (which
## it leans past) does not swallow the round at the barrel.
const RAY_SKIP := 1.0

## K (HUD) toggles this. Off, rounds draw no tracer; hit flashes are untouched.
## Static so it survives the VfxManager being rebuilt with the mission scene.
static var tracers_enabled := true

## Muzzle light: one warm, shadowed OmniLight3D pulse per round, from just ahead
## of the barrel. Starting values for the bodycam reference (a corridor flooded
## amber, nearest lockers blown out, far end still lit); tune by screenshot
## (tools/shot_muzzle_light.gd).
const MUZZLE_LIGHT_COLOR := Color(1.0, 0.64, 0.36)
## Peak energy at weapon scale 1. No tonemapper (main.tscn), so the nearest
## surfaces clip to a pale orange on purpose.
const MUZZLE_LIGHT_ENERGY := 16.0
## Metres. Long enough for a corridor; the shadows, not the range, keep it in
## the room.
const MUZZLE_LIGHT_RANGE := 18.0
## OmniLight3D.omni_attenuation: lower is flatter, a flood rather than a hotspot.
const MUZZLE_LIGHT_ATTENUATION := 0.3
## Haze the flash lights up (main.tscn has volumetric fog on). Kept low: the fog
## fills the void around the deck too, and at 3 the whole screen went brown —
## the old flood's "the screen flickered" read, back again.
const MUZZLE_LIGHT_FOG := 0.3
## Specular share. Low: at 1 every wall panel threw a blown-out hotspot, which
## reads as a lamp on the wall rather than the room filling with light.
const MUZZLE_LIGHT_SPECULAR := 0.2
## Ahead of the barrel along the bore, so the gun itself does not shadow the room.
const MUZZLE_LIGHT_AHEAD := 0.35
## Above the barrel. At barrel height the floor across the room takes the light
## at a graze and stays dark while the walls catch it all; lifted, the floor
## fills, and bodies still throw long shadows.
const MUZZLE_LIGHT_LIFT := 0.6
## Full energy for this long, then out over MUZZLE_LIGHT_FADE. Together under
## UnitVisual.BURST_CADENCE (0.11 s), so a burst strobes: lit, dark, lit.
const MUZZLE_LIGHT_HOLD := 0.035
const MUZZLE_LIGHT_FADE := 0.06
## Shadowed lights alive at once. A fourth shooter steals the oldest pulse, so
## the extra shadow cost is bounded however many guns go off.
const MUZZLE_LIGHT_POOL := 3

## FLESH hits. No glow at all: a realistic hit on a body is dark, not bright. A
## spray of droplets mostly out of the far side along the line of fire (the
## exit), some spatter back toward the shooter, and a red mist puff at the exit.
## Unshaded so they still read in a dark room from the tactical camera.
const BLOOD_COLOR := Color(0.42, 0.02, 0.03)
const BLOOD_MIST_COLOR := Color(0.38, 0.03, 0.03, 0.75)
## Droplets per hit, and per crit.
const BLOOD_DROPS := 12
const BLOOD_DROPS_CRIT := 22
## Share of the droplets thrown back toward the shooter, slower than the exit.
const BLOOD_BACK_SHARE := 0.25
## Half-angle of the exit cone round the line of fire.
const BLOOD_CONE := deg_to_rad(32.0)
## Metres/second a droplet leaves at.
const BLOOD_SPEED := Vector2(1.8, 4.0)
## Seconds a spray lives; droplets shrink away over the last BLOOD_SHRINK of it.
const BLOOD_TIME := 0.6
const BLOOD_SHRINK := 0.35
## Droplet radius, and how far one stretches into a streak at speed.
const BLOOD_DROP_RADIUS := 0.016
const BLOOD_STRETCH := 0.7
## Mist: diameter it puffs out from and to, and how long it takes to go.
const BLOOD_MIST_SIZE := Vector2(0.12, 0.5)
const BLOOD_MIST_TIME := 0.35
## Crit mist is this much bigger.
const BLOOD_CRIT_SCALE := 1.5
## Sprays alive at once; a horde under fire steals the oldest.
const BLOOD_MAX_SPRAYS := 24

static var _blood_drop_mesh: SphereMesh = null
static var _blood_mist_mesh: QuadMesh = null

## Live sprays: {mm: MultiMeshInstance3D, pos, vel: PackedVector3Array,
## size: PackedFloat32Array, floor: float, t: float}
var _blood_sprays: Array = []
## The spray's own generator. CPUParticles3D, and the global randf(), advance
## the generator seeded runs replay; blood must not shift a gameplay roll.
var _blood_rng := RandomNumberGenerator.new()

var _tracer_mesh: QuadMesh
var _tracer_material: ShaderMaterial
var _muzzle_lights: Array[OmniLight3D] = []
var _muzzle_tweens: Array = []  # Tween or null, parallel to _muzzle_lights
var _muzzle_next := 0


func _ready() -> void:
	add_to_group("vfx")
	_tracer_mesh = QuadMesh.new()
	_tracer_material = ShaderMaterial.new()
	_tracer_material.shader = TRACER_SHADER
	_blood_rng.randomize()


## Where a missed burst's group sits, picked once per burst and handed to every
## round's `shot_miss`: [angle round the line of fire, metres off the chest].
## Polar rather than a point because the line of fire is rebuilt per round from
## the barrel as the animation has it.
func miss_group() -> Vector2:
	return Vector2(randf_range(-MISS_BELOW, PI + MISS_BELOW), randf_range(MISS_MIN, MISS_MAX))


## A round of a burst that landed in nobody: a tracer (if `tracer`; Unit draws one
## every TRACER_EVERY rounds) thrown into the burst's `group` off the target at
## `to`, on past it, until a wall stops it. No flash -- one beside the target
## would read as a hit that did no damage -- so an untraced miss draws nothing.
func shot_miss(from: Vector3, to: Vector3, group: Vector2, tracer: bool = true) -> void:
	if not (tracer and tracers_enabled):
		return
	var aim := to + Vector3(0, CHEST_HEIGHT, 0)
	var along := aim - from
	if along.length_squared() < 0.0001:
		return
	var basis := _disc_basis(along)
	var centre := aim + (basis[0] * cos(group.x) + basis[1] * sin(group.x)) * group.y
	_spawn_tracer(from, _miss_end(from, centre + _cone_offset(along, MISS_GROUP)))


## A round of a burst that landed: one straight streak from the barrel into every
## body in `bodies` (feet positions, nearest first -- Penetration's path order),
## ending in the last. It passes any body the round missed on the way without a
## mark. Each body shows its hit as the streak reaches it; `crit_index` is the
## crit one, -1 for none. `styles` is each body's HitStyle, parallel to `bodies`
## (missing entries are FLASH). Untraced rounds still land after the same
## flight, so a burst keeps its rhythm whether or not each round is drawn.
func shot_through(from: Vector3, bodies: PackedVector3Array, crit_index: int = -1,
		tracer: bool = true, styles: PackedInt32Array = PackedInt32Array()) -> void:
	if bodies.is_empty():
		return
	var last := bodies[-1] + Vector3(0, CHEST_HEIGHT, 0)
	# The scatter cone is built perpendicular to the LINE OF FIRE, which is why
	# the impact has to know where the round came from.
	var end := last + _cone_offset(last - from, CONE_TIGHT)
	var dist := from.distance_to(end)
	if tracer and tracers_enabled:
		_spawn_tracer(from, end)
	var dir := (end - from) / maxf(dist, 0.0001)
	for i in bodies.size():
		var at := end
		if i < bodies.size() - 1:
			# Where the streak passes this body, kept on the body: the line runs
			# to the last body's chest, and a body beside a Bresenham line can sit
			# up to half a tile off it.
			var chest := bodies[i] + Vector3(0, CHEST_HEIGHT, 0)
			var on_line := from + dir * clampf((chest - from).dot(dir), 0.0, dist)
			at = chest + (on_line - chest).limit_length(CONE_TIGHT)
		var crit := i == crit_index
		var style := styles[i] if i < styles.size() else HitStyle.FLASH
		var travel := from.distance_to(at) / TRACER_SPEED
		var land := _spawn_hit.bind(at, dir, style, crit, bodies[i].y)
		if travel <= 0.0:
			land.call()
		else:
			get_tree().create_timer(travel, false).timeout.connect(land)


## Where a round aimed at `point` ends up: on past it, stopped by the first wall
## or cover in its way.
func _miss_end(from: Vector3, point: Vector3) -> Vector3:
	if from.distance_squared_to(point) < 0.0001:
		return point
	var dir := (point - from).normalized()
	var end := from + dir * MISS_RANGE
	if is_inside_tree():
		var start := from + dir * RAY_SKIP
		var query := PhysicsRayQueryParameters3D.create(start, end, SOLID_MASK)
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		if not hit.is_empty():
			end = hit.position
	return end


## Sends a tracer streak from `from` to `to`; returns how long the head takes to
## get there, so a caller can time the impact to its arrival.
func _spawn_tracer(from: Vector3, to: Vector3) -> float:
	var dist := from.distance_to(to)
	if dist < 0.05:
		return 0.0
	var tracer := MeshInstance3D.new()
	tracer.mesh = _tracer_mesh
	tracer.material_override = _tracer_material
	tracer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The shader places every vertex itself, so the node's own bounds are
	# meaningless; keep it from being culled while any of the line is in view.
	tracer.extra_cull_margin = dist + TRACER_LENGTH
	add_child(tracer)
	tracer.global_position = from
	var dir := (to - from) / dist
	var step := func(s: float) -> void:
		# `s` is how far the head WOULD be; it parks at the target and the tail
		# catches up to it, so the streak drains into the impact.
		tracer.set_instance_shader_parameter("head", from + dir * minf(s, dist))
		tracer.set_instance_shader_parameter("tail", from + dir * clampf(s - TRACER_LENGTH, 0.0, dist))
	step.call(0.0)
	var tween := tracer.create_tween()
	tween.tween_method(step, 0.0, dist + TRACER_LENGTH, (dist + TRACER_LENGTH) / TRACER_SPEED)
	tween.tween_callback(tracer.queue_free)
	return dist / TRACER_SPEED


func _cone_offset(along: Vector3, radius: float) -> Vector3:
	# A random point on a disc perpendicular to the shot, so the scatter is a
	# cone about the line of fire rather than a horizontal fan.
	var basis := _disc_basis(along)
	var angle := randf_range(0.0, TAU)
	# sqrt keeps the sample uniform over the disc instead of clustering at the
	# centre, so the spread looks like a group rather than a bullseye.
	var spread := radius * sqrt(randf())
	return (basis[0] * cos(angle) + basis[1] * sin(angle)) * spread


## [side, up]: unit axes of the disc perpendicular to `along`, `up` on the
## world-up side, so angle 0 is beside the target and PI/2 is over it.
func _disc_basis(along: Vector3) -> Array[Vector3]:
	var side := along.cross(Vector3.UP)
	if side.length_squared() < 0.0001:
		side = along.cross(Vector3.FORWARD)  # near-vertical shot: UP is degenerate
	side = side.normalized()
	return [side, side.cross(along.normalized())]


## A melee connection (or a grenade) at the feet position `at`: the same hit a
## landed shot leaves, without the scatter — one swing arrives at one place, so
## there is no group to open up. `dir` is the way the blow travelled (FLESH
## sprays out along it); zero picks a random sideways one.
func impact(at: Vector3, crit: bool = false, style: int = HitStyle.FLASH,
		dir: Vector3 = Vector3.ZERO) -> void:
	_spawn_hit(at + Vector3(0, CHEST_HEIGHT, 0), dir, style, crit, at.y)


## One hit's mark at chest point `at`, from a blow travelling along `dir`.
## `floor_y` is the deck under the body, where blood stops falling.
func _spawn_hit(at: Vector3, dir: Vector3, style: int, crit: bool, floor_y: float) -> void:
	if style == HitStyle.FLESH:
		_spawn_blood(at, dir, crit, floor_y)
	else:
		_spawn_flash(at, CRIT_COLOR if crit else HIT_COLOR,
			CRIT_FLASH_RADIUS if crit else FLASH_RADIUS)


## A FLESH hit: droplets out of the exit and back toward the shooter, and a red
## mist at the exit. Hand-rolled on a MultiMesh (see `_blood_rng`), stepped in
## `_process`.
func _spawn_blood(at: Vector3, dir: Vector3, crit: bool, floor_y: float) -> void:
	_ensure_blood_meshes()
	dir.y = clampf(dir.y, -0.3, 0.3)  # a round fired downhill still sprays out, not into the deck
	if dir.length_squared() < 0.0001:
		var a := _blood_rng.randf() * TAU
		dir = Vector3(cos(a), 0.0, sin(a))
	dir = dir.normalized()
	if _blood_sprays.size() >= BLOOD_MAX_SPRAYS:
		var oldest: Dictionary = _blood_sprays.pop_front()
		(oldest.mm as Node).queue_free()

	var n := BLOOD_DROPS_CRIT if crit else BLOOD_DROPS
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _blood_drop_mesh
	mm.instance_count = n
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "BloodSpray"
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Droplets move far from the node's origin; keep it from being culled.
	mmi.extra_cull_margin = 3.0
	add_child(mmi)
	mmi.global_transform = Transform3D.IDENTITY
	var basis := _disc_basis(dir)
	var spread := tan(BLOOD_CONE)
	var pos := PackedVector3Array()
	var vel := PackedVector3Array()
	var size := PackedFloat32Array()
	pos.resize(n)
	vel.resize(n)
	size.resize(n)
	for i in n:
		var back := _blood_rng.randf() < BLOOD_BACK_SHARE
		var a := _blood_rng.randf() * TAU
		var r := sqrt(_blood_rng.randf()) * spread * (1.6 if back else 1.0)
		var d := (dir * (-1.0 if back else 1.0) + (basis[0] * cos(a) + basis[1] * sin(a)) * r).normalized()
		var speed := _blood_rng.randf_range(BLOOD_SPEED.x, BLOOD_SPEED.y) * (0.45 if back else 1.0)
		vel[i] = d * speed + Vector3(0, 0.4, 0)
		pos[i] = at + d * 0.08
		size[i] = _blood_rng.randf_range(0.6, 1.3) * (1.2 if crit else 1.0)
		mm.set_instance_transform(i, _drop_transform(pos[i], vel[i], size[i], 1.0, false))
	_blood_sprays.append({"mm": mmi, "pos": pos, "vel": vel, "size": size,
		"floor": floor_y + 0.01, "t": 0.0})

	var mist := MeshInstance3D.new()
	mist.name = "BloodMist"
	mist.mesh = _blood_mist_mesh
	mist.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mist)
	mist.global_position = at + dir * 0.15
	var grow := BLOOD_CRIT_SCALE if crit else 1.0
	mist.scale = Vector3.ONE * BLOOD_MIST_SIZE.x * grow
	var tween := mist.create_tween().set_parallel()
	tween.tween_property(mist, "scale", Vector3.ONE * BLOOD_MIST_SIZE.y * grow, BLOOD_MIST_TIME) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	# Instance transparency, so every mist shares one material.
	tween.tween_property(mist, "transparency", 1.0, BLOOD_MIST_TIME) \
		.set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	tween.chain().tween_callback(mist.queue_free)


## A droplet streaked along its velocity in flight, a flat fleck once it is on
## the deck; `life` (1 -> 0) shrinks it away.
static func _drop_transform(pos: Vector3, vel: Vector3, size: float, life: float,
		landed: bool) -> Transform3D:
	var s := size * life
	if landed:
		return Transform3D(Basis.from_scale(Vector3(s * 1.6, s * 0.25, s * 1.6)), pos)
	var speed := vel.length()
	if speed < 0.001:
		return Transform3D(Basis.from_scale(Vector3.ONE * s), pos)
	var fwd := vel / speed
	var up := Vector3.RIGHT if absf(fwd.y) > 0.99 else Vector3.UP
	var stretch := 1.0 + speed * BLOOD_STRETCH
	return Transform3D(Basis.looking_at(fwd, up) * Basis.from_scale(Vector3(s, s, s * stretch)), pos)


func _ensure_blood_meshes() -> void:
	if _blood_drop_mesh != null:
		return
	var drop_mat := StandardMaterial3D.new()
	drop_mat.albedo_color = BLOOD_COLOR
	drop_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_blood_drop_mesh = SphereMesh.new()
	_blood_drop_mesh.radius = BLOOD_DROP_RADIUS
	_blood_drop_mesh.height = BLOOD_DROP_RADIUS * 2.0
	_blood_drop_mesh.radial_segments = 4
	_blood_drop_mesh.rings = 2
	_blood_drop_mesh.material = drop_mat

	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	g.add_point(0.4, Color(1, 1, 1, 0.55))
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(0.5, 0.0)
	tex.width = 64
	tex.height = 64
	var mist_mat := StandardMaterial3D.new()
	mist_mat.albedo_color = BLOOD_MIST_COLOR
	mist_mat.albedo_texture = tex
	mist_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mist_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mist_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mist_mat.billboard_keep_scale = true
	_blood_mist_mesh = QuadMesh.new()
	_blood_mist_mesh.size = Vector2.ONE
	_blood_mist_mesh.material = mist_mat


func _process(delta: float) -> void:
	if _blood_sprays.is_empty():
		return
	var gravity := Vector3(0, -9.8, 0) * delta
	for s: Dictionary in _blood_sprays:
		s.t += delta
		var mmi := s.mm as MultiMeshInstance3D
		if s.t >= BLOOD_TIME:
			mmi.queue_free()
			continue
		var life := clampf((BLOOD_TIME - s.t) / (BLOOD_TIME * BLOOD_SHRINK), 0.0, 1.0)
		var pos: PackedVector3Array = s.pos
		var vel: PackedVector3Array = s.vel
		var size: PackedFloat32Array = s.size
		var floor_y: float = s.floor
		var mm := mmi.multimesh
		for i in pos.size():
			var landed := vel[i] == Vector3.ZERO
			if not landed:
				vel[i] += gravity
				var p := pos[i] + vel[i] * delta
				if p.y <= floor_y:
					p.y = floor_y
					vel[i] = Vector3.ZERO
					landed = true
				pos[i] = p
			mm.set_instance_transform(i, _drop_transform(pos[i], vel[i], size[i], life, landed))
		s.pos = pos
		s.vel = vel
	_blood_sprays = _blood_sprays.filter(func(s: Dictionary) -> bool: return s.t < BLOOD_TIME)


func _spawn_flash(at: Vector3, color: Color, radius: float = FLASH_RADIUS) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 8
	mesh.rings = 4
	var flash := MeshInstance3D.new()
	flash.mesh = mesh
	flash.material_override = _flash_material(color)
	add_child(flash)
	flash.global_position = at
	_fade_and_free(flash)


func _fade_and_free(node: MeshInstance3D) -> void:
	var tween := create_tween()
	tween.tween_property(node.material_override, "albedo_color:a", 0.0, FADE_DURATION)
	tween.tween_callback(node.queue_free)


func _flash_material(color: Color) -> StandardMaterial3D:
	# One material per effect — the fade tween mutates it in place.
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	return material


## One round's muzzle light at `at` (the barrel tip), pushed MUZZLE_LIGHT_AHEAD
## along `bore`. `scale` is the weapon's (WeaponPresets.muzzle_light): energy
## scales with it, range with its square root. Cosmetic and per peer.
func muzzle_light(at: Vector3, bore: Vector3 = Vector3.ZERO, scale: float = 1.0) -> void:
	if scale <= 0.0:
		return
	var i := _muzzle_next
	_muzzle_next = (_muzzle_next + 1) % MUZZLE_LIGHT_POOL
	if i >= _muzzle_lights.size():
		_muzzle_lights.append(_make_muzzle_light())
		_muzzle_tweens.append(null)
	var light := _muzzle_lights[i]
	var tween: Tween = _muzzle_tweens[i]
	if tween and tween.is_valid():
		tween.kill()  # the oldest pulse is stolen
	var ahead := bore.normalized() * MUZZLE_LIGHT_AHEAD if bore.length_squared() > 0.0001 else Vector3.ZERO
	light.global_position = at + ahead + Vector3(0.0, MUZZLE_LIGHT_LIFT, 0.0)
	light.omni_range = MUZZLE_LIGHT_RANGE * sqrt(scale)
	light.light_energy = MUZZLE_LIGHT_ENERGY * scale
	light.visible = true
	tween = create_tween()
	tween.tween_interval(MUZZLE_LIGHT_HOLD)
	tween.tween_property(light, "light_energy", 0.0, MUZZLE_LIGHT_FADE) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	# Hidden, not just dark: a visible light at zero energy still renders shadows.
	tween.tween_callback(light.hide)
	_muzzle_tweens[i] = tween


## `rounds` muzzle lights `cadence` apart, without holding up the caller. For a
## shooter fog of war keeps off the screen: its burst plays instantly and draws
## nothing, but the light it throws still spills out of its room.
func muzzle_strobe(at: Vector3, rounds: int, cadence: float, scale: float = 1.0) -> void:
	if rounds <= 0 or scale <= 0.0:
		return
	muzzle_light(at, Vector3.ZERO, scale)
	if rounds == 1:
		return
	var tween := create_tween()
	for _i in rounds - 1:
		tween.tween_interval(cadence)
		tween.tween_callback(muzzle_light.bind(at, Vector3.ZERO, scale))


## Pool lights alive right now (tests).
func muzzle_lights_lit() -> int:
	var n := 0
	for light in _muzzle_lights:
		if light.visible:
			n += 1
	return n


func _make_muzzle_light() -> OmniLight3D:
	var light := OmniLight3D.new()
	light.name = "MuzzleLight%d" % (_muzzle_lights.size() + 1)
	light.light_color = MUZZLE_LIGHT_COLOR
	light.omni_attenuation = MUZZLE_LIGHT_ATTENUATION
	light.light_volumetric_fog_energy = MUZZLE_LIGHT_FOG
	light.light_specular = MUZZLE_LIGHT_SPECULAR
	light.shadow_enabled = true
	# Two shadow renders instead of six; the seam never shows in a 0.1 s pulse.
	light.omni_shadow_mode = OmniLight3D.SHADOW_DUAL_PARABOLOID
	light.shadow_blur = 0.1  # hard, like the fixtures
	light.visible = false
	add_child(light)
	return light
