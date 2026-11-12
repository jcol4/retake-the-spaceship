extends SceneTree
## Whole-frame performance probe on the REAL game scene (main.tscn: HUD,
## PixelView, glow, volumetric fog, flashlights), where tools/profile_horde.gd
## only loads test_map.tscn and times the horde's decision frame.
##
##   godot --path . --resolution 1920x1080 --script res://tools/profile_frame.gd -- --bodies=16
##
## Windowed: headless builds no models and draws nothing. Reports, over a
## steady window of frames with a Fodder pack standing in view of the squad:
##   * CPU: process and physics step, render-thread CPU per viewport;
##   * GPU: measured time per viewport (the PixelView buffer, its text overlay,
##     every face feed);
##   * draw calls / primitives / objects;
##   * per-system CPU, by calling each per-frame system directly;
##   * A/B toggles: volumetric fog, glow, flashlight shadows, hidden-unit
##     animation (what a horde fogged out of sight costs).
## --frames=N sets the sample window (default 240). PROFILE_SHOT=<png> saves a
## screenshot of the scene being measured.
##
## Untyped locals and dynamic calls: a --script tool compiles before autoloads.

var _frames := 240
var _bodies := 16
var _main: Node
var _vps: Array = []  # [name, Viewport]


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--bodies="):
			_bodies = int(arg.trim_prefix("--bodies="))
		elif arg.begins_with("--frames="):
			_frames = int(arg.trim_prefix("--frames="))
	if DisplayServer.get_name() == "headless":
		print("profile_frame: run windowed (headless draws nothing)")
		quit(1)
		return
	change_scene_to_file.call_deferred("res://scenes/main.tscn")
	_run.call_deferred()


func _run() -> void:
	for i in 40:
		await process_frame
	_main = current_scene
	var grid = root.get_node("GridManager")
	var dev = _main.get_node_or_null("DevSpawn")
	var squad: Array = get_nodes_in_group("player_units")
	if dev == null or squad.is_empty():
		print("profile_frame: no DevSpawn or no squad")
		quit(1)
		return
	# Uncapped, so frame time is the work done rather than the display's refresh
	# (TIME_PROCESS absorbs a vsync wait too).
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	print("GPU: %s | %s" % [RenderingServer.get_video_adapter_name(), DisplayServer.window_get_size()])
	var anchor: Vector3i = squad[0].grid_pos
	for s in squad:
		s.set("flashlight_on", true)

	# The pack: the nearest free tiles to the squad, so they are in the
	# squad's room or sight and drawn like a spotted horde.
	var free: Array = []
	for tile in grid.tiles:
		if grid.is_free(tile) and tile != anchor:
			free.append(tile)
	free.sort_custom(func(a, b): return (a - anchor).length_squared() < (b - anchor).length_squared())
	var placed := 0
	for tile in free:
		if placed >= _bodies:
			break
		if (tile - anchor).length_squared() < 4:
			continue  # leave the squad room to breathe
		if dev.spawn("zombie", tile) == "":
			placed += 1
	var pack: Array = []
	for u in get_nodes_in_group("enemy_units"):
		if String(u.name).begins_with("Dev_zombie"):
			pack.append(u)
			_main.map._spotted[u] = true
	_main.camera_rig.focus_on(grid.grid_to_world(anchor))
	for i in 60:
		await process_frame
	var drawn := 0
	for u in pack:
		if u.visual.visible:
			drawn += 1
	print("pack: %d Fodder spawned, %d drawn; %d units total; %d nodes" % [
		pack.size(), drawn, get_nodes_in_group("units").size(),
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT)])
	if OS.has_environment("PROFILE_SHOT"):
		root.get_viewport().get_texture().get_image().save_png(OS.get_environment("PROFILE_SHOT"))

	_collect_viewports()
	for entry in _vps:
		RenderingServer.viewport_set_measure_render_time(entry[1].get_viewport_rid(), true)

	var base := await _sample("baseline")
	_report(base)
	_bench_systems(pack)
	_bench_lighting()

	# --- Per-system share of the frame: switch one off, measure, switch back.
	var visuals: Array = []
	var players: Array = []
	var skels: Array = []
	for u in get_nodes_in_group("units"):
		if u.get("visual") == null:
			continue
		visuals.append(u.visual)
		players.append_array(u.visual.find_children("*", "AnimationPlayer", true, false))
		skels.append_array(u.visual.find_children("*", "Skeleton3D", true, false))
	print("animated: %d AnimationPlayers, %d Skeleton3Ds" % [players.size(), skels.size()])
	for v in visuals:
		v.set_process(false)
	_report(await _sample("UnitVisual._process OFF"), base)
	for v in visuals:
		v.set_process(true)
	var modes: Array = []
	var running := 0
	for p in players:
		modes.append(p.callback_mode_process)
		if p.callback_mode_process != AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL:
			running += 1
		p.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	print("animation players running before the pause: %d of %d (hidden ones idle)" % [running, players.size()])
	_report(await _sample("animation players paused"), base)
	for i in players.size():
		players[i].callback_mode_process = modes[i]
	for v in visuals:
		v.process_mode = Node.PROCESS_MODE_DISABLED
	_report(await _sample("whole Visual subtrees DISABLED"), base)
	for v in visuals:
		v.process_mode = Node.PROCESS_MODE_INHERIT
	var map = _main.map
	map.set_process(false)
	_report(await _sample("MapBuilder._process OFF"), base)
	map.set_process(true)
	var hud = _main.get_node_or_null("HUD")
	if hud:
		hud.set_process(false)
		_report(await _sample("HUD._process OFF"), base)
		hud.set_process(true)

	# --- A/B toggles. Each is put back before the next.
	var env: Environment = _world_env()
	if env:
		env.volumetric_fog_enabled = false
		_report(await _sample("volumetric fog OFF"), base)
		env.volumetric_fog_enabled = true
		env.glow_enabled = false
		_report(await _sample("glow OFF"), base)
		env.glow_enabled = true
	var lights: Array = []
	for n in root.find_children("*", "Light3D", true, false):
		if n.shadow_enabled and n.is_visible_in_tree():
			lights.append(n)
	print("shadowed lights in view: %d" % lights.size())
	for l in lights:
		l.shadow_enabled = false
	_report(await _sample("all light shadows OFF"), base)
	for l in lights:
		l.shadow_enabled = true

	# What a pack fogged out of sight costs: hide every body, as set_rendered
	# does (visual.visible = false), and measure again.
	for u in pack:
		u.visual.visible = false
	var hidden := await _sample("pack hidden (fogged)")
	_report(hidden, base)
	for u in pack:
		u.visual.visible = true
	# And with no pack at all, for the floor.
	for u in pack:
		u.get_parent().remove_child(u)
		u.queue_free()
	_report(await _sample("no pack (removed)"), base)
	quit(0)


