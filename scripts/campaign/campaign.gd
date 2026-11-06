extends Node
## Autoload `Campaign` (extraction plan 4.1–4.3): the live campaign and the one
## ironman save slot, the deployment a mission is built from, and the debrief it
## comes back with. The rules themselves are in CampaignState (engine-free,
## tested); this is the Node around it that owns what a RefCounted cannot — the
## save path, the network, and surviving the scene changes of the loop:
##
##   front_end.tscn (Title -> Hub)  --launch()-->  main.tscn (mission)
##        ^                                            |
##        +--- Debrief <-- book_result() <-- mission_ended (host/solo)
##
## Nothing here touches the disk until asked: `_ready` does not load the save, so
## --script tests (which get every autoload) and `--auto` runs never read or write
## the player's campaign. `--auto` plays a throwaway (`use_throwaway`), with no
## file at all unless it is given a temp path.
##
## CO-OP (MULTIPLAYER_PLAN.md, replacing assumption A7): EVERY player has their own
## campaign — their solo save — and brings 1–2 of its soldiers. The host merges the
## picks into one `deployment` (CoopRules.merge_deployment) and sends it to every
## client over this node's RPCs (an autoload, so /root/Campaign resolves on every
## peer whichever scene each is in); each peer books its own soldiers out on its
## own save (CampaignState.begin_coop). At the end the host splits the report per
## player (CoopRules.split_report), books its own, files the rest as pending and
## delivers them (`deliver_pending`); a client applies its own (`receive_report`)
## and acks. A dropped player is sent back into the running mission on reconnect
## (`send_rejoin`); a host's game closing mid-mission leaves a checkpoint
## (`write_checkpoint`) the host can resume from (`begin_resume`).

signal deployment_received
signal debrief_received(summary: Dictionary)
## A dropped co-op player is being brought back into the running mission.
signal rejoin_received

## The player's one slot (A8). Tests and auto runs never use it: tests drive
## CampaignState.save_to with their own path, and `use_throwaway` swaps this out.
const SAVE_PATH := "user://campaign.json"
const FRONT_END_SCENE := "res://scenes/front_end.tscn"
const MISSION_SCENE := "res://scenes/main.tscn"
## A co-op host's mission checkpoint (MULTIPLAYER_PLAN.md §2.8): the deployment and
## the latest round-start MissionSnapshot. One file, like the one slot.
const CHECKPOINT_PATH := "user://coop_mission.json"

## Where `save()` writes. Injectable: `use_throwaway(path)` points it elsewhere.
var save_path := SAVE_PATH
## False for a throwaway campaign with no file: `save()` and `wipe()` do nothing.
var persistent := true
## The live campaign on the host (or solo); null on a co-op client, and before
## the title screen has loaded or started one.
var state: CampaignState = null

## The mission being launched or played (CampaignState.make_deployment), on every
## peer. {} between missions.
var deployment: Dictionary = {}
## Set when a deployment arrives (or is made) and not yet spawned — what a client
## waiting in the front end watches for.
var deployment_fresh := false
## The last debrief's summary (CampaignState.apply_report), on every peer, and
## whether the front end has shown it yet.
var last_debrief: Dictionary = {}
var debrief_unseen := false
## Co-op client: the mission scene is being entered mid-mission, and builds from
## the snapshot the host sends rather than from a loadout screen.
var rejoining := false
## Co-op host: the checkpoint the mission scene restores before resuming. {} for
## an ordinary launch.
var resume_snapshot: Dictionary = {}
## Co-op host: the mission scene is resuming the checkpoint (`begin_resume`).
var resuming := false
## Where the checkpoint lives. Injectable for tests.
var checkpoint_path := CHECKPOINT_PATH


