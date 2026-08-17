# Faction: Rival Mercs

> ## 📝 DESIGN DRAFT — 2026-08-17
>
> **Built today:** the shared GOAP framework (`scripts/ai/`), the `Suppress` → `Flank` doctrine,
> squad-wide radio alerting, role assignment via `SquadCoordinator`, and aimless map-wide
> patrolling while `UNAWARE`. See [`docs/design/systems/coordinated-ai/README.md`](../../systems/coordinated-ai/README.md)
> for how the framework itself works — this document is the faction's half: what a merc squad is
> *for*, and everything below "Built today" is proposed, not yet in code.
>
> This document supersedes the informal notes that used to live here. It is the source of truth
> for the faction until it is either implemented (at which point this file gets the same
> "alpha implemented" treatment `security-robots/README.md` got) or revised.

*Written to slot into the existing systems — the initiative pool, the AP economy, the additive
accuracy formula, cover/LOS, the light/flashlight channel, the GOAP framework — without inventing
a second planner or a parallel combat system. Where a mechanic doesn't exist yet (objectives,
tiering, overwatch-awareness), it's called out as new work rather than assumed.*

## Identity

A rival contract crew, on the same derelict for a reason of their own — not aliens, not the
ship's own security network defaulting to lockdown, but people with a job, a radio net, and
rig lights, doing what the player's squad is doing. That symmetry is the point: a merc squad is
built to be read as *another player squad*, not as a reskinned monster wave. It should use cover
the way the player does, retreat the way the player would, and only fight recklessly when the
plan calls for it — never as its default state, since a mission is not truly won until you
know you weren't the only professional crew on this ship.

## Mechanical identity (how it differs from the other two factions)

| Axis | Aliens | Security Robots | Rival Mercs |
|---|---|---|---|
| Detection | Light + sound, same rules as the player | Sound + motion, light-blind | Light + sound, same rules as the player — **and they carry their own rig lights**, so they're trackable in the dark the way nothing else is |
| Alert propagation | Local, room/nest-scoped | Ship/zone-wide, over the security network | **Ship-wide over a radio net**, bounded only by who's on the channel — engaging one merc engages the whole squad |
| Presence on the deck | Spawns from a nest, stays | Holds an assigned post/zone | **Arrives with a job and leaves when it's done** — see §1 |
| Cover interaction | Standard | Standard + armor layer | Standard, and cover-seeking is closer to the player's own posture than either AI faction's |
| "Downed" state | Injured, recoverable | Destroyed outright | Injured, recoverable — human, same rules as the player squad |
| Squad shape | Loose nest cluster, no coordination | Zone-mates converging, no role negotiation | **The one faction that actually plans as a squad** — GOAP + blackboard + role assignment |

## 1. Ship presence: arrival, objective, departure

A merc squad is not furniture waiting in a room for the player to find it. It has a reason to be
aboard, and that reason has a beginning, a middle, and an end.

**Spawn point.** Squads deploy from a location that will eventually be an authored **hangar** —
a docking bay their own ship is parked in. Not built yet; for now, track a squad's spawn as a
plain `Vector3i` set at encounter setup (the same way any spawner already places a unit), so the
withdrawal leg (below) has something concrete to walk back to before the hangar exists as
authored geometry.

**Objective.** On spawn, the squad rolls one task from a short list, and that task governs its
`UNAWARE`/pre-contact behaviour — what it's doing instead of standing still:

| Objective | Pre-contact behaviour | "Complete" condition |
|---|---|---|
| **Hunt the player** | Patrol the deck (existing `_idle_turn` behaviour, retargeted at areas the player is likely to be rather than a pure random walk once intel exists — see below) | Never completes on its own; ends only when the squad disengages or is wiped |
| **Destroy a target** (e.g. a data drive, a comms relay) | Path toward a marked objective location | A unit reaches the location and spends an activation "working" it, mirroring how the player interacts with mission objects |
| **Retrieve an item** | Path toward a marked objective location | Same shape as Destroy: reach it, spend an activation on it, then carry it for the withdrawal leg |

The list is deliberately short at first — this is the seam other objective types slot into later
(e.g. "hold a location," "extract a VIP"), not the final roster of them.

**The squad-state machine**, layered above each merc's own `AlertState` the same way `EnemyUnit`
already layers `_combat_turn`/`_investigate`/`_idle_turn` above the awareness machine:

```
DEPLOYING → WORKING → COMPLETING → WITHDRAWING → DEPARTED
                ↕ (any state)
             COMBAT (existing AlertState.COMBAT, on any unit)
```

