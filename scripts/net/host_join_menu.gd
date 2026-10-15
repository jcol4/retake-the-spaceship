class_name HostJoinMenu
extends CanvasLayer
## First screen shown before the squad spawns (see main.gd): choose solo play,
## host a Steam lobby, or join one by ID. Built in code, same pattern as
## LoadoutMenu — a one-off overlay, not a reusable HUD element.
##
## Emits `resolved` once the local peer is ready to proceed to spawning:
## immediately for solo, or once SteamLobby's peer is actually live for
## host/join. `is_host()`/`SteamLobby.is_networked()` tell main.gd what to do
## from there.

signal resolved

var _status: Label
var _lobby_id_field: LineEdit
var _copy_button: Button
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

	var solo := Button.new()
	solo.text = "Solo"
	solo.pressed.connect(_on_solo)
	vbox.add_child(solo)

	var host := Button.new()
	host.text = "Host Co-op (Steam)"
	host.disabled = not SteamLobby.steam_available
	host.pressed.connect(_on_host)
	vbox.add_child(host)

	var join_row := HBoxContainer.new()
	_lobby_id_field = LineEdit.new()
	_lobby_id_field.placeholder_text = "Lobby ID"
	_lobby_id_field.custom_minimum_size = Vector2(160, 0)
	join_row.add_child(_lobby_id_field)
	var join := Button.new()
	join.text = "Join"
	join.disabled = not SteamLobby.steam_available
	join.pressed.connect(_on_join)
	join_row.add_child(join)
	vbox.add_child(join_row)

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.text = "" if SteamLobby.steam_available else "Steam unavailable — solo only"
	vbox.add_child(_status)

	_copy_button = Button.new()
	_copy_button.text = "Copy Lobby ID"
	_copy_button.visible = false
	_copy_button.pressed.connect(_on_copy_lobby_id)
	vbox.add_child(_copy_button)

	var credits := Button.new()
	credits.text = "Credits"
	credits.pressed.connect(_on_credits)
	vbox.add_child(credits)

	_build_credits_panel(root)

	SteamLobby.lobby_ready.connect(_on_lobby_ready)
	SteamLobby.join_failed.connect(func(reason: String) -> void: _status.text = reason)
	print("[BOOT] host/join menu shown (steam_available=%s)" % SteamLobby.steam_available)


## Diagnostic: names the control under every click that reaches this menu. A
## Solo press that does nothing but logs a hovered control other than the Solo
## button means something is drawn over the menu and eating the click; no line
## at all means the click never reached the viewport.
func _input(event: InputEvent) -> void:
	var click := event as InputEventMouseButton
	if click and click.pressed:
		var hovered := get_viewport().gui_get_hovered_control()
		print("[BOOT] menu click at %s, hovered control: %s" % [
			click.position, hovered.get_path() if hovered else "<none>"])


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
	vbox.custom_minimum_size = Vector2(420, 0)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "Credits"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	vbox.add_child(title)

	for line in Credits.lines():
		var label := Label.new()
		label.text = line
		vbox.add_child(label)

	var close := Button.new()
	close.text = "Back"
	close.pressed.connect(func() -> void: _credits_panel.visible = false)
	vbox.add_child(close)


func _on_credits() -> void:
	_credits_panel.visible = true


func _on_solo() -> void:
	print("[BOOT] Solo pressed")
	resolved.emit()
	queue_free()


func _on_host() -> void:
	_status.text = "Creating lobby..."
	SteamLobby.host_game()


func _on_join() -> void:
	var id := _lobby_id_field.text.to_int()
	if id == 0:
		_status.text = "Enter the host's lobby ID"
		return
	_status.text = "Joining..."
	SteamLobby.join_game(id)


func _on_lobby_ready(lobby_id: int) -> void:
	if SteamLobby.is_host():
		# There's no lobby browser or invite flow in the prototype — the host
		# shares this ID (aloud, Steam chat, or the copy button below) and the
		# joining player types it into the Join field above.
		_status.text = "Lobby ID: %d — waiting for a squadmate to join..." % lobby_id
		_copy_button.visible = true
		multiplayer.peer_connected.connect(func(_id: int) -> void: resolved.emit(); queue_free())
	else:
		resolved.emit()
		queue_free()


func _on_copy_lobby_id() -> void:
	DisplayServer.clipboard_set(str(SteamLobby.current_lobby_id))
	_copy_button.text = "Copied!"
