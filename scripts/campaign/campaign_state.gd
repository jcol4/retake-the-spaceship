class_name CampaignState
extends RefCounted
## The whole campaign as data (extraction plan 4.1): the roster, the money, the
## stash, the boards, and the RNG that fills them. Every rule that touches it —
## buying, hiring, treating, deploying, and the debrief's accounting — is a method
## here, so the whole economy is testable from a --script tool with no scene and
## no autoload (tools/test_campaign.gd). The `Campaign` autoload is the thin
## Node around it that owns the save path, the scene flow and the network.
##
## Hub actions return "" on success or the reason they were refused, the same
## convention as Unit's blockers, so the UI can show the refusal as-is.
##
## SAVED as JSON (`to_dict`/`save_to`) with a `version`; see SAVE_VERSION.

## Bump when the saved shape changes incompatibly. A save of another version is
## refused with a reason rather than half-read (`load_from`); add a migration in
## `_migrate` when one is worth writing.
const SAVE_VERSION := 1

## A debrief fate, per soldier. Strings rather than an enum so a saved or sent
## report reads plainly.
const FATE_SURVIVED := "survived"
const FATE_RECOVERED := "recovered"
const FATE_LOST := "lost"

## Recruit names. Drawn without repeats while any are unused on the roster; the
## first three are the old hardcoded squad's.
const NAMES: Array[String] = [
	"Reyes", "Okafor", "Lindqvist", "Marsh", "Varga", "Castellanos", "Ito", "Brennan",
	"Adeyemi", "Kowalski", "Haddad", "Novak", "Sato", "Ferreira", "Mbeki", "Larsen",
	"Duval", "Petrov", "Quinn", "Achterberg", "Nakamura", "Oyelaran", "Silva", "Holm",
	"Rourke", "Tanaka", "Abara", "Kerrigan", "Moreau", "Vasquez", "Eriksen", "Chen",
	"Doyle", "Iwu", "Rasmussen", "Bauer", "Kaur", "Mendes", "Volkov", "Asante",
]

var roster: Array[SoldierRecord] = []
var credits: int = 0
## AttachmentPresets id -> copies owned. Copies fitted to a soldier stay counted
## here (exactly LoadoutMenu.inventory's meaning: copies owned, one soldier each at
## a time); a soldier lost with the copy fitted takes it off this count.
var attachments: Dictionary = {}
## AmmoPresets ids unlocked. Standard is always in it.
var unlocked_ammo: Array[int] = []
## Grenade stock. Drawn at deploy (`begin_mission`), unthrown ones returned at the
## debrief.
var grenades: int = 0
## The medical resource (GDD §7.5): one clears one injured part.
var medical: int = 0
## The contract board and the recruit pool: re-rolled after every debrief (and at
## the start), never on load — they are saved, so quitting to the title cannot
## reroll them.
var contracts: Array[ContractOffer] = []
## [{"record": SoldierRecord, "price": int}]
var recruits: Array[Dictionary] = []
var next_id: int = 1
var missions_played: int = 0
## IRONMAN (decisions log): the deployment being played, written when a mission
## launches and cleared by its debrief. A save that still holds one was quit
## mid-mission, and `book_interrupted` books it as the squad lost.
var in_mission: Dictionary = {}
## The campaign's own generator: recruits, names and contracts. Saved (as strings
## — a 64-bit state does not survive JSON's doubles), so a reload deals the same
## future the save would have.
var rng := RandomNumberGenerator.new()


# --- Starting state ------------------------------------------------------------------


