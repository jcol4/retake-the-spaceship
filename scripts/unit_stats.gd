class_name UnitStats
extends Resource
## Per-soldier stats (design doc Sec 4.6). Percentile values 0-99.

enum UnitClass { ASSAULT, SNIPER, SUPPORT, HEAVY }

@export var display_name: String = "Soldier"
@export_range(0, 99) var perception: int = 50
@export_range(0, 99) var reflexes: int = 50
@export_range(0, 99) var fitness: int = 50
@export_range(0, 99) var luck: int = 50
@export var unit_class: UnitClass = UnitClass.ASSAULT
# Player-selected gear (design doc `weapons/`) — stats live on the weapon, not
# the class. `null` means unarmed at range (e.g. the Fodder swarm, Sec 11.4).
@export var weapon: WeaponData = null

var weapon_base_accuracy: int:
	get: return weapon.base_accuracy if weapon else 0

var weapon_damage: int:
	get: return weapon.damage if weapon else 0

var mag_size: int:
	get: return weapon.mag_size if weapon else 0

# Contact-range attack (Sec 11.4). Separate from the weapon numbers above so a
# unit can be dangerous in melee and harmless at range, or the reverse — the
# Fodder swarm has no gun at all (mag_size 0) and only these two matter to it.
@export var melee_base_accuracy: int = 45
@export var melee_damage: int = 5
@export var class_base_initiative: int = 50
@export var equipment_initiative: int = 50


func max_hp() -> int:
	return fitness  # +1 max HP per Fitness point (Sec 4.6.3)


## Tiles per 1 AP. Raised by half when movement went four-way, to hold effective
## reach roughly where it was: under the old eight-way rule N tiles reached a
## square of (2N+1)^2, and four-way reaches a diamond of 2N^2+2N+1. Solving those
## equal gives a factor of ~1.46, so 4 -> 6 and the Fitness step 1/20 -> 1/15,
## which is exactly x1.5 at both ends of the stat range (fitness 0: 4->6,
## fitness 99: 8->12).
##
## Area-matched rather than corner-matched on purpose. Matching the far CORNER
## would need double, because a diagonal now costs two steps instead of one, and
## doubling every move band to protect the one direction that got worse would
## make every other direction absurd. These numbers were never playtested against
## four-way movement; treat them as the starting point for that pass.
func move_run() -> int:
	var base := 6 + fitness / 15  # base 6 tiles, +1 per 15 Fitness (Sec 4.0/4.6.3)
	var mult := weapon.move_multiplier if weapon else 1.0
	return maxi(1, roundi(base * mult))


func move_sprint() -> int:
	return move_run() * 2


func initiative() -> float:
	# Reflexes 60% + class base 30% + equipment 10% (Sec 4.1)
	return reflexes * 0.6 + class_base_initiative * 0.3 + equipment_initiative * 0.1
