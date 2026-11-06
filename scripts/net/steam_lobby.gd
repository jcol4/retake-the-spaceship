extends Node
## Autoload. Thin wrapper around GodotSteam + SteamMultiplayerPeer for the
## co-op prototype: init Steam against Spacewar (AppID 480, steam_appid.txt),
## host or join a Steam lobby, and hand the resulting peer to Godot's own
## high-level multiplayer API. Nothing past this file needs to know Steam
## exists — everywhere else in the game talks to `multiplayer` the normal
## Godot way.
##
## MULTIPLAYER_PLAN.md: up to four players; joining is by Steam friend invite
## (the overlay's invite dialog, and the `join_requested` callback when a friend
## accepts one from inside the game, or `+connect_lobby <id>` on the command line
## when Steam launched the game to accept one) or from the friends' lobbies list
## (`friends_lobbies`). The typed lobby ID survives as a `--dev` fallback.

signal lobby_ready(lobby_id: int)  ## Host's lobby is up and the peer is live.
signal join_failed(reason: String)
signal player_joined(peer_id: int)
signal player_left(peer_id: int)
## A Steam invite was accepted (in game, or the launch argument). The front end
## joins it once a campaign is loaded — a player brings their own save to co-op.
signal invite_accepted(lobby_id: int)

const MAX_MEMBERS := 4  # MULTIPLAYER_PLAN.md: up to four players, 1–2 soldiers each
## Steam's "immediate" friends (k_EFriendFlagImmediate): the friends list proper.
const FRIEND_FLAG_IMMEDIATE := 4

var steam_available: bool = false
var current_lobby_id: int = 0

## Host-side only: clients that have finished building their own copy of the
## board and deployed (see main.gd's `_rpc_client_ready`). A unit's
## MultiplayerSynchronizer starts hidden and is only made visible to a peer in
## this list — streaming state at a node the client hasn't spawned yet just
## fails to resolve its path.
var ready_peers: Array[int] = []
## A lobby to join as soon as a campaign is loaded (an accepted invite), or 0.
var pending_join: int = 0
## DEV ONLY (MULTIPLAYER_PLAN.md §5): a plain ENet "lobby" for testing co-op with
## two instances on one machine or a LAN, where Steam cannot connect a client to
## itself. `--enet-host=<port>` / `--enet-join=<host>:<port>` on the command line
## (or the Co-op tab under `--dev`). Everything past this file is the same: the
## lobby id is a stand-in (ENET_LOBBY_ID) and the peer is an ENetMultiplayerPeer.
var enet := false
## An ENet host or join to start once a campaign is loaded: "host:<port>",
## "join:<address>:<port>", or "".
var pending_enet := ""
const ENET_LOBBY_ID := 1
const ENET_DEFAULT_PORT := 24680


func _ready() -> void:
	# Steam's callbacks (and with them the network) keep running while the host
	# has the mission paused (CoopLobby.set_paused).
	process_mode = Node.PROCESS_MODE_ALWAYS
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--enet-host="):
			pending_enet = "host:" + arg.trim_prefix("--enet-host=")
		elif arg.begins_with("--enet-join="):
			pending_enet = "join:" + arg.trim_prefix("--enet-join=")
	multiplayer.connected_to_server.connect(_on_enet_connected)
	multiplayer.connection_failed.connect(func() -> void:
		if enet:
			leave()
			join_failed.emit("Could not connect"))
	multiplayer.peer_connected.connect(func(id: int) -> void:
		print("[NET] peer_connected: %d (local_id=%d, is_server=%s)" % [id, multiplayer.get_unique_id(), multiplayer.is_server()])
		player_joined.emit(id))
	multiplayer.peer_disconnected.connect(func(id: int) -> void:
		print("[NET] peer_disconnected: %d" % id)
		ready_peers.erase(id)
		player_left.emit(id))
	multiplayer.connected_to_server.connect(func() -> void:
		print("[NET] connected_to_server (local_id=%d)" % multiplayer.get_unique_id()))
	multiplayer.connection_failed.connect(func() -> void:
		print("[NET] connection_failed"))
	multiplayer.server_disconnected.connect(func() -> void:
		print("[NET] server_disconnected"))
	# Runs before Steam is ever touched, so a dev machine without the Steam
	# client running still boots straight to normal single-player instead of
	# erroring out — see is_networked().
	var init_result: Dictionary = Steam.steamInitEx()
	steam_available = init_result.get("status", -1) == 0
	if not steam_available:
		push_warning("SteamLobby: Steam init failed (%s) — running single-player." % init_result.get("verbal", "unknown"))
		return
	Steam.lobby_created.connect(_on_lobby_created)
	Steam.lobby_joined.connect(_on_lobby_joined)
	Steam.join_requested.connect(_on_join_requested)
	# Launched by Steam to accept an invite: `+connect_lobby <id>` among the args.
	var args := OS.get_cmdline_args()
	for i in args.size() - 1:
		if args[i] == "+connect_lobby" and args[i + 1].to_int() != 0:
			pending_join = args[i + 1].to_int()