## A new campaign: one soldier per class, the starting money and kit, and the
## first boards. `p_seed` < 0 picks a random one.
static func new_campaign(p_seed: int = -1) -> CampaignState:
	var s := CampaignState.new()
	s.rng.seed = p_seed if p_seed >= 0 else randi()
	for unit_class in CampaignEconomy.STARTING_CLASSES:
		s.roster.append(SoldierRecord.roll(unit_class as UnitStats.UnitClass, s._unique_name(), s._new_id(), s.rng))
	s.credits = CampaignEconomy.STARTING_CREDITS
	s.grenades = CampaignEconomy.STARTING_GRENADES
	s.medical = CampaignEconomy.STARTING_MEDICAL
	for id in CampaignEconomy.STARTING_ATTACHMENTS:
		s.attachments[int(id)] = CampaignEconomy.STARTING_ATTACHMENTS[id]
	s.unlocked_ammo = CampaignEconomy.STARTING_AMMO.duplicate()
	s.refresh_offers()
	return s


## Re-deals the recruit pool and the contract board.
func refresh_offers() -> void:
	recruits.clear()
	var count := rng.randi_range(CampaignEconomy.RECRUITS_MIN, CampaignEconomy.RECRUITS_MAX)
	for _i in count:
		var unit_class: int = rng.randi_range(0, UnitStats.UnitClass.size() - 1)
		var rec := SoldierRecord.roll(unit_class as UnitStats.UnitClass, _unique_name(), _new_id(), rng)
		recruits.append({"record": rec, "price": CampaignEconomy.recruit_price(rec)})
	contracts.clear()
	for _i in CampaignEconomy.CONTRACT_OFFERS:
		contracts.append(ContractOffer.generate(rng))


func _new_id() -> String:
	var id := "S%d" % next_id
	next_id += 1
	return id


## A name nobody on the roster or the recruit board has, while any are left;
## then a repeat with a numeral, so two soldiers are never indistinguishable.
func _unique_name() -> String:
	var taken := {}
	for r in roster:
		taken[r.display_name] = true
	for c in recruits:
		taken[(c["record"] as SoldierRecord).display_name] = true
	var free: Array[String] = []
	for n in NAMES:
		if not taken.has(n):
			free.append(n)
	if not free.is_empty():
		return free[rng.randi_range(0, free.size() - 1)]
	var base: String = NAMES[rng.randi_range(0, NAMES.size() - 1)]
	var k := 2
	while taken.has("%s %d" % [base, k]):
		k += 1
	return "%s %d" % [base, k]


# --- Queries -------------------------------------------------------------------------


func record(id: String) -> SoldierRecord:
	for r in roster:
		if r.id == id:
			return r
	return null


func attachment_count(id: int) -> int:
	return attachments.get(id, 0)


## GDD §7.5 game over: "you can't field a squad and can't afford a recruit". Read
## as: the roster, plus every candidate on the board the money can buy (cheapest
## first), still falls short of MIN_SQUAD. The candidates ON OFFER, not the
## cheapest possible roll — the board only re-rolls after a mission, and a squad
## of one cannot fly that mission, so an unaffordable board is a dead end today.
func can_field_squad() -> bool:
	if roster.size() >= CampaignEconomy.MIN_SQUAD:
		return true
	var prices: Array[int] = []
	for c in recruits:
		prices.append(int(c["price"]))
	prices.sort()
	var have := roster.size()
	var money := credits
	for p in prices:
		if have >= CampaignEconomy.MIN_SQUAD or p > money:
			break
		money -= p
		have += 1
	return have >= CampaignEconomy.MIN_SQUAD


func is_game_over() -> bool:
	return not can_field_squad()


# --- Hub actions ----------------------------------------------------------------------


func hire(index: int) -> String:
	if index < 0 or index >= recruits.size():
		return "No such recruit"
	if roster.size() >= CampaignEconomy.MAX_ROSTER:
		return "The roster is full (%d)" % CampaignEconomy.MAX_ROSTER
	var price: int = recruits[index]["price"]
	if credits < price:
		return "Not enough credits (%d needed)" % price
	credits -= price
	roster.append(recruits[index]["record"])
	recruits.remove_at(index)
	return ""


