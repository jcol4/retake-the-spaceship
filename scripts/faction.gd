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
## SPLIT DELIBERATELY IN TWO. The commit that introduced this file changed only
## how hostility is REPRESENTED (the matrix reproduced the old boolean exactly).
## Turning cross-faction hostility ON was its own decision, taken in extraction
## plan Phase 7 (GDD §11.0): every faction is now hostile to every other. HOW each
## one picks those fights — aliens by whatever they detect, Cerberus by threat,
## mercs only when it is worth it — lives in `CrossFactionRules`, not here. The
## balance risk named at the time still stands and is a playtest item: a squad
## that hides while two factions fight is farming attrition.
##
## Holds no state and touches no autoload, so a `--script` headless tool can name
## it directly. Also holds DOWNED_POLICY (extraction plan 2.4): who finishes a
## downed enemy, which is as much a faction's identity as who it shoots at.

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
## Every entry is symmetric and complete (GDD §11.0: "every faction is hostile to
## every other"), each for its own reason:
##   - Aliens: prey is prey. A robot or a merc is meat like a soldier is.
##   - Cerberus: the lockdown protocol reads all unauthorised movement as an
##     intrusion. "Intruder" is not a species check (security-robots
##     faction-identity.md), so it covers aliens and the rival crew alike.
##   - Rival mercs: a competing crew on the same job, and the deck's natives and
##     machines are in their way as much as ours.
## The asymmetric levers (security reading the rival crew as authorised, say)
## remain expressible here and remain unspent; the PER-FACTION differences live
## in how fights are chosen (`CrossFactionRules`), not in who may be shot.
const HOSTILE_TO := {
	Id.CONTRACTORS: [Id.ALIENS, Id.SECURITY, Id.RIVAL_MERCS],
	Id.ALIENS: [Id.CONTRACTORS, Id.SECURITY, Id.RIVAL_MERCS],
	Id.SECURITY: [Id.CONTRACTORS, Id.ALIENS, Id.RIVAL_MERCS],
	Id.RIVAL_MERCS: [Id.CONTRACTORS, Id.ALIENS, Id.SECURITY],
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


## Whether a faction goes out of its way to shoot a DOWNED enemy (GDD §4.4 "Who
## shoots the downed"). `hostiles()` never offers a downed unit — that is right
## for ordinary targeting, where a body on the deck is not a threat — so finishing
## one is a separate, per-faction decision, and this table is where it is made.
##
##   NEVER          ignores them. Cerberus: a downed body is not a moving threat,
##                  and the robots' sensors are built around motion.
##   OPPORTUNISTIC  only when it is cheap: nothing active in sight, and the shot
##                  costs no more than what is left standing where it is
##                  (MercUnit). Professionals don't spend a turn on a body.
##   ALWAYS         prey is prey (the aliens). Still ranked BELOW an active threat
##                  the alien can see — see EnemyUnit.acquire_target.
##
## Contractors are NEVER: the player decides that for themselves, and the auto
## harness has no business doing it either.
##
## Only DOWNED counts. A corpse is never a target (DEAD takes no damage at all),
## and a carried body is shot THROUGH its carrier (Unit.fire_at), not aimed at.
enum DownedPolicy { NEVER, OPPORTUNISTIC, ALWAYS }

const DOWNED_POLICY := {
	Id.CONTRACTORS: DownedPolicy.NEVER,
	Id.ALIENS: DownedPolicy.ALWAYS,
	Id.SECURITY: DownedPolicy.NEVER,
	Id.RIVAL_MERCS: DownedPolicy.OPPORTUNISTIC,
}


static func downed_policy(id: Id) -> DownedPolicy:
	return DOWNED_POLICY.get(id, DownedPolicy.NEVER)
