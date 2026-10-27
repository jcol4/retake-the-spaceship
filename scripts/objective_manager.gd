extends Node
## Autoload. The mission's Contract (extraction plan 3.3, Phase 6): plants its
## target, says where the objective stands for the HUD, and decides at departure
## whether it was met — which ExtractionManager.build_result writes into the
## MissionResult.
##
## Mostly DERIVED state, mirrored by somebody else. Every peer calls
## `begin_mission` with the same contract (Contract.choose is deterministic in the
## shared spawn seed), plants the Retrieve item in its own copy of the same crate,
## builds the Hold terminal on its own copy of the same tile, finds the Destroy
## nest and the Recover VIP (spawned by main.gd on every peer) by tile — and from
## then on most of what this reads is already mirrored: the item's whereabouts by
## Unit.inventory_codes and LootManager's container snapshots, the nest's and the
## VIP's state by Unit.life_state and the carry links.
##
## The ONE thing it owns is the Hold terminal's clock (TerminalRules): host-
## authoritative, changed only by `operate_terminal` and the round-start tick, and
## mirrored to clients whole by `_rpc_terminal` on every change. Only the host's
## verdict (in the MissionResult) is ever acted on.

## The objective line may read differently now. Fired on every peer.
signal objective_changed

var contract: Contract = null
## DESTROY: the target nest, once found on the board.
var _nest: Unit = null
## RECOVER: the VIP, once found on the board (VipUnit; spawned by main.gd).
var _vip: Unit = null
## HOLD: the console's clock, and the prop that shows it.
var terminal_rules: TerminalRules = null
var _terminal: TerminalProp = null
## Units whose pack this manager listens to, for the objective line.
var _watched: Array = []
## RETRIEVE: a rival crew flew the item out (Phase 8, `note_carried_off`). The
## item is off the deck for good, and the objective line says so rather than the
## bare "lost" an item nobody can find gets.
var carried_off := false


func _is_authority() -> bool:
	return not SteamLobby.is_networked() or SteamLobby.is_host()


func is_active() -> bool:
	return contract != null


## Arms the contract on THIS peer. Call on every peer after the units have spawned
## (the Destroy target is a spawned nest, the Recover VIP a spawned unit) and after
## the map is built (the Hold console goes under it) — main.gd `_spawn_and_start`.
## `null` clears it.
func begin_mission(c: Contract) -> void:
	reset()
	contract = c
	if c == null:
		objective_changed.emit()
		return
	match c.type:
		Contract.Type.RETRIEVE:
			if not LootManager.put(c.target_tile, c.item_code):
				push_warning("ObjectiveManager: no crate at %s to plant %s in" % [c.target_tile, c.item_code])
		Contract.Type.DESTROY:
			_nest = _find_nest(c.target_tile)
			if _nest == null:
				push_warning("ObjectiveManager: no nest at %s to destroy" % c.target_tile)
			else:
				_nest.downed.connect(_on_nest_downed)
		Contract.Type.HOLD:
			terminal_rules = TerminalRules.new()
			_build_terminal(c.target_tile)
		Contract.Type.RECOVER:
			_vip = _find_vip(c.target_tile)
			if _vip == null:
				push_warning("ObjectiveManager: no VIP at %s to recover" % c.target_tile)
			else:
				_vip.died.connect(_on_anything_changed)
				_vip.carry_changed.connect(_on_anything_changed)
	if not LootManager.container_changed.is_connected(_on_anything_changed):
		LootManager.container_changed.connect(_on_anything_changed)
	if not TurnManager.turn_started.is_connected(_on_turn_started):
		TurnManager.turn_started.connect(_on_turn_started)
	for node in get_tree().get_nodes_in_group("units"):
		var unit := node as Unit
		if unit != null:
			unit.inventory_changed.connect(_on_anything_changed)
			_watched.append(unit)
	objective_changed.emit()


func reset() -> void:
	if _nest != null and is_instance_valid(_nest) and _nest.downed.is_connected(_on_nest_downed):
		_nest.downed.disconnect(_on_nest_downed)
	if _vip != null and is_instance_valid(_vip):
		if _vip.died.is_connected(_on_anything_changed):
			_vip.died.disconnect(_on_anything_changed)
		if _vip.carry_changed.is_connected(_on_anything_changed):
			_vip.carry_changed.disconnect(_on_anything_changed)
	for unit in _watched:
		if is_instance_valid(unit) and unit.inventory_changed.is_connected(_on_anything_changed):
			unit.inventory_changed.disconnect(_on_anything_changed)
	_watched.clear()
	if _terminal != null and is_instance_valid(_terminal):
		var t: GridTileData = GridManager.get_tile(_terminal.tile)
		if t:
			t.passable = true
		_terminal.queue_free()
	_terminal = null
	terminal_rules = null
	_nest = null
	_vip = null
	contract = null
	carried_off = false


