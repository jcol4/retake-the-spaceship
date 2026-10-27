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
## CO-OP (plan assumption A7, interim until GDD §12.1 #3): the host's campaign IS
## the campaign. The client has no `state` and owns no save; it receives the
## `deployment` (everything needed to build the identical squad and deck) and the
## debrief `summary`, both as plain dictionaries over this node's RPCs — an
## autoload, so the path (/root/Campaign) is the same on both peers whichever
## scene each is in.

signal deployment_received
signal debrief_received(summary: Dictionary)

## The player's one slot (A8). Tests and auto runs never use it: tests drive
## CampaignState.save_to with their own path, and `use_throwaway` swaps this out.
const SAVE_PATH := "user://campaign.json"
const FRONT_END_SCENE := "res://scenes/front_end.tscn"
const MISSION_SCENE := "res://scenes/main.tscn"

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
	deployment = {}
	deployment_fresh = false
	last_debrief = {}
	debrief_unseen = false


# --- Hub actions (host/solo): each one saves (ironman) ------------------------------


func hire(index: int) -> String:
	return _saved(state.hire(index))


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
	for a in deployment.get("ammo", [AmmoPresets.AmmoId.STANDARD]):
		out.append(int(a))
	return out


## After the loadout screens: records what each soldier really took, so an
## interrupted mission (ironman) loses the copies actually fitted. Host/solo.
func note_loadouts(units: Array) -> void:
	if state == null or state.in_mission.is_empty():
		return
	var loadouts := {}
	for unit in units:
		var p := unit as PlayerUnit
		if p != null and p.record_id != "":
			loadouts[p.record_id] = weapon_dict(p.stats.weapon)
	state.note_loadouts(loadouts)
	save()


@rpc("authority", "call_remote", "reliable")
func _rpc_deployment(d: Dictionary) -> void:
	deployment = d
	deployment_fresh = true
	deployment_received.emit()


# --- Debrief ------------------------------------------------------------------------


## Books a finished mission into the campaign (host/solo, at `mission_ended`, so
## the result is in the save before anyone clicks anything — ironman). `units` is
## every PlayerUnit the mission spawned. Returns the summary, also kept in
## `last_debrief` and sent to a co-op client. {} if there is no campaign mission
## to book (ABANDONED is not a result to book: see MissionResult).
func book_result(result: MissionResult, units: Array) -> Dictionary:
	if state == null or deployment.is_empty() or result.outcome == MissionResult.Outcome.ABANDONED:
		return {}
	var summary := state.apply_report(report_from_result(result, units, deployment))
	return _finish_debrief(summary)


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
	if SteamLobby.is_host():
		_rpc_debrief.rpc(summary)
	return summary


@rpc("authority", "call_remote", "reliable")
func _rpc_debrief(summary: Dictionary) -> void:
	last_debrief = summary
	debrief_unseen = true
	deployment = {}
	debrief_received.emit(summary)


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
		spawned[u.record_id] = true
		var fate := CampaignState.FATE_LOST
		if result.is_recovered_corpse(u):
			fate = CampaignState.FATE_RECOVERED
		elif result.extracted_units.has(u) and u.life_state != Unit.LifeState.DEAD:
			fate = CampaignState.FATE_SURVIVED
		soldiers.append({
			"id": u.record_id,
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
		if not spawned.has(id):
			benched.append({"id": id, "grenades": int(counts[i]) if i < counts.size() else 0})
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
