class_name Combat
extends RefCounted
## Pure combat resolution functions (design doc Sec 6.5/4.6.4).

enum ShotAction { SHOOT, AIMED_SHOT, OVERWATCH }

## VATS-style targeting zones for Aimed Shot (Sec 4.2/6.5 body-part targeting).
enum BodyPart { HEAD, TORSO, ARM_L, ARM_R, LEG_L, LEG_R }

const HIGH_GROUND_BONUS := 15
const COVER_PENALTY_HEAVY := 40
const COVER_PENALTY_LIGHT := 20
const HUNKER_PENALTY := 20
const OVERWATCH_PENALTY := 30  # flat accuracy hit on top of a normal Shoot's math

# Aimed Shot accuracy relative to the "no Reflexes" full-aim baseline (Sec 6.5):
# Torso is the easy, reliable target; limbs are harder; the head is a severe ask.
const ZONE_ACCURACY_MOD := {
	BodyPart.TORSO: 0,
	BodyPart.ARM_L: -20, BodyPart.ARM_R: -20,
	BodyPart.LEG_L: -20, BodyPart.LEG_R: -20,
	BodyPart.HEAD: -50,
}

# Light modifier (Sec 5.1): linear between a dark target (penalty) and a
# fully-lit one (bonus). GridTileData.light_value is written by LightingManager.
const LIGHT_DARK_PENALTY := 30  # accuracy penalty at light_value 0
const LIGHT_BRIGHT_BONUS := 10  # accuracy bonus at light_value 100

# Distance falloff (Sec 6.5): flat out to DIST_FALLOFF_START tiles, a gentle
# climb out to DIST_STEEP_START, then a dramatic per-tile penalty beyond that.
const DIST_FALLOFF_START := 3  # tiles — no penalty at or within this range
const DIST_STEEP_START := 10  # tiles — where the steep segment kicks in
const DIST_GENTLE_RATE := 1  # % per tile, between FALLOFF_START and STEEP_START
const DIST_STEEP_RATE := 12  # % per tile, beyond STEEP_START

# Luck (Sec 4.6.4): crit chance and attacker's miss-reroll both scale off the
# shooter's Luck; the defender's Luck can independently downgrade a landed
# non-crit hit back into a miss, using that same reroll rate.
const LUCK_CRIT_DIVISOR := 4.0
const LUCK_REROLL_DIVISOR := 8.0
const CRIT_MULTIPLIER := 2

# A headshot doubles the normal crit roll (half the divisor), and a crit rolled
# on a headshot has a further chance to upgrade to a severe critical.
const HEADSHOT_CRIT_DIVISOR := LUCK_CRIT_DIVISOR / 2.0
const SEVERE_CRIT_DIVISOR := 8.0
const SEVERE_CRIT_MULTIPLIER := 3


class ShotResult:
	var hit: bool = false
	var accuracy: int = 0
	var damage: int = 0
	# Which edge of the TARGET'S OWN tile defended the shot. Under edge cover the
	# target stands on the covered tile, so `cover_tile` is always target_pos and
	# `cover_side` is what actually identifies the prop.
	var cover_tile: Vector3i
	var cover_side: int = -1
	var cover_type: int = MapData.Cover.NONE  # tier that applied, before this shot
	var cover_broken: bool = false  # this shot knocked that tier down
	var had_cover: bool = false
	var flanked: bool = false
	var crit: bool = false
	var severe_crit: bool = false  # headshot-only upgrade over a normal crit
	var lucky_reroll: bool = false  # attacker's Luck saved an otherwise-missed shot
	var lucky_dodge: bool = false  # defender's Luck saved an otherwise-landed shot
	# Damage the target's Armor swallowed (security robots). `damage` above is
	# what actually landed once this was taken off, so the two together are the
	# whole story of one hit and the log never has to guess which it is holding.
	var absorbed: int = 0
	var body_part: int = -1  # Combat.BodyPart targeted, only set for AIMED_SHOT
	var newly_injured: bool = false  # this hit just crossed the targeted part's injury threshold
	var stunned: bool = false  # a torso crit stuns the target for its next activation


## Which edge of the target's tile, if any, this shot has to cross — as
## [MapData.Cover tier, MapData.Side], or [NONE, -1] when the target is exposed.
##
## Replaces the old 60-degree dot-product flank heuristic (Sec 6.2). Cover
## direction is discrete now, so this is a lookup rather than an estimate: take
## the sign of the shooter's offset on each axis and read the edge it points at.
##
## A shot straight down an axis has one non-zero component and therefore tests
## one edge. A DIAGONAL shot crosses a corner rather than an edge, so both
## adjacent sides are tested and the stronger one applies — the XCOM rule, and
## the generous reading: a unit tucked into a corner is genuinely harder to hit
## from the diagonal than from either open side.
static func defending_cover(shooter_pos: Vector3i, target_pos: Vector3i) -> Array:
	var best_type := MapData.Cover.NONE
	var best_side := -1
	var dx := signi(shooter_pos.x - target_pos.x)
	var dz := signi(shooter_pos.z - target_pos.z)
	var sides: Array[int] = []
	if dx != 0:
		sides.append(MapData.Side.EAST if dx > 0 else MapData.Side.WEST)
	if dz != 0:
		sides.append(MapData.Side.SOUTH if dz > 0 else MapData.Side.NORTH)
	for side in sides:
		var t := GridManager.cover_type_on(target_pos, side)
		# HEAVY sorts above LIGHT sorts above NONE in the enum, so the comparison
		# is the tier comparison. Strictly greater, so on a tie the x edge wins
		# and the result is deterministic.
		if t > best_type:
			best_type = t
			best_side = side
	return [best_type, best_side]


