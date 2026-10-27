class_name ItemPresets
extends RefCounted
## The item roster (GDD §7.5, extraction plan 3.1), a table like AttachmentPresets,
## plus the codec between an ItemData and its wire CODE.
##
## THE CODE IS THE ITEM. Everything that crosses the network or leaves a mission
## carries codes, never ItemData objects: `Unit.inventory_codes` (replicated),
## LootManager's container mirror, MissionResult.loot. So every item an inventory
## can hold must round-trip `from_code(item.code)` exactly, and a code that does
## not parse yields null rather than a guess — a code can arrive from a peer.
##
## Code grammar (no spaces or commas, so a `[loot]` line in a deck file can list
## several separated by spaces):
##   <valuable id>                      "scrap_electronics", "fusion_cell"
##   <objective id>                     "data_core"
##   salvage:<points>                   "salvage:4" — one robot's worth
##   weapon:<weapon id>:<att.att>:<ammo id>   "weapon:0:6.9:-1" — attachments
##                                      '.'-joined, '-' for none; ammo -1 = Standard
##   grenade
##   attachment:<attachment id>         container gear (Phase 6)
##   ammo:<ammo id>                     container gear (Phase 6) — an ammo-type unlock

# --- Valuables -----------------------------------------------------------------

## Value tiers, cheapest first. "Weaker items are the easy finds" (attachments.md)
## applies to valuables too: a container rolls tier 1 most of the time, and a
## tier-3 find is what makes a detour into an unexplored room worth it.
const TIER_COMMON := 1
const TIER_UNCOMMON := 2
const TIER_RARE := 3

## PLACEHOLDER credit values (decisions log, Phase 3). Read as "a tier-1 find is
## pocket change, a tier-3 find is a good fraction of a contract's payout"
## (Contract.PLACEHOLDER_PAYOUT is 500–600) — so loot is worth a detour but never
## worth more than the objective. Phase 4 tunes these against real prices.
const VALUABLES := {
	# Tier 1 — common, 15–25 cr.
	"sealed_rations": {"display_name": "Sealed Rations", "tier": TIER_COMMON, "value": 15},
	"scrap_electronics": {"display_name": "Scrap Electronics", "tier": TIER_COMMON, "value": 20},
	"crew_tags": {"display_name": "Crew Tags", "tier": TIER_COMMON, "value": 25},
	# Tier 2 — uncommon, 60–90 cr.
	"encrypted_drive": {"display_name": "Encrypted Drive", "tier": TIER_UNCOMMON, "value": 70},
	"pharma_case": {"display_name": "Pharma Case", "tier": TIER_UNCOMMON, "value": 85},
	# Tier 3 — rare, 160–240 cr.
	"gold_chronometer": {"display_name": "Gold Chronometer", "tier": TIER_RARE, "value": 160},
	"fusion_cell": {"display_name": "Fusion Cell", "tier": TIER_RARE, "value": 200},
	"prototype_chip": {"display_name": "Prototype Chip", "tier": TIER_RARE, "value": 240},
}

## Salvage (GDD §11.9): a VALUABLE whose value scales with the robot it came off —
## `CerberusUnit.salvage_value` points, each worth this many credits. One item per
## wreck rather than one per point, so a Securus (8 points) is one heavy slot, not
## eight.
const SALVAGE_ID := "salvage"
const SALVAGE_CREDITS_PER_POINT := 10

# --- Objective items --------------------------------------------------------------

## Retrieve contract items (GDD §7.5). Flavour only — they all play the same.
const OBJECTIVES := {
	"data_core": {"display_name": "Data Core"},
	"flight_recorder": {"display_name": "Flight Recorder"},
	"sample_case": {"display_name": "Sample Case"},
}

# --- Gear -----------------------------------------------------------------------

const WEAPON_ID := "weapon"
const GRENADE_ID := "grenade"
const ATTACHMENT_ID := "attachment"
const AMMO_ID := "ammo"

