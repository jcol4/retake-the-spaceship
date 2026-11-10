extends SceneTree
## Horde performance probe: how long one horde's activation takes to DECIDE
## (TurnManager._horde_turn, which runs as logic in a single frame before the
## pack's playback starts), and what the per-step primitives it leans on cost.
##
##   godot --headless --path . --script res://tools/profile_horde.gd -- --seed=7 --bodies=24
##
## Windowed (drop --headless) it also plays the horde back and reports the
## frame times seen while the pack walks.
##
## Scripts are load()ed and locals stay untyped (see test_cerberus.gd).

const SWARM := "res://scenes/swarm_unit.tscn"
const PLAYER := "res://scenes/player_unit.tscn"

var _grid: Node
var _turns: Node
var _light: Node


func _initialize() -> void:
	_grid = root.get_node_or_null("GridManager")
	_turns = root.get_node_or_null("TurnManager")
	_light = root.get_node_or_null("LightingManager")
	var bodies := 24
	var runs := 3
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--bodies="):
			bodies = int(arg.trim_prefix("--bodies="))
		elif arg.begins_with("--runs="):
			runs = int(arg.trim_prefix("--runs="))
	var map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(map)
	await process_frame
	await process_frame
	print("deck tiles: %d" % _grid.tiles.size())

	var soldier_at: Vector3i = map.player_spawns[0] if not map.player_spawns.is_empty() else _grid.tiles.keys()[0]
	var soldier = await _spawn(PLAYER, soldier_at)
	soldier.flashlight_on = true
	var placed := _place_horde(soldier_at, bodies)
	if placed.is_empty():
		print("no spot for a horde of %d" % bodies)
		quit(1)
		return
	_bench_primitives(placed[0], soldier_at, map)

	for run in runs:
		var pack: Array = []
		for i in placed.size():
			var swarm = load(SWARM).instantiate()
			swarm.stats = AlienPresets.swarm("Prof_%d_%d" % [run, i])
			swarm.horde_id = "prof_%d" % run
			swarm.name = "Prof_%d_%d" % [run, i]
			swarm.position = _grid.grid_to_world(placed[i])
			root.add_child(swarm)
			pack.append(swarm)
		await process_frame
		await process_frame
		if run == 0:
			check_paths_match(400)
			if DisplayServer.get_name() != "headless":
				var cam := Camera3D.new()
				root.add_child(cam)
				var c: Vector3 = (_grid.grid_to_world(placed[0]) + _grid.grid_to_world(soldier_at)) * 0.5
				cam.look_at_from_position(c + Vector3(7, 13, 7), c)
				cam.current = true
		# Drawn, as a horde the squad has spotted would be.
		if "_spotted" in map:
			for s in pack:
				map._spotted[s] = true
		pack[0].come_under_fire(soldier)
		_turns.pool.clear()
		_turns.pool.append_array(pack)
		_turns.pool.erase(pack[0])
		var mates: Array = _turns._horde_mates(pack[0])
		pack[0].begin_activation()
		var frames: Array[float] = []
		var t0 := Time.get_ticks_usec()
		var f0 := Engine.get_process_frames()
		var timing := {"done": false}
		_frame_watch(frames, timing)
		await _turns._horde_turn(pack[0], mates)
		timing["done"] = true
		var total := (Time.get_ticks_usec() - t0) / 1000.0
		var moved := 0
		for s in pack:
			if s.grid_pos != placed[pack.find(s)]:
				moved += 1
		frames.sort()
		var worst: float = frames[-1] if not frames.is_empty() else 0.0
		var over := frames.filter(func(f: float) -> bool: return f > 20.0).size()
		if frames.size() > 10:
			print("  frame ms p50 %.1f  p95 %.1f  p99 %.1f  top5 %s" % [frames[frames.size() / 2],
				frames[int(frames.size() * 0.95)], frames[int(frames.size() * 0.99)], frames.slice(-5)])
		print("run %d: horde of %d, %d moved — total %.1f ms over %d frames; worst frame %.1f ms, %d frames > 20 ms" % [
			run, pack.size(), moved, total, Engine.get_process_frames() - f0, worst, over])
		var held := {}
		var shared := 0
		var wrong_occ := 0
		var touching := 0
		for s in pack:
			if held.has(s.grid_pos):
				shared += 1
			held[s.grid_pos] = true
			if _grid.get_tile(s.grid_pos).occupant != s:
				wrong_occ += 1
			if _grid.is_melee_adjacent(s.grid_pos, soldier.grid_pos):
				touching += 1
		if _turns._playback != null and "crowd_timeouts" in _turns._playback:
			print("  crowd: %d wedged (%s), %.1f body-seconds straining" % [_turns._playback.crowd_timeouts.size(),
				_turns._playback.crowd_timeouts, _turns._playback.crowd_stall_seconds])
			if _turns._playback.crowd_frames > 0:
				print("  crowd steering: %.2f ms/frame over %d frames" % [_turns._playback.crowd_steer_usec / 1000.0 / _turns._playback.crowd_frames, _turns._playback.crowd_frames])
		print("  shared tiles %d, occupancy mismatches %d, bodies beside the prey %d" % [shared, wrong_occ, touching])
		# With the pack now crowding its prey: every body's way in, old vs new.
		var differ := 0
		for s in pack:
			for occ in [true, false]:
				if _old_find_path(s.grid_pos, soldier.grid_pos, 999, occ) != _grid.find_path(s.grid_pos, soldier.grid_pos, 999, occ):
					differ += 1
		print("  pack -> prey paths old vs new: %d differ" % differ)
		_turns.pool.clear()
		for s in pack:
			_grid.set_occupant(s.grid_pos, null)
			s.queue_free()
		await process_frame
		await process_frame
	quit(0)