func _ready() -> void:
	# `--save-slot=<name>`: this instance's own save and checkpoint, so two copies of
	# the game on one machine (co-op testing, MULTIPLAYER_PLAN.md §5) are two players
	# with two campaigns rather than one fighting over one file.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--save-slot="):
			var slot := arg.trim_prefix("--save-slot=").validate_filename()
			save_path = "user://campaign_%s.json" % slot
			checkpoint_path = "user://coop_mission_%s.json" % slot


# --- The slot ---------------------------------------------------------------------


func has_save() -> bool:
	return persistent and FileAccess.file_exists(save_path)


## Loads the slot into `state`. "" on success, else the reason (missing, damaged,
## wrong version) — the slot is left untouched for the player to decide about.
func load_campaign() -> String:
	var loaded := CampaignState.load_from(save_path)
	if loaded["error"] != "":
		return loaded["error"]
	state = loaded["state"]
	return ""


## A fresh campaign in the slot, replacing whatever was there.
func start_new(p_seed: int = -1) -> void:
	state = CampaignState.new_campaign(p_seed)
	save()


## A campaign that is never the player's: `--auto`, the screenshot tool, or
## main.tscn launched straight from the editor. `path` "" keeps it in memory only;
## a path (the `--auto-campaign` chain, which has to survive scene reloads AND
## exercise the save) writes there instead of the real slot.
func use_throwaway(path: String = "", p_seed: int = -1) -> void:
	save_path = path
	persistent = path != ""
	state = CampaignState.new_campaign(p_seed)
	save()


func save() -> void:
	if state == null or not persistent or save_path == "":
		return
	var err := state.save_to(save_path)
	if err != OK:
		push_error("Campaign: could not save to %s (%s)" % [save_path, error_string(err)])


## Deletes the slot (game over, A8: one slot and no way back).
func wipe() -> void:
	if persistent and save_path != "":
		CampaignState.delete_save(save_path)


## Leaves the campaign entirely (back to the title): forgets the state and any
## pending deployment. The slot on disk is not touched.
func close() -> void:
	state = null
	leave_mission()
	last_debrief = {}
	debrief_unseen = false


## Drops the deployment being played (a co-op client leaving, or the host gone)
## and keeps the campaign: back to this player's own hub.
func leave_mission() -> void:
	deployment = {}
	deployment_fresh = false
	rejoining = false
	resuming = false
	resume_snapshot = {}


# --- Hub actions (host/solo): each one saves (ironman) ------------------------------


func hire(index: int) -> String:
	return _saved(state.hire(index))


func rename(record_id: String, new_name: String) -> String:
	return _saved(state.rename(record_id, new_name))


func treat(record_id: String, part: int) -> String:
	return _saved(state.treat(record_id, part))


func buy_attachment(id: int) -> String:
	return _saved(state.buy_attachment(id))


func buy_ammo(id: int) -> String:
	return _saved(state.buy_ammo(id))


func buy_grenade() -> String:
	return _saved(state.buy_grenade())


func buy_medical() -> String:
	return _saved(state.buy_medical())


func _saved(err: String) -> String:
	if err == "":
		save()
	return err


# --- Deployment ---------------------------------------------------------------------


## The hub's Launch: books the deployment (grenades leave the stock, the mission
## is marked in progress), saves, and in co-op sends it to the client. The caller
## then changes to MISSION_SCENE. "" or the reason it cannot launch.
func launch(record_ids: Array, offer_index: int, grenade_counts: Array = []) -> String:
	var err := state.deploy_blocker(record_ids, offer_index)
	if err != "":
		return err
	deployment = state.make_deployment(record_ids, offer_index, grenade_counts, randi() & 0x7fffffff)
	_apply_cmdline_deck()
	state.begin_mission(deployment)
	save()
	deployment_fresh = true
	if SteamLobby.is_host():
		_rpc_deployment.rpc(deployment)
	return ""


