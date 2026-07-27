class_name ClassPresets
extends RefCounted
## Stat-range presets per class (Sec 4.6.5 tendencies). Exact ranges are
## placeholder guesses pending playtesting — tune freely.

# Per class: { stat: [min, max] }
const RANGES := {
	UnitStats.UnitClass.ASSAULT: {
		"perception": [30, 50], "reflexes": [45, 65], "fitness": [60, 85], "luck": [30, 60],
		"class_base_initiative": 60,
	},
	UnitStats.UnitClass.SNIPER: {
		"perception": [65, 90], "reflexes": [45, 65], "fitness": [30, 50], "luck": [30, 60],
		"class_base_initiative": 45,
	},
	UnitStats.UnitClass.SUPPORT: {
		"perception": [45, 65], "reflexes": [45, 65], "fitness": [45, 65], "luck": [45, 75],
		"class_base_initiative": 50,
	},
	UnitStats.UnitClass.HEAVY: {
		"perception": [40, 60], "reflexes": [25, 45], "fitness": [65, 90], "luck": [30, 60],
		"class_base_initiative": 40,
	},
}


static func roll(unit_class: UnitStats.UnitClass, display_name: String) -> UnitStats:
	var r: Dictionary = RANGES[unit_class]
	var stats := UnitStats.new()
	stats.display_name = display_name
	stats.unit_class = unit_class
	stats.perception = randi_range(r["perception"][0], r["perception"][1])
	stats.reflexes = randi_range(r["reflexes"][0], r["reflexes"][1])
	stats.fitness = randi_range(r["fitness"][0], r["fitness"][1])
	stats.luck = randi_range(r["luck"][0], r["luck"][1])
	stats.class_base_initiative = r["class_base_initiative"]
	# Suggested default (design doc `weapons/`) — the loadout screen lets the
	# player override this per soldier before the mission starts.
	stats.weapon = WeaponPresets.make(WeaponPresets.default_for_class(unit_class))
	return stats
