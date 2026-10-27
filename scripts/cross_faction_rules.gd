class_name CrossFactionRules
extends RefCounted
## How each faction picks fights with the OTHER hostile factions (GDD §11.0,
## extraction plan Phase 7). `Faction.HOSTILE_TO` says who may shoot whom; this
## file says how each side chooses, which is where the factions' identities show.
##
##   Aliens    Prey is prey. Whatever they detect, nearest first. Nothing here,
##             because nothing changed: EnemyUnit's nearest-first pick was already
##             the rule, it just stopped being filtered to the squad.
##   Cerberus  Every non-robot is an intruder, and "intruder" is not a species
##             check. Detected intruders are ranked by THREAT (`intruder_threat`),
##             and the same formula scores an alien, a merc and a soldier.
##   Mercs     Professionals on a job. The player crew always; anything else only
##             when it has found them, is in the way, or is too close to ignore
##             (`merc_engages`). Otherwise they route around it (`avoid_penalty`).
##
## Pure functions over plain values: no scene, no autoload, so a headless
## `--script` tool can name it directly, the same way `Faction` and `Combat` are.
## The callers (CerberusUnit, MercUnit) gather the inputs off the board.

# --- Cerberus: ranking intruders --------------------------------------------

## An intruder that has fired on a Cerberus unit in this zone. The heaviest term
## by design: a security net's first job is protecting itself, and a thing that
## has demonstrated it can and will damage the network outranks anything merely
## standing in the wrong place — whatever it is.
const THREAT_ATTACKED_NETWORK := 10.0
## Carries a ranged weapon. Something that can hurt the net from across a room
## is a bigger problem than something that has to walk up to it first.
const THREAT_ARMED := 4.0
## Moved within the motion memory. The sensors are built around movement, so a
## moving contact is the one they are "looking at" — the same bias that makes
## standing still the stealth lever against this faction.
const THREAT_MOVING := 2.0
## Per tile closer than `THREAT_RANGE`. Small next to the terms above, so it
## mostly breaks ties: proximity matters, but a far gunman who just shot a robot
## still beats a near Fodder that has done nothing.
const THREAT_PER_TILE := 0.5
## The distance the proximity term counts down from (the robots' 8-tile motion
## range). Beyond it the term is zero, never negative.
const THREAT_RANGE := 8
## How much better a new intruder must score before a robot already locked on
## one switches to it. Hysteresis, like MercUnit.PRIORITY_SWITCH_MARGIN: without
## it two near-equal intruders have a robot swinging between them every
## activation. Less than THREAT_ATTACKED_NETWORK, so opening fire on a robot
## always pulls its attention.
const THREAT_SWITCH_MARGIN := 3.0


## Threat score of one detected intruder, higher = deal with it first.
## Faction-blind on purpose (see the header).
static func intruder_threat(distance: int, armed: bool, moving: bool,
		attacked_network: bool) -> float:
	var score := 0.0
	if attacked_network:
		score += THREAT_ATTACKED_NETWORK
	if armed:
		score += THREAT_ARMED
	if moving:
		score += THREAT_MOVING
	score += float(maxi(0, THREAT_RANGE - distance)) * THREAT_PER_TILE
	return score


## Whether a robot locked on a target scoring `current` should switch to one
## scoring `candidate`.
static func should_switch(current: float, candidate: float) -> bool:
	return candidate >= current + THREAT_SWITCH_MARGIN


# --- Mercs: which fights are worth it ---------------------------------------

## "Within N tiles of a squad member" (plan Phase 7.3). Three is close enough that
## a melee alien could be on top of somebody next activation (Fodder walks one
## tile and swings, a Hunter is faster), so it is a fight the squad cannot route
## around any more; far enough that a robot standing post across a room is not.
const MERC_ENGAGE_RADIUS := 3
## How far along its intended route a merc checks for something in the way —
## about one activation's walk. A hostile further down the route than that can
## still be routed around before the squad gets there.
const MERC_ROUTE_LOOKAHEAD := 6
## A hostile within this many tiles of a route tile counts as "blocking" it: on
## it, or close enough that walking past means walking into contact.
const MERC_BLOCK_RADIUS := 1
## Tiles within this distance of a known third-party hostile are expensive ground
## for a merc's non-combat route (patrol, investigating a noise).
const MERC_AVOID_RADIUS := 2
## Extra path cost per such tile, on top of the 1 every tile costs. Three means a
## detour of up to three extra tiles beats brushing past one hazard tile — enough
## to swing wide around a room's doorway, not so much that a merc crosses half
## the deck to dodge a robot it could have walked past.
const MERC_AVOID_PENALTY := 3


## Whether a rival merc engages a hostile it has detected.
##   `hostile_faction`  the other unit's Faction.Id;
##   `hunting_squad`    it has detected the squad — it is fighting a member, or
##                      has landed a hit on one, or fired on one;
##   `blocks_route`     it sits on (or beside) the merc's next stretch of route;
##   `squad_distance`   tiles from it to the nearest live squad member.
static func merc_engages(hostile_faction: int, hunting_squad: bool, blocks_route: bool,
		squad_distance: int) -> bool:
	# The player crew is the competition: always.
	if hostile_faction == Faction.Id.CONTRACTORS:
		return true
	return hunting_squad or blocks_route or squad_distance <= MERC_ENGAGE_RADIUS


## Extra cost of stepping onto `tile` for a merc avoiding `hazards` (grid
## positions of third-party hostiles it knows about). Chebyshev on the same floor
## only: a robot one deck down is not in the way.
static func avoid_penalty(tile: Vector3i, hazards: Array) -> int:
	for h: Vector3i in hazards:
		if h.y == tile.y and maxi(absi(h.x - tile.x), absi(h.z - tile.z)) <= MERC_AVOID_RADIUS:
			return MERC_AVOID_PENALTY
	return 0


## Whether `hazard` blocks `route` (a path, excluding the start tile): within
## MERC_BLOCK_RADIUS of one of its first MERC_ROUTE_LOOKAHEAD tiles.
static func blocks_route(hazard: Vector3i, route: Array) -> bool:
	for i in mini(route.size(), MERC_ROUTE_LOOKAHEAD):
		var t: Vector3i = route[i]
		if t.y == hazard.y and maxi(absi(t.x - hazard.x), absi(t.z - hazard.z)) <= MERC_BLOCK_RADIUS:
			return true
	return false