func _world_env() -> Environment:
	for n in root.find_children("*", "WorldEnvironment", true, false):
		return n.environment
	return null


func _collect_viewports() -> void:
	_vps.clear()
	_vps.append(["root", root.get_viewport()])
	for n in root.find_children("*", "SubViewport", true, false):
		if n.render_target_update_mode != SubViewport.UPDATE_DISABLED:
			_vps.append([String(n.name), n])


## Averages over `_frames` frames.
func _sample(label: String) -> Dictionary:
	for i in 20:
		await process_frame  # settle after a toggle
	var acc := {"label": label, "process": 0.0, "physics": 0.0, "fps": 0.0, "draws": 0.0,
		"prims": 0.0, "objects": 0.0, "frame": [], "vp_cpu": {}, "vp_gpu": {}}
	var last := Time.get_ticks_usec()
	for i in _frames:
		await process_frame
		var now := Time.get_ticks_usec()
		acc.frame.append((now - last) / 1000.0)
		last = now
		acc.process += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		acc.physics += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		acc.draws += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		acc.prims += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
		acc.objects += Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
		for entry in _vps:
			var rid = entry[1].get_viewport_rid()
			acc.vp_cpu[entry[0]] = acc.vp_cpu.get(entry[0], 0.0) + RenderingServer.viewport_get_measured_render_time_cpu(rid)
			acc.vp_gpu[entry[0]] = acc.vp_gpu.get(entry[0], 0.0) + RenderingServer.viewport_get_measured_render_time_gpu(rid)
	for k in ["process", "physics", "draws", "prims", "objects"]:
		acc[k] /= _frames
	for k in acc.vp_cpu:
		acc.vp_cpu[k] /= _frames
		acc.vp_gpu[k] /= _frames
	acc.frame.sort()
	return acc


func _report(s: Dictionary, base: Dictionary = {}) -> void:
	var f: Array = s.frame
	var gpu_total := 0.0
	var cpu_total := 0.0
	for k in s.vp_gpu:
		gpu_total += s.vp_gpu[k]
		cpu_total += s.vp_cpu[k]
	var line := "[%s] frame p50 %.2f p95 %.2f ms | process %.2f physics %.2f | render cpu %.2f gpu %.2f ms | draws %d prims %dk objs %d" % [
		s.label, f[f.size() / 2], f[int(f.size() * 0.95)], s.process, s.physics, cpu_total, gpu_total,
		s.draws, s.prims / 1000.0, s.objects]
	if not base.is_empty():
		var bg := 0.0
		for k in base.vp_gpu:
			bg += base.vp_gpu[k]
		line += "  (gpu %+.2f, process %+.2f vs baseline)" % [gpu_total - bg, s.process - base.process]
	print(line)
	if base.is_empty():
		var parts: Array = []
		for k in s.vp_gpu:
			parts.append("%s gpu %.2f cpu %.2f" % [k, s.vp_gpu[k], s.vp_cpu[k]])
		print("   per viewport: " + ", ".join(parts))


