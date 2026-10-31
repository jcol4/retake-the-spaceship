class_name WeaponPresets
extends RefCounted
## The five player-selectable weapons (design doc `docs/design/factions/contractors/weapons/`).
## Weapon choice is independent of class — `CLASS_DEFAULT` is only the
## loadout screen's preselected suggestion, not a restriction.

## APPEND-ONLY: ids cross the wire (PlayerUnit._rpc_sync_loadout) as ints.
## PISTOL is the sidearm (GDD §4.3, extraction plan 2.5), not a primary — it is
## in DATA so it is built the same way as everything else, and kept out of the
## loadout picker by `all_ids` / PRIMARY_IDS.
enum WeaponId { ASSAULT_RIFLE, SHOTGUN, SMG, LMG, BATTLE_RIFLE, PISTOL }

## The sidearm every soldier deploys with (UnitStats.sidearm). Named rather than
## hardcoded at the spawn site so there is one place to swap it when sidearms
## become a loadout choice.
const SIDEARM_ID := WeaponId.PISTOL

## The weapons the loadout screen offers as a PRIMARY. Everything in DATA except
## the sidearm; listed explicitly so a future sidearm added to DATA does not land
## in the primary picker by default.
const PRIMARY_IDS: Array[WeaponId] = [
	WeaponId.ASSAULT_RIFLE, WeaponId.SHOTGUN, WeaponId.SMG, WeaponId.LMG, WeaponId.BATTLE_RIFLE,
]

# DAMAGE IS ~0.65x ITS OLD VALUE across the board, and that is the smaller half
# of the lethality rework — max HP came down ~3.5x at the same time (see
# UnitStats.base_hp). Read the column as HITS TO KILL A ~20 HP SOLDIER, which is
# what it was tuned against: Shotgun and Battle Rifle two, Assault Rifle and LMG
# three, SMG four. The spread between weapons is what it always was; the whole
# band just moved from "five or six" down to "two or three".
#
# base_accuracy/mag_size match the docs. starting_reserve is spare
# rounds beyond the loaded mag — total mission ammo is mag_size +
# starting_reserve (e.g. Assault Rifle: 3 in the gun + 15 spare = 6 mags'
# worth, 18 shots total). optimal_range/falloff_rate add a weapon-specific
# range penalty on top of Combat's global distance curve (Sec 6.5).
# fire_ap_modifier/reload_ap_modifier are AP added to the weapon's firing and
# reload prices (UnitStats.weapon_ap_modifier) — all 0 until tuned. noise_radius
# is how many tiles the gunfire carries — all 5 (the old flat value) until tuned.
# Attachments (AttachmentPresets) stack onto every column here.
#
# No move_multiplier column any more — see WeaponData for why it was retired
# rather than re-expressed against the granular AP economy.
const DATA := {
	WeaponId.ASSAULT_RIFLE: {
		"display_name": "Assault Rifle", "base_accuracy": 30, "damage": 8,
		"mag_size": 3, "starting_reserve": 15,  # 6 mags total (18 shots)
		"optimal_range": 999, "falloff_rate": 0,
		"fire_ap_modifier": 0, "reload_ap_modifier": 0, "noise_radius": 5,
	},
	WeaponId.SHOTGUN: {
		"display_name": "Shotgun", "base_accuracy": 20, "damage": 14,
		"mag_size": 6, "starting_reserve": 15,  # pump-action: loose shells, not discrete mags (21 total)
		"loose_reserve": true,
		"optimal_range": 3, "falloff_rate": 15,
		"fire_ap_modifier": 0, "reload_ap_modifier": 0, "noise_radius": 5,
	},
	WeaponId.SMG: {
		"display_name": "SMG", "base_accuracy": 35, "damage": 6,
		"mag_size": 4, "starting_reserve": 20,  # 6 mags total (24 shots)
		"optimal_range": 6, "falloff_rate": 6,
		"fire_ap_modifier": 0, "reload_ap_modifier": 0, "noise_radius": 5,
	},
	WeaponId.LMG: {
		"display_name": "LMG", "base_accuracy": 28, "damage": 9,
		"mag_size": 6, "starting_reserve": 12,  # 3 mags total (18 shots)
		"optimal_range": 999, "falloff_rate": 0,
		"fire_ap_modifier": 0, "reload_ap_modifier": 0, "noise_radius": 5,
	},
	WeaponId.BATTLE_RIFLE: {
		"display_name": "Battle Rifle", "base_accuracy": 35, "damage": 10,
		"mag_size": 3, "starting_reserve": 12,  # 5 mags total (15 shots)
		"optimal_range": 999, "falloff_rate": 0,
		"fire_ap_modifier": 0, "reload_ap_modifier": 0, "noise_radius": 5,
	},
	# PLACEHOLDER numbers (extraction plan A5), gameplay-first: the pistol exists
	# because carrying a body leaves one hand free (GDD §4.4), and what it has to
	# be is clearly WORSE than any long gun without being useless. Damage 5 is
	# four hits on a ~20 HP soldier where the SMG needs four at 6 — so it is the
	# weakest gun in the game. It falls off past 6 tiles at 8%/tile, so it is a
	# close-quarters answer, not a way to keep fighting the same firefight. Noise
	# 4 is one tile quieter than the long guns: a short barrel, not a suppressor.
	# 8 + 16 rounds: enough to cover one carry to the ship, not a second primary.
	WeaponId.PISTOL: {
		"display_name": "Pistol", "base_accuracy": 30, "damage": 5,
		"mag_size": 8, "starting_reserve": 16,  # 3 mags total (24 shots)
		"optimal_range": 6, "falloff_rate": 8,
		"fire_ap_modifier": 0, "reload_ap_modifier": 0, "noise_radius": 4,
	},
}

