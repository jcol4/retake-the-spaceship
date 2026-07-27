extends Node3D
## Rough shot VFX: a fading tracer beam from shooter to target, plus an impact
## flash on hits. Spawned nodes free themselves when their tween completes.

const TRACER_DURATION := 0.28
const HIT_COLOR := Color(1.0, 0.9, 0.45)
const CRIT_COLOR := Color(1.0, 0.35, 0.2)
const MISS_COLOR := Color(0.55, 0.7, 0.85)
const BEAM_WIDTH := 0.05
const FLASH_RADIUS := 0.28
const CRIT_FLASH_RADIUS := 0.44

# Shots leave the shoulder and land centre-mass.
const MUZZLE_HEIGHT := 1.4
const CHEST_HEIGHT := 0.9

# Muzzle flash light — a brief, room-filling flood rather than a hot pool,
# so it reads as "the whole room strobed white" instead of a local glow.
const MUZZLE_FLASH_COLOR := Color(1.0, 1.0, 0.95)
const MUZZLE_FLASH_ENERGY := 10.0
const MUZZLE_FLASH_RANGE := 25.0
const MUZZLE_FLASH_DURATION := 0.12


func _ready() -> void:
	add_to_group("vfx")


func tracer(from: Vector3, to: Vector3, hit: bool, crit: bool = false) -> void:
	var start := from + Vector3(0, MUZZLE_HEIGHT, 0)
	var end := to + Vector3(0, CHEST_HEIGHT, 0)
	var color := (CRIT_COLOR if crit else HIT_COLOR) if hit else MISS_COLOR
	if not hit:
		# Throw misses wide so they visibly sail past instead of reading as hits.
		# A dodged "lucky miss" is thrown wide the same as any other miss —
		# from the outside it should still read as the shot missing.
		var along := end - start
		var side := along.cross(Vector3.UP).normalized()
		end += side * randf_range(-0.9, 0.9) + Vector3(0, randf_range(0.2, 0.8), 0)
	_spawn_beam(start, end, color)
	if hit:
		_spawn_flash(end, color, CRIT_FLASH_RADIUS if crit else FLASH_RADIUS)


func muzzle_flash(at: Vector3) -> void:
	var light := OmniLight3D.new()
	light.light_color = MUZZLE_FLASH_COLOR
	light.light_energy = MUZZLE_FLASH_ENERGY
	light.omni_range = MUZZLE_FLASH_RANGE
	light.omni_attenuation = 1.0  # even flood, not a hot falloff — fills the room
	light.shadow_enabled = false  # transient; not worth the shadow-map cost
	add_child(light)
	light.global_position = at + Vector3(0, MUZZLE_HEIGHT, 0)
	var tween := create_tween()
	tween.tween_property(light, "light_energy", 0.0, MUZZLE_FLASH_DURATION)
	tween.tween_callback(light.queue_free)


func _spawn_beam(start: Vector3, end: Vector3, color: Color) -> void:
	var length := start.distance_to(end)
	if length < 0.01:
		return
	var mesh := BoxMesh.new()
	mesh.size = Vector3(BEAM_WIDTH, BEAM_WIDTH, length)
	var beam := MeshInstance3D.new()
	beam.mesh = mesh
	beam.material_override = _beam_material(color)
	add_child(beam)
	beam.global_position = (start + end) * 0.5
	# The box is centred, so which end -Z points at doesn't matter. Swap the up
	# vector for near-vertical shots, where UP would be degenerate.
	var dir := (end - start).normalized()
	beam.look_at(end, Vector3.FORWARD if absf(dir.y) > 0.99 else Vector3.UP)
	_fade_and_free(beam)


func _spawn_flash(at: Vector3, color: Color, radius: float = FLASH_RADIUS) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 8
	mesh.rings = 4
	var flash := MeshInstance3D.new()
	flash.mesh = mesh
	flash.material_override = _beam_material(color)
	add_child(flash)
	flash.global_position = at
	_fade_and_free(flash)


func _fade_and_free(node: MeshInstance3D) -> void:
	var tween := create_tween()
	tween.tween_property(node.material_override, "albedo_color:a", 0.0, TRACER_DURATION)
	tween.tween_callback(node.queue_free)


func _beam_material(color: Color) -> StandardMaterial3D:
	# One material per effect — the fade tween mutates it in place.
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	return material
