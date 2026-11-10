extends SceneTree
## Per-player co-op campaigns (MULTIPLAYER_PLAN.md): every player brings 1–2
## soldiers from their OWN save, and the mission's result is booked back into each
## save separately.
##
##   godot --headless --path . --script res://tools/test_coop_campaign.gd
##
## Covers, on plain CampaignStates and CoopRules (no network):
##   - pick packages: 1–2 soldiers, clamped to the player's own stash and stock;
##   - the launch blocker (contract, picks, Ready, squad size);
##   - the merged deployment (owners, per-player stashes, scale, mission id);
##   - booking out: the host's `in_mission` is co-op (resumable), a guest's soldiers
##     go `away` and are LOCKED (deploy, treat), grenades leave each player's stock;
##   - the report split: each player's own soldiers, payout shared evenly among
##     every player launched (a wiped one included), loot to whoever carried it,
##     partners' fates as party lines; applying clears `away`, counts a mission,
##     re-rolls the boards;
##   - pending reports: filed, replaced, acked; a late report after a write-off is
##     refused; a report is applied once only;
##   - write-off: soldiers lost with their kit, no mission counted;
##   - game over still counts locked soldiers;
##   - save v1 -> v2 migration, and `away`/`pending_reports` surviving the file.
##
## Scripts are load()ed and locals stay untyped: a --script tool is compiled before
## the class registry exists (see test_campaign.gd). Never touches the player's slot.

const TMP_SAVE := "user://test_coop_campaign_tmp.json"
const REAL_SAVE := "user://campaign.json"
const ASSAULT := 0
const VERTICAL_GRIP := 0
const SUPPRESSOR := 3
const HOLO_SIGHT := 6
const HEAVY_STOCK := 12
const ASSAULT_RIFLE := 0
const OUT_EXTRACTED := 0
const OUT_WIPED := 1
const LEG_L := 4

var _failures := 0
var _state
var _record
var _econ
var _rules


func _initialize() -> void:
	await process_frame
	_state = load("res://scripts/campaign/campaign_state.gd")
	_record = load("res://scripts/campaign/soldier_record.gd")
	_econ = load("res://scripts/campaign/campaign_economy.gd")
	_rules = load("res://scripts/net/coop_rules.gd")
	var real_before := _file_stamp(REAL_SAVE)

	_check_picks()
	_check_launch_blocker()
	var flow := _check_merge_and_book()
	_check_split_and_apply(flow)
	_check_pending()
	_check_write_off()
	_check_game_over_counts_away()
	_check_save_migration()
	_check_scale()

	_check(_file_stamp(REAL_SAVE) == real_before, "the player's slot (%s) is untouched" % REAL_SAVE)
	_state.delete_save(TMP_SAVE)
	print("")
	if _failures == 0:
		print("coop campaign: ALL CHECKS PASSED")
		quit(0)
	else:
		print("coop campaign: %d CHECK(S) FAILED" % _failures)
		quit(1)


## A save with soldiers T0..T3 (ids per save, so two players' saves collide on
## purpose), one Vertical Grip, `grenades` in stock.
func _save(prefix: String, grenades: int = 4):
	var s = _state.new_campaign(prefix.hash() & 0xffff)
	s.roster.clear()
	for i in 4:
		s.roster.append(_record.roll(ASSAULT, "%s%d" % [prefix, i], "T%d" % i))
	s.attachments = {VERTICAL_GRIP: 1}
	s.unlocked_ammo.assign([0])
	s.grenades = grenades
	s.credits = 1000
	return s


func _member(display_name: String, pick: Dictionary, ready: bool) -> Dictionary:
	return {"name": display_name, "peer": 1, "connected": true, "ready": ready, "pick": pick, "roster": [], "vote": -1}


func _check_picks() -> void:
	var s = _save("Ann")
	_check(s.pick_blocker([]) != "", "a player must bring at least one soldier")
	_check(s.pick_blocker(["T0", "T1", "T2"]) != "", "a player brings at most two soldiers")
	_check(s.pick_blocker(["T0"]) == "" and s.pick_blocker(["T0", "T1"]) == "", "one or two soldiers is a pick")
	_check(s.pick_blocker(["T0", "T0"]) != "" and s.pick_blocker(["nobody"]) != "", "duplicates and strangers are refused")
	# Both soldiers want the one Vertical Grip: the second loses it (squad order).
	s.record("T0").attachment_ids.assign([VERTICAL_GRIP])
	s.record("T1").attachment_ids.assign([VERTICAL_GRIP])
	var pick: Dictionary = s.make_pick(["T0", "T1"], [2, 2])
	var recs: Array = pick["records"]
	_check(recs.size() == 2 and recs[0]["attachments"] == [VERTICAL_GRIP] and recs[1]["attachments"] == [],
		"a pick clamps fitted copies to the player's own stash")
	_check(pick["grenades"] == [2, 2], "a pick's grenades come from the player's own stock")
	var poor = _save("Bea", 1)
	_check(poor.make_pick(["T0", "T1"], [2, 2])["grenades"] == [1, 0], "...clamped to that stock")
	_check(pick["attachments"] == {VERTICAL_GRIP: 1} and pick["ammo"] == [0], "a pick carries the player's stash for the loadout screen")


