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
## Emitted each time a walk ends; `cancel_all_walks` waits on it.
signal walk_drained
signal mission_ended(result: MissionResult)
## The mission moved between exploration and turn mode (plan B.1). Mirrored to
## clients by `_rpc_mode_changed`.
signal mode_changed(mode: Mode)
## The step clock moved (plan B.2/C.3): steps toward the next round, and the
## round it is counting toward. Mirrored to clients by `_rpc_clock`.
signal clock_changed(steps: int, turn_number: int)
## A round tick (AI pass and its playback) has finished; `settle_clock` waits on it.
signal tick_finished
## Exploration only: this peer's player picked `unit` to command (plan A.6). The
## local counterpart of `unit_activated`, which stays the draw's — `--auto` and the
## co-op sync hang off that one, and a selection is neither.
signal unit_selected(unit: Unit)

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

## GDD §4.7: whether a mission starts in exploration (free movement on a step
## clock) and drops into turn mode only on contact. OFF by default, like the
## inverse of `clear_out_mode`: every test deck and the `--turn-mode` baseline run
## the plain initiative loop, and main.gd switches it on for real play. Not reset
## by `start_mission` either, for the same reason.
var exploration_enabled: bool = false

## Which loop the mission is in (GDD §4.7, exploration plan B.1). TURN is the
## initiative-pool draw; EXPLORATION is free movement on the step clock. Lives
## here rather than in its own autoload so `turn_number` and every signal hung on
## it keep one owner (E2).
enum Mode { EXPLORATION, TURN }
var mode: Mode = Mode.TURN

## Units in the middle of a `move_along`, maintained by the walk itself (plan
## A.3). The mode switch cancels and drains all of them before any draw.
var _walking: Array[Unit] = []

## The step clock (GDD §4.7.3, plan B.2): steps taken toward the next round.
## Host-authoritative; clients hold the last value `_rpc_clock` sent.
const STEPS_PER_ROUND := ExplorationRules.STEPS_PER_ROUND
var steps: int = 0
## Rounds crossed by `add_steps` and not yet run. `add_steps` only RECORDS; the
## tick runs at the next `settle_clock`, so an action always lands before the
## round it crossed ticks (E6).
var _ticks_queued: int = 0
var _ticking: bool = false
## True while a tick's AI pass is being decided: every unit resolves as logic
## only (Unit.is_instant), and `record` collects what each one did for playback.
var resolving_tick: bool = false
var _timeline: Array = []
## Contact with the squad was reported and the switch to turn mode is pending:
## the clock stops ticking and the walks are being drained (plan B.3).
var _combat_pending: bool = false
## The last round with contact against the squad (plan B.9): set by
## `notify_combat` and by any enemy still fighting the squad at a draw.
var _last_squad_combat_round: int = 0
## A hostile has fallen in this fight since the last draw, so the next one asks
## whether that won it (`_fight_is_won`). Only a kill ever asks: a squad that ran,
## and whose pursuers gave up, leaves by the quiet round.
var _kill_pending: bool = false
## Tiles from a standing soldier within which an ALERT hostile keeps the fight open:
## past weapon range (EnemyUnit.ATTACK_RANGE), so one the squad could be shooting at
## next round still counts, and one investigating across the deck does not.
const CALM_RADIUS := 10
## Something outside the board is mid-action and the switch to turn mode must wait
## for it: `--auto`'s soldier part-way through a think (main.gd, plan D.1).
var hold_switch: int = 0
## Plays a tick's scheduled timeline (plan B.12). Built lazily; see tick_playback.gd.
var _playback: TickPlayback = null

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


## Whether the mission is in exploration right now (GDD §4.7). The one question
## every cost, gate and HUD branch asks.
func in_exploration() -> bool:
	return mode == Mode.EXPLORATION


## Who may command `unit` right now, asked for `peer_id` about `method`: "" if
## allowed, else why not (the `revive_blocker` style). The one authorization
## gate (plan A.4) — `PlayerUnit._accepting_input` asks it with the local peer,
## `_rpc_command` with the sender, and ending an activation with either.
##
## Turn mode is exactly the old gate: the owner, and only on the drawn unit.
## Exploration has no drawn unit: any owner may drive any of their standing
## soldiers that is not mid-action — except a move, which is allowed mid-walk so
## that it can redirect it (E9).
func may_act(unit: Unit, peer_id: int, method: StringName = &"") -> String:
	if unit == null:
		return "no unit"
	if unit.owner_peer_id != 0 and peer_id != unit.owner_peer_id:
		return "not yours"
	if mode == Mode.TURN:
		return "" if active_unit == unit else "not this unit's activation"
	if unit.is_downed:
		return "down"
	if _combat_pending:
		return "contact"
	# A walk paused at a tick can still be re-aimed; anything else waits for it
	# (E5). Wait goes through even with a soldier mid-walk (E16): it is the round
	# passing, not that soldier doing something.
	var redirect := method == &"_try_move" and unit.is_walking()
	if _ticking and not redirect:
		return "the round is ticking"
	if unit.is_busy and not redirect and method != &"try_wait":
		return "busy"
	return ""


