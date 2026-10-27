extends Node
## Autoload. Hangars, the ship, and how a mission ends by leaving (GDD §7.1–7.4).
##
## A thin node wrapper round ExtractionRules, which owns every timer and rule and
## is what tools/test_extraction.gd drives. This side does what the rules cannot:
## listens to the turn loop and to soldiers moving, makes the call-in loud,
## spawns and animates the Dropship, ends the mission through
## `TurnManager.end_mission`, and mirrors hangar state to clients.
##
## HOST-AUTHORITATIVE. On the host (and in single-player) this runs the rules;
## every state change goes out as one `_rpc_hangar_state` call, and a client's
## copy only applies those snapshots and animates the transitions — it never
## advances a timer or decides a departure itself. Both peers derive the hangar
## GEOMETRY from their own identical MapData, so only state crosses the wire.
##
## Inactive (every query answers "no", every hook returns at once) until
## `begin_mission` hands it a deck with at least one hangar — which is what keeps
## the legacy clear-out decks and every test that never calls it untouched.

## A deck's hangars were (re)loaded. The HUD rebuilds its markers on this.
signal hangars_reset
## Hangar `index` changed state on this peer (host: as it happens; client: as the
## snapshot lands). Countdown text is derived from the state plus
## TurnManager.turn_number, so turn starts are the HUD's other refresh cue.
signal hangar_changed(index: int)
## Hangar `index` became known to the player crew.
signal hangar_discovered(index: int)
## The map-wide radio notice (GDD §7.3): crew `crew_id` called a ship. Carries NO
## position on purpose — only the 15-tile sound gives a call-in's location away.
## The HUD logs it; rival mercs listen to it in extraction plan Phase 8.
signal ship_called(crew_id: int)
signal ship_landed(index: int)
## The ship at `index` took off; `boarded` says whether anyone was aboard.
signal ship_departed(index: int, boarded: bool)
## A line for the combat log (and the HUD's brief radio banner when `radio`).
## Fired on every peer from the same transitions, so a client narrates exactly
## what the host does without a second log channel.
signal notice(text: String, radio: bool)

## Seconds the ramp stays down during the insertion before the ship lifts off.
## Long enough to read "they're out", short enough not to drag every mission.
const INSERTION_DISEMBARK_PAUSE := 0.8

var rules := ExtractionRules.new()
var data: MapData = null
var _active := false
## Hangar index -> its Dropship while one is on screen (landed or animating).
var _dropships: Dictionary = {}
## PlayerUnits whose `stepped` this manager listens to, for discovery.
var _watched: Array = []

## Hangar index -> the pad tiles this manager made impassable while its ship is
## down (`_block_pad`), so the release puts back exactly what it took.
var _blocked_pads: Dictionary = {}

## Hangar index -> the DoorGunUnit on its landed ship (extraction plan Phase 5),
## live or disabled, from landing until takeoff. Every peer keeps its own.
var _door_guns: Dictionary = {}
## Hangar index -> how many gunners that hangar has had this mission. Only for
## node NAMES: a re-called ship's fresh gunner must not reuse the old one's path
## (it is freed with `queue_free`, which may not have happened yet), and both
## peers count the same landings, so both arrive at the same name.
var _door_gun_serial: Dictionary = {}

## Merc crew id -> its MercJob (extraction plan Phase 8), armed in
## `begin_mission`. Every peer builds them (cheaply, deterministically), but only
## the host's are ever read: merc AI runs on the host.
var _merc_jobs: Dictionary = {}
## MercUnits whose `stepped` this manager listens to, for their crew's discovery.
var _watched_mercs: Array = []
## Rival departures this mission, for the debrief (MissionResult.rivals): one
## wire-safe entry per merc ship that left with somebody aboard. Host-built.
var _rival_departures: Array = []


func _ready() -> void:
	# Registered once for the process lifetime — TurnManager keeps hooks across
	# missions, and `_on_round_ending` is a no-op while inactive.
	TurnManager.add_turn_end_hook(_on_round_ending)
	TurnManager.turn_started.connect(_on_turn_started)
	TurnManager.squad_gone_hook = _on_squad_gone


## Same rule as TurnManager: single-player, or the co-op host.
func _is_authority() -> bool:
	return not SteamLobby.is_networked() or SteamLobby.is_host()


## Arms the manager for a new mission on `map_data`. Call on EVERY peer once the
## squad has spawned (main.gd `_spawn_and_start`), before the mission starts:
## clients need the hangar geometry to mirror state against, and discovery needs
## the squad's `moved` signals.
func begin_mission(map_data: MapData) -> void:
	_clear_ships()
	_retire_all_door_guns()
	_door_gun_serial.clear()
	_unwatch_all()
	_unblock_all_pads()
	_merc_jobs.clear()
	_rival_departures.clear()
	data = map_data
	rules = ExtractionRules.new()
	rules.setup(map_data.hangars if map_data != null else [])
	_active = rules.hangar_count() > 0
	if _active:
		for node in get_tree().get_nodes_in_group("player_units"):
			var unit := node as Unit
			if unit == null:
				continue
			# Per TILE, not per settled move: walking straight through a bay finds
			# it as surely as stopping in one does (Phase 1 only heard `moved`,
			# the end of a walk, so a squad could cross a hangar without knowing).
			unit.stepped.connect(_on_unit_stepped)
			_watched.append(unit)
			# A squad that starts standing in a hangar other than the insertion
			# one (a hand-authored test deck, say) knows it from the outset. On every
			# peer, not just the host: spawn positions are identical everywhere, so
			# this needs no broadcast.
			rules.discover_room(data.room_index_at(unit.grid_pos))
		_arm_merc_crews()
	hangars_reset.emit()


## Drops everything mission-scoped. Safe to call with no mission running.
func reset() -> void:
	begin_mission(null)


func is_active() -> bool:
	return _active


func hangar(index: int) -> MapData.Hangar:
	return data.hangars[index]


## Player-facing name: "Hangar A", "Hangar B"... in deck order.
func hangar_name(index: int) -> String:
	return "Hangar %s" % char(65 + index)


