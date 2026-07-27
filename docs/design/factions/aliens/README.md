# Faction: Aliens

*Source: `game-design-document.md`, Section 11 ("AI & Enemy Design").*

## Identity

An infestation aboard the derelict ship — the default hostile faction for the current mission
archetype (clear-out). No named species/lore yet; the design is purely mechanical (see Section 8,
"no narrative focus for now"). Tone comes from the *Dead Space*-inspired setting: dark corridors,
failing power, things that come out of the dark.

## Mechanical identity

- **Same detection rules as the player** — light and sound (GDD Section 5). No special alien
  senses. This is a deliberate symmetry: darkness is a tool aliens use against the player and
  vice versa, not an asymmetric "aliens see in the dark" cheat.
- **No flashlights** (`has_flashlight = false` on `EnemyUnit`, see `scripts/enemy_unit.gd`) —
  aliens rely on their own senses rather than a rig-mounted light, which reinforces the Agile
  Hunter's darkness-dependent ambush design (see [`units/agile-hunter/`](units/agile-hunter/)).
- **Local alert propagation**, scoped to a room/nest cluster via the level's room-graph, not
  ship-wide. Isolating rooms via doors is an intentional, viable player strategy against this
  faction. (Contrast with [`security-robots`](../security-robots/), which propagates alerts
  ship/zone-wide over a network — see that faction's
  [`design-choices/detection-and-network-alert.md`](../security-robots/design-choices/detection-and-network-alert.md)
  for the deliberate asymmetry.)
- **Hidden Initiative.** Like all units the aliens participate in the shared initiative pool
  (Section 4.1), but the player never sees an alien's Initiative value, tier, or icon.
- **Full pool participants.** State machine decides *what* an alien does when drawn, not
  *whether* it's drawn — no separate "enemy turn."

## Roster (v1)

| Type | Speed | Toughness | Grouping | Core Role |
|---|---|---|---|---|
| [Fodder](units/fodder/) | Slow | Tanky | Swarms | Attrition |
| [Agile Hunter](units/agile-hunter/) | Fast | Fragile-moderate | Solo/pairs | Ambush striker |
| [Spitter](units/spitter/) | Slow-moderate | Fragile | Solo, or screens Fodder | Ranged pressure |

## Design choices

- [`design-choices/ai-state-machine.md`](design-choices/ai-state-machine.md) — the four-state
  layered state machine and utility scoring.
- [`design-choices/detection-and-alert.md`](design-choices/detection-and-alert.md) — light/sound
  detection reuse and local alert propagation.
- [`design-choices/spawn-nests.md`](design-choices/spawn-nests.md) — the Nest objective and spawn
  table.

## Open items (from GDD Section 12)

- Spitter's exact range, damage falloff, and minimum effective range.
- Exact ambush thresholds (light value cutoff, proximity range) for the Agile Hunter.
