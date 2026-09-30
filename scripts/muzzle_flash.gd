class_name MuzzleFlash
extends Node3D
## The muzzle flash authored in assets/gun_vfx.blend, drawn as it was made there.
##
## Blender's version is two node materials (the star, `Muzzle Face`, and the
## lance, `Muzzle Side`) that glTF cannot carry, so tools/bake_muzzle_flash.py
## bakes each to an RGBA texture — colour in RGB, how much of it is there in A —
## and exports the mesh with them. This draws those textures as light: unshaded
## and additive, bright enough to clear main.tscn's glow_hdr_threshold (1.1).
##
## Mounted by UnitVisual on the rifle, at the transform of the merc model's own
## `muzzle_flash` node (which is hidden and kept only as the mount point). Origin
## on the barrel tip, -Z down the bore.

const SCENE := preload("res://assets/vfx/muzzle_flash.glb")
const SIDECAR := "res://assets/vfx/muzzle_flash.json"

## How much brighter than its baked colour the brightest material is drawn. The
## .blend's Emission strengths (200 / 59) are for an AgX render and would only
## clip here; this is the game's dial, and the sidecar keeps Blender's balance
## between the two materials under it.
const GAIN := 6.0
## Drawn size against authored size. At 1 the lance reaches most of a tile past
## the barrel.
const SIZE := 0.67

## Shared by every flash in the game — they never differ.
static var _materials: Dictionary = {}

var _mesh: MeshInstance3D = null
var _tween: Tween = null


func _ready() -> void:
	var inst := SCENE.instantiate() as Node3D
	add_child(inst)
	_mesh = inst.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for s in _mesh.mesh.get_surface_count():
		_mesh.set_surface_override_material(s, _material_for(_mesh.mesh.surface_get_material(s)))
	visible = false


## One round: the flash at full size on a fresh roll about the bore, so no two
## rounds of a burst draw the same star, shrinking to nothing over `duration` —
## the same collapse `fire_shoot` animates in merc_anim.blend.
func fire(duration: float) -> void:
	if _tween:
		_tween.kill()
	visible = true
	_mesh.rotation.z = randf() * TAU
	_mesh.scale = Vector3.ONE * SIZE
	_tween = create_tween()
	_tween.tween_property(_mesh, "scale", Vector3.ZERO, duration) \
		.set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	_tween.tween_callback(hide)


## The imported material swapped for one that draws its baked texture as light,
## at GAIN scaled by that material's share of the .blend's Emission strength.
static func _material_for(src: Material) -> StandardMaterial3D:
	var key := src.resource_name if src else ""
	var mat: StandardMaterial3D = _materials.get(key)
	if mat:
		return mat
	mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.disable_receive_shadows = true
	var base := src as BaseMaterial3D
	if base:
		mat.albedo_texture = base.albedo_texture
	var gain := GAIN * _strength_share(key)
	mat.albedo_color = Color(gain, gain, gain)
	_materials[key] = mat
	return mat


## `material`'s Emission strength as a fraction of the strongest one's.
static func _strength_share(material: String) -> float:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(SIDECAR))
	var strengths: Dictionary = parsed.get("emission_strength", {}) if parsed is Dictionary else {}
	if strengths.is_empty() or not strengths.has(material):
		return 1.0
	var top := 0.0
	for s: Variant in strengths.values():
		top = maxf(top, float(s))
	return float(strengths[material]) / top if top > 0.0 else 1.0