## Which crew a unit flies with (ExtractionRules crew ids). Every PlayerUnit is
## the player crew whichever co-op peer owns it (GDD §7.6). Each merc squad is
## its own crew (Phase 8, `_arm_merc_crews`): MERC_CREW_BASE and up. Nothing else
## belongs to a crew.
##
## A door gun is in NO crew whoever's ship it rides (Phase 5): it is part of the
## ship, not a passenger, so a departure must never sort it into extracted or
## lost. Checked first and by type, so the merc branch below cannot pick a merc
## ship's gunner up by its faction.
func crew_of(unit: Unit) -> int:
	if unit is DoorGunUnit:
		return ExtractionRules.NO_CREW
	if unit != null and unit.is_player_controlled:
		return ExtractionRules.PLAYER_CREW
	if unit is MercUnit:
		return (unit as MercUnit).crew_id
	return ExtractionRules.NO_CREW


## The MercJob crew `crew` is running, or null (not a merc crew, or no mission).
func merc_job(crew: int) -> MercJob:
	return _merc_jobs.get(crew)


## Every merc crew id armed this mission, ascending.
func merc_crews() -> Array:
	var out: Array = _merc_jobs.keys()
	out.sort()
	return out


## Rival departures this mission (see `_rival_departures`), as a copy.
func rival_report() -> Array:
	return _rival_departures.duplicate(true)


## Gives every merc squad on the board a crew id and a job (Phase 8). Squads are
## numbered in squad-id order from MERC_CREW_BASE, so every peer — and every run of
## the same deck — numbers them alike. The job's rolls are seeded from the deck
## seed and the squad id for the same reason (host-only in practice, but a seed
## that replays is a seed you can debug). Each crew knows the hangar it spawned
## in, if any, exactly as the player crew does (`begin_mission` above).
func _arm_merc_crews() -> void:
	var squads: Dictionary = {}  # squad_id -> Array[MercUnit]
	for node in get_tree().get_nodes_in_group("units"):
		var merc := node as MercUnit
		if merc == null or merc.is_downed:
			continue
		if not squads.has(merc.squad_id):
			squads[merc.squad_id] = []
		squads[merc.squad_id].append(merc)
	var ids: Array = squads.keys()
	ids.sort()
	for k in ids.size():
		var squad_id: String = ids[k]
		var crew := ExtractionRules.MERC_CREW_BASE + k
		var members: Array = squads[squad_id]
		var rng := RandomNumberGenerator.new()
		rng.seed = hash([data.seed, squad_id])
		var job := MercJob.new()
		job.setup(crew, squad_id, members.size(), rng)
		_merc_jobs[crew] = job
		for merc: MercUnit in members:
			merc.crew_id = crew
			merc.job = job
			merc.stepped.connect(_on_merc_stepped)
			_watched_mercs.append(merc)
			var room := data.room_index_at(merc.grid_pos)
			job.visit_room(room)
			rules.discover_room_for(room, crew)


## What else leaves on the ship with `unit` — THE CARRIED-BODIES SEAM: the downed
## soldier or corpse it is carrying (GDD §4.4, §7.4: "and so does anything they
## are carrying"). Read only through `ExtractionRules.split_passengers`, which is
## what lets a CORPSE extract at all — the square test there skips the dead, and
## a rider bypasses it. (A carried DOWNED body shares its carrier's tile, so it
## would have counted as in the square anyway; listing it here as well is
## harmless — split_passengers never adds a unit twice.)
func riders_of(unit: Unit) -> Array:
	if unit != null and unit.carrying != null:
		return [unit.carrying]
	return []


# --- Queries (both peers; the HUD reads these) ------------------------------------


## The hangar `unit` could call the ship to right now (standing anywhere in a
## discovered bay, nothing else claimed — see ExtractionRules.call_blocker), or -1.
## AP is the caller's business (PlayerUnit / the HUD price it).
func callable_hangar_for(unit: Unit) -> int:
	if not _active or unit == null or unit.life_state != Unit.LifeState.ACTIVE:
		return -1
	return rules.callable_from(unit.grid_pos, crew_of(unit))


## The hangar `unit` could signal dust-off at (in the square of its crew's landed
## ship, not yet signalled), or -1.
func dust_off_hangar_for(unit: Unit) -> int:
	if not _active or unit == null or unit.life_state != Unit.LifeState.ACTIVE:
		return -1
	return rules.dust_off_from(unit.grid_pos, crew_of(unit))


## The hangar `crew` holds (CALLED or LANDED), or -1.
func claim_of(crew: int) -> int:
	return rules.claim_of(crew) if _active else -1


## The hangar `unit` could BOARD at — standing in the square of its crew's landed
## ship — or -1 (GDD §7.4). AP is the caller's business.
func board_hangar_for(unit: Unit) -> int:
	if not _active or unit == null or unit.life_state != Unit.LifeState.ACTIVE or unit.aboard:
		return -1
	return rules.hangar_at_square(unit.grid_pos) \
		if rules.board_blocker(unit.grid_pos, crew_of(unit)) == "" else -1


## Why `unit`'s crew cannot Extract right now, or "" (GDD §7.4): their own ship
## is down and somebody of theirs is aboard or alive in its square. Asked of the
## crew, not the soldier — any of them may give the word, wherever they stand.
func extract_blocker(unit: Unit) -> String:
	if not _active or unit == null:
		return "no ship"
	var crew := crew_of(unit)
	if crew == ExtractionRules.NO_CREW:
		return "no ship"
	return rules.extract_blocker(crew, _crew_units(crew))


## Who is aboard the player crew's ship right now (host; clients keep their own
## copy through `_take_aboard`). For the HUD's extract confirmation.
func aboard_units() -> Array:
	var out: Array = []
	for node in get_tree().get_nodes_in_group(ABOARD_GROUP):
		out.append(node)
	return out


## Group for units that have boarded a ship and left the board (see `_take_aboard`).
const ABOARD_GROUP := &"aboard_units"


# --- Commands (host only; PlayerUnit.try_call_ship / try_dust_off) ------------------


