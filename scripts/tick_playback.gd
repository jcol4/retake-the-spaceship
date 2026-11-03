class_name TickPlayback
extends RefCounted
## Plays a round tick's AI turns back together (exploration plan B.12, E25).
##
## The tick DECIDED every AI turn one at a time, as logic only, and recorded what
## each unit did (TurnManager.record). Every unit's root is therefore already on
## its final tile with its final facing — the truth the rules read. What is
## animated here is only the `UnitVisual` child: it is put back where the unit
## started, walked along the recorded path slot by slot with everybody else's,
## and re-zeroed onto the root at the end. No roll, no damage, no state: the
## replay entry points below draw a shot or a collapse that already happened.
##
## The slots come from ExplorationRules.schedule, so a unit never steps into a
## tile somebody else is still leaving and a shot never lands before its target
## is drawn where it was hit. While it plays, the drawn light (B.12.1) and who is
## drawn at all (B.12.2) follow the models rather than the roots.
##
## Runs on the host and, from the same timeline, on every client (plan C.9).
## Headless runs skip it: nothing would be drawn.

## A turn in place, seconds. Matches Unit.face_toward's tween.
const TURN_SECONDS := Unit.TURN_TIME * 2.0


## Fires `finished` once every coroutine it was handed has called `done`.
class Join:
	signal finished
	var left := 0

	func done() -> void:
		left -= 1
		if left <= 0:
			finished.emit()


## Host: hands the timeline to every ready client, then plays it here. `horde`
## plays it as one horde's activation (`play_horde`) rather than a round tick.
func play_host(events: Array, tree: SceneTree, horde := false) -> void:
	events = _live(events)
	if events.is_empty():
		return
	if SteamLobby.is_networked() and SteamLobby.is_host() and not SteamLobby.ready_peers.is_empty():
		var wire := to_wire(events)
		for peer_id in SteamLobby.ready_peers:
			if horde:
				TurnManager._rpc_play_horde.rpc_id(peer_id, wire)
			else:
				TurnManager._rpc_play_tick.rpc_id(peer_id, wire)
	if horde:
		await play_horde(events, tree)
	else:
		await play(events, tree)


## The timeline as it crosses the wire: every unit as its node path, which names
## the same unit on every peer (main.gd names them at spawn).
static func to_wire(events: Array) -> Array:
	var out: Array = []
	for e: Dictionary in events:
		var w := e.duplicate()
		for key in ["unit", "target", "by"]:
			if w.has(key):
				var node: Variant = w[key]
				w[key] = (node as Node).get_path() if is_instance_valid(node) else NodePath()
		out.append(w)
	return out


## Back from the wire on a client; events naming a unit it cannot resolve are
## dropped rather than played against nothing.
static func from_wire(wire: Array, root: Node) -> Array:
	var out: Array = []
	for w: Dictionary in wire:
		var e := w.duplicate()
		var ok := true
		for key in ["unit", "target", "by"]:
			if e.has(key):
				var path: NodePath = e[key]
				var node: Node = root.get_node_or_null(path) if not path.is_empty() else null
				if node == null:
					ok = false
				e[key] = node
		if ok:
			out.append(e)
	return out


## Drops events about a unit that no longer exists. A worm absorbed into a mass is
## freed rather than killed (WormUnit.dissolve), during the very pass that recorded
## it, and even casting a freed reference is an error. It is gone from the board
## either way; its model cannot be walked to where it vanished.
static func _live(events: Array) -> Array:
	return events.filter(func(e: Dictionary) -> bool:
		for key in ["unit", "target", "by"]:
			if e.has(key) and not is_instance_valid(e[key]):
				return false
		return true)


func play(events: Array, tree: SceneTree) -> void:
	events = _live(events)
	if events.is_empty() or DisplayServer.get_name() == "headless":
		return
	var slots := ExplorationRules.schedule(events)
	var groups := ExplorationRules.by_slot(slots)
	var units := _units_in(events)
	var unspawned := {}
	var last_step := {}
	for i in events.size():
		var e: Dictionary = events[i]
		if e["kind"] == ExplorationRules.EV_SPAWN:
			unspawned[e["unit"]] = true
		elif e["kind"] == ExplorationRules.EV_STEP:
			last_step[e["unit"]] = i
	_prepare(events, units, unspawned)
	LightingManager.begin_display()
	var map := tree.get_first_node_in_group("map")
	for group: Array in groups:
		_update_visibility(units, unspawned, map, events, group)
		var join := Join.new()
		join.left = group.size()
		for index: int in group:
			_run(events[index], index == last_step.get(events[index]["unit"], -1), unspawned, join)
		if join.left > 0:
			await join.finished
		LightingManager.recompute_display()
	_finish(units)
	LightingManager.end_display()


