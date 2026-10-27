extends SceneTree
## Extraction plan Phase 4: the campaign — roster, economy, debrief accounting,
## the ironman save (GDD §7.5, §4.4, §4.2.1).
##
##   godot --headless --path . --script res://tools/test_campaign.gd
##
## Covers:
##   - a new campaign's starting state, and that it is a pure function of its seed;
##   - recruit rolls stay in class ranges and are priced by quality (300–500);
##     hiring, the roster cap, refusals;
##   - the shop (attachments, ammo unlocks, grenades, medkits) and treating an
##     injury with a medkit;
##   - DEBRIEF ACCOUNTING from a hand-built report: a survivor's pack banked (a
##     valuable sold, a looted attachment and grenade stashed, an ammo unlock, the
##     objective item handed over), a recovered corpse's gear back in the stash, a
##     lost soldier's fitted copy gone, the payout paid / not paid, unknown codes
##     discarded, salvage priced, benched soldiers' grenades refunded;
##   - the same from REAL units through Campaign.report_from_result: a carried
##     corpse (died with its gear converted) comes home as `recovered`, its kit
##     credited; a downed soldier left behind is lost; injuries ride home;
##   - the game-over threshold (roster, credits, the candidates actually on offer);
##   - the save round-trip (incl. the RNG, so a reload deals the same future),
##     version mismatch and damaged files refused with a reason, file untouched;
##   - stash <-> loadout: deployments clamp over-claimed copies and grenades, the
##     co-op loadout split never hands a copy out twice, LoadoutMenu does not fall
##     back to "one of everything" for an empty stash;
##   - ironman: an interrupted mission is booked as lost;
##   - contract offers: payouts by type and size, deterministic placement.
##
## NEVER touches the player's slot: every file here is user://test_campaign_*.json,
## and the test checks the real slot is exactly as it found it.

const PLAYER := "res://scenes/player_unit.tscn"
const DECK := "res://maps/extraction_test.txt"
const TMP_SAVE := "user://test_campaign_tmp.json"
const TMP_BAD := "user://test_campaign_bad.json"
const REAL_SAVE := "user://campaign.json"
const ANCHOR := Vector3i(4, 0, 10)

# Ids by value (a --script tool is compiled before the class registry; see
# test_suppression.gd).
const VERTICAL_GRIP := 0
const SUPPRESSOR := 3
const HOLO_SIGHT := 6
const EXTENDED_MAG := 9
const HEAVY_STOCK := 12
const PENETRATOR := 1
const ASSAULT_RIFLE := 0
const LEG_L := 4
const ARM_R := 3
const OUT_EXTRACTED := 0
const OUT_WIPED := 1
const ASSAULT := 0
const SNIPER := 1

var _failures := 0
var _state
var _record
var _econ
var _offer
var _campaign_script
var _grid: Node
var _campaign: Node


class FakeUnit:
	var stats


func _initialize() -> void:
	_state = load("res://scripts/campaign/campaign_state.gd")
	_record = load("res://scripts/campaign/soldier_record.gd")
	_econ = load("res://scripts/campaign/campaign_economy.gd")
	_offer = load("res://scripts/campaign/contract_offer.gd")
	_campaign_script = load("res://scripts/campaign/campaign.gd")
	_grid = root.get_node_or_null("GridManager")
	_campaign = root.get_node_or_null("Campaign")
	var real_before := _file_stamp(REAL_SAVE)

	_check_new_campaign()
	_check_recruits()
	_check_shop_and_treat()
	_check_debrief_accounting()
	_check_payout_rules()
	await _check_report_from_units()
	_check_game_over()
	_check_save_round_trip()
	_check_version_mismatch()
	_check_stash_and_loadout()
	_check_interrupted()
	_check_contract_offers()

	_check(_file_stamp(REAL_SAVE) == real_before, "the player's slot (%s) is untouched" % REAL_SAVE)
	_state.delete_save(TMP_SAVE)
	_state.delete_save(TMP_BAD)
	print("")
	if _failures == 0:
		print("campaign: ALL CHECKS PASSED")
		quit(0)
	else:
		print("campaign: %d CHECK(S) FAILED" % _failures)
		quit(1)


