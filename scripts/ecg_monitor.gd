class_name EcgMonitor
extends Control
## A heart-monitor trace for one soldier's vitals: the squad feed's health bar.
##
## Colour and rhythm carry the condition at a glance, the way a survival-horror
## status screen does it -- green and steady when fine, amber and quicker when
## hurt, red and ragged in danger, weak and erratic while bleeding out, flat
## when dead. The numbers live in `vitals()`, a pure function, so tests can pin
## the bands without a renderer.
##
## Drawn as a hospital sweep, not a scroll: a write head runs left to right
## overwriting the oldest trace, with a short blank gap ahead of it, and the
## trace fades with age. Purely presentation -- nothing reads it back.

enum Condition { FINE, CAUTION, DANGER, DOWNED, DEAD }

const COLORS := {
	Condition.FINE: Color(0.30, 1.00, 0.45),
	Condition.CAUTION: Color(1.00, 0.80, 0.20),
	Condition.DANGER: Color(1.00, 0.30, 0.20),
	Condition.DOWNED: Color(1.00, 0.15, 0.15),
	Condition.DEAD: Color(0.55, 0.15, 0.15),
}
const WORDS := {
	Condition.FINE: "FINE",
	Condition.CAUTION: "CAUTION",
	Condition.DANGER: "DANGER",
	Condition.DOWNED: "CRITICAL",
	Condition.DEAD: "FLATLINE",
}

## Pixels of trace written per second.
const SWEEP_SPEED := 55.0
## Blank pixels kept ahead of the write head.
const GAP := 6
## Trace baseline, as a fraction of the height from the top.
const BASELINE := 0.62

var condition: Condition = Condition.FINE
var bpm := 70.0
var amplitude := 1.0
## 0..1: how much each beat's spacing wanders.
var irregularity := 0.0
var color: Color = COLORS[Condition.FINE]
## Down pips in the bottom-right corner: `downs` of `down_pips` lit red.
var down_pips := 0
var downs := 0
const PIP_RADIUS := 3.5
const PIP_LIT := Color(1.0, 0.12, 0.1)
const PIP_DARK := Color(0.35, 0.08, 0.08, 0.6)

var _samples := PackedFloat32Array()
var _head := 0.0
var _phase := 0.0
## The rate the current beat is running at -- re-rolled once per beat, so an
## irregular rhythm skips between beats rather than shivering inside one.
var _beat_rate := 70.0 / 60.0
## Seconds left of a hit's arrhythmia burst.
var _shock := 0.0
var _flash := 0.0


## The trace's parameters for a soldier's state. `hp_fraction` is current over
## max HP; `downed_fraction` is the downed bar's fill (only read while downed).
static func vitals(life_state: int, hp_fraction: float, downed_fraction: float) -> Dictionary:
	if life_state == Unit.LifeState.DEAD:
		return {condition = Condition.DEAD, bpm = 0.0, amplitude = 0.0, irregularity = 0.0}
	if life_state == Unit.LifeState.DOWNED:
		# Weaker and faster as the bar drains.
		var f := clampf(downed_fraction, 0.0, 1.0)
		return {condition = Condition.DOWNED, bpm = lerpf(150.0, 105.0, f),
				amplitude = lerpf(0.25, 0.55, f), irregularity = 0.45}
	if hp_fraction > 0.66:
		return {condition = Condition.FINE, bpm = 70.0, amplitude = 1.0, irregularity = 0.03}
	if hp_fraction > 0.33:
		return {condition = Condition.CAUTION, bpm = 95.0, amplitude = 0.95, irregularity = 0.08}
	return {condition = Condition.DANGER, bpm = 125.0, amplitude = 0.85, irregularity = 0.25}


## One heartbeat, p in [0, 1): P wave, QRS complex, T wave.
static func pqrst(p: float) -> float:
	return _bump(p, 0.10, 0.025, 0.12) + _bump(p, 0.20, 0.010, -0.15) \
		+ _bump(p, 0.23, 0.012, 1.0) + _bump(p, 0.26, 0.012, -0.30) \
		+ _bump(p, 0.45, 0.040, 0.25)


