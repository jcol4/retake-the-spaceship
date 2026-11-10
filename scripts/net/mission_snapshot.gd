class_name MissionSnapshot
extends RefCounted
## A running mission as data (MULTIPLAYER_PLAN.md §2.5): what a rejoining co-op
## client needs to catch up, and what a co-op host's checkpoint holds so the
## mission survives the host's game closing.
##
## A DELTA, NOT A WORLD. Every peer already builds the identical starting board
## from the deployment (main.gd `_spawn_and_start`: the same deck, the same units
## at the same paths, the same rolls off `spawn_seed`). A snapshot only records how
## the mission has moved on from that board:
##   journal   every change that ADDED something to it — a nest's spawn, a worm
##             shed from a pile, a dev spawn — and every hit on cover, in order,
##             replayed through the very functions that did them the first time
##             (so the new units get the same names, stats and paths)
##   units     every unit's state: the replicated set (Unit.REPLICATED, exactly
##             what a client's synchronizer receives) plus what is not streamed —
##             injuries, ownership, grenades, the gun, awareness, naming counters
##   gone      implied: a unit on the rebuilt board the snapshot does not list
##             (a merc who flew out, a worm absorbed into a pile) is taken off it
##   world     hangars, who is aboard, every container's contents, the terminal,
##             the hivemind and the round
##
## Plain Variants throughout (Vector3i, NodePath, packed arrays): an RPC carries it
## as-is, and `to_text`/`from_text` (var_to_str) store it losslessly in a file.
##
## WHAT IS NOT IN IT: AI plans and squad blackboards, merc job progress, reaction
## tracks, suppression links, in-flight animation. A resumed host restarts the
## round the checkpoint was taken at with those rebuilt fresh; a rejoining client
## never runs AI at all.

const VERSION := 1

## The journal of the mission being played, recorded on the host (and solo, where
## nobody reads it) by the code paths that add to the board. `reset` at mission
## start; replaced wholesale by `apply` on a resumed host.
static var journal: Array = []


static func reset() -> void:
	journal = []


## A unit was added mid-mission or cover was hit — see the class comment. Entries:
##   ["nest", nest_name, node_name, kind, tile, stat_seed]
##   ["worm", pile_name, node_name, tile, hp]
##   ["dev",  kind, tile, node_name, extra]
##   ["cover", tile, side, amount]
static func note(entry: Array) -> void:
	journal.append(entry.duplicate(true))


# --- Capture --------------------------------------------------------------------------


## The mission under `main` (the mission scene, which every unit is a child of).
static func capture(main: Node) -> Dictionary:
	var units: Array = []
	for child in main.get_children():
		var unit := child as Unit
		if unit != null and not unit.is_queued_for_deletion():
			units.append(_capture_unit(unit))
	var dev := main.get_node_or_null("DevSpawn")
	var active: Unit = TurnManager.active_unit
	return {
		"version": VERSION,
		"turn": {
			"number": TurnManager.turn_number,
			"mode": int(TurnManager.mode),
			"steps": TurnManager.steps,
			"last_combat": TurnManager._last_squad_combat_round,
			"active": String(active.name) if is_instance_valid(active) and TurnManager.mode == TurnManager.Mode.TURN else "",
		},
		"journal": journal.duplicate(true),
		"dev_counter": int(dev.get("_counter")) if dev != null else 0,
		"units": units,
		"hangars": ExtractionManager.capture() if ExtractionManager.is_active() else {},
		"loot": _capture_loot(),
		"rooms": RoomSystems.current().capture() if RoomSystems.current() != null else {},
		"objective": {
			"terminal": ObjectiveManager.terminal_rules.snapshot() if ObjectiveManager.terminal_rules != null else [],
			"carried_off": ObjectiveManager.carried_off,
		},
		"world": {
			"escalated": AlienHivemind.is_escalated,
			"last_trigger": AlienHivemind.last_trigger,
			"salvage": SecurityNetwork.salvage,
		},
	}