## Most a horde body's walk starts behind the pack's first, seconds. Enough that
## a room of one model does not stride off in lockstep; short against a step,
## so it still reads as one surge.
const HORDE_STAGGER := 0.3


## One horde's activation (TurnManager._horde_turn), played as a pack rather than
## slot by slot. Two phases:
##   1. Every walk and turn at once. Each body keeps to its own pace, starting up
##      to HORDE_STAGGER behind the others, and a step onto a tile another body
##      is leaving waits until that one is halfway off it.
##   2. Everything else — the claws and whatever they knocked down — one event
##      at a time, in the order it was decided.
## A Fodder closes OR swings (SwarmUnit), so a body that walks and then claws
## only ever stepped once, and nothing it did is reordered by the split.
func play_horde(events: Array, tree: SceneTree) -> void:
	events = _live(events)
	if events.is_empty() or DisplayServer.get_name() == "headless":
		return
	var moves: Array = []
	var blows: Array = []
	for i in events.size():
		var kind: String = events[i]["kind"]
		if kind == ExplorationRules.EV_STEP or kind == ExplorationRules.EV_TURN:
			moves.append(i)
		else:
			blows.append(i)
	var units := _units_in(events)
	var unspawned := {}
	_prepare(events, units, unspawned)
	LightingManager.begin_display()
	var map := tree.get_first_node_in_group("map")

	var starts := horde_starts(events, moves, _horde_offsets(events, moves))
	var chains := {}
	var last_step := {}
	for i: int in moves:
		var unit: Unit = events[i]["unit"]
		if not chains.has(unit):
			chains[unit] = []
		chains[unit].append(i)
		if events[i]["kind"] == ExplorationRules.EV_STEP:
			last_step[unit] = i
	_update_visibility(units, unspawned, map, events, moves)
	if not chains.is_empty():
		var join := Join.new()
		join.left = chains.size()
		var t0 := Time.get_ticks_msec()
		for unit: Unit in chains:
			_run_chain(events, chains[unit], starts, last_step.get(unit, -1), t0, unspawned, tree, join)
		if join.left > 0:
			await join.finished
	LightingManager.recompute_display()

	for i: int in blows:
		_update_visibility(units, unspawned, map, events, [i])
		var join := Join.new()
		join.left = 1
		_run(events[i], false, unspawned, join)
		if join.left > 0:
			await join.finished
		LightingManager.recompute_display()
	_finish(units)
	LightingManager.end_display()


## A pause in a horde body's walk shorter than this keeps its run going; a longer
## one stands it idle until it moves again. Covers the frame or two a timer can
## land late, so a body walking steps back to back never flickers to idle.
const HORDE_IDLE_GAP := 0.08


## One body's walk in a horde playback: its events in order, each held until its
## start time from `horde_starts` (seconds after `t0`) has come round. While it is
## held — waiting at a tile for a mate to clear the next — it stands IDLE rather
## than running on the spot; its next step puts it back into the run.
func _run_chain(events: Array, chain: Array, starts: Dictionary, last_step: int,
		t0: int, unspawned: Dictionary, tree: SceneTree, join: Join) -> void:
	var unit: Unit = events[chain[0]]["unit"]
	for i: int in chain:
		var wait: float = starts[i] - (Time.get_ticks_msec() - t0) / 1000.0
		# A turn on the spot is not a stride either.
		var stands: bool = wait > HORDE_IDLE_GAP or events[i]["kind"] == ExplorationRules.EV_TURN
		if stands and is_instance_valid(unit) and not unit.is_instant():
			unit.visual.set_stance_local(UnitVisual.IDLE)
		if wait > 0.0:
			await tree.create_timer(wait).timeout
		var one := Join.new()
		one.left = 1
		_run(events[i], i == last_step, unspawned, one)
		if one.left > 0:
			await one.finished
	join.done()