func _check_launch_blocker() -> void:
	var a = _save("Ann")
	var b = _save("Bea")
	var members := {
		"A": _member("Ann", a.make_pick(["T0", "T1"], []), false),
		"B": _member("Bea", b.make_pick(["T0"], []), false),
	}
	var order := ["A", "B"]
	_check(_rules.launch_blocker(order, members, -1, 3) == "Choose a contract", "no contract, no launch")
	_check(String(_rules.launch_blocker(order, members, 0, 3)).begins_with("Waiting for Bea"), "a guest must ready up")
	members["B"]["ready"] = true
	_check(_rules.launch_blocker(order, members, 0, 3) == "", "everyone ready with a pick: launch")
	members["B"]["pick"] = {}
	_check(String(_rules.launch_blocker(order, members, 0, 3)).begins_with("Bea must pick"), "a guest with no pick blocks")
	var solo := {"A": _member("Ann", a.make_pick(["T0"], []), false)}
	_check(_rules.launch_blocker(["A"], solo, 0, 3).contains("at least 2"), "a party squad still needs two soldiers")


## A and B launch together: A (host) brings T0 and T1, B brings T0 and T1 — the
## same ids on purpose, told apart by owner.
func _check_merge_and_book() -> Dictionary:
	var a = _save("Ann")
	var b = _save("Bea")
	var members := {
		"A": _member("Ann", a.make_pick(["T0", "T1"], [1, 1]), true),
		"B": _member("Bea", b.make_pick(["T0", "T1"], [2, 0]), true),
	}
	var offer: Dictionary = a.contracts[0].to_dict()
	var d: Dictionary = _rules.merge_deployment(["A", "B"], members, offer, 77, "m1")
	var owners := []
	for r in d["records"]:
		owners.append(r["owner"])
	_check(owners == ["A", "A", "B", "B"], "the merged squad is in lobby order, each record tagged with its owner")
	_check(d["grenades"] == [1, 1, 2, 0], "each soldier keeps their owner's grenade allotment")
	_check(d["owners"].has("A") and d["owners"].has("B") and d["owners"]["B"]["attachments"] == {VERTICAL_GRIP: 1},
		"every player's own stash rides along for their loadout screen")
	_check(d["coop"]["mission_id"] == "m1" and d["coop"]["host_key"] == "A" and d["coop"]["players"] == ["A", "B"],
		"the deployment names its mission, host and players")
	_check(is_equal_approx(float(d["scale"]), 1.0), "four soldiers: no scaling")
	_check(d["deck"] == a.contracts[0].deck(), "the deck is the host's chosen contract's")

	a.begin_coop(d, "A", true)
	b.begin_coop(d, "B", false)
	_check(a.is_hosting_coop() and a.in_mission["coop"]["mission_id"] == "m1" and a.in_mission["records"].size() == 2,
		"the host books its own two out as a co-op mission (resumable)")
	_check(a.grenades == 2 and b.grenades == 2, "each player's grenades leave their own stock (%d, %d)" % [a.grenades, b.grenades])
	_check(b.in_mission.is_empty() and b.away.size() == 1 and b.away[0]["host_name"] == "Ann",
		"a guest's soldiers go away, not into in_mission")
	_check(b.is_away("T0") and b.is_away("T1") and not b.is_away("T2"), "exactly the guest's deployed soldiers are locked")
	_check(b.deploy_blocker(["T0", "T2"], 0).contains("deployed with Ann"), "a locked soldier cannot be deployed")
	b.record("T0").injuries.assign([LEG_L])
	b.medical = 5
	_check(b.treat("T0", LEG_L).contains("deployed"), "a locked soldier cannot be treated")
	_check(b.available_roster().size() == 2, "the rest of the guest's roster plays on")
	# Through the file and back.
	b.save_to(TMP_SAVE)
	var loaded: Dictionary = _state.load_from(TMP_SAVE)
	var b2 = loaded["state"]
	_check(loaded["error"] == "" and b2.is_away("T0") and b2.away[0]["mission_id"] == "m1",
		"the away entry survives the save file")
	return {"a": a, "b": b2, "d": d}