static func _capture_unit(unit: Unit) -> Dictionary:
	var props := {}
	for prop in Unit.REPLICATED:
		props[prop] = unit.get_indexed(NodePath(prop))
	var extra := {
		"grid_pos": unit.grid_pos,
		"owner_peer_id": unit.owner_peer_id,
		"part_damage": unit._body_part_damage.duplicate(),
		"injured": unit._injured_parts.duplicate(),
		"stunned": unit.stunned,
		"overwatch_reserve": unit.overwatch_reserve,
		"last_moved_turn": unit.last_moved_turn,
		"aboard": unit.aboard,
		"visible": unit.visible,
	}
	if unit is PlayerUnit:
		var p := unit as PlayerUnit
		extra["owner_key"] = p.owner_key
		extra["record_id"] = p.record_id
		extra["grenade_charges"] = p.grenade_charges
		extra["deployed_grenades"] = p.deployed_grenades
		extra["weapon"] = Campaign.weapon_dict(p.stats.weapon)
	if unit is EnemyUnit:
		var e := unit as EnemyUnit
		extra["alert_state"] = int(e.alert_state)
		extra["last_known_pos"] = e.last_known_pos
	if unit is CerberusUnit:
		extra["emp_turns"] = (unit as CerberusUnit).emp_turns
	if unit is NestUnit:
		extra["activations"] = (unit as NestUnit).activations
		extra["spawned"] = (unit as NestUnit).spawned
	if unit is WormUnit:
		extra["shed_count"] = unit.get("_shed_count")
	return {"name": String(unit.name), "props": props, "extra": extra}


static func _capture_loot() -> Array:
	var out: Array = []
	for c: LootContainer in LootManager.all_containers():
		out.append([c.tile, c.codes(), c.is_pile])
	return out


# --- Apply ----------------------------------------------------------------------------


## Brings the freshly built board under `main` to `snap`. `as_host` is a resumed
## host (it will run the mission from here, so the journal carries on and the turn
## loop is restarted by the caller — `TurnManager.resume_mission`); otherwise a
## rejoining client, whose TurnManager only mirrors, so the round and the drawn
## unit are set here. Idempotent enough to apply over a board that has already had
## the base spawns and nothing else.
static func apply(main: Node, snap: Dictionary, as_host: bool) -> void:
	if snap.is_empty():
		return
	journal = (snap.get("journal", []) as Array).duplicate(true)
	_replay_journal(main, journal)
	if RoomSystems.current() != null:
		RoomSystems.current().restore(snap.get("rooms", {}))
	var dev := main.get_node_or_null("DevSpawn")
	if dev != null:
		dev.set("_counter", int(snap.get("dev_counter", 0)))

	# Hangars before units: a landed ship mounts its door gunner, and the gunner's
	# state is then just another unit's below.
	ExtractionManager.restore(snap.get("hangars", {}), main)

	var listed := {}
	for u: Dictionary in snap.get("units", []):
		listed[String(u.get("name", ""))] = u
	for child in main.get_children():
		var unit := child as Unit
		if unit != null and not unit.is_queued_for_deletion() and not listed.has(String(unit.name)):
			_remove(unit)
	for name: String in listed:
		var unit := main.get_node_or_null(NodePath(name)) as Unit
		if unit != null:
			_apply_unit(unit, listed[name])
	# Carry links and life states resolved, every unit's tile is final: rebuild the
	# occupancy from scratch, which no unit-by-unit order can get right while two
	# units may be swapping tiles between the base board and the snapshot.
	_rebuild_occupancy(main)
	# Aboard (after the props, which hid nothing): off the board on every peer.
	var paths := PackedStringArray()
	for name: String in listed:
		var extra: Dictionary = (listed[name] as Dictionary).get("extra", {})
		var unit := main.get_node_or_null(NodePath(name)) as Unit
		if unit != null and bool(extra.get("aboard", false)) and not unit.aboard:
			paths.append(String(unit.get_path()))
	if not paths.is_empty():
		ExtractionManager._take_aboard(paths)

	_apply_loot(snap.get("loot", []))
	var obj: Dictionary = snap.get("objective", {})
	var term: Array = obj.get("terminal", [])
	if ObjectiveManager.terminal_rules != null and not term.is_empty():
		ObjectiveManager.terminal_rules.apply_snapshot(term)
		ObjectiveManager._present_terminal()
	ObjectiveManager.carried_off = bool(obj.get("carried_off", false))
	ObjectiveManager.objective_changed.emit()
	var world: Dictionary = snap.get("world", {})
	AlienHivemind.is_escalated = bool(world.get("escalated", false))
	AlienHivemind.last_trigger = world.get("last_trigger", Vector3i.ZERO)
	SecurityNetwork.salvage = int(world.get("salvage", 0))
	LightingManager.recompute_dynamic()
	GridManager.invalidate_sight_cache()

	if not as_host:
		var turn: Dictionary = snap.get("turn", {})
		TurnManager._rpc_mode_changed(int(turn.get("mode", 0)), int(turn.get("steps", 0)), int(turn.get("number", 0)))
		var active := String(turn.get("active", ""))
		if active != "":
			var unit := main.get_node_or_null(NodePath(active)) as Unit
			if unit != null:
				TurnManager._rpc_sync_active_unit(unit.get_path())