func _process(_delta: float) -> void:
	if steam_available:
		Steam.run_callbacks()


## True once a real Steam multiplayer peer is assigned — as opposed to no
## peer at all, which is ordinary single-player. Everything ownership-gated
## (`Unit.is_owned_by_local_player`, `TurnManager` host guards) reads this
## indirectly through `multiplayer.has_multiplayer_peer()`.
func is_networked() -> bool:
	return multiplayer.has_multiplayer_peer()


func is_host() -> bool:
	# A guest whose host just went still holds its (closed) peer for a moment; a
	# disconnected peer has no id to ask about, and is nobody's host.
	return is_networked() and multiplayer.multiplayer_peer.get_connection_status() \
		!= MultiplayerPeer.CONNECTION_DISCONNECTED and multiplayer.is_server()


func local_peer_id() -> int:
	return multiplayer.get_unique_id() if is_networked() else 0


func host_game() -> void:
	if not steam_available:
		join_failed.emit("Steam is not available")
		return
	Steam.createLobby(Steam.LOBBY_TYPE_FRIENDS_ONLY, MAX_MEMBERS)


func join_game(lobby_id: int) -> void:
	if not steam_available:
		join_failed.emit("Steam is not available")
		return
	if current_lobby_id == lobby_id:
		return
	if current_lobby_id != 0:
		leave()
	Steam.joinLobby(lobby_id)


## Opens Steam's overlay invite dialog for the current lobby.
func invite_friends() -> void:
	if steam_available and current_lobby_id != 0 and not enet:
		Steam.activateGameOverlayInviteDialog(current_lobby_id)


## Steam friends playing this game right now: [{name, steam_id, lobby_id}], sorted
## by name; `lobby_id` 0 for one who has no open lobby. What the hub's Friends'
## lobbies list shows (a lobby to Join, or "playing, no open lobby").
##
## The lobby comes from two places, because Steam does not reliably fill in the
## first: the lobby in the friend's "game played" info, else the "connect" rich
## presence every host here sets (`_set_presence`, "+connect_lobby <id>" — the
## same string Steam's own friends-list "Join game" uses). `request_friends_presence`
## asks Steam to refresh that; it arrives as `friend_rich_presence_update`, which
## the Co-op tab listens to.
func friends_lobbies() -> Array:
	var out: Array = []
	if not steam_available or enet:
		return out
	var app := Steam.getAppID()
	for i in Steam.getFriendCount(FRIEND_FLAG_IMMEDIATE):
		var friend: int = Steam.getFriendByIndex(i, FRIEND_FLAG_IMMEDIATE)
		var game: Dictionary = Steam.getFriendGamePlayed(friend)
		var connect_lobby := _lobby_from_connect(Steam.getFriendRichPresence(friend, "connect"))
		var in_game := not game.is_empty() and int(game.get("id", 0)) == app
		if not in_game and connect_lobby == 0:
			continue
		var lobby := _as_lobby_id(game.get("lobby", 0))
		if lobby == 0:
			lobby = connect_lobby
		if lobby == current_lobby_id:
			continue
		out.append({"name": Steam.getFriendPersonaName(friend), "steam_id": friend, "lobby_id": lobby})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["name"]) < String(b["name"]))
	return out


## Asks Steam for fresh rich presence from every friend playing this game. Not
## from inside `friends_lobbies`: the answer triggers a list refresh, which must
## not ask again.
func request_friends_presence() -> void:
	if not steam_available or enet:
		return
	var app := Steam.getAppID()
	for i in Steam.getFriendCount(FRIEND_FLAG_IMMEDIATE):
		var friend: int = Steam.getFriendByIndex(i, FRIEND_FLAG_IMMEDIATE)
		var game: Dictionary = Steam.getFriendGamePlayed(friend)
		if not game.is_empty() and int(game.get("id", 0)) == app:
			Steam.requestFriendRichPresence(friend)


## A lobby id out of a "+connect_lobby <id>" connect string, or 0.
static func _lobby_from_connect(connect_string: String) -> int:
	var parts := connect_string.strip_edges().split(" ", false)
	if parts.size() >= 2 and parts[0] == "+connect_lobby" and parts[1].is_valid_int():
		return parts[1].to_int()
	return 0


## GodotSteam reports a friend's lobby as a number, or as a string when there is
## none ("No valid lobby" in some versions): 0 for anything that is not an id.
static func _as_lobby_id(v: Variant) -> int:
	if v is int:
		return v
	if v is String and (v as String).is_valid_int():
		return (v as String).to_int()
	return 0


## Host: drops `peer_id` from the session (CoopLobby.kick has already told them).
func kick_peer(peer_id: int) -> void:
	if is_host() and multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.disconnect_peer(peer_id)


