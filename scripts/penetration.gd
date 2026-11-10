class_name Penetration
extends RefCounted
## Bullet penetration and buckshot splash (docs/design/systems/penetration).
##
## A round travels a Bresenham tile line from the shooter through the target and
## on past it until something stops it, and every body on that line gets a roll
## of its own. Penetration is a percentile weapon stat: every PEN_PER_BODY of it
## is one more body the round can pass THROUGH (the first hit is free), and the
## unfloored remainder sets how much damage it keeps per pass — so two guns in
## the same bracket still differ.
##
## The shooter's own faction ducks: it is invisible to the round and costs it
## nothing. Everybody else is fair game, seen or not, which is how a stray round
## wakes a dormant horde in the dark.
##
## Host side, like every shot. `Unit.fire_at` applies the damage; this only rolls.

## Pen spent passing through one body, or one light cover edge, and the size of
## one bracket. An armored body costs it twice.
const PEN_PER_BODY := 25
## Accuracy taken off a shot at the target for every body in front of it. The
## roll on EVERY body on the path is then the lower of that and its own odds.
const THROUGH_BODY_PENALTY := 30
## How far past the target the line is followed before giving up. Walls stop it
## long before this on any real deck.
const MAX_TRACE := 64
## How far above its deck's floor a standing body can be hit — a little over a
## head. A line passing higher than this over a tile misses whoever is on it.
const BODY_TOP := 1.9


## Bodies a round with `pen` passes through.
static func bodies_for(pen: int) -> int:
	return pen / PEN_PER_BODY


## Fraction of damage a round with `pen` keeps per body (or light cover) it
## passes through: b / (b + 1) on the unfloored body count.
static func keep_for(pen: int) -> float:
	var b := float(pen) / PEN_PER_BODY
	return b / (b + 1.0)


## Whether `shooter` can put a round on `target` at all: it has line of sight AND
## the round can get through every body in front of it, assuming each is hit
## (a miss costs nothing, so that is the most it can cost). A body in front
## behind heavy cover is a wall. Buckshot has no penetration, so this is how a
## shotgun is kept from shooting past anybody standing in the way.
static func can_reach(shooter: Unit, target: Unit) -> bool:
	if not GridManager.has_line_of_sight(shooter, target):
		return false
	var pen := _pen_of(shooter)
	for entry: Dictionary in trace(shooter, target, false):
		var body: Unit = entry["unit"]
		if body == target:
			return true
		var tier: int = Combat.defending_cover(shooter.grid_pos, body.grid_pos)[0]
		if tier == MapData.Cover.HEAVY:
			return false
		var cost: int = _body_cost(body, tier, true)[0]
		if pen < cost:
			return false
		pen -= cost
	return true


## Accuracy a shot at `target` loses to the bodies standing in front of it —
## what the HUD's hit chance has to take off to be honest.
static func through_penalty(shooter: Unit, target: Unit) -> int:
	var front := 0
	for entry: Dictionary in trace(shooter, target, false):
		if entry["unit"] != target:
			front += 1
	return THROUGH_BODY_PENALTY * front


