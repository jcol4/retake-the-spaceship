shader_type spatial;
// The merc's muzzle flash (merc.glb `muzzle_flash`), drawn as light. The mesh is
// a star and a lance of crossed planes; in the .blend its softness came from a
// render-time material the glTF export cannot carry, so it is rebuilt here:
// glow falls off with distance from the muzzle (the mesh origin) and with how
// edge-on a plane is to the camera, which is what turns flat quads into a glow.
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec4 color : source_color = vec4(1.0, 0.78, 0.45, 1.0);
// Above 1 so the core clears main.tscn's glow_hdr_threshold and blooms.
uniform float gain = 1.8;
// Mesh-local distance from the muzzle at which the glow has fully faded.
uniform float reach = 2.0;
// Drawn size against authored size, about the muzzle (the mesh origin). Here
// rather than on the node, because the node's scale is what `fire_shoot`
// animates.
uniform float size = 0.5;

varying float muzzle_distance;

void vertex() {
	muzzle_distance = length(VERTEX);
	VERTEX *= size;
}

void fragment() {
	float along = 1.0 - clamp(muzzle_distance / reach, 0.0, 1.0);
	float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float glow = along * along * smoothstep(0.05, 0.6, facing);
	ALBEDO = color.rgb * gain * glow;
}