- **DEPLOYING** — walking from the hangar spawn toward the objective area.
- **WORKING** — the objective-specific behaviour in the table above.
- **COMPLETING** — one unit performs the completion action (see below); the rest hold position
  and screen it, which is the same shape `Suppress`/`Flank` already give the combat doctrine, just
  applied to a friendly action instead of a hostile one.
- **WITHDRAWING** — path back to the spawn point.
- **DEPARTED** — despawn once every living member reaches the spawn tile. A squad that took
  losses still leaves with however many of it survived; it does not wait to be finished off.

Combat interrupts this at any point and resumes it afterward: a squad that loses contact with the
player (the existing `lose_contact_turns` rule) picks its objective state back up rather than
reacting as if nothing happened, the same way `_investigate` already returns to `_idle_turn`. A
squad that has taken heavy losses (see §5) may resolve the interruption as WITHDRAWING instead of
resuming WORKING — retreating *is* the squad's answer to "we can't finish this," not a separate
system bolted on top.

**The completion action** needs one new small thing: a mission-object interaction (`interact()`
or similar) that a unit — merc or player — can spend an activation on. That doesn't exist for
either side yet, so it's shared new work rather than something scoped to this faction alone; see
the implementation plan.

## 2. Squad composition and tiers

Squad size: **4–10**, fixed per encounter at spawn (not dynamically reinforced — a merc squad is
the crew that flew in, not a respawning wave). Composition beyond size is future work; for now
every member draws from the same `MercUnit` stat block.

**Veteran tier**, v1: a stat-only variant — better `UnitStats` (accuracy, HP, AP pool, whatever
the tuning pass lands on), same `Doctrines.merc_brain`, same action library. No behavioural
divergence yet. This is deliberately the same shape `security-robots` used for Interceptor/Warden
before cutting them: prove the slot is worth having with the cheap version before spending a
planner change on it. A later pass can give veterans doctrine differences (e.g. weighted toward
the `SUPPRESSOR` role, or a lower `HURT` retreat threshold) once the base squad reads well.

## 3. Probabilistic action selection

**This replaces the hard `ATTACK_RANGE` gate.** Today, `GoapBrain.read_state` computes `IN_RANGE`
as a boolean — inside `EnemyUnit.ATTACK_RANGE` (8 tiles, Chebyshev) or not — and every action
that needs it either can or can't be planned. That's a clean mechanism but a flat one: a merc at
7 tiles with a sliver of LOS through a doorway is exactly as eager to shoot as one at point-blank
with a clean lane.

The replacement: **every combat action gets a scored "is this worth doing" pass on top of its
existing hard preconditions**, and the planner's choice among available actions is weighted by
that score rather than taking whichever the A* search finds cheapest. Hard preconditions don't go
away — ammo, a reachable tile, a role not already claimed are still binary, because there's no
interesting question in "should I try to shoot with an empty magazine." What becomes probabilistic
is the *judgment calls*: shoot now vs. close the distance, take the risky long shot vs. hold for a
better angle, commit to a flank vs. fall back.

**Scoring inputs** (the "what has the best perceived odds of the best outcome" the ask calls for):
- **Hit probability** — read straight from `Combat.compute_accuracy` for the shot being scored.
  This is the one input that's already computed elsewhere in the codebase; nothing new needed to
  read it.
- **Expected value of taking the shot** — hit chance × expected damage vs. the target's remaining
  HP, so a merc doesn't spend its action on a 20%-chance plinking shot when closing one tile
  turns it into a 60%-chance one next activation.
- **Exposure cost** — how much cover the *unit itself* gives up to take the shot (an `Attack` from
  open ground scores worse than the same shot from `AttackFromCover`), and whether the tile is
  covered by a known player overwatch (§5).
