class_name CoopPanel
extends VBoxContainer
## The hub's Co-op tab (MULTIPLAYER_PLAN.md §3). Out of a lobby: host one, or join
## a Steam friend's from the list (plus a typed lobby ID under `--dev`). In one:
## the party — each player's colour, Ready, what they are bringing, their roster on
## request — the host's Kick, Invite friends, chat, the colour picker, Leave.
##
## One instance lives as long as the hub (HubMenu keeps it across its rebuilds), so
## a half-typed chat line survives somebody readying up. It redraws its own lists
## on CoopLobby.table_changed and SteamLobby's lobby events.

## Something the hub should show in its status line.
signal status(text: String)

var _body: VBoxContainer
var _chat_log: RichTextLabel
var _chat_field: LineEdit
var _friends: Array = []
var _friends_box: VBoxContainer
## Refreshes the friends' list every few seconds while it is on screen, on top of
## Steam's own rich-presence pushes (`_on_steam_presence`).
var _friends_timer: Timer
const FRIENDS_REFRESH_SECONDS := 4.0
var _expanded: Dictionary = {}  # key -> showing their roster
var _armed_kick := ""
var _status_label: Label


func _ready() -> void:
	add_theme_constant_override("separation", 10)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 8)
	add_child(_body)
	_status_label = Label.new()
	_status_label.modulate = Color(1.0, 0.8, 0.5)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status_label)
	_build_chat()
	CoopLobby.table_changed.connect(_redraw)
	CoopLobby.chat_received.connect(_on_chat)
	SteamLobby.lobby_ready.connect(func(_id: int) -> void:
		# Replaces "Creating lobby..." / "Joining..." in the hub's status line too —
		# left there, it read as the lobby never having opened.
		_say("Lobby open — invite friends from the Co-op tab, or they can join from their Friends' lobbies list."
			if SteamLobby.is_host() else "Joined the lobby. Pick your soldiers on Deploy, then Ready.")
		_redraw())
	SteamLobby.join_failed.connect(func(reason: String) -> void: _say(reason))
	CoopPlayers.colors_changed.connect(_redraw)
	if SteamLobby.steam_available:
		# A friend opening (or leaving) a lobby shows up without a Refresh press.
		Steam.friend_rich_presence_update.connect(_on_steam_presence)
		Steam.persona_state_change.connect(_on_steam_presence)
	_friends_timer = Timer.new()
	_friends_timer.wait_time = FRIENDS_REFRESH_SECONDS
	_friends_timer.timeout.connect(_on_friends_timer)
	add_child(_friends_timer)
	_friends_timer.start()
	_refresh_friends()
	_redraw()


## Shows `text` here and in the hub's status line — always, empty included, so a
## progress message ("Creating lobby...") never outlives what it was waiting for.
func _say(text: String) -> void:
	_status_label.text = text
	status.emit(text)


func _redraw() -> void:
	for child in _body.get_children():
		_body.remove_child(child)
		child.queue_free()
	if CoopLobby.in_lobby():
		_draw_lobby()
	else:
		_draw_no_lobby()
	_chat_log.get_parent().visible = CoopLobby.in_lobby()


# --- Not in a lobby ------------------------------------------------------------------


func _draw_no_lobby() -> void:
	_body.add_child(_heading("Co-op"))
	_body.add_child(_dim("Play a mission with up to three friends. Everyone brings 1–2 soldiers from their own campaign; " +
		"what your soldiers carry out is yours, the contract pays everyone an even share, and losses are for keeps."))
	var dev := "--dev" in OS.get_cmdline_user_args()
	if dev:
		_draw_enet()
	if not SteamLobby.steam_available:
		_body.add_child(_dim("Steam isn't running, so co-op is unavailable." if not dev
			else "Steam isn't running: only the dev LAN lobby above works."))
		return
	var host := Button.new()
	host.text = "Host a co-op lobby"
	host.custom_minimum_size = Vector2(220, 40)
	host.pressed.connect(func() -> void:
		_say("Creating lobby...")
		SteamLobby.host_game())
	_body.add_child(host)

	var row := HBoxContainer.new()
	row.add_child(_heading("Friends' lobbies"))
	var refresh := Button.new()
	refresh.text = "Refresh"
	refresh.pressed.connect(func() -> void:
		SteamLobby.request_friends_presence()
		_refresh_friends()
		_redraw())
	row.add_child(refresh)
	_body.add_child(row)
	_friends_box = VBoxContainer.new()
	_body.add_child(_friends_box)
	if _friends.is_empty():
		_friends_box.add_child(_dim("None of your Steam friends are playing right now. A friend can also invite you: "
			+ "Invite friends in their lobby sends a Steam invite you accept from the overlay."))
	for f: Dictionary in _friends:
		var line := HBoxContainer.new()
		var label := Label.new()
		var lobby: int = f["lobby_id"]
		label.text = "%s's lobby" % f["name"] if lobby != 0 else "%s — playing, no open lobby" % f["name"]
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if lobby == 0:
			label.modulate = Color(0.7, 0.7, 0.7)
		line.add_child(label)
		if lobby != 0:
			var join := Button.new()
			join.text = "Join"
			join.pressed.connect(func() -> void:
				_say("Joining...")
				SteamLobby.join_game(lobby))
			line.add_child(join)
		_friends_box.add_child(line)

	if dev:
		var dev_row := HBoxContainer.new()
		var field := LineEdit.new()
		field.placeholder_text = "Steam lobby ID (dev)"
		field.custom_minimum_size = Vector2(200, 0)
		dev_row.add_child(field)
		var join := Button.new()
		join.text = "Join by ID"
		join.pressed.connect(func() -> void:
			if field.text.to_int() == 0:
				_say("Enter a lobby ID")
				return
			_say("Joining...")
			SteamLobby.join_game(field.text.to_int()))
		dev_row.add_child(join)
		_body.add_child(dev_row)