## Called by `Unit.move_along` as a walk starts and ends.
func register_walk(unit: Unit) -> void:
	if not _walking.has(unit):
		_walking.append(unit)


func unregister_walk(unit: Unit) -> void:
	_walking.erase(unit)
	walk_drained.emit()


func is_anyone_walking() -> bool:
	_walking = _walking.filter(func(u: Unit) -> bool: return is_instance_valid(u))
	return not _walking.is_empty()


## Stops every walk in flight at the tile each walker is stepping onto (E7), and
## returns once all of them have run their arrival. Coroutine. The mode switch
## needs this drain before any initiative draw (plan A.3).
func cancel_all_walks() -> void:
	for unit in _walking.duplicate():
		if is_instance_valid(unit):
			unit.cancel_walk()
	while is_anyone_walking():
		await walk_drained


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
	# Silently, so the mode this mission opens in always reads as a change, even
	# when the last mission ended in the same one.
	mode = Mode.TURN
	hold_switch = 0
	steps = 0
	_ticks_queued = 0
	_ticking = false
	resolving_tick = false
	_combat_pending = false
	_last_squad_combat_round = 0
	_kill_pending = false
	_timeline.clear()
	# Both hold state that outlives a single activation and would otherwise
	# outlive the MISSION too: squad blackboards are static, and an escalation is
	# a live ship-wide flag. Starting a second mission holding the first one's
	# claims — on units that no longer exist — is the bug this prevents.
	Doctrines.reset()
	AlienHivemind.reset()
	SecurityNetwork.clear_aggression()
	if exploration_enabled:
		# GDD §4.7: a mission opens out of combat, on round 1 of the step clock.
		_begin_round(false)
		_enter_mode(Mode.EXPLORATION)
		_log("--- Round %d: exploring ---" % turn_number)
		_check_end_conditions()
		return
	_set_mode(Mode.TURN)
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
	_walking.clear()
	_ticks_queued = 0
	_combat_pending = false
	_kill_pending = false
	resolving_tick = false
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
	_begin_round(true)
	_log("--- Turn %d: %d units in the pool ---" % [turn_number, pool.size()])
	_draw_next()


## A new round begins (plan B.1): the count moves on, the downed bleed, lights
## flicker and `turn_started` fires. Shared by a combat round (`_start_turn`,
## which then draws) and an exploration tick (which runs the AI pass instead).
## `take_pool` snapshots the draw pool where it always was: after the bleed,
## before `turn_started`.
func _begin_round(take_pool: bool) -> void:
	turn_number += 1
	# Before the pool, so the snapshot is taken of a board the bleed has already
	# settled — and before `turn_started`, so a soldier who bleeds out this round
	# is already a corpse when the HUD, the ship and the AI first look at it.
	_bleed_downed()
	if take_pool:
		pool = _all_units()
	var flicker_seed := randi()
	LightingManager.reroll_flicker(flicker_seed)  # Sec 5.3: flickering lights fluctuate turn-to-turn
	turn_started.emit(turn_number)
	if SteamLobby.is_networked() and SteamLobby.is_host():
		_rpc_turn_started.rpc(turn_number, flicker_seed)
	_broadcast_clock()


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
	if mission_over or mode != Mode.TURN:
		return
	if _check_end_conditions():
		return
	# `is_instance_valid` FIRST, and it is load-bearing rather than defensive.
	# The pool is a snapshot taken at turn start, and a worm absorbed into a mass
	# leaves the board by being freed rather than by dying (WormUnit.dissolve) —
	# so between two draws an entry here can become a freed object, and reading
	# `.is_downed` off one is a hard crash.
	pool = pool.filter(func(u: Unit) -> bool: return is_instance_valid(u) and not u.is_downed)
	# A won fight closes the round here, whoever had yet to act: out of combat their
	# actions are free, so nobody loses anything by not being drawn.
	var fight_won := _kill_pending and _fight_is_won()
	_kill_pending = false
	if fight_won:
		pool.clear()
	elif _squad_in_contact():
		_last_squad_combat_round = turn_number
	if pool.is_empty():
		await _end_round()
		# A hook may have ended the mission (the last soldiers flew out), or
		# changed the board enough to (departure leaving nobody standing).
		if mission_over or _check_end_conditions():
			return
		# Plan B.9: a full round with nothing fighting the squad, and the fight is
		# over — the next round opens out of combat instead of with a draw. A won
		# fight needs no such round, unless the round's end just woke something.
		if exploration_enabled and ((fight_won and _fight_is_won())
				or ExplorationRules.quiet_for_a_round(_last_squad_combat_round, turn_number)):
			_leave_turn_mode()
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
		# A shot involving the squad is contact whether or not the target lives to
		# notice — a kill never reaches `come_under_fire`, and a soldier has no
		# such thing to reach (plan B.8).
		if ExplorationRules.targets_squad(watcher.faction) or ExplorationRules.targets_squad(mover.faction):
			_last_squad_combat_round = turn_number
			_begin_contact()
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
	var why := may_act(unit, sender, &"end_activation")
	if why != "":
		push_warning("TurnManager: rejected end_activation from peer %d for %s — %s" % [
			sender, unit.stats.display_name, why])
		return
	_finish_activation(unit)