- **Squad value** — whether this unit taking the shot serves the doctrine (e.g. the assigned
  `SUPPRESSOR` shooting is worth more than an unassigned unit taking a speculative shot the
  squad didn't ask for).

**Where this plugs into the existing framework:** `GoapAction` already separates hard
preconditions (`preconditions`, planner-visible) from a runtime `is_available` gate. The score
becomes a third number the action can report — `expected_value(unit, ctx)` — and
`GoapBrain._plan_for_best_goal` uses it to break ties among multiple *legal* plans it already
knows how to build, rather than reworking the A* search itself. `IN_RANGE` stops being a single
boolean cutoff and becomes a smooth accuracy-vs-distance curve already implicit in
`Combat.compute_accuracy` — a merc "in range" is really just a merc for whom some action scores
above the threshold worth taking.

This is genuinely new design work, not a documentation pass — see the implementation plan for how
it's scoped and tested.

## 4. Cover: seek it, deny it

Cover-seeking (`RepositionToCover`, `fight_from_cover`) stays as built. New: **`DestroyCover`
joins the merc action library**, currently Cerberus-only. Mercs get it because a squad that reads
as capable should be able to force the issue the same way the robots do — but it must not read as
the same doctrine wearing a different faction, which is the whole point of Cerberus's "no
flanking, ever" contrast in the coordinated-ai doc.

**Design constraint: lower priority than for Cerberus.** For the robots, `break_their_cover` is
the *first* goal in the list — the doctrine in one line. For mercs, cover-breaking sits below
`Flank`: a merc squad's answer to good player cover is still "go around it" first, and "shoot
through it" only when going around isn't working (no reachable flank tile, or the flank role is
already claimed and this unit has nothing better queued). Mechanically: add `DestroyCover` to
`Doctrines.merc_brain`'s library, and give its goal a lower rank position (and/or a `relevance`
curve that only rises once `Flank` has failed to produce a plan this activation) rather than
placing it above `flank` the way Cerberus's `break_their_cover` sits above everything.

