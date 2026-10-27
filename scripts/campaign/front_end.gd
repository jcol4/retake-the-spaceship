extends Node
## The front end (extraction plan 4.2): every screen of the campaign loop that is
## not the mission itself, in one scene — the project's main scene.
##
##   Title (Solo / Host / Join — HostJoinMenu)
##     -> campaign select (continue the slot, or start a new one)
##     -> Hub (HubMenu) --Launch--> main.tscn
##   main.tscn --Continue--> here again:
##     -> Debrief (DebriefMenu) -> Hub, or the campaign-over screen
##
## Which screen opens is read off the Campaign autoload when the scene loads: a
## debrief not yet shown, a campaign already running (back from a mission), or
## neither (a fresh launch -> Title). The screens are code-built overlays, the
## same pattern as LoadoutMenu and HostJoinMenu.
##
## CO-OP (A7): the hub runs on the host. A joined client sees a waiting screen,
## the host's debrief summary when it arrives, and is taken into the mission when
## the host launches one (Campaign._rpc_deployment).
##
## `--auto` / `--auto-campaign=N` skip all of it straight to main.tscn, which
## plays its own throwaway campaign.

var _screen: Node = null
var _waiting := false


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if "--auto" in args or Array(args).any(func(a: String) -> bool: return a.begins_with("--auto-campaign=")):
		get_tree().change_scene_to_file.call_deferred(Campaign.MISSION_SCENE)
		return
	var bg_layer := CanvasLayer.new()
	bg_layer.layer = -1
	add_child(bg_layer)
	var bg := ColorRect.new()
	bg.color = Color(0.04, 0.05, 0.07)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg_layer.add_child(bg)

	Campaign.deployment_received.connect(_on_deployment_received)
	Campaign.debrief_received.connect(_on_debrief_received)
	multiplayer.server_disconnected.connect(_on_host_left)

	if _is_client():
		if Campaign.debrief_unseen:
			_show_debrief()
		else:
			_show_waiting()
	elif Campaign.state != null:
		if Campaign.debrief_unseen:
			_show_debrief()
		else:
			_show_hub()
	else:
		_show_title()


static func _is_client() -> bool:
	return SteamLobby.is_networked() and not SteamLobby.is_host()


func _swap(screen: Node) -> void:
	_waiting = false
	if _screen != null and is_instance_valid(_screen):
		_screen.queue_free()
	_screen = screen
	add_child(screen)


# --- Title ------------------------------------------------------------------------


func _show_title() -> void:
	var menu := HostJoinMenu.new()
	_swap(menu)
	menu.setup()
	await menu.resolved
	_screen = null  # HostJoinMenu frees itself
	if _is_client():
		_show_waiting()
	else:
		_show_campaign_select()


## Solo or host: continue the slot, or start over. A slot that cannot be read
## (damaged, another version) is shown with its reason and only replaced if the
## player says so — it is never silently overwritten.
func _show_campaign_select() -> void:
	if not Campaign.has_save():
		Campaign.start_new()
		_show_hub()
		return
	var err := Campaign.load_campaign()
	var box := _dialog("Campaign")
	var info := Label.new()
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(info)
	if err == "":
		var s: CampaignState = Campaign.state
		info.text = "Mission %d   |   %d cr   |   %d soldier(s) on the roster%s" % [
			s.missions_played + 1, s.credits, s.roster.size(),
			"\nThe last mission was quit mid-deployment — ironman: it will be booked as lost." if not s.in_mission.is_empty() else ""]
		box.add_child(_button("Continue campaign", _on_continue_campaign))
	else:
		info.text = "The saved campaign can't be loaded:\n%s" % err
	var fresh := _button("New campaign", func() -> void: pass)
	fresh.pressed.connect(func() -> void:
		# Two clicks: the slot is the only one there is.
		if fresh.text != "Confirm: replace the saved campaign":
			fresh.text = "Confirm: replace the saved campaign"
			return
		Campaign.start_new()
		_show_hub())
	box.add_child(fresh)
	box.add_child(_button("Back to title", _back_to_title))


func _on_continue_campaign() -> void:
	if not Campaign.state.in_mission.is_empty():
		Campaign.book_interrupted()
		_show_debrief()
		return
	if Campaign.state.is_game_over():
		Campaign.wipe()
		_show_game_over()
		return
	_show_hub()


# --- Hub --------------------------------------------------------------------------


func _show_hub() -> void:
	var hub := HubMenu.new()
	_swap(hub)
	hub.setup()
	hub.launched.connect(func() -> void:
		get_tree().change_scene_to_file(Campaign.MISSION_SCENE))
	hub.game_over.connect(_show_game_over)
	hub.quit_requested.connect(_back_to_title)


# --- Debrief and game over ----------------------------------------------------------


func _show_debrief() -> void:
	Campaign.debrief_unseen = false
	var client := _is_client()
	var menu := DebriefMenu.new()
	_swap(menu)
	menu.setup(Campaign.last_debrief, client)
	await menu.closed
	_screen = null
	if client:
		_show_waiting()
	elif Campaign.last_debrief.get("game_over", false):
		_show_game_over()
	else:
		_show_hub()


func _show_game_over() -> void:
	var box := _dialog("Campaign over")
	var info := Label.new()
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var s: CampaignState = Campaign.state
	info.text = "There aren't enough soldiers left to field a squad, and not enough money to hire them.\n\n%s\n\nThe save has been cleared." % (
		"Missions flown: %d   |   Credits left: %d" % [s.missions_played, s.credits] if s != null else "")
	box.add_child(info)
	box.add_child(_button("Back to title", _back_to_title))


# --- Co-op client -----------------------------------------------------------------


func _show_waiting() -> void:
	if Campaign.deployment_fresh:
		get_tree().change_scene_to_file.call_deferred(Campaign.MISSION_SCENE)
		return
	var box := _dialog("Waiting for the host")
	var info := Label.new()
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.text = "The host runs the campaign: roster, stash and contracts are theirs. You'll drop in with your share of the squad when they launch the next mission."
	box.add_child(info)
	box.add_child(_button("Leave", _back_to_title))
	_waiting = true


func _on_deployment_received() -> void:
	if _waiting:
		get_tree().change_scene_to_file.call_deferred(Campaign.MISSION_SCENE)


func _on_debrief_received(_summary: Dictionary) -> void:
	if _waiting:
		_show_debrief()


func _on_host_left() -> void:
	SteamLobby.leave()
	Campaign.close()
	get_tree().change_scene_to_file.call_deferred(Campaign.FRONT_END_SCENE)


## Leaves the campaign (it is saved already — every action saved) and any lobby.
func _back_to_title() -> void:
	SteamLobby.leave()
	Campaign.close()
	get_tree().change_scene_to_file.call_deferred(Campaign.FRONT_END_SCENE)


# --- Helpers ----------------------------------------------------------------------


## A centred panel on a dim layer, as the current screen; returns its column.
func _dialog(title_text: String) -> VBoxContainer:
	var layer := CanvasLayer.new()
	_swap(layer)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)
	var panel := PanelContainer.new()
	center.add_child(panel)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	vbox.custom_minimum_size = Vector2(420, 0)
	panel.add_child(vbox)
	var title := Label.new()
	title.text = title_text
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	vbox.add_child(title)
	return vbox


func _button(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(on_press)
	return b
