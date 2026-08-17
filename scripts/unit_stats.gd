class_name UnitStats
extends Resource
## Per-soldier stats (design doc Sec 4.6), and the AP/HP/Initiative formulas they
## feed. Percentile values 0-99.
##
## Design: docs/design/factions/contractors/design-choices/ap-and-stat-baselines.md
## (which supersedes GDD Sec 4.0-4.3, 4.1's Initiative composition, and 4.6.2/4.6.3).
##
## Each stat now has exactly ONE major lever and a couple of minor ones, rather
## than several stats competing to be the one that matters:
##
##   Fitness  MAJOR: AP pool size. minor: max HP.
##   Reflexes MAJOR: AP cost discount on actions. minor: Initiative, Shoot/
##            Overwatch accuracy.
##
## Both were the other way round before this rework — Fitness *was* max HP and
## nothing else, and Reflexes was 60% of Initiative.

enum UnitClass { ASSAULT, SNIPER, SUPPORT, HEAVY }

## The actions the AP economy prices, which is NOT the same set as
## `Combat.ShotAction`: that enum is about how a shot RESOLVES, so its Overwatch
## entry is about the reaction shot's accuracy math, not its price — Overwatch's
## price lives here, priced identically to Shoot (see BASE_AP_COST), and no
## entry for the four actions below that cost AP without resolving a shot.
##
## Aimed Shot is deliberately absent too: its price depends on the zone picked,
## so it goes through `aimed_shot_cost` rather than this table.
enum Action { SHOOT, MELEE, GRENADE, RELOAD, HUNKER, SUPPRESS, OVERWATCH }

# --- AP pool (Sec 4.2 of the rework doc) -------------------------------------

## Every unit gets this many AP before Fitness is counted, so a unit with no
## Fitness at all can still act.
##
## THE POOL IS 1.5x WHAT IT WAS (4 + 0.05/Fitness), and both terms scaled together
## so the Fitness spread keeps the same share of it. That multiplier is half of a
## pair — see BASE_AP_COST — and the pair only makes sense read together: every
## priced action went up by the same 1.5x, so the number of ACTIONS in an
## activation is unchanged. What did not scale is movement, which is still flat at
## Unit.MOVE_AP_PER_TILE, so the extra pool cashes out entirely as GROUND COVERED.
## A soldier now crosses about half again as much map per activation, while every
## action it might take at the far end costs the same fraction of an activation it
## always did. Shooting twice, in particular, is still the whole activation.
const AP_POOL_BASE := 6
const AP_POOL_PER_FITNESS := 0.075

# --- Action costs (Sec 4.3) --------------------------------------------------

## EVERY PRICED ACTION IS ITS OLD VALUE x1.5, Shoot included (Suppress's 7.5
## rounding up, per the cost rule below). Nothing here is exempt. The one thing
## that did NOT scale is MOVEMENT, which is still flat at Unit.MOVE_AP_PER_TILE —
## so against the 1.5x pool, walking is the only thing that got cheaper, and the
## extra AP cashes out as ground covered rather than as extra actions.
##
## The target this table is fitted to: A SECOND SHOT SHOULD COST YOU THE
## ACTIVATION. A typical soldier is 10-12 AP and pays 5 for a snap shot, so
## shooting twice is 10 — affordable only by a unit that set up and stayed put.
## Move first and the second shot is gone. That is the whole shape of the
## economy: shoot twice, or shoot once and reposition, never both.
##
## Suppression is 8 against a snap shot's 6, and the gap holds at every Reflexes
## value because both take the same discount — so pinning someone is always the
## dearer option than simply shooting at them, which is what stops it being a
## strictly better Shoot. What it buys for the extra points is a whole enemy
## activation spent flinching, and a free reaction shot if they run.
##
## Overwatch is priced identically to Shoot rather than carrying its own entry —
## same base, same discount — because holding an angle should cost what taking
## the shot would have. It still ends the activation outright (see
## Unit._end_activation_ap): this is the FLOOR of that price, and any AP left
## over once it is paid is forfeited, not banked.
const BASE_AP_COST := {
	Action.SHOOT: 6, Action.MELEE: 6, Action.GRENADE: 6,
	Action.RELOAD: 6, Action.HUNKER: 6, Action.SUPPRESS: 8, Action.OVERWATCH: 6,
}

