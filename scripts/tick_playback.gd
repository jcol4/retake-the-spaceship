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
				e.get("lean", Vector3i.ZERO), e.get("doomed", false), e.get("part", -1), true,
				e.get("overkill", 0))
	join.done()


## Most a horde body's walk starts behind the pack's first, seconds. Enough that
## a room of one model does not stride off in lockstep; short against a step,
## so it still reads as one surge.
const HORDE_STAGGER := 0.3

## Crowd steering for the horde's walk (`_walk_crowd`), in metres and seconds.
## Two bodies closer than CROWD_SPACING push apart, harder the closer they are;
## CROWD_PUSH scales that against the body's own pace. A body rounds a waypoint
## once within CROWD_CORNER of it and is home within CROWD_ARRIVE of its tile.
const CROWD_SPACING := 0.85
const CROWD_PUSH := 1.6
const CROWD_CORNER := 0.45
const CROWD_ARRIVE := 0.06
## How far to either side of its line a body is checked for walls, metres.
const CROWD_BODY := 0.25
## Seconds a body may strain in place before it gives up its cut corners and
## follows its rules route tile by tile (`_back_onto_route`).
const CROWD_UNSTICK := 0.3


## One horde's activation (TurnManager._horde_turn), played as a pack rather than
## slot by slot. Two phases:
##   1. Every walk at once, as a CROWD (`_walk_crowd`): each body flows from where
##      it started to the tile the rules left it on, cutting corners where the
##      floor allows and shouldering the others aside, starting up to
##      HORDE_STAGGER behind the pack. Bodies squeeze past each other in the
##      rules too (SwarmUnit.squeezes_past), so nobody waits for a tile to clear.
##      Reaction fire at a body goes out as it starts the step that drew it, at
##      wherever its model is.
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
	var reactions: Array = []
	var blows: Array = []
	for i in events.size():
		var e: Dictionary = events[i]
		var kind: String = e["kind"]
		if kind == ExplorationRules.EV_STEP or kind == ExplorationRules.EV_TURN:
			moves.append(i)
		elif kind == ExplorationRules.EV_SHOT and e.get("reaction", false) and not e.get("melee", false):
			reactions.append(i)
		else:
			blows.append(i)
	var units := _units_in(events)
	var unspawned := {}
	_prepare(events, units, unspawned)
	LightingManager.begin_display()
	var map := tree.get_first_node_in_group("map")

	_update_visibility(units, unspawned, map, events, moves)
	if not moves.is_empty() or not reactions.is_empty():
		await _walk_crowd(events, moves, reactions, units, unspawned, map, tree)
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


## One body's part in the crowd walk.
class Walker:
	var unit: Unit
	## Where the model heads, in order: the rules route with its corners cut.
	var waypoints: Array[Vector3] = []
	var next := 0
	## The rules route itself: the start tile, then each step's tile.
	var route: Array[Vector3] = []
	## Metres along `route` at which each step begins and ends, by event index.
	var step_from := {}
	var step_to := {}
	var length := 0.0
	var travelled := 0.0
	var delay := 0.0
	var final_yaw := 0.0
	var moving := false
	var done := false
	## Seconds spent straining in place (`_steer` barely moving it) — diagnostics.
	var stalled := 0.0
	## Seconds it has been straining without a break (`_back_onto_route`).
	var stuck_for := 0.0


## Diagnostics for tools/profile_horde.gd: the last crowd walk's bodies that hit
## the wedged timeout, and the seconds all of them spent straining in place.
var crowd_timeouts: Array[String] = []
var crowd_stall_seconds := 0.0
var crowd_steer_usec := 0
var crowd_frames := 0


