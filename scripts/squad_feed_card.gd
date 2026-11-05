class_name SquadFeedCard
extends PanelContainer
## One soldier in the squad feed (top-left of the mission HUD): a live helmet-cam
## of their face over a heart-monitor trace of their vitals.
##
## Reads the unit by POLLING, not signals: a co-op client never hears
## `hp_changed` for a squadmate -- the numbers arrive by replication -- so the
## card compares against what it last showed, every frame, which is a handful
## of int reads. A drop in HP (or in the downed bar) is a hit: the ECG jolts
## and the feed tears.
##
## Clicking selects the soldier, under the same rules the old portrait buttons
## had: your own, standing ones only.

const FEED_SIZE := Vector2(120, 90)
const ECG_SIZE := Vector2(150, 52)
const BORDER_IDLE := Color(0.25, 0.32, 0.30)
const BORDER_ACTIVE := Color(0.55, 1.0, 0.65)
const BORDER_PARTNER := Color(0.40, 0.40, 0.45)
const FEED_SHADER := preload("res://shaders/face_feed.gdshader")

var unit: Unit
var selectable := false

var _feed: FaceFeed
var _feed_material: ShaderMaterial
var _ecg: EcgMonitor
var _name_label: Label
var _detail_label: Label
var _ap_bar: ApBar
var _style: StyleBoxFlat
var _rec: Label

var _last_hp := -1
var _last_downed_hp := -1
var _last_state := -1
var _glitch := 0.0
var _rec_clock := 0.0


func setup(for_unit: Unit, live_feed: bool) -> void:
	unit = for_unit
	name = "Card_%s" % unit.name
	mouse_filter = Control.MOUSE_FILTER_STOP
	_style = StyleBoxFlat.new()
	_style.bg_color = Color(0.03, 0.05, 0.05, 0.82)
	_style.set_border_width_all(2)
	_style.border_color = BORDER_IDLE
	_style.set_content_margin_all(4)
	_style.set_corner_radius_all(2)
	add_theme_stylebox_override("panel", _style)

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 6)
	add_child(row)

	# The feed, with a REC dot and name plate laid over it.
	var feed_box := Control.new()
	feed_box.custom_minimum_size = FEED_SIZE
	feed_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	feed_box.clip_contents = true
	row.add_child(feed_box)
	if live_feed:
		_feed = FaceFeed.new()
		_feed.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		feed_box.add_child(_feed)
		_feed.setup(unit)
		_feed_material = ShaderMaterial.new()
		_feed_material.shader = FEED_SHADER
		_feed_material.set_shader_parameter("rows", float(FaceFeed.RES.y))
		_feed.material = _feed_material
	else:
		var blank := ColorRect.new()
		blank.color = Color(0.05, 0.07, 0.07)
		blank.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		blank.mouse_filter = Control.MOUSE_FILTER_IGNORE
		feed_box.add_child(blank)
	_rec = Label.new()
	_rec.text = "● REC"
	_rec.position = Vector2(4, 2)
	_rec.add_theme_font_size_override("font_size", 10)
	_rec.add_theme_color_override("font_color", Color(1, 0.25, 0.2))
	_rec.add_theme_color_override("font_outline_color", Color.BLACK)
	_rec.add_theme_constant_override("outline_size", 3)
	_rec.mouse_filter = Control.MOUSE_FILTER_IGNORE
	feed_box.add_child(_rec)

	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 2)
	row.add_child(column)
	_name_label = _small_label(13)
	column.add_child(_name_label)
	_ecg = EcgMonitor.new()
	_ecg.custom_minimum_size = ECG_SIZE
	column.add_child(_ecg)
	var ap_row := HBoxContainer.new()
	ap_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ap_row.add_theme_constant_override("separation", 4)
	column.add_child(ap_row)
	var ap_label := _small_label(10)
	ap_label.text = "AP"
	ap_label.add_theme_color_override("font_color", ApBar.FILL)
	ap_row.add_child(ap_label)
	_ap_bar = ApBar.new()
	_ap_bar.custom_minimum_size = Vector2(ECG_SIZE.x - 20.0, 10.0)
	_ap_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ap_row.add_child(_ap_bar)
	_detail_label = _small_label(10)
	_detail_label.add_theme_color_override("font_color", Color(0.7, 0.75, 0.75))
	column.add_child(_detail_label)

	_poll()


