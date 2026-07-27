class_name Combat
extends RefCounted
## Pure combat resolution functions (design doc Sec 6.5/4.6.4).

enum ShotAction { SHOOT, BARRAGE }

const HIGH_GROUND_BONUS := 15
const COVER_PENALTY_HEAVY := 40
const COVER_PENALTY_LIGHT := 20
const HUNKER_PENALTY := 20

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


class ShotResult:
	var hit: bool = false
	var accuracy: int = 0
	var damage: int = 0
	var cover_tile: Vector3i
	var had_cover: bool = false
	var flanked: bool = false
	var crit: bool = false
	var lucky_reroll: bool = false  # attacker's Luck saved an otherwise-missed shot
	var lucky_dodge: bool = false  # defender's Luck saved an otherwise-landed shot


static func find_defending_cover(shooter_pos: Vector3i, target_pos: Vector3i) -> Vector3i:
	# Which adjacent cover tile (if any) protects target from this shooter?
	# The cover must sit between them: the offset from target to cover must
	# point toward the shooter. Returns target_pos itself if no cover applies.
	var best := target_pos
	var best_pen := 0
	for cover_pos in GridManager.adjacent_cover_tiles(target_pos):
		var cover_dir := Vector2(cover_pos.x - target_pos.x, cover_pos.z - target_pos.z)
		var shot_dir := Vector2(shooter_pos.x - target_pos.x, shooter_pos.z - target_pos.z)
		if shot_dir.length() == 0:
			continue
		# Coarse flank check (Sec 6.2): cover counts only if the shooter is
		# within ~60 degrees of the cover's facing direction.
		if cover_dir.normalized().dot(shot_dir.normalized()) > 0.5:
			var t: GridTileData = GridManager.get_tile(cover_pos)
			var pen := COVER_PENALTY_HEAVY if t.cover_type == GridTileData.CoverType.HEAVY else COVER_PENALTY_LIGHT
			if pen > best_pen:
				best_pen = pen
				best = cover_pos
	return best


static func distance_penalty(dist: int) -> int:
	if dist <= DIST_FALLOFF_START:
		return 0
	if dist <= DIST_STEEP_START:
		return (dist - DIST_FALLOFF_START) * DIST_GENTLE_RATE
	var gentle := (DIST_STEEP_START - DIST_FALLOFF_START) * DIST_GENTLE_RATE
	return gentle + (dist - DIST_STEEP_START) * DIST_STEEP_RATE


static func light_modifier(target_pos: Vector3i) -> int:
	var t: GridTileData = GridManager.get_tile(target_pos)
	if t == null:
		return 0
	var lit := clampf(t.light_value, 0.0, 100.0) / 100.0
	return roundi(lerp(-float(LIGHT_DARK_PENALTY), float(LIGHT_BRIGHT_BONUS), lit))


static func compute_accuracy(shooter, target, action: ShotAction) -> int:
	var acc: int = shooter.stats.perception + shooter.stats.weapon_base_accuracy
	if action == ShotAction.SHOOT:
		acc += shooter.stats.reflexes
	if shooter.grid_pos.y > target.grid_pos.y:
		acc += HIGH_GROUND_BONUS
	var cover_pos := find_defending_cover(shooter.grid_pos, target.grid_pos)
	if cover_pos != target.grid_pos:
		var t: GridTileData = GridManager.get_tile(cover_pos)
		acc -= COVER_PENALTY_HEAVY if t.cover_type == GridTileData.CoverType.HEAVY else COVER_PENALTY_LIGHT
	if target.hunkered:
		acc -= HUNKER_PENALTY
	acc -= distance_penalty(GridManager.chebyshev_dist(shooter.grid_pos, target.grid_pos))
	acc += light_modifier(target.grid_pos)
	return clampi(acc, 1, 99)


static func resolve_shot(shooter, target, action: ShotAction) -> ShotResult:
	var result := ShotResult.new()
	result.accuracy = compute_accuracy(shooter, target, action)
	result.hit = randf() * 100.0 < result.accuracy

	# Attacker's Luck: a small chance to turn a missed roll into a hit.
	if not result.hit and randf() * 100.0 < shooter.stats.luck / LUCK_REROLL_DIVISOR:
		result.hit = true
		result.lucky_reroll = true

	if result.hit:
		# Crit is checked first and is guaranteed once rolled — a critical hit
		# cannot be dodged. Only a non-crit hit is subject to the defender's
		# Luck downgrading it back into a miss.
		if randf() * 100.0 < shooter.stats.luck / LUCK_CRIT_DIVISOR:
			result.crit = true
		elif randf() * 100.0 < target.stats.luck / LUCK_REROLL_DIVISOR:
			result.hit = false
			result.lucky_dodge = true

	if result.hit:
		result.damage = shooter.stats.weapon_damage * (CRIT_MULTIPLIER if result.crit else 1)

	# Sec 6.1.1: every shot at a unit in cover damages the cover, hit or miss.
	var cover_pos := find_defending_cover(shooter.grid_pos, target.grid_pos)
	if cover_pos != target.grid_pos:
		result.had_cover = true
		result.cover_tile = cover_pos
		GridManager.damage_cover(cover_pos, shooter.stats.weapon_damage)
	return result


static func describe(result: ShotResult) -> String:
	if result.crit:
		return "CRITICAL HIT for %d dmg!" % result.damage
	if result.hit:
		return "LUCKY HIT for %d dmg" % result.damage if result.lucky_reroll else "HIT for %d dmg" % result.damage
	if result.lucky_dodge:
		return "LUCKY DODGE"
	return "MISS"