## `unit` calls the ship (GDD §7.3). The caller has already checked and will
## charge the AP. Claims the hangar, starts the 3-round countdown, makes the
## 15-tile noise, and puts out the positionless radio notice. False if invalid.
##
## NO AlienHivemind escalation (extraction plan A2): the noise already reaches the
## aliens through the ordinary sound channel by their own hearing rules, and an
## escalation on top would make every call-in a deck-wide wake-up, which the GDD
## does not ask for (§11.2 lists it as TBD).
func call_ship(unit: Unit) -> bool:
	if not _is_authority():
		return false
	var index := callable_hangar_for(unit)
	if index < 0:
		return false
	var old := rules.state_of(index)
	if not rules.call_ship(index, crew_of(unit), TurnManager.turn_number):
		return false
	# From the PAD, not the caller: the sound is the ship's approach and the
	# hangar spinning up, and it gives away the hangar, not the soldier. No source
	# to exclude — nothing on the deck is deaf to it.
	SecurityNetwork.report_noise(hangar(index).pad_center, null, ExtractionRules.CALL_NOISE_RADIUS)
	_broadcast(index, old)
	return true


## `unit` signals dust-off: the ship leaves at the end of this round. 0 AP
## (extraction plan A1). False if `unit` is not in its crew's landed square.
func request_dust_off(unit: Unit) -> bool:
	if not _is_authority():
		return false
	var index := dust_off_hangar_for(unit)
	if index < 0:
		return false
	var old := rules.state_of(index)
	rules.request_dust_off(unit.grid_pos, crew_of(unit))
	_broadcast(index, old, false, false)
	return true


## `unit` walks up the ramp (GDD §7.4 "Board"), with whatever it carries: off
## the board, out of the fight, and safe — nothing can target, finish or bleed
## them now — and certain to leave with the ship however the mission ends from
## here (`split_passengers` puts the aboard first). The caller has checked
## `board_hangar_for` and charges the AP. It does NOT end the mission: that is
## Extract's job, so one soldier can carry a casualty aboard while another holds
## the bay. False if invalid.
func board(unit: Unit) -> bool:
	if not _is_authority():
		return false
	var index := board_hangar_for(unit)
	if index < 0:
		return false
	var going: Array = [unit]
	if unit.carrying != null:
		going.append(unit.carrying)
	rules.board(index, going)
	var names := PackedStringArray()
	for u: Unit in going:
		names.append(String(u.get_path()))
	_take_aboard(names)
	if SteamLobby.is_networked() and SteamLobby.is_host():
		_rpc_take_aboard.rpc(names)
	var carried := " with %s" % unit.carrying.stats.display_name if unit.carrying != null else ""
	notice.emit("%s boards the ship at %s%s." % [unit.stats.display_name, hangar_name(index), carried], false)
	return true


## Takes the units at `paths` off the board on THIS peer (host and clients alike):
## out of every group anything targets, draws or counts from ("units",
## "player_units"), out of the pool, off their tile, hidden and unclickable, beam
## off. The nodes stay in the tree in ABOARD_GROUP — MissionResult names them by
## path — and `Unit.aboard` marks them for anything that still holds a reference.
## A carried body keeps its link to its carrier: both are aboard.
func _take_aboard(paths: PackedStringArray) -> void:
	for p in paths:
		var unit := get_node_or_null(NodePath(p)) as Unit
		if unit == null or unit.aboard:
			continue
		unit.aboard = true
		unit.remove_from_group("units")
		unit.remove_from_group("player_units")
		unit.add_to_group(ABOARD_GROUP)
		TurnManager.pool.erase(unit)
		var tile: GridTileData = GridManager.get_tile(unit.grid_pos)
		if tile and tile.occupant == unit:
			GridManager.set_occupant(unit.grid_pos, null)
		unit.flashlight_on = false
		unit.visible = false
		var body := unit.get_node_or_null("Body") as CollisionObject3D
		if body:
			body.collision_layer = 0
	LightingManager.recompute_dynamic()


@rpc("authority", "call_remote", "reliable")
func _rpc_take_aboard(paths: PackedStringArray) -> void:
	_take_aboard(paths)


## `unit` gives the word to EXTRACT (GDD §7.4): the crew's ship leaves NOW with
## everyone aboard and everyone alive in its square, and the mission ends. 0 AP,
## from anywhere, on any of the crew's activations — the soldier asking does not
## have to be in the square. Everyone of the crew still outside is left behind.
## False if invalid (`extract_blocker`).
func extract(unit: Unit) -> bool:
	if not _is_authority() or extract_blocker(unit) != "":
		return false
	var index := rules.claim_of(crew_of(unit))
	_depart(index, TurnManager.turn_number, true)
	return true


## TurnManager's last word before it calls a wipe (`TurnManager.squad_gone_hook`):
## nobody of the player crew is standing on the board — but if some of them are
## aboard a landed ship, nobody is left to say "go", so the ship goes: the
## pilot's call. True if a departure took the mission over.
func _on_squad_gone() -> bool:
	if not _active or not _is_authority():
		return false
	var index := rules.claim_of(ExtractionRules.PLAYER_CREW)
	if index < 0 or rules.state_of(index) != ExtractionRules.State.LANDED \
			or rules.states[index].aboard.is_empty():
		return false
	notice.emit("Nobody left on the deck — the ship lifts off with whoever is aboard.", true)
	_depart(index, TurnManager.turn_number, true)
	return true


# --- Turn loop (host) ---------------------------------------------------------------


func _on_turn_started(turn: int) -> void:
	if not _active or not _is_authority():
		return
	var before: Array[int] = []
	for i in rules.hangar_count():
		before.append(rules.state_of(i))
	for i in rules.start_round(turn):
		_broadcast(i, before[i])


## TurnManager turn-end hook: every ship due out this round leaves now (GDD §7.4).
## Awaited by TurnManager before the next round, so a departure that ends the
## mission ends it before anyone acts again.
func _on_round_ending(turn: int) -> void:
	if not _active or not _is_authority():
		return
	for index in rules.departures_due(turn):
		if TurnManager.mission_over:
			return
		await _depart(index, turn)


