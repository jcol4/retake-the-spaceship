extends Node3D
## Rough shot VFX: a tracer per round, and an impact flash where a round or a
## swing connects. Spawned nodes free themselves when their tween completes.
##
## The tracer (see TRACER_SPEED) is not the old beam come back. THERE IS NO BEAM
## AND NO MUZZLE LIGHT any more. Both were stand-ins from
## before the character art existed: the beam said "a shot travelled" because
## nothing on the shooter showed it, and the room-filling `OmniLight3D` said "a
## gun went off" for the same reason. The muzzle flash (MuzzleFlash) now says
## both, at the barrel, on the round the kick lands on -- and it says it far
## better than a 10-energy white flood, which blew out the whole room and took
## the flash it was supposed to be selling with it.
##
## What is left is the one thing neither of those was doing: saying which rounds
## CONNECTED. That is target-end feedback, not shooter-end decoration, and it is
## shared with melee, which never had a beam to begin with.

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

var _tracer_mesh: QuadMesh
var _tracer_material: ShaderMaterial


func _ready() -> void:
	add_to_group("vfx")
	_tracer_mesh = QuadMesh.new()
	_tracer_material = ShaderMaterial.new()
	_tracer_material.shader = TRACER_SHADER


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
## mark. Each body flashes as the streak reaches it; `crit_index` is the one in
## crit colour, -1 for none. Untraced rounds still flash after the same flight,
## so a burst keeps its rhythm whether or not each round is drawn.
func shot_through(from: Vector3, bodies: PackedVector3Array, crit_index: int = -1,
		tracer: bool = true) -> void:
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
		var color := CRIT_COLOR if crit else HIT_COLOR
		var radius := CRIT_FLASH_RADIUS if crit else FLASH_RADIUS
		var travel := from.distance_to(at) / TRACER_SPEED
		if travel <= 0.0:
			_spawn_flash(at, color, radius)
		else:
			get_tree().create_timer(travel, false).timeout.connect(_spawn_flash.bind(at, color, radius))


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


func impact(at: Vector3, crit: bool = false) -> void:
	# A melee connection: the same flash a landed shot leaves behind, without the
	# scatter — one swing arrives at one place, so there is no group to open up.
	_spawn_flash(at + Vector3(0, CHEST_HEIGHT, 0), CRIT_COLOR if crit else HIT_COLOR,
		CRIT_FLASH_RADIUS if crit else FLASH_RADIUS)


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