## PLACEHOLDER resale prices for gear (decisions log). Gear is for equipping, not
## selling (GDD §7.5), but Phase 4's debrief has to put SOME number on a looted
## rifle, and zero would make carrying one out a strictly worse use of a slot than
## a tin of rations.
const WEAPON_BASE_VALUE := 40
const WEAPON_VALUE_PER_ATTACHMENT := 15
const GRENADE_VALUE := 10
## Fallbacks for an attachment or ammo type with no tier below (none today but
## Standard ammo, which is never rolled).
const ATTACHMENT_VALUE := 15
const AMMO_VALUE := 10

## Gear tiers (extraction plan Phase 6: "using attachments' tiers — weaker items are
## the easy finds", attachments.md). The SAME ladder the shop prices on
## (CampaignEconomy.ATTACHMENT_PRICE 90 / 140 / 200; tools/test_gear_loot.gd holds
## the two in step): a flat +3/+5 or a magazine tweak is tier 1, a sight or a
## suppressor that changes how a soldier plays is tier 2, and the three that buy
## an AP or darkness-ignoring are tier 3. Rolled with the same tier weights as
## valuables, so a Scope turns up about as often as a Fusion Cell.
const ATTACHMENT_TIER := {
	AttachmentPresets.AttachmentId.VERTICAL_GRIP: TIER_COMMON,
	AttachmentPresets.AttachmentId.MUZZLE_BRAKE: TIER_COMMON,
	AttachmentPresets.AttachmentId.HEAVY_STOCK: TIER_COMMON,
	AttachmentPresets.AttachmentId.EXTENDED_MAG: TIER_COMMON,
	AttachmentPresets.AttachmentId.LIGHT_MAG: TIER_COMMON,
	AttachmentPresets.AttachmentId.SAWED_OFF_STOCK: TIER_COMMON,
	AttachmentPresets.AttachmentId.ANGLED_GRIP: TIER_UNCOMMON,
	AttachmentPresets.AttachmentId.LASER_SIGHT: TIER_UNCOMMON,
	AttachmentPresets.AttachmentId.SUPPRESSOR: TIER_UNCOMMON,
	AttachmentPresets.AttachmentId.HOLO_SIGHT: TIER_UNCOMMON,
	AttachmentPresets.AttachmentId.DRUM_MAG: TIER_UNCOMMON,
	AttachmentPresets.AttachmentId.ERGO_STOCK: TIER_UNCOMMON,
	AttachmentPresets.AttachmentId.LONG_BARREL: TIER_RARE,
	AttachmentPresets.AttachmentId.SCOPE: TIER_RARE,
	AttachmentPresets.AttachmentId.THERMAL_SIGHT: TIER_RARE,
}
## Ammo-type unlocks (AmmoPresets — per TYPE, so one find fits the whole squad for
## good, and the shop charges 150–250 for one). Never tier 1: an unlock outlasts
## any attachment copy. Penetrator, the answer to armor, is the rare one. Standard
## is never loot — everyone has it.
const AMMO_TIER := {
	AmmoPresets.AmmoId.FMJ: TIER_UNCOMMON,
	AmmoPresets.AmmoId.SUBSONIC: TIER_UNCOMMON,
	AmmoPresets.AmmoId.HOLLOW_POINT: TIER_UNCOMMON,
	AmmoPresets.AmmoId.SLUG: TIER_UNCOMMON,
	AmmoPresets.AmmoId.PENETRATOR: TIER_RARE,
}
## A grenade is the commonest find of all: tier 1, and GRENADE_WEIGHT entries'
## worth in that tier's draw (a third of tier-1 gear), because the squad throws
## them and has to restock (CampaignEconomy.GRENADE_PRICE).
const GRENADE_TIER := TIER_COMMON
const GRENADE_WEIGHT := 3
## What gear is WORTH, by tier (index = tier): about a third of the shop price —
## what a fence would give. Gear is not sold at the debrief (an attachment goes to
## the stash, an unlock unlocks), so this is the loot panel's signal and the
## `--auto` looter's "most valuable first", plus the resale of an ammo type the
## campaign already owns (CampaignState._bank_items).
const ATTACHMENT_VALUE_BY_TIER: Array[int] = [0, 30, 45, 65]
const AMMO_VALUE_BY_TIER: Array[int] = [0, 30, 50, 80]

