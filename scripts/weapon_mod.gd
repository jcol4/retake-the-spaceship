class_name WeaponMod
extends Resource
## Anything fitted to or loaded into a weapon that changes its stats: the base of
## AttachmentData and AmmoData (design doc `weapons/attachments.md`). Every field
## is a bonus on the carrying weapon; WeaponData is the only place they're summed.
##
## Stacking rules:
## - Accuracy, mag, reserve, range, falloff and AP are flat and ADD.
## - Damage percentages ADD across every mod: Long Barrel (+20%) with Hollow
##   Point (+50%) is +70%, not x1.8.
## - Noise and visibility multipliers MULTIPLY: Suppressor (x0.5) with Subsonic
##   (x0.7) is x0.35.
## - AP discounts are capped per action — see WeaponData.MAX_AP_DISCOUNT.

@export var id: int = -1
@export var display_name: String = ""

# --- Accuracy (points on the hit chance) ---
@export var accuracy: int = 0
# Extra accuracy only when the target is within `close_range` tiles (inclusive).
@export var close_accuracy: int = 0
# Removes the darkness penalty on the target's tile (a lit bonus still applies).
@export var ignores_darkness: bool = false

# --- Damage (percent of the weapon's base damage) ---
@export var damage_pct: int = 0
@export var damage_pct_vs_armored: int = 0
@export var damage_pct_vs_unarmored: int = 0
# Extra damage percent only when the target is within `close_range` tiles.
@export var close_damage_pct: int = 0
# Tiles, inclusive, for the two `close_` bonuses above. 0 = they never apply.
@export var close_range: int = 0

# --- Ammo capacity and range ---
@export var mag_size: int = 0
@export var reserve: int = 0  # ignored on a weapon with unlimited reserve (-1)
# Tiles added to the weapon's optimal range, and %/tile taken off its falloff.
# Both only matter on a weapon that has a falloff to begin with.
@export var optimal_range: int = 0
@export var falloff_rate: int = 0

# --- AP, added to each action's base price before the Reflexes discount ---
@export var shoot_ap: int = 0
@export var aimed_ap: int = 0
@export var overwatch_ap: int = 0
@export var suppress_ap: int = 0
@export var reload_ap: int = 0

# --- Detection ---
# Scales how far this weapon's gunfire carries (WeaponData.noise_radius).
@export var noise_multiplier: float = 1.0
# Scales how far enemies can SEE the carrier (a laser dot is a tell).
@export var visibility_multiplier: float = 1.0

## Keys a preset table may set, and the loadout screen's label for each.
const LABELS := {
	"accuracy": "Acc", "close_accuracy": "Acc up close", "damage_pct": "Dmg%",
	"damage_pct_vs_armored": "Dmg% vs armor", "damage_pct_vs_unarmored": "Dmg% vs unarmored",
	"close_damage_pct": "Dmg% up close", "mag_size": "Mag", "reserve": "Reserve",
	"optimal_range": "Range", "falloff_rate": "Falloff", "shoot_ap": "Shoot AP",
	"aimed_ap": "Aimed AP", "overwatch_ap": "Overwatch AP", "suppress_ap": "Suppress AP",
	"reload_ap": "Reload AP",
}


## Copies every key `spec` sets onto this mod. Unknown keys are an authoring
## error in a preset table, so they fail loudly rather than silently doing nothing.
func apply_spec(spec: Dictionary) -> void:
	for key in spec:
		assert(key in self, "WeaponMod has no field '%s'" % key)
		set(key, spec[key])


## "+5 Acc, -1 Shoot AP" — the loadout screen's one-line readout of a preset.
static func describe_spec(spec: Dictionary) -> String:
	var parts: PackedStringArray = []
	for key in LABELS:
		var v: int = spec.get(key, 0)
		if v != 0:
			parts.append("%+d %s" % [v, LABELS[key]])
	if spec.has("close_range"):
		parts.append("up close = within %d tiles" % spec["close_range"])
	if spec.get("noise_multiplier", 1.0) != 1.0:
		parts.append("Noise x%s" % spec["noise_multiplier"])
	if spec.get("visibility_multiplier", 1.0) != 1.0:
		parts.append("Seen from x%s" % spec["visibility_multiplier"])
	if spec.get("ignores_darkness", false):
		parts.append("No dark penalty")
	return ", ".join(parts)