func _finish_activation(unit: Unit) -> void:
	if mode != Mode.TURN or unit != active_unit or not _awaiting_player:
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


# --- Exploration (GDD §4.7, EXPLORATION_PLAN.md Phase B) ------------------------


func _set_mode(new_mode: Mode) -> void:
	var changed := mode != new_mode
	mode = new_mode
	if changed:
		mode_changed.emit(mode)


## Host: switch modes here and on every client. Entering exploration drops the
## drawn unit, so each peer picks its own soldier again (plan A.6, C.5).
func _enter_mode(new_mode: Mode) -> void:
	if new_mode == Mode.EXPLORATION:
		pool.clear()
		_awaiting_player = false
		steps = 0
		_ticks_queued = 0
	_set_mode(new_mode)
	if SteamLobby.is_networked() and SteamLobby.is_host():
		_rpc_mode_changed.rpc(new_mode, steps, turn_number)
	if new_mode == Mode.EXPLORATION:
		reselect_local()
	_broadcast_clock()


@rpc("authority", "call_remote", "reliable")
func _rpc_mode_changed(new_mode: int, clock_steps: int, number: int) -> void:
	steps = clock_steps
	turn_number = number
	# Turn mode's first draw names the unit (`_rpc_sync_active_unit`); until then
	# this peer's old selection must not read as "your turn".
	if new_mode == Mode.TURN:
		active_unit = null
	_set_mode(new_mode as Mode)
	if mode == Mode.EXPLORATION:
		reselect_local()
	clock_changed.emit(steps, turn_number)


func _broadcast_clock() -> void:
	clock_changed.emit(steps, turn_number)
	if SteamLobby.is_networked() and SteamLobby.is_host():
		_rpc_clock.rpc(steps, turn_number)


## Plan C.3: the clients' HUD clock. The count itself lives on the host only.
@rpc("authority", "call_remote", "reliable")
func _rpc_clock(clock_steps: int, number: int) -> void:
	steps = clock_steps
	turn_number = number
	clock_changed.emit(steps, turn_number)


## This peer's player picks `unit` to command, in exploration only (plan A.6):
## `active_unit` is each peer's own selection there, set locally with no RPC —
## the host never reads it for authority (`may_act` does that). Refused for a
## soldier this peer does not own, or one down. Null clears it.
func select(unit: Unit) -> void:
	if mode != Mode.EXPLORATION:
		return
	if unit != null and (not unit.is_player_controlled or not unit.is_owned_by_local_player()
			or unit.is_downed or unit.aboard or not unit.is_inside_tree()):
		return
	active_unit = unit
	unit_selected.emit(unit)


## Keeps this peer's selection if it is still one of its own standing soldiers,
## else picks the first that is (plan C.5). Every peer runs this for itself.
func reselect_local() -> void:
	# Validity first, and untyped until then: a typed local cannot hold a freed one.
	if is_instance_valid(active_unit) and active_unit.is_player_controlled \
			and active_unit.is_owned_by_local_player() and not active_unit.is_downed and not active_unit.aboard:
		select(active_unit)
		return
	active_unit = null
	for unit in own_squad():
		select(unit)
		return
	unit_selected.emit(null)