## Clears one injured part with the medical resource (GDD §4.2.1, §7.5).
func treat(record_id: String, part: int) -> String:
	var r := record(record_id)
	if r == null:
		return "No such soldier"
	if not r.injuries.has(part):
		return "%s's %s is not injured" % [r.display_name, Combat.body_part_name(part)]
	if medical < CampaignEconomy.MEDICAL_PER_INJURY:
		return "No medkits left"
	medical -= CampaignEconomy.MEDICAL_PER_INJURY
	r.injuries.erase(part)
	return ""


func buy_attachment(id: int) -> String:
	if not AttachmentPresets.DATA.has(id):
		return "No such attachment"
	var price := CampaignEconomy.attachment_price(id)
	if credits < price:
		return "Not enough credits (%d needed)" % price
	credits -= price
	attachments[id] = attachment_count(id) + 1
	return ""


func buy_ammo(id: int) -> String:
	if not AmmoPresets.DATA.has(id):
		return "No such ammo"
	if unlocked_ammo.has(id):
		return "Already unlocked"
	var price := CampaignEconomy.ammo_price(id)
	if credits < price:
		return "Not enough credits (%d needed)" % price
	credits -= price
	unlocked_ammo.append(id)
	unlocked_ammo.sort()
	return ""


func buy_grenade() -> String:
	if credits < CampaignEconomy.GRENADE_PRICE:
		return "Not enough credits (%d needed)" % CampaignEconomy.GRENADE_PRICE
	credits -= CampaignEconomy.GRENADE_PRICE
	grenades += 1
	return ""


func buy_medical() -> String:
	if credits < CampaignEconomy.MEDICAL_PRICE:
		return "Not enough credits (%d needed)" % CampaignEconomy.MEDICAL_PRICE
	credits -= CampaignEconomy.MEDICAL_PRICE
	medical += 1
	return ""


# --- Deployment ----------------------------------------------------------------------


## Why this squad and contract cannot launch, or "".
func deploy_blocker(record_ids: Array, offer_index: int) -> String:
	if record_ids.size() < CampaignEconomy.MIN_SQUAD or record_ids.size() > CampaignEconomy.MAX_SQUAD:
		return "Choose %d–%d soldiers" % [CampaignEconomy.MIN_SQUAD, CampaignEconomy.MAX_SQUAD]
	var seen := {}
	for id in record_ids:
		if record(String(id)) == null or seen.has(id):
			return "Unknown soldier in the squad"
		seen[id] = true
	if offer_index < 0 or offer_index >= contracts.size():
		return "Choose a contract"
	return ""


## The default grenade allotment: one each round the squad, then a second each,
## until the stock or the per-soldier cap runs out.
static func auto_grenades(squad_size: int, stock: int) -> Array[int]:
	var out: Array[int] = []
	out.resize(squad_size)
	out.fill(0)
	var left := stock
	for _round in CampaignEconomy.GRENADES_PER_SOLDIER:
		for i in squad_size:
			if left <= 0:
				return out
			out[i] += 1
			left -= 1
	return out


