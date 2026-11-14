class_name AlienPresets
extends RefCounted
## Roster table for the alien tier — the faction's answer to `ClassPresets` and
## `CerberusPresets`. Design: docs/design/factions/aliens/
##
## These blocks lived as private functions in `main.gd` until the granular AP
## rework. They moved for a reason the rework created rather than for tidiness:
## the melee tier's pace is now an INVARIANT BETWEEN TWO NUMBERS — a swarm's AP
## pool and the cost of its claw have to stay in a relationship that lets it
## close or swing but never both (see SwarmUnit, and tools/test_swarm_pace.gd) —
## and an invariant nothing outside `main.gd` can read is an invariant nothing
## can test. The old `_move_budget` override this replaced needed no such care:
## it stated the rate outright.
##
## Sec 11.8 already wanted these out of `main.gd` and into the Nest node's spawn
## table (Sec 11.7). This is not that — the Nest still does not exist — but it is
## the direction, and the spawn table can lift these wholesale when it arrives.
##
## Every value is hand-set per type (rework doc Sec 4.5/5.5) rather than run
## through the player's percentile class-roll system, and the three that used to
## be one number are now genuinely independent:
##
##   fitness          PACE. The AP pool is 4 + 0.05 x Fitness, floored.
##   base_hp          TOUGHNESS.
##   base_initiative  STANDING IN THE DRAW ORDER.
##
## Each block below is written to land on the HP and draw weight that type
## already had under the old formulas, so this is a port of the alien tier and
## not a rebalance of it.


## FODDER-ONLY ROSTER (2026-11-02). While true, every alien a deck places — the
## ranged ENEMY glyph the generator drops, brawlers, hunters, worms, swarms — is
## spawned as a Fodder horde instead (main.gd `_spawn_hordes`), and a nest's
## spawn activation coughs up a burst of Fodder rather than rolling its table.
## The other types' code, scenes and map glyphs are untouched: flip this back to
## false and every deck spawns exactly what it always did.
const FODDER_ONLY := true

## A horde's head count. One per compartment, however many alien glyphs the
## room holds, so a hand-authored deck that clustered six swarm markers gets one
## horde there rather than six.
const HORDE_MIN := 5
const HORDE_MAX := 8

## The brute's body is this much bigger than a regular's, so the one that takes
## work reads across the room before anyone has to shoot it to find out.
const BRUTE_SCALE := 1.2


## The iteration-1 ranged alien (`EnemyUnit`'s own stat block).
static func ranged(display_name: String) -> UnitStats:
	var stats := UnitStats.new()
	stats.display_name = display_name
	stats.perception = randi_range(50, 60)  # Aim, a notch under the squad's 55-65
	stats.reflexes = randi_range(25, 45)
	stats.fitness = randi_range(30, 45)  # 8-9 AP: a shot and several tiles
	stats.luck = 20
	stats.base_hp = randi_range(8, 11)  # -> 10-14 HP, two or three rifle hits
	var weapon := WeaponData.new()
	weapon.archetype = WeaponArchetype.Id.ASSAULT_RIFLE
	weapon.damage = 5
	weapon.mag_size = 10
	stats.weapon = weapon
	stats.melee_base_accuracy = 30  # refit to its old ~85% swing at the new Aim
	stats.base_initiative = 26  # -> ~36
	stats.equipment_initiative = 3
	return stats


## Fodder (Sec 11.3/11.4): tanky, but each swing is small — three or four of them
## are what hurts, never one. `mag_size` 0 is what "has no gun" means
## mechanically: can_shoot() is false forever. Lowest initiative on the board, so
## a swarm generally acts after the squad has already had its say.
##
## FITNESS 30 IS THE SHAMBLE: an 8 AP pool. The claw is priced flat by
## SwarmUnit.CLAW_AP_COST (3 AP), so its threat range is 5 tiles — it can walk
## up to 5 and still swing. test_swarm_pace.gd checks that relationship.
static func swarm(display_name: String) -> UnitStats:
	var stats := UnitStats.new()
	stats.display_name = display_name
	stats.perception = randi_range(45, 55)  # Aim: its bite is Aim + the claw's 25
	# Fixed rather than rolled. It no longer prices the claw (SwarmUnit overrides
	# the melee cost with a flat CLAW_AP_COST); it only feeds the other
	# Reflexes-discounted actions, none of which a swarm takes.
	stats.reflexes = 40
	stats.fitness = 30
	stats.luck = 15
	# 6-8 HP: one or two rifle hits. In a horde the attrition is the COUNT, not
	# the body — each kill has to feel like ground gained against five more. The
	# one that takes work is the brute (below), one per horde. Was 15-20 while
	# Fodder came singly. Authored 2 under that range because Fitness 30 adds 2.4
	# on top (UnitStats.HP_PER_FITNESS), and the pace bump is not meant to buy HP.
	stats.base_hp = randi_range(4, 6)
	# stats.weapon stays null — no ranged weapon at all (Sec 11.4); the
	# weapon_aim_modifier/weapon_damage/mag_size getters all read 0 from that.
	# Refit for the Aim rescale (docs/design/systems/accuracy): a bite still lands
	# ~75% of the time against a soldier who is not hunkered, as it did at the old
	# Perception 25-40 + 45.
	stats.melee_base_accuracy = 25
	stats.melee_damage = 3
	stats.base_initiative = 17  # -> 27 (draws last regardless, SwarmUnit.draws_last)
	stats.equipment_initiative = 2
	return stats