static func cover_penalty(cover_type: int) -> int:
	match cover_type:
		MapData.Cover.HEAVY: return COVER_PENALTY_HEAVY
		MapData.Cover.LIGHT: return COVER_PENALTY_LIGHT
		_: return 0


static func distance_penalty(dist: int) -> int:
	if dist <= DIST_FALLOFF_START:
		return 0
	if dist <= DIST_STEEP_START:
		return (dist - DIST_FALLOFF_START) * DIST_GENTLE_RATE
	var gentle := (DIST_STEEP_START - DIST_FALLOFF_START) * DIST_GENTLE_RATE
	return gentle + (dist - DIST_STEEP_START) * DIST_STEEP_RATE


static func weapon_range_penalty(weapon: WeaponData, dist: int) -> int:
	# Weapon-specific range falloff (design doc `weapons/`), stacked on top of
	# the global distance curve above. Shotgun/SMG use this to be noticeably
	# worse past their optimal range; most weapons leave it at 0 and rely on
	# the global curve alone.
	if weapon == null or weapon.falloff_rate <= 0 or dist <= weapon.optimal_range:
		return 0
	return (dist - weapon.optimal_range) * weapon.falloff_rate


static func light_modifier(target_pos: Vector3i) -> int:
	var t: GridTileData = GridManager.get_tile(target_pos)
	if t == null:
		return 0
	var lit := clampf(t.light_value, 0.0, 100.0) / 100.0
	return roundi(lerp(-float(LIGHT_DARK_PENALTY), float(LIGHT_BRIGHT_BONUS), lit))


## Whether the Sec 5.1 light term applies to a roll between these two at all.
##
## It does not when either side is a security robot: their sensors do not read
## light, so a tile at 0% and a tile at 100% are the same tile to them, whether
## they are the ones shooting or the ones being shot at. This is the faction's
## central mechanical bet — killing the lights is the answer to the aliens and
## buys nothing here — so it is a flat exception to the formula rather than a
## modifier inside it.
##
## Duck-typed rather than checked against `CerberusUnit` on purpose: `Combat` is
## loaded standalone by the headless tools, and naming a unit class here would
## drag the whole scene-tree-dependent half of the project in with it.
static func light_matters(shooter, target) -> bool:
	return not _light_agnostic(shooter) and not _light_agnostic(target)


static func _light_agnostic(unit) -> bool:
	return unit != null and unit.has_method("light_agnostic") and unit.light_agnostic()


static func compute_accuracy(shooter, target, action: ShotAction, body_part: int = BodyPart.TORSO) -> int:
	var acc: int = shooter.stats.perception + shooter.stats.weapon_base_accuracy
	if action == ShotAction.SHOOT or action == ShotAction.OVERWATCH:
		acc += shooter.stats.reflexes
	if action == ShotAction.OVERWATCH:
		acc -= OVERWATCH_PENALTY
	if action == ShotAction.AIMED_SHOT:
		acc += ZONE_ACCURACY_MOD.get(body_part, 0)
	if shooter.grid_pos.y > target.grid_pos.y:
		acc += HIGH_GROUND_BONUS
	# Asked of the SHOOTER rather than read from the flat table, so a weapon that
	# partly ignores cover (Sagittarii's) affects the HUD's preview and the shot
	# it fires through one code path instead of two that can disagree.
	acc -= shooter.cover_penalty_for(defending_cover(shooter.grid_pos, target.grid_pos)[0])
	if target.hunkered:
		acc -= HUNKER_PENALTY
	var dist := GridManager.chebyshev_dist(shooter.grid_pos, target.grid_pos)
	acc -= distance_penalty(dist)
	acc -= weapon_range_penalty(shooter.stats.weapon, dist)
	if light_matters(shooter, target):
		acc += light_modifier(target.grid_pos)
	acc -= shooter.ranged_accuracy_penalty()  # Sec 4.2: an injured arm shakes every ranged shot, not just melee
	return clampi(acc, 1, 99)


