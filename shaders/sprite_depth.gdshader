// An opaque character layer with per-pixel depth. See sprite_depth.gdshaderinc.
//
// Opaque with a scissor, exactly as AnimatedSprite3D draws a layer with
// shaded = false and alpha_cut = ALPHA_CUT_DISCARD: never writes ALPHA, so it
// stays in the opaque pass, writes depth, and has no sorting to get wrong.
shader_type spatial;
render_mode unshaded, cull_disabled;

#include "res://shaders/sprite_depth.gdshaderinc"

uniform sampler2D texture_albedo : source_color, filter_nearest;
// AnimatedSprite3D's own ALPHA_CUT_DISCARD threshold.
uniform float alpha_cut = 0.5;

void vertex() {
	sprite_billboard(MODELVIEW_MATRIX, VIEW_MATRIX, INV_VIEW_MATRIX, MODEL_MATRIX);
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	vec4 tex = texture(texture_albedo, UV);
	// COLOR is the sprite's `modulate` — the tile-light tint and faction tint.
	if (tex.a * COLOR.a < alpha_cut) {
		discard;
	}
	ALBEDO = tex.rgb * COLOR.rgb;
	// A shadow map is drawn from the LIGHT, and the sidecar's depths are along
	// the SPRITE CAMERA's axis — meaningless there. The card's own depth is
	// what the stock sprite casts, so shadows are unchanged by this shader.
	DEPTH = IN_SHADOW_PASS ? FRAGCOORD.z
		: sprite_depth(UV, VERTEX, NODE_POSITION_VIEW, MODEL_MATRIX, PROJECTION_MATRIX);
}