## How much Reflexes takes off each action's base cost, per point.
##
## 0.03, DOWN from the 0.04 it has always been — the one coefficient in this
## rework that moved against the grain, and the table above does not work without
## it. Scaling the bases 1.5x alone does not make anything harder, because the
## discount scales with whatever it is subtracted from in practice: at 0.04 a
## Reflexes 55 soldier pays 4 for a 6 AP shot and can still shoot twice with three
## tiles to spare, which is the opposite of the intent. At 0.03 the same soldier
## pays 5, and two shots is the activation.
##
## What it costs is some of Reflexes' bite: the discount now spans 6 AP down to 4
## across the whole 0-99 stat, where it used to span 6 down to 2. Still worth two
## tiles of movement at the top end, and still the stat's MAJOR lever — but it no
## longer buys a whole extra action on its own, which is precisely the thing that
## was undoing the price rise.
##
## Hunker is 0 rather than missing, and that is the statement: it is the one
## priced action Reflexes does not touch. Dropping behind a crate is not a thing
## you do faster by being quick. Overwatch takes Shoot's own 0.03 — it is priced
## as a Shoot, so it is discounted as one.
const K_REFLEXES := {
	Action.SHOOT: 0.03, Action.MELEE: 0.03, Action.GRENADE: 0.03,
	Action.RELOAD: 0.03, Action.HUNKER: 0.0, Action.SUPPRESS: 0.03, Action.OVERWATCH: 0.03,
}

## No action is ever free, however quick its owner. Without this floor a Reflexes
## 99 unit shoots at 0 AP and the activation never ends.
const MIN_AP_COST := 1

# Aimed Shot is priced per ZONE, so its table lives in `Combat` next to the
# per-zone accuracy modifiers it tracks — see Combat.aimed_shot_ap_cost, which
# comes back through `discounted_cost` below for the rounding.
#
# It is not merely tidier there. Naming `Combat` from this file would make
# combat.gd a compile-time dependency of UnitStats, and combat.gd reaches
# GridManager — which would take UnitStats out of the set of classes a
# `--script` headless tool can name, and several of them do.

# --- Max HP and Initiative baselines (Sec 5) ---------------------------------

## 0.08, down from 0.3, because the HP SCALE ITSELF SHRANK by roughly 3.5x — a
## soldier is ~20 max HP now, not ~70. Held at the old 0.3 the Fitness term alone
## would have spanned 9-27 HP across the class ranges, i.e. more than a whole
## soldier's health bar, and the roster's toughest and frailest would not have
## been in the same fight. At 0.08 it spans about 2-7: still the minor edge Sec
## 5.1 wants it to be, against a `base_hp` that now carries almost everything.
const HP_PER_FITNESS := 0.08
const INITIATIVE_PER_REFLEXES := 0.2

## Named, and currently zero. The leveling system is explicitly NOT designed as
## part of this rework (Sec 5.3) — these exist so the formula shape is already
## right when it is, not as a placeholder curve to fill in by guessing.
const LEVEL_BONUS_HP := 0
const LEVEL_BONUS_INITIATIVE := 0

@export var display_name: String = "Soldier"
@export_range(0, 99) var perception: int = 50
@export_range(0, 99) var reflexes: int = 50
## 0-150, not the 0-99 its three neighbours share, and the difference is not
## laxity. The other three are PERCENTILES — they feed accuracy and initiative
## rolls against a d100, so a value above 99 would mean "better than certain"
## and is meaningless. Fitness is read as a percentile in exactly one place
## (nothing rolls against it) and as a QUANTITY everywhere else.
##
## The headroom used to exist for the brawler, which was written at 95-110 back
## when max HP *was* Fitness. HP now comes off `base_hp` instead, so nothing in
## the roster needs the top of this range today — it is kept because Fitness is
## still a quantity rather than a probability, and a unit with an outsized AP
## pool is a legitimate thing to want to author.
@export_range(0, 150) var fitness: int = 50
@export_range(0, 99) var luck: int = 50
@export var unit_class: UnitClass = UnitClass.ASSAULT
# Player-selected gear (design doc `weapons/`) — stats live on the weapon, not
# the class. `null` means unarmed at range (e.g. the Fodder swarm, Sec 11.4).
@export var weapon: WeaponData = null