## A deployment with no hub in front of it (`--auto`, main.tscn run directly): the
## first `count` soldiers, no contract offer — main.gd picks one for whatever deck
## the command line built, as before Phase 4.
func adhoc_deployment(count: int) -> void:
	var ids: Array = []
	for r in state.roster:
		if ids.size() >= count:
			break
		ids.append(r.id)
	deployment = state.make_deployment(ids, -1, [], randi() & 0x7fffffff)
	_apply_cmdline_deck()
	state.begin_mission(deployment)
	save()
	deployment_fresh = true


## Dev override: `--seed=<n>` or `--map=<name>` on the HOST's command line replaces
## the contract's deck, and rides in the deployment so a co-op client builds the
## same one whatever its own command line says.
func _apply_cmdline_deck() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seed="):
			deployment["deck"] = {"kind": "generated", "seed": int(arg.trim_prefix("--seed=")),
				"size": CampaignEconomy.DeckSize.MEDIUM}
			return
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--map="):
			deployment["deck"] = {"kind": "layout", "path": "res://maps/%s.txt" % arg.trim_prefix("--map=")}
			return


## The deployment's contract offer, or null.
func deployed_offer() -> ContractOffer:
	var d: Dictionary = deployment.get("offer", {})
	return ContractOffer.from_dict(d) if not d.is_empty() else null


## LoadoutMenu.inventory for this peer: the stash's copies minus those fitted to
## the soldiers `others` (the OTHER player's, in co-op) — each player re-fits only
## from their share, so two peers' loadout screens can never hand the same copy
## out twice. Solo passes no others and gets the whole stash.
func loadout_inventory(others: Array) -> Dictionary:
	var inv: Dictionary = {}
	if is_coop():
		# Per-player co-op: this player fits their own soldiers from their own
		# stash, which nobody else draws on — no share to split.
		var mine: Dictionary = (deployment.get("owners", {}) as Dictionary).get(my_key(), {})
		var own: Dictionary = mine.get("attachments", {})
		for key in own:
			inv[int(key)] = int(own[key])
		return inv
	var att: Dictionary = deployment.get("attachments", {})
	for key in att:
		inv[int(key)] = int(att[key])
	for unit in others:
		var w: WeaponData = unit.stats.weapon
		if w == null:
			continue
		for a in w.attachments():
			inv[a.id] = maxi(0, inv.get(a.id, 0) - 1)
	return inv


func loadout_ammo() -> Array:
	var out: Array = []
	var source: Array = deployment.get("ammo", [AmmoPresets.AmmoId.STANDARD])
	if is_coop():
		var mine: Dictionary = (deployment.get("owners", {}) as Dictionary).get(my_key(), {})
		source = mine.get("ammo", [AmmoPresets.AmmoId.STANDARD])
	for a in source:
		out.append(int(a))
	return out


## After the loadout screens: records what each soldier really took, so an
## interrupted mission (ironman) loses the copies actually fitted. Host/solo.
func note_loadouts(units: Array) -> void:
	if state == null or (state.in_mission.is_empty() and state.away.is_empty()):
		return
	var loadouts := {}
	var coop := is_coop()
	for unit in units:
		var p := unit as PlayerUnit
		# Co-op: only this save's own soldiers (record ids are per save).
		if p != null and p.record_id != "" and (not coop or p.owner_key == my_key()):
			loadouts[p.record_id] = weapon_dict(p.stats.weapon)
	state.note_loadouts(loadouts)
	save()


@rpc("authority", "call_remote", "reliable")
func _rpc_deployment(d: Dictionary) -> void:
	deployment = d
	# Book this player's own soldiers out on their own save before anything else
	# can happen to the mission: from here they are away until the report comes.
	if CoopRules.is_coop(d) and state != null and CoopRules.players_of(d).has(my_key()):
		state.begin_coop(d, my_key(), false)
		save()
	deployment_fresh = true
	deployment_received.emit()


# --- Co-op (MULTIPLAYER_PLAN.md) ---------------------------------------------------------


static func my_key() -> String:
	return CoopPlayers.local_key()


## Whether the deployment being played is a per-player co-op one.
func is_coop() -> bool:
	return CoopRules.is_coop(deployment)


