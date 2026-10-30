extends Node3D
## Root scene script: spawns squads onto the test map, wires signals, starts
## the mission.
##
## Since the campaign (extraction plan 4.2) this is the MISSION step of the loop
## Title -> Hub -> mission -> Debrief -> Hub. It is entered with
## `Campaign.deployment` already set — the squad's SoldierRecords, the contract
## offer, the deck, the spawn seed — by the hub (or, on a co-op client, by the
## host's `Campaign._rpc_deployment`), and it leaves through the HUD's Continue
## to the front end's Debrief. The squad comes from those records rather than a
## hardcoded list; the deck and the objective come from the contract.
##
## Run on its own (the editor's Play Scene, tools/screenshot.gd) it makes a
## throwaway campaign and deploys its first soldiers, so a bare main.tscn still
## plays a mission.

const PLAYER_SCENE := preload("res://scenes/player_unit.tscn")
const ENEMY_SCENE := preload("res://scenes/enemy_unit.tscn")
const SWARM_SCENE := preload("res://scenes/swarm_unit.tscn")
const BRAWLER_SCENE := preload("res://scenes/brawler_unit.tscn")
const MERC_SCENE := preload("res://scenes/merc_unit.tscn")
const HUNTER_SCENE := preload("res://scenes/agile_hunter_unit.tscn")
const WORM_SCENE := preload("res://scenes/worm_unit.tscn")
const NEST_SCENE := preload("res://scenes/nest_unit.tscn")

## Fixed ratio for Phase 1 of the rival-mercs plan (see
## docs/design/factions/rival-mercs/README.md Sec 2) — a placeholder roll until
## squad composition is decided by the objective/spawn system rather than by the
## test spawner.
const MERC_VETERAN_CHANCE := 0.25

@onready var map: Node3D = $TestMap
@onready var camera_rig: Node3D = $CameraRig
@onready var hud: CanvasLayer = $HUD

## How many soldiers a deployment with no hub in front of it takes (`--auto`, a
## bare main.tscn): three, the size of the hardcoded squad this replaced, so a
## smoke run's fight is the size it always was.
const AUTO_SQUAD_SIZE := 3

## `--auto-campaign=N`: the smoke run chained through the debrief N times on one
## throwaway campaign, so the economy (payouts, sales, losses, hiring, game over)
## gets exercised end to end. Saved to its OWN file — never the player's slot —
## because the chain has to survive the scene reload between missions and that is
## also the save path worth exercising; the file is deleted when the chain ends.
const AUTO_CAMPAIGN_SAVE := "user://auto_campaign_test.json"
## The harness hub's spending floor: it keeps this much back for a recruit when
## buying medkits and grenades.
const AUTO_CREDIT_RESERVE := 300

var _auto := false
var _auto_campaign := 0

## Host-side: set once the host's own loadout screen is done. The mission
## starts only once this AND every connected client's `_rpc_client_ready` are
## in — see `_try_start_mission`.
var _host_deployed := false
var _mission_started := false
## Every soldier this mission spawned — what the debrief books.
var _player_units: Array[PlayerUnit] = []


func _ready() -> void:
	TurnManager.log_message.connect(_print_line)
	ExtractionManager.notice.connect(_on_notice)
	TurnManager.mission_ended.connect(_on_mission_ended)
	hud.continue_pressed.connect(_on_continue)
	_auto_campaign = _cmdline_int("--auto-campaign=")
	_auto = "--auto" in OS.get_cmdline_user_args() or _auto_campaign > 0
	if _auto:
		TurnManager.unit_activated.connect(_auto_play)
		TurnManager.mode_changed.connect(_on_auto_mode_changed)
		_prepare_auto_deployment()
		_sync_deck()
		seed(int(Campaign.deployment.get("spawn_seed", randi())))
		_spawn_and_start()
		return

	# No deployment means nothing went through the hub: main.tscn launched on its
	# own. Play a throwaway squad rather than refuse to start.
	if Campaign.deployment.is_empty():
		if Campaign.state == null:
			Campaign.use_throwaway()
		Campaign.adhoc_deployment(AUTO_SQUAD_SIZE)
	_sync_deck()

	if SteamLobby.is_networked():
		print("[NET] proceeding to spawn: is_host=%s local_id=%d peers=%s" % [
			SteamLobby.is_host(), multiplayer.get_unique_id(), multiplayer.get_peers()])
		multiplayer.server_disconnected.connect(_on_host_left)
		multiplayer.peer_disconnected.connect(_on_squadmate_left)
		# Who has built THIS mission's board is a per-mission fact: last
		# mission's ready list would let the host start (and stream units at) a
		# client that is still in its debrief.
		if SteamLobby.is_host():
			SteamLobby.ready_peers.clear()
	# Spawning rolls stats off the global RNG (the alien/merc presets, the
	# veteran roll below, a contract with no offer), and every co-op peer spawns
	# its own copy of the board — so every peer seeds it with the deployment's
	# shared seed first. The squad itself no longer rolls anything: it is built
	# from the records the deployment carries.
	seed(int(Campaign.deployment.get("spawn_seed", randi())))
	Campaign.deployment_fresh = false
	_spawn_and_start()


## Makes sure the map is the deployment's deck. TestMap builds it itself when the
## deployment existed before the scene loaded (the normal path); a deployment made
## in `_ready` above (auto, a bare main.tscn) arrives after TestMap built its own
## choice, so it is rebuilt here — `MapBuilder.build` clears what it replaces.
func _sync_deck() -> void:
	var deck: Dictionary = Campaign.deployment.get("deck", {})
	if not deck.is_empty() and deck != map.built_deck:
		map.build_deck(deck)


func _print_line(text: String) -> void:
	print(text)


func _on_notice(text: String, _radio: bool) -> void:
	print(text)


static func _cmdline_int(prefix: String) -> int:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(prefix):
			return int(arg.trim_prefix(prefix))
	return 0


static func _names(units: Array[Unit]) -> String:
	var out := PackedStringArray()
	for unit in units:
		out.append(unit.stats.display_name)
	return ", ".join(out) if not out.is_empty() else "nobody"


## The mission is over on this peer. The host (or solo) books it into the
## campaign NOW, before anyone clicks anything — ironman: the result is in the
## save the moment it exists — and sends the client its summary
## (Campaign.book_result). The HUD's Continue then goes to the Debrief.
func _on_mission_ended(result: MissionResult) -> void:
	var summary := {}
	if not SteamLobby.is_networked() or SteamLobby.is_host():
		summary = Campaign.book_result(result, _player_units)
	if not _auto:
		return
	# The smoke run's verdict line: who made it out and who did not.
	print("AUTO RESULT: %s after %d rounds | extracted: %s | lost: %s" % [
		result.describe(), TurnManager.turn_number,
		_names(result.extracted_units), _names(result.lost_units)])
	# Extraction plan 3.3: the contract and what came out with the squad.
	var title := Contract.from_dict(result.contract).title() if not result.contract.is_empty() else "none"
	var codes := result.loot_codes()
	var credits := 0
	for code in codes:
		credits += ItemPresets.value_of(code)
	print("AUTO OBJECTIVE: %s | complete: %s | loot: %d item(s), %d cr %s" % [
		title, result.objective_complete, codes.size(), credits, codes])
	# Extraction plan Phase 8: rival crews on the deck, and what became of them.
	for crew in ExtractionManager.merc_crews():
		var job := ExtractionManager.merc_job(crew)
		print("AUTO RIVAL: crew %d (%s) | %s | %d container(s) looted" % [
			crew, job.squad_id, job.describe(), job.looted.size()])
	for line in result.rival_lines():
		print("AUTO RIVAL: %s" % line)
	# Extraction plan 4.2: what the campaign made of it.
	if not summary.is_empty():
		var fates := PackedStringArray()
		for s: Dictionary in summary["soldiers"]:
			fates.append("%s=%s" % [s["name"], s["fate"]])
		print("AUTO DEBRIEF: mission %d | %s | sold %d cr, payout %d cr | credits %d -> %d | roster %d | grenades %d, medkits %d%s" % [
			summary["mission"], ", ".join(fates), summary["sale_total"], summary["payout"],
			summary["credits_before"], summary["credits_after"], Campaign.state.roster.size(),
			Campaign.state.grenades, Campaign.state.medical,
			" | GAME OVER" if summary["game_over"] else ""])
		# Phase 6: gear carried out lands in the stash (attachments, unlocks, grenades).
		if not (summary.get("gear", []) as Array).is_empty():
			print("AUTO GEAR: %s" % "; ".join(PackedStringArray(summary["gear"])))
	_auto_continue.call_deferred(summary)


