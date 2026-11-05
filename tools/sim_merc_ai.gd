extends SceneTree
## Merc AI behaviour simulation — many seeded skirmishes, every merc activation
## measured, aggregated into the numbers the AI fixes make claims about.
##
##   godot --headless --path . --script res://tools/sim_merc_ai.gd -- [--scenarios N] [--rounds N] [--label NAME]
##
## Not a pass/fail test: it prints a metrics table so two builds of the AI can be
## compared on identical seeds. The soldiers are targets, not players — they do
## not shoot back — but they are healed between activations so a fight lasts,
## optionally shuffle to a new tile each round (so mercs must re-solve), and some
## scenarios start the mercs wounded so the cover/caution logic is exercised.
##
## Self-contained on purpose: shot viability is computed here rather than through
## any helper in the AI it measures, so the same harness runs against old and new.

const MERC := "res://scenes/merc_unit.tscn"
const PLAYER := "res://scenes/player_unit.tscn"
const DECKS := ["res://maps/coordination_deck.txt", "res://maps/merc_duel_deck.txt"]
const MIN_VIABLE := 15

var _grid: Node
var _light: Node
var _turns: Node
var _map
var _ascii
var _doctrines
var _combat

var _scenarios := 24
var _rounds := 6
var _label := "run"

var _acts: Array = []  # one Dictionary per merc activation


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		match args[i]:
			"--scenarios": _scenarios = int(args[i + 1])
			"--rounds": _rounds = int(args[i + 1])
			"--label": _label = args[i + 1]
	_grid = root.get_node_or_null("GridManager")
	_turns = root.get_node_or_null("TurnManager")
	_light = root.get_node_or_null("LightingManager")
	_ascii = load("res://scripts/map_ascii.gd")
	_doctrines = load("res://scripts/ai/doctrines.gd")
	_combat = load("res://scripts/combat.gd")
	_map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(_map)
	await process_frame
	Engine.time_scale = 50.0

	var started := Time.get_ticks_msec()
	for s in _scenarios:
		await _run_scenario(s)
	_report(Time.get_ticks_msec() - started)
	quit(0)


func _run_scenario(index: int) -> void:
	var deck: String = DECKS[index % DECKS.size()]
	var moving_players := (index / DECKS.size()) % 2 == 1
	var wounded := (index / (DECKS.size() * 2)) % 2 == 1
	seed(1000 + index)
	_map.build(_ascii.load_file(deck))
	await process_frame
	_doctrines.reset()
	_turns.turn_number = 1
	_turns.mission_over = false

	var players: Array = []
	for tile in _map.player_spawns:
		players.append(await _spawn(PLAYER, tile))
	var spawns: Array = _map.merc_spawns.duplicate()
	spawns.shuffle()
	var mercs: Array = []
	for i in mini(3, spawns.size()):
		var m = await _spawn(MERC, spawns[i])
		m.squad_id = "sim"
		m.flashlight_on = true
		if wounded and randf() < 0.67:
			m.current_hp = maxi(1, int(m.stats.max_hp() * randf_range(0.2, 0.6)))
		mercs.append(m)
	# The game recomputes flashlight light on every step; spawning by hand does
	# not, so without this every tile reads as if no beam existed.
	_light.recompute_dynamic()
	# The fight is already on: one merc has the contact and radios it.
	for m in mercs:
		m._brain.blackboard = _doctrines.blackboard_for("sim")
	mercs[0]._enter_combat(players[0], "")

	var meta := {"deck": deck.get_file().get_basename(), "moving": moving_players,
		"wounded": wounded, "scenario": index}
	for r in _rounds:
		_turns.turn_number = r + 1
		if moving_players and r > 0:
			for p in players:
				_shuffle_player(p)
		var order: Array = mercs.duplicate()
		order.shuffle()
		for m in order:
			if not is_instance_valid(m) or m.is_downed:
				continue
			if _live(players).is_empty():
				break
			await _activate(m, players, meta, r)
			for p in players:
				if not p.is_downed:
					p.current_hp = p.stats.max_hp()
	_free(players + mercs)
	await process_frame