func _small_label(font_size: int) -> Label:
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", font_size)
	return label


## Called on the HUD's poll: the slower-changing parts -- who is active, whose
## soldier this is, what they carry.
func refresh(is_active: bool, mine: bool) -> void:
	if not is_instance_valid(unit):
		return
	selectable = mine and not unit.is_downed
	if is_active:
		_style.border_color = BORDER_ACTIVE
	elif not mine:
		_style.border_color = BORDER_PARTNER
	else:
		_style.border_color = BORDER_IDLE
	_rec.visible = is_active and unit.life_state != Unit.LifeState.DEAD
	if _feed:
		_feed.active = is_active
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if selectable else Control.CURSOR_ARROW
	_detail_label.text = "+%s" % unit.carrying.stats.display_name if unit.carrying != null else ""
	_detail_label.visible = unit.carrying != null


func _process(delta: float) -> void:
	if not is_instance_valid(unit):
		return
	_poll()
	if _glitch > 0.0:
		_glitch = maxf(0.0, _glitch - delta * 2.5)
		if _feed_material:
			_feed_material.set_shader_parameter("glitch", _glitch)
	if _rec.visible:
		_rec_clock += delta
		_rec.modulate.a = 1.0 if fmod(_rec_clock, 1.0) < 0.6 else 0.25


func _poll() -> void:
	_ap_bar.show_ap(unit.ap, unit.ap_pool(), unit.life_state == Unit.LifeState.ACTIVE)
	_ecg.set_downs(unit.down_count, Unit.MAX_DOWNS)
	var hp := unit.current_hp
	var downed_hp := unit.downed_hp
	var state := int(unit.life_state)
	if hp == _last_hp and downed_hp == _last_downed_hp and state == _last_state:
		return
	var hurt := (_last_hp >= 0 and hp < _last_hp) \
		or (_last_downed_hp >= 0 and state == _last_state and downed_hp < _last_downed_hp) \
		or (_last_state == Unit.LifeState.ACTIVE and state == Unit.LifeState.DOWNED)
	_last_hp = hp
	_last_downed_hp = downed_hp
	_last_state = state

	var max_hp := maxi(1, unit.stats.max_hp())
	var v := EcgMonitor.vitals(state, float(hp) / max_hp,
			float(downed_hp) / unit.downed_bar_max())
	_ecg.apply(v)
	if hurt:
		_ecg.shock()
		_glitch = 1.0
	# No words or numbers: the trace's colour and rhythm are the health bar.
	_name_label.text = unit.stats.display_name.to_upper()
	if _feed:
		var dead := state == Unit.LifeState.DEAD
		_feed.frozen = dead
		_feed_material.set_shader_parameter("signal_lost", 0.85 if dead else 0.0)
		_feed_material.set_shader_parameter("tint", Color(1.0, 0.75, 0.7) \
				if state == Unit.LifeState.DOWNED else Color(0.85, 1.0, 0.9))


## The AP meter: one tick per point of the soldier's pool, so the ticks get
## narrower for a bigger pool and the bar keeps its width. Ticks still held are
## lit; spent ones are dim outlines. Redraws only when the numbers change.
class ApBar extends Control:
	const FILL := Color(0.35, 0.85, 1.0)
	const EMPTY := Color(0.35, 0.85, 1.0, 0.18)
	const GAP := 2.0

	var _ap := -1
	var _pool := -1
	var _live := true

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func show_ap(ap: int, pool: int, live: bool) -> void:
		# A bonus can lift AP over the pool; the bar grows to hold it.
		pool = maxi(maxi(pool, ap), 1)
		if ap == _ap and pool == _pool and live == _live:
			return
		_ap = ap
		_pool = pool
		_live = live
		queue_redraw()

	func _draw() -> void:
		if _pool <= 0:
			return
		var w := (size.x - GAP * (_pool - 1)) / _pool
		for i in _pool:
			var r := Rect2(i * (w + GAP), 0.0, maxf(w, 1.0), size.y)
			if i < _ap and _live:
				draw_rect(r, FILL)
			else:
				draw_rect(r, EMPTY)
				draw_rect(r, Color(FILL, 0.35), false, 1.0)


func _gui_input(event: InputEvent) -> void:
	var click := event as InputEventMouseButton
	if click and click.pressed and click.button_index == MOUSE_BUTTON_LEFT and selectable:
		TurnManager.select(unit)
		accept_event()
