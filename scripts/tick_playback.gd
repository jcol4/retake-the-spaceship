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


## Host: hands the timeline to every ready client, then plays it here.
func play_host(events: Array, tree: SceneTree) -> void:
	events = _live(events)
	if events.is_empty():
		return
	if SteamLobby.is_networked() and SteamLobby.is_host() and not SteamLobby.ready_peers.is_empty():
		var wire := to_wire(events)
		for peer_id in SteamLobby.ready_peers:
			TurnManager._rpc_play_tick.rpc_id(peer_id, wire)
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


## Who is drawn for this slot (plan B.12.2): a unit whose MODEL is on a revealed
## tile, or is stepping onto one, so a patrol visibly walks into view and out.
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
		if map == null or not map.has_method("is_revealed_tile"):
			unit.set_display_visible(true)
			continue
		var here := GridManager.world_to_grid(unit.visual.global_position)
		var seen: bool = map.is_revealed_tile(here)
		if not seen and entering.has(unit):
			seen = map.is_revealed_tile(entering[unit])
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
## the target's model is, the burst plays with the recorded hit and strays, and
## the target flinches if it was hit and still stands.
func _play_shot(unit: Unit, e: Dictionary) -> void:
	var target := e.get("target") as Unit
	if target == null or not is_instance_valid(target):
		return
	var delta := target.visual.global_position - unit.visual.global_position
	if absf(delta.x) > 0.001 or absf(delta.z) > 0.001:
		await _play_turn(unit, snappedf(atan2(-delta.x, -delta.z), PI / 4.0))
	await unit.replay_attack(target, e["hit"], e["crit"], e["rounds"], e["strays"], e["melee"])


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
