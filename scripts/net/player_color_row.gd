class_name PlayerColorRow
extends HBoxContainer
## The co-op colour picker, on the host's hub and the client's waiting screen: one
## swatch per CoopPlayers.PALETTE entry, with this player's outlined and any other
## player's greyed out. Colours are picked between missions, so a mission never
## has to cope with one changing under it.

const SWATCH_SIZE := Vector2(32, 32)
const SELECTED_BORDER := 3
const SELECTED_BORDER_COLOR := Color(1.0, 1.0, 1.0)
const TAKEN_ALPHA := 0.2

var _swatches: Array[Button] = []


func _ready() -> void:
	add_theme_constant_override("separation", 8)
	alignment = BoxContainer.ALIGNMENT_CENTER
	var label := Label.new()
	label.text = "Your color"
	add_child(label)
	for i in CoopPlayers.PALETTE.size():
		var swatch := Button.new()
		swatch.custom_minimum_size = SWATCH_SIZE
		swatch.pressed.connect(CoopPlayers.request_color.bind(i))
		add_child(swatch)
		_swatches.append(swatch)
	CoopPlayers.colors_changed.connect(_refresh)
	_refresh()


func _refresh() -> void:
	var mine := CoopPlayers.local_index()
	for i in _swatches.size():
		var taken := CoopPlayers.is_taken_by_other(i)
		var style := StyleBoxFlat.new()
		style.bg_color = CoopPlayers.PALETTE[i]
		if taken:
			style.bg_color.a = TAKEN_ALPHA
		if i == mine:
			style.set_border_width_all(SELECTED_BORDER)
			style.border_color = SELECTED_BORDER_COLOR
			# Outward, so white still reads as selected on a white swatch.
			style.set_expand_margin_all(SELECTED_BORDER)
		for state: String in ["normal", "hover", "pressed", "disabled", "focus"]:
			_swatches[i].add_theme_stylebox_override(state, style)
		# Nothing to pick until the host has answered: a click before then would
		# try to reach a host this client is still connecting to.
		_swatches[i].disabled = taken or mine < 0