## Phase 1 of `play_horde`. Every body is steered once a frame until it is on its
## tile; reaction bursts (`reactions`) fire as their target starts the step that
## drew them, and are waited out before this returns.
func _walk_crowd(events: Array, moves: Array, reactions: Array, units: Array[Unit],
		unspawned: Dictionary, map: Node, tree: SceneTree) -> void:
	var walkers := _walkers(events, moves)
	crowd_timeouts.clear()
	crowd_stall_seconds = 0.0
	crowd_steer_usec = 0
	crowd_frames = 0
	for w: Walker in walkers.values():
		if w.route.size() < 2:
			# Turned on the spot and no more: the model's springs draw it.
			_play_turn(w.unit, w.final_yaw, false)
			w.done = true
	# Each reaction waits on the step of its target that drew it: the last step
	# that target took before the shot in the timeline (-1: none, fire at once).
	var pending: Array = []
	for r: int in reactions:
		var target: Variant = events[r].get("target")
		var at := -1
		for i: int in moves:
			if i > r:
				break
			if events[i]["unit"] == target and events[i]["kind"] == ExplorationRules.EV_STEP:
				at = i
		pending.append([r, at])
	var bursts := Join.new()
	bursts.left = 0
	var bodies: Array[Unit] = []
	for unit in units:
		if is_instance_valid(unit):
			bodies.append(unit)
	var clock := 0.0
	var since_seen := 0.0
	while true:
		var all_done := true
		var t0 := Time.get_ticks_usec()
		for w: Walker in walkers.values():
			if not w.done:
				_steer(w, bodies, clock, tree.root.get_process_delta_time() if clock > 0.0 else 0.0)
				all_done = all_done and w.done
		crowd_steer_usec += Time.get_ticks_usec() - t0
		crowd_frames += 1
		var still: Array = []
		for p: Array in pending:
			var e: Dictionary = events[p[0]]
			var w: Walker = walkers.get(e.get("target"))
			var arrival := 0.0
			if w != null and not w.done and w.step_from.has(p[1]):
				if w.travelled < w.step_from[p[1]]:
					still.append(p)
					continue
				arrival = maxf(0.0, w.step_to[p[1]] - w.travelled) / maxf(0.1, w.unit.move_speed)
			bursts.left += 1
			_play_reaction(e["unit"], e, arrival, bursts)
		pending = still
		if all_done and pending.is_empty():
			break
		await tree.process_frame
		var dt := minf(tree.root.get_process_delta_time(), 0.05)
		clock += dt
		since_seen += dt
		if since_seen >= 0.25:
			since_seen = 0.0
			_update_visibility(units, unspawned, map, events, moves)
	if bursts.left > 0:
		await bursts.finished


## Every walking body in `moves`, its route, staggered start and final facing.
func _walkers(events: Array, moves: Array) -> Dictionary:
	var offsets := _horde_offsets(events, moves)
	var walkers := {}
	for i: int in moves:
		var e: Dictionary = events[i]
		var unit: Unit = e["unit"]
		if not is_instance_valid(unit):
			continue
		var w: Walker = walkers.get(unit)
		if w == null:
			w = Walker.new()
			w.unit = unit
			w.delay = offsets.get(unit, 0.0)
			walkers[unit] = w
		if e["kind"] == ExplorationRules.EV_STEP:
			if w.route.is_empty():
				w.route.append(GridManager.grid_to_world(e["from"]))
			w.step_from[i] = w.length
			var to := GridManager.grid_to_world(e["to"])
			w.length += _flat(to - w.route[-1]).length()
			w.step_to[i] = w.length
			w.route.append(to)
		w.final_yaw = e["yaw"]
	for w: Walker in walkers.values():
		if w.route.size() >= 2:
			w.waypoints = crowd_route(w.route)
	return walkers


## One frame of one body: toward its next waypoint at its own pace, pushed off
## anyone within CROWD_SPACING, never over floor that is not walkable. Facing
## follows where it is heading rather than where it is shoved.
func _steer(w: Walker, bodies: Array[Unit], clock: float, dt: float) -> void:
	var unit := w.unit
	if not is_instance_valid(unit) or not unit.is_inside_tree():
		w.done = true
		return
	var visual := unit.visual
	if visual.is_ragdolled():
		w.done = true  # dropped mid-stride by a reaction burst: it falls where it is
		return
	if clock < w.delay:
		return
	var speed := maxf(0.1, unit.move_speed)
	# Wedged (pinned against a wall by the crowd well past the time its walk
	# needs): put on its tile rather than left straining at it.
	if clock > w.delay + w.length / speed * 2.5 + 1.5:
		crowd_timeouts.append(String(unit.name))
		_settle(w)
		return
	var pos := visual.global_position
	var last := w.waypoints.size() - 1
	if w.next >= last and _flat(w.waypoints[last] - pos).length() <= CROWD_ARRIVE:
		_settle(w)
		return
	while w.next < last and _flat(w.waypoints[w.next] - pos).length() < CROWD_CORNER:
		w.next += 1
	var target := w.waypoints[w.next]
	var to := _flat(target - pos)
	var dist := to.length()
	var want := to / dist * speed if dist > 0.001 else Vector3.ZERO
	if w.next == last:
		want *= clampf(dist / 0.6, 0.35, 1.0)  # easing in onto its own tile
	var push := Vector3.ZERO
	for other: Unit in bodies:
		if other == unit or not is_instance_valid(other) or other.is_downed:
			continue
		var away := _flat(pos - other.visual.global_position)
		var d := away.length()
		if d >= CROWD_SPACING:
			continue
		if d < 0.001:
			# Dead on top of each other: split by name, the same on every peer.
			away = Vector3(1, 0, 0) if String(unit.name) < String(other.name) else Vector3(-1, 0, 0)
			d = 0.001
		push += away / d * (1.0 - d / CROWD_SPACING)
	# A shove only ever moves a body ASIDE (and checks it a little): the part
	# straight against where it is going is dropped, so a body behind one that
	# has stopped in a corridor squeezes past it rather than straining at it.
	var heading := want.normalized() if want.length() > 0.001 else Vector3.ZERO
	var against := push.dot(heading)
	if against < 0.0:
		push -= heading * against * 0.8
	# Shoved less as it nears home, so the last bodies in still settle.
	var vel := want + push * speed * CROWD_PUSH * clampf(_flat(w.waypoints[last] - pos).length(), 0.0, 1.0)
	if vel.length() > speed * 1.3:
		vel = vel.normalized() * speed * 1.3
	var step := _walkable_step(pos, vel * dt, want * dt)
	var moved := step.length()
	if dt > 0.0 and moved < speed * dt * 0.25:
		w.stalled += dt
		w.stuck_for += dt
		crowd_stall_seconds += dt
		if w.stuck_for > CROWD_UNSTICK:
			_back_onto_route(w, pos)
	else:
		w.stuck_for = 0.0
	if moved > 0.0:
		var nxt := pos + step
		nxt.y = move_toward(pos.y, target.y, speed * dt * 2.0)
		visual.global_position = nxt
		w.travelled += moved
	if not w.moving and moved > speed * dt * 0.2:
		w.moving = true
		visual.set_stance_local(UnitVisual.WALK if unit.walks_only else UnitVisual.RUN)
	if want.length() > speed * 0.3:
		var local_yaw := atan2(-want.x, -want.z) - unit.rotation.y
		visual.rotation.y += wrapf(local_yaw - visual.rotation.y, -PI, PI)