## Host: launches the party. `members`/`order` are CoopLobby's table; every
## player's pick package goes into one deployment, this save books its own share
## (`begin_coop`, saved), the checkpoint is started, and every client is sent the
## deployment. "" or why not.
func launch_coop(order: Array, members: Dictionary, offer_index: int) -> String:
	if state == null:
		return "No campaign loaded"
	if offer_index < 0 or offer_index >= state.contracts.size():
		return "Choose a contract"
	var mine: Dictionary = (members.get(my_key(), {}) as Dictionary).get("pick", {})
	var ids: Array = []
	for d: Dictionary in mine.get("records", []):
		ids.append(String(d.get("id", "")))
	var err := state.pick_blocker(ids)
	if err != "":
		return err
	deployment = CoopRules.merge_deployment(order, members, state.contracts[offer_index].to_dict(),
		randi() & 0x7fffffff, CoopRules.new_mission_id())
	_apply_cmdline_deck()
	state.begin_coop(deployment, my_key(), true)
	save()
	write_checkpoint({})
	deployment_fresh = true
	if SteamLobby.is_host():
		_rpc_deployment.rpc(deployment)
	return ""


## Host: sends player `key` every report this save still owes them, if they are
## connected. Called when they say hello (CoopLobby) and at a mission's end.
func deliver_pending(key: String) -> void:
	if state == null or not SteamLobby.is_host():
		return
	var peer := CoopPlayers.peer_of(key)
	if peer <= 0 or peer == multiplayer.get_unique_id():
		return
	for report: Dictionary in state.pending_reports.get(key, []):
		_rpc_report.rpc_id(peer, report)


@rpc("authority", "call_remote", "reliable")
func _rpc_report(report: Dictionary) -> void:
	receive_report(report)


## Client: one report from the host, for this player's soldiers. Applied only if
## it settles a mission this save is still away on (a written-off mission's late
## report is dropped — MULTIPLAYER_PLAN.md §1); acked either way, so the host
## stops owing it.
func receive_report(report: Dictionary) -> void:
	var mission_id := String(report.get("mission_id", ""))
	if state != null and state.accepts_report(report):
		var summary := state.apply_report(report)
		last_debrief = summary
		debrief_unseen = true
		if summary.get("game_over", false):
			wipe()
		else:
			save()
		debrief_received.emit(summary)
	if SteamLobby.is_networked() and not SteamLobby.is_host():
		_rpc_ack_report.rpc_id(1, mission_id)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_ack_report(mission_id: String) -> void:
	if not multiplayer.is_server() or state == null:
		return
	state.ack_pending_report(CoopPlayers.key_of(multiplayer.get_remote_sender_id()), mission_id)
	save()


## Host: brings the player on `peer` back into the running mission — the deployment
## only; their mission scene asks for the live snapshot once its board is built
## (main.gd `_rpc_request_snapshot`).
func send_rejoin(peer: int) -> void:
	if not deployment.is_empty() and SteamLobby.is_host():
		_rpc_rejoin.rpc_id(peer, deployment)


@rpc("authority", "call_remote", "reliable")
func _rpc_rejoin(d: Dictionary) -> void:
	var mission_id := String((d.get("coop", {}) as Dictionary).get("mission_id", ""))
	# Only for a mission this save is still away on: soldiers written off are
	# nobody's to command any more.
	if state == null or state.away_index(mission_id) < 0:
		return
	deployment = d
	rejoining = true
	deployment_fresh = true
	rejoin_received.emit()


## Gives up on co-op mission `mission_id` this save's soldiers are away on (the
## Roster tab's Write off). Returns the debrief summary, also kept as the last one.
func write_off(mission_id: String) -> Dictionary:
	if state == null:
		return {}
	var summary := state.write_off(mission_id)
	if summary.is_empty():
		return summary
	last_debrief = summary
	if summary.get("game_over", false):
		wipe()
	else:
		save()
	return summary


