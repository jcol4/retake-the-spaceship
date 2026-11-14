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
# mag_size matches the docs. starting_reserve is spare rounds beyond the loaded
# mag — total mission ammo is mag_size + starting_reserve (e.g. Assault Rifle: 3
# in the gun + 15 spare = 6 mags' worth, 18 shots total).
# fire_ap_modifier/reload_ap_modifier are AP added to the weapon's firing and
# reload prices (UnitStats.weapon_ap_modifier) — all 0 until tuned. noise_radius
# is how many tiles the gunfire carries — all 5 (the old flat value) until tuned.
# Attachments (AttachmentPresets) stack onto every column here.
#
# ACCURACY lives in two columns (docs/design/systems/accuracy). `archetype` names
# the WeaponArchetype distance table the gun reads — every roster gun is the
# first of its family, so each names its own. `aim_modifier` is how this gun
# differs from others of its family: 0 for all six today. The old 20-35 base
# accuracy, the per-gun optimal-range falloff and the Battle Rifle's/LMG's
# close-quarters accuracy penalties all became the tables.
#
# penetration is percentile (Penetration, docs/design/systems/penetration):
# every 25 is one more body a round passes through, and the unfloored remainder
# sets how much damage it keeps doing so. Battle Rifle > LMG > Assault Rifle >
# SMG > Pistol. The Shotgun has none and splashes instead.
#
# No move_multiplier column any more — see WeaponData for why it was retired
# rather than re-expressed against the granular AP economy.
#
# engaged_shoot_ap (docs/design/systems/close-quarters) is Shoot's AP change while
# a hostile its carrier can see is within 3 tiles: the SMG's and Pistol's 1 AP
# cheaper snap shot. Absent means 0.
const DATA := {
	WeaponId.ASSAULT_RIFLE: {
		"display_name": "Assault Rifle", "archetype": WeaponArchetype.Id.ASSAULT_RIFLE,
		"aim_modifier": 0, "damage": 8,
		"mag_size": 3, "starting_reserve": 15,  # 6 mags total (18 shots)
		"fire_ap_modifier": 0, "reload_ap_modifier": 0, "noise_radius": 5,
		"penetration": 45,
	},
	WeaponId.SHOTGUN: {
		"display_name": "Shotgun", "archetype": WeaponArchetype.Id.SHOTGUN,
		"aim_modifier": 0, "damage": 14,
		"mag_size": 6, "starting_reserve": 15,  # pump-action: loose shells, not discrete mags (21 total)
		"loose_reserve": true,
		"fire_ap_modifier": 0, "reload_ap_modifier": 0, "noise_radius": 5,
		"penetration": 0, "splash": true,  # buckshot; Slug Rounds swap it to penetration
	},
	WeaponId.SMG: {
		"display_name": "SMG", "archetype": WeaponArchetype.Id.SMG,
		"aim_modifier": 0, "damage": 6,
		"mag_size": 4, "starting_reserve": 20,  # 6 mags total (24 shots)
		"fire_ap_modifier": 0, "reload_ap_modifier": 0, "noise_radius": 5,
		"penetration": 30,
		"engaged_shoot_ap": -1,  # the cheap snap shot its role always promised
	},
	WeaponId.LMG: {
		"display_name": "LMG", "archetype": WeaponArchetype.Id.LMG,
		"aim_modifier": 0, "damage": 9,
		"mag_size": 6, "starting_reserve": 12,  # 3 mags total (18 shots)
		"fire_ap_modifier": 0, "reload_ap_modifier": 0, "noise_radius": 5,
		"penetration": 60,
	},
	WeaponId.BATTLE_RIFLE: {
		"display_name": "Battle Rifle", "archetype": WeaponArchetype.Id.BATTLE_RIFLE,
		"aim_modifier": 0, "damage": 10,
		"mag_size": 3, "starting_reserve": 12,  # 5 mags total (15 shots)
		"fire_ap_modifier": 0, "reload_ap_modifier": 0, "noise_radius": 5,
		"penetration": 80,
	},
	# PLACEHOLDER numbers (extraction plan A5), gameplay-first: the pistol exists
	# because carrying a body leaves one hand free (GDD §4.4), and what it has to
	# be is clearly WORSE than any long gun without being useless. Damage 5 is
	# four hits on a ~20 HP soldier where the SMG needs four at 6 — so it is the
	# weakest gun in the game. Its table is the SMG's shape, shorter and weaker, so
	# it is a close-quarters answer, not a way to keep fighting the same firefight.
	# Noise 4 is one tile quieter than the long guns: a short barrel, not a
	# suppressor. 8 + 16 rounds: enough to cover one carry to the ship, not a
	# second primary.
	WeaponId.PISTOL: {
		"display_name": "Pistol", "archetype": WeaponArchetype.Id.PISTOL,
		"aim_modifier": 0, "damage": 5,
		"mag_size": 8, "starting_reserve": 16,  # 3 mags total (24 shots)
		"fire_ap_modifier": 0, "reload_ap_modifier": 0, "noise_radius": 4,
		"penetration": 25,
		"engaged_shoot_ap": -1,  # the carry's answer to something getting close
	},
}

