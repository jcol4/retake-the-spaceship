shader_type spatial;
// Out-of-sight floor (MapBuilder._update_sight_dim): one quad per explored tile
// where an enemy would NOT be drawn, laid just above the floor. It repaints what
// is already on screen behind it, darker and with most of its colour drained, so
// a lit room seen through a doorway reads as half-seen: the bright part is what
// the squad is looking at, the grey part is where something could be standing.
//
// A grade of the rendered image rather than a flat black film, so the floor's own
// lighting and detail survive — a dimmed tile under a lamp is still lighter than a
// dimmed tile in the dark, and the layout stays readable.
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform sampler2D screen_texture : hint_screen_texture, filter_nearest;
// What fraction of its brightness an unseen tile keeps.
uniform float brightness : hint_range(0.0, 1.0) = 0.4;
// How much of its colour it keeps: 0 is grey, 1 untouched.
uniform float saturation : hint_range(0.0, 1.0) = 0.15;

void fragment() {
	vec3 seen = textureLod(screen_texture, SCREEN_UV, 0.0).rgb;
	float luma = dot(seen, vec3(0.2126, 0.7152, 0.0722));
	ALBEDO = mix(vec3(luma), seen, saturation) * brightness;
	ALPHA = 1.0;
}