func _check_new_campaign() -> void:
	var s = _state.new_campaign(1234)
	var classes := []
	for r in s.roster:
		classes.append(int(r.unit_class))
	classes.sort()
	_check(s.roster.size() == 4 and classes == [0, 1, 2, 3], "new campaign: four soldiers, one per class")
	_check(s.credits == _econ.STARTING_CREDITS and s.grenades == _econ.STARTING_GRENADES
		and s.medical == _econ.STARTING_MEDICAL, "new campaign: starting credits, grenades, medkits")
	_check(s.attachment_count(VERTICAL_GRIP) == 1 and s.attachment_count(HOLO_SIGHT) == 1
		and s.attachment_count(EXTENDED_MAG) == 1 and s.attachment_count(SUPPRESSOR) == 1,
		"new campaign: a few starting attachments")
	_check(s.unlocked_ammo == [0], "new campaign: Standard ammo only")
	_check(s.contracts.size() == 3, "new campaign: three contracts on the board")
	_check(s.recruits.size() >= 2 and s.recruits.size() <= 4, "new campaign: 2–4 recruits (%d)" % s.recruits.size())
	var names := {}
	for r in s.roster:
		names[r.display_name] = true
	for c in s.recruits:
		names[c["record"].display_name] = true
	_check(names.size() == s.roster.size() + s.recruits.size(), "every name on roster and board is distinct")
	var again = _state.new_campaign(1234)
	_check(JSON.stringify(again.to_dict()) == JSON.stringify(s.to_dict()), "a campaign is a pure function of its seed")


func _check_recruits() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var in_range := true
	var priced := true
	for i in 200:
		var cls := i % 4
		var r = _record.roll(cls, "R", "S%d" % i, rng)
		var ranges: Dictionary = load("res://scripts/class_presets.gd").RANGES[cls]
		for key in ["perception", "reflexes", "fitness", "luck"]:
			var v: int = r.get(key)
			if v < ranges[key][0] or v > ranges[key][1]:
				in_range = false
		var p: int = _econ.recruit_price(r)
		if p < _econ.RECRUIT_BASE_PRICE or p > _econ.RECRUIT_BASE_PRICE + _econ.RECRUIT_QUALITY_PRICE:
			priced = false
	_check(in_range, "recruit rolls stay within their class ranges (200 rolls)")
	_check(priced, "recruit prices stay within 300–500")
	var lo = _record.new()
	lo.unit_class = SNIPER
	lo.perception = 65; lo.reflexes = 45; lo.fitness = 30; lo.luck = 30
	var hi = _record.new()
	hi.unit_class = SNIPER
	hi.perception = 90; hi.reflexes = 65; hi.fitness = 50; hi.luck = 60
	_check(_econ.recruit_price(lo) == 300 and _econ.recruit_price(hi) == 500,
		"a floor roll costs 300, a ceiling roll 500 (%d, %d)" % [_econ.recruit_price(lo), _econ.recruit_price(hi)])

	var s = _state.new_campaign(7)
	var price: int = s.recruits[0]["price"]
	s.credits = price - 1
	_check(s.hire(0) != "" and s.roster.size() == 4, "hiring without the money is refused")
	s.credits = price + 10
	var hired_id: String = s.recruits[0]["record"].id
	var board: int = s.recruits.size()
	_check(s.hire(0) == "" and s.credits == 10 and s.roster.size() == 5 and s.record(hired_id) != null
		and s.recruits.size() == board - 1, "hiring pays the price and moves the candidate to the roster")
	while s.roster.size() < _econ.MAX_ROSTER:
		s.roster.append(_record.roll(ASSAULT, "Filler", "F%d" % s.roster.size()))
	s.credits = 99999
	_check(s.recruits.is_empty() or s.hire(0) != "", "hiring past the roster cap is refused")