## The deployment a mission is built from — everything every peer needs to build
## the identical squad and deck (Campaign sends it to a co-op client as-is):
##   records      the squad's SoldierRecord dicts, loadouts CLAMPED to the stash
##                (copies are handed out in squad order; an over-claimed copy
##                drops off the later soldier's preference)
##   grenades     per soldier, clamped to the cap and the stock (squad order)
##   offer        the ContractOffer dict ({} = none: the dev/auto path, where
##                main.gd picks a contract for whatever deck the command line built)
##   deck         {"kind": "generated", "seed", "size"} or {} (TestMap's own choice)
##   attachments  the stash's copies (LoadoutMenu.inventory), ammo the unlocks
##   spawn_seed   seeds the global RNG before spawning (aliens, mercs) on every peer
## `offer_index` -1 deploys without a contract.
func make_deployment(record_ids: Array, offer_index: int, grenade_counts: Array, spawn_seed: int) -> Dictionary:
	var remaining := attachments.duplicate()
	var recs: Array = []
	for id in record_ids:
		var r := record(String(id))
		if r == null:
			continue
		var fitted: Array[int] = []
		for a in r.attachment_ids:
			if remaining.get(a, 0) > 0 and AttachmentPresets.fits(a, r.weapon_id):
				remaining[a] -= 1
				fitted.append(a)
		var ammo := r.ammo_id if unlocked_ammo.has(r.ammo_id) and AmmoPresets.fits(r.ammo_id, r.weapon_id) else -1
		var d := r.to_dict()
		d["attachments"] = fitted
		d["ammo"] = ammo
		recs.append(d)
	var counts: Array[int] = []
	if grenade_counts.is_empty():
		counts = auto_grenades(recs.size(), grenades)
	else:
		var left := grenades
		for i in recs.size():
			var want: int = clampi(int(grenade_counts[i]) if i < grenade_counts.size() else 0, 0, CampaignEconomy.GRENADES_PER_SOLDIER)
			var take := mini(want, left)
			counts.append(take)
			left -= take
	var offer: ContractOffer = contracts[offer_index] if offer_index >= 0 and offer_index < contracts.size() else null
	return {
		"records": recs,
		"grenades": counts,
		"offer": offer.to_dict() if offer != null else {},
		"deck": offer.deck() if offer != null else {},
		"attachments": attachments.duplicate(),
		"ammo": unlocked_ammo.duplicate(),
		"spawn_seed": spawn_seed,
	}


## Books the launch (IRONMAN): the grenades leave the stock now, and the
## deployment is remembered until its debrief, so quitting mid-mission cannot
## undo it. The caller saves.
func begin_mission(deployment: Dictionary) -> void:
	for n in deployment.get("grenades", []):
		grenades -= int(n)
	grenades = maxi(0, grenades)
	in_mission = {
		"records": (deployment.get("records", []) as Array).duplicate(true),
		"grenades": (deployment.get("grenades", []) as Array).duplicate(),
		"offer": (deployment.get("offer", {}) as Dictionary).duplicate(),
	}


## Updates the in-mission record of what each soldier actually took (the loadout
## screen may have refitted them), so an interrupted mission loses the copies that
## were really fitted. `loadouts`: record id -> Campaign.weapon_dict
## ({"id", "attachments", "ammo"}).
func note_loadouts(loadouts: Dictionary) -> void:
	for d: Dictionary in in_mission.get("records", []):
		var l: Dictionary = loadouts.get(String(d.get("id", "")), {})
		if not l.is_empty():
			d["weapon"] = int(l["id"])
			d["attachments"] = (l["attachments"] as Array).duplicate()
			d["ammo"] = int(l["ammo"])


# --- Debrief -------------------------------------------------------------------------


