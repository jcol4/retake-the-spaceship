shader_type spatial;
// A bullet tracer streak: a quad stretched between `tail` and `head` (world
// space) and turned about that axis to face the camera, so it reads as a ribbon
// of light from any camera angle instead of going edge-on from above.
//
// Drawn on a unit QuadMesh. The node's transform is ignored -- every vertex is
// placed from the instance uniforms, so one mesh and one material serve every
// tracer (VfxManager sets these per instance).
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled,
	skip_vertex_transform, fog_disabled;

uniform vec4 color : source_color = vec4(1.0, 0.72, 0.32, 1.0);
// HDR multiplier, so the streak bites into the scene's glow.
uniform float energy = 4.0;
// Ribbon width in metres.
uniform float width = 0.07;

instance uniform vec3 head;
instance uniform vec3 tail;
instance uniform float fade = 1.0;

void vertex() {
	vec3 axis = head - tail;
	float len = length(axis);
	axis = len > 0.0001 ? axis / len : vec3(0.0, 0.0, 1.0);
	vec3 centre = (head + tail) * 0.5;
	vec3 to_cam = INV_VIEW_MATRIX[3].xyz - centre;
	vec3 side = cross(axis, to_cam);
	// Looking straight down the barrel: any perpendicular will do.
	if (dot(side, side) < 1e-8) {
		side = cross(axis, abs(axis.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0));
	}
	side = normalize(side);
	// QuadMesh spans -0.5..0.5 on X and Y; +Y is the head end.
	vec3 world = centre + axis * VERTEX.y * len + side * VERTEX.x * width;
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = normalize((VIEW_MATRIX * vec4(cross(side, axis), 0.0)).xyz);
}

void fragment() {
	// UV.y is 0 at the head and 1 at the tail: bright head, tapering tail.
	float along = pow(1.0 - UV.y, 1.6);
	float across = exp(-pow((UV.x - 0.5) * 5.0, 2.0));
	// White-hot core, coloured edges.
	float core = exp(-pow((UV.x - 0.5) * 12.0, 2.0)) * along;
	ALBEDO = mix(color.rgb, vec3(1.0), core * 0.8) * energy;
	ALPHA = clamp(along * across * fade, 0.0, 1.0);
}