## The move a body can actually make this frame: `step` if it stays on walkable
## floor, else that step slid along whichever axis is open (along a wall),
## else just `fallback` (its own way, unshoved), else nothing.
static func _walkable_step(pos: Vector3, step: Vector3, fallback: Vector3) -> Vector3:
	for tried: Vector3 in [step, Vector3(step.x, 0.0, 0.0), Vector3(0.0, 0.0, step.z), fallback,
			Vector3(fallback.x, 0.0, 0.0), Vector3(0.0, 0.0, fallback.z)]:
		if tried.length() > 0.0001 and _walkable_line(pos, pos + tried):
			return tried
	return Vector3.ZERO


## Given up on cutting corners: the waypoints become the rules route itself from
## the route tile nearest `pos` on, whose legs are tile centre to tile centre and
## always walkable, so a body wedged on a corner walks round it.
func _back_onto_route(w: Walker, pos: Vector3) -> void:
	w.stuck_for = 0.0
	var nearest := 0
	var best := INF
	for k in w.route.size():
		var d := _flat(w.route[k] - pos).length()
		if d < best:
			best = d
			nearest = k
	var rest: Array[Vector3] = []
	for k in range(nearest, w.route.size()):
		rest.append(w.route[k])
	if rest.size() == w.waypoints.size() - w.next and rest[0] == w.waypoints[w.next]:
		return  # already on it
	w.waypoints = rest
	w.next = 0


## Home: on its tile, facing the way the rules left it, at rest.
func _settle(w: Walker) -> void:
	w.done = true
	var visual := w.unit.visual
	visual.global_position = w.waypoints[-1]
	visual.rotation.y += wrapf(w.final_yaw - w.unit.rotation.y - visual.rotation.y, -PI, PI)
	visual.set_stance_local(UnitVisual.IDLE)


## The route with its corners cut: from each point, straight on to the furthest
## later one the body can reach in a line over walkable floor on the same deck.
## Starts and ends where `route` does. Pure: a test can read it.
static func crowd_route(route: Array[Vector3]) -> Array[Vector3]:
	var out: Array[Vector3] = [route[0]]
	var at := 0
	while at < route.size() - 1:
		var reach := at + 1
		for j in range(route.size() - 1, at + 1, -1):
			if _clear_run(route, at, j):
				reach = j
				break
		out.append(route[reach])
		at = reach
	return out


## Whether the straight run from route[a] to route[b] stays on walkable floor,
## the body's width either side included, and on one deck all the way.
static func _clear_run(route: Array[Vector3], a: int, b: int) -> bool:
	for k in range(a, b + 1):
		if absf(route[k].y - route[a].y) > 0.01:
			return false
	var from := route[a]
	var to := route[b]
	var side := _flat(to - from).normalized().cross(Vector3.UP) * CROWD_BODY
	return _walkable_line(from, to) and _walkable_line(from + side, to + side) \
		and _walkable_line(from - side, to - side)


## Whether every point of the segment, sampled finely, is over a passable tile.
static func _walkable_line(from: Vector3, to: Vector3) -> bool:
	var n := maxi(1, ceili(_flat(to - from).length() / (GridManager.TILE_SIZE * 0.2)))
	for k in range(1, n + 1):
		var t: GridTileData = GridManager.get_tile(GridManager.world_to_grid(from.lerp(to, float(k) / n)))
		if t == null or not t.passable:
			return false
	return true


static func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)


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
		e.get("lean", Vector3i.ZERO), e.get("doomed", false), e.get("part", -1),
		false, e.get("overkill", 0))


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
