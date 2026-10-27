extends Node
## Autoload. Initiative-pool draw loop (Sec 4.1), turn/mission state, win/loss.

signal unit_activated(unit: Unit)
signal turn_started(turn_number: int)
## The round is over: every unit in the pool has acted, and the next round has
## NOT started yet. Emitted with the number of the round that is ending, always
## before the `turn_started` of the next one, once per round.
##
## The moment GDD §7.4 hangs ship departure on ("the ship leaves at the end of
## the round"). A signal cannot be awaited by its emitter, so work that must
## FINISH before the next round starts — departure, which may end the mission —
## registers with `add_turn_end_hook` instead; this signal is the notification,
## the hooks are the work. Mirrored to clients (see `_rpc_turn_ending`); the
## hooks only ever run on the host.
signal turn_ending(turn_number: int)
signal log_message(text: String)
signal mission_ended(result: MissionResult)

var turn_number: int = 0
var pool: Array[Unit] = []
var active_unit: Unit = null
var mission_over: bool = false
var _awaiting_player: bool = false

## The legacy "every hostile down = mission won" rule (now MissionResult.CLEARED).
## With it OFF a mission ends only by extraction (extraction plan Phase 1) or a
## wipe — killing everything leaves the squad with a quiet deck to walk to the
## ship across, which is GDD §7's whole loop.
##
## ON by default, because no deck has a hangar yet and a mission with no way out
## must still be able to end; every existing test deck and the `--auto` smoke
## run depend on it. Phase 1 switches it off for a deck that has a hangar (set
## before `start_mission`; see main.gd `_spawn_and_start`). Deliberately NOT
## reset by `start_mission`, so whoever sets it is the one place that decides.
var clear_out_mode: bool = true

## Asked (host) when no PlayerUnit is left standing on the board, before that is
## called a wipe: `() -> bool`, true if it ended the mission some other way.
## ExtractionManager sets it — soldiers who boarded a landed ship are off the
## board but not lost (GDD §7.4). A seam rather than a direct call so this
## autoload keeps no compile-time dependency on the extraction layer.
var squad_gone_hook: Callable = Callable()

## Host-side work run at the end of each round, in registration order, each one
## awaited before the next — see `turn_ending`. Callables taking the ending
## round's number; a coroutine is awaited to completion, a plain function just
## runs. Lives on the autoload and outlives missions, so a registering autoload
## (ExtractionManager) registers once rather than once per mission.
var _turn_end_hooks: Array[Callable] = []


## Registers `hook(turn_number)` to run, and be awaited, at the end of every
## round on the host. Idempotent: registering the same Callable twice is one hook.
func add_turn_end_hook(hook: Callable) -> void:
	if not _turn_end_hooks.has(hook):
		_turn_end_hooks.append(hook)


func remove_turn_end_hook(hook: Callable) -> void:
	_turn_end_hooks.erase(hook)


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
	SecurityNetwork.clear_aggression()
	_start_turn()


## Drops everything that points into the current scene, which is about to be
## reloaded out from under this autoload (main.gd, when the host leaves). A
## client's TurnManager still holds the last `active_unit` the host synced, and
## a freed unit left there would be the first thing the next mission reads.
##
## Also the ABANDONED outcome: anything listening for `mission_ended` (the HUD
## today, the campaign later) hears that this mission stopped without being
## decided. Emitted only if it had not already ended — a host that leaves on the
## debrief screen has not abandoned anything.
func abandon() -> void:
	var was_over := mission_over
	mission_over = true
	active_unit = null
	pool.clear()
	_awaiting_player = false
	if not was_over:
		mission_ended.emit(MissionResult.new(MissionResult.Outcome.ABANDONED))


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
	# Before the pool, so the snapshot is taken of a board the bleed has already
	# settled — and before `turn_started`, so a soldier who bleeds out this round
	# is already a corpse when the HUD, the ship and the AI first look at it.
	_bleed_downed()
	pool = _all_units()
	var flicker_seed := randi()
	LightingManager.reroll_flicker(flicker_seed)  # Sec 5.3: flickering lights fluctuate turn-to-turn
	turn_started.emit(turn_number)
	if SteamLobby.is_networked() and SteamLobby.is_host():
		_rpc_turn_started.rpc(turn_number, flicker_seed)
	_log("--- Turn %d: %d units in the pool ---" % [turn_number, pool.size()])
	_draw_next()


## GDD §4.4: every DOWNED unit's downed bar drains `Unit.bleed_amount` at the
## start of each round, and empties into death. Host-only (it is called from
## `_start_turn`); the bar and the life state replicate. Round 1 never finds
## anyone downed, so "each round start" needs no special case for it.
func _bleed_downed() -> void:
	for node in get_tree().get_nodes_in_group("units"):
		var unit := node as Unit
		# A stable body (the Recover VIP, extraction plan A10) does not drain.
		if unit == null or unit.life_state != Unit.LifeState.DOWNED or not unit.bleeds_out():
			continue
		if unit.bleed_out_tick():
			_log("%s has bled out." % unit.stats.display_name)
		else:
			_log("%s is bleeding out (%d/%d)." % [
				unit.stats.display_name, unit.downed_hp, unit.downed_bar_max()])