func _frame_watch(frames: Array[float], timing: Dictionary) -> void:
	var last := Time.get_ticks_usec()
	while not timing["done"]:
		await process_frame
		var now := Time.get_ticks_usec()
		frames.append((now - last) / 1000.0)
		last = now
		if OS.has_environment("PROFILE_SHOT") and frames.size() in [20, 60, 100, 140, 200, 280]:
			root.get_texture().get_image().save_png(OS.get_environment("PROFILE_SHOT") % frames.size())


func _bench_primitives(from: Vector3i, to: Vector3i, map) -> void:
	var n := 20
	var t := Time.get_ticks_usec()
	var len := 0
	for i in n:
		len = _grid.find_path(from, to, 999, true).size()
	print("find_path (len %d): %.2f ms" % [len, (Time.get_ticks_usec() - t) / 1000.0 / n])
	var far := from
	var costs: Dictionary = _grid.reachable_costs(from, 999)
	for p: Vector3i in costs:
		if costs[p] > costs.get(far, 0):
			far = p
	t = Time.get_ticks_usec()
	for i in n:
		len = _grid.find_path(from, far, 999, true).size()
	print("find_path farthest tile (len %d, whole deck): %.2f ms" % [len, (Time.get_ticks_usec() - t) / 1000.0 / n])
	t = Time.get_ticks_usec()
	for i in n:
		_grid.reachable_costs(from, 999)
	print("reachable_costs whole deck: %.2f ms" % [(Time.get_ticks_usec() - t) / 1000.0 / n])
	t = Time.get_ticks_usec()
	for i in n:
		_light.recompute_dynamic()
	print("LightingManager.recompute_dynamic: %.2f ms" % [(Time.get_ticks_usec() - t) / 1000.0 / n])
	t = Time.get_ticks_usec()
	for i in n:
		map._apply_unit_visibility()
	print("MapBuilder._apply_unit_visibility: %.2f ms" % [(Time.get_ticks_usec() - t) / 1000.0 / n])
	t = Time.get_ticks_usec()
	for i in n:
		map._process(0.016)
	print("MapBuilder._process: %.2f ms" % [(Time.get_ticks_usec() - t) / 1000.0 / n])


