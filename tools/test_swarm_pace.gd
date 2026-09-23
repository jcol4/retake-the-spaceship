extends SceneTree
## The melee tier's pace under the granular AP economy, checked against the real
## deck.
##
##   godot --headless --path . --script res://tools/test_swarm_pace.gd
##
## REPLACES test_swarm_lunge.gd. That file asserted Sec 11.4's two-speed
## shamble/lunge, which was built on `_move_budget` meaning "tiles per 1 AP" —
## a unit of measure the AP rework deleted (movement is 1 AP per tile for
## everyone, rework doc Sec 4.1). The lunge went with it.
##
## What is asserted here is the property the lunge's LATCH existed to protect,
## which outlived the lunge itself: a swarm can close OR swing in one activation,
## never both, so the player always gets one turn of warning between "that thing
## is near" and "that thing is on me". That now falls out of the pool arithmetic
## (a hand-set Fitness of 10 buys 4 AP; a claw costs about 4) rather than out of
## a latch — which is precisely why it needs a test. Nothing about the stat block
## announces that those two numbers have to stay in that relationship, and a
## well-meaning Fitness bump would silently delete the warning.
##
## Scripts are load()ed and locals stay untyped for the reason test_cerberus.gd
## gives: a --script tool is compiled before autoloads register, so naming
## SwarmUnit or Combat here would fail to load and the test would never run.
## `AlienPresets` touches no autoload and so is safe to name — which is the whole
## reason these stat blocks moved out of `main.gd`. A scene instantiated on its
## own carries NO stat block (Unit._ready builds a default UnitStats), so a test
## that skipped the presets would be asserting against Fitness 50 and proving
## nothing about the roster.

const SWARM := "res://scenes/swarm_unit.tscn"
const BRAWLER := "res://scenes/brawler_unit.tscn"
const WORM := "res://scenes/worm_unit.tscn"
const PLAYER := "res://scenes/player_unit.tscn"

# Middle compartment, clear of the deck's own spawn markers.
const ANCHOR := Vector3i(7, 0, 6)

## UnitStats.Action.MELEE by value. Spelled as a literal for the same reason the
## locals here stay untyped — a --script tool is compiled before the project's
## class registry is available, so naming the enum would fail the load outright.
const MELEE := 1

var _failures := 0
var _grid: Node


func _initialize() -> void:
	_grid = root.get_node_or_null("GridManager")
	var map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(map)
	await process_frame

	await _check_pool_covers_one_claw()
	await _check_cannot_close_and_swing()
	await _check_movement_is_flat()
	await _check_brawler_shares_the_pace()
	await _check_worm_crawls_one_tile()
	await _check_worm_feels_footsteps()
	await _check_mass_trades_the_warning_for_a_gather()
	await _check_damage_shrinks_the_mass()
	await _check_absorption_leaves_no_corpses()
	await _check_the_cap_spills()

	print("")
	if _failures == 0:
		print("swarm pace: ALL CHECKS PASSED")
		quit(0)
	else:
		print("swarm pace: %d CHECK(S) FAILED" % _failures)
		quit(1)


## The floor of the melee tier: a swarm that has reached you must be able to pay
## for the swing. A pool below the claw's price would make Fodder harmless.
func _check_pool_covers_one_claw() -> void:
	var swarm = await _spawn(SWARM, ANCHOR, AlienPresets.swarm("Swarm"))
	var pool: int = swarm.ap_pool()
	var claw: int = swarm.action_cost(MELEE)
	_check(pool >= claw,
		"a swarm's pool (%d AP) covers its claw (%d AP)" % [pool, claw])
	_free([swarm])