# --- Rolls ------------------------------------------------------------------------

## Container tier weights, common -> rare (percent). A rare find in roughly one
## container in ten.
const CONTAINER_TIER_WEIGHTS: Array[int] = [60, 30, 10]
## Items per container, weighted by repetition: mostly one or two, sometimes three.
const CONTAINER_ITEM_COUNTS: Array[int] = [1, 1, 2, 2, 2, 3]
## Percent of container items that are GEAR rather than a valuable (extraction plan
## Phase 6). One in four: about one gear find per two crates, so a deck's worth of
## crates (~7) turns up three or four pieces — most runs bring home something to
## fit — while the valuables still carry the credits.
const CONTAINER_GEAR_PERCENT := 25
## A merc's pockets (MercPresets.roll_inventory): poorer odds than a container —
## they are carrying what they found on the way in, not what was locked up.
const MERC_TIER_WEIGHTS: Array[int] = [75, 20, 5]


static func make(id: String) -> ItemData:
	if VALUABLES.has(id):
		var v: Dictionary = VALUABLES[id]
		return _item(id, v["display_name"], ItemData.Kind.VALUABLE, v["value"], {}, id, v["tier"])
	if OBJECTIVES.has(id):
		return _item(id, OBJECTIVES[id]["display_name"], ItemData.Kind.OBJECTIVE, 0, {}, id)
	if id == GRENADE_ID:
		return make_grenade()
	push_warning("ItemPresets: unknown item id '%s'" % id)
	return null


static func make_salvage(points: int) -> ItemData:
	points = maxi(1, points)
	return _item(SALVAGE_ID, "Salvage (%d)" % points, ItemData.Kind.VALUABLE,
		points * SALVAGE_CREDITS_PER_POINT, {"points": points}, "%s:%d" % [SALVAGE_ID, points])


## A whole weapon as ONE item: the gun plus everything fitted to it and the ammo
## type loaded (extraction plan 3.2 — "weapon with attachments as one item").
## `weapon_from_item` rebuilds it for Phase 6's stash.
static func make_weapon(weapon_id: int, attachment_ids: PackedInt32Array = PackedInt32Array(), ammo_id: int = -1) -> ItemData:
	if not WeaponPresets.DATA.has(weapon_id):
		return null
	var ids := PackedInt32Array()
	var names := PackedStringArray()
	for aid in attachment_ids:
		if AttachmentPresets.DATA.has(aid) and AttachmentPresets.fits(aid, weapon_id) and not ids.has(aid):
			ids.append(aid)
			names.append(AttachmentPresets.DATA[aid]["display_name"])
	ids.sort()
	if ammo_id == AmmoPresets.AmmoId.STANDARD or not AmmoPresets.DATA.has(ammo_id) \
			or not AmmoPresets.fits(ammo_id, weapon_id):
		ammo_id = -1
	if ammo_id >= 0:
		names.append(AmmoPresets.DATA[ammo_id]["display_name"])
	var display: String = WeaponPresets.DATA[weapon_id]["display_name"]
	if not names.is_empty():
		display += " (%s)" % ", ".join(names)
	var att_parts := PackedStringArray()
	for aid in ids:
		att_parts.append(str(aid))
	var att_text := "-" if ids.is_empty() else ".".join(att_parts)
	return _item(WEAPON_ID, display, ItemData.Kind.GEAR,
		WEAPON_BASE_VALUE + WEAPON_VALUE_PER_ATTACHMENT * ids.size(),
		{"gear": WEAPON_ID, "weapon_id": weapon_id, "attachments": ids, "ammo": ammo_id},
		"%s:%d:%s:%d" % [WEAPON_ID, weapon_id, att_text, ammo_id])