func _check_shop_and_treat() -> void:
	var s = _state.new_campaign(5)
	s.credits = 1000
	_check(s.buy_attachment(HOLO_SIGHT) == "" and s.attachment_count(HOLO_SIGHT) == 2
		and s.credits == 1000 - _econ.attachment_price(HOLO_SIGHT), "buying an attachment adds a copy")
	_check(s.buy_ammo(PENETRATOR) == "" and s.unlocked_ammo.has(PENETRATOR), "buying an ammo unlock")
	_check(s.buy_ammo(PENETRATOR) != "", "an ammo type can't be unlocked twice")
	var g: int = s.grenades
	var m: int = s.medical
	_check(s.buy_grenade() == "" and s.grenades == g + 1 and s.buy_medical() == "" and s.medical == m + 1,
		"buying a grenade and a medkit")
	s.credits = 0
	_check(s.buy_grenade() != "" and s.buy_attachment(VERTICAL_GRIP) != "", "the shop refuses without money")
	var r = s.roster[0]
	r.set_injuries([LEG_L, ARM_R])
	s.medical = 1
	_check(s.treat(r.id, LEG_L) == "" and r.injuries == [ARM_R] and s.medical == 0, "a medkit treats one injured part")
	_check(s.treat(r.id, ARM_R) != "" and r.injuries == [ARM_R], "no medkit, no treatment")
	_check(s.treat(r.id, LEG_L) != "", "treating a healthy part is refused")


## A state with three known soldiers, for the accounting checks.
func _fixture():
	var s = _state.new_campaign(11)
	s.roster.clear()
	for i in 3:
		s.roster.append(_record.roll(ASSAULT, ["Able", "Baker", "Charlie"][i], "T%d" % i))
	s.attachments = {VERTICAL_GRIP: 1, HOLO_SIGHT: 1, EXTENDED_MAG: 1}
	s.unlocked_ammo.assign([0])
	s.grenades = 0
	s.credits = 1000
	return s


func _report(outcome: int, objective: bool) -> Dictionary:
	return {
		"outcome": outcome, "objective_complete": objective,
		"contract": {"type": 0, "target": Vector3i.ZERO, "item": "data_core", "payout": 500, "place_nest": false},
		"soldiers": [
			{"id": "T0", "fate": "survived",
				"weapon": {"id": ASSAULT_RIFLE, "attachments": [VERTICAL_GRIP], "ammo": -1},
				"grenades_left": 1,
				"items": ["fusion_cell", "attachment:%d" % HEAVY_STOCK, "grenade", "ammo:%d" % PENETRATOR, "data_core", "salvage:4", "bogus:1"],
				"injuries": [LEG_L], "was_downed": true},
			# A carried corpse: its gun (with the Holo copy) was converted into an item at death.
			{"id": "T1", "fate": "recovered",
				"weapon": {"id": ASSAULT_RIFLE, "attachments": [HOLO_SIGHT], "ammo": -1},
				"grenades_left": 0,
				"items": ["weapon:%d:%d:-1" % [ASSAULT_RIFLE, HOLO_SIGHT], "grenade", "crew_tags"],
				"injuries": [], "was_downed": true},
			{"id": "T2", "fate": "lost",
				"weapon": {"id": ASSAULT_RIFLE, "attachments": [EXTENDED_MAG], "ammo": -1},
				"grenades_left": 1, "items": ["prototype_chip"], "injuries": [], "was_downed": true},
		],
		"benched": [{"id": "T9", "grenades": 2}],
	}


