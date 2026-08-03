# Detection & Network Alert

> ⚙️ **Implemented 2026-07-31**, with one approximation: a **zone is currently one compartment
> plus its doorways**, not the cluster of rooms this document asks for — the derived room graph
> cannot express anything between "one room" and "the whole deck". Reasoning, and the authored-
> zone escape hatch that closes it without code, are in
> [`alpha-implementation.md`](alpha-implementation.md) §3. Everything else below — the light
> exception, motion, sound, evidence scanning, the priority call-in, no-new-spawns — is in.

This is the faction's central mechanical bet: aliens use the player's own light/sound system
against them; Cerberus units are built to **ignore the light half of it entirely**, so the player
has to fight a genuinely different problem, not a reskinned one.

## Sensor-based detection, not light-based

- **Light value has no effect on Cerberus detection or accuracy**, in either direction. A tile at
  0% light and a tile at 100% light are identical to a robot's sensors. This is a flat
  **exception** to GDD Section 5.1's light modifier — for `Unit vs CerberusUnit` accuracy rolls,
  the Light Modifier term in the Section 6.5 formula is always treated as `0` (neutral) rather
  than being computed from the target's `light_value`.
- Detection instead runs on **motion + sound only**:
  - **Motion:** a robot on active patrol or standing post has a fixed detection cone/radius
    (same raycast-based LOS as GDD Section 10.6 — occluded by walls/closed doors identically) but
    the cone is evaluated against *movement*, not lit-vs-dark appearance. A stationary, unmoving
    player unit is harder to detect at range than one that just sprinted through the same tile,
    independent of lighting.
  - **Sound:** identical to GDD Section 5.4 — gunfire, sprinting, explosions register on the same
    5-tile alert radius. Sound is the one detection channel the two factions still share, which
    keeps "stay quiet" a universally useful player strategy rather than something that only works
    against one faction.

**Why:** if robots also cared about light, they'd just be "aliens with different stats," and the
flashlight-toggle decision (GDD Section 5.2) would remain the single dominant lever in every
fight. Removing light from the equation for one faction means a mission that mixes both factions
forces a real tradeoff: staying dark helps against aliens/keeps the player less visible generally,
but does *nothing* to stop a robot's sensors, so the player can't rely on one blanket tactic
("just turn the lights off") to solve the whole level.

## A third channel: evidence scanning ([Proctor](../units/proctor/) only)

Motion and sound both require the robot to sense the player (or an alien) *while an event is
happening*. [Proctor](../units/proctor/) adds a channel that doesn't: it can flag a zone as
compromised purely from **environmental state left behind** — a breached door, alien residue, a
corpse, spent brass, cover that's taken damage. This is deliberately not available to any other
Cerberus unit; the rest of the roster still detects the same way described above.

- Mechanically, this is a periodic scan (once per Proctor activation, or once per patrol
  waypoint) that checks tiles within a radius for a small set of **evidence flags** set by other
  gameplay systems when they occur (a destroyed cover object, an alien death, a fired weapon's
  brass/scorch decal, a body). It does not require LOS to the player or alien the way motion/sound
  detection does — the evidence can be found well after whatever produced it happened, and well
  after the responsible unit has moved on.
- **Why give one unit a delayed, indirect detection channel:** every other detection channel in
  the game (player and both factions) is tied to *what's happening right now*. Evidence scanning
  is the one thing that punishes a player for leaving a mess after the fact rather than for being
  caught in the act — it's the mechanical payoff for "clean up after yourself" as a real
  strategy, which nothing else in the current design rewards.
- Proctor itself does not need to see the player to flag a zone this way, which is also why it's
  restricted to a single, fragile, non-combat-focused unit — see
  [`../units/proctor/`](../units/proctor/) — rather than being folded into the shared Cerberus
  detection model, which would make every robot in a zone able to "smell" a fight it wasn't
  present for.

## Alert propagation is ship/zone-wide, not room-local

Where an alerted alien only propagates to its local room/nest cluster (GDD Section 11.2), an
alerted Cerberus unit broadcasts over the **security network**, and every other Cerberus unit
registered to that network **zone** goes to Alert/Investigating immediately — including units the
player hasn't encountered yet and can't see.

- **Zone, not whole-ship:** reuses the same room-graph structure from GDD Section 10.4 that
  scopes alien alert propagation, but at a coarser grain — a "zone" is a cluster of rooms (e.g.
  everything behind one checkpoint), not a single room. This keeps the ship-wide framing from the
  faction's lore honest without making a single triggered robot alert literally the entire level
  at once, which would be closer to punishing than tense (mirrors the reasoning in
  [`../../aliens/design-choices/detection-and-alert.md`](../../aliens/design-choices/detection-and-alert.md)
  against a fully global alert).
- **Doors still matter, differently than against aliens:** closing a door blocks the LOS/sound
  that would *trigger* an alert in the first place (same rule as aliens, Section 10.5), but once
  a robot in a zone *is* alerted, closing a door won't un-alert the rest of its zone the way it
  can cut an alien pack off from reinforcements — the network alert has already gone out. This is
  the intended asymmetry: **against aliens, doors are a way to de-escalate a fight already in
  progress; against robots, doors only matter *before* the first alert.**
- **No new spawns.** Unlike a Nest (GDD Section 11.7), an alerted zone doesn't manufacture new
  units — it converges whatever Cerberus units already exist in that zone onto the alert
  location. This keeps the faction from stacking an economy problem (ammo attrition) on top of a
  positioning problem; the robot faction's pressure is entirely about being caught by multiple
  units at once, not about attrition over time. **[Proctor](../units/proctor/)'s call-in follows
  this same rule** — when it flags evidence or a spotted target, it isn't spawning a fresh
  [Securus](../units/securus/) or other unit into the level; it's issuing a priority, targeted
  version of the standard zone broadcast that specifically routes already-placed heavy units
  (Securus foremost) toward its location faster than the generic alert would. The distinction
  matters for level authoring: a zone with no Securus placed in it has nothing for a Proctor to
  call in, regardless of how loudly it's screaming.

## Implementation sketch

- `CerberusUnit` base class (parallel to `AlienUnit`), `has_flashlight = false` like aliens, but
  with its own `_compute_accuracy_light_term()` override that returns `0` regardless of
  `GridTileData.light_value`.
- A `SecurityZone` resource/grouping, assigned at level-authoring time (same authoring pass that
  places set-piece rooms, GDD Section 10.4), that all `CerberusUnit`s in that area register to.
  On alert, broadcast to every registered unit in the same `SecurityZone`, mirroring the existing
  alert-propagation signal pattern used for alien nest clusters (Section 11.8).
