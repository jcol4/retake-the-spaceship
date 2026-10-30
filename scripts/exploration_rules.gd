class_name ExplorationRules
extends RefCounted
## The exploration rules (GDD §4.7, EXPLORATION_PLAN.md), engine-free: the step
## clock and its carry-over, the predicates that move a mission between
## exploration and turn mode, the opening shot's AP, and the scheduler that
## turns a tick's recorded AI turns into one shared playback timeline. No scene
## tree, no autoloads, no Unit class — tools/test_exploration.gd drives all of
## it directly, as test_extraction.gd drives ExtractionRules. TurnManager is the
## node side that feeds it steps, rounds and recorded events.
##
## "Round" is TurnManager.turn_number, the one clock: out of combat it advances
## through the same round-end/round-start path a combat round does, so every
## round timer in the game (bleed-out, ship countdown, Hold, nest spawns) keeps
## working with no exploration-specific timer of its own.

## GDD §4.7.3: steps of action that make one round out of combat. Every tile
## walked is a step (two or three on a wounded leg, E17), and every other action
## costs its AP price in steps. Tune in plan D.4.
const STEPS_PER_ROUND := 20


## The clock after adding `n` steps to `steps`: [steps, rounds crossed]. Steps
## past a boundary CARRY (E6) — 19 + 3 is one round with 2 on the clock, so an
## action never loses the part of itself that spilled over.
static func advance(steps: int, n: int, per_round: int = STEPS_PER_ROUND) -> Vector2i:
	var total := maxi(0, steps) + maxi(0, n)
	return Vector2i(total % per_round, total / per_round)


## Steps still to go before the next round ticks. Wait (plan B.10) adds exactly
## this, which is what makes one press always one round.
static func steps_to_boundary(steps: int, per_round: int = STEPS_PER_ROUND) -> int:
	return per_round - (maxi(0, steps) % per_round)


## Rounds a `cost`-step action would pass from `steps`, for the path readout
## ("23 steps · 1 round").
static func rounds_passed(steps: int, cost: int, per_round: int = STEPS_PER_ROUND) -> int:
	return advance(steps, cost, per_round).y


## Mirrors Faction.Id.CONTRACTORS. Spelled out like ExtractionRules.LIFE_DEAD so
## this file names no other script; the test asserts the two agree.
const SQUAD_FACTION := 0


## Whether an enemy entering combat against `target_faction` starts turn mode
## (plan B.3): its target is on the squad's side — a soldier, the squad's door
## gun or the Recover VIP, all Contractor faction. A fight between two other
## factions puts both into COMBAT, but not against the squad, so it starts
## nothing; neither does an ALERT unit investigating, which never gets this far.
static func targets_squad(target_faction: int) -> bool:
	return target_faction == SQUAD_FACTION


## Whether turn mode may end at the close of round `ending_round` (plan B.9):
## a full round has passed since the last one with contact against the squad.
static func quiet_for_a_round(last_contact_round: int, ending_round: int) -> bool:
	return ending_round > last_contact_round


## The AP a soldier starts their first combat activation with after opening the
## fight from exploration (E8): the opening shot came out of it. Never negative.
static func opening_ap(pool: int, pre_spent: int) -> int:
	return maxi(0, pool - maxi(0, pre_spent))


# --- Tick playback (plan B.12, E25) ---------------------------------------------
#
# A tick's AI turns are DECIDED one at a time, in initiative order, as logic only
# — so no AI code changes and results stay repeatable — and every unit appends
# what it did to a timeline. Each event is a Dictionary with at least
#   "unit"  any key naming the unit (a node path on the wire, a node on the host)
#   "kind"  one of the EV_* kinds below
# and per kind:
#   step   "from", "to" (Vector3i), "yaw" (float, facing on arrival)
#   turn   "yaw"
#   light  "on" (bool)
#   shot   "target" (unit key), "hit", "crit" (bool), "rounds" (int), "melee" (bool)
#   down   "dead" (bool)
#   spawn  "by" (the spawner's key)
#
# `schedule` then gives every event the earliest slot it can play in, and the
# playback walks the slots with every unit's events in a slot playing together.

const EV_STEP := "step"
const EV_TURN := "turn"
const EV_LIGHT := "light"
const EV_SHOT := "shot"
const EV_DOWN := "down"
const EV_SPAWN := "spawn"


## The slot each of `events` plays in, index for index. One pass in recorded
## order. An event goes in the earliest slot that is after:
##   - its unit's own previous event (a unit does one thing at a time),
##   - any shot at its unit recorded before it (a unit being shot holds still
##     for it, so a hit reaction or a collapse plays after the burst),
##   - for a step, the last slot any unit LEFT the tile it steps into — B into a
##     tile A just vacated waits until A is out, so two models never overlap
##     mid-step,
##   - for a shot, the target's own last event so far — the shot lands where the
##     target is drawn, after its last step has played,
##   - for a spawn, the spawner's last event.
static func schedule(events: Array) -> Array[int]:
	var slots: Array[int] = []
	var own_last := {}
	var shot_at := {}
	var vacated := {}
	for e: Dictionary in events:
		var unit: Variant = e.get("unit")
		var slot := 0
		if own_last.has(unit):
			slot = own_last[unit] + 1
		if shot_at.has(unit):
			slot = maxi(slot, shot_at[unit] + 1)
		var kind: String = e.get("kind", "")
		if kind == EV_STEP and vacated.has(e.get("to")):
			slot = maxi(slot, vacated[e.get("to")] + 1)
		elif kind == EV_SHOT and own_last.has(e.get("target")):
			slot = maxi(slot, own_last[e.get("target")] + 1)
		elif kind == EV_SPAWN and own_last.has(e.get("by")):
			slot = maxi(slot, own_last[e.get("by")] + 1)
		slots.append(slot)
		own_last[unit] = slot
		if kind == EV_STEP:
			vacated[e.get("from")] = maxi(vacated.get(e.get("from"), -1), slot)
		elif kind == EV_SHOT:
			shot_at[e.get("target")] = maxi(shot_at.get(e.get("target"), -1), slot)
	return slots


## The events grouped by slot: an Array of Arrays of event indices, slot by slot.
## Empty slots cannot occur — each slot is one past something already placed.
static func by_slot(slots: Array[int]) -> Array:
	var out: Array = []
	for i in slots.size():
		while out.size() <= slots[i]:
			out.append([])
		out[slots[i]].append(i)
	return out
