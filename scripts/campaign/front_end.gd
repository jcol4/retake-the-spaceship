extends Node
## The front end (extraction plan 4.2): every screen of the campaign loop that is
## not the mission itself, in one scene — the project's main scene.
##
##   Title (Play / Credits — HostJoinMenu)
##     -> campaign select (continue the slot, start a new one, or — a co-op host's
##        interrupted mission — Resume it or write it off)
##     -> Hub (HubMenu, co-op from its Co-op tab) --Launch--> main.tscn
##   main.tscn --Continue--> here again:
##     -> Debrief (DebriefMenu) -> Hub, or the campaign-over screen
##
## Which screen opens is read off the Campaign autoload when the scene loads: a
## debrief not yet shown, a campaign already running (back from a mission), or
## neither (a fresh launch -> Title). The screens are code-built overlays, the
## same pattern as LoadoutMenu and HostJoinMenu.
##
## CO-OP (MULTIPLAYER_PLAN.md): every player is in their own hub on their own save.
## A guest is taken into the mission when the host launches
## (Campaign.deployment_received) or brought back into a running one
## (Campaign.rejoin_received); their own debrief arrives as a report
## (Campaign.debrief_received) and is shown over whatever they are looking at. An
## accepted Steam invite is joined once a campaign is loaded.
##
## `--auto` / `--auto-campaign=N` skip all of it straight to main.tscn, which
## plays its own throwaway campaign.

var _screen: Node = null
var _in_hub := false


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if "--auto" in args or Array(args).any(func(a: String) -> bool: return a.begins_with("--auto-campaign=")):
		_go_to_mission()
		return
	get_tree().paused = false
	Music.play("menu")
	var bg_layer := CanvasLayer.new()
	bg_layer.layer = -1
	add_child(bg_layer)
	var bg := ColorRect.new()
	bg.color = Color(0.04, 0.05, 0.07)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg_layer.add_child(bg)

	Campaign.deployment_received.connect(_on_deployment_received)
	Campaign.debrief_received.connect(_on_debrief_received)
	Campaign.rejoin_received.connect(_go_to_mission)
	multiplayer.server_disconnected.connect(_on_host_left)
	CoopLobby.kicked.connect(_on_kicked)
	SteamLobby.invite_accepted.connect(_on_invite_accepted)

	# A guest back from a co-op mission: the deployment is spent either way (the
	# host cleared its own when it booked the result).
	if Campaign.is_coop() and not SteamLobby.is_host():
		Campaign.leave_mission()

	# DEV: the headless co-op bot (CoopBot) skips the title and the slot choice.
	if CoopBot.ensure(get_tree()) != null and Campaign.state == null:
		_bot_boot()
		return
	if Campaign.state != null:
		if Campaign.debrief_unseen:
			_show_debrief()
		else:
			_show_hub()
	else:
		_show_title()


## DEV (CoopBot): a fresh campaign under `--coop-bot-fresh`, else the slot; a
## hosted co-op mission resumed (`host-resume`) or written off; then the hub.
func _bot_boot() -> void:
	var bot := CoopBot.ensure(get_tree())
	# Fresh once per process: the bot comes back here after a quit, and that save
	# (and its checkpoint) is the thing under test.
	if "--coop-bot-fresh" in OS.get_cmdline_user_args() and not bot.booted:
		CampaignState.delete_save(Campaign.save_path)
		Campaign.delete_checkpoint()
	bot.booted = true
	if not Campaign.has_save() or Campaign.load_campaign() != "":
		Campaign.start_new()
	if Campaign.state.is_hosting_coop():
		if CoopBot.requested() == "host-resume":
			_on_resume()
			return
		if CoopBot.requested() == "host-quit":
			_show_hub()  # it has just quit; the checkpoint is what it is checking
			return
		Campaign.write_off_hosted()
	elif not Campaign.state.in_mission.is_empty():
		Campaign.book_interrupted()
	Campaign.debrief_unseen = false
	_show_hub()


func _swap(screen: Node) -> void:
	_in_hub = false
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
	_show_campaign_select()


