extends Node
## Autoload. Who is in the lobby as far as anyone's screen cares: each player's
## colour, and the relay for their mouse cursor. An autoload for the same reason
## Campaign is: the path (/root/CoopPlayers) resolves on both peers whichever scene
## each is in, so a cursor still arriving from a partner in a mission cannot fail
## against a host already back in the hub.
##
## The host owns the colours. A client asks for one and the host's answer, the
## whole table, goes to everybody, so two players clicking the same free swatch
## at once settle on one winner.

signal colors_changed
signal cursor_received(peer_id: int, at: Vector3, on_deck: bool)
## The peer -> player table changed (someone said hello, or left).
signal players_changed
## Host-side: `peer_id` has said who it is. CoopLobby hangs the lobby and rejoin
## logic off this rather than off `peer_connected`, which knows only a peer id.
signal player_identified(peer_id: int, key: String)

## The swatches on offer. The first four are the default colours for the host,
## player 2, 3 and 4: a player with no saved choice gets the first one free.
const PALETTE: Array[Color] = [
	Color(0.3, 1.0, 0.6),  # green
	Color(0.72, 0.42, 1.0),  # purple
	Color(1.0, 0.9, 0.25),  # yellow
	Color(1.0, 1.0, 1.0),  # white
	Color(1.0, 0.55, 0.15),  # orange
	Color(0.25, 0.85, 1.0),  # cyan
	Color(1.0, 0.45, 0.75),  # pink
	Color(0.35, 0.5, 1.0),  # blue
]

## Peer id -> index into PALETTE, on every peer. Empty out of a lobby.
var _colors: Dictionary = {}
## Peer id -> {"key": player key, "name": display name}, on every peer, host-built
## (MULTIPLAYER_PLAN.md §2.1). Peer ids change every connection; the KEY — the
## Steam ID — is who the player is: what owns soldiers and is owed reports.
var _players: Dictionary = {}


func _ready() -> void:
	SteamLobby.lobby_ready.connect(_on_lobby_ready)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)


## The colour to draw `peer_id` in. Anyone not in the table is the first swatch:
## solo play has no table, and its soldiers keep the default green.
func color_of(peer_id: int) -> Color:
	return PALETTE[_colors.get(peer_id, 0)]


## This peer's index into PALETTE, or -1 before the host has answered.
func local_index() -> int:
	return _colors.get(multiplayer.get_unique_id(), -1)


func is_taken_by_other(index: int) -> bool:
	return _taken_by_others(_colors, multiplayer.get_unique_id()).has(index)


## Picks a swatch for this player, and remembers it for next time.
func request_color(index: int) -> void:
	GameSettings.set_preferred_color(index)
	if multiplayer.is_server():
		_grant(multiplayer.get_unique_id(), index)
	else:
		_rpc_request_color.rpc_id(1, index)


## Forgets the lobby's colours and players (SteamLobby.leave).
func clear() -> void:
	_colors.clear()
	_players.clear()
	colors_changed.emit()
	players_changed.emit()


# --- Who is who (MULTIPLAYER_PLAN.md §2.1) --------------------------------------------


## This player's key: their Steam ID, or "local" without Steam. `--player-key=<k>`
## overrides it, so two instances on one machine (or a test) can be two players.
static func local_key() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--player-key="):
			return arg.trim_prefix("--player-key=")
	if SteamLobby.steam_available:
		return str(Steam.getSteamID())
	return "local"


static func local_name() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--player-name="):
			return arg.trim_prefix("--player-name=")
	if SteamLobby.steam_available:
		return Steam.getPersonaName()
	return "Player"


## The key of whoever is on `peer_id`, or "" if they have not said hello.
func key_of(peer_id: int) -> String:
	if peer_id == multiplayer.get_unique_id() and not _players.has(peer_id):
		return local_key()
	return String((_players.get(peer_id, {}) as Dictionary).get("key", ""))


func name_of(peer_id: int) -> String:
	return String((_players.get(peer_id, {}) as Dictionary).get("name", "Player"))


