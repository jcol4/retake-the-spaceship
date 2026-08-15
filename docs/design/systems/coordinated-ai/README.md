# Shared GOAP Coordination Framework

*Implemented 2026-08-10. Source of truth for behaviour is `scripts/ai/`; this document
records what was built, what it decided, and what is deliberately still missing.*

One Goal-Oriented Action Planning framework, three factions, three different fights. The payoff
being bought is **multi-unit role negotiation** — units that check a shared blackboard before
committing to a role — not merely smarter individual decisions.

## 1. The shape of it

| File | What it is |
|---|---|
| `scripts/ai/goap_action.gd` | One action: preconditions, effects, AP cost, execution. |
| `scripts/ai/goap_actions.gd` | The shared library every faction draws a subset from. |
| `scripts/ai/goap_planner.gd` | A* over the action graph. |
| `scripts/ai/goap_brain.gd` | Runs one unit's activation: read state, rank goals, plan, execute, replan. |
| `scripts/ai/squad_blackboard.gd` | Per-squad claims and facts. |
| `scripts/ai/doctrines.gd` | Per-faction action library + goal order. |

A doctrine is **exactly two things**: which actions a unit may draw from, and what order it wants
goals in. There is no third knob, and adding one would be the first step back toward three
planners.

The integration seam is `_combat_turn()` — the same override point `SwarmUnit` and `SecurusUnit`
already used. A unit either has a brain or it does not, which is what keeps Fodder planner-free
**structurally** rather than by anybody remembering not to give it one.

## 2. Costs come from the AP formulas

Every `ap_cost` routes through `Unit.action_cost` / `move_cost_for` → `UnitStats`. There is no cost
table in the AI layer and there must not be one: a planner scoring against invented numbers drifts
out of step with what actions actually charge, and the drift shows up as an AI that plans things it
cannot afford. `tools/test_goap.gd` asserts this directly.

## 3. Claims outlive activations — forced by the initiative pool

Units are drawn **one at a time** from a shared random pool. There is no squad turn. So a merc that
suppresses and the ally that flanks are separate draws with anything at all in between.

A claim that expired at the end of its owner's activation would therefore never once be read by the
ally it was meant for, and the coordination would be decoration. Claims persist and are
**revalidated when their owner is next drawn**, with four releases: owner downed, target downed,
goal achieved, and a two-turn staleness backstop.

Coordination degrades gracefully when the draw order is unkind. That is the honest outcome — the
pool is supposed to be able to spoil a plan.

## 4. Doctrine

### 4.1 Rival mercs — angle discipline

`Suppress` → `Flank`, and it is a **squad sequence across two draws, not a chain one unit walks**:
suppression ends the suppressor's activation outright, so the merc that pins is never the merc that
flanks.

Which merc does which falls out of the `squad_needs_pin` fact — target in cover, nobody has pinned
it, an ally still standing. The first merc drawn sees that and lays down fire. The next reads a
board where it is no longer true, drops through to the flank goal, and takes the angle the covering
fire bought. **Neither is told what the other did.**

Self-preservation is gated on `is_hurt` rather than merely ranked low. Ranking would not work: an
unhurt merc in the open satisfies nothing else more cheaply than by ducking, so it would duck every
turn and never flank at all.

### 4.2 Cerberus — no flanking, ever

`Flank` is **absent from the robot library**, not deprioritised. A doctrine expressed as a low score
is one tuning pass from evaporating. `RepositionToCover` is absent too — a machine grinding forward
does not duck.

The roster gained the unit this doctrine needed: **FRC-6 Lictor**, a ranged cover-breaker. Securus
already broke cover, but only by walking up and hitting it. Without a unit that removes cover *at
range*, a squad that cannot manoeuvre is one you hold a corner against indefinitely. Its counterplay
is its own fragility — thin plate, small magazine, 3 AP pool.

### 4.3 Aliens — hivemind pressure

**Agile Hunter** now exists and is the only alien with a planner. Flanking is its **standing
tactic**, not gated to an ambush; the old darkness-plus-proximity condition survives as a **bonus**
(`ambush_bonus_accuracy`, +25 through the existing melee accuracy math). So the condition decides
how well an ambush goes rather than whether the creature may try one.

Fodder feeds it for free: `ally_is_engaging_target` is read off a shambler doing what it always
does. Fodder gets no planner and no blackboard access, and never learns it helped.

## 5. Escalation

Local propagation is the default and is now genuinely local — **scoped by compartment**, not by a
6-tile radius that leaked through bulkheads. Isolating rooms with doors finally does what §11.2 says
it does.

`AlienHivemind` adds ship-wide escalation on trigger. Roused aliens go to **ALERT and investigate**
— never straight to COMBAT, never handed a target — so escalation compresses *how many things are
coming* without breaking *they still have to find you*. It expires after `DE_ESCALATION_TURNS` (4),
settling everything that never made contact and leaving anything that found a fight alone.

| Trigger | Status |
|---|---|
| Nest destruction | `report_nest_destroyed` written; **no caller — `Nest` does not exist** |
| Alarm panel | **Built.** Map glyph `!`, routed through the ordinary sound channel at ship-wide radius, exactly as designed. Fires once; aliens do not trip it |
| Hivemind relay | **Not built, deliberately** — §8 gates it on playtesting the cheaper two |

## 6. Resolved open questions

- **Replanning cadence** — replan after every executed step. Under the pool, a plan more than one
  step old was formed against a board that has since moved, and a full replan over a library this
  small costs less than deciding whether the old plan still holds.
- **Blackboard claim release** — four rules, §3 above.
- **Ambush bonus magnitude** — +25 accuracy through the existing melee math, per the constraint that
  it reuse existing systems rather than invent a bonus type.
- **De-escalation timer** — 4 turns, tunable constant.
- **Cerberus squad definition** — the security zone. It needed no new concept: the group that
  already shares an alert is the group that should share a plan.

## 7. Still missing

- **`Nest` (§11.7)** — blocks the nest-destruction trigger. The seam is written.
- **Spitter (§11.6)** — never built; unrelated to this framework but the last roster gap.
- **Hivemind relay** — deliberately gated on playtesting.
- **Cross-faction hostility** — `Faction.HOSTILE_TO` is built and tested but still reproduces the old
  two-sided behaviour. Turning it on is a one-line change with real balance consequences; the
  merc↔security relationship is the interesting lever (ship security plausibly reads a rival
  contract crew as authorised and the player as intruders).
- **Everything here is unplaytested.** Every constant is a starting point.
