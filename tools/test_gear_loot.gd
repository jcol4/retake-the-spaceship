extends SceneTree
## Extraction plan Phase 6: gear loot (GDD §7.5 — "gear (attachments, ammo,
## consumables, weapons) can be equipped next mission"; attachments.md — "weaker
## items are the easy finds").
##
##   godot --headless --path . --script res://tools/test_gear_loot.gd
##
## Covers:
##   - the gear table: every attachment and every non-Standard ammo type, plus the
##     grenade; every entry a GEAR item that round-trips its code; Standard ammo
##     never rolled;
##   - gear tiers follow the shop's price ladder (CampaignEconomy), and value rises
##     with tier;
##   - container rolls over many seeds: about CONTAINER_GEAR_PERCENT of items are
##     gear; gear tiers come out 60/30/10 (common finds most often); the grenade is
##     about a third of tier-1 gear; a seeded roll repeats;
##   - generated decks carry gear in their crates, every code parseable, and the
##     deck generator stays a pure function of its seed;
##   - extracted gear reaches the stash through the debrief: an attachment is a
##     copy, a new ammo type unlocks, an owned one sells for its value, a grenade
##     restocks.

var _failures := 0
var _items
var _econ
var _state
var _record
const ASSAULT := 0
const OUT_EXTRACTED := 0
const KIND_GEAR := 1
const STANDARD := 0
const FMJ := 4
const PENETRATOR := 1
const SCOPE := 7
const VERTICAL_GRIP := 0


func _initialize() -> void:
	_items = load("res://scripts/item_presets.gd")
	_econ = load("res://scripts/campaign/campaign_economy.gd")
	_state = load("res://scripts/campaign/campaign_state.gd")
	_record = load("res://scripts/campaign/soldier_record.gd")

	_check_table()
	_check_tiers_follow_prices()
	_check_rolls()
	_check_decks()
	_check_debrief()

	print("")
	if _failures == 0:
		print("gear_loot: ALL CHECKS PASSED")
		quit(0)
	else:
		print("gear_loot: %d CHECK(S) FAILED" % _failures)
		quit(1)


func _check_table() -> void:
	print("-- the gear table")
	var table: Array = _items.gear_table()
	var codes := {}
	var all_ok := true
	for entry: Dictionary in table:
		var item = _items.from_code(entry["code"])
		if item == null or item.code != entry["code"] or item.kind != KIND_GEAR or not (entry["tier"] in [1, 2, 3]):
			all_ok = false
			print("    bad entry %s" % entry)
		codes[entry["code"]] = true
	_check(all_ok, "every entry is a GEAR item that round-trips its code, tiered 1-3 (%d entries)" % table.size())
	var att_ok := true
	for id in load("res://scripts/attachment_presets.gd").DATA:
		att_ok = att_ok and codes.has("attachment:%d" % id)
	_check(att_ok, "every attachment can be found")
	var ammo_ok := true
	for id in load("res://scripts/ammo_presets.gd").DATA:
		if id == STANDARD:
			ammo_ok = ammo_ok and not codes.has("ammo:%d" % id)
		else:
			ammo_ok = ammo_ok and codes.has("ammo:%d" % id)
	_check(ammo_ok, "every special ammo type can be found, Standard never")
	_check(codes.has("grenade"), "grenades can be found")
	_check(_items.from_code("ammo:%d" % PENETRATOR).value > _items.from_code("ammo:%d" % FMJ).value,
		"a rare unlock is worth more than an uncommon one")


func _check_tiers_follow_prices() -> void:
	print("-- tiers follow the shop's price ladder")
	var ladder := {}
	var ok := true
	for id in _items.ATTACHMENT_TIER:
		var tier: int = _items.ATTACHMENT_TIER[id]
		var price: int = _econ.attachment_price(id)
		if ladder.has(tier) and ladder[tier] != price:
			ok = false
		ladder[tier] = price
	_check(ok and ladder.size() == 3 and ladder[1] < ladder[2] and ladder[2] < ladder[3],
		"one price per tier, rising with it (%s)" % ladder)
	var values_ok := true
	for id in _items.ATTACHMENT_TIER:
		var tier: int = _items.ATTACHMENT_TIER[id]
		values_ok = values_ok and _items.make_attachment(id).value == _items.ATTACHMENT_VALUE_BY_TIER[tier]
	_check(values_ok and _items.ATTACHMENT_VALUE_BY_TIER[1] < _items.ATTACHMENT_VALUE_BY_TIER[3],
		"an attachment item's value follows its tier")
	var ammo_ok := true
	for id in _items.AMMO_TIER:
		ammo_ok = ammo_ok and _items.AMMO_TIER[id] >= 2 and _econ.ammo_price(id) >= 150
	_check(ammo_ok, "ammo unlocks are never tier 1 (they fit the whole squad for good)")