func _activate(m, players: Array, meta: Dictionary, round_index: int) -> void:
	var path: Array[Vector3i] = [m.grid_pos]
	var lines: Array[String] = []
	var on_step := func(u) -> void: path.append(u.grid_pos)
	var on_log := func(t: String) -> void: lines.append(t)
	m.stepped.connect(on_step)
	m.action_logged.connect(on_log)

	m.begin_activation()
	var start_ap: int = m.ap
	var shoot_cost: int = m.action_cost(0)
	var state_before: int = m.alert_state
	var quarry = m.target if state_before == 2 else null  # AlertState.COMBAT
	var had_shot: bool = quarry != null and not quarry.is_downed and m.can_shoot() \
		and start_ap >= shoot_cost and _viable(m, m.grid_pos, quarry)
	var dist_before: int = _nearest(m, players)
	var diag: String = _diagnose(m, quarry)

	await m.take_turn()

	m.stepped.disconnect(on_step)
	m.action_logged.disconnect(on_log)

	var shots := 0
	var suppress := 0
	var overwatch := 0
	var goap_moves := 0
	for line in lines:
		if "fires at" in line or "fires from cover" in line or "puts a round" in line \
				or "fires on the cover" in line:
			shots += 1
		elif "suppressing fire" in line:
			suppress += 1
		elif "holds overwatch" in line:
			overwatch += 1
		if "moves to flank" in line or "takes cover" in line or "advances on" in line:
			goap_moves += 1
	var walked := path.size() - 1
	var start: Vector3i = path[0]
	var end: Vector3i = path[-1]
	var max_out := 0
	var seen := {}
	var revisit := false
	for t in path:
		max_out = maxi(max_out, _grid.chebyshev_dist(start, t))
		if seen.has(t):
			revisit = true
		seen[t] = true
	var came_back: bool = max_out - _grid.chebyshev_dist(start, end) >= 2
	var dist_after: int = _nearest(m, players)
	_acts.append({
		"meta": meta, "round": round_index, "combat": state_before == 2,
		"state": state_before, "had_shot": had_shot,
		"attacked": shots + suppress > 0, "shots": shots, "suppress": suppress,
		"overwatch": overwatch, "goap_moves": goap_moves, "walked": walked,
		"shuttle": revisit or came_back,
		"adjacent": dist_after <= 1, "dist_before": dist_before, "dist_after": dist_after,
		"left_ap": m.ap, "shoot_cost": shoot_cost,
		"wasted": state_before == 2 and shots + suppress + overwatch == 0 \
			and walked > 0 and had_shot,
		"lines": lines, "diag": diag,
	})


func _viable(m, tile: Vector3i, t) -> bool:
	if not _grid.tiles_have_sight(m, tile, t.grid_pos, true, t.can_peek()):
		return false
	var real: Vector3i = m.grid_pos
	m.grid_pos = tile
	var acc: int = _combat.compute_accuracy(m, t, _combat.ShotAction.SHOOT)
	m.grid_pos = real
	return acc >= MIN_VIABLE


func _nearest(m, players: Array) -> int:
	var best := 999
	for p in _live(players):
		best = mini(best, _grid.chebyshev_dist(m.grid_pos, p.grid_pos))
	return best


func _live(players: Array) -> Array:
	return players.filter(func(p) -> bool: return is_instance_valid(p) and not p.is_downed)


## A soldier repositions between rounds: any free walkable tile within 4.
func _shuffle_player(p) -> void:
	if p.is_downed:
		return
	var options: Array = []
	for t: Vector3i in _map.data.walkable_positions():
		if t != p.grid_pos and _grid.chebyshev_dist(t, p.grid_pos) <= 4 and _grid.is_free(t) \
				and _grid.get_tile(t).passable:
			options.append(t)
	if options.is_empty():
		return
	var to: Vector3i = options[randi() % options.size()]
	_grid.set_occupant(p.grid_pos, null)
	p.grid_pos = to
	p.position = _grid.grid_to_world(to)
	_grid.set_occupant(to, p)
	_light.recompute_dynamic()


func _spawn(scene_path: String, at: Vector3i):
	var unit = load(scene_path).instantiate()
	if scene_path == MERC:
		unit.stats = MercPresets.rifleman("Merc")
	else:
		unit.stats = ClassPresets.roll(UnitStats.UnitClass.ASSAULT, "Soldier")
	unit.position = _grid.grid_to_world(at)
	root.add_child(unit)
	await process_frame
	return unit


func _free(units: Array) -> void:
	for unit in units:
		if is_instance_valid(unit):
			_grid.set_occupant(unit.grid_pos, null)
			unit.queue_free()