## Applies one mission's report (Campaign.report_from_result builds it from a
## MissionResult) and returns the debrief summary the screens show. A report:
##   outcome             MissionResult.Outcome
##   objective_complete  bool; contract  Contract.to_dict() or {}
##   soldiers            [{id, fate, weapon: {id, attachments, ammo},
##                         grenades_left, items: [codes], injuries: [parts],
##                         was_downed}]
##   benched             [{id, grenades}] — deployed but never spawned (a deck with
##                       fewer spawn tiles than the squad): untouched, grenades back
##
## THE ACCOUNTING (decisions log "Phase 4 — debrief"):
##   survived   back on the roster with their loadout and injuries as they came
##              home; unthrown grenades back to stock; pack -> `_bank_item`
##   recovered  off the roster; the copies fitted to their gun leave the stash, and
##              the pack — which holds that gun, converted at death, and their
##              grenades — is banked, so a carried-out body's kit comes back
##   lost       off the roster with everything: fitted copies leave the stash
##   payout     only if the objective is complete AND the squad got out
func apply_report(report: Dictionary) -> Dictionary:
	var summary := {
		"mission": missions_played + 1,
		"outcome": int(report.get("outcome", 0)),
		"contract": "",
		"objective_complete": bool(report.get("objective_complete", false)),
		"payout": 0,
		"soldiers": [],
		"sold": [],
		"sale_total": 0,
		"gear": [],
		"credits_before": credits,
		"credits_after": credits,
		"notes": [],
		"game_over": false,
	}
	var contract: Dictionary = report.get("contract", {})
	if not contract.is_empty():
		summary["contract"] = Contract.from_dict(contract).title()

	for s: Dictionary in report.get("soldiers", []):
		var r := record(String(s.get("id", "")))
		if r == null:
			(summary["notes"] as Array).append("Unknown soldier '%s' in the report — ignored" % s.get("id", ""))
			continue
		var fate := String(s.get("fate", FATE_LOST))
		var weapon: Dictionary = s.get("weapon", {})
		var line := {"name": r.display_name, "class": r.class_name_text(), "fate": fate, "detail": ""}
		match fate:
			FATE_SURVIVED:
				var before := r.injuries.duplicate()
				if not weapon.is_empty():
					r.set_loadout(int(weapon.get("id", r.weapon_id)), weapon.get("attachments", []), int(weapon.get("ammo", -1)))
				r.set_injuries(s.get("injuries", []))
				r.missions_survived += 1
				grenades += int(s.get("grenades_left", 0))
				var parts := PackedStringArray(["Extracted"])
				if bool(s.get("was_downed", false)):
					# GDD §12.1 #8 (parked): downed-but-extracted carries no extra
					# penalty for now — only the body-part injuries already taken.
					parts.append("went down, recovered aboard")
				var fresh := PackedStringArray()
				for p in r.injuries:
					if not before.has(p):
						fresh.append(Combat.body_part_name(p))
				if not fresh.is_empty():
					parts.append("new injury: %s" % ", ".join(fresh))
				elif r.is_injured():
					parts.append("still injured: %s" % r.injury_text())
				line["detail"] = "; ".join(parts)
				_bank_items(s.get("items", []), summary)
			FATE_RECOVERED:
				_remove_fitted(weapon)
				roster.erase(r)
				line["detail"] = "Killed in action — body carried out, gear recovered"
				_bank_items(s.get("items", []), summary)
			_:
				_remove_fitted(weapon)
				roster.erase(r)
				line["fate"] = FATE_LOST
				var kit := ItemPresets.make_weapon(int(weapon.get("id", 0)), PackedInt32Array(weapon.get("attachments", [])), int(weapon.get("ammo", -1))) if not weapon.is_empty() else null
				line["detail"] = "Left behind — lost%s" % (" with their %s" % kit.display_name if kit != null else "")
		(summary["soldiers"] as Array).append(line)

	for b: Dictionary in report.get("benched", []):
		grenades += int(b.get("grenades", 0))

	var outcome := int(report.get("outcome", 0))
	var got_out := outcome == MissionResult.Outcome.EXTRACTED or outcome == MissionResult.Outcome.CLEARED
	if not contract.is_empty() and summary["objective_complete"] and got_out:
		var pay := int(contract.get("payout", 0))
		credits += pay
		summary["payout"] = pay

	# Extraction plan Phase 8: rival crews that got out, as the report gives them.
	# Intel only — nothing here is paid or charged.
	for line in report.get("rival_notes", []):
		(summary["notes"] as Array).append(String(line))

	missions_played += 1
	in_mission = {}
	refresh_offers()
	summary["credits_after"] = credits
	summary["game_over"] = is_game_over()
	return summary


## Books a mission that never reached its debrief (the save still held
## `in_mission` — the game was quit or crashed mid-mission): IRONMAN, so it counts
## as a wipe — every deployed soldier lost with their kit, no payout.
func book_interrupted() -> Dictionary:
	var soldiers: Array = []
	for d: Dictionary in in_mission.get("records", []):
		soldiers.append({
			"id": String(d.get("id", "")), "fate": FATE_LOST,
			"weapon": {"id": int(d.get("weapon", 0)), "attachments": d.get("attachments", []), "ammo": int(d.get("ammo", -1))},
		})
	var offer: Dictionary = in_mission.get("offer", {})
	var summary := apply_report({
		"outcome": MissionResult.Outcome.WIPED, "objective_complete": false,
		"contract": {}, "soldiers": soldiers,
	})
	(summary["notes"] as Array).append("The last mission%s was abandoned mid-deployment. Ironman: the squad is listed as lost." % (
		" (%s)" % ContractOffer.from_dict(offer).type_name() if not offer.is_empty() else ""))
	return summary