## The report: A's T0 extracted with a valuable; A's T1 lost; B's T0 extracted
## carrying a looted attachment; B's T1 extracted. Objective done, 600 cr.
func _report(owner_a: String, owner_b: String, objective: bool = true) -> Dictionary:
	return {
		"outcome": OUT_EXTRACTED, "objective_complete": objective,
		"contract": {"type": 1, "target": Vector3i.ZERO, "item": "", "payout": 600, "place_nest": true},
		"soldiers": [
			{"id": "T0", "owner": owner_a, "name": "Ann0", "class": "Assault", "fate": "survived",
				"weapon": {"id": ASSAULT_RIFLE, "attachments": [VERTICAL_GRIP], "ammo": -1},
				"grenades_left": 1, "items": ["fusion_cell"], "injuries": [], "was_downed": false},
			{"id": "T1", "owner": owner_a, "name": "Ann1", "class": "Assault", "fate": "lost",
				"weapon": {"id": ASSAULT_RIFLE, "attachments": [], "ammo": -1},
				"grenades_left": 0, "items": [], "injuries": [], "was_downed": true},
			{"id": "T0", "owner": owner_b, "name": "Bea0", "class": "Assault", "fate": "survived",
				"weapon": {"id": ASSAULT_RIFLE, "attachments": [VERTICAL_GRIP], "ammo": -1},
				"grenades_left": 2, "items": ["attachment:%d" % HEAVY_STOCK], "injuries": [LEG_L], "was_downed": false},
			{"id": "T1", "owner": owner_b, "name": "Bea1", "class": "Assault", "fate": "survived",
				"weapon": {"id": ASSAULT_RIFLE, "attachments": [], "ammo": -1},
				"grenades_left": 0, "items": [], "injuries": [], "was_downed": false},
		],
		"benched": [],
		"rival_notes": [],
	}


func _check_split_and_apply(flow: Dictionary) -> void:
	var a = flow["a"]
	var b = flow["b"]
	var d: Dictionary = flow["d"]
	var split: Dictionary = _rules.split_report(_report("A", "B"), d)
	_check(split.size() == 2 and split["A"]["soldiers"].size() == 2 and split["B"]["soldiers"].size() == 2,
		"one report per player, each with only their own soldiers")
	_check(split["A"]["payout_divisor"] == 2 and split["B"]["mission_id"] == "m1", "each report carries the share and the mission")
	var party_names := []
	for l in split["A"]["party"]:
		party_names.append(l["name"])
	_check(party_names == ["Bea0", "Bea1"], "the host's party lines are the guest's soldiers")

	var a_credits: int = a.credits
	var a_summary: Dictionary = a.apply_report(split["A"])
	_check(a_summary["payout"] == 300 and a_summary["payout_total"] == 600, "the host is paid half the contract (300 of 600)")
	_check(a.credits == a_credits + 300 + 200, "...plus the valuable its own soldier carried out (fusion cell 200)")
	_check(a.record("T0") != null and a.record("T1") == null and a.in_mission.is_empty(),
		"the host books its own fates and closes its mission")
	_check(a_summary.has("party") and a_summary["party"].size() == 2, "the host's debrief lists the partners' soldiers")

	var b_credits: int = b.credits
	var b_played: int = b.missions_played
	var b_offers: String = JSON.stringify(b.contracts.map(func(o): return o.to_dict()))
	_check(b.accepts_report(split["B"]), "the guest accepts the report for the mission it is away on")
	var b_summary: Dictionary = b.apply_report(split["B"])
	_check(b_summary["payout"] == 300 and b.credits == b_credits + 300, "the guest is paid the other half")
	_check(b.attachment_count(HEAVY_STOCK) == 1, "loot goes to the save of the soldier who carried it (Heavy Stock -> guest)")
	_check(b.record("T0").injuries == [LEG_L] and b.record("T0").missions_survived == 1, "the guest's survivor comes home with their injury")
	_check(b.away.is_empty() and not b.is_away("T0"), "the report clears the away entry and unlocks the soldiers")
	_check(b.missions_played == b_played + 1, "a co-op mission counts for the guest")
	_check(JSON.stringify(b.contracts.map(func(o): return o.to_dict())) != b_offers, "the guest's boards re-roll")
	_check(not b.accepts_report(split["B"]), "the same report is never applied twice")

	# Everyone launched shares, a wiped player included.
	var wiped := _report("A", "B")
	for s: Dictionary in wiped["soldiers"]:
		if s["owner"] == "B":
			s["fate"] = "lost"
	var w: Dictionary = _rules.split_report(wiped, d)
	_check(w["B"]["payout_divisor"] == 2 and w["A"]["payout_divisor"] == 2,
		"a wiped player still takes their share (divisor counts every player launched)")