## DEV: a plain ENet lobby (SteamLobby.host_enet / join_enet) for testing two
## instances on one machine or a LAN. Give each instance its own `--save-slot=`
## and `--player-key=`.
func _draw_enet() -> void:
	_body.add_child(_heading("LAN lobby (dev)"))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var host := Button.new()
	host.text = "Host on port %d" % SteamLobby.ENET_DEFAULT_PORT
	host.pressed.connect(func() -> void: SteamLobby.host_enet())
	row.add_child(host)
	var field := LineEdit.new()
	field.text = "127.0.0.1"
	field.custom_minimum_size = Vector2(160, 0)
	row.add_child(field)
	var join := Button.new()
	join.text = "Join"
	join.pressed.connect(func() -> void:
		_say("Connecting...")
		SteamLobby.join_enet(field.text.strip_edges()))
	row.add_child(join)
	_body.add_child(row)


func _refresh_friends() -> void:
	_friends = SteamLobby.friends_lobbies()


## Steam pushed a friend's presence or rich presence: redraw the list if it changed.
## Untyped, optional arguments: the two signals carry different ones.
func _on_steam_presence(_a: Variant = null, _b: Variant = null) -> void:
	_update_friends()


## Every few seconds on screen: ask Steam for fresh rich presence (the answer comes
## back through `_on_steam_presence`), and redraw from what it already has.
func _on_friends_timer() -> void:
	if CoopLobby.in_lobby() or not is_visible_in_tree():
		return
	SteamLobby.request_friends_presence()
	_update_friends()


func _update_friends() -> void:
	if CoopLobby.in_lobby() or not is_visible_in_tree():
		return
	var before := _friends
	_refresh_friends()
	if _friends != before:
		_redraw()


# --- In a lobby ----------------------------------------------------------------------


func _draw_lobby() -> void:
	var host_name := ""
	if not CoopLobby.order.is_empty():
		host_name = String((CoopLobby.members.get(CoopLobby.order[0], {}) as Dictionary).get("name", ""))
	_body.add_child(_heading("Lobby — %s" % ("you are the host" if CoopLobby.is_host() else "hosted by %s" % host_name)))
	if CoopLobby.in_mission():
		_body.add_child(_dim("The party is out on a mission." + (
			"" if CoopLobby.is_mission_owner(CoopLobby.my_key())
			else " You'll be in on the next one.")))
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	var invite := Button.new()
	invite.text = "Invite friends"
	invite.disabled = CoopLobby.order.size() >= SteamLobby.MAX_MEMBERS
	invite.pressed.connect(SteamLobby.invite_friends)
	actions.add_child(invite)
	if "--dev" in OS.get_cmdline_user_args() and CoopLobby.is_host():
		var copy := Button.new()
		copy.text = "Copy lobby ID"
		copy.pressed.connect(func() -> void:
			DisplayServer.clipboard_set(str(SteamLobby.current_lobby_id))
			_say("Lobby ID copied."))
		actions.add_child(copy)
	var leave := Button.new()
	leave.text = "Leave lobby"
	leave.pressed.connect(func() -> void:
		SteamLobby.leave()
		_say("Left the lobby."))
	actions.add_child(leave)
	_body.add_child(actions)

	_body.add_child(_heading("Players (%d/%d)" % [CoopLobby.order.size(), SteamLobby.MAX_MEMBERS]))
	for i in CoopLobby.order.size():
		_draw_member(String(CoopLobby.order[i]), i == 0)
	_body.add_child(PlayerColorRow.new())