func _check_debrief_accounting() -> void:
	var s = _fixture()
	var summary: Dictionary = s.apply_report(_report(OUT_EXTRACTED, true))
	# 200 fusion cell + 40 salvage + 25 crew tags + 40 scrap for the recovered rifle + 500 payout.
	var expected: int = 1000 + 200 + 40 + 25 + _econ.LOOTED_WEAPON_SALE + 500
	_check(s.credits == expected and summary["credits_after"] == expected,
		"credits: valuables sold, salvage priced, gun scrapped, payout paid (%d, want %d)" % [s.credits, expected])
	_check(summary["sale_total"] == 200 + 40 + 25 + _econ.LOOTED_WEAPON_SALE and summary["payout"] == 500,
		"summary itemises the sale and the payout")
	var able = s.record("T0")
	_check(able != null and able.missions_survived == 1 and able.injuries == [LEG_L]
		and able.attachment_ids == [VERTICAL_GRIP], "the survivor stays on the roster with their kit and their injury")
	_check(s.record("T1") == null and s.record("T2") == null and s.roster.size() == 1,
		"the recovered corpse and the lost soldier leave the roster")
	_check(s.attachment_count(VERTICAL_GRIP) == 1, "the survivor's fitted copy stays in the stash")
	_check(s.attachment_count(HOLO_SIGHT) == 1, "the carried corpse's fitted copy comes back with the body")
	_check(s.attachment_count(EXTENDED_MAG) == 0, "the lost soldier's fitted copy is gone")
	_check(s.attachment_count(HEAVY_STOCK) == 1, "a looted attachment goes into the stash")
	_check(s.unlocked_ammo.has(PENETRATOR), "looted ammo of a new type unlocks it")
	# 1 unthrown (survivor) + 1 looted + 1 off the corpse + 2 refunded (benched).
	_check(s.grenades == 5, "grenades: unthrown, looted, the corpse's and a benched soldier's come back (%d)" % s.grenades)
	var fates := {}
	for line in summary["soldiers"]:
		fates[line["name"]] = line["fate"]
	_check(fates == {"Able": "survived", "Baker": "recovered", "Charlie": "lost"}, "summary fates %s" % fates)
	var notes: Array = summary["notes"]
	_check(notes.size() == 1 and String(notes[0]).contains("bogus"), "an unrecognised code is discarded with a note")
	_check(str(summary["gear"]).contains("Delivered"), "the objective item is handed over, not sold")
	_check(s.contracts.size() == 3 and s.missions_played == 1 and s.in_mission.is_empty(),
		"the debrief re-deals the board and closes the mission")


func _check_payout_rules() -> void:
	var s = _fixture()
	var summary: Dictionary = s.apply_report(_report(OUT_EXTRACTED, false))
	_check(summary["payout"] == 0 and s.credits == 1000 + 200 + 40 + 25 + _econ.LOOTED_WEAPON_SALE,
		"objective not complete: no payout, the loot still sells")
	var w = _fixture()
	var report := _report(OUT_WIPED, true)
	for line: Dictionary in report["soldiers"]:
		line["fate"] = "lost"
	var wiped: Dictionary = w.apply_report(report)
	_check(wiped["payout"] == 0 and w.credits == 1000 and w.roster.is_empty(),
		"a wipe pays nothing and loses everyone, whatever the objective says")
	_check(w.attachment_count(VERTICAL_GRIP) == 0 and w.attachment_count(HOLO_SIGHT) == 0
		and w.attachment_count(EXTENDED_MAG) == 0, "a wipe loses every fitted copy")