# --- Host-resume (MULTIPLAYER_PLAN.md §2.8) --------------------------------------------


## Writes the co-op host's checkpoint: the deployment and `snapshot` (a round
## start's MissionSnapshot; {} at launch). Temp file and rename, like the save.
func write_checkpoint(snapshot: Dictionary) -> void:
	if not persistent or checkpoint_path == "":
		return
	var tmp := checkpoint_path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("Campaign: could not write the co-op checkpoint (%s)" % error_string(FileAccess.get_open_error()))
		return
	f.store_string(MissionSnapshot.to_text({"deployment": deployment, "snapshot": snapshot}))
	f.close()
	if FileAccess.file_exists(checkpoint_path):
		DirAccess.remove_absolute(checkpoint_path)
	DirAccess.rename_absolute(tmp, checkpoint_path)


## The checkpoint on disk: {deployment, snapshot}, or {} if there is none.
func load_checkpoint() -> Dictionary:
	if checkpoint_path == "" or not FileAccess.file_exists(checkpoint_path):
		return {}
	return MissionSnapshot.from_text(FileAccess.get_file_as_string(checkpoint_path))


func delete_checkpoint() -> void:
	if checkpoint_path != "" and FileAccess.file_exists(checkpoint_path):
		DirAccess.remove_absolute(checkpoint_path)


## Whether the loaded save is a co-op host's mid-mission, with a checkpoint for
## that same mission to resume from.
func can_resume() -> bool:
	if state == null or not state.is_hosting_coop():
		return false
	var cp := load_checkpoint()
	var d: Dictionary = cp.get("deployment", {})
	return String((d.get("coop", {}) as Dictionary).get("mission_id", "")) \
		== String((state.in_mission["coop"] as Dictionary).get("mission_id", ""))


## Sets the mission scene up to resume the checkpoint. "" or why not.
func begin_resume() -> String:
	if not can_resume():
		return "No co-op mission to resume"
	var cp := load_checkpoint()
	deployment = cp.get("deployment", {})
	resume_snapshot = cp.get("snapshot", {})
	resuming = true
	deployment_fresh = true
	return ""


## The co-op host gives up on its interrupted mission: its own soldiers are booked
## lost (ironman, `book_interrupted`); the checkpoint goes. The other players write
## theirs off on their own saves.
func write_off_hosted() -> Dictionary:
	var summary := book_interrupted()
	delete_checkpoint()
	return summary


# --- Debrief ------------------------------------------------------------------------


## Books a finished mission into the campaign (host/solo, at `mission_ended`, so
## the result is in the save before anyone clicks anything — ironman). `units` is
## every PlayerUnit the mission spawned. Returns the summary, also kept in
## `last_debrief` and sent to a co-op client. {} if there is no campaign mission
## to book (ABANDONED is not a result to book: see MissionResult).
func book_result(result: MissionResult, units: Array) -> Dictionary:
	if state == null or deployment.is_empty() or result.outcome == MissionResult.Outcome.ABANDONED:
		return {}
	var report := report_from_result(result, units, deployment)
	if not is_coop():
		return _finish_debrief(state.apply_report(report))
	# Per-player co-op (MULTIPLAYER_PLAN.md §2.7): one report per player. Everyone
	# else's is filed as owed BEFORE anything is sent — saved with this player's own
	# booking — so a player who is gone, or drops in the next second, still gets
	# theirs the next time they connect.
	var split := CoopRules.split_report(report, deployment)
	for key: String in split:
		if key != my_key():
			state.add_pending_report(key, split[key])
	var mine: Dictionary = split.get(my_key(), {})
	var summary := state.apply_report(mine) if not mine.is_empty() else {}
	delete_checkpoint()
	var out := _finish_debrief(summary)
	for key: String in split:
		if key != my_key():
			deliver_pending(key)
	CoopLobby.mission_finished()
	return out


## A save that still held a mission in progress: book it as lost (ironman).
func book_interrupted() -> Dictionary:
	return _finish_debrief(state.book_interrupted())