func _draw_member(key: String, is_host_row: bool) -> void:
	var m: Dictionary = CoopLobby.members.get(key, {})
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var swatch := ColorRect.new()
	swatch.custom_minimum_size = Vector2(16, 16)
	swatch.color = CoopPlayers.color_of_key(key)
	row.add_child(swatch)
	var label := Label.new()
	var state := ""
	if not bool(m.get("connected", true)):
		state = "disconnected — soldiers driven by the host"
	elif CoopLobby.in_mission():
		state = "on the mission" if CoopLobby.is_mission_owner(key) else "waiting in the hub"
	elif is_host_row:
		state = "host"
	else:
		state = "READY" if bool(m.get("ready", false)) else "not ready"
	label.text = "%s%s — %s" % [String(m.get("name", "?")), " (you)" if key == CoopLobby.my_key() else "", state]
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if state == "READY":
		label.modulate = Color(0.6, 1.0, 0.6)
	row.add_child(label)
	var view := Button.new()
	view.text = "Hide roster" if _expanded.get(key, false) else "View roster"
	view.pressed.connect(func() -> void:
		_expanded[key] = not _expanded.get(key, false)
		_redraw())
	row.add_child(view)
	if CoopLobby.is_host() and key != CoopLobby.my_key() and not CoopLobby.in_mission():
		var kick := Button.new()
		kick.text = "Confirm kick" if _armed_kick == key else "Kick"
		kick.pressed.connect(func() -> void:
			if _armed_kick != key:
				_armed_kick = key
				_redraw()
				return
			_armed_kick = ""
			var err := CoopLobby.kick(key)
			_say(err if err != "" else ""))
		row.add_child(kick)
	_body.add_child(row)
	# What they are bringing.
	var pick: Dictionary = m.get("pick", {})
	var recs: Array = pick.get("records", [])
	if recs.is_empty():
		_body.add_child(_dim("    Bringing: nobody picked yet"))
	for d: Dictionary in recs:
		_body.add_child(_dim("    Bringing: " + soldier_line(d)))
	if _expanded.get(key, false):
		var roster: Array = m.get("roster", [])
		if roster.is_empty():
			_body.add_child(_dim("    (roster not shared yet)"))
		for d: Dictionary in roster:
			_body.add_child(_dim("      " + soldier_line(d)))


## One soldier as a line, from a SoldierRecord dict: name, class, stats, gun,
## injuries. What the party sees of each other's soldiers.
static func soldier_line(d: Dictionary) -> String:
	var r := SoldierRecord.from_dict(d)
	var line := "%s — %s — %s — %s" % [r.display_name, r.class_name_text(), r.stats_text(), r.loadout_text()]
	if r.is_injured():
		line += " — injured: %s" % r.injury_text()
	if bool(d.get("away", false)):
		line += " — deployed elsewhere"
	return line


# --- Chat --------------------------------------------------------------------------------


func _build_chat() -> void:
	var box := VBoxContainer.new()
	box.add_child(_heading("Chat"))
	_chat_log = RichTextLabel.new()
	_chat_log.custom_minimum_size = Vector2(0, 160)
	_chat_log.scroll_following = true
	_chat_log.bbcode_enabled = true
	box.add_child(_chat_log)
	var row := HBoxContainer.new()
	_chat_field = LineEdit.new()
	_chat_field.placeholder_text = "Say something to the party"
	_chat_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_field.max_length = 240
	_chat_field.text_submitted.connect(func(_t: String) -> void: _send())
	row.add_child(_chat_field)
	var send := Button.new()
	send.text = "Send"
	send.pressed.connect(_send)
	row.add_child(send)
	box.add_child(row)
	add_child(box)
	for line: Dictionary in CoopLobby.chat:
		_on_chat(line)


func _send() -> void:
	CoopLobby.send_chat(_chat_field.text)
	_chat_field.text = ""


func _on_chat(line: Dictionary) -> void:
	var text := String(line.get("text", "")).replace("[", "[lb]")
	var key := String(line.get("key", ""))
	if key == "":
		_chat_log.append_text("[i]%s[/i]\n" % text)
		return
	var color := CoopPlayers.color_of_key(key).to_html(false)
	var who := String(line.get("name", "?")).replace("[", "[lb]")
	_chat_log.append_text("[color=#%s]%s:[/color] %s\n" % [color, who, text])


# --- Helpers ----------------------------------------------------------------------------


func _heading(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 20)
	return label


func _dim(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.modulate = Color(0.8, 0.8, 0.8)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label