## The copies fitted to a gun that leaves the stash with its soldier.
func _remove_fitted(weapon: Dictionary) -> void:
	for a in weapon.get("attachments", []):
		var id := int(a)
		attachments[id] = maxi(0, attachment_count(id) - 1)
		if attachments[id] == 0:
			attachments.erase(id)


## Everything carried out, item by item (GDD §7.5: "valuables sell for credits,
## gear can be equipped next mission"):
##   valuable / salvage   sold at its value
##   objective            handed over (the contract pays for it, not the item)
##   grenade              back into the stock
##   attachment           a copy into the stash
##   ammo                 unlocks the type; a type already owned sells as spare
##   weapon               its attachments into the stash; the gun itself sells for
##                        scrap (primaries are free issue, never stashed)
func _bank_items(codes: Array, summary: Dictionary) -> void:
	for code in codes:
		var item := ItemPresets.from_code(String(code))
		if item == null:
			(summary["notes"] as Array).append("Unrecognised item '%s' — discarded" % code)
			continue
		match item.kind:
			ItemData.Kind.VALUABLE:
				_sell(item.display_name, item.value, summary)
			ItemData.Kind.OBJECTIVE:
				(summary["gear"] as Array).append("Delivered to the client: %s" % item.display_name)
			ItemData.Kind.GEAR:
				match String(item.payload.get("gear", "")):
					ItemPresets.GRENADE_ID:
						grenades += 1
						(summary["gear"] as Array).append("Grenade -> stock")
					ItemPresets.ATTACHMENT_ID:
						var aid := int(item.payload["attachment_id"])
						attachments[aid] = attachment_count(aid) + 1
						(summary["gear"] as Array).append("%s -> stash" % item.display_name)
					ItemPresets.AMMO_ID:
						var ammo := int(item.payload["ammo_id"])
						if unlocked_ammo.has(ammo):
							_sell("%s (spare)" % item.display_name, item.value, summary)
						else:
							unlocked_ammo.append(ammo)
							unlocked_ammo.sort()
							(summary["gear"] as Array).append("%s unlocked" % item.display_name)
					ItemPresets.WEAPON_ID:
						for a in item.payload.get("attachments", []):
							var id := int(a)
							attachments[id] = attachment_count(id) + 1
							(summary["gear"] as Array).append("%s -> stash" % AttachmentPresets.DATA[id]["display_name"])
						_sell("%s (scrap)" % WeaponPresets.DATA[int(item.payload["weapon_id"])]["display_name"],
							CampaignEconomy.LOOTED_WEAPON_SALE, summary)


func _sell(label: String, value: int, summary: Dictionary) -> void:
	credits += value
	(summary["sold"] as Array).append({"name": label, "value": value})
	summary["sale_total"] = int(summary["sale_total"]) + value


# --- Persistence ---------------------------------------------------------------------


func to_dict() -> Dictionary:
	var att := {}
	for id in attachments:
		att[str(id)] = attachments[id]
	var recs: Array = []
	for r in roster:
		recs.append(r.to_dict())
	var offers: Array = []
	for o in contracts:
		offers.append(o.to_dict())
	var cands: Array = []
	for c in recruits:
		cands.append({"record": (c["record"] as SoldierRecord).to_dict(), "price": c["price"]})
	return {
		"version": SAVE_VERSION,
		"credits": credits, "grenades": grenades, "medical": medical,
		"next_id": next_id, "missions_played": missions_played,
		"roster": recs, "attachments": att, "ammo": unlocked_ammo.duplicate(),
		"contracts": offers, "recruits": cands,
		"in_mission": in_mission.duplicate(true),
		"rng_seed": str(rng.seed), "rng_state": str(rng.state),
	}


