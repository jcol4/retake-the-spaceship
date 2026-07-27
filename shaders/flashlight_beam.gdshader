shader_type spatial;
// The visible shaft of a rifle light (Sec 5.2). Drawn on a hollow cone whose
// tip sits at the lens; the shading fakes the dust hanging inside that cone so
// the shell reads as a solid volume — harsh at the barrel, dissipating to
// nothing further out.
//
// Additive and depth-write-free because it is light, not surface: it must
// brighten whatever is behind it and never occlude anything. Unlit for the same
// reason — a beam that took lighting would go dark in exactly the pitch-black
// rooms it exists for.
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec3 beam_color : source_color = vec3(0.66, 0.8, 1.0);
// Metres. Must match the mesh's height, or the fade lands in the wrong place.
uniform float beam_length = 9.0;
uniform float intensity = 1.35;
// Higher dies out sooner; 1.0 would still be going at the far end.
uniform float dissipate = 2.6;
// Higher gives a thinner, harder core and a quicker fade to the cone's edge.
uniform float edge_softness = 2.0;
// Fraction of the length that keeps the extra punch nearest the barrel.
uniform float hotspot = 0.18;
uniform float hot_gain = 1.6;
// Metres of fade where the cone meets geometry.
uniform float depth_fade = 0.7;
// Metres in front of the camera at which the cone fades out entirely. A unit
// walking toward the camera otherwise swallows it and floods the frame white.
uniform float camera_fade = 1.5;

uniform sampler2D depth_buffer : hint_depth_texture, filter_linear_mipmap;

// 0 at the lens, 1 at the far end.
varying float v_progress;

void vertex() {
	// The mesh is a cylinder running along local +Y, rotated by FlashlightBeam
	// so that +Y lies along the light's forward. VERTEX is model space here.
	v_progress = clamp(VERTEX.y / beam_length + 0.5, 0.0, 1.0);
}

void fragment() {
	// How much cone the eye is looking through: a full diameter down the middle,
	// nothing at the silhouette. This is what turns a shell into a volume, and
	// what keeps the ray's edges soft while its core stays harsh. abs() because
	// cull_disabled means back faces land here too.
	vec3 to_eye = normalize(-VERTEX);  // VERTEX is view space in fragment
	float thickness = pow(abs(dot(normalize(NORMAL), to_eye)), edge_softness);

	// Dissipation along the ray, with the first centimetres ramped in so the
	// cone's tip doesn't read as a hard disc floating at the lens.
	float along = pow(1.0 - v_progress, dissipate) * smoothstep(0.0, 0.03, v_progress);
	float core = 1.0 + hot_gain * (1.0 - smoothstep(0.0, hotspot, v_progress));

	// Soft-particle fade: the cone melts into whatever it lands on rather than
	// slicing through the floor, and vanishes entirely past a wall.
	float raw_depth = texture(depth_buffer, SCREEN_UV).x;
	vec4 scene = INV_PROJECTION_MATRIX * vec4(vec3(SCREEN_UV * 2.0 - 1.0, raw_depth), 1.0);
	scene.xyz /= scene.w;
	float contact = clamp((-scene.z + VERTEX.z) / depth_fade, 0.0, 1.0);
	contact *= smoothstep(0.0, camera_fade, -VERTEX.z);

	// Above 1.0 on purpose near the barrel — that is what the environment's
	// glow threshold picks up as bloom.
	ALBEDO = beam_color * intensity * core;
	ALPHA = thickness * along * contact;
}