func _draw_next() -> void:
	if not _is_authority():
		return
	if mission_over:
		return
	if _check_end_conditions():
		return
	# `is_instance_valid` FIRST, and it is load-bearing rather than defensive.
	# The pool is a snapshot taken at turn start, and a worm absorbed into a mass
	# leaves the board by being freed rather than by dying (WormUnit.dissolve) —
	# so between two draws an entry here can become a freed object, and reading
	# `.is_downed` off one is a hard crash.
	pool = pool.filter(func(u: Unit) -> bool: return is_instance_valid(u) and not u.is_downed)
	if pool.is_empty():
		await _end_round()
		# A hook may have ended the mission (the last soldiers flew out), or
		# changed the board enough to (departure leaving nobody standing).
		if mission_over or _check_end_conditions():
			return
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


## The round-end moment: notify (`turn_ending`, here and on clients), then run
## every registered hook to completion. Host-only, like the rest of the draw loop.
func _end_round() -> void:
	turn_ending.emit(turn_number)
	if SteamLobby.is_networked() and SteamLobby.is_host():
		_rpc_turn_ending.rpc(turn_number)
	# Iterates a copy: a hook may unregister itself (or another) as it runs.
	for hook in _turn_end_hooks.duplicate():
		if mission_over:
			return
		if hook.is_valid():
			await hook.call(turn_number)  # no-op await if the hook isn't a coroutine


@rpc("authority", "call_remote", "reliable")
func _rpc_turn_ending(number: int) -> void:
	turn_ending.emit(number)


## Without this a client's lights never flickered at all (its TurnManager never
## runs `_start_turn`), so its light map — and every accuracy preview built on
## it — drifted from the host's a little more each turn.
@rpc("authority", "call_remote", "reliable")
func _rpc_turn_started(number: int, flicker_seed: int) -> void:
	turn_number = number
	LightingManager.reroll_flicker(flicker_seed)
	turn_started.emit(turn_number)


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
	#
	# The two halves ask different questions on purpose (the Phase 0.4 audit):
	# "is the squad standing" counts PlayerUnits (`is_player_controlled`), not the
	# Contractor faction — a door gun or an escorted VIP is on the squad's side,
	# but a mission with only those left standing has no soldier in it. "Is
	# anything hostile left" stays a faction test.
	#
	# Only "standing" is checked here. A soldier already flown out is not on the
	# board to count; ExtractionManager (extraction plan Phase 1) ends a mission
	# by departure itself, through `end_mission`, before this can read a board
	# emptied by extraction as a wipe.
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
	# Checked before the wipe, as the old boolean was: a last exchange that drops
	# the final hostile and the final soldier together still reads as a clear.
	if clear_out_mode and not enemies_alive:
		end_mission(_squad_result(MissionResult.Outcome.CLEARED))
		return true
	if not players_alive:
		# Nobody standing on the BOARD is not yet a wipe if some of the squad
		# already boarded a landed ship (GDD §7.4): the extraction layer flies them
		# out instead, and ends the mission itself.
		if squad_gone_hook.is_valid() and squad_gone_hook.call():
			return true
		end_mission(_squad_result(MissionResult.Outcome.WIPED))
		return true
	return false


## A result for the outcomes TurnManager itself decides (CLEARED, WIPED), with
## the squad sorted into the two lists off the board as it stands: standing
## soldiers count as extracted, everyone else as lost (see MissionResult).
func _squad_result(outcome: MissionResult.Outcome) -> MissionResult:
	var result := MissionResult.new(outcome)
	for node in get_tree().get_nodes_in_group("units"):
		var unit := node as Unit
		if unit == null or not unit.is_player_controlled:
			continue
		# A wipe loses EVERY deployed soldier (GDD §4.4: "nobody is left to carry
		# anyone"), stated outright rather than left to fall out of "nobody is
		# standing" — so it holds even for a soldier the check raced.
		if unit.is_downed or outcome == MissionResult.Outcome.WIPED:
			result.lost_units.append(unit)
		else:
			result.extracted_units.append(unit)
	result.objective_complete = outcome == MissionResult.Outcome.CLEARED
	return result


## Ends the mission with `result` on every peer. THE one way a mission ends on
## the host: TurnManager's own end checks come through here, and so does
## extraction (extraction plan Phase 1's departure, from a turn-end hook). Safe to
## call more than once — only the first call counts.
func end_mission(result: MissionResult) -> void:
	if mission_over:
		return
	mission_over = true
	active_unit = null
	# Rival lifts (extraction plan Phase 8) belong in every outcome's debrief, and
	# whoever built the result — this manager for a wipe, ExtractionManager for a
	# lift — need not know about them.
	if result.rivals.is_empty() and ExtractionManager.is_active():
		result.rivals = ExtractionManager.rival_report()
	_log("=== MISSION %s ===" % result.describe())
	mission_ended.emit(result)
	if SteamLobby.is_networked() and SteamLobby.is_host():
		_rpc_mission_ended.rpc(result.to_dict())


## A MissionResult is a RefCounted and cannot cross the wire, so it travels as
## `MissionResult.to_dict` and is rebuilt here, with units re-resolved by path.
@rpc("authority", "call_remote", "reliable")
func _rpc_mission_ended(data: Dictionary) -> void:
	mission_over = true
	active_unit = null
	mission_ended.emit(MissionResult.from_dict(data, get_tree().root))