**Deferred, explicitly:** height/elevation and distance factors on cover-breaking (shooting cover
from an angle or elevation the target can't easily reposition around). Noted here as the seam this
slots into once elevation is a modelled thing the accuracy formula reads, not designed now.

## 5. Self-preservation and overwatch awareness

Two related pieces: a squad that behaves like its members' lives are on the line, and a squad that
can read the one player mechanic that punishes reckless movement.

**Overwatch awareness (new mechanic).** `Unit.on_overwatch` is already a plain, unhidden bool —
nothing has ever needed to *ask* whether a unit is covering an angle, because nothing has needed
to plan around it before. New: `GoapBrain.read_state` (or a helper it calls) collects hostile units
with `on_overwatch == true` and, for any tile a movement action is considering, checks
`GridManager.has_line_of_sight` from each watcher to that tile. A tile a known watcher covers
scores as expensive ground in §3's exposure term — not impassable, since sometimes crossing a
covered lane is the least-bad option, but a plan that avoids it should almost always outscore one
that doesn't.

**Bait vs. hide.** When a squad needs to cross ground a watcher covers and there's no way around
it, it should send its most expendable unit through rather than its most valuable one (see §6 for
what "valuable" means from the *player's* side — this is the mirror question, "which of my own
units can I afford to lose"). Concretely: the unit crossing a covered lane is chosen by lowest
current HP / most replaceable role (an unassigned unit over the current `FLANKER`/`SUPPRESSOR`),
which reuses the priority-scoring machinery from §6 rather than inventing a second one.

**Not suicidal, generally.** Falling back is an acceptable outcome, not a failure state for the
AI to avoid. This needs an explicit squad-level retreat condition — proposed: once a threshold
share of the squad is downed (tunable, e.g. half), the squad's objective state (§1) resolves to
WITHDRAWING regardless of what it was doing, and individual `HURT`-driven `fight_from_cover`
behaviour (already in `doctrines.gd`) continues to cover individuals below that threshold. This
is the squad-level backstop; the per-unit reactive cover-seeking already handles "one merc is
badly hurt but the squad is fine."

## 6. Priority targets

New shared fact, read by the whole squad rather than computed privately per unit (the same reason
`SQUAD_NEEDS_PIN` became `SquadCoordinator`'s job instead of each unit's private conclusion — see
`doctrines.gd`'s note on why that didn't scale past two mercs). A **priority score** per visible
hostile, combining:

- **Positional threat** — a player unit in strong cover with a clean lane is worth more attention
  than one caught in the open (which the squad can already punish cheaply without needing to
  agree on anything).
- **Damage output already shown** — a unit that has suppressed or hit a squad member this
  encounter reads as more dangerous than one that hasn't fired yet.
- **Faction weight** — a player unit outranks incidental aliens wandering into the same fight; the
  squad shouldn't spend a `SUPPRESSOR` claim pinning a fodder alien that wandered into LOS.
- **Vulnerability** — a wounded or exposed player unit is worth finishing over a healthy one at
  equal threat, the same "focus fire" logic real squads use.

Computed once per squad read (alongside `SquadCoordinator.assign`, which already runs before
individual units plan) and written to the blackboard as the squad's current priority target,
rather than each `MercUnit.acquire_target()` continuing to fall back to "nearest visible." Units
whose own doctrine goal doesn't specify a target (e.g. `Flank`, which needs *a* target but not
necessarily the top-priority one if this unit has no angle on it) still fall back to their own
best option — this is a bias on the squad's shared attention, not a hard lock, matching how
`assignment_for` is already advisory rather than absolute.

## 7. Team play

Structurally already the strongest part of the faction — `Suppress` → `Flank` across two draws,
role claims on the shared blackboard, squad-wide radio alerting. What's proposed above extends it
rather than replacing it: priority targets (§6) and overwatch-awareness (§5) both become new
*facts* the existing coordinator/blackboard machinery reasons over, not a second coordination
layer. `DestroyCover` (§4) is a new library entry the existing goal-ranking already knows how to
sequence. The probabilistic scoring in §3 changes *how a unit picks among legal actions*, not
whether the squad negotiates roles — that stays exactly as built.

## 8. Alien awareness

Mercs need to read aliens as a distinct hazard, not just another entry in `hostiles()`. Proposed:

- **A threat-range table** per alien type (melee reach for swarm/hunter types, spit range for a
  spitter once it exists) that a merc's action scoring (§3) reads the same way it reads a player
  overwatch lane — closing to melee range of something that kills at melee range scores as
  expensive ground.
- **Ammo discipline against low-value alien threats** — a `Fodder` alien shambling into LOS
  shouldn't draw a full-value `Attack` decision the way a player unit does; this falls mostly out
  of §6's priority scoring once aliens are weighted correctly rather than needing separate logic.
- **Kiting instead of standing** — a merc caught at melee range by something fast should have
  `RepositionToCover`/retreat outscore standing and trading, which is the existing `HURT`
  relevance curve doing the same job it already does for player-inflicted damage, once the
  threat-range table feeds it.

This section is intentionally the thinnest — it's mostly "feed the existing self-preservation and
priority machinery an alien-specific input," not a new subsystem, and should be revisited once
`Faction.HOSTILE_TO` cross-faction hostility (already built, not yet turned on per the
coordinated-ai doc's "still missing" list) is live and this can be observed rather than guessed at.

## Explicitly out of scope (for now)

- **Voice lines / barks beyond the existing radio-contact text** in `merc_unit.gd`. The squad
  already narrates contact calls and role claims (`Barks.line` via `SquadBlackboard._announce`);
  expanding that vocabulary is a content pass, not a behaviour one, and isn't blocked on anything
  above.
- **Distinct shooting animations** (lean/peek/blind-fire, tier- or role-specific poses). Visual
  work, tracked separately from this doc.

## Test criteria

Each numbered section above should be checkable against a concrete claim before it's considered
done, the same way `tools/test_goap.gd` pins the framework's rules rather than its tuned numbers:

1. **Objectives** — a squad given `destroy_target` reaches the marked location, spends an
   activation completing it, and transitions to `WITHDRAWING` without manual intervention; a squad
   given `hunt_player` never self-resolves to `WITHDRAWING` from patrolling alone (only from
   combat losses, §5).
2. **Tiers** — a veteran-tier merc measurably outperforms a standard one in a controlled
   accuracy/HP check; doctrine and action library are otherwise identical (asserted, not just
   "not obviously different").
3. **Probabilistic selection** — given two candidate actions with known, different expected
   values under the scoring in §3, the brain picks the higher-scored one; and a merc beyond
   effective range (very low hit probability) prefers `Advance` over a low-odds `Attack` without
   needing a hard range cutoff to force it.
4. **Cover** — `DestroyCover` is reachable by a merc's planner, and in a scenario where both
   `Flank` and `DestroyCover` are legal, `Flank` is chosen; cover-breaking is only chosen when
   flanking has no legal plan this activation.
5. **Overwatch awareness** — a merc given a choice between a tile covered by a known player
   overwatch and an uncovered route to the same destination takes the uncovered one; when no
   uncovered route exists, the unit sent through is the one the priority-scoring machinery (§6)
   ranks most expendable, not an arbitrary squad member.
6. **Priority targets** — given two visible player units of unequal threat/exposure, the whole
   squad's `SUPPRESSOR`/`FLANKER` assignments (via `SquadCoordinator`) target the higher-priority
   one, not whichever a unit happened to spot first.
7. **Team play** — unchanged behaviour from what's already built continues to pass
   `tools/test_goap.gd`'s existing assertions after §3–§6 land; the doctrine sequence
   (`Suppress` before `Flank`, never both claimed by the same unit) still holds under the new
   scoring.
8. **Alien awareness** — a merc squad fighting both the player and an incidental alien spends its
   `SUPPRESSOR`/priority attention on the player; a merc adjacent to a melee-threat alien
   deprioritises standing and trading in favour of repositioning, once §5's relevance curve is fed
   the threat-range table.