func _check_rolls() -> void:
	print("-- container rolls")
	var rng := RandomNumberGenerator.new()
	rng.seed = 2468
	var items := 0
	var gear := 0
	var tiers := [0, 0, 0, 0]
	var t1 := 0
	var t1_grenades := 0
	var scope := 0
	var grip := 0
	for i in 6000:
		for code in _items.roll_container(rng):
			items += 1
			var item = _items.from_code(code)
			if item == null:
				continue
			if item.kind == KIND_GEAR:
				gear += 1
				var tier := _tier_of(code)
				tiers[tier] += 1
				if tier == 1:
					t1 += 1
					if code == "grenade":
						t1_grenades += 1
				if code == "attachment:%d" % SCOPE:
					scope += 1
				if code == "attachment:%d" % VERTICAL_GRIP:
					grip += 1
	var share := float(gear) / items
	_check(absf(share - _items.CONTAINER_GEAR_PERCENT / 100.0) < 0.02,
		"%.1f%% of container items are gear (want %d%%)" % [share * 100.0, _items.CONTAINER_GEAR_PERCENT])
	var p1 := float(tiers[1]) / gear
	var p2 := float(tiers[2]) / gear
	var p3 := float(tiers[3]) / gear
	_check(absf(p1 - 0.6) < 0.03 and absf(p2 - 0.3) < 0.03 and absf(p3 - 0.1) < 0.02,
		"gear tiers %.0f/%.0f/%.0f (want 60/30/10)" % [p1 * 100, p2 * 100, p3 * 100])
	var gw: float = _items.GRENADE_WEIGHT
	var want := gw / (gw + 6.0)
	_check(absf(float(t1_grenades) / t1 - want) < 0.03,
		"grenades are %.0f%% of tier-1 gear (want %.0f%%)" % [100.0 * t1_grenades / t1, want * 100])
	_check(grip > scope * 2, "weaker items are the easy finds: Vertical Grip %d vs Scope %d" % [grip, scope])
	var a := RandomNumberGenerator.new()
	a.seed = 31
	var b := RandomNumberGenerator.new()
	b.seed = 31
	var same := true
	for i in 200:
		same = same and _items.roll_container(a) == _items.roll_container(b)
	_check(same, "a seeded roll repeats (co-op decks and saved seeds rely on it)")


func _tier_of(code: String) -> int:
	for entry: Dictionary in _items.gear_table():
		if entry["code"] == code:
			return entry["tier"]
	return 0


func _check_decks() -> void:
	print("-- generated decks")
	var gen = load("res://scripts/map_generator.gd")
	var decks_with_gear := 0
	var gear := 0
	var parse_ok := true
	const DECKS := 60
	for s in range(1, DECKS + 1):
		var data = gen.generate(s)
		var here := 0
		for spot in data.containers:
			for code in spot.items:
				var item = _items.from_code(code)
				if item == null:
					parse_ok = false
				elif item.kind == KIND_GEAR:
					here += 1
		gear += here
		if here > 0:
			decks_with_gear += 1
	_check(parse_ok, "every crate code on %d decks parses" % DECKS)
	_check(decks_with_gear >= DECKS * 3 / 4,
		"most decks carry gear (%d/%d, %.1f pieces per deck)" % [decks_with_gear, DECKS, float(gear) / DECKS])
	var x = gen.generate(17)
	var y = gen.generate(17)
	var same: bool = x.containers.size() == y.containers.size()
	for i in mini(x.containers.size(), y.containers.size()):
		same = same and x.containers[i].pos == y.containers[i].pos and x.containers[i].items == y.containers[i].items
	_check(same, "a deck's crates are a pure function of its seed")


func _check_debrief() -> void:
	print("-- extracted gear reaches the stash")
	var s = _state.new_campaign(5)
	s.roster.clear()
	s.roster.append(_record.roll(ASSAULT, "Able", "T0"))
	s.attachments = {}
	s.unlocked_ammo.assign([STANDARD, FMJ])
	s.grenades = 0
	s.credits = 100
	var report := {
		"outcome": OUT_EXTRACTED, "objective_complete": false, "contract": {},
		"soldiers": [{
			"id": "T0", "fate": "survived",
			"weapon": {"id": 0, "attachments": [], "ammo": -1},
			"grenades_left": 0,
			"items": ["attachment:%d" % SCOPE, "ammo:%d" % PENETRATOR, "ammo:%d" % FMJ, "grenade"],
			"injuries": [], "was_downed": false,
		}],
	}
	var summary: Dictionary = s.apply_report(report)
	_check(s.attachment_count(SCOPE) == 1, "a looted Scope is a stash copy")
	_check(s.unlocked_ammo.has(PENETRATOR), "a looted Penetrator crate unlocks the type")
	var fmj_value: int = _items.from_code("ammo:%d" % FMJ).value
	_check(s.credits == 100 + fmj_value and summary["sale_total"] == fmj_value,
		"a looted FMJ crate (already owned) sells for its value %d (credits %d)" % [fmj_value, s.credits])
	_check(s.grenades == 1, "a looted grenade restocks")


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
