# AI Decision Model

*Source: GDD Section 11.1, implementation scaffold Section 11.8. Current code
(`scripts/enemy_unit.gd`) implements only a minimal iteration-1 version of this — see "Current
implementation status" below.*

## The model

A **layered state machine** with a **lightweight utility-scoring pass inside Combat** to choose
the best action each activation:

| State | Behavior |
|---|---|
| Unaware | Patrols/rests near its nest/spawn area. No awareness of any player unit. |
| Alert / Investigating | Detected a stimulus but has no confirmed target; moves toward the last known stimulus location. |
| Combat | Has a confirmed target; participates in the initiative pool with utility-scored target/action selection. |
| Search | Lost track of all player targets; searches around the last known position before reverting to Unaware. |

## Why a state machine plus utility scoring, not one or the other

A pure state machine handles *macro* behavior (am I even aware of a threat) cleanly, but is a
poor fit for *micro* decisions (which of three visible targets, which action) — those need
comparison between options, which utility scoring is built for. Splitting the two keeps each
piece simple: the state machine answers "what phase am I in," the utility pass only has to run,
and only matters, inside Combat.

## Utility scoring weights (defaults)

**Flanking opportunity** and **low-HP retreat** are the two highest-weighted factors in action
selection — both outrank raw "can I take a shot now." This means an alien with a flanking route
available will generally take it over an immediate mediocre shot, and a badly hurt alien will
prioritize disengaging over pressing an attack. *(Tunable — refine after playtesting.)*

## Per-type behavior via exported parameters

Rather than three separate codebases for Fodder/Agile Hunter/Spitter, the `AlienUnit` base class
(extends the shared `Unit` class) holds one state machine component, and per-type differences are
expressed as exported parameters: `preferred_engagement_range`, `flanking_bias_weight`,
`retreat_health_threshold`, `prefers_darkness: bool`, `ambush_light_threshold`,
`ambush_proximity_range`. This keeps balance tuning a matter of adjusting numbers on a resource,
not editing behavior code per type.

## Current implementation status

`scripts/enemy_unit.gd` is explicitly a **minimal iteration-1 stand-in**: shoot the nearest
visible player unit if in range and LOS is clear, otherwise move toward it. No state machine, no
utility scoring, no per-type parameters yet — the full model above is the target, not the current
state of the code.
