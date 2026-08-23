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

	SteamLobby.lobby_ready.connect(_on_lobby_ready)
	SteamLobby.join_failed.connect(func(reason: String) -> void: _status.text = reason)


func _on_solo() -> void:
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
