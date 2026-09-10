shader_type spatial;
// A retro-CRT color-grade for the billboarded sprite layers (unit_visual.gd
// _build_layers): posterized levels broken up by an ordered dither instead of
// smooth gradients, desaturated toward a murky olive/amber, crushed contrast,
// and a film-grain overlay — the look of a 256-color isometric renderer
// pretending it has more depth than it does.
//
// Unshaded and alpha-discard, matching what AnimatedSprite3D's own material
// would have given it (shaded = false, alpha_cut = ALPHA_CUT_DISCARD) — this
// shader REPLACES that material via material_override, so both properties have
// to be reproduced here rather than inherited.
render_mode unshaded, cull_disabled;

uniform sampler2D texture_albedo : source_color, filter_nearest;
// Matches AnimatedSprite3D's own ALPHA_CUT_DISCARD: a hard cutoff rather than
// blending, so the sprite's edge stays crisp instead of picking up a soft
// halo from partially-transparent border pixels.
uniform float alpha_cutoff : hint_range(0.0, 1.0) = 0.5;

// --- Color grade --------------------------------------------------------
// 0 = untouched, 1 = fully toward tint_color. Fallout 1's palette reads as one
// murky hue family with the actual color doing the differentiating — this is
// what gets you there without just crushing everything to grey.
uniform float desaturate : hint_range(0.0, 1.0) = 0.55;
uniform vec3 tint_color : source_color = vec3(0.42, 0.40, 0.28);
// Pulled toward black/white around the midpoint. Fallout's shadows go dead
// black fast; a straight multiply doesn't do that, so this pivots around 0.5.
uniform float contrast : hint_range(0.5, 2.5) = 1.35;
// Multiplies the whole result down before the floor kicks in — lowers the
// ceiling as well as the floor, which is what "murky" actually means as
// opposed to just "dark".
uniform float brightness : hint_range(0.2, 1.5) = 0.92;

// --- Posterize + dither ---------------------------------------------------
// Levels PER CHANNEL. Real Fallout 1 art is indexed to a fixed palette, not
// posterized RGB, but this is the cheap approximation that still reads as
// "low color count" at game resolution. 6 is deliberately stingy — try 10-12
// for a softer, less crunchy version.
uniform int color_levels : hint_range(2, 32) = 6;
// How much the 4x4 Bayer threshold nudges a pixel before quantizing. 0 gives
// flat posterize bands; 1 gives full dithering. This is the single knob that
// makes it read as "dithered sprite" instead of "cheap Instagram filter".
uniform float dither_strength : hint_range(0.0, 1.0) = 0.65;

// --- Grain -----------------------------------------------------------------
uniform float grain_amount : hint_range(0.0, 0.3) = 0.06;
// 0 = grain locked to the pixel (static, like film scan noise baked into the
// sprite). >0 reseeds it over time — noisier and more "CRT interference",
// costs nothing until you turn it up.
uniform float grain_speed : hint_range(0.0, 20.0) = 0.0;

const mat4 BAYER4 = mat4(
	vec4(0.0,  8.0,  2.0, 10.0),
	vec4(12.0, 4.0, 14.0,  6.0),
	vec4(3.0, 11.0,  1.0,  9.0),
	vec4(15.0, 7.0, 13.0,  5.0)
) / 16.0;

float bayer_threshold(vec2 frag_coord) {
	int x = int(mod(frag_coord.x, 4.0));
	int y = int(mod(frag_coord.y, 4.0));
	return BAYER4[y][x] - 0.5; // centred on 0 so it can push either direction
}

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void fragment() {
	vec4 tex = texture(texture_albedo, UV);
	if (tex.a * COLOR.a < alpha_cutoff) {
		discard;
	}
	ALPHA = tex.a * COLOR.a;

	vec3 col = tex.rgb;

	// Desaturate toward the tint rather than toward grey, then grade.
	float luma = dot(col, vec3(0.299, 0.587, 0.114));
	col = mix(col, vec3(luma) * tint_color * 2.0, desaturate);
	col = (col - 0.5) * contrast + 0.5;
	col *= brightness;

	// Ordered dither, applied in linear steps of the target level count so the
	// nudge is exactly one quantization bucket wide — any bigger and it looks
	// noisy instead of like a dither pattern.
	float levels = float(color_levels);
	float step_size = 1.0 / levels;
	float dither = bayer_threshold(FRAGCOORD.xy) * step_size * dither_strength;
	col = clamp(col + dither, 0.0, 1.0);
	col = floor(col * levels + 0.5) / levels;

	// Grain last, after quantization, so it reads as scan noise sitting on top
	// of the flat color bands rather than as extra levels the posterize ate.
	vec2 grain_uv = FRAGCOORD.xy + (grain_speed > 0.0 ? vec2(TIME * grain_speed) : vec2(0.0));
	float grain = hash12(grain_uv) - 0.5;
	col += grain * grain_amount;

	ALBEDO = clamp(col, 0.0, 1.0) * COLOR.rgb;
}
