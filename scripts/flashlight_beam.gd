class_name FlashlightBeam
extends MeshInstance3D
## The visible ray thrown by a unit's rifle light (Sec 5.2): a hollow cone with
## its tip at the lens, drawn by flashlight_beam.gdshader, plus a blown-out dot
## on the lens itself.
##
## Cosmetic only. Which tiles a flashlight actually lights is LightingManager's
## business and it knows nothing about this mesh. The ray here is deliberately
## much tighter than the 90-degree gameplay cone — that full cone is still what
## the parent SpotLight3D washes the floor with, so the harsh core reads on top
## of a spill that remains honest about what the unit can see.
##
## Lives under the SpotLight3D so it always points down the light's -Z, and so
## toggling the light off hides the ray with it (visibility is inherited).

const SHADER := preload("res://shaders/flashlight_beam.gdshader")
const RADIAL_SEGMENTS := 24

## Metres. Keep in step with the parent SpotLight3D's spot_range.
@export var beam_length: float = 9.0
@export var lens_radius: float = 0.045
## Radius at the far end — atan(end_radius / beam_length) is the ray's
## half-angle, so 1.5 over 9.0 is about 9 degrees: a ray, not a wash.
@export var end_radius: float = 1.5
@export var beam_color: Color = Color(0.66, 0.8, 1.0)
@export var intensity: float = 0.55
## Higher dies out sooner; 1.0 would still be going at the far end.
@export var dissipate: float = 3.0
## Higher gives a thinner, harder core and a quicker fade to the cone's edge.
@export var edge_softness: float = 2.4
## Fraction of the length that keeps the extra punch nearest the barrel.
@export var hotspot: float = 0.18
@export var hot_gain: float = 1.2
## Metres of fade where the cone meets geometry.
@export var depth_fade: float = 0.7
## Width of the additive blob at the lens. 0 leaves it off.
@export var lens_glow_size: float = 0.22


func _ready() -> void:
	mesh = _cone()
	material_override = _beam_material()
	cast_shadow = SHADOW_CASTING_SETTING_OFF
	# The cone is built centred on its own origin, so push it half a length down
	# the light's -Z to put the tip at the lens. Rx(-90) is what turns the mesh's
	# +Y axis into that -Z.
	transform = Transform3D(Basis.from_euler(Vector3(-PI * 0.5, 0.0, 0.0)),
		Vector3(0.0, 0.0, -beam_length * 0.5))
	if lens_glow_size > 0.0:
		add_child(_lens_glow())


func _cone() -> CylinderMesh:
	# Open at both ends: a shell, not a solid. Caps would read as bright discs
	# sitting at the lens and hanging in mid-air at the far end.
	var cone := CylinderMesh.new()
	cone.top_radius = end_radius  # +Y is the far end once the node is rotated
	cone.bottom_radius = lens_radius
	cone.height = beam_length
	cone.radial_segments = RADIAL_SEGMENTS
	cone.rings = 1  # the shader's fade is linear in Y, so extra rings buy nothing
	cone.cap_top = false
	cone.cap_bottom = false
	return cone


func _beam_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("beam_color", beam_color)
	mat.set_shader_parameter("beam_length", beam_length)
	mat.set_shader_parameter("intensity", intensity)
	mat.set_shader_parameter("dissipate", dissipate)
	mat.set_shader_parameter("edge_softness", edge_softness)
	mat.set_shader_parameter("hotspot", hotspot)
	mat.set_shader_parameter("hot_gain", hot_gain)
	mat.set_shader_parameter("depth_fade", depth_fade)
	return mat


func _lens_glow() -> MeshInstance3D:
	# The bulb itself, blown out. A billboarded radial gradient rather than more
	# cone: at 20 cm across there is nothing for the volume fake to work with.
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.3, 1.0])
	gradient.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.3), Color(1, 1, 1, 0)])
	var tex := GradientTexture2D.new()
	tex.gradient = gradient
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 64
	tex.height = 64

	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.albedo_color = beam_color.lerp(Color.WHITE, 0.7)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.disable_receive_shadows = true

	var quad := QuadMesh.new()
	quad.size = Vector2(lens_glow_size, lens_glow_size)
	var node := MeshInstance3D.new()
	node.name = "LensGlow"
	node.mesh = quad
	node.material_override = mat
	node.cast_shadow = SHADOW_CASTING_SETTING_OFF
	# Back at the cone's tip: this node is centred on the cone, which sits half a
	# length down the beam, and the rotation above makes that direction -Y here.
	node.position = Vector3(0.0, -beam_length * 0.5, 0.0)
	return node
