shader_type spatial;
// The combat move range's XCOM-style border (HighlightManager.show_move_range):
// a bright line traced round the edge of a region, with a soft glow fading in
// from it, and nothing at all over the tiles inside.
//
// Drawn per TILE rather than as a polyline, from one MultiMesh. Every tile on a
// region's rim is one instance, and INSTANCE_CUSTOM says which of its sides and
// corners the rim runs along:
//   r  edge bits    1 north (-z)   2 east (+x)   4 south (+z)   8 west (-x)
//   g  corner bits  1 NE   2 SE   4 SW   8 NW  -- inside corners only, where both
//                   sides are in the region but the diagonal is not
//   b  zone         0 blue (can still shoot)   1 yellow (cannot)
// The fragment takes its distance to the nearest of those, which is the true
// distance to the rim for everything within a tile of it. That is what keeps the
// line continuous from one tile to the next and rounds its inside corners,
// without ever building the outline as geometry.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform float tile_size = 1.5;
uniform vec3 blue_color : source_color = vec3(0.25, 0.65, 1.0);
uniform vec3 yellow_color : source_color = vec3(1.0, 0.72, 0.12);
// All distances in fractions of a tile.
// How far in from the tile edge the line runs. Non-zero so the whole line falls
// inside the region's own tiles: where blue meets yellow only the blue tile
// draws, and a line centred on the shared edge would lose its outer half.
uniform float line_inset = 0.045;
uniform float line_half_width = 0.018;
// Just over main.tscn's glow_hdr_threshold (1.1) in the colour's brightest
// channel, so the line catches a faint halo of bloom without outshining the
// deck's own lights. 2.6 read as neon against the dark ship.
uniform float line_energy = 1.25;
uniform float glow_strength = 0.2;
uniform float glow_falloff = 0.09;
// A slow breathe on the inner glow only; the line itself holds steady.
uniform float pulse_amount = 0.15;
uniform float pulse_speed = 2.4;

varying vec2 v_local;
varying flat vec3 v_mask;

void vertex() {
	// 0..1 across the tile, x east and y south, whatever the mesh's own UVs are.
	v_local = VERTEX.xz / tile_size + 0.5;
	v_mask = INSTANCE_CUSTOM.rgb;
}

void fragment() {
	int edges = int(v_mask.r + 0.5);
	int corners = int(v_mask.g + 0.5);
	vec2 p = v_local;
	float d = 1e3;
	if ((edges & 1) != 0) { d = min(d, p.y); }
	if ((edges & 2) != 0) { d = min(d, 1.0 - p.x); }
	if ((edges & 4) != 0) { d = min(d, 1.0 - p.y); }
	if ((edges & 8) != 0) { d = min(d, p.x); }
	if ((corners & 1) != 0) { d = min(d, length(p - vec2(1.0, 0.0))); }
	if ((corners & 2) != 0) { d = min(d, length(p - vec2(1.0, 1.0))); }
	if ((corners & 4) != 0) { d = min(d, length(p - vec2(0.0, 1.0))); }
	if ((corners & 8) != 0) { d = min(d, length(p - vec2(0.0, 0.0))); }

	float aa = max(fwidth(d), 1e-4);
	float line = 1.0 - smoothstep(line_half_width - aa, line_half_width + aa, abs(d - line_inset));
	// Inward only: the glow fills the region side of the line and falls away
	// across it, and is faded out over the sliver between the line and the edge.
	float breathe = 1.0 - pulse_amount * (0.5 + 0.5 * sin(TIME * pulse_speed));
	float glow = glow_strength * breathe
		* exp(-max(d - line_inset, 0.0) / glow_falloff)
		* smoothstep(0.0, line_inset, d);

	vec3 color = v_mask.b < 0.5 ? blue_color : yellow_color;
	ALBEDO = color * (line * line_energy + glow);
}
