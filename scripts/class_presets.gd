class_name ClassPresets
extends RefCounted
## Stat-range presets per class (Sec 4.6.5 tendencies). Exact ranges are
## placeholder guesses pending playtesting — tune freely.
##
## THE CLASS INITIATIVE MODIFIER IS GONE, and its absence is the design rather
## than an oversight. Initiative is a flat base plus a small Reflexes term now
## (rework doc Sec 5.2), with no per-class addition anywhere in the calculation —
## so a class acts early because of the Reflexes range it tends to roll in, not
## because the roster grants it a head start. Re-adding a direct class term is a
## deliberate decision to make, not a regression to fix.
##
## Fitness ranges are worth re-reading in that light too: Fitness is the AP POOL
## now (Sec 4.2), with max HP demoted to a minor term off it, so these numbers
## are pace-and-budget values that happen to also buy a little toughness — the
## reverse of what they meant when they were HP and nothing else.

# Per class: { stat: [min, max] }
const RANGES := {
	UnitStats.UnitClass.ASSAULT: {
		"perception": [30, 50], "reflexes": [45, 65], "fitness": [60, 85], "luck": [30, 60],
	},
	UnitStats.UnitClass.SNIPER: {
		"perception": [65, 90], "reflexes": [45, 65], "fitness": [30, 50], "luck": [30, 60],
	},
	UnitStats.UnitClass.SUPPORT: {
		"perception": [45, 65], "reflexes": [45, 65], "fitness": [45, 65], "luck": [45, 75],
	},
	UnitStats.UnitClass.HEAVY: {
		"perception": [40, 60], "reflexes": [25, 45], "fitness": [65, 90], "luck": [30, 60],
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
	# base_hp / base_initiative / equipment_initiative are left at UnitStats'
	# defaults: 15/50/5, which ARE the player faction's baseline (rework doc Sec
	# 5.1/5.2). Only non-player types hand-set them (Sec 4.5/5.5).
	#
	# 15 puts the squad at 17-22 max HP by class — Sniper lowest off its 30-50
	# Fitness, Heavy highest off 65-90 — centred on 20. Worth knowing before
	# reading these ranges: under the shortened HP scale a class's Fitness band is
	# worth only a couple of HP either way, so the ranges below are almost purely
	# an AP-POOL and accuracy statement now, not a durability one.
	# Suggested default (design doc `weapons/`) — the loadout screen lets the
	# player override this per soldier before the mission starts.
	stats.weapon = WeaponPresets.make(WeaponPresets.default_for_class(unit_class))
	return stats