## The report built from live units: a survivor with loot and an injury, a corpse
## carried aboard (gear converted at death), and a downed soldier left behind.
func _check_report_from_units() -> void:
	var map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(map)
	await process_frame
	map.build(load("res://scripts/map_ascii.gd").load_file(DECK))
	await process_frame
	var s = _fixture()
	var units: Array = []
	for i in 3:
		var u = load(PLAYER).instantiate()
		var rec = s.roster[i]
		rec.set_loadout(ASSAULT_RIFLE, [[VERTICAL_GRIP], [HOLO_SIGHT], [EXTENDED_MAG]][i], -1)
		u.stats = rec.to_stats()
		u.record_id = rec.id
		u.deployed_grenades = 1
		u.grenade_charges = 1
		u.name = "CampaignTest_%d" % i
		u.position = _grid.grid_to_world(ANCHOR + Vector3i(i, 0, 0))
		root.add_child(u)
		units.append(u)
	await process_frame
	var able = units[0]
	var baker = units[1]
	var charlie = units[2]
	able.add_item(load("res://scripts/item_presets.gd").make("gold_chronometer"))
	able.apply_body_part_damage(LEG_L, 999)
	baker.add_item(load("res://scripts/item_presets.gd").make("crew_tags"))
	baker.take_damage(9999)
	baker.die()
	charlie.take_damage(9999)  # downed, never carried
	able.pick_up(baker)
	var result = load("res://scripts/mission_result.gd").new(OUT_EXTRACTED)
	result.extracted_units.assign([able, baker])
	result.recovered_corpses.assign([baker])
	result.lost_units.assign([charlie])
	result.objective_complete = false
	var deployment := {"records": [s.roster[0].to_dict(), s.roster[1].to_dict(), s.roster[2].to_dict(),
		{"id": "T9"}], "grenades": [1, 1, 1, 2]}
	var report: Dictionary = _campaign_script.report_from_result(result, units, deployment)
	var by_id := {}
	for line: Dictionary in report["soldiers"]:
		by_id[line["id"]] = line
	_check(by_id["T0"]["fate"] == "survived" and by_id["T1"]["fate"] == "recovered" and by_id["T2"]["fate"] == "lost",
		"report fates from units: survived / recovered corpse / downed and left behind")
	_check(by_id["T0"]["injuries"] == [LEG_L] and by_id["T0"]["was_downed"] == false, "report: the survivor's injury")
	var baker_items: Array = by_id["T1"]["items"]
	_check(baker_items.has("weapon:%d:%d:-1" % [ASSAULT_RIFLE, HOLO_SIGHT]) and baker_items.has("grenade")
		and baker_items.has("crew_tags"), "report: the carried corpse's pack holds its converted gear %s" % [baker_items])
	_check(report["benched"] == [{"id": "T9", "grenades": 2}], "report: a deployed record with no unit is benched")
	s.apply_report(report)
	_check(s.attachment_count(HOLO_SIGHT) == 1 and s.attachment_count(EXTENDED_MAG) == 0
		and s.attachment_count(VERTICAL_GRIP) == 1, "a carried corpse's gear is recovered; the left-behind soldier's is not")
	_check(s.roster.size() == 1 and s.record("T0").injuries == [LEG_L], "only the survivor is still on the roster, injured")
	for u in units:
		u.remove_from_group("units")
		u.remove_from_group("player_units")
		u.queue_free()
	map.queue_free()
	await process_frame


func _check_game_over() -> void:
	var s = _state.new_campaign(3)
	_check(not s.is_game_over(), "a new campaign is not over")
	s.roster.resize(2)
	s.credits = 0
	_check(not s.is_game_over(), "two soldiers can always deploy, broke or not")
	s.roster.resize(1)
	var cheapest := 999999
	for c in s.recruits:
		cheapest = mini(cheapest, int(c["price"]))
	s.credits = cheapest - 1
	_check(s.is_game_over(), "one soldier and less than the cheapest recruit on offer: game over")
	s.credits = cheapest
	_check(not s.is_game_over(), "one soldier and enough for the cheapest recruit: play on")
	s.roster.clear()
	_check(s.recruits.size() < 2 or s.is_game_over(), "no soldiers and one recruit's money: game over")
	s.credits = 99999
	_check(s.recruits.size() < 2 or not s.is_game_over(), "no soldiers but money for two recruits: play on")
	s.recruits.clear()
	_check(s.is_game_over(), "nobody on the board and nobody on the roster: game over")
	var t = _fixture()
	t.credits = 0
	var report := _report(OUT_WIPED, false)
	for line: Dictionary in report["soldiers"]:
		line["fate"] = "lost"
		line["items"] = []
	var summary: Dictionary = t.apply_report(report)
	_check(summary["game_over"] == true, "a debrief that leaves no squad and no money reports game over")