## Max HP before the Fitness term. 15 is the soldier's — it lands the squad at
## 17-22 max HP depending on class, centred on 20 — and non-player types hand-set
## their own (Sec 4.5/5.5) rather than being squeezed through the player's
## percentile roll system.
##
## It was 50, for a ~70 HP soldier. The whole HP scale came down about 3.5x while
## weapon damage came down only ~1.5x, and that gap IS the lethality rework: an
## Assault Rifle used to need six connected hits to drop a soldier and now needs
## three. Two for a Battle Rifle or a Shotgun. Nothing about accuracy, cover or
## crits changed — the fight is shorter because the bars are shorter, so cover and
## first contact decide more and attrition decides less.
##
## This field is what makes tanky-and-slow expressible again. It used to be one
## number — Fitness was HP *and* pace — so a tough, slow unit was a contradiction
## the roster worked around. Now toughness is here and pace is Fitness, and the
## two are set independently.
@export var base_hp: int = 15

## Initiative before the Reflexes term. Same split as `base_hp`: the player's
## soldiers all sit on the Sec 5.2 baseline of 50, and each non-player type
## hand-sets its own standing in the draw order.
@export var base_initiative: int = 50

## Flat Initiative bonus from gear (Sec 4.1's "equipment bonus"). ADDITIVE now,
## where it used to be a 0-99 value taken at 10% weight — so the numbers here are
## an order of magnitude smaller than the ones this field held before the rework,
## and porting an old value across unchanged would make gear the loudest term on
## the board. Magnitude is still formally open (rework doc Sec 6 item 2).
@export var equipment_initiative: int = 5

var weapon_base_accuracy: int:
	get: return weapon.base_accuracy if weapon else 0

var weapon_damage: int:
	get: return weapon.damage if weapon else 0

var mag_size: int:
	get: return weapon.mag_size if weapon else 0

# Contact-range attack (Sec 11.4). Separate from the weapon numbers above so a
# unit can be dangerous in melee and harmless at range, or the reverse — the
# Fodder swarm has no gun at all (mag_size 0) and only these two matter to it.
@export var melee_base_accuracy: int = 45
@export var melee_damage: int = 3


## AP available for one activation (Sec 4.2). Floored, per the rounding rule
## below: a unit never has more than the formula gives it.
func ap_pool() -> int:
	return floori(AP_POOL_BASE + AP_POOL_PER_FITNESS * fitness)


func action_cost(action: Action) -> int:
	return discounted_cost(BASE_AP_COST[action], K_REFLEXES[action], reflexes)


## Sec 4.3b, the cost half of the rounding convention: costs round UP, and never
## below MIN_AP_COST. The pool half (`ap_pool`, `max_hp`, `initiative`) rounds
## DOWN. One sentence for both: a unit never has more than the formula gives it,
## and never pays less than the formula charges it. Deliberately asymmetric
## rather than round-to-nearest, so there is no favourable rounding boundary to
## hunt for.
##
## Static, and the one place any AP price is rounded — Combat's per-zone Aimed
## Shot costs come back through here rather than repeating the rule.
static func discounted_cost(base: int, k: float, reflex_value: int) -> int:
	return maxi(MIN_AP_COST, ceili(base - k * reflex_value))


## Sec 5.1. Fitness's contribution is explicitly MINOR now — its major role moved
## to the AP pool. A soldier's toughness is mostly baseline, with Fitness giving
## a modest edge rather than being the whole of it.
##
## Downstream, and worth knowing before reading a playtest: the body-part injury
## thresholds of Sec 4.2.1 are fractions of this, so compressing HP into a
## narrower band compresses the absolute thresholds across the roster with it.
func max_hp() -> int:
	return floori(base_hp + HP_PER_FITNESS * fitness + LEVEL_BONUS_HP)


## Sec 5.2. NO class base modifier term — that is not an omission, it is the
## change: class identity in turn order is now indirect only, via whatever
## Reflexes range a class tends to roll in (Sec 4.6.5). Re-adding a direct
## per-class term is a deliberate design decision, not a bug fix.
func initiative() -> int:
	return floori(base_initiative + INITIATIVE_PER_REFLEXES * reflexes
		+ equipment_initiative + LEVEL_BONUS_INITIATIVE)
