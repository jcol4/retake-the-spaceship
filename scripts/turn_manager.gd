extends Node
## Autoload. Initiative-pool draw loop (Sec 4.1), turn/mission state, win/loss.

signal unit_activated(unit: Unit)
signal turn_started(turn_number: int)
signal log_message(text: String)
signal mission_ended(player_won: bool)

var turn_number: int = 0
var pool: Array[Unit] = []
var active_unit: Unit = null
var mission_over: bool = false
var _awaiting_player: bool = false


## True on every peer in single-player (nothing to gate), and on the host in
## co-op. False on a joined client: the pool draw, combat RNG, and AI all live
## on the host's GridManager/Combat state (Sec "Turn loop" of the co-op plan),
## so a client's own TurnManager must sit inert and only mirror what the host
## broadcasts via `_rpc_sync_activation`/`_rpc_log` below.
func _is_authority() -> bool:
	return not SteamLobby.is_networked() or SteamLobby.is_host()


## Every `log_message.emit(...)` call in this file should go through here
## instead — same signal, but also fans the line out to clients in co-op. A
## client never calls this itself (see `_is_authority`), so there's no risk of
## an RPC loop.
func _log(text: String) -> void:
	log_message.emit(text)
	if SteamLobby.is_networked() and SteamLobby.is_host():
		_rpc_log.rpc(text)


@rpc("authority", "call_remote", "reliable")
func _rpc_log(text: String) -> void:
	log_message.emit(text)


func start_mission() -> void:
	if not _is_authority():
		return
	turn_number = 0
	mission_over = false
	# Both hold state that outlives a single activation and would otherwise
	# outlive the MISSION too: squad blackboards are static, and an escalation is
	# a live ship-wide flag. Starting a second mission holding the first one's
	# claims — on units that no longer exist — is the bug this prevents.
	Doctrines.reset()
	AlienHivemind.reset()
	_start_turn()


func _all_units() -> Array[Unit]:
	var out: Array[Unit] = []
	for node in get_tree().get_nodes_in_group("units"):
		var unit := node as Unit
		if unit and not unit.is_downed:
			out.append(unit)
	return out


func _start_turn() -> void:
	if not _is_authority():
		return
	turn_number += 1
	pool = _all_units()
	LightingManager.reroll_flicker()  # Sec 5.3: flickering lights fluctuate turn-to-turn
	turn_started.emit(turn_number)
	_log("--- Turn %d: %d units in the pool ---" % [turn_number, pool.size()])
	_draw_next()


func _draw_next() -> void:
	if not _is_authority():
		return
	if mission_over:
		return
	if _check_end_conditions():
		return
	pool = pool.filter(func(u: Unit) -> bool: return not u.is_downed)
	if pool.is_empty():
		_start_turn()
		return
	# Weighted random without replacement — roulette wheel on Initiative.
	var total := 0.0
	for unit in pool:
		total += unit.stats.initiative()
	var roll := randf() * total
	var drawn: Unit = pool[-1]
	for unit in pool:
		roll -= unit.stats.initiative()
		if roll < 0.0:
			drawn = unit
			break
	pool.erase(drawn)
	active_unit = drawn
	drawn.begin_activation()
	if drawn.stunned:
		# Sec 4.2: a torso crit burns the target's next activation outright —
		# the WHOLE pool, however big Fitness made it, not a fixed 2 AP.
		drawn.stunned = false
		drawn.ap = 0
		_log("%s is STUNNED and loses their turn!" % drawn.stats.display_name)
	_log("%s drawn from the pool" % drawn.stats.display_name)
	unit_activated.emit(drawn)
	if SteamLobby.is_networked() and SteamLobby.is_host():
		# Clients' own TurnManager sits inert (see `_is_authority`) — this is
		# the only way their `active_unit`/HUD/`_accepting_input` gate ever
		# learns whose turn it is.
		print("[NET] host syncing active_unit -> %s (%s)" % [drawn.stats.display_name, drawn.get_path()])
		_rpc_sync_active_unit.rpc(drawn.get_path())
	if drawn is EnemyUnit:
		await drawn.take_turn()  # animated moves — must finish before the next draw
		if mission_over:
			return
		active_unit = null
		# Defer so deep recursion can't build up over many draws.
		call_deferred("_draw_next")
	else:
		_awaiting_player = true  # wait for end_activation from the player unit


@rpc("authority", "call_remote", "reliable")
func _rpc_sync_active_unit(unit_path: NodePath) -> void:
	var unit := get_tree().root.get_node_or_null(unit_path) as Unit
	print("[NET] client received active_unit sync: path=%s resolved=%s" % [
		unit_path, unit.stats.display_name if unit else "NULL (node not found at that path!)"])
	active_unit = unit
	if unit:
		unit_activated.emit(unit)