## The gun model each weapon is drawn with: `assets/models/guns/<model>.glb`,
## built by tools/build_guns.py. Every one shares the rifle's grip, so any of
## them fits any gun-carrying character (UnitVisual.set_gun). The pistol is
## Poly Haven's Service Pistol, fitted to the same grip by tools/build_pistol.py.
const GUN_MODEL := {
	WeaponId.ASSAULT_RIFLE: &"assault_rifle",
	WeaponId.SHOTGUN: &"shotgun",
	WeaponId.SMG: &"smg",
	WeaponId.LMG: &"lmg",
	WeaponId.BATTLE_RIFLE: &"battle_rifle",
	WeaponId.PISTOL: &"pistol",
}

## The pose family a weapon is held with (UnitVisual.WEAPON_FAMILIES); absent
## means the rifle poses. Every family pose is optional, so this can name a
## family before any of its animations exist.
const ANIM_FAMILY := {
	WeaponId.PISTOL: &"pistol",
}

## The Sfx key each weapon fires with (SfxManager.STREAMS). Calibres from Snake's
## Authentic Gun Sounds, chosen so no two guns share a recording: 5.56 rifle,
## 9mm spray (SMG) and 9mm double-tap (pistol), 7.62x54R for the LMG (a PKM's
## round), .308 for the battle rifle, 20 gauge for the shotgun.
const FIRE_SFX := {
	WeaponId.ASSAULT_RIFLE: "ar_fire",
	WeaponId.SHOTGUN: "shotgun_fire",
	WeaponId.SMG: "smg_fire",
	WeaponId.LMG: "lmg_fire",
	WeaponId.BATTLE_RIFLE: "battle_rifle_fire",
	WeaponId.PISTOL: "pistol_fire",
}

## What a weapon off the roster (id -1: alien weapons, the door gun) fires with —
## the sound every gun made before each got its own.
const DEFAULT_FIRE_SFX := "rifle_fire"

## How hard each gun's muzzle light floods the room (VfxManager.muzzle_light),
## against the assault rifle's 1. Cosmetic only.
const MUZZLE_LIGHT := {
	WeaponId.ASSAULT_RIFLE: 1.0,
	WeaponId.SHOTGUN: 1.5,
	WeaponId.SMG: 0.7,
	WeaponId.LMG: 1.3,
	WeaponId.BATTLE_RIFLE: 1.15,
	WeaponId.PISTOL: 0.5,
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
	w.archetype = d["archetype"]
	w.aim_modifier = d["aim_modifier"]
	w.damage = d["damage"]
	w.mag_size = d["mag_size"]
	w.starting_reserve = d["starting_reserve"]
	w.loose_reserve = d.get("loose_reserve", false)
	w.fire_ap_modifier = d["fire_ap_modifier"]
	w.reload_ap_modifier = d["reload_ap_modifier"]
	w.noise_radius = d["noise_radius"]
	w.penetration = d.get("penetration", 0)
	w.splash = d.get("splash", false)
	w.engaged_shoot_ap = d.get("engaged_shoot_ap", 0)
	for aid in attachment_ids:
		if AttachmentPresets.DATA.has(aid) and AttachmentPresets.fits(aid, id):
			w.set_attachment(AttachmentPresets.make(aid))
	if AmmoPresets.DATA.has(ammo_id) and AmmoPresets.fits(ammo_id, id):
		w.ammo = AmmoPresets.make(ammo_id)
	return w


## The pose family weapon `id` is held with, or "" for the rifle poses.
static func anim_family(id: int) -> StringName:
	return ANIM_FAMILY.get(id, &"")


## The gun model for weapon `id`, or "" for one with none (the non-roster
## weapons aliens and the door gun are built with, id -1).
static func gun_model(id: int) -> StringName:
	return GUN_MODEL.get(id, &"")


## The Sfx key weapon `id` fires with. See FIRE_SFX.
static func fire_sfx(id: int) -> String:
	return FIRE_SFX.get(id, DEFAULT_FIRE_SFX)


## The muzzle-light scale `weapon` fires with: its own `muzzle_light` if set,
## else MUZZLE_LIGHT by id, else 1 (alien weapons). Null (unarmed) is 1 too, so
## anything that plays a burst lights the room.
static func muzzle_light(weapon: WeaponData) -> float:
	if weapon == null:
		return 1.0
	if weapon.muzzle_light > 0.0:
		return weapon.muzzle_light
	return MUZZLE_LIGHT.get(weapon.id, 1.0)


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