## THE CASE THE WHOLE STAT BLOCK EXISTS FOR, and the one the deleted lunge latch
## used to guarantee by hand: the player's turn of warning.
##
## The bar is TWO tiles, not one, and the difference is the whole point. A
## shambler could always step one tile and swing — that was 1 AP of movement plus
## a 1 AP claw out of two, the ordinary shamble — so a swarm already one step
## away reaching you is not the thing the latch protected against. What it
## protected against was CROSSING GROUND and connecting on the same draw, which
## is what the lunge did and what the pool now forbids: anything standing two or
## more tiles out cannot both arrive and land a blow.
func _check_cannot_close_and_swing() -> void:
	var swarm = await _spawn(SWARM, ANCHOR, AlienPresets.swarm("Swarm"))
	var pool: int = swarm.ap_pool()
	var claw: int = swarm.action_cost(MELEE)
	var two_tiles: int = 2 * swarm.move_ap_per_tile()
	_check(two_tiles + claw > pool,
		"closing two tiles (%d AP) then clawing (%d AP) exceeds the pool (%d AP)"
		% [two_tiles, claw, pool])
	# And the reach it DOES keep is exactly the shamble's: one step, then a swing.
	_check(swarm.move_ap_per_tile() + claw <= pool,
		"while one step (%d AP) plus a claw (%d AP) still fits, as it always did"
		% [swarm.move_ap_per_tile(), claw])
	_free([swarm])


## Sec 4.1: movement is flat for every unit regardless of stats. The melee tier
## is where a private rate would be most tempting to reintroduce, since it is the
## tier that used to have one.
func _check_movement_is_flat() -> void:
	var swarm = await _spawn(SWARM, ANCHOR, AlienPresets.swarm("Swarm"))
	var player = await _spawn(PLAYER, ANCHOR + Vector3i(4, 0, 0), ClassPresets.roll(UnitStats.UnitClass.ASSAULT, "Reyes"))
	_check(swarm.move_ap_per_tile() == player.move_ap_per_tile(),
		"a swarm pays the same AP per tile a soldier does (%d vs %d)"
		% [swarm.move_ap_per_tile(), player.move_ap_per_tile()])
	# Pace is the POOL, and a soldier's is bigger — which is what keeps a squad
	# able to outwalk the thing shambling after it.
	_check(player.ap_pool() > swarm.ap_pool(),
		"and a soldier's pool outruns it (%d vs %d AP)"
		% [player.ap_pool(), swarm.ap_pool()])
	_free([swarm, player])


## BrawlerUnit extends SwarmUnit, and the design is that it is TOUGHER, not
## faster. Asserted rather than assumed: HP and pace are separate fields now
## (base_hp vs fitness), and it would be easy to raise one meaning the other.
func _check_brawler_shares_the_pace() -> void:
	var swarm = await _spawn(SWARM, ANCHOR, AlienPresets.swarm("Swarm"))
	var brawler = await _spawn(BRAWLER, ANCHOR + Vector3i(3, 0, 0), AlienPresets.brawler("Brawler"))
	_check(brawler.ap_pool() == swarm.ap_pool(),
		"a brawler moves at the swarm's pace (%d vs %d AP)"
		% [brawler.ap_pool(), swarm.ap_pool()])
	_check(brawler.stats.max_hp() > swarm.stats.max_hp(),
		"and is tougher instead (%d vs %d HP)"
		% [brawler.stats.max_hp(), swarm.stats.max_hp()])
	_free([swarm, brawler])


## The worm is the named exception to flat movement (`WormUnit.move_ap_per_tile`): a
## step costs its whole pool. Asserted as numbers, because the pace is an
## agreement between three of them — the pool floor, the tile price and the
## bite price — and none of them says so on its own.
func _check_worm_crawls_one_tile() -> void:
	var worm = await _spawn(WORM, ANCHOR, AlienPresets.worm("Worm"))
	var pool: int = worm.ap_pool()
	var tile: int = worm.move_ap_per_tile()
	var bite: int = worm.action_cost(MELEE)
	_check(tile <= pool and 2 * tile > pool,
		"a worm crawls exactly one tile per activation (%d AP a tile, %d AP pool)" % [tile, pool])
	_check(pool >= bite and tile + bite > pool,
		"and closes OR bites, never both (tile %d + bite %d vs pool %d)" % [tile, bite, pool])
	_check(worm.stats.max_hp() == 5 and worm.stats.melee_damage == 2,
		"5 HP, 2 damage (got %d HP, %d damage)" % [worm.stats.max_hp(), worm.stats.melee_damage])
	_free([worm])