## A merc is boarding his crew's ship (ExtractionManager, every peer, before the
## unit leaves the board): if he carries the Retrieve item it leaves with him.
func note_carried_off(unit: Unit) -> void:
	if contract == null or contract.type != Contract.Type.RETRIEVE or unit == null:
		return
	if unit.has_item_code(contract.item_code):
		carried_off = true
		objective_changed.emit()


func target_nest() -> Unit:
	return _nest


## DESTROY: the target nest is dead. Complete "whether or not anyone extracts"
## (plan 3.3) — the PAYOUT still needs an extraction, which is why the result is
## only ever built for one.
func nest_destroyed() -> bool:
	return _nest != null and is_instance_valid(_nest) and _nest.life_state == Unit.LifeState.DEAD


## RECOVER: the VIP on the board, or null.
func vip() -> Unit:
	return _vip if _vip != null and is_instance_valid(_vip) else null


## Whether the objective is met for a departure carrying `extracted` (every unit
## aboard, carried bodies and escorts included).
##   RETRIEVE  the item is in the pack of somebody aboard: a soldier, a downed
##             soldier carried on, or a corpse carried on (plan 3.3: "or on a
##             carried corpse").
##   DESTROY   the nest is dead.
##   HOLD      the console's count finished (latched; plan Phase 6 "complete when
##             the count finishes").
##   RECOVER   the VIP is aboard — carried on, or set down in the square
##             (ExtractionManager.escorts_aboard) — and ALIVE. A dead VIP is a
##             failed contract however carefully the body comes home.
func is_complete(extracted: Array) -> bool:
	if contract == null:
		return false
	match contract.type:
		Contract.Type.RETRIEVE:
			for unit in extracted:
				if unit is Unit and is_instance_valid(unit) and (unit as Unit).has_item_code(contract.item_code):
					return true
			return false
		Contract.Type.DESTROY:
			return nest_destroyed()
		Contract.Type.HOLD:
			return terminal_rules != null and terminal_rules.is_complete()
		Contract.Type.RECOVER:
			var v := vip()
			return v != null and extracted.has(v) and v.life_state == Unit.LifeState.DOWNED
	return false


## Where the Retrieve item is now: the Unit whose pack holds it, the LootContainer
## it is in, or null (it should never be nowhere — an item is always somewhere).
func item_holder() -> Object:
	if contract == null or contract.type != Contract.Type.RETRIEVE:
		return null
	for node in get_tree().get_nodes_in_group("units"):
		var unit := node as Unit
		if unit != null and unit.has_item_code(contract.item_code):
			return unit
	for c: LootContainer in LootManager.all_containers():
		for item in c.items:
			if item.code == contract.item_code:
				return c
	return null


# --- Hold the terminal (extraction plan Phase 6) -----------------------------------


## HOLD: the console prop, or null.
func terminal() -> TerminalProp:
	return _terminal if _terminal != null and is_instance_valid(_terminal) else null


## Why `unit` cannot operate the console right now, or "". Rules only; the AP is
## the caller's (PlayerUnit.try_operate_terminal prices it). Any soldier, whoever
## owns them — the crew is the whole squad (GDD §7.6).
func operate_blocker(unit: Unit) -> String:
	var t := terminal()
	if t == null or terminal_rules == null:
		return "no terminal on this deck"
	if unit == null or unit.life_state != Unit.LifeState.ACTIVE:
		return "not able"
	if not unit.within_reach(t.tile):
		return "out of reach"
	return terminal_rules.start_blocker()


## Host: `unit` starts (or restarts) the console. Validated with `operate_blocker`;
## false if refused. The round it starts in is a round it runs, so it is loud now.
func operate_terminal(unit: Unit) -> bool:
	if not _is_authority() or operate_blocker(unit) != "":
		return false
	var resumed := terminal_rules.state == TerminalRules.State.PAUSED
	terminal_rules.start()
	_terminal_noise()
	TurnManager._log("%s %s the terminal (%d/%d) — it's loud" % [unit.stats.display_name,
		"restarts" if resumed else "starts", terminal_rules.progress, TerminalRules.HOLD_ROUNDS])
	_broadcast_terminal()
	return true


## Whether the console is HELD: some soldier on their feet within reach of it.
## "Any contractor" (plan Phase 6) read as the player's crew — which is every
## PlayerUnit, both co-op players' (GDD §7.6). The door gun never stands next to a
## console; the VIP is never on its feet. Phase 8 mercs contesting a Hold contract
## would need their own crew's answer here.
func terminal_held() -> bool:
	var t := terminal()
	if t == null:
		return false
	for node in get_tree().get_nodes_in_group("player_units"):
		var unit := node as Unit
		if unit != null and unit.is_player_controlled and unit.life_state == Unit.LifeState.ACTIVE \
				and unit.within_reach(t.tile):
			return true
	return false