## A pinned unit that breaks cover eats the shot the suppressor was holding for
## exactly that. Called by Unit.move_along per tile, alongside `check_overwatch`.
##
## Fired as a plain SHOOT rather than an OVERWATCH, and that is the whole reward
## for having paid the extra AP and three rounds: a reserved snap shot carries
## -30% accuracy, this carries none. The suppressor already has the angle held
## and the weapon up — they are not reacting, they are waiting.
##
## The shot ENDS the suppression whether it hits or misses. Suppression is a
## burst of covering fire, and once it has been fired at somebody it is spent.
func check_suppression_break(mover: Unit) -> void:
	if not _is_authority():
		return
	if mission_over or mover.is_downed:
		return
	var watcher := mover.suppressed_by
	# No can_shoot()/ammo check: the burst was already paid for in do_suppress,
	# so a watcher who spent their last rounds pinning someone still gets to
	# fire it even at 0 ammo left in the mag.
	if watcher == null or watcher.is_downed:
		return
	if not GridManager.has_line_of_sight(watcher, mover):
		return
	watcher.release_suppression()
	# No ammo charge: the 3 rounds for this shot were already paid in do_suppress.
	var result: Combat.ShotResult = await watcher.fire_at(mover, Combat.ShotAction.SHOOT, Combat.BodyPart.TORSO, false)
	_log("SUPPRESSING FIRE! %s breaks cover — %s fires (%d%% acc): %s" % [
		mover.stats.display_name, watcher.stats.display_name,
		result.accuracy, Combat.describe(result),
	])
	if mover.is_downed:
		_log("%s is DOWN!" % mover.stats.display_name)


func check_overwatch(mover: Unit) -> void:
	# Sec 4.2: a unit holding Overwatch interrupts the draw order to fire when
	# an *enemy* walks into its sightline — never on allied movement. Called by
	# Unit.move_along after each tile, so the shot lands mid-walk.
	if not _is_authority():
		return
	if mission_over or mover.is_downed:
		return
	for node in get_tree().get_nodes_in_group("units"):
		var watcher := node as Unit
		if watcher == null or watcher == mover or not watcher.on_overwatch or watcher.is_downed:
			continue
		# Asked of the WATCHER, which is the whole of "never on allied movement":
		# a reserved angle covers what its owner would shoot at, and nothing else.
		if not watcher.is_hostile_to(mover):
			continue
		if not watcher.can_shoot() or not GridManager.has_line_of_sight(watcher, mover):
			continue
		watcher.on_overwatch = false  # the reserved shot is spent
		var result: Combat.ShotResult = await watcher.fire_at(mover, Combat.ShotAction.OVERWATCH)
		_log("OVERWATCH! %s fires at %s (%d%% acc): %s" % [
			watcher.stats.display_name, mover.stats.display_name, result.accuracy, Combat.describe(result),
		])
		if mover.is_downed:
			_log("%s is DOWN!" % mover.stats.display_name)
			return


## Called locally by the unit's own owning peer (see PlayerUnit._accepting_input
## / PlayerUnit.end_activation — a non-owning peer's copy of the same node
## never gets far enough to call this). On a client that just forwards the
## request to the host, which is the only place `_finish_activation` actually
## runs.
func end_activation(unit: Unit) -> void:
	if not _is_authority():
		print("[NET] client requesting end_activation for %s" % unit.stats.display_name)
		_rpc_request_end_activation.rpc_id(1, unit.get_path())
		return
	_finish_activation(unit)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_end_activation(unit_path: NodePath) -> void:
	print("[NET] host received end_activation request for %s from peer %d" % [unit_path, multiplayer.get_remote_sender_id()])
	if not _is_authority():
		return
	var unit := get_tree().root.get_node_or_null(unit_path) as Unit
	if unit == null:
		print("[NET] ...but no unit resolved at that path")
		return
	var sender := multiplayer.get_remote_sender_id()
	if unit.owner_peer_id != 0 and sender != unit.owner_peer_id:
		push_warning("TurnManager: rejected end_activation from peer %d for %s (owned by %d)" % [
			sender, unit.stats.display_name, unit.owner_peer_id])
		return
	_finish_activation(unit)


func _finish_activation(unit: Unit) -> void:
	if unit != active_unit or not _awaiting_player:
		return
	_awaiting_player = false
	active_unit = null
	call_deferred("_draw_next")


func _check_end_conditions() -> bool:
	# The mission is the CONTRACTORS' mission, so both halves are asked from their
	# point of view: is the squad still standing, and is anything still hostile to
	# it. The second is a faction question rather than "is anything left that
	# isn't the player" — a future neutral or allied faction should not have to be
	# killed to end a mission.
	var players_alive := false
	var enemies_alive := false
	for node in get_tree().get_nodes_in_group("units"):
		var unit := node as Unit
		if unit == null or unit.is_downed:
			continue
		if unit.is_player_controlled:
			players_alive = true
		elif Faction.is_hostile(Faction.Id.CONTRACTORS, unit.faction):
			enemies_alive = true
	if not enemies_alive:
		_end_mission(true)
		return true
	if not players_alive:
		_end_mission(false)
		return true
	return false


func _end_mission(player_won: bool) -> void:
	mission_over = true
	active_unit = null
	_log("=== MISSION %s ===" % ("WON — all hostiles down" if player_won else "FAILED — squad wiped"))
	mission_ended.emit(player_won)
	if SteamLobby.is_networked() and SteamLobby.is_host():
		_rpc_mission_ended.rpc(player_won)


@rpc("authority", "call_remote", "reliable")
func _rpc_mission_ended(player_won: bool) -> void:
	mission_over = true
	active_unit = null
	mission_ended.emit(player_won)
