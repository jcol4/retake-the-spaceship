class_name SoldierRecord
extends RefCounted
## One soldier on the campaign roster (extraction plan 4.1): who they are, what
## they rolled, what they carry, what is wrong with them. The persistent half of a
## PlayerUnit — main.gd builds the unit FROM this at spawn, and the debrief writes
## the unit's fate back INTO it.
##
## Engine-free and plain data (ints, strings, arrays of ints), so it saves to JSON,
## crosses the wire in a deployment (Campaign._rpc_deployment), and a --script test
## can build one without a scene.
##
## WHY THE STATS ARE STORED, NOT RE-ROLLED: a soldier is the same soldier every
## mission (GDD §2 "soldiers are permanent stakes"), and in co-op the client must
## build an identical unit. Sending the four numbers is both — the old path rolled
## a fresh squad from a shared seed every mission, which made every soldier a
## stranger and every co-op spawn depend on both peers consuming the RNG in
## lockstep.

## Stable roster key, "S<n>" off CampaignState.next_id. Never reused, so a debrief
## can never credit one soldier's fate to another who took their name.
var id: String = ""
var display_name: String = "Soldier"
var unit_class: UnitStats.UnitClass = UnitStats.UnitClass.ASSAULT
var perception: int = 50
var reflexes: int = 50
var fitness: int = 50
var luck: int = 50

## The loadout last deployed with (or the class default for a fresh recruit) — the
## loadout screen's preselection. A PREFERENCE, not a reservation: attachment
## copies belong to the stash, and only the copies fitted on the day are checked
## against it (CampaignState.make_deployment clamps, LoadoutMenu enforces).
var weapon_id: int = WeaponPresets.WeaponId.ASSAULT_RIFLE
var attachment_ids: Array[int] = []
## AmmoPresets id; -1 = Standard.
var ammo_id: int = -1

## Untreated body-part injuries (Combat.BodyPart values, sorted). GDD §4.2.1: they
## last until treated with the medical resource, so they ride into the next
## mission (Unit.apply_injuries) and out of it again (Unit.injured_parts).
var injuries: Array[int] = []
var missions_survived: int = 0


## A fresh soldier rolled within their class ranges (GDD §7.5 "rolled within class
## ranges, like today"), carrying the class's suggested weapon and nothing fitted.
static func roll(p_class: UnitStats.UnitClass, p_name: String, p_id: String, rng: RandomNumberGenerator = null) -> SoldierRecord:
	var stats := ClassPresets.roll(p_class, p_name, rng)
	var r := SoldierRecord.new()
	r.id = p_id
	r.display_name = p_name
	r.unit_class = p_class
	r.perception = stats.perception
	r.reflexes = stats.reflexes
	r.fitness = stats.fitness
	r.luck = stats.luck
	r.weapon_id = WeaponPresets.default_for_class(p_class)
	return r


## The stat block a PlayerUnit spawns with. Mirrors ClassPresets.roll (armored,
## the player baselines left at UnitStats' defaults) with the record's numbers and
## its loadout in place of the dice and the class default.
func to_stats() -> UnitStats:
	var stats := UnitStats.new()
	stats.armored = true  # see UnitStats.armored
	stats.display_name = display_name
	stats.unit_class = unit_class
	stats.perception = perception
	stats.reflexes = reflexes
	stats.fitness = fitness
	stats.luck = luck
	stats.weapon = WeaponPresets.make(weapon_id, PackedInt32Array(attachment_ids), ammo_id)
	return stats


## How good a roll this is within the class's own ranges, 0 (every stat at its
## floor) to 1 (every stat at its ceiling) — the price lever for recruits
## (CampaignEconomy.recruit_price). Within-class on purpose: a Sniper's Perception
## of 70 is ordinary and an Assault's is exceptional, and the price should say so.
func quality() -> float:
	var r: Dictionary = ClassPresets.RANGES[unit_class]
	var total := 0.0
	var values := {"perception": perception, "reflexes": reflexes, "fitness": fitness, "luck": luck}
	for key: String in values:
		var lo: int = r[key][0]
		var hi: int = r[key][1]
		total += clampf(float(values[key] - lo) / maxf(1.0, hi - lo), 0.0, 1.0)
	return total / values.size()


func class_name_text() -> String:
	return String(UnitStats.UnitClass.keys()[unit_class]).capitalize()


func max_hp() -> int:
	return to_stats().max_hp()


func is_injured() -> bool:
	return not injuries.is_empty()


func injury_text() -> String:
	if injuries.is_empty():
		return "None"
	var names := PackedStringArray()
	for part in injuries:
		names.append(Combat.body_part_name(part))
	return ", ".join(names)


func stats_text() -> String:
	return "Per %d  Ref %d  Fit %d  Luck %d  |  %d HP, %d AP" % [
		perception, reflexes, fitness, luck, to_stats().max_hp(), to_stats().ap_pool()]


func loadout_text() -> String:
	var item := ItemPresets.make_weapon(weapon_id, PackedInt32Array(attachment_ids), ammo_id)
	return item.display_name if item != null else "?"


## Takes a deployed weapon's actual fit back into the record (the debrief, for a
## soldier who came home with it).
func set_loadout(p_weapon_id: int, p_attachments: Array, p_ammo_id: int) -> void:
	weapon_id = p_weapon_id
	attachment_ids.clear()
	for a in p_attachments:
		attachment_ids.append(int(a))
	attachment_ids.sort()
	ammo_id = p_ammo_id


func set_injuries(parts: Array) -> void:
	injuries.clear()
	for p in parts:
		if not injuries.has(int(p)):
			injuries.append(int(p))
	injuries.sort()


func to_dict() -> Dictionary:
	return {
		"id": id, "name": display_name, "class": int(unit_class),
		"perception": perception, "reflexes": reflexes, "fitness": fitness, "luck": luck,
		"weapon": weapon_id, "attachments": attachment_ids.duplicate(), "ammo": ammo_id,
		"injuries": injuries.duplicate(), "missions": missions_survived,
	}


## Every number is cast back to int: JSON hands them all back as floats, and an
## enum compared against 2.0 is a quiet bug.
static func from_dict(d: Dictionary) -> SoldierRecord:
	var r := SoldierRecord.new()
	r.id = String(d.get("id", ""))
	r.display_name = String(d.get("name", "Soldier"))
	r.unit_class = clampi(int(d.get("class", 0)), 0, UnitStats.UnitClass.size() - 1) as UnitStats.UnitClass
	r.perception = int(d.get("perception", 50))
	r.reflexes = int(d.get("reflexes", 50))
	r.fitness = int(d.get("fitness", 50))
	r.luck = int(d.get("luck", 50))
	var weapon := int(d.get("weapon", WeaponPresets.default_for_class(r.unit_class)))
	if not (weapon in WeaponPresets.PRIMARY_IDS):
		weapon = WeaponPresets.default_for_class(r.unit_class)
	r.set_loadout(weapon, d.get("attachments", []), int(d.get("ammo", -1)))
	r.set_injuries(d.get("injuries", []))
	r.missions_survived = int(d.get("missions", 0))
	return r