## One ship leaving. With anyone aboard: the result is built FIRST (MissionResult
## records units by node path, and they must still be on the board to have
## one), the hangar resolves and goes out to clients, the ship lifts, and only
## then does the mission end — so the last thing on screen is the ship leaving.
## Empty: the ship lifts and the pad cools down, and the mission carries on.
##
## `now` is the crew's own Extract (and the pilot's call when nobody is left on
## the deck): the mission ends FIRST, synchronously — the command that asked for
## it, or TurnManager's end check, must find it over when it returns — and the
## lift-off then plays under the end banner. Without `now` (the window ran out at
## the end of a round) it is awaited as before.
func _depart(index: int, turn: int, now := false) -> void:
	var crew := rules.states[index].claimed_by
	var split := rules.split_passengers(index, _crew_units(crew), riders_of)
	# Boarded is decided by the CREW: a VIP lying in an otherwise empty square
	# does not fly the ship home on their own.
	var boarded: bool = not split["extracted"].is_empty()
	if boarded and crew == ExtractionRules.PLAYER_CREW:
		split["extracted"].append_array(escorts_in_square(index, split["extracted"]))
	var result: MissionResult = null
	if boarded and crew == ExtractionRules.PLAYER_CREW:
		result = build_result(split)
	elif boarded and crew != ExtractionRules.NO_CREW:
		# A rival crew's lift (Phase 8): it ends THEIR run, never the mission.
		_merc_crew_boards(crew, split)
	var old := rules.state_of(index)
	rules.resolve_departure(index, turn, boarded)
	_broadcast(index, old)
	if now:
		if result != null:
			TurnManager.end_mission(result)
		_take_off(index)
		return
	await _take_off(index)
	if result != null:
		TurnManager.end_mission(result)


## The EXTRACTED result for a departure split (see ExtractionRules.split_passengers):
## extracted = who left aboard, lost = every other soldier, dead or alive.
## Loot (every extracted pack) and the objective verdict come from Phase 3.
func build_result(split: Dictionary) -> MissionResult:
	var result := MissionResult.new(MissionResult.Outcome.EXTRACTED)
	# The Recover VIP (Phase 6) rides home — as a carrier's rider or set down in
	# the square — but is not the squad: kept out of the result's lists (and so
	# out of the roll call, the loot manifest and the debrief), and read only by
	# the objective verdict below.
	var escorts: Array = []
	for unit in split["extracted"]:
		if unit is VipUnit:
			escorts.append(unit)
		elif unit is Unit:
			result.extracted_units.append(unit)
			# Only a rider can be dead here (the square test skips corpses), so
			# this is exactly "a body somebody carried aboard".
			if unit.life_state == Unit.LifeState.DEAD:
				result.recovered_corpses.append(unit)
	for unit in split["lost"]:
		if unit is Unit:
			result.lost_units.append(unit)
	# Extraction plan 3.3: what came out, and whether the contract was met — both
	# read off who is aboard, carried bodies included (a Retrieve item on a carried
	# corpse counts; GDD §7.5 "losing its carrier loses it" is the other half).
	result.loot = MissionResult.manifest_for(result.extracted_units)
	result.objective_complete = ObjectiveManager.is_complete(result.extracted_units + escorts)
	if ObjectiveManager.contract != null:
		result.contract = ObjectiveManager.contract.to_dict()
	return result


## The Recover VIPs (VipUnit) lying uncarried and alive in hangar `index`'s square
## — set down there by whoever carried them in — that are not already in
## `aboard`. They leave with the player crew's ship like a downed soldier lying in
## the square would (GDD §7.4), though they are in no crew (`crew_of`): the squad
## loads them. A carried VIP is already aboard as its carrier's rider
## (`riders_of`). Not for merc crews: the VIP is the player's contract.
func escorts_in_square(index: int, aboard: Array) -> Array:
	var out: Array = []
	var h := hangar(index)
	if h == null:
		return out
	for node in get_tree().get_nodes_in_group(VipUnit.GROUP):
		var vip := node as Unit
		if vip == null or aboard.has(vip) or vip.carried_by != null \
				or vip.life_state != Unit.LifeState.DOWNED or not h.in_square(vip.grid_pos):
			continue
		out.append(vip)
	return out


## Every unit on the board that flies with `crew`, in any life state: the
## candidates a departure sorts into extracted and lost.
func _crew_units(crew: int) -> Array:
	var out: Array = []
	if crew == ExtractionRules.NO_CREW:
		return out
	for node in get_tree().get_nodes_in_group("units"):
		var unit := node as Unit
		if unit != null and crew_of(unit) == crew:
			out.append(unit)
	return out


## Host: merc crew `crew` lifts off with `split["extracted"]` aboard (Phase 8).
## The mission goes on — only crew 0's lift builds a MissionResult.
##   - What they carry leaves with them: their packs are gone from the deck, and a
##     contested Retrieve item among them is flown out (ObjectiveManager notes it,
##     so the objective line says so instead of "lost").
##   - The ones aboard leave the board on every peer (`_board_mercs`, then the
##     names go to clients). Corpses and anyone outside the square stay: a dead
##     merc's pack is still on his body, and a living straggler is stranded — his
##     crew's run is over (ExtractionRules.retired_crews) and he goes on as a plain
##     merc.
##   - A line for the debrief (MissionResult.rivals via `rival_report`).
func _merc_crew_boards(crew: int, split: Dictionary) -> void:
	var aboard: Array = []
	var items: Array = []
	for unit in split["extracted"]:
		var merc := unit as MercUnit
		if merc == null or crew_of(merc) != crew:
			continue
		aboard.append(merc)
		items.append_array(Array(merc.inventory_codes))
	var stranded := 0
	for unit in split["lost"]:
		if unit is Unit and (unit as Unit).life_state == Unit.LifeState.ACTIVE:
			stranded += 1
	var job := merc_job(crew)
	if job != null:
		job.depart()
	_rival_departures.append({
		"crew": crew, "aboard": aboard.size(), "stranded": stranded, "items": items,
		"turn": TurnManager.turn_number,
	})
	var names := PackedStringArray()
	for merc: MercUnit in aboard:
		names.append(String(merc.name))
	TurnManager._log("%s board their ship (%d aboard, %d item(s))." % [
		", ".join(aboard.map(func(m: MercUnit) -> String: return m.stats.display_name)),
		aboard.size(), items.size()])
	_board_mercs(names)
	if SteamLobby.is_networked() and SteamLobby.is_host():
		_rpc_board_mercs.rpc(names)