## The item for a weapon a unit is carrying, or null for one that is not a roster
## gun (an alien's inline claws, a robot's built-in weapon) — those cannot be
## looted, there is nothing to take.
static func make_weapon_from(weapon: WeaponData) -> ItemData:
	if weapon == null or not WeaponPresets.DATA.has(weapon.id):
		return null
	var ids := PackedInt32Array()
	for a in weapon.attachments():
		ids.append(a.id)
	return make_weapon(weapon.id, ids, weapon.ammo.id if weapon.ammo != null else -1)


static func make_grenade() -> ItemData:
	return _item(GRENADE_ID, "Grenade", ItemData.Kind.GEAR, GRENADE_VALUE, {"gear": GRENADE_ID}, GRENADE_ID)


static func make_attachment(attachment_id: int) -> ItemData:
	if not AttachmentPresets.DATA.has(attachment_id):
		return null
	return _item(ATTACHMENT_ID, AttachmentPresets.DATA[attachment_id]["display_name"], ItemData.Kind.GEAR,
		ATTACHMENT_VALUE_BY_TIER[ATTACHMENT_TIER[attachment_id]] if ATTACHMENT_TIER.has(attachment_id) else ATTACHMENT_VALUE,
		{"gear": ATTACHMENT_ID, "attachment_id": attachment_id},
		"%s:%d" % [ATTACHMENT_ID, attachment_id])


static func make_ammo(ammo_id: int) -> ItemData:
	if not AmmoPresets.DATA.has(ammo_id):
		return null
	return _item(AMMO_ID, AmmoPresets.DATA[ammo_id]["display_name"], ItemData.Kind.GEAR,
		AMMO_VALUE_BY_TIER[AMMO_TIER[ammo_id]] if AMMO_TIER.has(ammo_id) else AMMO_VALUE,
		{"gear": AMMO_ID, "ammo_id": ammo_id}, "%s:%d" % [AMMO_ID, ammo_id])


## Rebuilds a WEAPON gear item into the WeaponData it was (Phase 6: into the stash,
## then onto a soldier). Null for any other item.
static func weapon_from_item(item: ItemData) -> WeaponData:
	if item == null or item.payload.get("gear", "") != WEAPON_ID:
		return null
	return WeaponPresets.make(item.payload["weapon_id"], item.payload["attachments"], item.payload["ammo"])


# --- Codec ------------------------------------------------------------------------


## The item a code names, or null if it names nothing (see the header).
static func from_code(code: String) -> ItemData:
	if VALUABLES.has(code) or OBJECTIVES.has(code) or code == GRENADE_ID:
		return make(code)
	var parts := code.split(":")
	match parts[0]:
		SALVAGE_ID:
			if parts.size() == 2 and parts[1].is_valid_int():
				return make_salvage(int(parts[1]))
		WEAPON_ID:
			if parts.size() == 4 and parts[1].is_valid_int() and parts[3].is_valid_int():
				var ids := PackedInt32Array()
				if parts[2] != "-":
					for a in parts[2].split("."):
						if not a.is_valid_int():
							return null
						ids.append(int(a))
				return make_weapon(int(parts[1]), ids, int(parts[3]))
		ATTACHMENT_ID:
			if parts.size() == 2 and parts[1].is_valid_int():
				return make_attachment(int(parts[1]))
		AMMO_ID:
			if parts.size() == 2 and parts[1].is_valid_int():
				return make_ammo(int(parts[1]))
	return null