## After an auto mission: the next one of an `--auto-campaign` chain (through the
## harness hub and a scene reload, as a player would go), or quit.
func _auto_continue(summary: Dictionary) -> void:
	var state: CampaignState = Campaign.state
	if _auto_campaign > 0 and state != null and not summary.get("game_over", false) \
			and state.missions_played < _auto_campaign:
		if _auto_hub_step():
			get_tree().change_scene_to_file(Campaign.MISSION_SCENE)
			return
	if _auto_campaign > 0:
		print("AUTO CAMPAIGN: %d mission(s) played%s" % [
			state.missions_played if state != null else 0,
			" — campaign over" if summary.get("game_over", false) else ""])
		Campaign.wipe()  # the chain's own temp file, never the player's slot
	get_tree().quit()


## The deployment an auto run plays. Plain `--auto`: a throwaway campaign with no
## file, its first AUTO_SQUAD_SIZE soldiers, and no contract offer — main.gd picks
## one for whatever deck the command line built, exactly as before the campaign.
## `--auto-campaign`: a throwaway saved to AUTO_CAMPAIGN_SAVE, deployed through
## the harness hub on its first contract.
func _prepare_auto_deployment() -> void:
	if not Campaign.deployment.is_empty():
		return  # the previous auto-campaign mission already launched this one
	if _auto_campaign > 0:
		Campaign.use_throwaway(AUTO_CAMPAIGN_SAVE)
		_auto_hub_step()
		return
	Campaign.use_throwaway()
	Campaign.adhoc_deployment(AUTO_SQUAD_SIZE)


## The harness's stand-in for a player in the hub: treat injuries (buying medkits
## above the reserve), hire up to a full squad while it can, restock a grenade per
## soldier above the reserve, then launch the first contract with the healthiest
## soldiers. False if it could not launch.
func _auto_hub_step() -> bool:
	var s: CampaignState = Campaign.state
	for r in s.roster:
		for part in r.injuries.duplicate():
			if s.medical < CampaignEconomy.MEDICAL_PER_INJURY \
					and s.credits >= CampaignEconomy.MEDICAL_PRICE + AUTO_CREDIT_RESERVE:
				Campaign.buy_medical()
			Campaign.treat(r.id, part)
	while s.roster.size() < CampaignEconomy.MAX_SQUAD:
		var cheapest := -1
		for i in s.recruits.size():
			if int(s.recruits[i]["price"]) <= s.credits and (cheapest < 0 \
					or int(s.recruits[i]["price"]) < int(s.recruits[cheapest]["price"])):
				cheapest = i
		if cheapest < 0 or Campaign.hire(cheapest) != "":
			break
	while s.grenades < CampaignEconomy.MAX_SQUAD \
			and s.credits >= CampaignEconomy.GRENADE_PRICE + AUTO_CREDIT_RESERVE:
		Campaign.buy_grenade()
	var squad := s.roster.duplicate()
	squad.sort_custom(func(a: SoldierRecord, b: SoldierRecord) -> bool:
		return a.injuries.size() < b.injuries.size())
	var ids: Array = []
	for r: SoldierRecord in squad:
		if ids.size() < CampaignEconomy.MAX_SQUAD:
			ids.append(r.id)
	var offer_text: String = s.contracts[0].describe() if not s.contracts.is_empty() else "no contract"
	var err := Campaign.launch(ids, 0)
	print("AUTO HUB: mission %d | %s | roster %d, credits %d, grenades %d, medkits %d, stash %s | %s" % [
		s.missions_played + 1, offer_text, s.roster.size(), s.credits, s.grenades, s.medical,
		s.attachments, "launched %d" % ids.size() if err == "" else "cannot launch: " + err])
	return err == ""


## HUD Continue: on to the Debrief (the front end shows it, then the hub — or, on
## a co-op client, the host's summary and then the wait for the next deployment).
func _on_continue() -> void:
	get_tree().change_scene_to_file(Campaign.FRONT_END_SCENE)



