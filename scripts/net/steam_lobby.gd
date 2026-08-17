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


func _ready() -> void:
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
	multiplayer.peer_connected.connect(func(id: int) -> void: player_joined.emit(id))
	multiplayer.peer_disconnected.connect(func(id: int) -> void: player_left.emit(id))


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


func _on_lobby_created(connect_result: int, lobby_id: int) -> void:
	if connect_result != 1:  # Steam.RESULT_OK
		join_failed.emit("Lobby creation failed (%d)" % connect_result)
		return
	current_lobby_id = lobby_id
	var peer := SteamMultiplayerPeer.new()
	peer.create_host(0)
	multiplayer.multiplayer_peer = peer
	lobby_ready.emit(lobby_id)


func _on_lobby_joined(lobby_id: int, _permissions: int, _locked: bool, response: int) -> void:
	if response != Steam.CHAT_ROOM_ENTER_RESPONSE_SUCCESS:
		join_failed.emit("Could not enter lobby (%d)" % response)
		return
	current_lobby_id = lobby_id
	var host_steam_id := Steam.getLobbyOwner(lobby_id)
	var peer := SteamMultiplayerPeer.new()
	peer.create_client(host_steam_id, 0)
	multiplayer.multiplayer_peer = peer
	lobby_ready.emit(lobby_id)
