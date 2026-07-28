class_name WeaponData
extends Resource
## A player-selectable weapon's stats (design doc `weapons/`). Decoupled from
## class — any soldier can carry any weapon; see `WeaponPresets` for the roster.

@export var id: int = -1  # WeaponPresets.WeaponId
@export var display_name: String = "Unarmed"
@export var base_accuracy: int = 0
@export var damage: int = 0
@export var mag_size: int = 0
# Spare rounds carried beyond the loaded magazine — the total mission ammo
# budget is mag_size + starting_reserve. -1 means unlimited (the default, so
# non-roster weapons like the alien's inline WeaponData in `main.gd` keep the
# old infinite-reload behavior unless they opt into a finite reserve).
@export var starting_reserve: int = -1
# Weapon-specific range falloff, stacked on top of Combat's global distance
# curve (Sec 6.5). No penalty at or within `optimal_range`; beyond it, accuracy
# drops an extra `falloff_rate`% per tile. Default (999/0) means "no weapon-
# specific range penalty" — just the global curve.
@export var optimal_range: int = 999
@export var falloff_rate: int = 0
# Multiplies UnitStats.move_run()/move_sprint() — a heavier weapon can slow its
# carrier down. 1.0 means no penalty.
@export var move_multiplier: float = 1.0
