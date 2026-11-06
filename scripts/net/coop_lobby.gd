extends Node
## Autoload `CoopLobby` (MULTIPLAYER_PLAN.md §2.2): the co-op party between
## missions and around them — who is in it, what each player is bringing, who is
## ready, the host's contract board and the votes on it, chat, and whether the
## party is out on a mission. Every player runs their OWN hub on their OWN save;
## this is the shared table their hubs read and write.
##
## HOST-AUTHORITATIVE, broadcast whole. A client never edits the table: it sends
## the host a patch for its own row (`set_pick`, `set_ready`, `vote`) and the host
## sends everyone the new table. Four players' rows are small enough that the
## whole table on every change is simpler than deltas and never drifts.
##
## Keyed by PLAYER KEY (CoopPlayers.local_key, the Steam ID), not peer id: a row
## survives its player dropping mid-mission and coming back on a new peer, which
## is how a rejoin is recognised (`_on_player_identified`).
##
## Also the host's pause (`set_paused`), the kick, and the hand-off of pending
## reports and rejoins to Campaign when a known player says hello.

signal table_changed
signal chat_received(line: Dictionary)
## This player was removed from the lobby by the host.
signal kicked(reason: String)
signal paused_changed(paused: bool)

const PHASE_HUB := "hub"
const PHASE_MISSION := "mission"
## Chat lines kept (and shown).
const CHAT_KEEP := 60
## How long a kick waits after telling the player before cutting the connection,
## so the "you were removed" message arrives first.
const KICK_DELAY := 0.5

## key -> {name, peer, connected, ready, pick, roster, vote}. `pick` is the
## player's CampaignState.make_pick ({records, grenades, attachments, ammo}) or {};
## `roster` their whole roster (record dicts) for the read-only view; `vote` an
## index into `board` or -1.
var members: Dictionary = {}
## Member keys, host first: the spawn and ownership order of a launch.
var order: Array = []
## The host's contract board (ContractOffer dicts) and the host's pick from it.
var board: Array = []
var selected: int = -1
var phase: String = PHASE_HUB
## While out: {mission_id, owners: [keys]} — whose soldiers are on the deck.
var mission: Dictionary = {}
var paused := false
## {name, key, text}
var chat: Array = []
## Keys the host removed this lobby; a hello from one is turned away again.
var _banned: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	SteamLobby.lobby_ready.connect(_on_lobby_ready)
	CoopPlayers.player_identified.connect(_on_player_identified)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)


# --- Queries ----------------------------------------------------------------------------


func in_lobby() -> bool:
	return SteamLobby.current_lobby_id != 0


func is_host() -> bool:
	return SteamLobby.is_host()


static func my_key() -> String:
	return CoopPlayers.local_key()


func me() -> Dictionary:
	return members.get(my_key(), {})


func in_mission() -> bool:
	return phase == PHASE_MISSION


## Whether the running mission has soldiers of `key` on the deck.
func is_mission_owner(key: String) -> bool:
	return in_mission() and (mission.get("owners", []) as Array).has(key)


func votes_for(index: int) -> int:
	var n := 0
	for key in members:
		if int((members[key] as Dictionary).get("vote", -1)) == index:
			n += 1
	return n


## The soldiers the party would field right now (every player's current pick).
func squad_size() -> int:
	var n := 0
	for key in order:
		n += ((members.get(key, {}) as Dictionary).get("pick", {}) as Dictionary).get("records", []).size()
	return n


## Why Launch is greyed out, or "" (host).
func launch_blocker() -> String:
	if not is_host():
		return "Only the host launches"
	if in_mission():
		return "The party is on a mission"
	return CoopRules.launch_blocker(order, members, selected, board.size())


# --- This player's own row (any peer) ------------------------------------------------


## What this player brings: their pick package and their roster for the others to
## look at. Changing the pick takes back a Ready.
func set_pick(pick: Dictionary, roster: Array) -> void:
	_submit({"pick": pick, "roster": roster})


func set_ready(on: bool) -> void:
	_submit({"ready": on})


func vote(index: int) -> void:
	_submit({"vote": index})


func send_chat(text: String) -> void:
	var clean := text.strip_edges().left(240)
	if clean.is_empty() or not in_lobby():
		return
	if is_host():
		_post_chat(my_key(), clean)
	else:
		_rpc_chat.rpc_id(1, clean)


