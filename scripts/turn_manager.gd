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


func start_mission() -> void:
	turn_number = 0
	mission_over = false
	_start_turn()


func _all_units() -> Array[Unit]:
	var out: Array[Unit] = []
	for node in get_tree().get_nodes_in_group("units"):
		var unit := node as Unit
		if unit and not unit.is_downed:
			out.append(unit)
	return out


func _start_turn() -> void:
	turn_number += 1
	pool = _all_units()
	LightingManager.reroll_flicker()  # Sec 5.3: flickering lights fluctuate turn-to-turn
	turn_started.emit(turn_number)
	log_message.emit("--- Turn %d: %d units in the pool ---" % [turn_number, pool.size()])
	_draw_next()


func _draw_next() -> void:
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
	log_message.emit("%s drawn from the pool" % drawn.stats.display_name)
	unit_activated.emit(drawn)
	if drawn is EnemyUnit:
		await drawn.take_turn()  # animated moves — must finish before the next draw
		if mission_over:
			return
		active_unit = null
		# Defer so deep recursion can't build up over many draws.
		call_deferred("_draw_next")
	else:
		_awaiting_player = true  # wait for end_activation from the player unit


func check_overwatch(mover: Unit) -> void:
	# Sec 4.2: a unit holding Overwatch interrupts the draw order to fire when
	# an *enemy* walks into its sightline — never on allied movement. Called by
	# Unit.move_along after each tile, so the shot lands mid-walk.
	if mission_over or mover.is_downed:
		return
	for node in get_tree().get_nodes_in_group("units"):
		var watcher := node as Unit
		if watcher == null or watcher == mover or not watcher.on_overwatch or watcher.is_downed:
			continue
		if watcher.is_player_controlled == mover.is_player_controlled:
			continue
		if not watcher.can_shoot() or not GridManager.has_line_of_sight(watcher, mover):
			continue
		watcher.on_overwatch = false  # the reserved shot is spent
		var result: Combat.ShotResult = await watcher.fire_at(mover, Combat.ShotAction.SHOOT)
		log_message.emit("OVERWATCH! %s fires at %s (%d%% acc): %s" % [
			watcher.stats.display_name, mover.stats.display_name, result.accuracy, Combat.describe(result),
		])
		if mover.is_downed:
			log_message.emit("%s is DOWN!" % mover.stats.display_name)
			return


func end_activation(unit: Unit) -> void:
	if unit != active_unit or not _awaiting_player:
		return
	_awaiting_player = false
	active_unit = null
	call_deferred("_draw_next")


func _check_end_conditions() -> bool:
	var players_alive := false
	var enemies_alive := false
	for node in get_tree().get_nodes_in_group("units"):
		var unit := node as Unit
		if unit == null or unit.is_downed:
			continue
		if unit.is_player_controlled:
			players_alive = true
		else:
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
	log_message.emit("=== MISSION %s ===" % ("WON — all hostiles down" if player_won else "FAILED — squad wiped"))
	mission_ended.emit(player_won)
