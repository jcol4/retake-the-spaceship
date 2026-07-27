class_name EnemyUnit
extends Unit
## Minimal iteration-1 AI: shoot nearest visible player unit if in range and
## LOS is clear, otherwise move closer. Full state machine (Sec 11) deferred.

const ATTACK_RANGE := 8  # tiles (Chebyshev)

signal action_logged(text: String)


func _init() -> void:
	is_player_controlled = false
	has_flashlight = false  # aliens rely on their own senses, not a rig light


func take_turn() -> void:
	# Coroutine — moves are animated, so TurnManager must `await` this before
	# drawing the next unit from the pool.
	while ap > 0 and not is_downed:
		var target := _nearest_player()
		if target == null:
			return
		var in_range := GridManager.chebyshev_dist(grid_pos, target.grid_pos) <= ATTACK_RANGE
		if in_range and GridManager.has_line_of_sight(self, target) and can_shoot():
			spend_ap(1)
			var result: Combat.ShotResult = await fire_at(target, Combat.ShotAction.SHOOT)
			action_logged.emit("%s fired at %s (%d%% acc): %s" % [stats.display_name, target.stats.display_name, result.accuracy, Combat.describe(result)])
			if target.is_downed:
				action_logged.emit("%s is DOWN!" % target.stats.display_name)
		elif not can_shoot():
			spend_ap(1)
			await do_reload()
			action_logged.emit("%s reloaded" % stats.display_name)
		else:
			await _move_toward(target)


func _nearest_player() -> Unit:
	var best: Unit = null
	var best_dist := 999999
	for unit in get_tree().get_nodes_in_group("player_units"):
		if unit.is_downed:
			continue
		var d := GridManager.chebyshev_dist(grid_pos, unit.grid_pos)
		if d < best_dist:
			best_dist = d
			best = unit
	return best


func _move_toward(target: Unit) -> void:
	# Path all the way to the target's tile (allowed occupied), then walk the
	# first move_run steps of it — routes around walls instead of greedy
	# straight-line chasing.
	var full_path := GridManager.find_path(grid_pos, target.grid_pos, 999, true)
	if full_path.size() <= 1:
		ap = 0  # adjacent already or fully blocked — stop burning AP
		return
	full_path.resize(full_path.size() - 1)  # never step onto the target itself
	var steps := mini(stats.move_run(), full_path.size())
	var path := full_path.slice(0, steps)
	spend_ap(1)
	await move_along(path)
	action_logged.emit("%s moved to %s" % [stats.display_name, path[-1]])