## Takes the named mercs off the board (every peer): their contract item, if any,
## is noted as flown out first, then each one leaves (MercUnit.board_ship).
func _board_mercs(names: PackedStringArray) -> void:
	var parent := _unit_parent()
	if parent == null:
		return
	for n in names:
		var merc := parent.get_node_or_null(NodePath(n)) as MercUnit
		if merc == null:
			continue
		ObjectiveManager.note_carried_off(merc)
		merc.board_ship()


## Mirror of `_board_mercs` for clients. Sent BEFORE the hangar's own state (both
## reliable, same node, so in order), so a client's departure presentation runs
## with the boarded mercs already gone, as the host's does.
@rpc("authority", "call_remote", "reliable")
func _rpc_board_mercs(names: PackedStringArray) -> void:
	_board_mercs(names)


func _on_unit_stepped(unit: Unit) -> void:
	if not _active or not _is_authority() or data == null:
		return
	var index := rules.discover_room(data.room_index_at(unit.grid_pos))
	if index >= 0:
		# The state it is in NOW as the "old" one: discovering a hangar some other
		# crew is mid-call on must not replay that call's transition.
		_broadcast(index, rules.state_of(index), true)


## A merc stepped: its crew has now seen this room — its containers, and the
## hangar if it is one (GDD §7.2, by the same "entered the room" rule as the
## player). Host-only state with no presentation, so nothing is broadcast.
func _on_merc_stepped(unit: Unit) -> void:
	if not _active or not _is_authority() or data == null:
		return
	var merc := unit as MercUnit
	if merc == null or merc.job == null:
		return
	var room := data.room_index_at(merc.grid_pos)
	merc.job.visit_room(room)
	rules.discover_room_for(room, merc.crew_id)


# --- State out to clients, and presentation on every peer ---------------------------


## Host: announce hangar `index`'s new state here and to every client.
## `old_dust` is whether dust-off was ALREADY signalled before this change; only
## `request_dust_off` changes it without changing the state, so it alone passes
## false, and the default reads as "no dust-off transition".
func _broadcast(index: int, old_state: int, newly_discovered := false, old_dust := true) -> void:
	_present(index, old_state, old_dust, newly_discovered)
	if SteamLobby.is_networked() and SteamLobby.is_host():
		_rpc_hangar_state.rpc(index, rules.snapshot(index))


## The one mission-level RPC (extraction plan 1.4): a client applies the host's
## snapshot of one hangar and plays whatever transition it implies.
@rpc("authority", "call_remote", "reliable")
func _rpc_hangar_state(index: int, snap: Array) -> void:
	if not rules.is_valid(index):
		return
	var old := rules.state_of(index)
	var was_known := rules.is_discovered(index)
	var old_dust := rules.states[index].dust_off_requested
	rules.apply_snapshot(index, snap)
	_present(index, old, old_dust, rules.is_discovered(index) and not was_known)


## Everything a state change LOOKS like, run identically on host and client:
## signals for the HUD, the log/radio line, the ship's moves, and the square's
## highlight. Never changes rules state.
func _present(index: int, old_state: int, old_dust: bool, newly_discovered: bool) -> void:
	var s := rules.states[index]
	var label := hangar_name(index)
	var S := ExtractionRules.State
	if newly_discovered:
		hangar_discovered.emit(index)
		notice.emit("%s discovered." % label, false)
		# A rival ship already sitting on a hangar the squad just walked into
		# becomes visible with it (`_ship_visible`).
		_refresh_ship_visibility(index)
	# Phase 8: a rival crew's ship says nothing about WHERE it is unless the
	# player already knows the hangar (GDD §7.3: a call never reveals one). The
	# markers already follow that rule; these lines and the hull follow it too.
	var ours := s.claimed_by == ExtractionRules.PLAYER_CREW
	var known := rules.is_discovered(index)
	if s.state == S.CALLED and old_state != S.CALLED:
		ship_called.emit(s.claimed_by)
		_hurry_merc_crews(s.claimed_by)
		# Positionless for every crew (GDD §7.3). The marker says where for our own.
		notice.emit("RADIO: A ship has been called." if ours \
			else "RADIO: Another crew has called a ship.", true)
	if s.state == S.LANDED and old_state != S.LANDED:
		_block_pad(index)
		# After the pad is blocked (and, on the host, cleared): the gunner stands
		# on a pad tile, and `_clear_pad` would otherwise nudge it off.
		spawn_door_gun(index, s.claimed_by)
		ship_landed.emit(index)
		if ours:
			notice.emit("The ship is down at %s — get into the square." % label, true)
		elif known:
			notice.emit("A rival ship is down at %s — its door gun covers the square." % label, true)
		_land(index)
	if s.state == S.LANDED and s.dust_off_requested and not old_dust and (ours or known):
		notice.emit("Dust-off signalled — the ship leaves at the end of this round." if ours \
			else "The rival crew at %s signals dust-off." % label, ours)
	if old_state == S.LANDED and s.state != S.LANDED:
		# The gunner goes with the ship — live or disabled (GDD §7.4: it stays down
		# "for the rest of that landing", and this is the end of it).
		_retire_door_gun(index)
		_unblock_pad(index)
		var boarded := s.state != S.COOLDOWN
		var was_ours := s.last_crew == ExtractionRules.PLAYER_CREW
		ship_departed.emit(index, boarded)
		if boarded and was_ours:
			_hide_boarded(index)
			notice.emit("The ship lifts off from %s." % label, true)
		elif boarded:
			# The squad hears a rival lift go over the net either way; where only if
			# they know the hangar.
			notice.emit("The rival ship lifts off from %s." % label if known \
				else "RADIO: A rival crew's ship has left the deck.", true)
		elif was_ours or known:
			notice.emit("The %s left %s empty. The pad cools down for %d rounds." % [
				"ship" if was_ours else "rival ship", label, ExtractionRules.COOLDOWN_ROUNDS], true)
		_clear_square_highlight(index)
		# The host's `_depart` awaits the take-off itself (the mission must not end
		# until the ship is gone); a client just plays it.
		if not _is_authority():
			_take_off(index)
	hangar_changed.emit(index)


