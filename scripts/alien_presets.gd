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


## The iteration-1 ranged alien (`EnemyUnit`'s own stat block).
static func ranged(display_name: String) -> UnitStats:
	var stats := UnitStats.new()
	stats.display_name = display_name
	stats.perception = randi_range(30, 50)
	stats.reflexes = randi_range(25, 45)
	stats.fitness = randi_range(30, 45)  # 8-9 AP: a shot and several tiles
	stats.luck = 20
	stats.base_hp = randi_range(8, 11)  # -> 10-14 HP, two or three rifle hits
	var weapon := WeaponData.new()
	weapon.base_accuracy = 20
	weapon.damage = 5
	weapon.mag_size = 10
	stats.weapon = weapon
	stats.base_initiative = 26  # -> ~36
	stats.equipment_initiative = 3
	return stats


## Fodder (Sec 11.3/11.4): tanky, but each swing is small — three or four of them
## are what hurts, never one. `mag_size` 0 is what "has no gun" means
## mechanically: can_shoot() is false forever. Lowest initiative on the board, so
## a swarm generally acts after the squad has already had its say.
##
## FITNESS 10 IS THE SHAMBLE, and it is the whole of what replaced the deleted
## two-speed movement override. A 6 AP pool against a 5 AP claw means it closes OR
## swings in an activation and never both — so the player still gets
## one turn of warning between "that thing is near" and "that thing is on me",
## which is the property the old lunge latch existed to guarantee. Raising this
## number is how that warning gets deleted by accident; test_swarm_pace.gd is
## there to make the attempt fail loudly.
static func swarm(display_name: String) -> UnitStats:
	var stats := UnitStats.new()
	stats.display_name = display_name
	stats.perception = randi_range(25, 40)
	# FIXED, where the other three roll, and it changed meaning enough to be worth
	# saying why. Reflexes used to be near-decorative on a swarm — it has no gun,
	# and melee accuracy is Perception (Sec 11.4) — so a 15-30 roll cost nothing.
	# It now sets the price of the claw, and across that old range the price came
	# out 3 AP or 4 depending on the roll: some swarms could step a tile and swing,
	# others could only do one or the other. That is the tier's signature action
	# behaving differently between two identical-looking creatures, so it is
	# authored now.
	# 40, re-pinned when K_REFLEXES dropped to 0.03. This number is not a
	# characterisation, it is a DIAL SET TO BUY A PRICE: the claw has to come out
	# at 5 AP against the 6 AP pool, because that is what leaves one-step-then-
	# swing affordable and two-steps-then-swing not. At the old 0.04 discount, 28
	# bought that; at 0.03 it buys a 6 AP claw — the whole pool — and a swarm that
	# has to stand still to swing cannot shamble into contact at all.
	#
	# So: if K_REFLEXES or the melee base ever moves again, this moves with it, and
	# tools/test_swarm_pace.gd is what says so out loud.
	stats.reflexes = 40
	stats.fitness = 10
	stats.luck = 15
	stats.base_hp = randi_range(15, 20)  # -> 15-20 HP: still the tier that takes work
	# stats.weapon stays null — no ranged weapon at all (Sec 11.4); the
	# weapon_base_accuracy/weapon_damage/mag_size getters all read 0 from that.
	stats.melee_base_accuracy = 45
	stats.melee_damage = 3
	stats.base_initiative = 17  # -> ~23
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
	stats.perception = randi_range(45, 65)  # it hunts; it needs to find you
	# High enough to make its claw cheap (4-5 AP against an 11 AP pool), which is
	# what pays for the close-and-strike its whole design is built on: six or seven
	# tiles of ground AND a blow, where everything else on the board buys one or
	# the other.
	stats.reflexes = randi_range(55, 70)
	stats.fitness = 70
	stats.luck = 25
	stats.base_hp = 8  # -> 13 HP: two rifle hits, killable once caught out of hiding
	# Unarmed at range like the rest of the melee tier — stats.weapon stays null.
	stats.melee_base_accuracy = 50
	stats.melee_damage = 8  # a real threat if it connects: three swings ends a soldier
	stats.base_initiative = 38  # -> ~55, it acts early
	stats.equipment_initiative = 2
	return stats


## The swarm's block with two numbers moved, which is the whole design: same
## senses, same reflexes, same pace, same lowest-on-the-board initiative, same
## absent weapon. What changes is how long it takes to put down and what it costs
## to let one reach you.
##
## 29-33 HP is roughly DOUBLE the swarm's 15-20: a swarm dies inside one soldier's
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
	stats.base_hp = randi_range(28, 32)  # -> 29-33 HP, still double the swarm
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
	stats.perception = randi_range(25, 40)  # the swarm's range: bite accuracy is Perception
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
	stats.melee_base_accuracy = 45
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
