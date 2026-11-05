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

## A turn in place, seconds. Matches Unit.face_toward's hold.
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
		var poses := final_poses(events)
		for peer_id in SteamLobby.ready_peers:
			if horde:
				TurnManager._rpc_play_horde.rpc_id(peer_id, wire, poses)
			else:
				TurnManager._rpc_play_tick.rpc_id(peer_id, wire, poses)
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


## Host: where every unit in the timeline stands once the tick is decided — its
## root's position and facing, by node path. Rides along with the timeline.
##
## The client's roots get there by replication, which the host sends on its next
## network poll — AFTER this RPC, which went out the moment it was called. So the
## timeline used to land first: `_prepare` put each model at its start tile while
## the root was still standing there too, then the replicated jump to the final
## tile dragged the model (its child) along with it, and the first step's tween
## walked it from the end of its route back to the start before playing forward.
static func final_poses(events: Array) -> Dictionary:
	var out := {}
	for e: Dictionary in events:
		var unit := e.get("unit") as Unit
		if unit != null and is_instance_valid(unit) and not out.has(unit.get_path()):
			out[unit.get_path()] = [unit.global_position, unit.rotation.y]
	return out


## Client: puts every root where the host's already is before playback rewinds
## the models, so the late replicated update moves nothing (see `final_poses`).
static func apply_final_poses(poses: Dictionary, root: Node) -> void:
	for path: NodePath in poses:
		var unit := root.get_node_or_null(path) as Unit
		if unit == null:
			continue
		var pose: Array = poses[path]
		unit.global_position = pose[0]
		unit.rotation.y = pose[1]


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
	# Reaction bursts play detached from the slots (ExplorationRules.schedule):
	# each one's Join, by shooter and by target, until it lands.
	var by_shooter := {}
	var by_target := {}
	for group: Array in groups:
		# Held until any reaction burst it must not overlap has landed: anything
		# the shooter does next, and the target going down or being shot again.
		for index: int in group:
			for j: Join in _reaction_waits(events[index], by_shooter, by_target):
				if j.left > 0:
					await j.finished
		_update_visibility(units, unspawned, map, events, group)
		var join := Join.new()
		join.left = 0
		for index: int in group:
			var e: Dictionary = events[index]
			if e["kind"] == ExplorationRules.EV_SHOT and e.get("reaction", false) \
					and not e.get("melee", false):
				var rj := Join.new()
				rj.left = 1
				by_shooter[e["unit"]] = rj
				if not by_target.has(e["target"]):
					by_target[e["target"]] = []
				by_target[e["target"]].append(rj)
				_play_reaction(e["unit"], e, _arrival_in(events, group, e["target"]), rj)
				continue
			join.left += 1
			_run(e, index == last_step.get(e["unit"], -1), unspawned, join)
		if join.left > 0:
			await join.finished
		LightingManager.recompute_display()
	for rj: Join in by_shooter.values():
		if rj.left > 0:
			await rj.finished
	_finish(units)
	LightingManager.end_display()


## The reaction bursts still in the air that `e` must wait for: one by its own
## unit, and — unless `e` is just its target running on — any at its unit.
func _reaction_waits(e: Dictionary, by_shooter: Dictionary, by_target: Dictionary) -> Array:
	var out: Array = []
	var unit: Variant = e.get("unit")
	if by_shooter.has(unit):
		out.append(by_shooter[unit])
	var runs_on: bool = e["kind"] in [ExplorationRules.EV_STEP, ExplorationRules.EV_TURN,
		ExplorationRules.EV_LIGHT]
	if not runs_on and by_target.has(unit):
		out.append_array(by_target[unit])
	if e["kind"] == ExplorationRules.EV_SHOT and by_target.has(e.get("target")) \
			and not e.get("reaction", false):
		out.append_array(by_target[e["target"]])
	return out


## Seconds until `target`'s model arrives where its step in `group` takes it,
## from now (the slot's start) — or 0 when it is not stepping in this slot.
func _arrival_in(events: Array, group: Array, target: Unit) -> float:
	if target == null or not is_instance_valid(target) or target.is_instant():
		return 0.0
	for index: int in group:
		var e: Dictionary = events[index]
		if e["kind"] == ExplorationRules.EV_STEP and e["unit"] == target:
			return target.visual.global_position.distance_to(GridManager.grid_to_world(e["to"])) \
				/ maxf(0.1, target.move_speed)
	return 0.0


## A reaction shot (overwatch, a suppression break) at a runner, played the way
## it plays live: the shooter's aim picks the runner up as its step onto the
## trigger tile begins, follows it, and the first round goes out as it arrives —
## then the burst plays on while it keeps running. Never holds a slot up.
func _play_reaction(unit: Unit, e: Dictionary, arrival: float, join: Join) -> void:
	var target := e.get("target") as Unit
	if unit != null and is_instance_valid(unit) and unit.is_inside_tree() \
			and target != null and is_instance_valid(target):
		if not unit.is_instant():
			var delta := target.visual.global_position - unit.visual.global_position
			if absf(delta.x) > 0.001 or absf(delta.z) > 0.001:
				_play_turn(unit, atan2(-delta.x, -delta.z), false)
			unit.track_local(target)
			if arrival > 0.0:
				await unit.get_tree().create_timer(arrival).timeout
		if is_instance_valid(target):
			await unit.replay_attack(target, e["hit"], e["crit"], e["rounds"], e["strays"], false,
				e.get("lean", Vector3i.ZERO), e.get("doomed", false), e.get("part", -1), true)
	join.done()


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
## A Fodder normally walks and then claws (SwarmUnit), so playing every walk
## first and every blow after keeps each body's own order. The rare body that
## kills its prey and then walks on to another has that walk shown early.
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
			# Facing set as the leg starts, as Unit._tween_yaw does live; the
			# model's free-turn springs draw the turn.
			visual.rotation.y += wrapf(local_yaw - visual.rotation.y, -PI, PI)
			var tween := visual.create_tween()
			tween.tween_property(visual, "global_position", target, seconds)
			await tween.finished
	if last_step:
		visual.set_stance_local(UnitVisual.IDLE)


func _play_turn(unit: Unit, yaw: float, hold := true) -> void:
	var visual := unit.visual
	var local_yaw := visual.rotation.y + wrapf(yaw - unit.rotation.y - visual.rotation.y, -PI, PI)
	# Instant either way, then held for the turn's length when drawn: the
	# model's free-turn springs (UnitVisual) draw the turn itself.
	visual.rotation.y = local_yaw
	if unit.is_instant() or not hold:
		return
	await visual.get_tree().create_timer(TURN_SECONDS).timeout


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
		await _play_turn(unit, atan2(-delta.x, -delta.z))  # continuous, as Unit._yaw_toward
	await unit.replay_attack(target, e["hit"], e["crit"], e["rounds"], e["strays"], e["melee"],
		e.get("lean", Vector3i.ZERO), e.get("doomed", false), e.get("part", -1))


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
