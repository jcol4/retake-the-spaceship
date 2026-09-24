// The soft dark patch under a unit's feet (unit_visual.gd CONTACT_SHADOW).
//
// A sprite placed exactly on the floor still reads as hovering when nothing
// ties it to the ground: in the ship's flat, tinted light a figure casts no
// shadow of its own, and the eye takes "no contact shadow" as "not touching".
// This is the standard fix, and the depth sidecars are what make it correct
// rather than approximate: the blob lies ON the floor and depth-tests against
// the sprite's real per-pixel depth, so a boot planted in front of the origin
// draws over it and the heel behind hides it, exactly as a 3D model would.
//
// MULTIPLIED onto what is below rather than painted: it can only darken, it
// darkens a dim floor proportionally less than a bright one, and it adds no
// light in an unlit corridor.
shader_type spatial;
render_mode unshaded, blend_mul, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

// How dark the centre gets: 0 is no shadow, 1 is black.
uniform float strength : hint_range(0.0, 1.0) = 0.45;
// Fraction of the radius, from the rim inward, over which it fades out.
uniform float softness : hint_range(0.01, 1.0) = 0.65;

void fragment() {
	float r = length(UV * 2.0 - 1.0);
	float cover = 1.0 - smoothstep(1.0 - softness, 1.0, r);
	ALBEDO = vec3(1.0 - strength * cover);
}