## THE MASS IS EXEMPT FROM THE WARNING TURN, AND THAT IS A DECISION.
##
## Everything above this line defends one property: a melee unit closes OR
## swings in an activation, never both, so the player gets one turn between
## "that thing is near" and "that thing is on me". The worm mass BREAKS it —
## from count 2 there is no swing to price at all, because movement is the
## attack (docs/design/factions/aliens/design-choices/worm-mass.md).
##
## This case exists so that break is asserted rather than merely absent. A test
## file that simply stopped checking the worm would look identical to one where
## somebody deleted an inconvenient failure, and the next person to read it
## could not tell which had happened.
##
## What the mass pays instead is stated in the tiers below: it is slower than
## anything it hunts at every size, so the warning moved from the moment of
## contact to the whole approach.
func _check_mass_trades_the_warning_for_a_gather() -> void:
	var worm = await _spawn(WORM, ANCHOR, AlienPresets.worm("Worm"))
	var soldier = await _spawn(PLAYER, ANCHOR + Vector3i(4, 0, 0),
		ClassPresets.roll(UnitStats.UnitClass.ASSAULT, "Reyes"))

	# A lone worm keeps the invariant the rest of this file defends.
	_check(worm.move_ap_per_tile() + worm.action_cost(MELEE) > worm.ap_pool(),
		"one worm still closes OR bites (tile %d + bite %d vs pool %d)"
		% [worm.move_ap_per_tile(), worm.action_cost(MELEE), worm.ap_pool()])

	# The ladder. HP is the only state, so every tier is reached by setting it.
	var ladder := [[1, 1, 2], [5, 1, 10], [9, 2, 18], [13, 3, 26], [16, 4, 32]]
	var ok := true
	var seen := []
	for rung in ladder:
		var count: int = rung[0]
		worm.current_hp = count * 5
		worm._apply_count()
		var tiles: int = worm.ap_pool() / worm.move_ap_per_tile()
		seen.append("%dx=%dt/%ddmg" % [worm.worm_count(), tiles, worm.stats.melee_damage])
		if worm.worm_count() != count or tiles != rung[1] or worm.stats.melee_damage != rung[2]:
			ok = false
	_check(ok, "the ladder is 1/1/2, 5/1/10, 9/2/18, 13/3/26, 16/4/32 (got %s)"
		% ", ".join(PackedStringArray(seen)))

	# The trade: even at its fastest the mass is slower than what it hunts, so it
	# can cut a squad off but never run one down. This is the counterweight to
	# the deleted warning turn, and it is the number that would quietly vanish if
	# somebody "fixed" the mass's pace.
	worm.current_hp = 16 * 5
	worm._apply_count()
	var mass_tiles: int = worm.ap_pool() / worm.move_ap_per_tile()
	var soldier_tiles: int = soldier.ap_pool() / soldier.move_ap_per_tile()
	_check(mass_tiles < soldier_tiles,
		"a full Tide is still outrun by a soldier (%d vs %d tiles)" % [mass_tiles, soldier_tiles])

	_free([worm, soldier])


## Damage removes WORMS, which is the whole counterplay loop: shooting a mass
## makes it weaker, slower and smaller on the same hit. Asserted on all three at
## once, because a change that kept the count honest while letting damage or
## pace drift would pass any one of them alone.
func _check_damage_shrinks_the_mass() -> void:
	var worm = await _spawn(WORM, ANCHOR, AlienPresets.worm("Worm"))
	worm.current_hp = 16 * 5
	worm._apply_count()
	var was_tiles: int = worm.ap_pool() / worm.move_ap_per_tile()
	var was_damage: int = worm.stats.melee_damage

	# Six worms killed: 30 damage, which is four assault-rifle hits. This is the
	# number the design promises the player — de-fanging a Tide is four hits,
	# where killing it outright is ten.
	worm.take_damage(30)
	_check(worm.worm_count() == 10,
		"30 damage kills exactly six worms (16 -> %d)" % worm.worm_count())
	_check(worm.stats.melee_damage < was_damage,
		"and the bite shrinks with it (%d -> %d)" % [was_damage, worm.stats.melee_damage])
	_check(worm.ap_pool() / worm.move_ap_per_tile() < was_tiles,
		"and so does the pace (%d -> %d tiles)"
		% [was_tiles, worm.ap_pool() / worm.move_ap_per_tile()])
	_check(worm.stats.melee_damage == 20,
		"10 worms still one-shots most of the roster (%d vs 19-21 HP)" % worm.stats.melee_damage)
	_free([worm])