## Soldiers walking up the ramp: everyone not dead in the square vanishes into
## the ship as it lifts. Cosmetic, and computed from positions so both peers
## agree without being told who boarded. The nodes stay in the tree — the
## MissionResult names them by path.
func _hide_boarded(index: int) -> void:
	var square: Array = hangar(index).square
	for node in get_tree().get_nodes_in_group("player_units"):
		var unit := node as Unit
		if unit != null and square.has(unit.grid_pos) and unit.life_state != Unit.LifeState.DEAD:
			unit.visible = false
	# A Recover VIP set down in the square boards with them (`escorts_in_square`).
	for node in get_tree().get_nodes_in_group(VipUnit.GROUP):
		var vip := node as Unit
		if vip != null and vip.carried_by == null and square.has(vip.grid_pos) \
				and vip.life_state != Unit.LifeState.DEAD:
			vip.visible = false


# --- The Dropship -----------------------------------------------------------------------


## The MapBuilder the ship belongs under: it is level geometry, and goes with
## the deck on a rebuild.
func _map_node() -> Node3D:
	return get_tree().get_first_node_in_group("map") as Node3D


## Spawns a Dropship over hangar `h`'s pad, at hover height unless `landed`.
## Null when there is no built map (a headless rules test).
func spawn_dropship(h: MapData.Hangar, landed := false) -> Dropship:
	var map := _map_node()
	if map == null:
		return null
	var ship := Dropship.new()
	map.add_child(ship)
	ship.place(map.cell_to_world(h.pad_center), h.ramp_side, landed)
	return ship


func _land(index: int) -> void:
	if _dropships.has(index):
		return
	var ship := spawn_dropship(hangar(index))
	if ship == null:
		_refresh_ship_visibility(index)
		return
	_dropships[index] = ship
	_refresh_ship_visibility(index)
	# The gunner is on the board (and in the pool) from the landing transition,
	# but it rides IN on the roof: hidden until the hull it sits on has come down,
	# or it would hang in the air over the pad for the length of the descent.
	var gun := door_gun(index)
	if gun != null:
		gun.visible = false
	await ship.descend()
	if gun != null and is_instance_valid(gun):
		gun.visible = true
	if is_instance_valid(ship) and _dropships.get(index) == ship:
		await ship.lower_ramp()


## Whether hangar `index`'s ship (and its square highlight) is drawn: always for
## the player crew's own, and for a rival's only once the player knows the hangar
## (Phase 8) — a hull hanging over an undiscovered bay would give away exactly
## what the positionless radio notice keeps back (GDD §7.3). The rival door
## gunner needs nothing here: it is a unit, and the fog of war already hides
## units in compartments the squad cannot see.
func _ship_visible(index: int) -> bool:
	var s := rules.states[index]
	return s.claimed_by == ExtractionRules.PLAYER_CREW or rules.is_discovered(index)


func _refresh_ship_visibility(index: int) -> void:
	var landed := rules.state_of(index) == ExtractionRules.State.LANDED
	var shown := _ship_visible(index)
	var ship: Dropship = _dropships.get(index)
	if ship != null and is_instance_valid(ship):
		ship.visible = shown
	if landed and shown:
		_show_square_highlight(index)


## Host: a crew called a ship — every OTHER merc crew hears it over the net (the
## positionless notice, GDD §7.3) and brings its own departure forward
## (MercJob.hear_rival_call). Where the call came from reaches them only through
## the 15-tile noise, by the ordinary hearing rules.
func _hurry_merc_crews(caller: int) -> void:
	if not _is_authority():
		return
	for crew in _merc_jobs:
		if crew != caller:
			(_merc_jobs[crew] as MercJob).hear_rival_call(TurnManager.turn_number)


## Lifts and frees hangar `index`'s ship, if one is on screen. Safe to call twice
## (host's departure and its own presentation both do): the second finds nothing.
func _take_off(index: int) -> void:
	var ship: Dropship = _dropships.get(index)
	_dropships.erase(index)
	if ship == null or not is_instance_valid(ship):
		return
	await ship.take_off()
	if is_instance_valid(ship):
		ship.queue_free()


## The landed ship's hull covers the 3x3 pad, so while it is down those tiles are
## impassable (Phase 1 left them walkable, and a soldier standing on the pad stood
## inside the hull). Every peer blocks its own grid — the geometry is identical
## everywhere — and the host then moves anybody already standing there off it
## (`_clear_pad`); positions reach clients the usual ways.
##
## The ship also BLOCKS LINE OF SIGHT AND LIGHT across its reserved space while it
## is down (GDD §7.2): a layer-1 blocker (Dropship.make_blocker) goes on the pad —
## the square in front stays open — and the static light map is recomputed round
## it. The door gunner's corner is left out of the blocker so the gun can see and
## be seen. Placed at the LANDED transition, not when the descent animation ends:
## the rules say the ship is down, so sightlines change now on every peer alike.
func _block_pad(index: int) -> void:
	if _blocked_pads.has(index):
		return
	var tiles: Array[Vector3i] = []
	for cell in MapData.hangar_pad_cells(hangar(index).pad_center):
		var t: GridTileData = GridManager.get_tile(cell)
		if t != null and t.passable:
			t.passable = false
			tiles.append(cell)
	_blocked_pads[index] = tiles
	_add_blocker(index)
	if _is_authority():
		_clear_pad(index)


func _unblock_pad(index: int) -> void:
	var tiles: Array = _blocked_pads.get(index, [])
	_blocked_pads.erase(index)
	for cell: Vector3i in tiles:
		var t: GridTileData = GridManager.get_tile(cell)
		if t != null:
			t.passable = true
	_remove_blocker(index)


