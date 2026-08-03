class_name CerberusPresets
extends RefCounted
## Roster table for the security robots — the faction's answer to `ClassPresets`.
## Design: docs/design/factions/security-robots/
##
## Every number here is an alpha value, and the faction's own docs say so: the
## roster defers exact HP/Armor/damage to playtesting the same way the GDD defers
## its own combat numbers (Sec 12). What they are NOT is arbitrary — each one is
## the smallest set that makes the roster's stated shape true on screen:
##
##   Auxilium   moderate everything, armored enough that one snap shot rarely
##              settles it — which is what pushes the player toward a flank or a
##              2 AP Aimed Shot rather than trading pot shots with a sentry.
##   Sagittarii tanky and slow, with plate thick enough that ordinary rifle fire
##              is a losing trade. This is the unit EMP exists for.
##   Proctor    fragile, fast, unarmed. One solid hit should end it.
##   Securus    the wall. Only two things get through it quickly: an EMP window,
##              or breaking the head with Aimed Shots.
##
## Robots have no Fitness in any meaningful sense — the stat is reused because
## `UnitStats.max_hp()` is Fitness, and inventing a parallel HP path for one
## faction would fork the stat system for no gain.

## MapData.Spawn kind -> scene. Loaded on demand rather than preloaded: main.gd
## only ever instantiates the types a deck actually places.
const SCENE := {
	MapData.Spawn.AUXILIUM: "res://scenes/auxilium_unit.tscn",
	MapData.Spawn.SAGITTARII: "res://scenes/sagittarii_unit.tscn",
	MapData.Spawn.PROCTOR: "res://scenes/proctor_unit.tscn",
	MapData.Spawn.SECURUS: "res://scenes/securus_unit.tscn",
}

## `weapon` null means no ranged attack at all (mag_size 0 -> can_shoot() is
## false forever), the same way the alien swarm is unarmed at range.
const DATA := {
	MapData.Spawn.AUXILIUM: {
		"name": "QRN-4 Auxilium",
		"perception": 45, "reflexes": 35, "fitness": 45, "luck": 10,
		"initiative": [50, 45],
		"weapon": {"display_name": "QRN Sentry Gun", "base_accuracy": 25, "damage": 10, "mag_size": 8},
		"melee": [40, 6],
	},
	MapData.Spawn.SAGITTARII: {
		"name": "MKV-9 Sagittarii",
		"perception": 55, "reflexes": 20, "fitness": 65, "luck": 10,
		"initiative": [35, 30],
		# Hits harder than anything the squad carries, and reloads less often. The
		# counterplay is exposure management, not a damage race.
		"weapon": {"display_name": "MKV Support Cannon", "base_accuracy": 30, "damage": 16, "mag_size": 5},
		"melee": [35, 8],
	},
	MapData.Spawn.PROCTOR: {
		"name": "XVT-7 Proctor",
		# High Perception and the best Reflexes on the board: it is built to see
		# and to leave, and its Initiative reflects that it usually reports first.
		"perception": 70, "reflexes": 65, "fitness": 20, "luck": 25,
		"initiative": [65, 60],
		"weapon": null,
		"melee": [20, 2],
	},
	MapData.Spawn.SECURUS: {
		"name": "JXM-2 Securus",
		"perception": 50, "reflexes": 25, "fitness": 85, "luck": 10,
		"initiative": [40, 35],
		"weapon": null,  # melee/breach only — the reason to fear it is the distance closing
		"melee": [60, 18],
	},
}


static func make_stats(kind: int, index: int = 1) -> UnitStats:
	var d: Dictionary = DATA[kind]
	var stats := UnitStats.new()
	# Numbered only when a deck places more than one, so the common case reads as
	# a model designation rather than as a spawn slot.
	stats.display_name = "%s" % d["name"] if index <= 1 else "%s #%d" % [d["name"], index]
	stats.perception = d["perception"]
	stats.reflexes = d["reflexes"]
	stats.fitness = d["fitness"]
	stats.luck = d["luck"]
	stats.class_base_initiative = d["initiative"][0]
	stats.equipment_initiative = d["initiative"][1]
	stats.melee_base_accuracy = d["melee"][0]
	stats.melee_damage = d["melee"][1]
	stats.weapon = _make_weapon(d["weapon"])
	return stats


static func _make_weapon(spec) -> WeaponData:
	if spec == null:
		return null
	var w := WeaponData.new()
	w.display_name = spec["display_name"]
	w.base_accuracy = spec["base_accuracy"]
	w.damage = spec["damage"]
	w.mag_size = spec["mag_size"]
	# Unlimited reserve, like the aliens' inline weapon. A robot running dry
	# would be an attrition mechanic, and this faction's pressure is explicitly
	# positional rather than attritional — it fields no reinforcements either.
	w.starting_reserve = -1
	return w


static func scene_for(kind: int) -> PackedScene:
	return load(SCENE[kind]) as PackedScene


static func display_name(kind: int) -> String:
	return DATA[kind]["name"]