## Continue the slot, or start over. A slot that cannot be read (damaged, another
## version) is shown with its reason and only replaced if the player says so — it
## is never silently overwritten. A co-op mission this save HOSTED and never
## finished is offered for Resume (or write-off) instead of being booked lost.
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
		var lines := PackedStringArray(["Mission %d   |   %d cr   |   %d soldier(s) on the roster" % [
			s.missions_played + 1, s.credits, s.roster.size()]])
		for e: Dictionary in s.away:
			lines.append("%d soldier(s) deployed with %s — back when that mission ends." % [
				(e.get("records", []) as Array).size(), String(e.get("host_name", "another crew"))])
		if s.is_hosting_coop():
			lines.append("\nA co-op mission you hosted is still in progress. Resume it — your party is brought back in as they join — or write it off (ironman: your soldiers on it are lost).")
			info.text = "\n".join(lines)
			var resume := _button("Resume co-op mission", _on_resume)
			resume.disabled = not Campaign.can_resume()
			if resume.disabled:
				lines.append("(The checkpoint for it is missing — it can only be written off.)")
				info.text = "\n".join(lines)
			box.add_child(resume)
			var off := _button("Write off the co-op mission", func() -> void: pass)
			off.pressed.connect(func() -> void:
				if off.text != "Confirm: my soldiers on it are lost":
					off.text = "Confirm: my soldiers on it are lost"
					return
				Campaign.write_off_hosted()
				_show_debrief())
			box.add_child(off)
		else:
			if not s.in_mission.is_empty():
				lines.append("\nThe last mission was quit mid-deployment — ironman: it will be booked as lost.")
			info.text = "\n".join(lines)
			box.add_child(_button("Continue campaign", _on_continue_campaign))
	else:
		info.text = "The saved campaign can't be loaded:\n%s" % err
	var fresh := _button("New campaign", func() -> void: pass)
	fresh.pressed.connect(func() -> void:
		# Two clicks: the slot is the only one there is.
		if fresh.text != "Confirm: replace the saved campaign":
			fresh.text = "Confirm: replace the saved campaign"
			return
		Campaign.delete_checkpoint()
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


## Resume the co-op mission this save hosted (MULTIPLAYER_PLAN.md §2.8): open a
## lobby already out on that mission, so its players are brought back in as they
## join, and load the mission from its checkpoint. Without Steam it resumes alone.
func _on_resume() -> void:
	var err := Campaign.begin_resume()
	if err != "":
		return
	# Steam's lobby, or (dev) the ENet one the command line asked for.
	var enet_host := SteamLobby.pending_enet.begins_with("host:")
	if SteamLobby.steam_available or enet_host:
		var box := _dialog("Resuming")
		var info := Label.new()
		info.text = "Opening a lobby for your party..."
		box.add_child(info)
		var open_lobby := SteamLobby.start_pending_enet if enet_host else SteamLobby.host_game
		var result: Array = await _first_of(SteamLobby.lobby_ready, SteamLobby.join_failed, open_lobby)
		if result[0] == 0:
			CoopLobby.begin_resumed(Campaign.deployment)
	_go_to_mission()


## Calls `start`, then awaits whichever of two one-argument signals fires first:
## [index, argument]. Connected BEFORE `start`, which may emit synchronously.
func _first_of(a: Signal, b: Signal, start: Callable) -> Array:
	var out := []
	var done := func(i: int, v: Variant) -> void:
		if out.is_empty():
			out.append(i)
			out.append(v)
	var fa := func(v: Variant) -> void: done.call(0, v)
	var fb := func(v: Variant) -> void: done.call(1, v)
	a.connect(fa, CONNECT_ONE_SHOT)
	b.connect(fb, CONNECT_ONE_SHOT)
	start.call()
	while out.is_empty():
		await get_tree().process_frame
	if a.is_connected(fa):
		a.disconnect(fa)
	if b.is_connected(fb):
		b.disconnect(fb)
	return out


# --- Hub --------------------------------------------------------------------------


func _show_hub(message: String = "") -> void:
	var hub := HubMenu.new()
	_swap(hub)
	hub.setup()
	_in_hub = true
	if message != "":
		hub._status.text = message
	hub.launched.connect(func() -> void:
		_go_to_mission())
	hub.game_over.connect(_show_game_over)
	hub.quit_requested.connect(_back_to_title)
	hub.debrief_ready.connect(_show_debrief)
	# DEV: an ENet host or join from the command line (`--enet-host`/`--enet-join`).
	if SteamLobby.pending_enet != "":
		SteamLobby.start_pending_enet()
	# An invite accepted at the title (or the launch argument): join it now that
	# this player has a campaign to bring.
	if SteamLobby.pending_join != 0:
		var lobby := SteamLobby.pending_join
		SteamLobby.pending_join = 0
		SteamLobby.join_game(lobby)


# --- Debrief and game over ----------------------------------------------------------


func _show_debrief() -> void:
	Campaign.debrief_unseen = false
	var menu := DebriefMenu.new()
	_swap(menu)
	menu.setup(Campaign.last_debrief)
	await menu.closed
	_screen = null
	if Campaign.last_debrief.get("game_over", false):
		_show_game_over()
	else:
		_show_hub()


func _show_game_over() -> void:
	# A campaign over is out of the party, too.
	SteamLobby.leave()
	var box := _dialog("Campaign over")
	var info := Label.new()
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var s: CampaignState = Campaign.state
	info.text = "There aren't enough soldiers left to field a squad, and not enough money to hire them.\n\n%s\n\nThe save has been cleared." % (
		"Missions flown: %d   |   Credits left: %d" % [s.missions_played, s.credits] if s != null else "")
	box.add_child(info)
	box.add_child(_button("Back to title", _back_to_title))


# --- Co-op ------------------------------------------------------------------------


## The host launched: this guest's soldiers are booked out (Campaign._rpc_deployment)
## and the mission loads, whatever screen is up.
func _on_deployment_received() -> void:
	if Campaign.deployment_fresh:
		_go_to_mission()


## This player's own report arrived (a mission's end, or a pending one delivered on
## joining): shown at once over the hub. A debrief screen already up keeps its turn.
func _on_debrief_received(_summary: Dictionary) -> void:
	if _in_hub:
		_show_debrief()


func _on_host_left() -> void:
	SteamLobby.leave()
	if Campaign.state != null:
		if _in_hub:
			_show_hub("The host closed the lobby.")
		return
	_back_to_title()


func _on_kicked(reason: String) -> void:
	if _in_hub:
		_show_hub.call_deferred(reason)


func _on_invite_accepted(lobby_id: int) -> void:
	if _in_hub:
		SteamLobby.pending_join = 0
		SteamLobby.join_game(lobby_id)


## Every way out of the front end into a mission — the host's Launch, a co-op
## guest following the host in or rejoining, a resume, `--auto` — goes through here
## so the menu music stops at the moment of deployment.
func _go_to_mission() -> void:
	Music.stop()
	get_tree().change_scene_to_file.call_deferred(Campaign.MISSION_SCENE)


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
	vbox.custom_minimum_size = Vector2(460, 0)
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
