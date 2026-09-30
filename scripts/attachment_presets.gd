class_name AttachmentPresets
extends RefCounted
## The attachment roster (design doc `docs/design/factions/contractors/weapons/attachments.md`).
## Each entry names its slot and only the WeaponMod keys it changes; anything
## left out is neutral. Stacking rules are in WeaponMod.
##
## Some entries are strictly worse than another in the same slot, which is
## fine: attachments are tiered loot and the weaker ones are the easy finds.
##
## Unlocks are per COPY: unlocking an attachment gives the squad one of it, to
## fit on one soldier at a time. An inventory is a Dictionary of id -> copies
## owned; see `placeholder_inventory` and LoadoutMenu.inventory.

enum AttachmentId {
	VERTICAL_GRIP, ANGLED_GRIP, LASER_SIGHT,
	SUPPRESSOR, MUZZLE_BRAKE, LONG_BARREL,
	HOLO_SIGHT, SCOPE, THERMAL_SIGHT,
	EXTENDED_MAG, DRUM_MAG, LIGHT_MAG,
	HEAVY_STOCK, SAWED_OFF_STOCK, ERGO_STOCK,
}

const Slot := AttachmentData.Slot

const DATA := {
	# --- Underbarrel ---
	AttachmentId.VERTICAL_GRIP: {
		"display_name": "Vertical Grip", "slot": Slot.UNDERBARREL,
		"accuracy": 5,
	},
	AttachmentId.ANGLED_GRIP: {
		"display_name": "Angled Grip", "slot": Slot.UNDERBARREL,
		"close_accuracy": 7, "close_range": 7,
	},
	AttachmentId.LASER_SIGHT: {
		"display_name": "Laser Sight", "slot": Slot.UNDERBARREL,
		"accuracy": 3, "shoot_ap": -1, "visibility_multiplier": 1.5,
	},
	# --- Barrel ---
	AttachmentId.SUPPRESSOR: {
		"display_name": "Suppressor", "slot": Slot.BARREL,
		"accuracy": 2, "noise_multiplier": 0.5,
	},
	AttachmentId.MUZZLE_BRAKE: {
		"display_name": "Muzzle Brake", "slot": Slot.BARREL,
		"accuracy": 5,
	},
	AttachmentId.LONG_BARREL: {
		"display_name": "Long Barrel", "slot": Slot.BARREL,
		"accuracy": 4, "damage_pct": 20,
		"shoot_ap": 1, "overwatch_ap": 1, "aimed_ap": 1, "suppress_ap": 1,
	},
	# --- Optic ---
	AttachmentId.HOLO_SIGHT: {
		"display_name": "Holo Sight", "slot": Slot.OPTIC,
		"accuracy": 5, "shoot_ap": -1, "overwatch_ap": -1,
	},
	AttachmentId.SCOPE: {
		"display_name": "Scope", "slot": Slot.OPTIC,
		"accuracy": 5, "aimed_ap": -2, "shoot_ap": -1, "overwatch_ap": -1, "suppress_ap": 1,
	},
	AttachmentId.THERMAL_SIGHT: {
		"display_name": "Thermal Sight", "slot": Slot.OPTIC,
		"accuracy": 7, "ignores_darkness": true, "shoot_ap": -1, "overwatch_ap": -1,
	},
	# --- Magazine ---
	AttachmentId.EXTENDED_MAG: {
		"display_name": "Extended Mag", "slot": Slot.MAGAZINE,
		"mag_size": 1,
	},
	AttachmentId.DRUM_MAG: {
		"display_name": "Drum Mag", "slot": Slot.MAGAZINE,
		"mag_size": 2, "reload_ap": 1,
	},
	AttachmentId.LIGHT_MAG: {
		"display_name": "Light Mag", "slot": Slot.MAGAZINE,
		"reload_ap": -1,
	},
	# --- Stock ---
	AttachmentId.HEAVY_STOCK: {
		"display_name": "Heavy Stock", "slot": Slot.STOCK,
		"accuracy": 3,
	},
	AttachmentId.SAWED_OFF_STOCK: {
		"display_name": "Sawed Off Stock", "slot": Slot.STOCK,
		"accuracy": -10, "shoot_ap": -1, "overwatch_ap": -1,
	},
	AttachmentId.ERGO_STOCK: {
		"display_name": "Ergo Stock", "slot": Slot.STOCK,
		"shoot_ap": -1, "overwatch_ap": -1, "aimed_ap": -1,
	},
}

# Weapons an attachment will NOT fit. Anything absent fits everything. The
# shotgun's tube is loaded shell by shell, so no magazine fits it.
const INCOMPATIBLE := {
	AttachmentId.EXTENDED_MAG: [WeaponPresets.WeaponId.SHOTGUN],
	AttachmentId.DRUM_MAG: [WeaponPresets.WeaponId.SHOTGUN],
	AttachmentId.LIGHT_MAG: [WeaponPresets.WeaponId.SHOTGUN],
}


static func make(id: AttachmentId) -> AttachmentData:
	var d: Dictionary = DATA[id].duplicate()
	var a := AttachmentData.new()
	a.id = id
	a.slot = d["slot"]
	d.erase("slot")
	a.apply_spec(d)
	return a


static func fits(id: AttachmentId, weapon_id: int) -> bool:
	return not (weapon_id in INCOMPATIBLE.get(id, []))


## Every attachment for `slot` that fits `weapon_id`, in roster order.
static func ids_for(slot: AttachmentData.Slot, weapon_id: int) -> Array[AttachmentId]:
	var ids: Array[AttachmentId] = []
	for id in DATA:
		if DATA[id]["slot"] == slot and fits(id, weapon_id):
			ids.append(id)
	return ids


static func describe(id: AttachmentId) -> String:
	return WeaponMod.describe_spec(DATA[id])


## One copy of everything — what the loadout screen offers until progression
## exists to hand out unlocks.
static func placeholder_inventory() -> Dictionary:
	var inv := {}
	for id in DATA:
		inv[id] = 1
	return inv
