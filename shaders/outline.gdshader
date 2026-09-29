shader_type spatial;
// Inverted-hull outline, used as a next_pass on character materials (see
// UnitVisual._outline_for). Front faces are culled, so only the back of a
// slightly inflated copy of the mesh draws — and only where it pokes out past
// the silhouette.
//
// Inflated in CLIP space by a fixed count of SCREEN pixels rather than in world
// space by metres: the camera zooms by Camera3D.size, so a world-space shell
// would thicken and thin with every scroll notch. VIEWPORT_SIZE is PixelView's
// low-res buffer, so thickness 1.0 is exactly one chunky pixel at every zoom.
//
// COLOURED BY THE SURFACE IT OUTLINES. The shell is the same mesh with the same
// UVs, so each outline texel samples the albedo of the model right beside it and
// draws it darkened — a boot gets a dark-brown edge, a skin panel a dark-flesh
// one, rather than one flat black line round everything.
//
// LIT, like the surface beside it. The shell's NORMAL is the model's own outward
// normal at that vertex (with cull_front there is no back-face flip), so a
// flashlight that lights an arm lights its edge too, and in a dark corridor the
// outline sinks into the dark with the model rather than glowing round it.
// Fully rough and non-specular: a 1-texel rim that caught highlights would
// sparkle as the unit turned.
//
// Needs smooth normals to close. Hard-edged meshes (the placeholder boxes) split
// at every corner, and the shell shows notches there.
render_mode cull_front;

// Mirrors of the host material's albedo, set by UnitVisual._outline_for.
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform sampler2D albedo_texture : source_color, hint_default_white, filter_nearest_mipmap;
uniform vec3 uv1_scale = vec3(1.0);
uniform vec3 uv1_offset = vec3(0.0);
// Multiplier on the surface colour: 0 is black, 1 is the colour itself.
uniform float darken : hint_range(0.0, 1.0) = 0.35;
uniform float thickness = 1.0;

void vertex() {
	UV = UV * uv1_scale.xy + uv1_offset.xy;
	vec4 clip = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	vec3 view_normal = (MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz;
	// Normalised in PIXEL space, so the shell is as thick horizontally as it is
	// vertically on a non-square buffer.
	vec2 dir = (PROJECTION_MATRIX * vec4(view_normal, 0.0)).xy * VIEWPORT_SIZE;
	if (dot(dir, dir) > 1e-8) {
		clip.xy += normalize(dir) * thickness * 2.0 / VIEWPORT_SIZE * clip.w;
	}
	POSITION = clip;
}

void fragment() {
	ALBEDO = albedo_color.rgb * texture(albedo_texture, UV).rgb * darken;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}
