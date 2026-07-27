# Agile Hunter

*Source: GDD Section 11.5.*

| Speed | Toughness | Grouping | Core Role |
|---|---|---|---|
| Fast | Fragile-moderate | Solo or pairs | Ambush striker |

## Role

Punishes bad positioning and bad lighting decisions. Fast and dangerous if it connects, but
killable once caught out of hiding — it's a threat that rewards player caution around dark tiles
rather than a raw stat check.

## Combat behavior

- **Ambush trigger is a combination condition**: requires *both* sufficient darkness (light value
  below a threshold — exact value TBD, GDD Section 12 open item #6) *and* player proximity within
  a close range (also TBD) before it commits to an ambush attack. Neither condition alone is
  enough.
- **Never swarms** — solo or pairs only, which keeps it distinct from Fodder's group-attrition
  identity.
- **Combat bias:** heavily favors reaching/holding an ambush setup over direct engagement — it
  will maneuver into darkness near the player rather than just charging in.

## Relationship to other systems

- Directly exploits the light/darkness mechanic (GDD Section 5.1) that the player also depends
  on — this is the unit that makes "should I turn my flashlight off" a real tactical question
  (Section 5.2).
- Minor spawn-table presence from a [Nest](../../design-choices/spawn-nests.md) — 10% of nest
  spawns, the rarest of the three.

## Implementation hooks

Per the GDD's `AlienUnit` scaffold (Section 11.8), this type is expected to be tuned via exported
parameters rather than a separate codebase: `prefers_darkness: bool`, `ambush_light_threshold`,
`ambush_proximity_range`.

## Open items

- Exact ambush light threshold and proximity range (GDD Section 12, item 6).