## The new find_path must return exactly what the old one did. Random pairs,
## with whatever is standing on the deck at the time as obstacles.
func check_paths_match(samples: int) -> void:
	var keys: Array = _grid.tiles.keys()
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var bad := 0
	var t_old := 0
	var t_new := 0
	for i in samples:
		var a: Vector3i = keys[rng.randi_range(0, keys.size() - 1)]
		var b: Vector3i = keys[rng.randi_range(0, keys.size() - 1)]
		var occ := rng.randf() < 0.5
		var cap := 999 if rng.randf() < 0.7 else rng.randi_range(1, 30)
		var t := Time.get_ticks_usec()
		var old := _old_find_path(a, b, cap, occ)
		t_old += Time.get_ticks_usec() - t
		t = Time.get_ticks_usec()
		var new: Array = _grid.find_path(a, b, cap, occ)
		t_new += Time.get_ticks_usec() - t
		if old != new:
			bad += 1
			if bad <= 3:
				print("  MISMATCH %s -> %s cap %d occ %s: old %d new %d" % [a, b, cap, occ, old.size(), new.size()])
	print("find_path old vs new: %d/%d differ; old %.1f ms total, new %.1f ms total" % [
		bad, samples, t_old / 1000.0, t_new / 1000.0])


func _old_find_path(from: Vector3i, to: Vector3i, max_tiles: int, allow_occupied_goal := false) -> Array:
	if from == to:
		return []
	var parent := {from: from}
	var depth := {from: 0}
	var turns := {from: 0}
	var heading := {from: Vector3i.ZERO}
	var goal_depth := -1
	var frontier: Array[Vector3i] = [from]
	while not frontier.is_empty():
		var cur: Vector3i = frontier.pop_front()
		var cur_depth: int = depth[cur]
		if cur_depth >= max_tiles:
			continue
		if goal_depth >= 0 and cur_depth >= goal_depth:
			break
		for n in _grid.neighbors(cur):
			if not _grid._path_open(n, to, allow_occupied_goal, null, {}):
				continue
			var step: Vector3i = n - cur
			var straight: bool = step.y != 0 \
				or heading[cur] == Vector3i.ZERO or heading[cur] == step
			var cost: int = turns[cur] + (0 if straight else 1)
			if not depth.has(n):
				depth[n] = cur_depth + 1
				turns[n] = cost
				heading[n] = Vector3i.ZERO if step.y != 0 else step
				parent[n] = cur
				if n == to:
					goal_depth = cur_depth + 1
				frontier.append(n)
			elif depth[n] == cur_depth + 1 and cost < turns[n]:
				turns[n] = cost
				heading[n] = Vector3i.ZERO if step.y != 0 else step
				parent[n] = cur
	if not parent.has(to):
		return []
	var path: Array = []
	var walk := to
	while walk != from:
		path.push_front(walk)
		walk = parent[walk]
	return path


## `count` free tiles bunched round a centre 10-18 steps from the soldier.
func _place_horde(soldier_at: Vector3i, count: int) -> Array:
	var costs: Dictionary = _grid.reachable_costs(soldier_at, 18)
	for centre: Vector3i in costs:
		if costs[centre] < 10:
			continue
		var spot: Array = []
		for r in range(0, 4):
			for dz in range(-r, r + 1):
				for dx in range(-r, r + 1):
					if maxi(absi(dx), absi(dz)) != r:
						continue
					var p := centre + Vector3i(dx, 0, dz)
					if costs.has(p) and _grid.is_free(p) and spot.size() < count:
						spot.append(p)
		if spot.size() >= count:
			print("horde centre %s, %d steps from the soldier" % [centre, costs[centre]])
			return spot
	return []


func _spawn(scene_path: String, at: Vector3i):
	var unit = load(scene_path).instantiate()
	unit.position = _grid.grid_to_world(at)
	root.add_child(unit)
	await process_frame
	return unit