## Agile Hunter (Sec 11.5): fast, fragile, solo or in pairs, never a swarm.
##
## The inverse of the melee tier's stat shape, and deliberately so. Fodder is
## slow and hard to put down; a Hunter is quick and dies to one solid hit — so
## the question it asks is "can you answer it this turn", where Fodder asks "can
## you afford to keep answering". Both are melee, and that is the point: the tier
## is defined by how the creature ARRIVES, not by what it does on arrival.
##
## Fitness 70 buys an 11 AP pool — the fastest thing on the alien side, level with
## the quickest soldiers — which is what lets it cross ground and still swing. It
## is also the only alien that gets a planner (Sec 5.3/8).
static func hunter(display_name: String) -> UnitStats:
	var stats := UnitStats.new()
	stats.display_name = display_name
	stats.perception = randi_range(60, 70)  # it hunts; it needs to find you
	# High enough to make its claw cheap (4-5 AP against an 11 AP pool), which is
	# what pays for the close-and-strike its whole design is built on: six or seven
	# tiles of ground AND a blow, where everything else on the board buys one or
	# the other.
	stats.reflexes = randi_range(55, 70)
	stats.fitness = 70
	stats.luck = 25
	stats.base_hp = 8  # -> 13 HP: two rifle hits, killable once caught out of hiding
	# Unarmed at range like the rest of the melee tier — stats.weapon stays null.
	# ~85% a swing at the new Aim, before its ambush bonus (the old 45-65 + 50 was
	# pinned at the cap).
	stats.melee_base_accuracy = 20
	stats.melee_damage = 8  # a real threat if it connects: three swings ends a soldier
	# Fast and low: +20 Defense, so answering it this turn is a real gamble unless
	# you flank it or take aim (docs/design/systems/accuracy).
	stats.defense = 20
	stats.base_initiative = 38  # -> ~55, it acts early
	stats.equipment_initiative = 2
	return stats


## The horde's anchor: one per group, the body that holds the line while the
## regulars wrap around. The swarm's block with HP and claw damage moved and
## nothing else — the same 3 AP claw against the same 8 AP pool
## (test_swarm_pace.gd checks it).
##
## 18-22 HP is three or four rifle hits, against a regular's one or two. Claw 5
## is a rifle round's worth: of the bodies in contact, this is the one to kill
## first.
static func brute(display_name: String) -> UnitStats:
	var stats := swarm(display_name)
	stats.base_hp = randi_range(16, 20)  # -> 18-22 with the Fitness term
	stats.melee_damage = 5
	return stats


## The swarm's block with two numbers moved, which is the whole design: same
## senses, same reflexes, same pace, same lowest-on-the-board initiative, same
## absent weapon. What changes is how long it takes to put down and what it costs
## to let one reach you.
##
## 29-33 HP was roughly DOUBLE the swarm's old 15-20 (the horde regular is 6-8
## now; the brute, 18-22, is the closer comparison): a swarm dies inside one soldier's
## activation, a brawler does not. That number lives in `base_hp` now rather than
## in Fitness, which is exactly what lets the two share an identical pool — a
## brawler is TOUGHER than a swarm, not faster, and while HP and pace were the
## same stat that distinction could not be stated.
##
## Damage 6 against 3, and the shortened HP scale sharpened what that means: two
## connected swings is more than half a soldier and a third finishes one, so a
## brawler in contact is a problem to solve this turn rather than a tax to absorb.
static func brawler(display_name: String) -> UnitStats:
	var stats := swarm(display_name)
	stats.base_hp = randi_range(26, 30)  # -> 28-32 HP with the Fitness term
	stats.melee_damage = 6
	return stats


