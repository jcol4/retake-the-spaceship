class_name MissionMenu
extends CanvasLayer
## The in-mission Esc menu, on every peer (MULTIPLAYER_PLAN.md §2.4): Resume,
## sound/fullscreen settings, and Leave. Built in code like the other overlays.
##
##   Solo         opening it pauses the game. Leave is ironman: the save still
##                holds the mission, and the next Continue books the squad lost.
##   Co-op host   the menu does not pause anyone by itself; "Pause for everyone"
##                does (CoopLobby.set_paused — the host's power alone). Leave
##                stops the mission for the party; the round-start checkpoint is
##                what they resume from.
##   Co-op guest  a local overlay. Leave drops this player out; their soldiers
##                stay with the host and they can rejoin.
##
## A "PAUSED BY THE HOST" banner shows on every peer while the host has it paused.
## Runs while the tree is paused (PROCESS_MODE_ALWAYS), or it could not unpause it.

const LAYER := 20

var _panel: Control
var _pause_button: Button
var _leave_button: Button
var _banner: Label
var _leave_armed := false


func _ready() -> void:
	layer = LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	_panel.visible = false
	CoopLobby.paused_changed.connect(_on_paused_changed)
	_on_paused_changed(CoopLobby.paused)


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
		_set_open(not _panel.visible)
		get_viewport().set_input_as_handled()


func is_open() -> bool:
	return _panel.visible


func _set_open(open: bool) -> void:
	_panel.visible = open
	_leave_armed = false
	_refresh()
	# Solo only: a co-op menu never stops the shared game on its own.
	if not SteamLobby.is_networked():
		get_tree().paused = open


func _mode() -> String:
	if not SteamLobby.is_networked():
		return "solo"
	return "host" if SteamLobby.is_host() else "guest"


func _build() -> void:
	_banner = Label.new()
	_banner.text = "PAUSED BY THE HOST"
	_banner.add_theme_font_size_override("font_size", 28)
	_banner.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35))
	_banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.offset_left = -240
	_banner.offset_right = 240
	_banner.offset_top = 64
	_banner.offset_bottom = 104
	_banner.visible = false
	add_child(_banner)

	_panel = Control.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_panel)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.add_child(center)
	var box := PanelContainer.new()
	center.add_child(box)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	vbox.custom_minimum_size = Vector2(360, 0)
	box.add_child(vbox)

	var title := Label.new()
	title.text = "Menu"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	vbox.add_child(title)

	var resume := Button.new()
	resume.text = "Resume"
	resume.pressed.connect(func() -> void: _set_open(false))
	vbox.add_child(resume)

	_pause_button = Button.new()
	_pause_button.pressed.connect(func() -> void: CoopLobby.set_paused(not CoopLobby.paused))
	vbox.add_child(_pause_button)

	vbox.add_child(HSeparator.new())
	var fullscreen := CheckBox.new()
	fullscreen.text = "Fullscreen"
	fullscreen.button_pressed = GameSettings.fullscreen
	fullscreen.toggled.connect(GameSettings.set_fullscreen)
	vbox.add_child(fullscreen)
	vbox.add_child(_slider("Sound effects", GameSettings.sfx_volume, GameSettings.set_sfx_volume))
	vbox.add_child(_slider("Music", GameSettings.music_volume, GameSettings.set_music_volume))
	vbox.add_child(_slider("Interface", GameSettings.ui_volume, GameSettings.set_ui_volume))
	vbox.add_child(HSeparator.new())

	_leave_button = Button.new()
	_leave_button.pressed.connect(_on_leave)
	vbox.add_child(_leave_button)
	_refresh()


func _slider(label_text: String, value: float, setter: Callable) -> Control:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(120, 0)
	row.add_child(label)
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.05
	slider.value = value
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(setter)
	row.add_child(slider)
	return row


func _refresh() -> void:
	if _pause_button == null:
		return
	var mode := _mode()
	_pause_button.visible = mode == "host"
	_pause_button.text = "Unpause for everyone" if CoopLobby.paused else "Pause for everyone"
	var text := ""
	match mode:
		"solo":
			text = "Quit to title" if not _leave_armed else "Confirm: quit — ironman, the squad on this mission is lost"
		"host":
			text = "Save & quit" if not _leave_armed else "Confirm: stop for everyone — resume later from this round"
		_:
			text = "Leave mission" if not _leave_armed else "Confirm: leave — your soldiers stay with the host, rejoin any time"
	_leave_button.text = text


func _on_leave() -> void:
	if not _leave_armed:
		_leave_armed = true
		_refresh()
		return
	var main := get_parent()
	if main != null and main.has_method("quit_mission"):
		main.quit_mission()


func _on_paused_changed(paused: bool) -> void:
	_banner.visible = paused and SteamLobby.is_networked()
	_refresh()