## Each walking body's head start: a random fraction of HORDE_STAGGER, seeded off
## the unit's name so every peer staggers the pack the same way.
static func _horde_offsets(events: Array, moves: Array) -> Dictionary:
	var out := {}
	for i: int in moves:
		var unit: Unit = events[i]["unit"]
		if not out.has(unit):
			var rng := RandomNumberGenerator.new()
			rng.seed = hash(String(unit.name))
			out[unit] = rng.randf() * HORDE_STAGGER
	return out


## When each of `moves` starts, seconds into the walk phase: index -> seconds.
## A body's first event starts at its offset and each later one when the one
## before it ends (a step's length is the model's own travel time, as
## `_play_step` tweens it). A step onto a tile some other body is leaving starts
## no sooner than halfway through that body's step off it, so two models never
## stand in one tile. Pure arithmetic on the timeline: a test can read it.
static func horde_starts(events: Array, moves: Array, offsets: Dictionary) -> Dictionary:
	var out := {}
	var free_at := {}
	var vacated := {}
	for i: int in moves:
		var e: Dictionary = events[i]
		var unit: Unit = e["unit"]
		var t: float = free_at.get(unit, offsets.get(unit, 0.0))
		var seconds := TURN_SECONDS
		if e["kind"] == ExplorationRules.EV_STEP:
			if vacated.has(e["to"]):
				t = maxf(t, vacated[e["to"]])
			var dist := GridManager.grid_to_world(e["from"]).distance_to(GridManager.grid_to_world(e["to"]))
			seconds = dist / maxf(0.1, unit.move_speed)
			vacated[e["from"]] = t + seconds * 0.5
		out[i] = t
		free_at[unit] = t + seconds
	return out


func _units_in(events: Array) -> Array[Unit]:
	var out: Array[Unit] = []
	for e: Dictionary in events:
		for key in ["unit", "target"]:
			var unit := e.get(key) as Unit
			if unit != null and not out.has(unit):
				out.append(unit)
	return out


## Rewinds every model in the timeline to where, and how, its unit started the
## tick: the first step's tile and the first facing recorded, standing if it
## went down during the tick, its lamp as it was before any toggle, and hidden
## until its spawn slot if it was spawned.
func _prepare(events: Array, units: Array[Unit], unspawned: Dictionary) -> void:
	var start_tile := {}
	var start_yaw := {}
	var start_light := {}
	var went_down := {}
	for e: Dictionary in events:
		var unit := e["unit"] as Unit
		match e["kind"]:
			ExplorationRules.EV_STEP:
				if not start_tile.has(unit):
					start_tile[unit] = e["from"]
				if not start_yaw.has(unit):
					start_yaw[unit] = e["from_yaw"]
			ExplorationRules.EV_TURN:
				if not start_yaw.has(unit):
					start_yaw[unit] = e["from_yaw"]
			ExplorationRules.EV_LIGHT:
				if not start_light.has(unit):
					start_light[unit] = not e["on"]
			ExplorationRules.EV_DOWN:
				if not went_down.has(unit):
					went_down[unit] = e.get("was_active", true)
	for unit in units:
		unit.begin_display()
		if start_tile.has(unit):
			unit.visual.global_position = GridManager.grid_to_world(start_tile[unit])
			unit.visual.set_cover_pose_local(&"")
		unit.visual.rotation = Vector3(0.0, start_yaw.get(unit, unit.rotation.y) - unit.rotation.y, 0.0)
		if went_down.has(unit):
			unit.visual.replay_reset(went_down[unit])
		var lamp_on: bool = start_light.get(unit,
			unit.has_flashlight and unit.flashlight_on and (went_down.get(unit, false) or not unit.is_downed))
		unit.visual.set_lamp_local(unit.has_flashlight and lamp_on)
		if unspawned.has(unit):
			unit.set_display_visible(false)


