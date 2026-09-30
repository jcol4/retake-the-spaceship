class_name AmmoPresets
extends RefCounted
## The ammo roster (design doc `docs/design/factions/contractors/weapons/attachments.md`).
## Same WeaponMod keys as AttachmentPresets; stacking rules are in WeaponMod.
## "Armored" is the TARGET's UnitStats.armored flag, not its armor value.
##
## Unlocks are per TYPE, not per copy like attachments: once a type is unlocked,
## any number of soldiers can load it. Standard is always available and is what
## every weapon carries by default (buckshot, on the Shotgun).

enum AmmoId {
	STANDARD,
	PENETRATOR, HOLLOW_POINT, SUBSONIC, FMJ,
	SLUG,
}

const DATA := {
	AmmoId.STANDARD: {"display_name": "Standard"},
	# --- Rifle / SMG / LMG (and pistol, once there is one) ---
	AmmoId.PENETRATOR: {
		"display_name": "Penetrator Rounds", "damage_pct_vs_armored": 34,
	},
	AmmoId.HOLLOW_POINT: {
		"display_name": "Hollow Point", "damage_pct_vs_unarmored": 50, "damage_pct_vs_armored": -15,
	},
	AmmoId.SUBSONIC: {
		"display_name": "Subsonic", "noise_multiplier": 0.7,
	},
	AmmoId.FMJ: {
		"display_name": "FMJ", "accuracy": 2,
	},
	# --- Shotgun ---
	# Slugs trade the spread for reach: optimal range 3 -> 6, but -34% damage
	# within 4 tiles. The two +% lines stack with that, so a slug at 3 tiles
	# does +16% to armor and -9% to flesh.
	AmmoId.SLUG: {
		"display_name": "Slug Rounds", "optimal_range": 3,
		"damage_pct_vs_armored": 50, "damage_pct_vs_unarmored": 25,
		"close_damage_pct": -34, "close_range": 4,
	},
}

const _RIFLES := [
	WeaponPresets.WeaponId.ASSAULT_RIFLE, WeaponPresets.WeaponId.SMG,
	WeaponPresets.WeaponId.LMG, WeaponPresets.WeaponId.BATTLE_RIFLE,
]
const _SHOTGUNS := [WeaponPresets.WeaponId.SHOTGUN]

# The weapons each type fits. Anything absent (Standard) fits everything.
const FITS := {
	AmmoId.PENETRATOR: _RIFLES,
	AmmoId.HOLLOW_POINT: _RIFLES,
	AmmoId.SUBSONIC: _RIFLES,
	AmmoId.FMJ: _RIFLES,
	AmmoId.SLUG: _SHOTGUNS,
}


static func make(id: AmmoId) -> AmmoData:
	var a := AmmoData.new()
	a.id = id
	a.apply_spec(DATA[id])
	return a


static func fits(id: AmmoId, weapon_id: int) -> bool:
	return not FITS.has(id) or weapon_id in FITS[id]


## Every ammo type that fits `weapon_id`, in roster order. Standard is always first.
static func ids_for(weapon_id: int) -> Array[AmmoId]:
	var ids: Array[AmmoId] = []
	for id in DATA:
		if fits(id, weapon_id):
			ids.append(id)
	return ids


static func describe(id: AmmoId) -> String:
	return WeaponMod.describe_spec(DATA[id])


## Every type unlocked, until progression exists to hand them out.
static func placeholder_unlocks() -> Array:
	return DATA.keys()
