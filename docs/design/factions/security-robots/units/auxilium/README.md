# Auxilium (QRN-4)

*New unit, designed to be this faction's Fodder-equivalent: the common, entry-level threat —
but the design is inverted rather than copied, since "tanky and slow, swarms" would just be
Fodder with an armor coat of paint.*

| Speed | Toughness | Grouping | Core Role |
|---|---|---|---|
| Stationary / slow patrol | Moderate, armored | Solo per post | Overwatch anchor |

## Role

Where Fodder is a *swarm* attrition unit, Auxilium is a **solo choke-point** unit — it
holds a fixed post (a doorway, a junction, a checkpoint) and punishes the player for moving
through its sightline without a plan. It's the most common Cerberus unit by design, the way
Fodder is the most common alien, but "common and dangerous alone" instead of "common and
dangerous in numbers."

## Combat behavior

- **Defaults to Overwatch-like behavior** at its post — mechanically this can reuse the existing
  Overwatch action (GDD Section 4.2) rather than needing new interrupt logic: an Auxilium
  holding position and reserving its action to fire when a unit enters its sightline is exactly
  what Overwatch already models.
- **Low mobility** — its `preferred_engagement_range` favors staying at its post over chasing; it
  will reposition only a tile or two to maintain a sightline, not pursue across a room.
- **Moderate Armor** (see
  [`../../design-choices/armor-and-destruction.md`](../../design-choices/armor-and-destruction.md))
  — enough that a single snap-shot (Shoot, 1 AP) rarely drops one outright, encouraging either a
  Aimed Shot (2 AP) or a flank to bypass its cover.

## Relationship to other systems

- Because it doesn't chase, an Auxilium is the unit most likely to be **left alive but
  bypassed** — a legitimate player choice against this faction that has no real alien equivalent
  (aliens will eventually path toward noise/light within their room). This is intentional: it
  makes stealth/routing decisions matter against robots in a way they don't against aliens.
- First to broadcast a **network alert** (see
  [`../../design-choices/detection-and-network-alert.md`](../../design-choices/detection-and-network-alert.md))
  if it detects the player and isn't dealt with quickly — the "trip an Auxilium, alert the zone"
  loop is the faction's core early-warning threat.

## Open items

- Exact HP/Armor numbers deferred to playtesting, consistent with the rest of the roster.
- Whether an Auxilium can be silently disabled (melee takedown, hacking) before it alerts —
  not currently proposed, but a natural extension if a future stealth-focused mission type is
  added.