## The peer the player `key` is connected on right now, or -1 if they are not.
func peer_of(key: String) -> int:
	if key == "":
		return -1
	for peer_id in _players:
		if String((_players[peer_id] as Dictionary).get("key", "")) == key:
			return int(peer_id)
	if key == local_key() and SteamLobby.is_networked():
		return multiplayer.get_unique_id()
	return -1


## The colour of the player `key`, wherever they are connected; the default
## swatch if they are not (a dropped player's soldiers keep a colour).
func color_of_key(key: String) -> Color:
	var peer := peer_of(key)
	return color_of(peer) if peer >= 0 else PALETTE[0]


## Host: records who `peer_id` is, and tells everyone.
func _identify(peer_id: int, key: String, display_name: String) -> void:
	# A player reconnecting on a new peer: drop the stale entry for their key.
	for p in _players.keys():
		if int(p) != peer_id and String((_players[p] as Dictionary).get("key", "")) == key:
			_players.erase(p)
	_players[peer_id] = {"key": key, "name": display_name}
	_rpc_players.rpc(_players)
	players_changed.emit()
	player_identified.emit(peer_id, key)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_hello(key: String, display_name: String) -> void:
	if multiplayer.is_server():
		_identify(multiplayer.get_remote_sender_id(), key, display_name)


@rpc("authority", "call_remote", "reliable")
func _rpc_players(players: Dictionary) -> void:
	_players = players
	players_changed.emit()


## What `peer_id` ends up with when it asks for `wanted`: that, if it is a real
## swatch nobody else holds; else what it already has; else the first free one.
static func resolve_color(colors: Dictionary, peer_id: int, wanted: int) -> int:
	var taken := _taken_by_others(colors, peer_id)
	if wanted >= 0 and wanted < PALETTE.size() and not taken.has(wanted):
		return wanted
	if colors.has(peer_id):
		return colors[peer_id]
	for i in PALETTE.size():
		if not taken.has(i):
			return i
	return 0


static func _taken_by_others(colors: Dictionary, peer_id: int) -> Array:
	var others := colors.duplicate()
	others.erase(peer_id)
	return others.values()


func _on_lobby_ready(_lobby_id: int) -> void:
	if SteamLobby.is_host():
		_grant(multiplayer.get_unique_id(), GameSettings.preferred_color)
		_identify(multiplayer.get_unique_id(), local_key(), local_name())


func _on_connected_to_server() -> void:
	_rpc_hello.rpc_id(1, local_key(), local_name())
	_rpc_request_color.rpc_id(1, GameSettings.preferred_color)


func _on_peer_disconnected(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	if _colors.erase(peer_id):
		_rpc_colors.rpc(_colors)
		colors_changed.emit()
	if _players.erase(peer_id):
		_rpc_players.rpc(_players)
		players_changed.emit()


## Host-side. Always answers, even when nothing changed: a client that lost a race
## for a swatch needs the table to see what it actually has.
func _grant(peer_id: int, wanted: int) -> void:
	_colors[peer_id] = resolve_color(_colors, peer_id, wanted)
	_rpc_colors.rpc(_colors)
	colors_changed.emit()


@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_color(index: int) -> void:
	if multiplayer.is_server():
		_grant(multiplayer.get_remote_sender_id(), index)


@rpc("authority", "call_remote", "reliable")
func _rpc_colors(colors: Dictionary) -> void:
	_colors = colors
	colors_changed.emit()


# --- Cursors ----------------------------------------------------------------------


## Tells every other player where this one's mouse is (SquadCursors). `on_deck`
## false hides it on their screens: over the UI, or off the map.
func send_cursor(at: Vector3, on_deck: bool) -> void:
	if not multiplayer.get_peers().is_empty():
		_rpc_cursor.rpc(at, on_deck)


## Unreliable: the next one is along in a moment, and is the one worth having.
@rpc("any_peer", "call_remote", "unreliable")
func _rpc_cursor(at: Vector3, on_deck: bool) -> void:
	cursor_received.emit(multiplayer.get_remote_sender_id(), at, on_deck)