## Replays the journal onto a board that has only the base spawns. Each entry goes
## back through the code that made it the first time, minus the recording and the
## broadcast — the nest's `_spawn_at`, the pile's `_add_worm`, DevSpawn's `_build`,
## GridManager's `_damage_cover_edge` — so names and stats come out the same.
static func _replay_journal(main: Node, entries: Array) -> void:
	for e: Array in entries:
		match String(e[0]):
			"nest":
				var nest := main.get_node_or_null(NodePath(String(e[1]))) as NestUnit
				if nest != null and main.get_node_or_null(NodePath(String(e[2]))) == null:
					nest._spawn_at(String(e[2]), int(e[3]), e[4], int(e[5]))
			"worm":
				var pile := main.get_node_or_null(NodePath(String(e[1]))) as WormUnit
				if pile != null and main.get_node_or_null(NodePath(String(e[2]))) == null:
					pile._add_worm(String(e[2]), e[3], int(e[4]))
			"dev":
				var dev := main.get_node_or_null("DevSpawn")
				if dev == null:
					dev = DevSpawn.new(main)
					main.add_child(dev)
				if main.get_node_or_null(NodePath(String(e[3]))) == null:
					dev._build(StringName(e[1]), e[2], String(e[3]), e[4])
			"cover":
				GridManager._damage_cover_edge(e[1], int(e[2]), int(e[3]))