## Everything that used to be unconditional in `_ready` — spawning is
## deterministic (the deployment's records, fixed map spawn points, alien and
## merc rolls off the deployment's shared `spawn_seed`) so every peer builds an
## identical node tree independently rather than one peer spawning and
## replicating nodes to the other. See the co-op plan's Sec 3.
##
## Every unit is NAMED here, before add_child, and that is load-bearing: RPCs
## and MultiplayerSynchronizers address a unit by node path. Left unnamed, the
## second PlayerUnit collides with the first and Godot renames it
## `@PlayerUnit@<n>` off a process-wide counter — which the client, having
## built its map twice, has advanced further than the host has.
func _spawn_and_start() -> void:
	# The squad (extraction plan 4.2): the deployment's SoldierRecords, in the
	# order the hub listed them, each with its grenade allotment.
	var records: Array = Campaign.deployment.get("records", [])
	var grenade_counts: Array = Campaign.deployment.get("grenades", [])
	# Which peer owns which merc. Computed identically on every peer — sorted
	# by peer id rather than "whoever's local" — so a block split lands on the
	# same mercs everywhere despite each peer building this tree independently.
	# Solo play never networks, so every unit stays owner 0 and
	# `is_owned_by_local_player()` is unconditionally true (see Unit).
	var owning_peers: Array[int] = [0]
	if SteamLobby.is_networked():
		owning_peers = [multiplayer.get_unique_id()]
		owning_peers.append_array(Array(multiplayer.get_peers()))
		owning_peers.sort()
	var mercs_per_peer := maxi(1, ceili(float(records.size()) / owning_peers.size()))
	print("[NET] owning_peers=%s mercs_per_peer=%d" % [owning_peers, mercs_per_peer])

	# The mission's contract (extraction plans 3.3, 4.2). Extraction decks only: a
	# legacy clear-out deck's objective is the clear-out itself, and planting a
	# nest on one would change every test and smoke run built on it.
	#   - A campaign deployment's contract offer places itself with its own seeded
	#     RNG (ContractOffer.build_contract) — the same placement on every peer.
	#   - With no offer (`--auto`, a bare main.tscn) one is picked at random among
	#     the types the deck supports, off the global RNG every peer has seeded
	#     identically, and priced for the deck's size.
	# Either way it is settled FIRST, so a Destroy contract can add its nest to
	# the spawn list below before anything is spawned.
	var deck_hangars: Array = map.data.hangars if map.data != null else []
	var contract: Contract = null
	if not deck_hangars.is_empty():
		var offer := Campaign.deployed_offer()
		if offer != null:
			contract = offer.build_contract(map.data)
		else:
			contract = Contract.choose(map.data)
			if contract != null:
				var deck: Dictionary = Campaign.deployment.get("deck", {})
				contract.payout = CampaignEconomy.payout_for(contract.type,
					int(deck.get("size", CampaignEconomy.DeckSize.MEDIUM)))
	var nest_spawns: Array[Vector3i] = map.nest_spawns.duplicate()
	if contract != null and contract.place_nest:
		nest_spawns.append(contract.target_tile)

	var player_units: Array[PlayerUnit] = []
	var spawn_index := 0
	for i in records.size():
		if spawn_index >= map.player_spawns.size():
			# More soldiers than the deck has spawn tiles (a hand-authored deck):
			# the rest stay aboard. The debrief books them as benched, untouched.
			print("Deck has %d spawn tiles; %d soldier(s) stay aboard" % [
				map.player_spawns.size(), records.size() - spawn_index])
			break
		var record := SoldierRecord.from_dict(records[i])
		var unit: PlayerUnit = PLAYER_SCENE.instantiate()
		unit.stats = record.to_stats()
		unit.record_id = record.id
		# Grenades are stocked gear (CampaignEconomy): the hub allotted these out
		# of the stash, and what is not thrown goes back at the debrief.
		var grenades: int = int(grenade_counts[i]) if i < grenade_counts.size() else 0
		unit.deployed_grenades = grenades
		unit.grenade_charges = grenades
		# Untreated injuries ride in (GDD §4.2.1) — on every peer, from the same
		# record, so a client's movement preview prices the same bad leg.
		unit.apply_injuries(record.injuries)
		var peer_slot := mini(spawn_index / mercs_per_peer, owning_peers.size() - 1)
		unit.owner_peer_id = owning_peers[peer_slot]
		print("[NET] spawning %s -> owner_peer_id=%d" % [record.display_name, unit.owner_peer_id])
		unit.name = "Player_%d" % spawn_index
		unit.position = GridManager.grid_to_world(map.player_spawns[spawn_index])
		add_child(unit)  # Unit._ready snaps to grid + registers occupancy
		unit.action_logged.connect(_on_unit_log)
		player_units.append(unit)
		spawn_index += 1
	_player_units = player_units

	var enemy_index := 1
	for spawn in map.enemy_spawns:
		var enemy: EnemyUnit = ENEMY_SCENE.instantiate()
		enemy.stats = AlienPresets.ranged("Alien_%d" % enemy_index)
		enemy.name = "Alien_%d" % enemy_index
		enemy.position = GridManager.grid_to_world(spawn)
		add_child(enemy)
		enemy.action_logged.connect(_on_unit_log)
		enemy_index += 1

	var swarm_index := 1
	for spawn in map.swarm_spawns:
		var swarm: SwarmUnit = SWARM_SCENE.instantiate()
		swarm.stats = AlienPresets.swarm("Swarm_%d" % swarm_index)
		swarm.name = "Swarm_%d" % swarm_index
		swarm.position = GridManager.grid_to_world(spawn)
		add_child(swarm)
		swarm.action_logged.connect(_on_unit_log)
		swarm_index += 1

	var brawler_index := 1
	for spawn in map.brawler_spawns:
		var brawler: BrawlerUnit = BRAWLER_SCENE.instantiate()
		brawler.stats = AlienPresets.brawler("Brawler_%d" % brawler_index)
		brawler.name = "Brawler_%d" % brawler_index
		brawler.position = GridManager.grid_to_world(spawn)
		add_child(brawler)
		brawler.action_logged.connect(_on_unit_log)
		brawler_index += 1

	var hunter_index := 1
	for spawn in map.hunter_spawns:
		var hunter: AgileHunterUnit = HUNTER_SCENE.instantiate()
		hunter.stats = AlienPresets.hunter("Hunter_%d" % hunter_index)
		hunter.name = "Hunter_%d" % hunter_index
		hunter.position = GridManager.grid_to_world(spawn)
		add_child(hunter)
		hunter.action_logged.connect(_on_unit_log)
		hunter_index += 1

	# Worms, and the masses a map may place pre-formed. A mass is not a second
	# scene — it is this same unit carrying more HP — so the map's `[worms]`
	# count is applied by writing HP and letting `WormUnit` derive the rest:
	# damage, pace, sprite and label all follow from `current_hp` alone.
	#
	# AFTER `add_child`, and that ordering is the whole of it: `Unit._ready`
	# sets `current_hp` from the stat block, so a count written before the node
	# enters the tree is overwritten by the single worm's 5 HP.
	var worm_index := 1
	for spawn in map.worm_spawns:
		var worm: WormUnit = WORM_SCENE.instantiate()
		worm.stats = AlienPresets.worm("Worm_%d" % worm_index)
		worm.name = "Worm_%d" % worm_index
		worm.position = GridManager.grid_to_world(spawn)
		add_child(worm)
		worm.action_logged.connect(_on_unit_log)
		var worms: int = maxi(1, map.worm_counts.get(spawn, 1))
		if worms > 1:
			worm.current_hp = mini(worms, WormUnit.MAX_WORMS) * WormUnit.HP_PER_WORM
			worm._apply_count()
		worm_index += 1

	# Nests (Sec 11.7). Placed exactly like a unit and drawn from the same pool,
	# but they are the mission objective rather than a threat — see NestUnit for
	# why an objective is a Unit here, and for what is still missing from it.
	var nest_index := 1
	for spawn in nest_spawns:
		var nest: NestUnit = NEST_SCENE.instantiate()
		nest.stats = AlienPresets.nest("Nest_%d" % nest_index)
		nest.name = "Nest_%d" % nest_index
		nest.position = GridManager.grid_to_world(spawn)
		add_child(nest)
		nest.action_logged.connect(_on_unit_log)
		nest_index += 1

	# Recover (extraction plan Phase 6): the VIP, lying DOWNED where the contract
	# placed them. On every peer, like the nests — name, tile and stats are all
	# fixed by the contract, nothing rolls — so both copies sit at the same path and
	# the host's state streams onto the client's. ObjectiveManager finds it by tile.
	if contract != null and contract.type == Contract.Type.RECOVER:
		var vip := VipUnit.make(contract.target_tile, contract.vip_name)
		add_child(vip)

	var merc_index := 1
	# One LMG per squad, handed to whichever member is placed first in a room.
	# The coordinator has to pick a suppressor every engagement, and a squad where
	# that choice is arbitrary reads as arbitrary — this gives it an answer.
	var squads_seen := {}
	for spawn in map.merc_spawns:
		var merc: MercUnit = MERC_SCENE.instantiate()
		# Explicitly typed: `map` is a bare Node3D here, so its return type is
		# unknown at compile time and `:=` has nothing to infer from.
		var room: int = map.room_at(spawn)
		var name := "Merc_%d" % merc_index
		# Stat-only veteran tier (docs/design/factions/rival-mercs/README.md
		# Sec 2): a flat chance per merc, independent of the support/rifleman
		# split above — a squad's designated gunner earning the better body is as
		# plausible as a rifleman earning it.
		var veteran := randf() < MERC_VETERAN_CHANCE
		merc.stats = MercPresets.support(name, veteran) if not squads_seen.has(room) \
			else MercPresets.rifleman(name, veteran)
		squads_seen[room] = true
		# Squad BY COMPARTMENT, the same way a robot takes its security zone from
		# the deck. Two merc teams in two rooms get two independent blackboards
		# without the map needing a second glyph or the spawner a second list —
		# and it means a level author draws squads by drawing walls.
		merc.squad_id = "mercs_room_%d" % room
		# A few valuables in their pockets, lootable off the corpse (plan 3.2).
		# Before add_child, so Unit._ready syncs the replicated codes from it.
		merc.inventory = MercPresets.roll_inventory()
		merc.name = "Merc_%d" % merc_index
		merc.position = GridManager.grid_to_world(spawn)
		add_child(merc)
		merc.action_logged.connect(_on_unit_log)
		merc_index += 1

	# Iterates whatever the deck placed, so a map with no robot glyphs — the test
	# deck, currently, so the alien tier can be judged on its own — spawns none
	# without this needing to know that.
	_spawn_security_robots()

	# A deck with a hangar is an extraction deck (GDD §7): the mission ends when
	# the ship leaves with someone aboard, or on a wipe — never by "every hostile
	# down", so `clear_out_mode` goes off. A deck without one (every legacy test
	# deck) has no way out but the old one and keeps it on. Set on every peer, but
	# only the host's copy is ever checked.
	TurnManager.clear_out_mode = deck_hangars.is_empty()
	# GDD §4.7: missions open out of combat. `--turn-mode` keeps the plain initiative
	# loop for the whole run, as the regression baseline (plan D.2, E12).
	TurnManager.exploration_enabled = not ("--turn-mode" in OS.get_cmdline_user_args())
	# Every peer, after the squad exists (discovery listens to their moves) and
	# before the mission starts. Inert on a deck with no hangar.
	ExtractionManager.begin_mission(map.data)
	# Every peer, after the nest exists: plants the Retrieve item in its crate or
	# finds the Destroy target. Deterministic, so nothing is sent (see
	# ObjectiveManager). A null contract clears the last mission's.
	ObjectiveManager.begin_mission(contract)
	if contract != null:
		var line := "Contract: %s (payout %d cr)" % [contract.title(), contract.payout]
		print(line)
		hud.append_log(line)  # local on every peer — each one chose the same contract

	if not map.player_spawns.is_empty():
		camera_rig.focus_on(GridManager.grid_to_world(map.player_spawns[0]))

	# Static fixtures are already baked in (TestMap._ready ran first); layer in
	# the squad's flashlights now that the units themselves exist.
	LightingManager.recompute_dynamic()

	if _auto:
		# Headless smoke test skips the loadout screen entirely — every unit
		# just deploys with its record's saved loadout (clamped to the stash).
		TurnManager.start_mission.call_deferred()
		return

	var loadout: LoadoutMenu = LoadoutMenu.new()
	# Fed from the campaign stash (extraction plan 4.2). In co-op each peer gets
	# the copies NOT fitted to the other player's soldiers, so the two loadout
	# screens can never hand out the same copy twice.
	loadout.from_stash = true
	loadout.inventory = Campaign.loadout_inventory(player_units.filter(
		func(u: PlayerUnit) -> bool: return not u.is_owned_by_local_player()))
	loadout.unlocked_ammo = Campaign.loadout_ammo()
	add_child(loadout)
	loadout.setup(player_units)
	_squad = player_units
	loadout.deployed.connect(_on_local_deployed)


