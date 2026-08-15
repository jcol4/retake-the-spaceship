class_name Faction
extends RefCounted
## Who is on whose side. Replaces the `is_player_controlled` boolean as the thing
## hostility is decided by.
##
## The boolean was not wrong, it was two-sided: everything not the player was
## "the enemy", so the aliens and the security robots were the same side by
## accident rather than by decision. They already share a deck without ever
## acknowledging each other — a Securus and a Brawler standing a tile apart both
## hunt the squad and neither notices the other — and that is a gap this file
## makes it possible to state, and later to close.
##
## SPLIT DELIBERATELY IN TWO. This commit changes only how hostility is
## REPRESENTED: the matrix below reproduces the old boolean's answers exactly, so
## nothing about how a mission plays has moved. Turning cross-faction hostility
## ON is a separate, revertible decision — one edit to `HOSTILE_TO` — with real
## balance consequences (a player who hides while two factions fight is farming
## attrition) that deserve their own playtest rather than riding in on a refactor.
##
## Holds no state and touches no autoload, so a `--script` headless tool can name
## it directly.

enum Id { CONTRACTORS, ALIENS, SECURITY, RIVAL_MERCS }

const DISPLAY_NAME := {
	Id.CONTRACTORS: "Contractors",
	Id.ALIENS: "Aliens",
	Id.SECURITY: "Cerberus Security",
	Id.RIVAL_MERCS: "Rival Mercs",
}

## Who each faction is willing to shoot at, keyed BY OBSERVER. Read as "a unit of
## the key faction treats these as hostile".
##
## Deliberately a per-observer list rather than a set of unordered pairs, because
## the interesting cases are not symmetric. The one already on the roadmap: ship
## security plausibly reads rival mercenaries as authorised personnel and the
## player's squad as intruders, which is an asymmetric relationship and a real
## disadvantage to hand the player. A pair-based model could not express it.
##
## Every entry here IS symmetric today, and that is the point — it is the old
## boolean, restated. Aliens and Security omit each other exactly as the boolean
## did by treating them both as "not the player".
## The rival mercs join on the same terms as everyone else — hostile to the
## squad, indifferent to the other two — because that is what every faction does
## today, and this file's whole discipline is that turning cross-faction
## hostility on is its own decision. Merc↔Security in particular is a design
## lever worth spending deliberately (ship security plausibly reads a rival
## contract crew as authorised and the player as intruders), not a default that
## fell out of a refactor.
const HOSTILE_TO := {
	Id.CONTRACTORS: [Id.ALIENS, Id.SECURITY, Id.RIVAL_MERCS],
	Id.ALIENS: [Id.CONTRACTORS],
	Id.SECURITY: [Id.CONTRACTORS],
	Id.RIVAL_MERCS: [Id.CONTRACTORS],
}


## Whether `observer` will engage `other`. Never hostile to its own faction, and
## that is hardcoded rather than left to the table: a faction that could be
## listed against itself is a typo waiting to turn a squad on each other.
static func is_hostile(observer: Id, other: Id) -> bool:
	if observer == other:
		return false
	return other in HOSTILE_TO[observer]


static func display_name(id: Id) -> String:
	return DISPLAY_NAME[id]