static func _apply_unit(unit: Unit, d: Dictionary) -> void:
	var extra: Dictionary = d.get("extra", {})
	if unit is PlayerUnit:
		var p := unit as PlayerUnit
		p.owner_key = String(extra.get("owner_key", p.owner_key))
		p.record_id = String(extra.get("record_id", p.record_id))
		p.grenade_charges = int(extra.get("grenade_charges", p.grenade_charges))
		p.deployed_grenades = int(extra.get("deployed_grenades", p.deployed_grenades))
		var w: Dictionary = extra.get("weapon", {})
		if not w.is_empty():
			var atts := PackedInt32Array(w.get("attachments", []))
			var ammo := int(w.get("ammo", -1))
			# The gun first: `ammo`/`reserve` below are set against ITS magazine, and
			# `_loadout_*` is what the host replays to a client that shows up later.
			p.stats.weapon = WeaponPresets.make(int(w.get("id", 0)), atts, ammo)
			p._loadout_weapon_id = int(w.get("id", 0))
			p._loadout_attachment_ids = atts
			p._loadout_ammo_id = ammo
			p.sync_gun_model()
	unit.owner_peer_id = int(extra.get("owner_peer_id", unit.owner_peer_id))
	var props: Dictionary = d.get("props", {})
	for prop: String in props:
		unit.set_indexed(NodePath(prop), props[prop])
	unit.grid_pos = extra.get("grid_pos", unit.grid_pos)
	unit._body_part_damage = (extra.get("part_damage", {}) as Dictionary).duplicate()
	unit._injured_parts = (extra.get("injured", {}) as Dictionary).duplicate()
	unit.stunned = bool(extra.get("stunned", false))
	unit.overwatch_reserve = int(extra.get("overwatch_reserve", 0))
	unit.last_moved_turn = int(extra.get("last_moved_turn", -1))
	if unit is EnemyUnit and extra.has("alert_state"):
		var e := unit as EnemyUnit
		e.last_known_pos = extra.get("last_known_pos", e.last_known_pos)
		e._rpc_show_state(int(extra["alert_state"]) as EnemyUnit.AlertState)
	if unit is CerberusUnit:
		(unit as CerberusUnit).emp_turns = int(extra.get("emp_turns", 0))
	if unit is NestUnit:
		(unit as NestUnit).activations = int(extra.get("activations", 0))
		(unit as NestUnit).spawned = int(extra.get("spawned", 0))
	if unit is WormUnit and extra.has("shed_count"):
		unit.set("_shed_count", int(extra["shed_count"]))
	# Everything a client does after a synchronized batch lands: present the life
	# state, re-link carried bodies, draw the right gun, rebuild the pack from its
	# codes, refresh the HUD's AP and the beam. The same code, so a snapshot can
	# never look different from what the stream would have produced.
	unit._after_replication()
	if unit.life_state == Unit.LifeState.ACTIVE:
		unit.global_position = GridManager.grid_to_world(unit.grid_pos)
	if unit.has_signal("hp_changed"):
		unit.hp_changed.emit(unit)


## Takes a unit the snapshot does not list off the rebuilt board, the way a merc
## boarding his ship or an absorbed worm leaves it: out of every group and the
## pool, off its tile, and freed.
static func _remove(unit: Unit) -> void:
	var tile: GridTileData = GridManager.get_tile(unit.grid_pos)
	if tile != null and tile.occupant == unit:
		GridManager.set_occupant(unit.grid_pos, null)
	TurnManager.pool.erase(unit)
	for group in unit.get_groups():
		unit.remove_from_group(group)
	# Left in the tree until the frame ends, as the game's own removals are: the
	# unit is still wired to signals (lighting, the grid) that fire in the meantime.
	unit.visible = false
	unit.queue_free()


## Every tile's occupant, from scratch: each standing unit on the board on its
## `grid_pos`. Bodies hold no tile (Unit._present_life_state).
static func _rebuild_occupancy(main: Node) -> void:
	for tile: GridTileData in GridManager.tiles.values():
		if tile.occupant is Unit:
			tile.occupant = null
	for child in main.get_children():
		var unit := child as Unit
		if unit != null and not unit.is_queued_for_deletion() and not unit.aboard 				and unit.life_state == Unit.LifeState.ACTIVE:
			GridManager.set_occupant(unit.grid_pos, unit)


## Every container to its captured contents: a crate that changed, a pile that
## formed (created by the same path a client's mirror uses), a pile since emptied.
static func _apply_loot(entries: Array) -> void:
	var seen := {}
	for e: Array in entries:
		var tile: Vector3i = e[0]
		seen[tile] = true
		LootManager._rpc_contents(tile, PackedStringArray(e[1]), bool(e[2]))
	for c: LootContainer in LootManager.all_containers():
		if not seen.has(c.tile):
			LootManager._rpc_contents(c.tile, PackedStringArray(), c.is_pile)


# --- Storage --------------------------------------------------------------------------


## A snapshot as text for a file, losslessly (Vector3i, NodePath, packed arrays).
static func to_text(snap: Dictionary) -> String:
	return var_to_str(snap)


static func from_text(text: String) -> Dictionary:
	var v: Variant = str_to_var(text)
	return v if v is Dictionary else {}
