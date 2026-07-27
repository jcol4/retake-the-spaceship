class_name WeaponData
extends Resource
## A player-selectable weapon's stats (design doc `weapons/`). Decoupled from
## class — any soldier can carry any weapon; see `WeaponPresets` for the roster.

@export var id: int = -1  # WeaponPresets.WeaponId
@export var display_name: String = "Unarmed"
@export var base_accuracy: int = 0
@export var damage: int = 0
@export var mag_size: int = 0
# Weapon-specific range falloff, stacked on top of Combat's global distance
# curve (Sec 6.5). No penalty at or within `optimal_range`; beyond it, accuracy
# drops an extra `falloff_rate`% per tile. Default (999/0) means "no weapon-
# specific range penalty" — just the global curve.
@export var optimal_range: int = 999
@export var falloff_rate: int = 0
# Multiplies UnitStats.move_run()/move_sprint() — a heavier weapon can slow its
# carrier down. 1.0 means no penalty.
@export var move_multiplier: float = 1.0