## Absorbing is not killing. The distinction is invisible in a damage number and
## very visible to a Proctor: `take_damage`'s death path reports a CORPSE to the
## security network, and a pile that merely FORMED must not leave sixteen of
## them in a room where nothing died.
func _check_absorption_leaves_no_corpses() -> void:
	var big = await _spawn(WORM, ANCHOR, AlienPresets.worm("Big"))
	var small = await _spawn(WORM, ANCHOR + Vector3i(1, 0, 0), AlienPresets.worm("Small"))
	big.current_hp = 25  # five worms, so it outranks the newcomer
	big._apply_count()

	var network = root.get_node_or_null("SecurityNetwork")
	var before: int = network._evidence.size() if network else 0

	big.absorb(small)
	await process_frame

	_check(big.worm_count() == 6, "five worms plus one is six (got %d)" % big.worm_count())
	_check(big.current_hp == 30, "and the HP came with it (got %d)" % big.current_hp)
	_check(not is_instance_valid(small) or small.is_downed,
		"the absorbed worm has left the board")
	_check(_grid.get_tile(ANCHOR + Vector3i(1, 0, 0)).occupant == null,
		"and released its tile")
	var after: int = network._evidence.size() if network else 0
	_check(after == before,
		"and left no corpse behind (%d evidence before, %d after)" % [before, after])
	_free([big])


## The cap is a FRONT, not a ceiling: a worm arriving at a full pile does not
## vanish into it, it spills alongside and seeds the next mass.
func _check_the_cap_spills() -> void:
	var full = await _spawn(WORM, ANCHOR, AlienPresets.worm("Full"))
	var extra = await _spawn(WORM, ANCHOR + Vector3i(1, 0, 0), AlienPresets.worm("Extra"))
	full.current_hp = 16 * 5
	full._apply_count()

	full.absorb(extra)
	await process_frame

	_check(full.worm_count() == 16, "a full pile stays at the cap (got %d)" % full.worm_count())
	_check(is_instance_valid(extra) and not extra.is_downed and extra.current_hp == 5,
		"and the newcomer survives alongside it as its own worm")
	_free([full, extra])


## The worm's sense: MOVEMENT within tremor range, lit or not. Sight is switched
## off here (an unreachable light threshold) so that only the tremor channel can
## answer, and each _feel_tremors() call stands in for one activation.
func _check_worm_feels_footsteps() -> void:
	var worm = await _spawn(WORM, ANCHOR, AlienPresets.worm("Worm"))
	var player = await _spawn(PLAYER, ANCHOR + Vector3i(3, 0, 0), ClassPresets.roll(UnitStats.UnitClass.ASSAULT, "Reyes"))
	worm.sight_light_threshold = 1.0e9
	worm._feel_tremors()
	_check(not worm._can_see(player), "a soldier standing still in range is not felt")
	player.grid_pos = ANCHOR + Vector3i(2, 0, 0)
	worm._feel_tremors()
	_check(worm._can_see(player), "a soldier who moved within range is felt")
	worm._feel_tremors()
	_check(not worm._can_see(player), "and lost again once he stops")
	player.grid_pos = ANCHOR + Vector3i(worm.tremor_range + 2, 0, 0)
	worm._feel_tremors()
	_check(not worm._can_see(player), "movement beyond tremor range (%d) is not felt" % worm.tremor_range)
	player.grid_pos = ANCHOR + Vector3i(1, 0, 0)
	worm._feel_tremors()
	worm._feel_tremors()
	_check(worm._can_see(player), "contact is always felt, moving or not")
	# Back onto the tile he occupies, or _free clears the wrong one.
	player.grid_pos = ANCHOR + Vector3i(3, 0, 0)
	_free([worm, player])


## Spawns a unit carrying the stat block the mission would actually give it.
## MUST be assigned before `add_child`, since Unit._ready reads max_hp off it and
## substitutes a bare default when it finds none — which is what makes a scene
## instantiated without one useless to assert against.
func _spawn(scene_path: String, at: Vector3i, stats = null):
	var unit = load(scene_path).instantiate()
	if stats != null:
		unit.stats = stats
	unit.position = _grid.grid_to_world(at)
	root.add_child(unit)
	await process_frame
	return unit


func _free(units: Array) -> void:
	for unit in units:
		if is_instance_valid(unit):
			_grid.set_occupant(unit.grid_pos, null)
			unit.queue_free()


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
