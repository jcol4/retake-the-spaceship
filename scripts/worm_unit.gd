class_name WormUnit
extends SwarmUnit
## The worm: a half-metre crawler with a 5-damage bite. Design:
## docs/design/factions/aliens/units/worm/
##
## Fodder's loop (crawl at the quarry, bite once adjacent), so it extends
## SwarmUnit rather than copying it. Two things set it apart, and both are
## deliberate breaks from a faction rule rather than tuning:
##
## PACE IS A PRICE PER TILE, NOT A POOL. Sec 4.1 makes movement flat — 1 AP a
## tile for everybody, pace bought through the pool — but the pool floors at
## UnitStats.AP_POOL_BASE (6) even at Fitness 0, so no stat block can hold a unit
## under six tiles a turn. Nine metres a turn is not a pace for something half a
## metre long. So this is the one unit whose steps cost more, and the
## price is the whole pool: one tile per activation, and it closes OR bites,
## never both (the bite also costs the whole pool — see AlienPresets.worm).
##
## IT FEELS FOOTSTEPS. The faction's rule is no special senses — same light and
## sound as the player (docs/design/factions/aliens/README.md). The worm is the
## named exception: it senses any hostile that MOVED within `tremor_range` on its
## own deck since its last activation, lit or not, seen or not. Standing still
## is the counterplay, and it is a real one — a locked-on worm that stops feeling
## its quarry loses it after `lose_contact_turns`, exactly as a sighted alien
## does when the lights go out. Contact is always felt: nothing touching the
## worm can hide from it.

## AP per tile. The whole of UnitStats.AP_POOL_BASE: one tile per activation.
const AP_PER_TILE := 6

## Tiles (Chebyshev, same deck) within which a hostile's movement is felt.
@export var tremor_range: int = 4

## Where each hostile stood at this worm's last activation.
var _felt_at: Dictionary = {}
## Hostiles that moved within range since then. Rebuilt once per activation, so
## every sense check inside one activation gets the same answer.
var _tremors: Array[Unit] = []


func move_ap_per_tile() -> int:
	return AP_PER_TILE


func take_turn() -> void:
	_feel_tremors()
	await super()


func _feel_tremors() -> void:
	_tremors.clear()
	for unit in hostiles():
		var was: Variant = _felt_at.get(unit)
		_felt_at[unit] = unit.grid_pos
		if was == null or was == unit.grid_pos or unit.grid_pos.y != grid_pos.y:
			continue
		if GridManager.chebyshev_dist(grid_pos, unit.grid_pos) <= tremor_range:
			_tremors.append(unit)


func _can_see(unit: Unit) -> bool:
	if super(unit):
		return true
	if unit == null or unit.is_downed:
		return false
	return GridManager.is_melee_adjacent(grid_pos, unit.grid_pos) or unit in _tremors


func _melee_verb() -> String:
	return "bit"
