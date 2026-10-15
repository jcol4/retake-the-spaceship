// An ADDITIVE layer (the muzzle flash) with per-pixel depth. See
// sprite_depth.gdshaderinc and unit_visual.gd ADDITIVE_LAYERS.
//
// Transparent and never depth-WRITING, but still depth-TESTED at the flash's
// real distance: the part of the flash behind the rifle is hidden by the
// rifle, the part in front is not, and a wall in front of the unit hides all of
// it. The stock additive material had to fake the first two by pulling the
// whole card a couple of centimetres in front of the body.
shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never, shadows_disabled;

#include "res://shaders/sprite_depth.gdshaderinc"

// LINEAR, as the stock additive material had it: a glow resampled with nearest
// is a staircase.
uniform sampler2D texture_albedo : source_color, filter_linear;
// unit_visual.gd ADDITIVE_GAIN: lifts the hot core over the glow threshold.
uniform float gain = 1.8;

void vertex() {
	sprite_billboard(MODELVIEW_MATRIX, VIEW_MATRIX, INV_VIEW_MATRIX, MODEL_MATRIX);
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	vec4 tex = texture(texture_albedo, UV);
	ALBEDO = tex.rgb * COLOR.rgb * gain;
	ALPHA = tex.a * COLOR.a;
	DEPTH = IN_SHADOW_PASS ? FRAGCOORD.z
		: sprite_depth(UV, VERTEX, NODE_POSITION_VIEW, MODEL_MATRIX, PROJECTION_MATRIX);
}
