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
## Robots have no Fitness in any meaningful sense — the stat is reused rather
## than forked, but what it BUYS changed with the granular AP rework: Fitness is
## the AP pool now (rework doc Sec 4.2), so on this roster it reads as PACE. HP
## moved to `base_hp` and standing in the draw order to `base_initiative`, both
## hand-set per model exactly as Sec 4.5/5.5 prescribes for non-player units.
##
## The three are set INDEPENDENTLY, which is what the rework bought this table:
## Securus is the thickest thing on the board and slow, Proctor is the thinnest
## and fast, and neither is a compromise between the two any more. Every
## `initiative` pair lands on the draw weight that model has always had.
##
## HP AND DAMAGE ARE BOTH RESCALED, HP harder — the whole game moved to a ~20 HP
## soldier and ~8 damage rifle (UnitStats.base_hp, WeaponPresets), so this roster
## moved with it: HP to roughly 0.3x its old value and damage to roughly 0.65x.
## The ORDERING is untouched, and that is what to check a change against — 26 /
## 20 / 14 / 9 / 6 across Securus, Sagittarii, Auxilium, Lictor, Proctor is the
## same shape as the old 85 / 65 / 45 / 30 / 20. What moved is how many hits each
## rung is worth, which is the point: two or three, roster-wide, instead of five
## or six.

## MapData.Spawn kind -> scene. Loaded on demand rather than preloaded: main.gd
## only ever instantiates the types a deck actually places.
const SCENE := {
	MapData.Spawn.AUXILIUM: "res://scenes/auxilium_unit.tscn",
	MapData.Spawn.SAGITTARII: "res://scenes/sagittarii_unit.tscn",
	MapData.Spawn.PROCTOR: "res://scenes/proctor_unit.tscn",
	MapData.Spawn.SECURUS: "res://scenes/securus_unit.tscn",
	MapData.Spawn.LICTOR: "res://scenes/lictor_unit.tscn",
}

## `weapon` null means no ranged attack at all (mag_size 0 -> can_shoot() is
## false forever), the same way the alien swarm is unarmed at range.
##
## `fitness` is PACE (AP pool = 6 + 0.075 x Fitness, floored), `base_hp` carries
## toughness, and `initiative` is [base, equipment bonus] — both now additive
## terms rather than the 0-99 percentiles the old weighted average took.
const DATA := {
	MapData.Spawn.AUXILIUM: {
		"name": "QRN-4 Auxilium",
		# 7 AP: a shot (5) and two tiles. It anchors a doorway rather than roaming,
		# so the pool is spent covering an approach rather than crossing the map.
		"perception": 45, "reflexes": 35, "fitness": 20, "luck": 10,
		"base_hp": 13,  # -> 14 HP
		"initiative": [28, 5],  # -> 40
		"weapon": {"display_name": "QRN Sentry Gun", "base_accuracy": 25, "damage": 7, "mag_size": 8},
		"melee": [40, 4],
	},
	MapData.Spawn.SAGITTARII: {
		"name": "MKV-9 Sagittarii",
		# The smallest pool on the roster, and the clearest case for splitting
		# Fitness from HP: this is the unit that was always meant to be tanky AND
		# slow, and it could not be both while one number did both jobs. 6 AP
		# against a 6 AP shot means it fires or it walks, never both.
		#
		# That property briefly broke and came back, which is worth recording: when
		# the pool scaled 1.5x and Shoot did not, this became "fires AND shuffles
		# two tiles". Scaling Shoot with everything else restored it exactly. It is
		# an invariant of two numbers, not of one, and nothing in this block says so
		# on its own — the pool and the shot price have to move together.
		"perception": 55, "reflexes": 20, "fitness": 10, "luck": 10,
		"base_hp": 20,  # -> 20 HP
		"initiative": [18, 3],  # -> 25
		# Hits harder than anything the squad carries, and reloads less often. The
		# counterplay is exposure management, not a damage race — and on the
		# shortened HP scale that is no longer advice: 10 a hit is half a soldier.
		"weapon": {"display_name": "MKV Support Cannon", "base_accuracy": 30, "damage": 10, "mag_size": 5},
		"melee": [35, 5],
	},
	MapData.Spawn.PROCTOR: {
		"name": "XVT-7 Proctor",
		# High Perception and the best Reflexes on the board: it is built to see
		# and to leave, and its Initiative reflects that it usually reports first.
		# The biggest pool on the roster at 10 AP — leaving is the whole job.
		"perception": 70, "reflexes": 65, "fitness": 60, "luck": 25,
		"base_hp": 2,  # -> 6 HP: one solid hit ends it, which is now literally true
		"initiative": [45, 6],  # -> 64, still drawing with the squad
		"weapon": null,
		"melee": [20, 1],
	},
	MapData.Spawn.LICTOR: {
		"name": "FRC-6 Lictor",
		# The cover-breaker the no-flank doctrine needs (coordinated-ai Sec 5.2).
		# Thin plate and a 6 AP pool against a 6 AP shot: it fires exactly once and
		# folds quickly if reached, which is what keeps "shoot the demolition gun
		# first" a real answer to a squad that cannot be out-positioned.
		"perception": 60, "reflexes": 30, "fitness": 10, "luck": 10,
		"base_hp": 9,  # -> 9 HP, the roster's second-thinnest after Proctor
		"initiative": [24, 3],  # -> 33
		"weapon": {"display_name": "FRC Demolition Gun", "base_accuracy": 20, "damage": 4, "mag_size": 4},
		"melee": [25, 3],
	},
	MapData.Spawn.SECURUS: {
		"name": "JXM-2 Securus",
		# 7 AP against a 6 AP swing: one tile and a strike, or seven tiles. Slow,
		# but it closes — the threat is arrival.
		"perception": 50, "reflexes": 25, "fitness": 20, "luck": 10,
		"base_hp": 25,  # -> 26 HP, the thickest on either roster
		"initiative": [21, 4],  # -> 30
		"weapon": null,  # melee/breach only — the reason to fear it is the distance closing
		"melee": [60, 12],  # two connected swings kill a soldier outright
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
	stats.base_hp = d["base_hp"]
	stats.base_initiative = d["initiative"][0]
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
