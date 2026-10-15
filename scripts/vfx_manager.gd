extends Node3D
## Rough shot VFX: an impact flash where a round or a swing connects. Spawned
## nodes free themselves when their tween completes.
##
## THERE IS NO TRACER AND NO MUZZLE LIGHT any more. Both were stand-ins from
## before the character art existed: the beam said "a shot travelled" because
## nothing on the shooter showed it, and the room-filling `OmniLight3D` said "a
## gun went off" for the same reason. The drawn `flash` sprite layer now says
## both, at the barrel, in the frame the kick lands on -- and it says it far
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


func _ready() -> void:
	add_to_group("vfx")


func shot_impact(from: Vector3, to: Vector3, hit: bool, crit: bool = false) -> void:
	# A round of a burst arriving. Misses draw NOTHING: with no beam there is no
	# near-miss to sell any more, and a flash beside the target would read as a
	# hit that did no damage rather than as a round sailing past.
	if not hit:
		return
	var end := to + Vector3(0, CHEST_HEIGHT, 0)
	# `from` outlives the beam it used to draw, because the scatter cone is built
	# perpendicular to the LINE OF FIRE — the impact still has to know where the
	# round came from even though nothing is drawn along the way.
	end += _cone_offset(end - from, CONE_TIGHT)
	_spawn_flash(end, CRIT_COLOR if crit else HIT_COLOR,
		CRIT_FLASH_RADIUS if crit else FLASH_RADIUS)


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
