class_name HostJoinMenu
extends CanvasLayer
## The title screen (front_end.gd): Play, or the credits. Built in code, same
## pattern as LoadoutMenu — a one-off overlay, not a reusable HUD element.
##
## Co-op is no longer chosen here (MULTIPLAYER_PLAN.md): every player brings their
## own campaign, so a lobby is hosted or joined from the hub's Co-op tab once the
## save is loaded. An accepted Steam invite is noted on the way past and joined
## from the hub.
##
## Emits `resolved` on Play.

signal resolved

var _status: Label
var _credits_panel: Control


func setup() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.75)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var panel := PanelContainer.new()
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	vbox.custom_minimum_size = Vector2(320, 0)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "Retake the Spaceship"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	vbox.add_child(title)

	var play := Button.new()
	play.text = "Play"
	play.pressed.connect(_on_play)
	vbox.add_child(play)

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.text = _status_text()
	vbox.add_child(_status)

	var credits := Button.new()
	credits.text = "Credits"
	credits.pressed.connect(_on_credits)
	vbox.add_child(credits)

	_build_credits_panel(root)
	SteamLobby.invite_accepted.connect(func(_id: int) -> void: _status.text = _status_text())


func _status_text() -> String:
	if not SteamLobby.steam_available:
		return "Steam isn't running — solo only."
	if SteamLobby.pending_join != 0:
		return "Invite accepted — press Play and you'll join the lobby from your hub."
	return "Co-op: host or join a party from the hub's Co-op tab."


## Built up front and hidden rather than on demand: this screen is also where
## the ZapSplat attribution is discharged (see Credits), and a panel that only
## exists after a successful button press is one bug away from the credit never
## being shown at all.
func _build_credits_panel(root: Control) -> void:
	_credits_panel = Control.new()
	_credits_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_credits_panel.visible = false
	root.add_child(_credits_panel)

	# Fully opaque, unlike the 0.75 dim the menu itself uses over the game. That
	# one is layered over a 3D scene it is fine to see through; this one sits
	# over the menu's own panel, and at any alpha below 1 the title and buttons
	# read straight through the credits text behind it.
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 1.0)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_credits_panel.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_credits_panel.add_child(center)

	var panel := PanelContainer.new()
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	# Wide enough for an attribution line to wrap once, not three times.
	vbox.custom_minimum_size = Vector2(640, 0)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "Credits"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	vbox.add_child(title)

	for line in Credits.lines():
		var label := Label.new()
		label.text = line
		# Attribution lines (title, author, source, licence) run long; wrap
		# rather than stretch the panel off-screen.
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vbox.add_child(label)

	var close := Button.new()
	close.text = "Back"
	close.pressed.connect(func() -> void: _credits_panel.visible = false)
	vbox.add_child(close)


func _on_credits() -> void:
	_credits_panel.visible = true


func _on_play() -> void:
	resolved.emit()
	queue_free()
