extends Node
## Autoload. Thin wrapper around GodotSteam + SteamMultiplayerPeer for the
## co-op prototype: init Steam against Spacewar (AppID 480, steam_appid.txt),
## host or join a Steam lobby, and hand the resulting peer to Godot's own
## high-level multiplayer API. Nothing past this file needs to know Steam
## exists — everywhere else in the game talks to `multiplayer` the normal
## Godot way.
##
## Deliberately minimal for the prototype (Sec "scope" of the multiplayer
## plan): no reconnect handling, no lobby browser, no invites. Joining means
## typing the lobby ID a squadmate read off `lobby_ready`'s printed line.

signal lobby_ready(lobby_id: int)  ## Host's lobby is up and the peer is live.
signal join_failed(reason: String)
signal player_joined(peer_id: int)
signal player_left(peer_id: int)

const MAX_MEMBERS := 2  # co-op prototype: exactly one squadmate

var steam_available: bool = false
var current_lobby_id: int = 0

## Host-side only: clients that have finished building their own copy of the
## board and deployed (see main.gd's `_rpc_client_ready`). A unit's
## MultiplayerSynchronizer starts hidden and is only made visible to a peer in
## this list — streaming state at a node the client hasn't spawned yet just
## fails to resolve its path.
var ready_peers: Array[int] = []


func _ready() -> void:
	# Runs before Steam is ever touched, so a dev machine without the Steam
	# client running still boots straight to normal single-player instead of
	# erroring out — see is_networked().
	# Peer bookkeeping first, and unconditionally: a direct ENet session (see
	# `host_direct`) has no Steam behind it but still needs `ready_peers` pruned.
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
	var init_result: Dictionary = Steam.steamInitEx()
	steam_available = init_result.get("status", -1) == 0
	if not steam_available:
		push_warning("SteamLobby: Steam init failed (%s) — running single-player." % init_result.get("verbal", "unknown"))
		return
	Steam.lobby_created.connect(_on_lobby_created)
	Steam.lobby_joined.connect(_on_lobby_joined)


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
	return is_networked() and multiplayer.is_server()


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
	Steam.joinLobby(lobby_id)


## Plain ENet on localhost, no Steam at all — for two copies of the game on one
## machine (`-- --net=host` / `-- --net=join`, see main.gd), which is how the
## headless two-peer smoke test (tools/two_peer_smoke.sh) runs. Everything
## past the peer itself is the same code path a Steam session takes.
func host_direct(port: int) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_MEMBERS - 1)
	if err == OK:
		multiplayer.multiplayer_peer = peer
	return err


func join_direct(address: String, port: int) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err == OK:
		multiplayer.multiplayer_peer = peer
	return err


## Host-side: stops Steam letting anyone else into the lobby. Called once the
## mission's layout has gone out (main.gd) — the game has no late-join catch-up,
## so a slot freed by a squadmate dropping must not be one somebody can take.
func close_lobby() -> void:
	if steam_available and current_lobby_id != 0 and is_host():
		Steam.setLobbyJoinable(current_lobby_id, false)


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
	if steam_available and current_lobby_id != 0:
		Steam.leaveLobby(current_lobby_id)
	current_lobby_id = 0
	ready_peers.clear()


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
	lobby_ready.emit(lobby_id)


func _on_lobby_joined(lobby_id: int, _permissions: int, _locked: bool, response: int) -> void:
	print("[NET] _on_lobby_joined lobby_id=%d response=%d" % [lobby_id, response])
	if response != Steam.CHAT_ROOM_ENTER_RESPONSE_SUCCESS:
		join_failed.emit("Could not enter lobby (%d)" % response)
		return
	current_lobby_id = lobby_id
	var host_steam_id := Steam.getLobbyOwner(lobby_id)
	print("[NET] joining as client, host_steam_id=%d" % host_steam_id)
	var peer := SteamMultiplayerPeer.new()
	peer.create_client(host_steam_id, 0)
	multiplayer.multiplayer_peer = peer
	print("[NET] client peer created, local_id=%d is_server=%s" % [multiplayer.get_unique_id(), multiplayer.is_server()])
	lobby_ready.emit(lobby_id)