func _check_pending() -> void:
	var host = _save("Ann")
	var r1 := {"mission_id": "m1", "soldiers": []}
	var r1b := {"mission_id": "m1", "soldiers": [{"id": "T0"}]}
	var r2 := {"mission_id": "m2", "soldiers": []}
	host.add_pending_report("B", r1)
	host.add_pending_report("B", r1b)
	host.add_pending_report("B", r2)
	_check(host.pending_reports["B"].size() == 2 and host.pending_reports["B"][0]["mission_id"] == "m1"
		and host.pending_reports["B"][0]["soldiers"].size() == 1, "a re-filed report replaces its earlier copy")
	host.save_to(TMP_SAVE)
	var reloaded = _state.load_from(TMP_SAVE)["state"]
	_check(reloaded.pending_reports.has("B") and reloaded.pending_reports["B"].size() == 2, "owed reports survive the save file")
	reloaded.ack_pending_report("B", "m1")
	_check(reloaded.pending_reports["B"].size() == 1, "an ack drops that mission's report")
	reloaded.ack_pending_report("B", "m2")
	_check(not reloaded.pending_reports.has("B"), "...and the player's entry once nothing is owed")


func _check_write_off() -> void:
	var a = _save("Ann")
	var b = _save("Bea")
	b.record("T0").attachment_ids.assign([VERTICAL_GRIP])
	var members := {
		"A": _member("Ann", a.make_pick(["T0"], []), true),
		"B": _member("Bea", b.make_pick(["T0", "T1"], [1, 1]), true),
	}
	var d: Dictionary = _rules.merge_deployment(["A", "B"], members, a.contracts[0].to_dict(), 5, "m9")
	b.begin_coop(d, "B", false)
	var played: int = b.missions_played
	var summary: Dictionary = b.write_off("m9")
	_check(b.record("T0") == null and b.record("T1") == null and b.away.is_empty(),
		"a write-off books the away soldiers lost and clears the entry")
	_check(b.attachment_count(VERTICAL_GRIP) == 0, "...with the kit they took")
	_check(b.missions_played == played, "a write-off is not a mission played")
	_check(str(summary["notes"]).contains("Written off"), "the write-off says so")
	var late: Dictionary = _rules.split_report(_report("A", "B"), d)["B"]
	_check(not b.accepts_report(late), "a report arriving after the write-off is refused")
	_check(b.write_off("m9").is_empty(), "writing off twice does nothing")


func _check_game_over_counts_away() -> void:
	var b = _save("Bea", 0)
	b.roster.resize(2)
	b.credits = 0
	b.recruits.clear()
	var members := {
		"A": _member("Ann", _save("Ann").make_pick(["T0"], []), true),
		"B": _member("Bea", b.make_pick(["T0", "T1"], []), true),
	}
	b.begin_coop(_rules.merge_deployment(["A", "B"], members, b.contracts[0].to_dict(), 5, "m5"), "B", false)
	_check(b.available_roster().is_empty() and not b.is_game_over(),
		"locked soldiers still count: a save with everyone away is not game over")


func _check_save_migration() -> void:
	var s = _save("Old")
	var d: Dictionary = s.to_dict()
	d["version"] = 1
	d.erase("away")
	d.erase("pending_reports")
	var f := FileAccess.open(TMP_SAVE, FileAccess.WRITE)
	f.store_string(JSON.stringify(d))
	f.close()
	var loaded: Dictionary = _state.load_from(TMP_SAVE)
	_check(loaded["error"] == "" and loaded["state"].away.is_empty() and loaded["state"].pending_reports.is_empty()
		and loaded["state"].roster.size() == 4, "a version-1 save loads as version 2 with nothing away")
	_check(loaded["state"].to_dict()["version"] == 2, "...and saves as version 2")


func _check_scale() -> void:
	_check(is_equal_approx(_econ.squad_scale(2), 1.0) and is_equal_approx(_econ.squad_scale(4), 1.0),
		"a solo-sized squad is not scaled")
	_check(is_equal_approx(_econ.squad_scale(6), 1.5) and is_equal_approx(_econ.squad_scale(8), 2.0),
		"six soldiers 1.5x, eight 2x")
	_check(_econ.scaled_payout(600, 1.5) == 900 and _econ.scaled_payout(650, 2.0) == 1300, "payouts scale and round")
	_check(_econ.COOP_MAX_SQUAD == 8, "four players of two: eight soldiers at most")


func _file_stamp(path: String) -> String:
	if not FileAccess.file_exists(path):
		return "absent"
	return "%d:%d" % [FileAccess.get_modified_time(path), FileAccess.get_file_as_bytes(path).size()]


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