## This peer's own standing soldiers, in node-name order — the order the portrait
## bar and Tab use.
func own_squad() -> Array[Unit]:
	var out: Array[Unit] = []
	for node in get_tree().get_nodes_in_group("player_units"):
		var unit := node as Unit
		if unit and unit.is_player_controlled and unit.is_owned_by_local_player() and not unit.is_downed:
			out.append(unit)
	out.sort_custom(func(a: Unit, b: Unit) -> bool: return String(a.name) < String(b.name))
	return out


## Records `n` steps on the clock (plan B.2). Host-only, and RECORD only: a
## round crossed is queued, and runs at the next `settle_clock`, with the
## remainder carried (E6). Ignored outside exploration and once contact is
## pending — leftover steps are discarded on the switch anyway (E19).
func add_steps(n: int) -> void:
	if not _is_authority() or mode != Mode.EXPLORATION or _combat_pending or n <= 0:
		return
	var after := ExplorationRules.advance(steps, n, STEPS_PER_ROUND)
	steps = after.x
	_ticks_queued += after.y
	_broadcast_clock()


## Runs any round the clock has crossed, or waits for one already running.
## Coroutine. Called at every tile boundary of a soldier's walk and at the end of
## every command, which is what pauses every walker reaching a boundary while a
## tick runs (E5) and lands an action before the round it crossed (E6).
func settle_clock() -> void:
	if not _is_authority():
		return
	while not mission_over and mode == Mode.EXPLORATION and not _combat_pending:
		if _ticking:
			await tick_finished
			continue
		if _ticks_queued <= 0:
			return
		_ticks_queued -= 1
		await _tick()


## Wait (plan B.10): burns the clock to the next boundary and runs that round.
## Always exactly one round (E11). Not a `pay`, so it never counts as anybody
## acting and never clears an overwatch (E26).
func wait_round() -> void:
	if not _is_authority() or mode != Mode.EXPLORATION or _combat_pending:
		return
	add_steps(ExplorationRules.steps_to_boundary(steps, STEPS_PER_ROUND))
	await settle_clock()


## Per-tile exploration work for a walking soldier (plans B.2, B.4, B.8), called
## by `Unit.move_along` after its overwatch checks. Coroutine.
func after_step(walker: Unit) -> void:
	if not _is_authority() or mode != Mode.EXPLORATION:
		return
	if not walker.is_player_controlled:
		return
	# Moving is acting: an overwatch held since the last fight is let go (B.8).
	walker.on_overwatch = false
	walker.overwatch_reserve = 0
	_detect_around(walker)
	if _combat_pending:
		return
	add_steps(walker.move_ap_per_tile())
	await settle_clock()


## Per-step detection (plan B.4, E23): every enemy close enough to have noticed
## the walker looks for targets with its OWN rules, so a robot still ranks by
## threat and a merc still radios its crew. A nest has no senses; one already
## fighting is not shopping around. Anything that spots a soldier reaches
## `notify_combat` through `_enter_combat`.
func _detect_around(walker: Unit) -> void:
	for node in get_tree().get_nodes_in_group("enemy_units"):
		var enemy := node as EnemyUnit
		if enemy == null or enemy is NestUnit or enemy.is_downed:
			continue
		if enemy.alert_state == EnemyUnit.AlertState.COMBAT:
			continue
		var reach := roundi(enemy.detection_range * maxf(1.0, walker.visibility_multiplier()))
		if GridManager.chebyshev_dist(enemy.grid_pos, walker.grid_pos) > reach:
			continue
		enemy._look_for_targets()
		if _combat_pending:
			return


## One round of the step clock (plan B.2): the round ends (hooks first, so a
## departure can still end the mission), the next begins, and every non-player
## unit takes its turn.
func _tick() -> void:
	_ticking = true
	await _end_round()
	if not mission_over and not _check_end_conditions():
		_begin_round(false)
		_log("--- Round %d ---" % turn_number)
		await _ai_pass()
	_ticking = false
	tick_finished.emit()
	if not mission_over:
		_check_end_conditions()