func _check_save_round_trip() -> void:
	var s = _state.new_campaign(42)
	s.credits = 777
	s.attachments[HEAVY_STOCK] = 3
	s.roster[0].set_injuries([ARM_R])
	s.begin_mission(s.make_deployment([s.roster[0].id, s.roster[1].id], 0, [], 123))
	_check(s.save_to(TMP_SAVE) == OK, "saves to an injected path")
	var loaded: Dictionary = _state.load_from(TMP_SAVE)
	var t = loaded["state"]
	_check(loaded["error"] == "" and t != null, "loads it back")
	if t == null:
		return
	_check(JSON.stringify(t.to_dict()) == JSON.stringify(s.to_dict()), "round-trip: the reloaded campaign saves identically")
	_check(t.attachment_count(HEAVY_STOCK) == 3 and t.roster[0].injuries == [ARM_R] and t.credits == 777
		and not t.in_mission.is_empty(), "round-trip: stash, injuries, credits and the mission in progress")
	s.refresh_offers()
	t.refresh_offers()
	_check(JSON.stringify(t.to_dict()) == JSON.stringify(s.to_dict()),
		"round-trip: the RNG too — a reload deals the same next board")
	var text: String = FileAccess.get_file_as_string(TMP_SAVE)
	_check(text.contains("\"version\": %d" % _state.SAVE_VERSION), "the save carries its version")


func _check_version_mismatch() -> void:
	var s = _state.new_campaign(1)
	var d: Dictionary = s.to_dict()
	d["version"] = _state.SAVE_VERSION + 1
	var f := FileAccess.open(TMP_BAD, FileAccess.WRITE)
	f.store_string(JSON.stringify(d))
	f.close()
	var loaded: Dictionary = _state.load_from(TMP_BAD)
	_check(loaded["state"] == null and String(loaded["error"]).contains("version"),
		"a save of another version is refused with a reason (%s)" % loaded["error"])
	_check(FileAccess.file_exists(TMP_BAD), "...and left on disk for the player to decide about")
	f = FileAccess.open(TMP_BAD, FileAccess.WRITE)
	f.store_string("{ this is not json")
	f.close()
	loaded = _state.load_from(TMP_BAD)
	_check(loaded["state"] == null and loaded["error"] != "", "a damaged save is refused with a reason")
	_state.delete_save(TMP_BAD)
	loaded = _state.load_from(TMP_BAD)
	_check(loaded["state"] == null and loaded["error"] != "", "a missing save is reported, not invented")