## The worm (WormUnit): 5 HP, a 2-damage bite, the slowest thing on the board —
## and the SEED of the only thing on the board the squad cannot outfight.
## Design: docs/design/factions/aliens/design-choices/worm-mass.md
##
## THIS BLOCK IS ONE WORM AND ONLY ONE. A pile is the same node with more HP, and
## every number that scales with the pile is derived in `WormUnit` from
## `current_hp` rather than authored here — there is no second preset to keep in
## step with this one, deliberately.
##
## `base_hp` 5 is the unit the pile is counted in. `WormUnit.worm_count()` is
## `ceil(hp / 5)`, so this number is also the size of the step a mass shrinks by
## when it is shot, and moving it re-scales the whole ladder.
##
## `melee_damage` 2 is what ONE worm contributes (`WormUnit.DAMAGE_PER_WORM`
## restates it, and `_apply_count` overwrites this field with `2 x count` the
## moment the unit is ready). Alone that is ten bites to put down a soldier,
## which is the point: a lone worm is an alarm, not a threat. Ten TOGETHER is
## 20 against a 19-21 HP soldier, which is also the point.
##
## Both zeros are dials set to buy a price, like the swarm's Reflexes 40, and
## neither is a characterisation. Both are now overridden in `WormUnit` rather
## than read through the formulas — `ap_pool()` returns a flat 12 and the bite is
## priced at the whole of it — so what these buy is only the HP and initiative
## side of the block. They are kept at zero so that nothing reading the stats
## directly is handed a pace or a price that disagrees with the unit's own.
static func worm(display_name: String) -> UnitStats:
	var stats := UnitStats.new()
	stats.display_name = display_name
	stats.perception = randi_range(45, 55)  # the swarm's range: bite accuracy is Aim + 25
	stats.reflexes = 0
	stats.fitness = 0
	stats.luck = 15
	# Literals, NOT `WormUnit.HP_PER_WORM` / `DAMAGE_PER_WORM`, though those name
	# exactly these two numbers. `WormUnit` sheds worms and builds their stats
	# through this file, so a reference back to it here is a cyclic class
	# dependency and Godot rejects the pair with an unrelated-looking
	# "Identifier not found" on whichever it compiles second.
	#
	# This table is the AUTHORING side and those constants are the restatement,
	# so if these move, move them there too — `WormUnit`'s own doc comment says
	# the same thing from the other end.
	stats.base_hp = 5
	# Unarmed at range like the rest of the melee tier — stats.weapon stays null.
	stats.melee_base_accuracy = 25  # the swarm's refit claw
	stats.melee_damage = 2
	stats.base_initiative = 17  # -> 19, below the swarm: the last thing to act
	stats.equipment_initiative = 2
	return stats


## The Nest (Sec 11.7). An OBJECTIVE wearing a stat block, not a combatant, so
## most of this file's usual reasoning does not apply to it:
##
##   base_hp 50  The design's number, kept as-is on 2026-09-22 knowing it
##               predates the lethality rescale and now reads as roughly twice
##               the toughest unit on the board. That is the intent — an
##               objective that folds to one burst is not an objective. See
##               design-choices/spawn-nests.md.
##   fitness 0   So `base_hp` IS max HP (UnitStats.max_hp, LEVEL_BONUS_HP is 0).
##               Nothing about a nest should be rolled: two nests on a deck must
##               take the same number of bursts, or the player cannot learn what
##               destroying one costs.
##   perception  Zero, and it is the honest value rather than a small one. A
##   reflexes    nest has no senses and never acts — `NestUnit.take_turn`
##   luck        passes without looking — so these terms are never read. Left at
##               0 so anyone grepping for what a nest can do finds nothing.
##
## No initiative worth tuning either: it draws from the pool and passes.
static func nest(display_name: String) -> UnitStats:
	var stats := UnitStats.new()
	stats.display_name = display_name
	stats.perception = 0
	stats.reflexes = 0
	stats.fitness = 0
	stats.luck = 0
	stats.base_hp = 50
	# Unarmed at every range: it has no attack of any kind, now or planned.
	stats.melee_base_accuracy = 0
	stats.melee_damage = 0
	stats.base_initiative = 1  # dead last; it passes, so the slot costs nothing
	stats.equipment_initiative = 0
	return stats