## The gun model each weapon is drawn with: `assets/models/guns/<model>.glb`,
## built by tools/build_guns.py. Every one shares the rifle's grip, so any of
## them fits any gun-carrying character (UnitVisual.set_gun). The pistol has no
## model yet; a unit with its sidearm out keeps showing its primary.
const GUN_MODEL := {
	WeaponId.ASSAULT_RIFLE: &"assault_rifle",
	WeaponId.SHOTGUN: &"shotgun",
	WeaponId.SMG: &"smg",
	WeaponId.LMG: &"lmg",
	WeaponId.BATTLE_RIFLE: &"battle_rifle",
}

const CLASS_DEFAULT := {
	UnitStats.UnitClass.ASSAULT: WeaponId.ASSAULT_RIFLE,
	UnitStats.UnitClass.SNIPER: WeaponId.BATTLE_RIFLE,
	UnitStats.UnitClass.SUPPORT: WeaponId.SMG,
	UnitStats.UnitClass.HEAVY: WeaponId.LMG,
}


## `attachment_ids` is AttachmentPresets.AttachmentId values in any order; -1
## entries are empty slots, and anything that doesn't fit this weapon is dropped
## rather than trusted — the list can arrive over the network. `ammo_id` is an
## AmmoPresets.AmmoId; one that doesn't fit falls back to Standard (null).
static func make(id: WeaponId, attachment_ids: PackedInt32Array = PackedInt32Array(), ammo_id: int = -1) -> WeaponData:
	var d: Dictionary = DATA[id]
	var w := WeaponData.new()
	w.id = id
	w.display_name = d["display_name"]
	w.base_accuracy = d["base_accuracy"]
	w.damage = d["damage"]
	w.mag_size = d["mag_size"]
	w.starting_reserve = d["starting_reserve"]
	w.loose_reserve = d.get("loose_reserve", false)
	w.optimal_range = d["optimal_range"]
	w.falloff_rate = d["falloff_rate"]
	w.fire_ap_modifier = d["fire_ap_modifier"]
	w.reload_ap_modifier = d["reload_ap_modifier"]
	w.noise_radius = d["noise_radius"]
	for aid in attachment_ids:
		if AttachmentPresets.DATA.has(aid) and AttachmentPresets.fits(aid, id):
			w.set_attachment(AttachmentPresets.make(aid))
	if AmmoPresets.DATA.has(ammo_id) and AmmoPresets.fits(ammo_id, id):
		w.ammo = AmmoPresets.make(ammo_id)
	return w


## The gun model for weapon `id`, or "" for one with none (the pistol, and the
## non-roster weapons aliens and the door gun are built with, id -1).
static func gun_model(id: int) -> StringName:
	return GUN_MODEL.get(id, &"")


static func default_for_class(unit_class: UnitStats.UnitClass) -> WeaponId:
	return CLASS_DEFAULT[unit_class]


## Every PRIMARY weapon, in roster order — what the loadout picker lists. The
## sidearm is deliberately absent (it is fixed gear, shown as its own line).
static func all_ids() -> Array[WeaponId]:
	return PRIMARY_IDS.duplicate()


## A fresh sidearm. No attachments and Standard ammo: the sidearm is not fitted
## on the loadout screen (yet), and the attachment/ammo tables are written
## against long guns.
static func make_sidearm() -> WeaponData:
	return make(SIDEARM_ID)