## The squad as spawned, for the insertion cinematic to hide and reveal.
var _squad: Array[PlayerUnit] = []


## The ready handshake, the equivalent of a join handshake for a game that
## doesn't spawn over the network: the host may not start the turn loop — whose
## first RPCs name units by path — until every client has built those units.
## A client's Deploy is that signal: it only reaches its loadout screen after
## spawning, and deploying last means its weapon picks are already in.
##
## The insertion (GDD §7.1 step 2) plays first, on each peer locally: it is
## outside the pool, so no round passes, and a peer only reports ready once its
## own squad is off the ramp. `--auto` never gets here (it starts directly).
func _on_local_deployed() -> void:
	var insertion: MapData.Hangar = map.data.insertion_hangar() if map.data != null else null
	if ExtractionManager.is_active() and insertion != null:
		camera_rig.focus_on(GridManager.grid_to_world(insertion.pad_center))
		await ExtractionManager.play_insertion(_squad)
	if not SteamLobby.is_networked():
		_begin_mission()
	elif SteamLobby.is_host():
		_host_deployed = true
		_try_start_mission()
	else:
		hud.append_log("Waiting for the host to deploy...")
		_rpc_client_ready.rpc_id(1)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_client_ready() -> void:
	if not multiplayer.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	print("[NET] peer %d reports ready" % peer_id)
	if peer_id in SteamLobby.ready_peers:
		return
	SteamLobby.ready_peers.append(peer_id)
	for node in get_tree().get_nodes_in_group("units"):
		var unit := node as Unit
		if unit:
			unit.show_to_peer(peer_id)
	_try_start_mission()


func _try_start_mission() -> void:
	if _mission_started or not _host_deployed:
		return
	for peer_id in multiplayer.get_peers():
		if peer_id not in SteamLobby.ready_peers:
			hud.append_log("Waiting for your squadmate to deploy...")
			return
	_mission_started = true
	_begin_mission()


## Host/solo, once every loadout is in: records what each soldier really took (so
## a mission quit midway loses the copies actually fitted — ironman, see
## Campaign.note_loadouts) and starts the turn loop. A client's picks reach the
## host before its ready report (both reliable, in order), so they are counted.
func _begin_mission() -> void:
	Campaign.note_loadouts(_player_units)
	TurnManager.start_mission.call_deferred()


## The host is peer 1 and runs the whole simulation, so there is nothing to
## migrate to — same as any listen-server game, the mission ends with it.
func _on_host_left() -> void:
	TurnManager.abandon()
	var dialog := AcceptDialog.new()
	dialog.title = "Disconnected"
	dialog.dialog_text = "The host left the game, so this mission is over."
	dialog.ok_button_text = "Back to menu"
	add_child(dialog)
	dialog.confirmed.connect(_return_to_menu)
	dialog.canceled.connect(_return_to_menu)
	dialog.popup_centered()


## Back to the title: the client owns no campaign (A7), so nothing is booked —
## the host's debrief, if it ever happens, is the host's.
func _return_to_menu() -> void:
	SteamLobby.leave()
	Campaign.close()
	get_tree().change_scene_to_file(Campaign.FRONT_END_SCENE)