## The whole shot: the result on the intended target, with every other body the
## round was rolled against in its `collateral`. Rolls only: units take their
## damage in `Unit.fire_at`, but cover is chipped here, at roll time, as a plain
## shot always has.
static func resolve(shooter: Unit, target: Unit, action: Combat.ShotAction, body_part: int) -> Combat.ShotResult:
	var weapon := shooter.stats.active_weapon()
	if weapon != null and weapon.effective_splash():
		return _resolve_splash(shooter, target, action, body_part)

	var pen := _pen_of(shooter)
	var keep := keep_for(pen)
	var path := trace(shooter, target, true)
	var front := 0
	for entry: Dictionary in path:
		if entry.get("unit") == target:
			break
		if entry.has("unit"):
			front += 1
	var cap := 99
	if front > 0:
		cap = clampi(Combat.compute_accuracy(shooter, target, action, body_part)
			- THROUGH_BODY_PENALTY * front, 1, 99)

	var primary: Combat.ShotResult = null
	var collateral: Array = []
	var steps := 0  # keep steps taken so far: damage here is base x keep^steps
	var first := true
	var last_body := ""
	for entry: Dictionary in path:
		var scale := pow(keep, steps)
		if entry.has("cover"):
			# An empty tile's edge behind the target: chipped by what is left of
			# the round, and paid for if it is light. Heavy is where it ends.
			var cover: Array = entry["cover"]
			# Spared when it is the shooter's own cover too (Combat.resolve_shot).
			if not GridManager.shares_cover_edge(entry["tile"], cover[1], shooter.grid_pos):
				GridManager.damage_cover_edge(entry["tile"], cover[1],
					roundi(shooter.stats.weapon_damage * scale))
			if cover[0] == MapData.Cover.HEAVY or pen < PEN_PER_BODY:
				break
			pen -= PEN_PER_BODY
			steps += 1
			continue
		var body: Unit = entry["unit"]
		var is_target := body == target
		last_body = body.stats.display_name
		var r := Combat.resolve_shot(shooter, body, action,
			body_part if is_target else Combat.BodyPart.TORSO, cap, scale, not is_target)
		if is_target:
			primary = r
		else:
			r.unit = body
			collateral.append(r)
		# The first roll on the path missing ends the shot; a later miss lets the
		# round carry on past that body for free.
		if first and not r.hit:
			break
		first = false
		# Heavy cover — a crate or a wall corner — takes whatever is left.
		if r.had_cover and r.cover_type == MapData.Cover.HEAVY:
			break
		var cost: Array = _body_cost(body, r.cover_type if r.had_cover else MapData.Cover.NONE, r.hit)
		if pen < cost[0]:
			break
		pen -= cost[0]
		steps += cost[1]

	if primary == null:
		# The round never got to the target: a body in front ate it.
		primary = Combat.ShotResult.new()
		primary.accuracy = cap
		primary.blocked_by = last_body
	primary.collateral = collateral
	return primary


## [pen, keep steps] a round spends getting past `body`: one bracket for the body
## if it was hit (two if armored), and one more for a light cover edge in front
## of it, crossed hit or miss.
static func _body_cost(body: Unit, cover_tier: int, hit: bool) -> Array:
	var pen := 0
	var steps := 0
	if hit:
		pen += PEN_PER_BODY
		steps += 1
		if body.stats.armored:
			pen += PEN_PER_BODY
			steps += 1
	if cover_tier == MapData.Cover.LIGHT:
		pen += PEN_PER_BODY
		steps += 1
	return [pen, steps]


static func _pen_of(shooter: Unit) -> int:
	var weapon := shooter.stats.active_weapon()
	return weapon.effective_penetration() if weapon != null else 0


## Whether a round from `shooter` can hit `body` without having been aimed at it.
## Its own faction ducks; a downed or carried body is only ever hit on purpose.
static func _eligible(shooter: Unit, body: Unit, target: Unit) -> bool:
	if body == shooter or body == target:
		return false
	if body.life_state != Unit.LifeState.ACTIVE or body.carried_by != null:
		return false
	if body.is_queued_for_deletion():
		return false
	return body.faction != shooter.faction