## DEV: hosts a plain ENet lobby on `port` (see `enet`).
func host_enet(port: int = ENET_DEFAULT_PORT) -> void:
	if current_lobby_id != 0:
		leave()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_MEMBERS - 1)
	if err != OK:
		join_failed.emit("Could not host on port %d (%s)" % [port, error_string(err)])
		return
	multiplayer.multiplayer_peer = peer
	enet = true
	current_lobby_id = ENET_LOBBY_ID
	print("[NET] ENet host on port %d" % port)
	lobby_ready.emit(current_lobby_id)


## DEV: joins a plain ENet lobby at `address`:`port`. `lobby_ready` fires once the
## connection is up (`_on_enet_connected`).
func join_enet(address: String, port: int = ENET_DEFAULT_PORT) -> void:
	if current_lobby_id != 0:
		leave()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		join_failed.emit("Could not connect to %s:%d (%s)" % [address, port, error_string(err)])
		return
	multiplayer.multiplayer_peer = peer
	enet = true
	print("[NET] ENet joining %s:%d" % [address, port])


func _on_enet_connected() -> void:
	if enet and not multiplayer.is_server():
		current_lobby_id = ENET_LOBBY_ID
		lobby_ready.emit(current_lobby_id)


## Starts the ENet host or join the command line asked for (`pending_enet`), once.
func start_pending_enet() -> void:
	var what := pending_enet
	pending_enet = ""
	if what.begins_with("host:"):
		host_enet(int(what.trim_prefix("host:")) if what.trim_prefix("host:").is_valid_int() else ENET_DEFAULT_PORT)
	elif what.begins_with("join:"):
		var target := what.trim_prefix("join:")
		var port := ENET_DEFAULT_PORT
		var colon := target.rfind(":")
		if colon > 0:
			port = int(target.substr(colon + 1))
			target = target.substr(0, colon)
		join_enet(target, port)


func _on_join_requested(lobby_id: int, _friend_id: int) -> void:
	pending_join = lobby_id
	invite_accepted.emit(lobby_id)


## Rich presence, so a friend's Steam list offers "Join game" straight into the
## lobby (Steam launches or signals us with the connect string).
func _set_presence(lobby_id: int) -> void:
	if not steam_available or enet:
		return
	if lobby_id == 0:
		Steam.clearRichPresence()
	else:
		Steam.setRichPresence("connect", "+connect_lobby %d" % lobby_id)


## Drops back to plain single-player: closes the peer, leaves the Steam lobby,
## forgets who was ready. Called when the host goes away (see main.gd) — there
## is no host migration, so a client whose host left has nothing to rejoin.
func leave() -> void:
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
	# Offline rather than null: that is what a fresh boot starts with, so every
	# `has_multiplayer_peer()`/`is_server()` check reads exactly as it did
	# before a lobby was ever joined.
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	if steam_available and current_lobby_id != 0 and not enet:
		Steam.leaveLobby(current_lobby_id)
	enet = false
	current_lobby_id = 0
	ready_peers.clear()
	_set_presence(0)
	CoopPlayers.clear()
	CoopLobby.clear()


func _on_lobby_created(connect_result: int, lobby_id: int) -> void:
	print("[NET] _on_lobby_created result=%d lobby_id=%d" % [connect_result, lobby_id])
	if connect_result != 1:  # Steam.RESULT_OK
		join_failed.emit("Lobby creation failed (%d)" % connect_result)
		return
	current_lobby_id = lobby_id
	var peer := SteamMultiplayerPeer.new()
	peer.create_host(0)
	multiplayer.multiplayer_peer = peer
	print("[NET] host peer created, local_id=%d is_server=%s" % [multiplayer.get_unique_id(), multiplayer.is_server()])
	_set_presence(lobby_id)
	lobby_ready.emit(lobby_id)


func _on_lobby_joined(lobby_id: int, _permissions: int, _locked: bool, response: int) -> void:
	print("[NET] _on_lobby_joined lobby_id=%d response=%d" % [lobby_id, response])
	if response != Steam.CHAT_ROOM_ENTER_RESPONSE_SUCCESS:
		join_failed.emit("Could not enter lobby (%d)" % response)
		return
	var host_steam_id := Steam.getLobbyOwner(lobby_id)
	# Steam also reports the creator entering its own lobby; the host's peer is
	# already up (`_on_lobby_created`), and a client peer to itself would replace it.
	if host_steam_id == Steam.getSteamID():
		return
	current_lobby_id = lobby_id
	print("[NET] joining as client, host_steam_id=%d" % host_steam_id)
	var peer := SteamMultiplayerPeer.new()
	peer.create_client(host_steam_id, 0)
	multiplayer.multiplayer_peer = peer
	print("[NET] client peer created, local_id=%d is_server=%s" % [multiplayer.get_unique_id(), multiplayer.is_server()])
	_set_presence(lobby_id)
	lobby_ready.emit(lobby_id)
