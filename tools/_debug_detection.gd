extends SceneTree
## Throwaway check for the light-detection rules (Sec 11.2), which the headless
## `--auto` smoke test can't cover: that run never turns a flashlight off, and
## being unseen in the dark is the whole point of the mechanic.
##   godot --headless --path . --script res://tools/_debug_detection.gd
##
## Autoloads aren't resolvable when this file is compiled, so everything here
## goes through root.get_node("/root/...") and untyped dynamic calls.

var _elapsed := 0.0
var _ran := false
var _failures := 0


func _initialize() -> void:
	change_scene_to_file.call_deferred("res://scenes/main.tscn")


func _process(delta: float) -> bool:
	_elapsed += delta
	if _ran or _elapsed < 1.0:
		return false
	_ran = true
	_run()
	quit(1 if _failures > 0 else 0)
	return true


func _check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		_failures += 1
	print("[detect] %s  %s%s" % ["PASS" if ok else "FAIL", label,
		"" if detail == "" else "  (" + detail + ")"])


func _run() -> void:
	var grid := root.get_node("/root/GridManager")
	var lighting := root.get_node("/root/LightingManager")
	var turns := root.get_node("/root/TurnManager")
	# Freeze the initiative loop so nothing acts underneath the assertions.
	turns.mission_over = true

	var players := root.get_tree().get_nodes_in_group("player_units")
	var aliens := root.get_tree().get_nodes_in_group("enemy_units")
	if players.is_empty() or aliens.is_empty():
		_check("scene has units", false, "players=%d aliens=%d" % [players.size(), aliens.size()])
		return
	print("[detect] %d players, %d aliens" % [players.size(), aliens.size()])

	# --- 1. Lights out: the flashlight layer must be completely empty, and no
	# alien may be roused by the map's own fixtures (the monitor at the bottom of
	# the enemy room lights a swarm's spawn tile to ~27, well over the alert
	# threshold — if aggro read total light_value instead, this is what would
	# wrongly trip it).
	for p in players:
		p.flashlight_on = false
	lighting.recompute_dynamic()

	var any_beam := false
	for a in aliens:
		a.alert_state = 0  # AlertState.UNAWARE
		if lighting.flashlight_value(a.grid_pos) > 0.0:
			any_beam = true
	_check("flashlight layer empty with every light off", not any_beam)

	var static_lit := 0
	for a in aliens:
		var tile = grid.get_tile(a.grid_pos)
		if tile and tile.light_value > 0.0:
			static_lit += 1
		a._on_lighting_changed()
	var roused := 0
	for a in aliens:
		if a.alert_state != 0:
			roused += 1
	_check("static fixtures alone rouse nobody", roused == 0,
		"%d of %d aliens stand on statically-lit tiles" % [static_lit, aliens.size()])
	_check("at least one alien IS statically lit (test is meaningful)", static_lit > 0)

	# --- 2. A player in the dark is not seen, even in the open with clear LOS.
	var dark_hidden := true
	var dark_checked := 0
	for a in aliens:
		for p in players:
			var tile = grid.get_tile(p.grid_pos)
			if tile == null or tile.light_value >= a.sight_light_threshold:
				continue  # standing under a fixture — being seen there is correct
			dark_checked += 1
			if a._can_see(p):
				dark_hidden = false
	_check("unlit players are invisible regardless of LOS", dark_hidden,
		"%d alien/player pairs in darkness" % dark_checked)

	# --- 3. Point a beam at an alien and it must notice. Pick the alien nearest
	# a player so the cone can actually reach it.
	var best_p = null
	var best_a = null
	var best_d := 999999
	for p in players:
		for a in aliens:
			var d: int = grid.chebyshev_dist(p.grid_pos, a.grid_pos)
			if d < best_d:
				best_d = d
				best_p = p
				best_a = a
	print("[detect] nearest pair: %s -> %s at %d tiles" % [
		best_p.stats.display_name, best_a.stats.display_name, best_d])

	best_p.flashlight_on = true
	best_p.look_at(best_a.global_position, Vector3.UP)
	best_p.rotation.x = 0.0
	best_p.rotation.z = 0.0
	lighting.recompute_dynamic()

	var lit_on_alien: float = lighting.flashlight_value(best_a.grid_pos)
	var in_range: bool = best_d <= int(lighting.FLASHLIGHT_RANGE)
	if not in_range:
		print("[detect] SKIP beam tests — nearest alien is %d tiles away, beyond the %d-tile cone"
			% [best_d, int(lighting.FLASHLIGHT_RANGE)])
		return
	_check("beam registers on the aimed-at alien", lit_on_alien > 0.0,
		"flashlight_value=%.1f" % lit_on_alien)
	_check("beam is attributed to the unit holding it",
		lighting.flashlight_source(best_a.grid_pos) == best_p)
	_check("aimed-at alien left UNAWARE", best_a.alert_state != 0,
		"state=%d after %.1f light" % [best_a.alert_state, lit_on_alien])