# --- Reporting -----------------------------------------------------------------

func _report(ms: int) -> void:
	print("")
	print("=== MERC AI SIM [%s] — %d scenarios x %d rounds, %d activations, %.1fs ===" % [
		_label, _scenarios, _rounds, _acts.size(), ms / 1000.0])
	_summary("ALL", _acts)
	for deck in ["coordination_deck", "merc_duel_deck"]:
		_summary(deck, _acts.filter(func(a): return a["meta"]["deck"] == deck))
	_summary("static players", _acts.filter(func(a): return not a["meta"]["moving"]))
	_summary("moving players", _acts.filter(func(a): return a["meta"]["moving"]))
	_summary("wounded mercs", _acts.filter(func(a): return a["meta"]["wounded"]))
	print("")
	print("--- sample shuttle activations ---")
	var n := 0
	for a in _acts:
		if a["shuttle"] and n < 4:
			n += 1
			print("  [%s s%d r%d] walked %d: %s" % [a["meta"]["deck"], a["meta"]["scenario"],
				a["round"], a["walked"], " | ".join(a["lines"])])
	print("--- sample overwatch activations ---")
	n = 0
	for a in _acts:
		if a["overwatch"] > 0 and n < 4:
			n += 1
			print("  [%s s%d r%d] had_shot=%s walked %d, dist %d->%d: %s" % [a["meta"]["deck"],
				a["meta"]["scenario"], a["round"], a["had_shot"], a["walked"],
				a["dist_before"], a["dist_after"], " | ".join(a["lines"])])
	print("--- sample ended-adjacent activations ---")
	n = 0
	for a in _acts:
		if a["adjacent"] and n < 4:
			n += 1
			print("  [%s s%d r%d] state=%d walked %d, dist %d->%d: %s" % [a["meta"]["deck"],
				a["meta"]["scenario"], a["round"], a["state"], a["walked"],
				a["dist_before"], a["dist_after"], " | ".join(a["lines"])])
	print("--- sample had-a-shot-but-did-not-fire activations ---")
	n = 0
	for a in _acts:
		if a["combat"] and a["had_shot"] and not a["attacked"] and n < 4:
			n += 1
			print("  [%s s%d r%d] walked %d, left %d AP: %s" % [a["meta"]["deck"],
				a["meta"]["scenario"], a["round"], a["walked"], a["left_ap"], " | ".join(a["lines"])])
	print("--- diagnostics: overwatch with no move ---")
	n = 0
	for a in _acts:
		if a["overwatch"] > 0 and a["walked"] == 0 and n < 6:
			n += 1
			print("  [%s s%d r%d] %s" % [a["meta"]["deck"], a["meta"]["scenario"], a["round"], a["diag"]])
	var ow_still := _acts.filter(func(a): return a["combat"] and a["overwatch"] > 0 and a["walked"] == 0).size()
	var lost := _acts.filter(func(a): return a["combat"] and a["had_shot"] and not a["attacked"] and " | ".join(a["lines"]).contains("loses track")).size()
	var missed := _acts.filter(func(a): return a["combat"] and a["had_shot"] and not a["attacked"]).size()
	print("of those, no path to target: %d" % _acts.filter(func(a): return a["combat"] and a["overwatch"] > 0 and a["walked"] == 0 and a["diag"].contains("path_to_target=0 ")).size())
	print("overwatch-without-moving: %d | had-shot-no-fire: %d, of which lost contact first: %d" % [ow_still, missed, lost])
	print("--- diagnostics: had a shot, did not attack ---")
	n = 0
	for a in _acts:
		if a["combat"] and a["had_shot"] and not a["attacked"] and n < 12:
			n += 1
			print("  [%s s%d r%d] %s
      => %s" % [a["meta"]["deck"], a["meta"]["scenario"], a["round"], a["diag"], " | ".join(a["lines"])])
	print("SIMJSON " + JSON.stringify(_numbers(_acts)))


func _numbers(acts: Array) -> Dictionary:
	var combat: Array = acts.filter(func(a): return a["combat"])
	var with_shot: Array = combat.filter(func(a): return a["had_shot"])
	var c := float(maxi(combat.size(), 1))
	var w := float(maxi(with_shot.size(), 1))
	var count := func(arr: Array, key: String) -> int:
		return arr.filter(func(a): return a[key]).size()
	var walked := 0
	var shots := 0
	for a in combat:
		walked += a["walked"]
		shots += a["shots"]
	return {
		"activations": acts.size(),
		"combat_acts": combat.size(),
		"attack_rate": count.call(combat, "attacked") / c,
		"shots_per_act": shots / c,
		"overwatch_rate": combat.filter(func(a): return a["overwatch"] > 0).size() / c,
		"had_shot_acts": with_shot.size(),
		"fired_when_had_shot": count.call(with_shot, "attacked") / w,
		"walked_away_from_shot": count.call(with_shot, "wasted") / w,
		"shuttle_rate": count.call(combat, "shuttle") / c,
		"multi_goap_move_rate": combat.filter(func(a): return a["goap_moves"] >= 2).size() / c,
		"adjacent_end_rate": count.call(combat, "adjacent") / c,
		"tiles_per_act": walked / c,
		"all_adjacent_end_rate": count.call(acts, "adjacent") / float(maxi(acts.size(), 1)),
	}


func _summary(title: String, acts: Array) -> void:
	var n := _numbers(acts)
	print("%-18s acts %3d (combat %3d) | attack %5.1f%% | shots/act %.2f | fired-when-had-shot %5.1f%% (n=%d) | walked-off-a-shot %5.1f%% | shuttle %5.1f%% | 2+ moves %5.1f%% | ends adjacent %5.1f%% | overwatch %5.1f%% | tiles/act %.1f" % [
		title, n["activations"], n["combat_acts"], n["attack_rate"] * 100, n["shots_per_act"],
		n["fired_when_had_shot"] * 100, n["had_shot_acts"], n["walked_away_from_shot"] * 100,
		n["shuttle_rate"] * 100, n["multi_goap_move_rate"] * 100, n["adjacent_end_rate"] * 100,
		n["overwatch_rate"] * 100, n["tiles_per_act"]])


## What the brain sees at the top of an activation: world facts, the shot's
## numbers, and the plan each goal would produce. Read-only.
func _diagnose(m, quarry) -> String:
	if quarry == null or m._brain == null:
		return ""
	var brain = m._brain
	var planner = load("res://scripts/ai/goap_planner.gd")
	var st: Dictionary = brain.read_state(m, quarry)
	var facts: Array = []
	for k in st:
		if st[k]:
			facts.append(String(k))
	var tl = _grid.get_tile(quarry.grid_pos)
	var out := "light %.0f/%s dist %d/%d | " % [tl.light_value if tl else -1.0, m.sight_light_threshold,
		_grid.chebyshev_dist(m.grid_pos, quarry.grid_pos), roundi(m.detection_range * quarry.visibility_multiplier())]
	out += "hp %d/%d ap %d ammo %d acc %d los %s has_shot_at %s | facts: %s" % [
		m.current_hp, m.stats.max_hp(), m.ap, m.ammo,
		_combat.compute_accuracy(m, quarry, _combat.ShotAction.SHOOT),
		_grid.has_line_of_sight(m, quarry), m.has_shot_at(quarry), ",".join(facts)]
	var ctx := {"target": quarry, "blackboard": brain.blackboard}
	for action in brain.actions:
		if String(action.name) in ["Attack", "Advance"]:
			out += " | %s.avail=%s" % [action.name, action.is_available(m, ctx)]
	var route: Array = _grid.find_path(m.grid_pos, quarry.grid_pos, 999, true)
	if route.is_empty():
		var held := {}
		var who: Array = []
		for t in _grid.tiles:
			if _grid.tiles[t].occupant != null:
				held[t] = true
				who.append("%s@%s" % [_grid.tiles[t].occupant.name, t])
		var ghost: Array = _grid.find_path(m.grid_pos, quarry.grid_pos, 999, true, null, held)
		out += " | path_ignoring_units=%d occupied=%s" % [ghost.size(), who]
	out += " | path_to_target=%d (%s -> %s %s)" % [route.size(), m.grid_pos, quarry.grid_pos, quarry.stats.display_name]
	for entry: Dictionary in brain.goals:
		var gate: StringName = entry.get("when", &"")
		if gate != &"" and not st.get(gate, false):
			out += " | %s: gated" % entry["name"]
			continue
		var plan: Array = planner.plan(m, brain.actions, st, entry["goal"], ctx)
		out += " | %s: [%s]" % [entry["name"], ",".join(plan.map(func(a): return String(a.name)))]
	return out