func _finish_debrief(summary: Dictionary) -> Dictionary:
	last_debrief = summary
	debrief_unseen = true
	deployment = {}
	deployment_fresh = false
	if summary.get("game_over", false):
		wipe()  # one slot, ironman: a finished campaign leaves nothing to load
	else:
		save()
	# No broadcast: in co-op every player gets their OWN report (`book_result`,
	# `deliver_pending`), never the host's summary.
	return summary


## A soldier across saves (co-op): record ids are per save, so the owner key and
## the id together. Solo is "/<id>".
static func _soldier_key(owner: String, id: String) -> String:
	return "%s/%s" % [owner, id]


## The engine-free report CampaignState.apply_report books, from the live units:
## each deployed soldier's fate, gun, grenades, pack and injuries. Built while the
## units are still in the tree (they are: the ship hides them, nothing frees them
## before the scene changes).
##
## Fate: a recovered corpse (MissionResult.recovered_corpses) is RECOVERED; anyone
## else aboard is SURVIVED (downed or not); everyone else — dead, downed and left
## behind, or never extracted at all — is LOST (GDD §4.4: left behind = lost).
## Deployed records with no unit (more soldiers than the deck had spawn tiles)
## come back as `benched`, untouched.
static func report_from_result(result: MissionResult, units: Array, p_deployment: Dictionary) -> Dictionary:
	var soldiers: Array = []
	var spawned := {}
	for node in units:
		var u := node as PlayerUnit
		if u == null or not is_instance_valid(u) or u.record_id == "":
			continue
		spawned[_soldier_key(u.owner_key, u.record_id)] = true
		var fate := CampaignState.FATE_LOST
		if result.is_recovered_corpse(u):
			fate = CampaignState.FATE_RECOVERED
		elif result.extracted_units.has(u) and u.life_state != Unit.LifeState.DEAD:
			fate = CampaignState.FATE_SURVIVED
		soldiers.append({
			"id": u.record_id,
			# Co-op (MULTIPLAYER_PLAN.md §2.7): whose save, and the name and class
			# the partners' debriefs show. Solo carries "" and nobody reads it.
			"owner": u.owner_key,
			"name": u.stats.display_name,
			"class": String(UnitStats.UnitClass.keys()[u.stats.unit_class]).capitalize(),
			"fate": fate,
			"weapon": weapon_dict(u.stats.weapon),
			"grenades_left": u.grenade_charges,
			"items": Array(u.inventory_codes),
			"injuries": u.injured_parts(),
			"was_downed": u.down_count > 0,
		})
	var benched: Array = []
	var recs: Array = p_deployment.get("records", [])
	var counts: Array = p_deployment.get("grenades", [])
	for i in recs.size():
		var id := String((recs[i] as Dictionary).get("id", ""))
		var owner := String((recs[i] as Dictionary).get("owner", ""))
		if not spawned.has(_soldier_key(owner, id)):
			benched.append({"id": id, "owner": owner, "grenades": int(counts[i]) if i < counts.size() else 0})
	return {
		"outcome": int(result.outcome),
		"objective_complete": result.objective_complete,
		"contract": result.contract.duplicate(true),
		"soldiers": soldiers,
		"benched": benched,
		# Phase 8: rival lifts, as finished lines (the debrief only shows them).
		"rival_notes": result.rival_lines(),
	}


## A gun as the record and the report store it. Standard ammo is -1, matching
## ItemPresets' weapon codes.
static func weapon_dict(w: WeaponData) -> Dictionary:
	if w == null:
		return {}
	var ids: Array[int] = []
	for a in w.attachments():
		ids.append(a.id)
	ids.sort()
	var ammo := w.ammo.id if w.ammo != null else -1
	if ammo == AmmoPresets.AmmoId.STANDARD:
		ammo = -1
	return {"id": w.id, "attachments": ids, "ammo": ammo}