static func _bump(p: float, centre: float, width: float, height: float) -> float:
	var d := (p - centre) / width
	return height * exp(-d * d)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	resized.connect(_resize_buffer)
	_resize_buffer()


func apply(v: Dictionary) -> void:
	condition = v.condition
	bpm = v.bpm
	amplitude = v.amplitude
	irregularity = v.irregularity
	color = COLORS[condition]


## A hit: force a beat now and run ragged for a moment.
func shock() -> void:
	if condition == Condition.DEAD:
		return
	_phase = 0.18
	_shock = 0.9
	_flash = 1.0


func _resize_buffer() -> void:
	var n := maxi(2, int(size.x))
	if _samples.size() == n:
		return
	_samples.resize(n)
	_samples.fill(0.0)
	_head = fmod(_head, n)


func _process(delta: float) -> void:
	var n := _samples.size()
	if n < 2:
		return
	_shock = maxf(0.0, _shock - delta)
	_flash = maxf(0.0, _flash - delta * 3.0)
	var start := int(_head)
	_head = fmod(_head + SWEEP_SPEED * delta, n)
	var steps := posmod(int(_head) - start, n)
	for i in steps:
		var v := 0.0
		if bpm > 0.0:
			var before := _phase
			_phase += _beat_rate / SWEEP_SPEED
			if _phase >= 1.0:
				_phase = fmod(_phase, 1.0)
			if _phase < before:
				_roll_beat()
			v = pqrst(_phase) * amplitude
			if _shock > 0.0:
				v += randf_range(-0.25, 0.25) * _shock
		v += randf_range(-0.025, 0.025)  # baseline noise, even on a flatline
		_samples[(start + i + 1) % n] = v
	queue_redraw()


func _roll_beat() -> void:
	var jitter := irregularity + (0.5 if _shock > 0.0 else 0.0)
	var rate := bpm * (1.0 + (0.35 if _shock > 0.0 else 0.0)) / 60.0
	_beat_rate = maxf(0.2, rate * (1.0 + randf_range(-jitter, jitter)))


func _draw() -> void:
	var n := _samples.size()
	var h := size.y
	var mid := h * BASELINE
	var reach := h * 0.55
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.05, 0.03, 0.85))
	var grid := Color(color.r, color.g, color.b, 0.08)
	var cell := 8.0
	var x := cell
	while x < size.x:
		draw_line(Vector2(x, 0), Vector2(x, h), grid)
		x += cell
	var y := fmod(mid, cell)
	while y < h:
		draw_line(Vector2(0, y), Vector2(size.x, y), grid)
		y += cell
	var head := int(_head)
	var width := 1.5 + _flash
	for i in range(1, n):
		var age := posmod(head - i, n)
		if age < 1 or age > n - GAP:
			continue
		var c := color
		c.a = clampf(1.0 - float(age) / n, 0.12, 1.0)
		draw_line(Vector2(i - 1, mid - _samples[i - 1] * reach),
				Vector2(i, mid - _samples[i] * reach), c, width)
	var dot := Vector2(head, mid - _samples[head % n] * reach)
	draw_circle(dot, 3.0, Color(color.r, color.g, color.b, 0.35))
	draw_circle(dot, 1.6, color.lightened(0.5))
	_draw_down_pips()


func set_downs(count: int, of: int) -> void:
	if count == downs and of == down_pips:
		return
	downs = count
	down_pips = of


## Drawn over the trace, so each sits on a dark backing to stay readable.
func _draw_down_pips() -> void:
	var step := PIP_RADIUS * 2.0 + 3.0
	for i in down_pips:
		var centre := Vector2(size.x - 6.0 - (down_pips - 1 - i) * step, size.y - 6.0)
		draw_circle(centre, PIP_RADIUS + 1.2, Color(0, 0, 0, 0.8))
		if i < downs:
			draw_circle(centre, PIP_RADIUS + 1.2, Color(PIP_LIT, 0.35))
			draw_circle(centre, PIP_RADIUS, PIP_LIT)
		else:
			draw_circle(centre, PIP_RADIUS, PIP_DARK)
