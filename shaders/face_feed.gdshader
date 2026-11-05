// The squad feed's helmet-cam look: a low-res live view through a cheap
// transmitter. Scanlines, vignette, sensor noise and a tint, plus two event
// knobs the card drives -- `glitch` (a hit tears the signal for a moment) and
// `signal_lost` (static, for a dead or missing feed).
shader_type canvas_item;

uniform vec4 tint : source_color = vec4(0.85, 1.0, 0.9, 1.0);
uniform float scanlines : hint_range(0.0, 1.0) = 0.35;
uniform float vignette : hint_range(0.0, 2.0) = 0.9;
uniform float noise_amount : hint_range(0.0, 1.0) = 0.08;
uniform float glitch : hint_range(0.0, 1.0) = 0.0;
uniform float signal_lost : hint_range(0.0, 1.0) = 0.0;
// Source texel rows, so scanlines line up with the chunky pixels.
uniform float rows = 60.0;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void fragment() {
	vec2 uv = UV;
	float t = floor(TIME * 24.0);
	// Tearing: whole bands slide sideways, re-rolled 24 times a second.
	float band = floor(uv.y * 14.0);
	float tear = (hash(vec2(band, t)) - 0.5) * 0.18 * glitch * step(0.55, hash(vec2(t, band * 1.7)));
	uv.x += tear;
	float split = 0.012 * glitch;
	vec3 col;
	col.r = texture(TEXTURE, uv + vec2(split, 0.0)).r;
	col.g = texture(TEXTURE, uv).g;
	col.b = texture(TEXTURE, uv - vec2(split, 0.0)).b;
	col *= tint.rgb;
	// Scanlines on the texel grid.
	float line = 0.5 + 0.5 * cos(uv.y * rows * 6.28318);
	col *= 1.0 - scanlines * line * 0.5;
	// Sensor noise, heavier while glitching.
	float n = hash(floor(UV * vec2(rows * 1.333, rows)) + t);
	col += (n - 0.5) * (noise_amount + glitch * 0.25);
	// Static for a lost signal.
	col = mix(col, vec3(n * 0.8), signal_lost);
	// Vignette.
	vec2 d = UV - 0.5;
	col *= clamp(1.0 - dot(d, d) * vignette * 1.6, 0.0, 1.0);
	COLOR = vec4(col, 1.0);
}