## Hangar index -> its landed ship's ShipBlocker (see `_block_pad`).
var _blockers: Dictionary = {}


## Hangar `index`'s sight-and-light blocker while its ship is down, else null.
func ship_blocker(index: int) -> StaticBody3D:
	var body: Variant = _blockers.get(index)
	return body if body != null and is_instance_valid(body) else null


func _add_blocker(index: int) -> void:
	var map := _map_node()
	if map == null or _blockers.has(index):
		return
	var h := hangar(index)
	var body := Dropship.make_blocker(map.cell_to_world(h.pad_center), h.ramp_side)
	map.add_child(body)
	_blockers[index] = body
	_relight()


func _remove_blocker(index: int) -> void:
	var body: Node = _blockers.get(index)
	_blockers.erase(index)
	if body != null and is_instance_valid(body):
		# Off layer 1 at once — `queue_free` waits for the frame, and the light map
		# is recomputed before then.
		(body as StaticBody3D).collision_layer = 0
		body.queue_free()
		_relight()


## Lighting is a set of raycasts against layer 1, so a blocker arriving or
## leaving changes which tiles each fixture reaches. The physics space takes a
## new or retired body on its next step, hence the wait for one before the
## recompute. Headless rules tests have no map and never get here.
func _relight() -> void:
	if not is_inside_tree():
		return
	await get_tree().physics_frame
	LightingManager.recompute_base()


func _unblock_all_pads() -> void:
	for index in _blocked_pads.keys():
		_unblock_pad(index)


## Host: nudges every unit on hangar `index`'s pad — standing soldiers, enemies,
## and bodies lying there — to the nearest free, passable tile off the pad
## (breadth-first from where it stood, so "nearest" is by steps, and tiles taken
## by an earlier nudge are skipped). A carried body goes with its carrier. Logged,
## because a soldier who moves without being ordered to needs explaining.
func _clear_pad(index: int) -> void:
	var pad: Array = _blocked_pads.get(index, [])
	if pad.is_empty():
		return
	var claimed := {}  # tiles already handed to a body this pass (bodies hold no occupancy)
	for node in get_tree().get_nodes_in_group("units"):
		var unit := node as Unit
		if unit == null or unit.carried_by != null or not pad.has(unit.grid_pos):
			continue
		if unit is DoorGunUnit:
			continue  # a ship's gunner stands on its pad by design (MapData.hangar_gun_cell)
		if unit.is_queued_for_deletion():
			continue
		var standing := unit.life_state == Unit.LifeState.ACTIVE
		var dest := _nearest_off_pad(unit.grid_pos, pad, claimed, standing)
		if dest == unit.grid_pos:
			push_warning("ExtractionManager: no free tile to move %s off the pad at %s" % [
				unit.stats.display_name, hangar_name(index)])
			continue
		var from := unit.grid_pos
		claimed[dest] = true
		unit.relocate_to(dest)
		notice.emit("%s is moved clear of the landing ship (%s -> %s)." % [
			unit.stats.display_name, from, dest], false)


## Breadth-first from `from` over every neighbour (pad tiles included, so a unit
## in the middle of the pad can get out) to the first passable tile that is off
## the pad and not already claimed this pass. A STANDING unit also needs it
## unoccupied (`is_free`); a body only needs it passable, since bodies hold no
## tile and may share one. Returns `from` if nothing qualifies.
func _nearest_off_pad(from: Vector3i, pad: Array, claimed: Dictionary, standing: bool) -> Vector3i:
	var seen := {from: true}
	var frontier: Array[Vector3i] = [from]
	while not frontier.is_empty():
		var cur: Vector3i = frontier.pop_front()
		for n in GridManager.neighbors(cur):
			if seen.has(n):
				continue
			seen[n] = true
			var t: GridTileData = GridManager.get_tile(n)
			if t == null:
				continue
			if pad.has(n):
				frontier.append(n)  # walk through the pad, never stop on it
				continue
			if not t.passable:
				continue
			if not claimed.has(n) and (GridManager.is_free(n) if standing else true):
				return n
			frontier.append(n)
	return from


func _clear_ships() -> void:
	for index in _dropships:
		var ship: Dropship = _dropships[index]
		if is_instance_valid(ship):
			ship.queue_free()
	_dropships.clear()


# --- The door gun (GDD §7.4, extraction plan Phase 5) ---------------------------------


## The faction a crew's door gunner fights for. The player's crew is the
## Contractors; every other crew id is a rival merc squad (ExtractionRules
## MERC_CREW_BASE and up), whose ship's gun "shoots at you" (GDD §7.4).
func crew_faction(crew: int) -> Faction.Id:
	return Faction.Id.CONTRACTORS if crew == ExtractionRules.PLAYER_CREW else Faction.Id.RIVAL_MERCS


## The gunner on hangar `index`'s landed ship (live or disabled), or null.
func door_gun(index: int) -> DoorGunUnit:
	var gun: DoorGunUnit = _door_guns.get(index)
	return gun if gun != null and is_instance_valid(gun) else null


## What a crew's door gun is doing right now — the HUD's ship line. NONE while
## the crew has no ship on the ground (not called, still inbound, or gone).
enum DoorGunStatus { NONE, ACTIVE, DISABLED }


func door_gun_status(crew: int) -> DoorGunStatus:
	var index := claim_of(crew)
	if index < 0 or rules.state_of(index) != ExtractionRules.State.LANDED:
		return DoorGunStatus.NONE
	var gun := door_gun(index)
	if gun == null:
		return DoorGunStatus.NONE
	return DoorGunStatus.DISABLED if gun.is_disabled() else DoorGunStatus.ACTIVE


