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