func _check_stash_and_loadout() -> void:
	var s = _fixture()
	s.unlocked_ammo.assign([0])
	s.grenades = 4
	for r in s.roster:
		r.set_loadout(ASSAULT_RIFLE, [HOLO_SIGHT, VERTICAL_GRIP], PENETRATOR)
	var dep: Dictionary = s.make_deployment(["T0", "T1", "T2"], 0, [2, 2, 2], 9)
	var recs: Array = dep["records"]
	_check(recs[0]["attachments"] == [VERTICAL_GRIP, HOLO_SIGHT] and recs[1]["attachments"] == []
		and recs[2]["attachments"] == [], "one copy each: the first soldier keeps them, the others' preferences drop")
	_check(recs[0]["ammo"] == -1, "ammo that isn't unlocked falls back to Standard")
	_check(dep["grenades"] == [2, 2, 0], "grenade picks clamp to the stock in squad order (%s)" % [dep["grenades"]])
	_check(_state.auto_grenades(3, 4) == [2, 1, 1] and _state.auto_grenades(4, 3) == [1, 1, 1, 0],
		"default grenade allotment: one each, then seconds, while stock lasts")
	s.begin_mission(dep)
	_check(s.grenades == 0, "launching draws the grenades from the stock")

	# The co-op loadout split: each peer's LoadoutMenu gets the stash minus what is
	# fitted to the OTHER player's soldiers.
	var held = _campaign.deployment
	_campaign.deployment = dep
	var host_unit := FakeUnit.new()
	host_unit.stats = _record.from_dict(recs[0]).to_stats()
	var client_unit := FakeUnit.new()
	client_unit.stats = _record.from_dict(recs[1]).to_stats()
	var client_inv: Dictionary = _campaign.loadout_inventory([host_unit])
	var host_inv: Dictionary = _campaign.loadout_inventory([client_unit])
	_check(client_inv.get(HOLO_SIGHT, 0) == 0 and client_inv.get(VERTICAL_GRIP, 0) == 0
		and client_inv.get(EXTENDED_MAG, 0) == 1, "the client's share excludes the host soldier's fitted copies")
	_check(host_inv.get(HOLO_SIGHT, 0) == 1 and host_inv.get(EXTENDED_MAG, 0) == 1, "the host's share is the rest")
	_campaign.deployment = held

	# A record crosses the wire as a dict and builds the identical soldier.
	var copy = _record.from_dict(recs[0])
	var a = s.record("T0").to_stats()
	var b = copy.to_stats()
	_check(a.perception == b.perception and a.fitness == b.fitness and a.max_hp() == b.max_hp()
		and b.weapon.attachments().size() == 2, "a deployed record rebuilds the same soldier (co-op determinism)")

	var menu = load("res://scripts/loadout_menu.gd").new()
	menu.from_stash = true
	# Typed without naming PlayerUnit (that would compile it before the autoloads exist).
	menu.setup(Array([], TYPE_OBJECT, &"Node3D", load("res://scripts/player_unit.gd")))
	_check(menu.inventory.is_empty(), "LoadoutMenu fed an empty stash offers nothing (no placeholder fallback)")
	menu.free()


func _check_interrupted() -> void:
	var s = _fixture()
	s.grenades = 2
	var dep: Dictionary = s.make_deployment(["T0", "T1"], 0, [], 5)
	dep["records"][0]["attachments"] = [VERTICAL_GRIP]
	s.begin_mission(dep)
	s.save_to(TMP_SAVE)
	var t = _state.load_from(TMP_SAVE)["state"]
	var summary: Dictionary = t.book_interrupted()
	_check(t.roster.size() == 1 and t.record("T2") != null and t.attachment_count(VERTICAL_GRIP) == 0
		and t.grenades == 0 and t.in_mission.is_empty(),
		"ironman: a mission quit midway books its squad lost with their kit")
	_check((summary["notes"] as Array).size() == 1, "...and says why")


func _check_contract_offers() -> void:
	_check(_econ.payout_for(0, 1) == 500 and _econ.payout_for(1, 1) == 600 and _econ.payout_for(0, 0) == 350
		and _econ.payout_for(1, 2) == 780, "payouts by type and deck size")
	var rng := RandomNumberGenerator.new()
	rng.seed = 2024
	var o = _offer.generate(rng)
	var data = load("res://scripts/map_generator.gd").generate(o.map_seed, _offer.config_for(o.size))
	var c1 = o.build_contract(data)
	var data2 = load("res://scripts/map_generator.gd").generate(o.map_seed, _offer.config_for(o.size))
	var c2 = o.build_contract(data2)
	_check(c1 != null and c1.type == o.type and c1.payout == o.payout, "an offer builds its own contract at its price")
	_check(c2 != null and c1.target_tile == c2.target_tile and c1.item_code == c2.item_code,
		"the same offer places the same objective (every peer agrees)")
	var round_trip = _offer.from_dict(JSON.parse_string(JSON.stringify(o.to_dict())))
	_check(round_trip.map_seed == o.map_seed and round_trip.contract_seed == o.contract_seed
		and round_trip.payout == o.payout, "an offer survives JSON")


func _file_stamp(path: String) -> String:
	if not FileAccess.file_exists(path):
		return "absent"
	return "%d:%d" % [FileAccess.get_modified_time(path), FileAccess.get_file_as_bytes(path).size()]


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
