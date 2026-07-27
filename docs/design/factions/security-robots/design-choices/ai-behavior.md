# AI Behavior

## Reusing the alien state-machine model, with one state swapped

Cerberus units reuse the same **layered state machine + utility scoring** approach the aliens use
(see [`../../aliens/design-choices/ai-state-machine.md`](../../aliens/design-choices/ai-state-machine.md)),
since it's already the GDD's general-purpose AI model (Section 11.1) and there's no reason to
invent a second framework for a second faction:

| State | Alien behavior | Cerberus behavior |
|---|---|---|
| Unaware → **Standing Post** | Patrols/rests near nest | Holds a fixed post or short patrol route; does not "rest," since it's a machine on standby, not a resting creature |
| Alert / Investigating | Moves toward last known stimulus | Same, but can be triggered by a **network broadcast**, not just its own sensors — see [`detection-and-network-alert.md`](detection-and-network-alert.md) |
| Combat | Utility-scored target/action selection | Same utility model, different weights (below) |
| Search | Searches last known position, reverts to Unaware | Reverts to **Standing Post**, not a patrol — a robot returns to its assigned position rather than resuming a route, reinforcing that it's defending a place, not wandering |

**Why rename Unaware to "Standing Post":** it's the same slot in the state machine, but the
Cerberus framing ("defending a checkpoint") reads oddly under a state named for *unawareness* —
a sentry at a post is aware of its post, just not of a target yet. Purely a naming/flavor choice;
the transition logic is unchanged.

## Utility weights: armor and posture over flanking

Aliens weight flanking opportunity and low-HP retreat highest (GDD Section 11.1). Cerberus units
invert the retreat half of that:

- **Flanking opportunity** — still high-weighted; a robot with a clean flanking angle
  (bypassing Cover per Section 6.2) will generally take it.
- **No low-HP retreat.** A security unit doesn't have a self-preservation drive — it holds its
  engagement until destroyed or the encounter ends, rather than disengaging at a health
  threshold. This is a deliberate contrast: fleeing, wounded aliens create one kind of tactical
  read ("finish it before it escapes"), while robots that never retreat create a different one
  ("commit to the fight or don't start it") — reinforcing that Cerberus engagements are meant to
  be about *positioning before* the fight starts, not maneuvering *during* it.
- **Armor-aware target selection** replaces the "low-HP retreat" slot in the weighting: Sagittarii
  or Auxilium will weight staying in cover (preserving its own Armor advantage) over pressing
  an attack that would expose it, when a safer shot is available next turn.

## One exception to "no retreat": Proctor

The "never retreats" default has exactly one exception in the roster: the
**[Proctor](../units/proctor/)**. It isn't just retreat-biased in combat utility scoring, it's
built to avoid combat outright — its *value* is in staying alive to do its job, not in winning a
fight. On spotting evidence or a live target, its entire response is to broadcast (see
[`detection-and-network-alert.md`](detection-and-network-alert.md)) and then disengage — pull
back toward its patrol route or the nearest cover, rather than engaging even opportunistically. A
Proctor that fights is a Proctor that's failed at its actual job, which is reporting, not
shooting; giving it combat-capable stats would blur it with the Auxilium's chokepoint role.

## Securus: no retreat, but multiple can share a fight

Securus follows the roster default (no low-HP retreat, holds its engagement) with no exception —
consistent with an "elite" unit that's meant to be committed to, not kited. The one behavioral
difference from the rest of the "no retreat" units is grouping: where Auxilium/Sagittarii are
solo-only, **more than one Securus can be placed in the same encounter**, which the utility model
needs to account for — two Securus units converging on the same flank should coordinate target
selection (not both fixate on the same soldier) the same way the existing model already avoids
alien pile-ons in dense encounters.

## Per-type behavior via exported parameters

Same pattern as `AlienUnit` (GDD Section 11.8) — one `CerberusUnit` base class, per-type
differences expressed as exported parameters rather than separate codebases:
`preferred_engagement_range`, `flanking_bias_weight`, `armor_value`, `holds_position: bool`
(true for Auxilium, false for Sagittarii/Securus), `network_zone_ref`.
Proctor adds `avoids_combat: bool` (true only for Proctor) and `ignores_terrain_move_cost: bool`
(true only for Proctor, false everywhere else); Securus adds `emp_stun_duration_mult` (< 1.0,
vs. 1.0 for the rest of the roster) and `head_hp`.
