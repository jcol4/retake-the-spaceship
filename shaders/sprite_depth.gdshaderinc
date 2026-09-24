// Shared by sprite_depth.gdshader and sprite_depth_add.gdshader: a sprite card
// that depth-tests as the 3D model it was rendered from.
//
// render_sprites.py writes a DEPTH SIDECAR beside every frame, holding how far
// each pixel's surface sat in front of the world origin along the sprite
// camera's axis. unit_visual.gd anchors the card ON that origin (foot_anchor),
// so the node's own position is the model's ground point, and a pixel's true
// depth is simply the node's depth plus the sidecar. The camera is
// orthographic, so moving a fragment along the view axis changes its depth and
// nothing else — the pixel stays exactly where the render put it on screen.
//
// These shaders replace the sprite's whole material (material_override), so
// they restate everything AnimatedSprite3D's own material would have done: the
// Y-fixed billboard, keeping the node's scale (unit_visual.gd stretches the
// card vertically to undo the render's foreshortening), and no shading.

// `texture_albedo` is declared by each shader: the body wants nearest, the
// flash (a glow) wants linear. The depth texture is nearest in both.
//
// RAW data, never colour: no source_color (no sRGB decode) and nearest filter
// (interpolating between two pixels' high bytes is a different depth entirely).
uniform sampler2D texture_depth : filter_nearest, hint_default_black;
// World metres per canvas height at scale 1 — UnitVisual.canvas_height. The
// sidecar is in canvas heights so it survives a rescale; this converts back.
uniform float canvas_metres = 2.56;
// Half-range of the encoding in canvas heights. MIRRORS render_sprites.py
// DEPTH_RANGE.
uniform float depth_range = 2.0;
// False when the current frame has no sidecar (a stale depth build): the whole
// card then tests at the origin's depth rather than decoding a missing texture
// as "far behind" and vanishing under the floor.
uniform bool use_depth = true;

void sprite_billboard(inout mat4 modelview, mat4 view, mat4 inv_view, mat4 model) {
	// BaseMaterial3D's BILLBOARD_FIXED_Y with billboard_keep_scale, verbatim in
	// effect: face the camera about world Y only, then reapply the node's scale.
	modelview = view * mat4(
		vec4(normalize(cross(vec3(0.0, 1.0, 0.0), inv_view[2].xyz)), 0.0),
		vec4(0.0, 1.0, 0.0, 0.0),
		vec4(normalize(cross(inv_view[0].xyz, vec3(0.0, 1.0, 0.0))), 0.0),
		model[3]);
	modelview = modelview * mat4(
		vec4(length(model[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(model[1].xyz), 0.0, 0.0),
		vec4(0.0, 0.0, length(model[2].xyz), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0));
}

// Metres this pixel's surface sits in front of the node's origin, toward the
// camera (negative = behind).
float sprite_toward(vec2 uv, mat4 model) {
	if (!use_depth) {
		return 0.0;
	}
	vec3 texel = texture(texture_depth, uv).rgb;
	float code = (floor(texel.r * 255.0 + 0.5) * 256.0 + floor(texel.g * 255.0 + 0.5)) / 65535.0;
	// Horizontal scale, because the card maps 1:1 to the screen horizontally —
	// the vertical axis carries unit_visual.gd's foreshortening stretch, which
	// is about the card, not about the world size of what is drawn on it.
	return (code - 0.5) * 2.0 * depth_range * canvas_metres * length(model[0].xyz);
}

// The value to write to DEPTH for a fragment at view-space `vertex`.
float sprite_depth(vec2 uv, vec3 vertex, vec3 node_view, mat4 model, mat4 projection) {
	// View space looks down -Z, so toward the camera is +Z.
	vec4 clip = projection * vec4(vertex.xy, node_view.z + sprite_toward(uv, model), 1.0);
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	return clip.z / clip.w * 0.5 + 0.5;
#else
	return clip.z / clip.w;
#endif
}