func _submit(patch: Dictionary) -> void:
	if not in_lobby():
		return
	if is_host():
		_apply_patch(my_key(), patch)
	else:
		_rpc_patch.rpc_id(1, patch)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_patch(patch: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	var key := CoopPlayers.key_of(multiplayer.get_remote_sender_id())
	if members.has(key):
		_apply_patch(key, patch)


## Host. Only a player's own row, and only the fields a player owns. Picks and
## Ready are frozen while the party is out — the deployment already took them.
func _apply_patch(key: String, patch: Dictionary) -> void:
	var m: Dictionary = members.get(key, {})
	if m.is_empty():
		return
	var before := m.duplicate(true)
	if patch.has("roster"):
		m["roster"] = patch["roster"]
	if not in_mission():
		if patch.has("pick") and patch["pick"] != m.get("pick", {}):
			m["pick"] = patch["pick"]
			m["ready"] = false
		if patch.has("ready"):
			m["ready"] = bool(patch["ready"])
	if patch.has("vote"):
		m["vote"] = int(patch["vote"])
	# Only a real change goes out: a hub answering the table with what the table
	# already says must not start a broadcast loop.
	if m != before:
		_broadcast()


# --- Host ---------------------------------------------------------------------------


## The host's contract board, from its save. Re-published whenever the board may
## have changed (lobby up, a debrief re-rolled it); a different board clears the
## votes and the selection, which named offers that are gone.
func publish_board() -> void:
	if not is_host() or Campaign.state == null:
		return
	var offers: Array = []
	for o: ContractOffer in Campaign.state.contracts:
		offers.append(o.to_dict())
	if offers != board:
		board = offers
		selected = -1
		for key in members:
			(members[key] as Dictionary)["vote"] = -1
	_broadcast()


func select_contract(index: int) -> void:
	if is_host() and not in_mission():
		selected = index if index >= 0 and index < board.size() else -1
		_broadcast()


## Host: launches the party (Campaign.launch_coop), or the reason it cannot.
func launch() -> String:
	var why := launch_blocker()
	if why != "":
		return why
	var err := Campaign.launch_coop(order, members, selected)
	if err != "":
		return err
	phase = PHASE_MISSION
	mission = {
		"mission_id": String((Campaign.deployment.get("coop", {}) as Dictionary).get("mission_id", "")),
		"owners": CoopRules.players_of(Campaign.deployment),
	}
	for key in members:
		(members[key] as Dictionary)["ready"] = false
	_broadcast()
	return ""


## Host, resuming a co-op mission from its checkpoint (Campaign.begin_resume): the
## lobby opens already out on that mission, so its players are recognised and
## brought back in as they connect.
func begin_resumed(deployment: Dictionary) -> void:
	phase = PHASE_MISSION
	mission = {
		"mission_id": String((deployment.get("coop", {}) as Dictionary).get("mission_id", "")),
		"owners": CoopRules.players_of(deployment),
	}
	_broadcast()


## Host, at the mission's end (Campaign.book_result): back in the hub. Every pick
## is cleared (soldiers died; each hub sends a fresh one), anyone who dropped and
## never came back leaves the table, the board re-publishes (it re-rolled), and
## nobody stays paused.
func mission_finished() -> void:
	if not is_host():
		return
	phase = PHASE_HUB
	mission = {}
	for key in members.keys():
		var m: Dictionary = members[key]
		if not bool(m.get("connected", false)) and key != my_key():
			members.erase(key)
			order.erase(key)
			continue
		m["pick"] = {}
		m["ready"] = false
		m["vote"] = -1
	if paused:
		_set_paused_everywhere(false)
	publish_board()


## Host: removes `key` from the lobby for the rest of it. Not mid-mission (the
## host cannot take a player's soldiers off them). "" or why not.
func kick(key: String) -> String:
	if not is_host():
		return "Only the host can remove players"
	if in_mission():
		return "Not during a mission"
	if key == my_key() or not members.has(key):
		return "No such player"
	var peer := int((members[key] as Dictionary).get("peer", -1))
	_banned[key] = true
	members.erase(key)
	order.erase(key)
	_post_chat("", "%s was removed from the lobby." % CoopPlayers.name_of(peer))
	_broadcast()
	if peer > 0:
		_rpc_kicked.rpc_id(peer, "The host removed you from the lobby.")
		get_tree().create_timer(KICK_DELAY).timeout.connect(func() -> void: SteamLobby.kick_peer(peer))
	return ""


## Host: pauses (or resumes) the mission for every player (MULTIPLAYER_PLAN.md:
## the host's power alone). Only mid-mission.
func set_paused(on: bool) -> void:
	if is_host() and in_mission():
		_set_paused_everywhere(on)


func _set_paused_everywhere(on: bool) -> void:
	_apply_pause(on)
	_rpc_paused.rpc(on)


@rpc("authority", "call_remote", "reliable")
func _rpc_paused(on: bool) -> void:
	_apply_pause(on)


## Only a peer actually in the mission scene stops: a lobby member waiting in
## their hub (or still loading back in) keeps a live menu, and picks the pause up
## on arrival (main.gd, after the rejoin snapshot).
func _apply_pause(on: bool) -> void:
	paused = on
	get_tree().paused = on and in_mission_scene()
	paused_changed.emit(on)


func in_mission_scene() -> bool:
	var scene := get_tree().current_scene
	return scene != null and scene.has_method("quit_mission")


# --- Membership ------------------------------------------------------------------------


func _on_lobby_ready(_lobby_id: int) -> void:
	if not is_host():
		return
	var key := my_key()
	if not members.has(key):
		members[key] = _new_member(CoopPlayers.local_name(), multiplayer.get_unique_id())
	if not order.has(key):
		order.push_front(key)
	publish_board()


## Host: a peer has said who it is. A banned key is turned away; anyone else gets
## (or gets back) their row. A player whose soldiers are on the running mission is
## sent back into it (Campaign.send_rejoin); anyone owed a report gets it.
func _on_player_identified(peer_id: int, key: String) -> void:
	if not is_host() or peer_id == multiplayer.get_unique_id():
		return
	if _banned.has(key):
		_rpc_kicked.rpc_id(peer_id, "The host removed you from this lobby.")
		get_tree().create_timer(KICK_DELAY).timeout.connect(func() -> void: SteamLobby.kick_peer(peer_id))
		return
	var m: Dictionary = members.get(key, {})
	if m.is_empty():
		m = _new_member(CoopPlayers.name_of(peer_id), peer_id)
		members[key] = m
	m["peer"] = peer_id
	m["connected"] = true
	m["name"] = CoopPlayers.name_of(peer_id)
	if not order.has(key):
		order.append(key)
	_broadcast()
	# History for the newcomer.
	for line in chat:
		_rpc_chat_line.rpc_id(peer_id, line)
	Campaign.deliver_pending(key)
	if is_mission_owner(key):
		Campaign.send_rejoin(peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	if not is_host():
		return
	for key in members.keys():
		var m: Dictionary = members[key]
		if int(m.get("peer", -1)) != peer_id:
			continue
		if in_mission() and is_mission_owner(key):
			# Their soldiers are still on the deck: keep the row, so the rejoin
			# finds it and the report knows them.
			m["connected"] = false
			m["peer"] = -1
		else:
			members.erase(key)
			order.erase(key)
	_broadcast()


static func _new_member(display_name: String, peer: int) -> Dictionary:
	return {"name": display_name, "peer": peer, "connected": true, "ready": false,
		"pick": {}, "roster": [], "vote": -1}


## Forgets the lobby (SteamLobby.leave) and lifts any pause.
func clear() -> void:
	members.clear()
	order.clear()
	board.clear()
	selected = -1
	phase = PHASE_HUB
	mission = {}
	chat.clear()
	_banned.clear()
	if paused:
		_apply_pause(false)
	table_changed.emit()


# --- Broadcast ---------------------------------------------------------------------------


func _broadcast() -> void:
	if is_host():
		_rpc_table.rpc({"members": members, "order": order, "board": board, "selected": selected,
			"phase": phase, "mission": mission, "paused": paused})
	table_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _rpc_table(t: Dictionary) -> void:
	members = t.get("members", {})
	order = t.get("order", [])
	board = t.get("board", [])
	selected = int(t.get("selected", -1))
	phase = String(t.get("phase", PHASE_HUB))
	mission = t.get("mission", {})
	if bool(t.get("paused", false)) != paused:
		_apply_pause(bool(t.get("paused", false)))
	table_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _rpc_kicked(reason: String) -> void:
	kicked.emit(reason)
	SteamLobby.leave.call_deferred()


# --- Chat --------------------------------------------------------------------------------


@rpc("any_peer", "call_remote", "reliable")
func _rpc_chat(text: String) -> void:
	if multiplayer.is_server():
		_post_chat(CoopPlayers.key_of(multiplayer.get_remote_sender_id()), text.strip_edges().left(240))


## Host. `key` "" is a system line.
func _post_chat(key: String, text: String) -> void:
	var line := {"key": key, "name": String((members.get(key, {}) as Dictionary).get("name", "")), "text": text}
	_add_chat(line)
	_rpc_chat_line.rpc(line)


@rpc("authority", "call_remote", "reliable")
func _rpc_chat_line(line: Dictionary) -> void:
	_add_chat(line)


func _add_chat(line: Dictionary) -> void:
	chat.append(line)
	while chat.size() > CHAT_KEEP:
		chat.pop_front()
	chat_received.emit(line)
