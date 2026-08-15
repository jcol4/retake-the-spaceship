class_name WeaponPresets
extends RefCounted
## The five player-selectable weapons (design doc `docs/design/factions/contractors/weapons/`).
## Weapon choice is independent of class — `CLASS_DEFAULT` is only the
## loadout screen's preselected suggestion, not a restriction.

enum WeaponId { ASSAULT_RIFLE, SHOTGUN, SMG, LMG, BATTLE_RIFLE }

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
#
# No move_multiplier column any more — see WeaponData for why it was retired
# rather than re-expressed against the granular AP economy.
const DATA := {
	WeaponId.ASSAULT_RIFLE: {
		"display_name": "Assault Rifle", "base_accuracy": 30, "damage": 8,
		"mag_size": 3, "starting_reserve": 15,  # 6 mags total (18 shots)
		"optimal_range": 999, "falloff_rate": 0,
	},
	WeaponId.SHOTGUN: {
		"display_name": "Shotgun", "base_accuracy": 20, "damage": 14,
		"mag_size": 6, "starting_reserve": 15,  # pump-action: loose shells, not discrete mags (21 total)
		"optimal_range": 3, "falloff_rate": 15,
	},
	WeaponId.SMG: {
		"display_name": "SMG", "base_accuracy": 35, "damage": 6,
		"mag_size": 4, "starting_reserve": 20,  # 6 mags total (24 shots)
		"optimal_range": 6, "falloff_rate": 6,
	},
	WeaponId.LMG: {
		"display_name": "LMG", "base_accuracy": 28, "damage": 9,
		"mag_size": 6, "starting_reserve": 12,  # 3 mags total (18 shots)
		"optimal_range": 999, "falloff_rate": 0,
	},
	WeaponId.BATTLE_RIFLE: {
		"display_name": "Battle Rifle", "base_accuracy": 35, "damage": 10,
		"mag_size": 3, "starting_reserve": 12,  # 5 mags total (15 shots)
		"optimal_range": 999, "falloff_rate": 0,
	},
}

const CLASS_DEFAULT := {
	UnitStats.UnitClass.ASSAULT: WeaponId.ASSAULT_RIFLE,
	UnitStats.UnitClass.SNIPER: WeaponId.BATTLE_RIFLE,
	UnitStats.UnitClass.SUPPORT: WeaponId.SMG,
	UnitStats.UnitClass.HEAVY: WeaponId.LMG,
}


static func make(id: WeaponId) -> WeaponData:
	var d: Dictionary = DATA[id]
	var w := WeaponData.new()
	w.id = id
	w.display_name = d["display_name"]
	w.base_accuracy = d["base_accuracy"]
	w.damage = d["damage"]
	w.mag_size = d["mag_size"]
	w.starting_reserve = d["starting_reserve"]
	w.optimal_range = d["optimal_range"]
	w.falloff_rate = d["falloff_rate"]
	return w


static func default_for_class(unit_class: UnitStats.UnitClass) -> WeaponId:
	return CLASS_DEFAULT[unit_class]


static func all_ids() -> Array[WeaponId]:
	var ids: Array[WeaponId] = []
	for id in DATA:
		ids.append(id)
	return ids
