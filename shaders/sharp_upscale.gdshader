shader_type canvas_item;
// Upscales PixelView's low-res buffer by a NON-INTEGER factor without the
// uneven columns plain nearest filtering gives (at 1.4x, some texels land on
// one screen pixel and some on two, and the pattern crawls as the camera pans).
//
// "Sharp bilinear": the UV is pulled toward the centre of whichever texel the
// screen pixel falls in, so the sample is a pure texel colour everywhere except
// a band one screen pixel wide at each texel boundary, where the hardware's
// linear filter blends the two neighbours. Needs the TextureRect's filter set to
// linear. At an integer scale on a pixel-aligned rect, every screen pixel centre
// sits outside the band, so it draws exactly what nearest would.

void fragment() {
	vec2 tex_size = 1.0 / TEXTURE_PIXEL_SIZE;
	vec2 px = UV * tex_size;
	// Half a screen pixel, in texels: the blend band reaches that far either
	// side of each boundary.
	vec2 band = max(fwidth(px) * 0.5, vec2(1e-5));
	vec2 f = fract(px);
	vec2 pulled = clamp(f * 0.5 / band, 0.0, 0.5)
		+ clamp((f - 1.0) * 0.5 / band + 0.5, 0.0, 0.5);
	COLOR = texture(TEXTURE, (floor(px) + pulled) / tex_size);
}