## Puts a fresh gunner for `crew` on hangar `index`'s pad (MapData.hangar_gun_cell,
## under the Dropship's door_gun_mount) and returns it. Called from `_present` on
## the landing transition, so it runs on EVERY peer, and that is the co-op
## approach (decision log, Phase 5): the same deterministic spawn the board itself
## uses (main.gd `_spawn_and_start`) rather than a host spawn the client has to be
## told about. Each peer derives the tile from its own MapData, the stats are
## fixed constants (nothing rolls), and the node NAME comes from a landing count
## both peers keep in step — so the host's MultiplayerSynchronizer (Unit
## `_setup_replication`, opened to every ready peer on creation) finds the
## client's copy at the same path, and HP and life state stream over it.
##
## Host only, it also joins the CURRENT round's pool: a landing happens on
## `turn_started`, after TurnManager took that round's snapshot, and "joins the
## initiative pool" (GDD §4.1, §7.4) means from the round it lands. From the next
## round on it is simply one of the "units" the snapshot finds.
##
## THE SPAWN ENTRY POINT FOR ANY CREW (extraction plan Phase 8): a merc ship's
## landing goes through `_present` like ours and gets its gunner here, fighting
## for `crew_faction(crew)`. Returns null with no board to stand on (a rules-only
## test that never built a map) or a gunner already there.
func spawn_door_gun(index: int, crew: int) -> DoorGunUnit:
	if door_gun(index) != null or data == null or not rules.is_valid(index):
		return null
	var h := hangar(index)
	var tile := MapData.hangar_gun_cell(h.pad_center, h.ramp_side)
	if not GridManager.has_tile(tile):
		return null
	var parent := _unit_parent()
	if parent == null:
		return null
	var serial: int = _door_gun_serial.get(index, 0) + 1
	_door_gun_serial[index] = serial
	var label := "Door gun %s" % char(65 + index) if crew == ExtractionRules.PLAYER_CREW \
		else "Hostile door gun %s" % char(65 + index)
	var gun := DoorGunUnit.make("DoorGun_%d_%d" % [index, serial], crew, crew_faction(crew),
		index, tile, h.square, label)
	var occupant: Node = GridManager.get_tile(tile).occupant
	if occupant != null:
		# `_clear_pad` moved everyone standing off the pad first; this is a
		# soldier it could not find a free tile for. The gunner still mounts —
		# the ship is down either way — and the tile is the gun's.
		push_warning("ExtractionManager: %s's tile %s was still held by %s" % [label, tile, occupant.name])
	parent.add_child(gun)
	gun.action_logged.connect(_on_door_gun_log)
	gun.died.connect(_on_door_gun_disabled)  # host-side signal; the line fans out via _log
	_door_guns[index] = gun
	if _is_authority() and not TurnManager.mission_over and not TurnManager.pool.has(gun):
		TurnManager.pool.append(gun)
	if crew == ExtractionRules.PLAYER_CREW or rules.is_discovered(index):
		notice.emit("%s is manned (%d HP) and covering the square." % [label, gun.current_hp], false)
	return gun


## Takes hangar `index`'s gunner off the board, live or disabled (DoorGunUnit.retire).
func _retire_door_gun(index: int) -> void:
	var gun := door_gun(index)
	_door_guns.erase(index)
	if gun != null:
		gun.retire()


func _retire_all_door_guns() -> void:
	for index in _door_guns.keys():
		_retire_door_gun(index)
	_door_guns.clear()


## Where units live: next to the squad (main.gd adds every unit straight under
## the mission scene), so the gunner's node path is the same shape as every other
## unit's on every peer. Falls back for a test tree that has no squad.
func _unit_parent() -> Node:
	var any := get_tree().get_first_node_in_group("player_units")
	if any != null and any.get_parent() != null:
		return any.get_parent()
	if get_tree().current_scene != null:
		return get_tree().current_scene
	return get_tree().root


## The gunner's narration goes out through TurnManager's log, which already fans
## out to co-op clients: only the host's copy ever fires, and a gunner has no
## main.gd sponsor wiring its `action_logged` the way spawned squads do.
func _on_door_gun_log(text: String) -> void:
	TurnManager._log(text)


func _on_door_gun_disabled(unit: Unit) -> void:
	var index := (unit as DoorGunUnit).hangar_index
	if (unit as DoorGunUnit).crew_id == ExtractionRules.PLAYER_CREW or rules.is_discovered(index):
		TurnManager._log("%s is DISABLED — it stays silent until the ship lifts off." % unit.stats.display_name)
	hangar_changed.emit(index)


func _unwatch_all() -> void:
	for unit in _watched:
		if is_instance_valid(unit) and unit.stepped.is_connected(_on_unit_stepped):
			unit.stepped.disconnect(_on_unit_stepped)
	_watched.clear()
	for unit in _watched_mercs:
		if is_instance_valid(unit) and unit.stepped.is_connected(_on_merc_stepped):
			unit.stepped.disconnect(_on_merc_stepped)
	_watched_mercs.clear()


func _show_square_highlight(index: int) -> void:
	var highlights := get_tree().get_first_node_in_group("highlights")
	if highlights and highlights.has_method("show_extraction_square"):
		highlights.show_extraction_square(index, hangar(index).square)


func _clear_square_highlight(index: int) -> void:
	var highlights := get_tree().get_first_node_in_group("highlights")
	if highlights and highlights.has_method("clear_extraction_square"):
		highlights.clear_extraction_square(index)


# --- Insertion (GDD §7.1 step 2) -------------------------------------------------------


## The insertion cinematic, before round 1 and outside the pool, so no round
## passes: the ship descends onto the insertion pad with the squad already placed
## on the square but hidden, the ramp drops, the squad appears, and the ship
## leaves. Purely local and cosmetic — each co-op peer plays its own copy before
## reporting ready — and main.gd skips it under `--auto`. Instant headless.
func play_insertion(units: Array) -> void:
	if not _active or data == null:
		return
	var h := data.insertion_hangar()
	if h == null:
		return
	var ship := spawn_dropship(h)
	if ship == null:
		return
	for unit in units:
		if is_instance_valid(unit):
			unit.visible = false
	await ship.descend()
	await ship.lower_ramp()
	for unit in units:
		if is_instance_valid(unit):
			unit.visible = true
	if DisplayServer.get_name() != "headless":
		await get_tree().create_timer(INSERTION_DISEMBARK_PAUSE).timeout
	await ship.take_off()
	if is_instance_valid(ship):
		ship.queue_free()