## Host, every round start: the console counts a round if it is held, or pauses.
## Loud every round it runs (TerminalRules.NOISE_RADIUS) — through the ordinary
## sound channel, so whatever hears it comes to look.
func _on_turn_started(_turn: int) -> void:
	if not _is_authority() or terminal_rules == null or not terminal_rules.is_running():
		return
	var tick := terminal_rules.tick(terminal_held())
	if TerminalRules.is_loud(tick):
		_terminal_noise()
	match tick:
		TerminalRules.Tick.COUNTED:
			TurnManager._log("Terminal: %d/%d rounds held" % [terminal_rules.progress, TerminalRules.HOLD_ROUNDS])
		TerminalRules.Tick.COMPLETED:
			TurnManager._log("Terminal: upload complete — extract to get paid")
		TerminalRules.Tick.INTERRUPTED:
			TurnManager._log("Terminal: nobody at the console — paused at %d/%d" % [
				terminal_rules.progress, TerminalRules.HOLD_ROUNDS])
	_broadcast_terminal()


func _terminal_noise() -> void:
	var t := terminal()
	if t != null:
		SecurityNetwork.report_noise(t.tile, null, TerminalRules.NOISE_RADIUS)


## The console prop on THIS peer, its tile made impassable like a crate's
## (LootManager.build_from) — reachable for `within_reach`, never stood on.
## Deterministic, so every peer builds its own and nothing is sent.
func _build_terminal(tile: Vector3i) -> void:
	var t: GridTileData = GridManager.get_tile(tile)
	if t == null:
		push_warning("ObjectiveManager: no tile at %s for the terminal" % tile)
		return
	t.passable = false
	_terminal = TerminalProp.new()
	_terminal.setup(tile)
	var parent: Node = get_tree().get_first_node_in_group("map")
	if parent == null:
		parent = get_tree().root
	parent.add_child(_terminal)
	_terminal.refresh(terminal_rules)


func _broadcast_terminal() -> void:
	_present_terminal()
	if SteamLobby.is_networked() and SteamLobby.is_host():
		_rpc_terminal.rpc(terminal_rules.snapshot())


## A client applies the host's console clock.
@rpc("authority", "call_remote", "reliable")
func _rpc_terminal(snap: Array) -> void:
	if terminal_rules == null:
		return
	terminal_rules.apply_snapshot(snap)
	_present_terminal()


func _present_terminal() -> void:
	var t := terminal()
	if t != null:
		t.refresh(terminal_rules)
	objective_changed.emit()


# --- The HUD line --------------------------------------------------------------------


## The HUD's objective line (plan 3.3, Phase 6): "Retrieve: Data Core — not
## found", "— carried by Reyes", "— on Okafor's body", "— in a pile"; "Destroy:
## Nest — alive (38/50)", "— destroyed, extract to get paid"; "Hold: Terminal —
## running 2/4"; "Recover: Dr. Halvorsen — carried by Reyes (stable 20/20)". Empty
## when there is no contract.
func status_text() -> String:
	if contract == null:
		return ""
	var state := ""
	match contract.type:
		Contract.Type.RETRIEVE:
			var holder := item_holder()
			if holder is Unit:
				var unit := holder as Unit
				if unit.life_state == Unit.LifeState.DEAD:
					state = "on %s's body" % unit.stats.display_name
				elif unit.is_player_controlled:
					state = "carried by %s%s" % [unit.stats.display_name,
						" (downed)" if unit.life_state == Unit.LifeState.DOWNED else ""]
				else:
					state = "taken by %s" % unit.stats.display_name
			elif holder is LootContainer:
				state = "in a pile" if (holder as LootContainer).is_pile else "not found"
			elif carried_off:
				state = "flown out by a rival crew"
			else:
				state = "lost"
		Contract.Type.DESTROY:
			if _nest == null or not is_instance_valid(_nest):
				state = "no nest"
			elif nest_destroyed():
				state = "destroyed — extract to get paid"
			else:
				state = "alive (%d/%d)" % [_nest.current_hp, _nest.stats.max_hp()]
		Contract.Type.HOLD:
			state = terminal_rules.describe() if terminal_rules != null else "no terminal"
		Contract.Type.RECOVER:
			var v := vip()
			if v == null:
				state = "no VIP"
			elif v.life_state == Unit.LifeState.DEAD:
				state = "dead — contract failed"
			elif v.carried_by != null:
				state = "carried by %s (stable %d/%d) — get them aboard" % [
					v.carried_by.stats.display_name, v.downed_hp, v.downed_bar_max()]
			else:
				state = "down, stable (%d/%d) — find them, carry them out" % [v.downed_hp, v.downed_bar_max()]
	return "%s — %s   [%d cr]" % [contract.title(), state, contract.payout]


func _find_nest(tile: Vector3i) -> Unit:
	for node in get_tree().get_nodes_in_group("units"):
		if node is NestUnit and (node as Unit).grid_pos == tile:
			return node
	return null


func _find_vip(tile: Vector3i) -> Unit:
	for node in get_tree().get_nodes_in_group(VipUnit.GROUP):
		if node is VipUnit and (node as Unit).grid_pos == tile:
			return node
	return null


func _on_nest_downed(_unit: Unit) -> void:
	objective_changed.emit()


func _on_anything_changed(_arg: Variant = null) -> void:
	objective_changed.emit()