static func _roll_hit(result: ShotResult, attacker, target, crit_divisor: float = LUCK_CRIT_DIVISOR) -> void:
	# The Luck layer (Sec 4.6.4), shared by shots and melee — only the accuracy
	# that feeds it and the damage read off the far side differ between them.
	# Expects result.accuracy already set; writes hit/crit/lucky_* in place.
	# `crit_divisor` lets a headshot roll crit at double the normal rate.
	result.hit = randf() * 100.0 < result.accuracy

	# Attacker's Luck: a small chance to turn a missed roll into a hit.
	if not result.hit and randf() * 100.0 < attacker.stats.luck / LUCK_REROLL_DIVISOR:
		result.hit = true
		result.lucky_reroll = true

	if result.hit:
		# Crit is checked first and is guaranteed once rolled — a critical hit
		# cannot be dodged. Only a non-crit hit is subject to the defender's
		# Luck downgrading it back into a miss.
		if randf() * 100.0 < attacker.stats.luck / crit_divisor:
			result.crit = true
		elif randf() * 100.0 < target.stats.luck / LUCK_REROLL_DIVISOR:
			result.hit = false
			result.lucky_dodge = true


static func resolve_shot(shooter, target, action: ShotAction, body_part: int = BodyPart.TORSO) -> ShotResult:
	var result := ShotResult.new()
	result.accuracy = compute_accuracy(shooter, target, action, body_part)
	var is_headshot := action == ShotAction.AIMED_SHOT and body_part == BodyPart.HEAD
	_roll_hit(result, shooter, target, HEADSHOT_CRIT_DIVISOR if is_headshot else LUCK_CRIT_DIVISOR)

	if result.hit:
		var mult := CRIT_MULTIPLIER if result.crit else 1
		if is_headshot and result.crit and randf() * 100.0 < shooter.stats.luck / SEVERE_CRIT_DIVISOR:
			result.severe_crit = true
			mult = SEVERE_CRIT_MULTIPLIER
		result.damage = shooter.stats.weapon_damage * mult
		if action == ShotAction.AIMED_SHOT:
			result.body_part = body_part
			# Sec 4.2: a crit to center-mass knocks the wind out of them.
			if body_part == BodyPart.TORSO and result.crit:
				result.stunned = true

	# Sec 6.1.1: every shot at a unit in cover damages the cover, hit or miss.
	var defence := defending_cover(shooter.grid_pos, target.grid_pos)
	if defence[0] != MapData.Cover.NONE:
		result.had_cover = true
		result.cover_tile = target.grid_pos
		result.cover_side = defence[1]
		result.cover_type = defence[0]
		var left := GridManager.damage_cover_edge(
			target.grid_pos, defence[1], shooter.stats.weapon_damage)
		result.cover_broken = left != defence[0]
	return result


static func body_part_name(part: int) -> String:
	match part:
		BodyPart.HEAD: return "Head"
		BodyPart.TORSO: return "Torso"
		BodyPart.ARM_L: return "Left Arm"
		BodyPart.ARM_R: return "Right Arm"
		BodyPart.LEG_L: return "Left Leg"
		BodyPart.LEG_R: return "Right Leg"
		_: return "?"


static func compute_melee_accuracy(attacker, target) -> int:
	# Melee happens at contact range, so the modifiers that exist to model
	# *distance* are all deliberately absent (Sec 11.4):
	#   - cover: a crate can't shield a body something is already on top of,
	#   - distance falloff: zero by definition at one tile,
	#   - light: darkness changes what you can shoot, not what a claw can reach —
	#     and taken the other way it would make standing in the dark a defence
	#     against the swarm, which is backwards for the game's whole premise.
	# What's left is the attacker's own skill, elevation, hunkering, and Luck.
	var acc: int = attacker.stats.perception + attacker.stats.melee_base_accuracy
	if attacker.grid_pos.y > target.grid_pos.y:
		acc += HIGH_GROUND_BONUS
	if target.hunkered:
		acc -= HUNKER_PENALTY
	acc -= attacker.melee_accuracy_penalty()
	return clampi(acc, 1, 99)


static func resolve_melee(attacker, target) -> ShotResult:
	# Reuses ShotResult so `describe` and the HUD log read one shape for every
	# attack; the cover fields simply stay unset. Melee doesn't damage cover
	# either — the swing never travels through it.
	var result := ShotResult.new()
	result.accuracy = compute_melee_accuracy(attacker, target)
	_roll_hit(result, attacker, target)
	if result.hit:
		var base_damage := roundi(attacker.stats.melee_damage * attacker.melee_damage_multiplier())
		result.damage = base_damage * (CRIT_MULTIPLIER if result.crit else 1)
	return result


static func describe(result: ShotResult) -> String:
	# Armor is called out rather than folded silently into a smaller number: a
	# player who cannot see the plate eating half the shot has no way to work out
	# that the EMP grenade in their kit is the answer.
	var armor := " (-%d armor)" % result.absorbed if result.absorbed > 0 else ""
	if result.severe_crit:
		return "SEVERE CRITICAL for %d dmg!!%s" % [result.damage, armor]
	if result.crit:
		return "CRITICAL HIT for %d dmg!%s" % [result.damage, armor]
	if result.hit:
		var verb := "LUCKY HIT" if result.lucky_reroll else "HIT"
		return "%s for %d dmg%s" % [verb, result.damage, armor]
	if result.lucky_dodge:
		return "LUCKY DODGE"
	return "MISS"