## Host-side: a squadmate dropping doesn't end the mission — their mercs are
## handed to the host, who can keep playing them. Also unblocks a host still
## waiting on that squadmate's Deploy.
func _on_squadmate_left(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	for node in get_tree().get_nodes_in_group("player_units"):
		var unit := node as Unit
		if unit and unit.owner_peer_id == peer_id:
			# Whatever they had that soldier doing out of combat stops with them
			# (plan C.7): nobody is left to re-order it, and its goal frees up.
			unit.cancel_walk()
			GridManager.release_reservation(unit)
			unit.owner_peer_id = multiplayer.get_unique_id()
			# Mid-activation for one of theirs: re-announce it, so the HUD
			# (which decided on activation that it wasn't ours to drive) picks
			# it up instead of the turn stalling on nobody.
			if unit == TurnManager.active_unit:
				TurnManager.unit_activated.emit(unit)
	hud.append_log("Your squadmate disconnected — their mercs are yours now.")
	_try_start_mission()


func _spawn_security_robots() -> void:
	# One pass over the roster rather than a block per type: the deck says which
	# models it wants and where, and CerberusPresets says what each one is.
	#
	# The zone assignment is the only thing that cannot come from either — it is a
	# property of the DECK's compartment graph, so the builder derives it (see
	# MapBuilder.zone_at). A robot spawned outside any room gets NO_ZONE and
	# simply broadcasts to nobody, which is the right answer rather than an error.
	for kind: int in MapData.CERBERUS_SPAWNS:
		var spawns: Array = map.cerberus_spawns.get(kind, [])
		var index := 1
		for spawn: Vector3i in spawns:
			var robot: CerberusUnit = CerberusPresets.scene_for(kind).instantiate()
			robot.stats = CerberusPresets.make_stats(kind, index if spawns.size() > 1 else 1)
			robot.security_zone = map.zone_at(spawn)
			robot.name = "Robot_%d_%d" % [kind, index]
			robot.position = GridManager.grid_to_world(spawn)
			add_child(robot)
			robot.action_logged.connect(_on_unit_log)
			index += 1


## Brains for auto-played soldiers, one per unit. Built lazily and kept, because
## a `GoapBrain` carries the unit's goal commitment and starvation counter — a
## fresh one each activation would reset exactly the state fixes C and F exist to
## accumulate.
var _auto_brains: Dictionary = {}
## The exploration loop is running (`_auto_explore`).
var _auto_exploring := false


## Headless smoke test (`godot -- --auto`): soldiers resolve a full skirmish
## without input.
##
## They run the RIVAL MERC DOCTRINE, which is not a shortcut — that doctrine is
## written as full parity with the player (same actions, same weapons, same cover
## rules), so it is the closest thing to a competent human the codebase contains.
## It also means a smoke run exercises the framework from both sides at once, and
## a doctrine bug that only shows up when the player side is the one planning has
## somewhere to surface.
##
## Real play is untouched: nothing below runs unless `--auto` is passed.
func _auto_play(unit: Unit) -> void:
	var player := unit as PlayerUnit
	if player == null:
		return
	await get_tree().process_frame
	var target := _nearest_hostile(player)
	# Loot is grabbed when it is cheap (plan 3.2 harness): anything in reach, with
	# nothing hostile in sight to spend the AP on instead.
	_auto_loot_in_reach(player)
	# Hold (Phase 6): the soldier at the console stays there until the count is
	# done — leaving pauses it — and fights from where it stands.
	if _auto_holding(player):
		await _auto_work_terminal(player)
		await _auto_shoot(player)
		if not TurnManager.mission_over:
			player.end_activation()
		return
	var extracting := _auto_wants_extraction(target)
	# While the hunt is on, the squad's fetcher spends quiet activations (nothing
	# hostile in sight) walking to the Retrieve item instead.
	var fetched := false
	var destroy_nest: Unit = null
	if not extracting and target != null and not _auto_hostile_in_sight(player):
		fetched = await _auto_fetch_objective(player)
		# Destroy: with nothing in sight, hunt the contract's nest rather than the
		# nearest hostile, so the objective gets done before the round cap.
		destroy_nest = _auto_destroy_target(player)
	if extracting:
		await _auto_extract(player)
	elif fetched:
		pass  # this activation went to the Retrieve item
	elif destroy_nest != null:
		# The planner's doctrine is built for things that shoot back and treats a
		# nest it cannot see as nothing to plan against; the greedy loop just walks
		# up to it and empties the magazine, which is what a nest calls for.
		await _greedy_fallback(player, destroy_nest)
	elif target != null:
		# A squadmate down within reach is revived before the fight resumes —
		# cheap, and it exercises revive in every run that has a casualty.
		await _auto_tend_downed(player, false)
		if not _auto_brains.has(player):
			_auto_brains[player] = Doctrines.merc_brain(Doctrines.blackboard_for("contractors"))
		var brain: GoapBrain = _auto_brains[player]
		SquadCoordinator.assign(brain.blackboard, _living_squad(), target)
		var before := player.ap
		await brain.run(player, target)
		# The planner declining to act must never end the run. A target it cannot
		# plan against — no ammo, no reachable angle — would otherwise leave the
		# soldier idling every turn while the enemy sits UNAWARE, which is the
		# stalemate this harness has already been fixed for once.
		if player.ap == before:
			await _greedy_fallback(player)
	if not TurnManager.mission_over:
		player.end_activation()


# --- `--auto` out of combat (exploration plan D.1) -----------------------------


func _on_auto_mode_changed(new_mode: int) -> void:
	if new_mode == TurnManager.Mode.EXPLORATION:
		_auto_explore()


## Turn mode drives `_auto_play` off each draw. Out of combat nothing is drawn, so
## the harness loops the squad itself, one think per soldier, until contact or the
## end. A pass in which nobody spent a step (all holding, all out of ideas) waits a
## round rather than spinning: the clock is what ends a stalemate on an extraction
## deck, exactly as the round count did in turn mode.
func _auto_explore() -> void:
	if _auto_exploring:
		return
	_auto_exploring = true
	while TurnManager.in_exploration() and not TurnManager.mission_over:
		await get_tree().process_frame
		var before := _auto_clock()
		for member: Variant in _living_squad():
			if not TurnManager.in_exploration() or TurnManager.mission_over:
				break
			await _auto_explore_think(member)
		if TurnManager.in_exploration() and not TurnManager.mission_over and _auto_clock() == before:
			await TurnManager.wait_round()
	_auto_exploring = false


## One soldier's think against a synthetic AP pool, so the same planner and the same
## helpers run in both modes. What the think spent goes on the clock at the end, less
## what its walking already charged tile by tile (Unit.auto_budget). A shot fired is
## an attack from exploration, the same as a human's (plan B.7).
func _auto_explore_think(player: PlayerUnit) -> void:
	if not is_instance_valid(player) or player.is_downed or player.aboard:
		return
	TurnManager.hold_switch += 1
	player.auto_budget = true
	var pool := player.ap_pool()
	player.ap = pool
	var clock := _auto_clock()
	var ammo := player.ammo
	await _auto_play(player)
	if is_instance_valid(player):
		player.auto_budget = false
	TurnManager.hold_switch -= 1
	if TurnManager.mission_over or not is_instance_valid(player):
		return
	if player.ammo < ammo:
		TurnManager.notify_attack(player, player.action_cost(UnitStats.Action.SHOOT))
	TurnManager.add_steps(maxi(0, (pool - player.ap) - (_auto_clock() - clock)))
	await TurnManager.settle_clock()


## Total steps walked so far this mission, across rounds.
func _auto_clock() -> int:
	return TurnManager.turn_number * TurnManager.STEPS_PER_ROUND + TurnManager.steps


## Round from which the auto squad stops hunting and heads for the ship however
## many hostiles are left. The hunt is what an auto run did before hangars
## existed and still exercises the AI; the cap is what guarantees an extraction
## deck terminates even when some hostile can never be cornered.
const AUTO_EXTRACT_ROUND := 20


## On an extraction deck (a hangar exists), the auto squad leaves when there is
## nothing left it can fight, when the round cap passes, or once a ship is
## already called — from then on everyone heads for it rather than splitting
## between the hunt and the square. On a legacy deck it never does: clear-out is
## the only ending there.
func _auto_wants_extraction(target: Unit) -> bool:
	if not ExtractionManager.is_active():
		return false
	return target == null or TurnManager.turn_number >= AUTO_EXTRACT_ROUND \
		or ExtractionManager.claim_of(ExtractionRules.PLAYER_CREW) >= 0 \
		or _auto_vip_in_hand()


## Recover (Phase 6): a soldier has the VIP over their shoulder — time to go home
## rather than hunt one-handed.
func _auto_vip_in_hand() -> bool:
	var vip := ObjectiveManager.vip()
	return vip != null and vip.life_state == Unit.LifeState.DOWNED and vip.carried_by is PlayerUnit


## Hold (Phase 6): `player` is the fetcher, beside a console whose count is not
## done, before the give-up round.
func _auto_holding(player: PlayerUnit) -> bool:
	var t := ObjectiveManager.terminal()
	var rules: TerminalRules = ObjectiveManager.terminal_rules
	return t != null and rules != null and not rules.is_complete() and player == _auto_fetcher() \
		and player.within_reach(t.tile) and TurnManager.turn_number < AUTO_FETCH_GIVE_UP_ROUND


## One auto-played soldier's extraction activation (GDD §7.1 steps 4–5): call the
## ship if standing in a callable bay, walk into the square, signal dust-off once
## every soldier still on their feet is in it, then shoot whatever is in sight
## with what AP is left. Downed soldiers can't be carried until extraction plan
## Phase 2, so anyone downed outside the square is left behind — which is the
## left-behind case of the result screen, exercised for free.
##
## Calls UnitStats/ExtractionManager directly rather than `try_call_ship`, the
## way `_greedy_fallback` calls `fire_at`: the `try_` commands end the
## activation when AP runs out, and this function still has steps to run.
func _auto_extract(player: PlayerUnit) -> void:
	# The squad's fetcher keeps after the Retrieve item until the ship is down —
	# then everyone, fetcher included, goes for the square.
	var fetched: bool = await _auto_fetch_objective(player)
	if fetched:
		await _auto_shoot(player)
		return
	var crew := ExtractionRules.PLAYER_CREW
	var index := ExtractionManager.claim_of(crew)
	if index < 0:
		index = _auto_pick_hangar(player)
	if index < 0:
		await _auto_shoot(player)  # nowhere to go yet (every pad cooling down)
		return
	_auto_try_call(player)
	var h := ExtractionManager.hangar(index)
	# Nobody left behind if it can be helped: revive or lift a body in reach, or
	# detour a few tiles to one, before heading for the ship (GDD §4.4).
	await _auto_tend_downed(player, true, h)
	if TurnManager.mission_over or player.is_downed:
		return
	if not h.in_square(player.grid_pos):
		await _auto_walk_to_square(player, h)
	if TurnManager.mission_over or player.is_downed:
		return
	_auto_try_call(player)
	# GDD §7.4: in the square of our landed ship. The last one in gives the word
	# (everyone else still standing is aboard or beside them); anyone earlier
	# boards — with any body they carry — and is safe until then.
	if ExtractionManager.board_hangar_for(player) >= 0:
		if _auto_squad_in_square(h) and ExtractionManager.extract(player):
			_on_unit_log("%s auto-extracted" % player.stats.display_name)
			return
		var board_cost := player.action_cost(UnitStats.Action.BOARD_SHIP)
		if player.ap >= board_cost:
			player.spend_ap(board_cost)
			if ExtractionManager.board(player):
				_on_unit_log("%s auto-boarded" % player.stats.display_name)
				return
	await _auto_shoot(player)


## Round after which the fetcher gives up on the Retrieve item and goes home with
## everyone else, so a contract it cannot reach never keeps a run from ending.
const AUTO_FETCH_GIVE_UP_ROUND := 28


## Whether anything hostile is within shooting distance and in sight.
func _auto_hostile_in_sight(player: PlayerUnit) -> bool:
	for enemy in player.hostiles():
		if GridManager.chebyshev_dist(player.grid_pos, enemy.grid_pos) <= 8 \
				and GridManager.has_line_of_sight(player, enemy):
			return true
	return false


## Takes whatever is in reach while it is cheap: nothing hostile in sight, AP to
## spare, a free slot. The objective item first, then the most valuable. Calls the
## Unit/LootManager operations directly (not `try_loot`, which ends the activation
## at 0 AP while this soldier still has a turn to play).
func _auto_loot_in_reach(player: PlayerUnit) -> void:
	var cost := player.action_cost(UnitStats.Action.LOOT)
	while player.ap >= cost and player.has_free_slot() and not _auto_hostile_in_sight(player):
		var best_source: Object = null
		var best_index := -1
		var best_score := -1
		for source in player.loot_sources():
			var items: Array = source.loot_items()
			for i in items.size():
				var item: ItemData = items[i]
				var score := 1000000 if item.is_objective() else item.value
				if score > best_score:
					best_score = score
					best_source = source
					best_index = i
		if best_source == null:
			return
		player.spend_ap(cost)
		var item: ItemData = LootManager.take(best_source, best_index)
		player.add_item(item)
		_on_unit_log("%s auto-looted %s from %s (pack %d/%d)" % [player.stats.display_name,
			item.display_name, best_source.loot_name(), player.inventory.size(), Unit.INVENTORY_SLOTS])


## What the Retrieve item is sitting in if a soldier has to go and get it — a
## crate, a pile, or an uncarried corpse — else null: no Retrieve contract, or the
## item is already on a living soldier (or a body somebody is carrying).
func _auto_objective_source() -> Object:
	var holder: Object = ObjectiveManager.item_holder()
	if holder is LootContainer:
		return holder
	var unit := holder as Unit
	if unit != null and unit.life_state == Unit.LifeState.DEAD and unit.carried_by == null:
		return unit
	return null


## The one soldier who goes for the objective: the first on their feet, by name,
## so the rest keep fighting and the squad does not all wander off together.
func _auto_fetcher() -> PlayerUnit:
	var best: PlayerUnit = null
	for node in get_tree().get_nodes_in_group("player_units"):
		var member := node as PlayerUnit
		if member == null or member.life_state != Unit.LifeState.ACTIVE:
			continue
		if best == null or String(member.name) < String(best.name):
			best = member
	return best


## Whether the fetcher is still working the objective, before the give-up round:
## going for a Retrieve item it can reach, holding (or going to hold) the Hold
## console until its count finishes, or going for the Recover VIP (Phase 6).
## While it is, nobody calls the ship.
func _auto_fetch_pending() -> bool:
	var fetcher := _auto_fetcher()
	if fetcher == null or TurnManager.turn_number >= AUTO_FETCH_GIVE_UP_ROUND:
		return false
	var tile := NO_AUTO_TILE
	var c: Contract = ObjectiveManager.contract
	if c != null and c.type == Contract.Type.HOLD:
		var t := ObjectiveManager.terminal()
		if t != null and not ObjectiveManager.terminal_rules.is_complete():
			tile = t.tile
	elif c != null and c.type == Contract.Type.RECOVER:
		var vip := ObjectiveManager.vip()
		if vip != null and vip.life_state == Unit.LifeState.DOWNED and vip.carried_by == null:
			tile = vip.grid_pos
	else:
		var source := _auto_objective_source()
		if source != null:
			tile = source.loot_tile()
	if tile == NO_AUTO_TILE:
		return false
	return fetcher.within_reach(tile) or not GridManager.find_path(fetcher.grid_pos, tile, 999, true).is_empty()


const NO_AUTO_TILE := Vector3i(-99999, -99999, -99999)


## The objective's share of the fetcher's activation, by contract type. True if it
## acted (and the rest of the activation should stay put / shoot from where it is).
func _auto_fetch_objective(player: PlayerUnit) -> bool:
	var c: Contract = ObjectiveManager.contract
	if c != null and c.type == Contract.Type.HOLD:
		return await _auto_work_terminal(player)
	if c != null and c.type == Contract.Type.RECOVER:
		return await _auto_fetch_vip(player)
	return await _auto_fetch_item(player)


## The Hold fetcher (Phase 6): walk to the console, operate it, and stand there —
## an activation spent beside a running console is spent holding it (the caller
## shoots from where it stands). Restarts it if it was left and paused.
func _auto_work_terminal(player: PlayerUnit) -> bool:
	var t := ObjectiveManager.terminal()
	var rules: TerminalRules = ObjectiveManager.terminal_rules
	if t == null or rules == null or rules.is_complete() or player != _auto_fetcher() \
			or TurnManager.turn_number >= AUTO_FETCH_GIVE_UP_ROUND:
		return false
	var cost := player.action_cost(UnitStats.Action.OPERATE_TERMINAL)
	if not player.within_reach(t.tile):
		if not await _auto_walk_toward(player, t.tile, 0 if rules.is_running() else cost, "the terminal"):
			return false
		if player.is_downed or TurnManager.mission_over or not player.within_reach(t.tile):
			return true
	if not rules.is_running() and player.ap >= cost:
		player.spend_ap(cost)
		if ObjectiveManager.operate_terminal(player):
			_on_unit_log("%s auto-operated the terminal" % player.stats.display_name)
	return true


## The Recover fetcher (Phase 6): walk to the VIP, keeping the pick-up's AP back,
## and lift them. From then on the carrier is part of the extraction (see
## `_auto_wants_extraction`).
func _auto_fetch_vip(player: PlayerUnit) -> bool:
	var vip := ObjectiveManager.vip()
	if vip == null or vip.life_state != Unit.LifeState.DOWNED or vip.carried_by != null \
			or player != _auto_fetcher() or player.carrying != null \
			or TurnManager.turn_number >= AUTO_FETCH_GIVE_UP_ROUND:
		return false
	var cost := player.action_cost(UnitStats.Action.PICK_UP)
	if not player.within_reach(vip.grid_pos):
		if not await _auto_walk_toward(player, vip.grid_pos, cost, "the VIP"):
			return false
		if player.is_downed or TurnManager.mission_over or not player.within_reach(vip.grid_pos):
			return true
	if player.ap >= cost and player.pick_up_blocker(vip) == "":
		player.spend_ap(cost)
		player.pick_up(vip)
		_on_unit_log("%s auto-lifted the VIP %s" % [player.stats.display_name, vip.stats.display_name])
	return true


## Walks toward `tile` (a body, a console, a crate — it may be unstandable) with
## this activation's AP less `keep_ap`. True if it moved.
func _auto_walk_toward(player: PlayerUnit, tile: Vector3i, keep_ap: int, what: String) -> bool:
	var path := GridManager.find_path(player.grid_pos, tile, 999, true)
	if path.is_empty():
		return false
	if not GridManager.is_free(path[-1]):
		path.resize(path.size() - 1)
	var steps := mini(path.size(), (player.ap - keep_ap) / player.move_ap_per_tile())
	if steps < 1:
		return false
	var walk := path.slice(0, steps)
	player.spend_ap(player.move_cost_for(walk.size()))
	await player.move_along(walk)
	_on_unit_log("%s auto-moved to %s heading for %s" % [player.stats.display_name, walk[-1], what])
	return true


## The Destroy contract's nest, if it is alive and this soldier could walk to it.
func _auto_destroy_target(player: PlayerUnit) -> Unit:
	var c: Contract = ObjectiveManager.contract
	if c == null or c.type != Contract.Type.DESTROY or ObjectiveManager.nest_destroyed():
		return null
	var nest := ObjectiveManager.target_nest()
	if nest == null or not is_instance_valid(nest) or not _can_act_on(player, nest):
		return null
	return nest


## The fetcher's activation spent on the Retrieve item: loot it if in reach (first
## dropping the least valuable thing in a full pack — dropping is free), else
## walk toward it, keeping the loot's AP back, and loot on arrival. True if it
## acted. Stops once the ship is down or the give-up round passes.
func _auto_fetch_item(player: PlayerUnit) -> bool:
	var source := _auto_objective_source()
	if source == null or player != _auto_fetcher() or TurnManager.turn_number >= AUTO_FETCH_GIVE_UP_ROUND:
		return false
	var claim := ExtractionManager.claim_of(ExtractionRules.PLAYER_CREW)
	if claim >= 0 and ExtractionManager.rules.state_of(claim) == ExtractionRules.State.LANDED:
		return false
	var cost := player.action_cost(UnitStats.Action.LOOT)
	var tile: Vector3i = source.loot_tile()
	if not player.within_reach(tile):
		var path := GridManager.find_path(player.grid_pos, tile, 999, true)
		if path.is_empty():
			return false
		if not GridManager.is_free(path[-1]):
			path.resize(path.size() - 1)
		var steps := mini(path.size(), (player.ap - cost) / player.move_ap_per_tile())
		if steps < 1:
			return false  # no AP to close the distance this activation
		var walk := path.slice(0, steps)
		player.spend_ap(player.move_cost_for(walk.size()))
		await player.move_along(walk)
		_on_unit_log("%s auto-moved to %s to fetch the objective" % [player.stats.display_name, walk[-1]])
		if player.is_downed or TurnManager.mission_over or not player.within_reach(tile):
			return true
	if player.ap < cost:
		return true
	if not player.has_free_slot():
		var cheapest := 0
		for i in player.inventory.size():
			if player.inventory[i].value < player.inventory[cheapest].value:
				cheapest = i
		var dropped := player.remove_item(cheapest)
		LootManager.drop_to_pile(player.grid_pos, dropped)
		_on_unit_log("%s auto-dropped %s to make room" % [player.stats.display_name, dropped.display_name])
	var items: Array = source.loot_items()
	for i in items.size():
		if (items[i] as ItemData).is_objective():
			player.spend_ap(cost)
			var item: ItemData = LootManager.take(source, i)
			player.add_item(item)
			_on_unit_log("%s auto-took the objective: %s" % [player.stats.display_name, item.display_name])
			break
	return true


## How far (in path tiles) an extracting auto soldier will detour to reach a
## downed or dead squadmate. Far enough to go back for someone in the same
## firefight, short enough that the run still gets to the ship.
const AUTO_RESCUE_RANGE := 8


## The auto squad's half of GDD §4.4, kept deliberately simple: revive a downed
## squadmate in reach if the AP is there; otherwise, when `go_get` (the extraction
## branch), lift a body in reach — downed before dead — or walk toward the nearest
## one within AUTO_RESCUE_RANGE and lift it on arrival. Bodies already lying in
## `h`'s square are left where they are: they extract anyway. Calls the Unit-level
## operations directly rather than the `try_` commands, which end the activation
## at 0 AP while this branch still has steps to run (see `_auto_extract`).
func _auto_tend_downed(player: PlayerUnit, go_get: bool, h: MapData.Hangar = null) -> void:
	if player.carrying != null or player.is_downed or TurnManager.mission_over:
		return
	var revive_cost := player.action_cost(UnitStats.Action.REVIVE)
	var lift_cost := player.action_cost(UnitStats.Action.PICK_UP)
	var revivable := player.body_targets(PlayerUnit.Mode.REVIVE)
	if not revivable.is_empty() and player.ap >= revive_cost:
		var body: Unit = revivable[0]
		player.spend_ap(revive_cost)
		body.revive_at(player.revive_tile_for(body))
		_on_unit_log("%s auto-revived %s (%d HP)" % [player.stats.display_name,
			body.stats.display_name, body.current_hp])
		return
	if not go_get:
		return
	if _auto_try_lift(player, h, lift_cost):
		return
	# Walk toward the nearest body worth fetching, keeping the lift's AP back.
	var best: Array[Vector3i] = []
	for node in get_tree().get_nodes_in_group("player_units"):
		var body := node as Unit
		if body == null or not body.is_carriable() or (h != null and h.in_square(body.grid_pos)):
			continue
		var path := GridManager.find_path(player.grid_pos, body.grid_pos, AUTO_RESCUE_RANGE, true)
		if path.is_empty() or path.size() > AUTO_RESCUE_RANGE:
			continue
		if best.is_empty() or path.size() < best.size():
			best = path
	if best.is_empty():
		return
	# The body's own tile may be stood on by somebody; stop short of it if so.
	if not GridManager.is_free(best[-1]):
		best.resize(best.size() - 1)
	var steps := mini(best.size(), (player.ap - lift_cost) / player.move_ap_per_tile())
	if steps < 1:
		return
	var walk := best.slice(0, steps)
	player.spend_ap(player.move_cost_for(walk.size()))
	await player.move_along(walk)
	_on_unit_log("%s auto-moved to %s to fetch a body" % [player.stats.display_name, walk[-1]])
	if not player.is_downed and not TurnManager.mission_over:
		_auto_try_lift(player, h, lift_cost)


## Lifts the best body in reach (a downed squadmate before a corpse), if the AP
## is there. True if it did.
func _auto_try_lift(player: PlayerUnit, h: MapData.Hangar, lift_cost: int) -> bool:
	if player.ap < lift_cost or player.carrying != null:
		return false
	var pick: Unit = null
	for body in player.body_targets(PlayerUnit.Mode.PICK_UP):
		if h != null and h.in_square(body.grid_pos):
			continue
		if pick == null or (body.life_state == Unit.LifeState.DOWNED and pick.life_state == Unit.LifeState.DEAD):
			pick = body
	if pick == null:
		return false
	player.spend_ap(lift_cost)
	player.pick_up(pick)
	_on_unit_log("%s auto-lifted %s%s" % [player.stats.display_name, pick.stats.display_name,
		"'s body" if pick.life_state == Unit.LifeState.DEAD else ""])
	return true


func _auto_try_call(player: PlayerUnit) -> void:
	var cost := player.action_cost(UnitStats.Action.CALL_SHIP)
	if player.ap < cost or ExtractionManager.callable_hangar_for(player) < 0:
		return
	# The ship is not called while the fetcher is still on its way to a reachable
	# Retrieve item: a ship that lands first sends the fetcher home empty-handed.
	if _auto_fetch_pending():
		return
	player.spend_ap(cost)
	if ExtractionManager.call_ship(player):
		_on_unit_log("%s auto-called the ship (%d AP)" % [player.stats.display_name, cost])


## The hangar to extract from: the squad's claimed one if any, else the nearest
## (by path) discovered hangar that can be called right now. The insertion
## hangar is always a candidate, so a run that never found another still has
## a way out — the "safe run" GDD §7.2 says is legal and pays poorly.
func _auto_pick_hangar(player: PlayerUnit) -> int:
	var best := -1
	var best_len := 999999
	var rules: ExtractionRules = ExtractionManager.rules
	for i in rules.hangar_count():
		if rules.call_blocker(i, ExtractionRules.PLAYER_CREW) != "":
			continue
		var h := ExtractionManager.hangar(i)
		var length := 0
		if not h.in_bay(player.grid_pos):
			var path := GridManager.find_path(player.grid_pos, h.square[4], 999, true)
			if path.is_empty():
				continue
			length = path.size()
		if length < best_len:
			best_len = length
			best = i
	return best


## Walks toward the nearest free square tile this activation's AP can afford,
## all of it if need be — getting in matters more than a shot does now.
func _auto_walk_to_square(player: PlayerUnit, h: MapData.Hangar) -> void:
	var best: Array[Vector3i] = []
	for tile: Vector3i in h.square:
		if not GridManager.is_free(tile):
			continue
		var path := GridManager.find_path(player.grid_pos, tile, 999)
		if path.is_empty():
			continue
		if best.is_empty() or path.size() < best.size():
			best = path
	if best.is_empty():
		return
	var steps := mini(player.move_tiles_affordable(), best.size())
	if steps < 1:
		return
	var path := best.slice(0, steps)
	player.spend_ap(player.move_cost_for(path.size()))
	await player.move_along(path)
	_on_unit_log("%s auto-moved to %s heading for the ship" % [player.stats.display_name, path[-1]])


## Every soldier still on their feet is in `h`'s square. Downed ones don't count:
## they cannot get in on their own, and waiting on them would only run the
## window out with the rest of the squad standing in the open.
func _auto_squad_in_square(h: MapData.Hangar) -> bool:
	for node in get_tree().get_nodes_in_group("player_units"):
		var member := node as Unit
		if member != null and member.life_state == Unit.LifeState.ACTIVE and not h.in_square(member.grid_pos):
			return false
	return true


## Shoots (or reloads) at the nearest hostile in sight with whatever AP is left,
## without moving — the extraction branch's covering fire.
func _auto_shoot(player: PlayerUnit) -> void:
	var shoot_cost := player.action_cost(UnitStats.Action.SHOOT)
	var reload_cost := player.action_cost(UnitStats.Action.RELOAD)
	while player.ap > 0 and not player.is_downed and not TurnManager.mission_over:
		var target: Unit = null
		for enemy in player.hostiles():
			if GridManager.chebyshev_dist(player.grid_pos, enemy.grid_pos) <= 8 \
					and GridManager.has_line_of_sight(player, enemy):
				target = enemy
				break
		if target == null:
			return
		if player.can_shoot() and player.ap >= shoot_cost:
			player.spend_ap(shoot_cost)
			var result: Combat.ShotResult = await player.fire_at(target, Combat.ShotAction.SHOOT)
			_on_unit_log("%s auto-fired at %s (%d%%): %s" % [player.stats.display_name,
				target.stats.display_name, result.accuracy, Combat.describe(result)])
		elif not player.can_shoot() and player.can_reload() and player.ap >= reload_cost:
			player.spend_ap(reload_cost)
			await player.do_reload()
		else:
			return


func _living_squad() -> Array:
	var out: Array = []
	for node in get_tree().get_nodes_in_group("player_units"):
		var member := node as Unit
		if member != null and not member.is_downed:
			out.append(member)
	return out


## The original greedy loop, kept as the harness's floor: shoot, reload, close,
## swing. Crude on purpose — it exists to guarantee the run terminates, not to
## play well.
##
## `fixed_target`, when given and still standing, is attacked instead of the
## nearest hostile — the Destroy contract's nest (extraction plan 3.3).
func _greedy_fallback(player: PlayerUnit, fixed_target: Unit = null) -> void:
	var shoot_cost := player.action_cost(UnitStats.Action.SHOOT)
	var reload_cost := player.action_cost(UnitStats.Action.RELOAD)
	var melee_cost := player.action_cost(UnitStats.Action.MELEE)
	while player.ap > 0 and not player.is_downed and not TurnManager.mission_over:
		var target := fixed_target if fixed_target != null and is_instance_valid(fixed_target) \
			and not fixed_target.is_downed else _nearest_hostile(player)
		if target == null:
			break
		var in_range := GridManager.chebyshev_dist(player.grid_pos, target.grid_pos) <= 8
		if in_range and GridManager.has_line_of_sight(player, target) and player.can_shoot():
			if player.ap < shoot_cost:
				break  # cannot afford the shot it wants — end the activation
			player.spend_ap(shoot_cost)
			var result: Combat.ShotResult = await player.fire_at(target, Combat.ShotAction.SHOOT)
			_on_unit_log("%s auto-fired at %s (%d%%): %s" % [player.stats.display_name, target.stats.display_name, result.accuracy, Combat.describe(result)])
		# `can_reload` matters as much as `can_shoot`, and leaving it out was a
		# hang: a weapon's reserve is finite, so a soldier who burns the mission's
		# whole ammo budget can neither fire nor refill — and this branch happily
		# charged AP to draw zero rounds, every activation, forever. A run could
		# sit at 2000+ turns with one dry survivor doing that.
		#
		# Falling through to the move branch instead is also the better behaviour:
		# a soldier out of ammo walks at the enemy rather than miming a reload,
		# which gets them seen and gets the mission resolved one way or the other.
		elif not player.can_shoot() and player.can_reload():
			if player.ap < reload_cost:
				break
			player.spend_ap(reload_cost)
			await player.do_reload()
		elif GridManager.is_melee_adjacent(player.grid_pos, target.grid_pos):
			# The branch whose absence was the last way this could hang. A soldier
			# with nothing left to fire walks at the enemy (above), arrives, and
			# then had literally no action available: `_move_toward` stops short
			# of the target's tile, so the path goes empty and the activation just
			# ended, every turn, forever. Standing in the dark it was not even
			# noticed — the aliens need light to see, which is the system working,
			# but it left the run unable to finish.
			if player.ap < melee_cost:
				break
			player.spend_ap(melee_cost)
			var hit: Combat.ShotResult = await player.melee_at(target)
			_on_unit_log("%s auto-struck %s (%d%%): %s" % [
				player.stats.display_name, target.stats.display_name,
				hit.accuracy, Combat.describe(hit)])
		else:
			var full_path := GridManager.find_path(player.grid_pos, target.grid_pos, 999, true)
			if full_path.size() <= 1:
				break
			full_path.resize(full_path.size() - 1)
			# Holds back the price of a shot, exactly as the alien loop does — at
			# 1 AP per tile a unit that walks its whole pool never fires.
			var budget := maxi(1, (player.ap - shoot_cost) / player.move_ap_per_tile())
			if player.move_tiles_affordable() < 1:
				break
			var path := full_path.slice(0, mini(budget, full_path.size()))
			player.spend_ap(player.move_cost_for(path.size()))
			await player.move_along(path)
			_on_unit_log("%s auto-moved to %s" % [player.stats.display_name, path[-1]])


## Nearest hostile this unit can actually DO something about — shoot from where
## it stands, or walk to. The reachability half is what stops the smoke test
## deadlocking.
##
## Chebyshev ignores walls, so "nearest" is frequently something on the far side
## of a bulkhead. The old version picked it anyway, `_auto_play` then found no
## path and ended the activation, and the same unreachable unit won the next draw
## too — so both sides idled at each other forever. Harmless while every hostile
## shared one room with the squad; the rival mercs spawn in a compartment of
## their own, and a run promptly stalemated for 3000+ turns.
##
## Costs a pathfind per candidate that would improve on the current best, which
## is nothing at smoke-test scale and buys a run that terminates. This is the
## headless harness's greedy stand-in for AI, not the game's — real units plan
## through `EnemyUnit`.
func _nearest_hostile(player: Unit) -> Unit:
	var best: Unit = null
	var best_dist := 999999
	for enemy in player.hostiles():
		var d := GridManager.chebyshev_dist(player.grid_pos, enemy.grid_pos)
		if d >= best_dist or not _can_act_on(player, enemy):
			continue
		best_dist = d
		best = enemy
	return best


func _can_act_on(player: Unit, enemy: Unit) -> bool:
	if GridManager.chebyshev_dist(player.grid_pos, enemy.grid_pos) <= 8 \
			and GridManager.has_line_of_sight(player, enemy):
		return true
	return not GridManager.find_path(player.grid_pos, enemy.grid_pos, 999, true).is_empty()


func _on_unit_log(text: String) -> void:
	print(text)
	hud.append_log(text)
	# `action_logged` narration (move/shoot/reload/etc.) is per-unit and local
	# by default — unlike TurnManager.log_message, which already fans itself
	# out (see turn_manager.gd's `_log`). Only the host's copy of a unit ever
	# actually runs these actions, so only the host needs to relay.
	if SteamLobby.is_networked() and SteamLobby.is_host():
		_rpc_relay_log.rpc(text)


@rpc("authority", "call_remote", "reliable")
func _rpc_relay_log(text: String) -> void:
	print(text)
	hud.append_log(text)