## The round's path, in order. Each entry is either {"unit": Unit} — a body on
## the line, the target's own entry among them — or, behind the target only,
## {"cover": [tier, side, structural], "tile": Vector3i} for a cover edge crossed
## into an empty tile. With `past_target` false it ends at the target.
##
## The line starts from the tile the shooter actually sees the target from (a
## lean tile, GDD §6.1.2) and is a 2D Bresenham over (x, z). Height runs along
## it from the shooter's chest to the target's, so a shot fired down off high
## ground runs into the floor a few tiles behind the target, and a level one runs
## on until a wall, heavy cover or the end of the deck stops it. In front of the
## target only bodies matter — line of sight already settled the geometry there.
static func trace(shooter: Unit, target: Unit, past_target: bool) -> Array:
	var line := GridManager.sight_line(shooter, target)
	var start: Vector3i = line[0] if not line.is_empty() else shooter.grid_pos
	var end := target.grid_pos
	var dx := end.x - start.x
	var dz := end.z - start.z
	var n := maxi(absi(dx), absi(dz))
	if n == 0:
		return [{"unit": target}]
	var h0 := GridManager.grid_to_world(start).y + GridManager.CHEST_HEIGHT
	var floor_y := GridManager.grid_to_world(end).y
	var h1 := floor_y + GridManager.CHEST_HEIGHT

	# Every body that could be hit, by column.
	var by_column := {}
	for node in shooter.get_tree().get_nodes_in_group("units"):
		var u := node as Unit
		if u != null and _eligible(shooter, u, target):
			var col := Vector2i(u.grid_pos.x, u.grid_pos.z)
			if not by_column.has(col):
				by_column[col] = []
			by_column[col].append(u)

	var out: Array = []
	var prev := end
	var prev_h := h1
	var last := n + MAX_TRACE if past_target else n
	for i in range(1, last + 1):
		var t := float(i) / n
		var col := Vector2i(start.x + roundi(dx * t), start.z + roundi(dz * t))
		var h := lerpf(h0, h1, t)
		var bodies: Array = []
		for u: Unit in by_column.get(col, []):
			var base := GridManager.grid_to_world(u.grid_pos).y
			if h >= base and h <= base + BODY_TOP:
				bodies.append(u)
		if i < n:
			for u: Unit in bodies:
				out.append({"unit": u})
			continue
		if i == n:
			out.append({"unit": target})
			# Whoever shares the target's tile is the first body behind it: a
			# zombie squeezing past another alien (Unit.passes_through) is shot
			# with that one pressed against it.
			for u: Unit in bodies:
				out.append({"unit": u})
			continue
		# Behind the target: the round stays on the target's deck.
		var tile := Vector3i(col.x, end.y, col.y)
		if h < floor_y or h > floor_y + GridManager.FLOOR_HEIGHT:
			break  # into the floor, or the deck above
		if not GridManager.has_tile(tile):
			break  # a wall cell or off the deck
		var from_pt := GridManager.grid_to_world(prev)
		var to_pt := GridManager.grid_to_world(tile)
		if not GridManager.has_clear_line(shooter, Vector3(from_pt.x, prev_h, from_pt.z),
				Vector3(to_pt.x, h, to_pt.z)):
			break  # a wall between the two tiles
		if bodies.is_empty():
			var cover := Combat.defending_cover(prev, tile)
			if cover[2]:
				break  # a sight-blocker flush with the edge: a wall
			if cover[0] != MapData.Cover.NONE:
				out.append({"cover": cover, "tile": tile})
				if cover[0] == MapData.Cover.HEAVY:
					break
		else:
			for u: Unit in bodies:
				out.append({"unit": u})
		prev = tile
		prev_h = h
	return out


# --- Buckshot ------------------------------------------------------------------

## The eight neighbours, counter-clockwise from +x, so an index and its ±1, ±2
## are the five tiles of a half-ring facing that direction.
const _RING: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(-1, 1),
	Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
]


## The five tiles around `at` that buckshot from `from` splashes into: front,
## front-left, front-right, left and right, "front" being toward the shooter
## snapped to the nearest of eight directions. The back three are spared.
static func splash_tiles(from: Vector3i, at: Vector3i) -> Array[Vector3i]:
	var facing := posmod(roundi(atan2(from.z - at.z, from.x - at.x) / (PI / 4.0)), 8)
	var out: Array[Vector3i] = []
	for k in [0, 1, -1, 2, -2]:
		var step := _RING[posmod(facing + k, 8)]
		out.append(at + Vector3i(step.x, 0, step.y))
	return out


## Buckshot: the target rolls as any shot does, and a hit splashes FULL damage
## into every eligible body in `splash_tiles`, each rolling for itself. Nothing
## splashes through a wall.
static func _resolve_splash(shooter: Unit, target: Unit, action: Combat.ShotAction, body_part: int) -> Combat.ShotResult:
	var primary := Combat.resolve_shot(shooter, target, action, body_part)
	if not primary.hit:
		return primary
	var chest := Vector3(0, GridManager.CHEST_HEIGHT, 0)
	for tile in splash_tiles(shooter.grid_pos, target.grid_pos):
		var t: GridTileData = GridManager.get_tile(tile)
		if t == null:
			continue
		var body := t.occupant as Unit
		if body == null or not _eligible(shooter, body, target):
			continue
		if not GridManager.has_clear_line(shooter, GridManager.grid_to_world(target.grid_pos) + chest,
				GridManager.grid_to_world(tile) + chest):
			continue
		var r := Combat.resolve_shot(shooter, body, action, Combat.BodyPart.TORSO, 99, 1.0, true)
		r.unit = body
		primary.collateral.append(r)
	return primary
