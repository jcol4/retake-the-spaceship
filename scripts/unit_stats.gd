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
@export var weapon_base_accuracy: int = 30
@export var weapon_damage: int = 12
@export var mag_size: int = 6
@export var class_base_initiative: int = 50
@export var equipment_initiative: int = 50


func max_hp() -> int:
	return fitness  # +1 max HP per Fitness point (Sec 4.6.3)


func move_run() -> int:
	return 4 + fitness / 20  # base 4 tiles, +1 per 20 Fitness (Sec 4.0/4.6.3)


func move_sprint() -> int:
	return move_run() * 2


func initiative() -> float:
	# Reflexes 60% + class base 30% + equipment 10% (Sec 4.1)
	return reflexes * 0.6 + class_base_initiative * 0.3 + equipment_initiative * 0.1