## The inverse of `to_dict`, for a dict whose version has already been checked.
static func from_dict(d: Dictionary) -> CampaignState:
	var s := CampaignState.new()
	s.credits = int(d.get("credits", 0))
	s.grenades = int(d.get("grenades", 0))
	s.medical = int(d.get("medical", 0))
	s.next_id = int(d.get("next_id", 1))
	s.missions_played = int(d.get("missions_played", 0))
	for rd in d.get("roster", []):
		s.roster.append(SoldierRecord.from_dict(rd))
	var att: Dictionary = d.get("attachments", {})
	for key in att:
		var id := int(key)
		if AttachmentPresets.DATA.has(id) and int(att[key]) > 0:
			s.attachments[id] = int(att[key])
	for a in d.get("ammo", [AmmoPresets.AmmoId.STANDARD]):
		if AmmoPresets.DATA.has(int(a)) and not s.unlocked_ammo.has(int(a)):
			s.unlocked_ammo.append(int(a))
	if not s.unlocked_ammo.has(AmmoPresets.AmmoId.STANDARD):
		s.unlocked_ammo.append(AmmoPresets.AmmoId.STANDARD)
	s.unlocked_ammo.sort()
	for od in d.get("contracts", []):
		s.contracts.append(ContractOffer.from_dict(od))
	for cd in d.get("recruits", []):
		s.recruits.append({"record": SoldierRecord.from_dict(cd.get("record", {})), "price": int(cd.get("price", 0))})
	s.in_mission = _ints(d.get("in_mission", {}))
	s.rng.seed = String(d.get("rng_seed", "0")).to_int()
	s.rng.state = String(d.get("rng_state", "0")).to_int()
	return s


## Writes the save. Through a temp file and a rename, so a crash mid-write leaves
## the previous save rather than half of a new one — one slot, no backups
## (IRONMAN), so the one slot had better be whole.
func save_to(path: String) -> Error:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(to_dict(), "\t"))
	f.close()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	return DirAccess.rename_absolute(tmp, path)


## Reads a save: {"state": CampaignState or null, "error": "" or why not}. A
## missing file, unparseable JSON and a version this build does not read are all
## refusals with a reason — never a half-loaded campaign and never a silent new
## one. The file is left alone either way; only the player decides to replace it.
static func load_from(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"state": null, "error": "No campaign save"}
	var text := FileAccess.get_file_as_string(path)
	# A JSON instance rather than JSON.parse_string, which also prints an engine
	# error for a damaged file — this is a handled case, reported to the player.
	var json := JSON.new()
	var parsed: Variant = json.data if json.parse(text) == OK else null
	if not (parsed is Dictionary):
		return {"state": null, "error": "The campaign save is damaged and cannot be read"}
	var data: Dictionary = _migrate(parsed)
	var version := int(data.get("version", -1))
	if version != SAVE_VERSION:
		return {"state": null, "error": "The campaign save is version %d; this build reads version %d" % [version, SAVE_VERSION]}
	return {"state": from_dict(data), "error": ""}


## JSON hands every number back as a float; the free-form parts of a save
## (`in_mission`) are read back with whole floats turned into ints again, so a
## reloaded deployment is the same data the launch wrote, not 1.0 for 1.
static func _ints(v: Variant) -> Variant:
	if v is float and is_equal_approx(v, roundf(v)):
		return int(v)
	if v is Array:
		var out: Array = []
		for e in v:
			out.append(_ints(e))
		return out
	if v is Dictionary:
		var out := {}
		for k in v:
			out[k] = _ints(v[k])
		return out
	return v


static func delete_save(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


## Upgrades an older save's dict to SAVE_VERSION where a path exists. None yet:
## version 1 is the first, so anything else falls through to the refusal.
static func _migrate(data: Dictionary) -> Dictionary:
	return data
