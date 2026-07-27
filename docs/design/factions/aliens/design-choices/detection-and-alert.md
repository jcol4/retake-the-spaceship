# Detection & Alert Propagation

*Source: GDD Section 11.2, cross-referenced with Section 5 (Line of Sight, Lighting & Detection)
and Section 10.4 (Procedural Generation / room graph).*

## No special alien senses

Aliens use the **same light- and sound-based detection rules as the player** (GDD Section 5).
There is no alien-specific "sees in the dark" or "always knows where you are" mechanic. This is
a deliberate symmetry decision: the game's core tension pillar is "light is a weapon and a
liability" (Section 2), and that pillar only holds up if darkness is genuinely double-edged —
useful to the player *and* to what's hunting them — rather than a one-sided player tool.

The one asymmetry that does exist is equipment, not senses: aliens carry no flashlight
(`has_flashlight = false`), so they never generate their own light source the way a player
soldier does. They still see, hear, and are seen using the same rules.

## Alert propagation is local

Propagation is scoped to the same room/nest cluster, via the room-graph structure built during
procedural generation (Section 10.4) — **not** ship-wide.

**Why local:** it makes "isolating rooms via doors" a legitimate, intentional player strategy
(closed doors block both LOS and sound propagation per Section 5.4/10.5). If alert state were
global, closing a door behind you would be cosmetic rather than tactical. Keeping it local also
avoids a common tactics-genre failure mode where one mistake alerts an entire level at once,
which would make the initiative pool's per-turn uncertainty (Section 4.1) feel punishing rather
than tense.

**Contrast with `security-robots`:** the new security-robot faction deliberately does the
opposite — alerts propagate over a ship-wide security network within a zone, not room-by-room.
See
[`../security-robots/design-choices/detection-and-network-alert.md`](../../security-robots/design-choices/detection-and-network-alert.md)
for why that asymmetry exists and what it's meant to teach the player about telling the two
factions apart.

## Implementation

An alerted alien signals its current room node; propagation reaches only `AlienUnit`s registered
to that node or its associated nest cluster (GDD Section 11.8).
