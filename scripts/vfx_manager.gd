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
## Lateral miss distance at the target, so a miss is visibly a miss and never
## grazes the model. Metres, sampled between these.
const MISS_MIN := 0.55
const MISS_MAX := 1.1
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


## A round of a burst leaving the barrel: a flash where it lands if it landed,
## and a tracer if `tracer` (Unit draws one every TRACER_EVERY rounds). A miss
## leaves no flash -- one beside the target would read as a hit that did no
## damage -- so a miss without a tracer draws nothing at all.
func shot_impact(from: Vector3, to: Vector3, hit: bool, crit: bool = false,
		tracer: bool = true) -> void:
	tracer = tracer and tracers_enabled
	var aim := to + Vector3(0, CHEST_HEIGHT, 0)
	if not hit:
		if tracer:
			_spawn_tracer(from, _miss_end(from, aim))
		return
	# The scatter cone is built perpendicular to the LINE OF FIRE, which is why
	# the impact has to know where the round came from.
	var end := aim + _cone_offset(aim - from, CONE_TIGHT)
	# Untraced rounds still arrive after the same flight, so every flash in a
	# burst keeps the same rhythm whether or not its round was drawn.
	var travel := _spawn_tracer(from, end) if tracer else from.distance_to(end) / TRACER_SPEED
	var color := CRIT_COLOR if crit else HIT_COLOR
	var radius := CRIT_FLASH_RADIUS if crit else FLASH_RADIUS
	if travel <= 0.0:
		_spawn_flash(end, color, radius)
	else:
		get_tree().create_timer(travel, false).timeout.connect(_spawn_flash.bind(end, color, radius))


## Where a round that missed ends up: thrown wide of `aim`, on past it, and
## stopped by the first wall or cover in its way.
func _miss_end(from: Vector3, aim: Vector3) -> Vector3:
	var along := aim - from
	if along.length_squared() < 0.0001:
		return aim
	var wide := _cone_offset(along, 1.0)
	if wide.length_squared() < 0.0001:
		wide = along.cross(Vector3.UP)
	wide = wide.normalized() * randf_range(MISS_MIN, MISS_MAX)
	var dir := (aim + wide - from).normalized()
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
	var side := along.cross(Vector3.UP)
	if side.length_squared() < 0.0001:
		side = along.cross(Vector3.FORWARD)  # near-vertical shot: UP is degenerate
	side = side.normalized()
	var up := side.cross(along.normalized())
	var angle := randf_range(0.0, TAU)
	# sqrt keeps the sample uniform over the disc instead of clustering at the
	# centre, so the spread looks like a group rather than a bullseye.
	var spread := radius * sqrt(randf())
	return (side * cos(angle) + up * sin(angle)) * spread


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
