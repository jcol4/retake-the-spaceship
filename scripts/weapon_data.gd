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
# No move_multiplier. A heavier weapon used to scale the carrier's Run/Sprint
# tile allowance, and the granular AP rework deleted the allowance — movement is
# a flat 1 AP per tile for every unit (Unit.MOVE_AP_PER_TILE). Retired rather
# than re-expressed: the LMG's 0.75 was the only non-1.0 value the table ever
# held, and the two candidate homes both cost more than it was worth (a pool cut
# would quietly take shots and reloads away too; a per-tile surcharge would put a
# weapon in the one place the rework wanted kept stat-free).

# AP added to the base price of this weapon's firing actions (Shoot, Aimed Shot,
# Overwatch, Suppress) and of its Reload, before the Reflexes discount — see
# `ap_modifier`. 0 for every weapon today; positive is a heavier, slower gun,
# negative a handier one. Attachments stack onto these per action.
@export var fire_ap_modifier: int = 0
@export var reload_ap_modifier: int = 0

# How many tiles this weapon's gunfire carries (Sec 5.4) — every unit with an
# awareness state inside it hears the shot. 5 matches SecurityNetwork.NOISE_RADIUS,
# the old flat value every gun used; it can't be named here (see
# Unit.gunfire_noise_radius), so keep the two in step by hand.
@export var noise_radius: int = 5

# --- Attachments and ammo (design doc `weapons/attachments.md`) --------------
# One attachment per slot, null for empty, plus one ammo type (null = Standard).
# All of them are WeaponMods; read the totals through the accessors below, never
# the raw fields, or the mods silently stop doing anything. Stacking rules are
# in WeaponMod.
@export var underbarrel: AttachmentData = null
@export var barrel: AttachmentData = null
@export var optic: AttachmentData = null
@export var magazine: AttachmentData = null
@export var stock: AttachmentData = null
@export var ammo: AmmoData = null

## The actions whose AP price a weapon can change.
enum ApAction { SHOOT, AIMED, OVERWATCH, SUPPRESS, RELOAD }

const _AP_FIELDS := {
	ApAction.SHOOT: &"shoot_ap", ApAction.AIMED: &"aimed_ap",
	ApAction.OVERWATCH: &"overwatch_ap", ApAction.SUPPRESS: &"suppress_ap",
	ApAction.RELOAD: &"reload_ap",
}

## The most any one action's price can come DOWN, however the discounts stack.
## Without it Laser Sight + an optic + a stock takes Shoot from 5 AP to 2 and a
## soldier fires four times a turn. Price increases aren't capped.
const MAX_AP_DISCOUNT := 2


func get_attachment(slot: AttachmentData.Slot) -> AttachmentData:
	match slot:
		AttachmentData.Slot.UNDERBARREL: return underbarrel
		AttachmentData.Slot.BARREL: return barrel
		AttachmentData.Slot.OPTIC: return optic
		AttachmentData.Slot.MAGAZINE: return magazine
		AttachmentData.Slot.STOCK: return stock
	return null


## Fits `attachment` into its own slot, replacing whatever was there.
func set_attachment(attachment: AttachmentData) -> void:
	match attachment.slot:
		AttachmentData.Slot.UNDERBARREL: underbarrel = attachment
		AttachmentData.Slot.BARREL: barrel = attachment
		AttachmentData.Slot.OPTIC: optic = attachment
		AttachmentData.Slot.MAGAZINE: magazine = attachment
		AttachmentData.Slot.STOCK: stock = attachment


func attachments() -> Array[AttachmentData]:
	var out: Array[AttachmentData] = []
	for a in [underbarrel, barrel, optic, magazine, stock]:
		if a != null:
			out.append(a)
	return out


## Every attachment plus the ammo.
func mods() -> Array[WeaponMod]:
	var out: Array[WeaponMod] = []
	out.append_array(attachments())
	if ammo != null:
		out.append(ammo)
	return out


func _bonus(stat: StringName) -> int:
	var total := 0
	for m in mods():
		total += m.get(stat)
	return total


## `stat` summed over only the mods whose close range reaches `dist`.
func _close_bonus(stat: StringName, dist: int) -> int:
	var total := 0
	for m in mods():
		if m.close_range > 0 and dist <= m.close_range:
			total += m.get(stat)
	return total


func _product(stat: StringName) -> float:
	var total := 1.0
	for m in mods():
		total *= m.get(stat)
	return total


# --- Accuracy ---

## The flat part only. Combat adds `close_accuracy_at` once it knows the range.
func effective_accuracy() -> int:
	return base_accuracy + _bonus(&"accuracy")


func close_accuracy_at(dist: int) -> int:
	return _close_bonus(&"close_accuracy", dist)


func ignores_darkness() -> bool:
	for m in mods():
		if m.ignores_darkness:
			return true
	return false


# --- Damage ---

## Total damage percent against a target. Every percent adds (WeaponMod).
func damage_percent(target_armored: bool, dist: int) -> int:
	var pct := _bonus(&"damage_pct") + _close_bonus(&"close_damage_pct", dist)
	pct += _bonus(&"damage_pct_vs_armored") if target_armored else _bonus(&"damage_pct_vs_unarmored")
	return pct


## What a hit on this target does, before crits. Rounded to nearest.
func damage_against(target_armored: bool, dist: int) -> int:
	return maxi(0, roundi(damage * (100 + damage_percent(target_armored, dist)) / 100.0))


## Damage with no particular target in mind — only the unconditional percent.
## What chips cover and what the loadout screen and AI estimates read.
func effective_damage() -> int:
	return maxi(0, roundi(damage * (100 + _bonus(&"damage_pct")) / 100.0))


# --- Ammo and range ---

## Floored at 1 so a mod can never turn a gun into one that can't fire. An
## unarmed weapon (mag 0) stays at 0.
func effective_mag_size() -> int:
	if mag_size <= 0:
		return mag_size
	return maxi(1, mag_size + _bonus(&"mag_size"))


func effective_reserve() -> int:
	if starting_reserve < 0:
		return starting_reserve  # unlimited stays unlimited
	return maxi(0, starting_reserve + _bonus(&"reserve"))


func effective_optimal_range() -> int:
	return optimal_range + _bonus(&"optimal_range")


func effective_falloff_rate() -> int:
	if falloff_rate <= 0:
		return falloff_rate  # no falloff to reduce, and a bonus can't create one
	return maxi(0, falloff_rate + _bonus(&"falloff_rate"))


# --- AP ---

## AP added to `action`'s base price: the weapon's own modifier plus every mod's,
## never below -MAX_AP_DISCOUNT.
func ap_modifier(action: ApAction) -> int:
	var base := reload_ap_modifier if action == ApAction.RELOAD else fire_ap_modifier
	return maxi(-MAX_AP_DISCOUNT, base + _bonus(_AP_FIELDS[action]))


# --- Detection ---

func effective_noise_radius() -> int:
	return maxi(0, roundi(noise_radius * _product(&"noise_multiplier")))


## How much further (or nearer) enemies can see the carrier.
func visibility_multiplier() -> float:
	return _product(&"visibility_multiplier")