## LightingManager.recompute_dynamic, split: the beams, the call as a lit step
## makes it (beams' tiles only) against one forced to rewrite the whole deck,
## and the `lighting_changed` fan-out. Called on every step of a lit walk.
func _bench_lighting() -> void:
	var light = root.get_node("LightingManager")
	var grid = root.get_node("GridManager")
	var reps := 20
	var units: Array = light._flashlight_units()
	var t := Time.get_ticks_usec()
	for i in reps:
		for u in units:
			light._beam_contribution(u.grid_pos, u.global_position, light._aim_of(u), u)
	var beams := (Time.get_ticks_usec() - t) / float(reps)
	t = Time.get_ticks_usec()
	for i in reps:
		light._full_pass_needed = true
		light.recompute_dynamic()
	var full := (Time.get_ticks_usec() - t) / float(reps)
	t = Time.get_ticks_usec()
	for i in reps:
		light.recompute_dynamic()
	var step := (Time.get_ticks_usec() - t) / float(reps)
	t = Time.get_ticks_usec()
	for i in reps:
		light.lighting_changed.emit()
	var emit := (Time.get_ticks_usec() - t) / float(reps)
	print("  recompute_dynamic: %d beams %.1f us | per step %.1f us vs whole-deck pass %.1f us (%d tiles) | emit to %d listeners %.1f us" % [
		units.size(), beams, step, full, grid.tiles.size(), light.lighting_changed.get_connections().size(), emit])
	t = Time.get_ticks_usec()
	light.recompute_base()
	print("  recompute_base (map load, flicker reroll) %.1f us" % (Time.get_ticks_usec() - t))
	light.begin_display()
	t = Time.get_ticks_usec()
	for i in reps:
		light.recompute_display()
	print("  recompute_display (once per playback slot) %.1f us" % ((Time.get_ticks_usec() - t) / float(reps)))
	light.end_display()


## Per-system CPU: each per-frame system called directly, many times.
func _bench_systems(pack: Array) -> void:
	var map = _main.map
	var dt := 1.0 / 60.0
	var reps := 100
	var t := Time.get_ticks_usec()
	for i in reps:
		map._process(dt)
	print("  MapBuilder._process            %7.1f us" % ((Time.get_ticks_usec() - t) / float(reps)))
	t = Time.get_ticks_usec()
	for i in reps:
		map._apply_unit_visibility()
	print("    of which _apply_unit_visibility %7.1f us" % ((Time.get_ticks_usec() - t) / float(reps)))
	var all_units: Array = get_nodes_in_group("units")
	t = Time.get_ticks_usec()
	for i in reps:
		for u in all_units:
			map.unit_visible_at(u, u.grid_pos)
	print("      unit_visible_at x%d          %7.1f us" % [all_units.size(), (Time.get_ticks_usec() - t) / float(reps)])
	t = Time.get_ticks_usec()
	for i in reps:
		for u in all_units:
			map.squad_sees_tile(u.grid_pos)
	print("      squad_sees_tile x%d (cached) %7.1f us" % [all_units.size(), (Time.get_ticks_usec() - t) / float(reps)])
	t = Time.get_ticks_usec()
	for i in reps:
		for u in all_units:
			map.data.room_index_at(u.grid_pos)
	print("      data.room_index_at x%d       %7.1f us" % [all_units.size(), (Time.get_ticks_usec() - t) / float(reps)])
	t = Time.get_ticks_usec()
	for i in reps:
		for u in all_units:
			u.set_rendered(u._rendered)
	print("      set_rendered (no change) x%d %7.1f us" % [all_units.size(), (Time.get_ticks_usec() - t) / float(reps)])
	for fn in ["_revealed_regions", "_update_fog", "_update_sight_dim"]:
		t = Time.get_ticks_usec()
		for i in reps:
			map.call(fn)
		print("    MapBuilder.%-22s %7.1f us" % [fn, (Time.get_ticks_usec() - t) / float(reps)])
	var visuals: Array = []
	for u in get_nodes_in_group("units"):
		if u.get("visual") != null:
			visuals.append(u.visual)
	t = Time.get_ticks_usec()
	for i in reps:
		for v in visuals:
			v._process(dt)
	print("  UnitVisual._process x%d        %7.1f us" % [visuals.size(), (Time.get_ticks_usec() - t) / float(reps)])
	var hud = _main.get_node_or_null("HUD")
	if hud:
		for fn in ["_refresh_room_hover", "_refresh_target_bar", "_refresh_room_controls",
				"_refresh_body_labels", "_refresh_portraits", "_refresh_objective"]:
			if not hud.has_method(fn):
				continue
			t = Time.get_ticks_usec()
			for i in reps:
				hud.call(fn)
			print("  HUD.%-28s %7.1f us" % [fn, (Time.get_ticks_usec() - t) / float(reps)])
	var light = root.get_node("LightingManager")
	t = Time.get_ticks_usec()
	for i in 10:
		light.recompute_dynamic()
	print("  LightingManager.recompute_dynamic %7.1f us (event-driven, not per frame)" % ((Time.get_ticks_usec() - t) / 10.0))
	var active = root.get_node("TurnManager").active_unit
	if active and active.has_method("_process"):
		t = Time.get_ticks_usec()
		for i in reps:
			active.set("_hover_tile", Vector3i(-999, -999, -999))
			active._process(dt)
		print("  PlayerUnit._process (forced re-preview) %7.1f us" % ((Time.get_ticks_usec() - t) / float(reps)))
