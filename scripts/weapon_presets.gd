class_name WeaponPresets
extends RefCounted
## The five player-selectable weapons (design doc `docs/design/factions/contractors/weapons/`).
## Weapon choice is independent of class — `CLASS_DEFAULT` is only the
## loadout screen's preselected suggestion, not a restriction.

enum WeaponId { ASSAULT_RIFLE, SHOTGUN, SMG, LMG, BATTLE_RIFLE }

# base_accuracy/damage/mag_size match the docs. optimal_range/falloff_rate add
# a weapon-specific range penalty on top of Combat's global distance curve
# (Sec 6.5); move_multiplier scales UnitStats.move_run()/move_sprint().
const DATA := {
	WeaponId.ASSAULT_RIFLE: {
		"display_name": "Assault Rifle", "base_accuracy": 30, "damage": 12, "mag_size": 6,
		"optimal_range": 999, "falloff_rate": 0, "move_multiplier": 1.0,
	},
	WeaponId.SHOTGUN: {
		"display_name": "Shotgun", "base_accuracy": 20, "damage": 22, "mag_size": 6,
		"optimal_range": 3, "falloff_rate": 15, "move_multiplier": 1.0,
	},
	WeaponId.SMG: {
		"display_name": "SMG", "base_accuracy": 35, "damage": 8, "mag_size": 12,
		"optimal_range": 6, "falloff_rate": 6, "move_multiplier": 1.0,
	},
	WeaponId.LMG: {
		"display_name": "LMG", "base_accuracy": 28, "damage": 14, "mag_size": 15,
		"optimal_range": 999, "falloff_rate": 0, "move_multiplier": 0.75,
	},
	WeaponId.BATTLE_RIFLE: {
		"display_name": "Battle Rifle", "base_accuracy": 35, "damage": 16, "mag_size": 5,
		"optimal_range": 999, "falloff_rate": 0, "move_multiplier": 1.0,
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
	w.optimal_range = d["optimal_range"]
	w.falloff_rate = d["falloff_rate"]
	w.move_multiplier = d["move_multiplier"]
	return w


static func default_for_class(unit_class: UnitStats.UnitClass) -> WeaponId:
	return CLASS_DEFAULT[unit_class]


static func all_ids() -> Array[WeaponId]:
	var ids: Array[WeaponId] = []
	for id in DATA:
		ids.append(id)
	return ids