## Every non-player unit's turn for a tick, in weighted-initiative order (plan
## B.2, B.12). Decided ONE AT A TIME as logic only — the same instant path a
## hidden unit takes — and recorded, then played back together. Stops early if
## contact starts mid-pass (E20); whoever started it is the last one recorded.
func _ai_pass() -> void:
	var units: Array[Unit] = []
	for unit in _all_units():
		if not unit.is_player_controlled:
			units.append(unit)
	var order := _initiative_order(units)
	resolving_tick = true
	_timeline.clear()
	for unit in order:
		if mission_over or _combat_pending:
			break
		if not is_instance_valid(unit) or unit.is_downed or not unit.is_inside_tree():
			continue
		unit.begin_activation()
		if unit.stunned:
			unit.stunned = false
			unit.ap = 0
			_log("%s is STUNNED and loses their turn!" % unit.stats.display_name)
			continue
		if unit is EnemyUnit:
			await unit.take_turn()
	resolving_tick = false
	var events := _timeline.duplicate()
	_timeline.clear()
	await _play_tick(events)


## Weighted random order without replacement — the draw's roulette wheel on
## Initiative, run to the end.
func _initiative_order(units: Array[Unit]) -> Array[Unit]:
	var rest := units.duplicate()
	var out: Array[Unit] = []
	while not rest.is_empty():
		var total := 0.0
		for unit in rest:
			total += unit.stats.initiative()
		var roll := randf() * total
		var drawn: Unit = rest[-1]
		for unit in rest:
			roll -= unit.stats.initiative()
			if roll < 0.0:
				drawn = unit
				break
		rest.erase(drawn)
		out.append(drawn)
	return out


## Appends one event to the tick being decided (plan B.12). A no-op outside a
## tick's AI pass. Units are keyed by node on the host; the timeline goes to
## clients by path.
func record(event: Dictionary) -> void:
	if resolving_tick:
		_timeline.append(event)


func _play_tick(events: Array) -> void:
	if _playback == null:
		_playback = TickPlayback.new()
	await _playback.play_host(events, get_tree())


## Plan C.9: a client plays the host's tick from the same timeline, on its own
## models, display layer and visibility. The host's paused walks resume when the
## HOST's playback ends; nothing waits on this one.
@rpc("authority", "call_remote", "reliable")
func _rpc_play_tick(wire: Array) -> void:
	if _playback == null:
		_playback = TickPlayback.new()
	await _playback.play(TickPlayback.from_wire(wire, get_tree().root), get_tree())


## An enemy just entered COMBAT against `target` (EnemyUnit._enter_combat, the
## one funnel every channel reaches — sight, beam, gunfire, a merc's radio). If
## the target is on the squad's side, this is contact (plan B.3).
func notify_combat(enemy: Unit, target: Unit) -> void:
	if not _is_authority() or enemy == null or target == null:
		return
	# A nest has no senses and fights nobody: lit or shot, it still does nothing.
	if enemy is NestUnit or not ExplorationRules.targets_squad(target.faction):
		return
	_last_squad_combat_round = turn_number
	_begin_contact()


## A unit just fell (Unit._set_life_state). A hostile falling in a fight may be the
## one that wins it, which ends the fight without the quiet round (plan B.9). Also
## while a switch to turn mode is pending: an opening shot can kill its only target.
func notify_unit_down(unit: Unit) -> void:
	if not _is_authority() or not exploration_enabled or mission_over:
		return
	if mode != Mode.TURN and not _combat_pending:
		return
	if unit is EnemyUnit and Faction.is_hostile(Faction.Id.CONTRACTORS, unit.faction):
		_kill_pending = true
		_close_won_fight.call_deferred()


## The kill landed in a soldier's activation, so no draw is coming until it ends: if
## that kill won the fight, end it, once the shot on screen has finished. Every other
## case is the next draw's to read: an AI turn, or a switch to turn mode still pending.
func _close_won_fight() -> void:
	while _squad_busy() and not mission_over:
		await get_tree().process_frame
	if _kill_pending and mode == Mode.TURN and _awaiting_player and _fight_is_won():
		_finish_activation(active_unit)


## Nothing left for the squad to worry about: nobody fighting it, and no hostile
## awake within CALM_RADIUS of a soldier still standing.
func _fight_is_won() -> bool:
	if _squad_in_contact():
		return false
	for node in get_tree().get_nodes_in_group("enemy_units"):
		var enemy := node as EnemyUnit
		if enemy == null or enemy.is_downed or enemy.alert_state != EnemyUnit.AlertState.ALERT \
				or not Faction.is_hostile(Faction.Id.CONTRACTORS, enemy.faction):
			continue
		for other in get_tree().get_nodes_in_group("player_units"):
			var soldier := other as Unit
			if soldier and not soldier.is_downed \
					and GridManager.chebyshev_dist(enemy.grid_pos, soldier.grid_pos) <= CALM_RADIUS:
				return false
	return true