static func codes_of(items: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for item: ItemData in items:
		if item != null:
			out.append(item.code)
	return out


## Every code that parses, in order; bad ones are dropped (with a warning).
static func items_from(codes: PackedStringArray) -> Array[ItemData]:
	var out: Array[ItemData] = []
	for code in codes:
		var item := from_code(code)
		if item == null:
			push_warning("ItemPresets: dropping unparseable item code '%s'" % code)
			continue
		out.append(item)
	return out


## Credits for a code, 0 if it does not parse. What Phase 4 prices
## MissionResult.loot with.
static func value_of(code: String) -> int:
	var item := from_code(code)
	return item.value if item != null else 0


static func is_objective_code(code: String) -> bool:
	return OBJECTIVES.has(code)


# --- Rolls ------------------------------------------------------------------------
#
# Every roll takes an optional RandomNumberGenerator: the generator passes its own
# seeded one so a deck stays a pure function of its seed; null uses the global RNG,
# which main.gd seeds identically on every co-op peer before spawning.


## One valuable, its tier rolled from `tier_weights` (percent, common -> rare).
static func roll_valuable(rng: RandomNumberGenerator = null, tier_weights: Array[int] = CONTAINER_TIER_WEIGHTS) -> ItemData:
	var tier := _weighted_index(tier_weights, rng) + 1
	var ids: Array = []
	for id: String in VALUABLES:
		if VALUABLES[id]["tier"] == tier:
			ids.append(id)
	ids.sort()  # Dictionary order is insertion order today; sorting makes it a promise
	return make(ids[_rand_int(ids.size(), rng)])


## A container's contents as codes (what MapData stores): CONTAINER_ITEM_COUNTS
## items, each one gear with CONTAINER_GEAR_PERCENT chance (`roll_gear`), else a
## valuable.
static func roll_container(rng: RandomNumberGenerator = null) -> PackedStringArray:
	var out := PackedStringArray()
	var count: int = CONTAINER_ITEM_COUNTS[_rand_int(CONTAINER_ITEM_COUNTS.size(), rng)]
	for _i in count:
		if _rand_int(100, rng) < CONTAINER_GEAR_PERCENT:
			out.append(roll_gear(rng, CONTAINER_TIER_WEIGHTS).code)
		else:
			out.append(roll_valuable(rng, CONTAINER_TIER_WEIGHTS).code)
	return out


## One piece of container gear: its tier rolled from `tier_weights` (percent,
## common -> rare), then one entry of that tier from `gear_table`, by weight.
static func roll_gear(rng: RandomNumberGenerator = null, tier_weights: Array[int] = CONTAINER_TIER_WEIGHTS) -> ItemData:
	var tier := _weighted_index(tier_weights, rng) + 1
	var codes: Array[String] = []
	var weights: Array[int] = []
	for entry: Dictionary in gear_table():
		if entry["tier"] == tier:
			codes.append(entry["code"])
			weights.append(entry["weight"])
	return from_code(codes[_weighted_index(weights, rng)])


## Every piece of gear a container can roll, as {code, tier, weight}, in a fixed
## order — attachments by id, then ammo by id, then the grenade — so a seeded roll
## is the same on every run and every peer.
static func gear_table() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var att_ids: Array = ATTACHMENT_TIER.keys()
	att_ids.sort()
	for id: int in att_ids:
		out.append({"code": "%s:%d" % [ATTACHMENT_ID, id], "tier": ATTACHMENT_TIER[id], "weight": 1})
	var ammo_ids: Array = AMMO_TIER.keys()
	ammo_ids.sort()
	for id: int in ammo_ids:
		out.append({"code": "%s:%d" % [AMMO_ID, id], "tier": AMMO_TIER[id], "weight": 1})
	out.append({"code": GRENADE_ID, "tier": GRENADE_TIER, "weight": GRENADE_WEIGHT})
	return out


static func objective_ids() -> Array:
	var ids: Array = OBJECTIVES.keys()
	ids.sort()
	return ids


static func _weighted_index(weights: Array[int], rng: RandomNumberGenerator) -> int:
	var total := 0
	for w in weights:
		total += w
	var roll := _rand_int(maxi(1, total), rng)
	for i in weights.size():
		roll -= weights[i]
		if roll < 0:
			return i
	return weights.size() - 1


## Uniform in [0, n).
static func _rand_int(n: int, rng: RandomNumberGenerator) -> int:
	if n <= 1:
		return 0
	return rng.randi_range(0, n - 1) if rng != null else randi_range(0, n - 1)


static func _item(id: String, display_name: String, kind: ItemData.Kind, value: int,
		payload: Dictionary, code: String, tier: int = 0) -> ItemData:
	var item := ItemData.new()
	item.id = id
	item.display_name = display_name
	item.kind = kind
	item.value = value
	item.payload = payload
	item.code = code
	item.tier = tier
	return item