## Who is drawn for this slot (plan B.12.2): a unit whose MODEL is on a tile the
## squad can see (MapBuilder.unit_visible_at), or is stepping onto one, so a
## patrol visibly walks into view and out.
func _update_visibility(units: Array[Unit], unspawned: Dictionary, map: Node,
		events: Array, group: Array) -> void:
	var entering := {}
	for index: int in group:
		var e: Dictionary = events[index]
		if e["kind"] == ExplorationRules.EV_STEP:
			entering[e["unit"]] = e["to"]
	for unit in units:
		if not is_instance_valid(unit) or unspawned.has(unit):
			continue
		if map == null or not map.has_method("unit_visible_at"):
			unit.set_display_visible(true)
			continue
		var here := GridManager.world_to_grid(unit.visual.global_position)
		var seen: bool = map.unit_visible_at(unit, here)
		if not seen and entering.has(unit):
			seen = map.unit_visible_at(unit, entering[unit])
		unit.set_display_visible(seen)


func _run(e: Dictionary, last_step: bool, unspawned: Dictionary, join: Join) -> void:
	var unit := e["unit"] as Unit
	if unit != null and is_instance_valid(unit) and unit.is_inside_tree():
		match e["kind"]:
			ExplorationRules.EV_STEP:
				await _play_step(unit, e, last_step)
			ExplorationRules.EV_TURN:
				await _play_turn(unit, e["yaw"])
			ExplorationRules.EV_LIGHT:
				unit.visual.set_lamp_local(e["on"])
			ExplorationRules.EV_SHOT:
				await _play_shot(unit, e)
			ExplorationRules.EV_DOWN:
				await unit.visual.replay_down(e.get("was_active", true), e["dead"])
			ExplorationRules.EV_SPAWN:
				unspawned.erase(unit)
				unit.set_display_visible(true)
	join.done()


func _play_step(unit: Unit, e: Dictionary, last_step: bool) -> void:
	var visual := unit.visual
	var target := GridManager.grid_to_world(e["to"])
	var local_yaw: float = e["yaw"] - unit.rotation.y
	if unit.is_instant():
		visual.global_position = target
		visual.rotation.y = local_yaw
	else:
		visual.set_stance_local(UnitVisual.WALK if unit.walks_only else UnitVisual.RUN)
		var seconds := visual.global_position.distance_to(target) / maxf(0.1, unit.move_speed)
		if seconds > 0.001:
			var tween := visual.create_tween()
			tween.set_parallel(true)
			tween.tween_property(visual, "global_position", target, seconds)
			if absf(wrapf(local_yaw - visual.rotation.y, -PI, PI)) > 0.001:
				tween.tween_property(visual, "rotation:y",
					visual.rotation.y + wrapf(local_yaw - visual.rotation.y, -PI, PI), minf(Unit.TURN_TIME, seconds))
			await tween.finished
	if last_step:
		visual.set_stance_local(UnitVisual.IDLE)


func _play_turn(unit: Unit, yaw: float) -> void:
	var visual := unit.visual
	var local_yaw := visual.rotation.y + wrapf(yaw - unit.rotation.y - visual.rotation.y, -PI, PI)
	if unit.is_instant():
		visual.rotation.y = local_yaw
		return
	var tween := visual.create_tween()
	tween.tween_property(visual, "rotation:y", local_yaw, TURN_SECONDS)
	await tween.finished


## A shot or a swing that already resolved: the shooter's model turns onto where
## the target's model is, the burst plays with the recorded hit, strays and lean
## round a corner (GDD §6.1.2), and the target flinches if it was hit and still
## stands. The lean moves the model relative to where this playback put it.
func _play_shot(unit: Unit, e: Dictionary) -> void:
	var target := e.get("target") as Unit
	if target == null or not is_instance_valid(target):
		return
	var delta := target.visual.global_position - unit.visual.global_position
	if absf(delta.x) > 0.001 or absf(delta.z) > 0.001:
		await _play_turn(unit, snappedf(atan2(-delta.x, -delta.z), PI / 4.0))
	await unit.replay_attack(target, e["hit"], e["crit"], e["rounds"], e["strays"], e["melee"],
		e.get("lean", Vector3i.ZERO))


## Hands every model back to its unit: re-zeroed on the root, drawn by the
## logic's own visibility, posed and lit as the rules now stand.
func _finish(units: Array[Unit]) -> void:
	for unit in units:
		if not is_instance_valid(unit):
			continue
		unit.visual.set_lamp_local(unit.has_flashlight and unit.flashlight_on and not unit.is_downed)
		unit.end_display()
		if not unit.is_downed:
			unit.refresh_cover_pose()