## A soldier attacked from exploration (plan B.7): that alone starts the fight,
## whether or not the target lived to notice. `cost` comes out of the shooter's
## first combat activation (E8); an opening Suppress is their whole first
## activation instead (E21).
func notify_attack(shooter: Unit, cost: int, opening_suppress := false) -> void:
	if not _is_authority() or mode != Mode.EXPLORATION:
		return
	if opening_suppress:
		shooter.opening_suppress = true
	else:
		shooter.pre_spent_ap += cost
	_last_squad_combat_round = turn_number
	_begin_contact()


func _begin_contact() -> void:
	if mode != Mode.EXPLORATION or _combat_pending or mission_over:
		return
	_combat_pending = true
	# Out of combat a soldier's AP means nothing — except to an `--auto` think
	# running against a synthetic budget, which this ends.
	for node in get_tree().get_nodes_in_group("player_units"):
		(node as Unit).ap = 0
	# Soldiers' walks stop at the tile each is stepping onto (E7) — including one
	# paused at a tick, which sees the flag when the tick ends. AI walks inside a
	# tick are its own and finish as decided.
	for unit in _walking.duplicate():
		if is_instance_valid(unit) and unit.is_player_controlled:
			unit.cancel_walk()
	_enter_turn_mode.call_deferred()


## The switch to turn mode (plan B.3), once everything in flight has landed:
## the tick and its playback, every walk, every soldier's action. The round in
## progress becomes the opening combat round (E19) — same `turn_number`, no
## round start, so contact by itself ticks no timer — and the leftover steps go.
func _enter_turn_mode() -> void:
	while _ticking:
		await tick_finished
	await cancel_all_walks()
	while _squad_busy() or hold_switch > 0:
		await get_tree().process_frame
	if mission_over or mode != Mode.EXPLORATION:
		_combat_pending = false
		return
	_combat_pending = false
	active_unit = null
	_enter_mode(Mode.TURN)
	steps = 0
	_ticks_queued = 0
	_broadcast_clock()
	# An opening Suppress is the suppressor's whole first activation (E21): they
	# sit this round out with the pin held, and it releases at their next one.
	pool = _all_units().filter(func(u: Unit) -> bool: return not u.opening_suppress)
	for unit in _all_units():
		unit.opening_suppress = false
	_log("--- Contact! Round %d is a combat round: %d units in the pool ---" % [turn_number, pool.size()])
	_draw_next()


func _squad_busy() -> bool:
	for node in get_tree().get_nodes_in_group("player_units"):
		var unit := node as Unit
		if unit and unit.is_busy and not unit.is_downed:
			return true
	return false


## Back to exploration at the start of a new round (plan B.9, E10). The postures
## that only mean something under fire are dropped — hunker, both ends of
## suppression, a stun nobody will draw — and overwatch is KEPT, so a squad can
## sit in an ambush between fights.
func _leave_turn_mode() -> void:
	for node in get_tree().get_nodes_in_group("units"):
		var unit := node as Unit
		if unit == null:
			continue
		var was_hunkered := unit.hunkered
		unit.hunkered = false
		unit.release_suppression()
		unit.suppressed_by = null
		unit.stunned = false
		unit.opening_suppress = false
		unit.pre_spent_ap = 0
		if was_hunkered and not unit.is_downed:
			unit.settle_idle()
	active_unit = null
	_enter_mode(Mode.EXPLORATION)
	_begin_round(false)
	_log("--- Round %d: the deck goes quiet — exploring ---" % turn_number)
	_check_end_conditions()


## Out of combat nothing draws, so nothing else would notice the board has run out
## of soldiers between ticks: the last one up the ramp has to say so, or the mission
## waits on commands nobody is left to give (GDD §7.4).
func squad_changed() -> void:
	if _is_authority() and mode == Mode.EXPLORATION and not mission_over:
		_check_end_conditions()


## Whether anything is still fighting the squad: an enemy in COMBAT whose target
## is on the squad's side (plan B.9).
func _squad_in_contact() -> bool:
	for node in get_tree().get_nodes_in_group("enemy_units"):
		var enemy := node as EnemyUnit
		if enemy == null or enemy.is_downed or enemy.alert_state != EnemyUnit.AlertState.COMBAT:
			continue
		# Never takes a turn, so never gets to lose contact: counted, it would hold
		# the squad in turn mode for the rest of the mission.
		if enemy is NestUnit:
			continue
		if is_instance_valid(enemy.target) and ExplorationRules.targets_squad(enemy.target.faction):
			return true
	return false
