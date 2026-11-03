# Fodder

*Source: GDD Section 11.4.*

| Speed | Toughness | Grouping | Core Role |
|---|---|---|---|
| Slow | Tanky | Swarms (groups) | Attrition |

## Role

Threat is **attrition**, not raw damage — Fodder exists to drain the player's AP, ammo, and turns
on numbers rather than posing serious per-hit risk. It's the "cheap enemy" of the roster: tanky
enough that killing one costs a real action, weak enough per-hit that no single Fodder threatens
a soldier alone.

## Combat behavior

- **Combat bias:** direct approach toward the nearest player unit.
- **Low priority on flanking/repositioning** — Fodder doesn't play the utility-scoring game
  (Section 11.1) as aggressively as the other two types; it mostly just closes distance and
  attacks.

## Horde rework (decided 2026-11-02)

For now **every alien is Fodder**, and Fodder comes as hordes. Toggle: `AlienPresets.FODDER_ONLY`
(the other types' code and map glyphs are untouched; flip it off to get them back).

| Decision | Value | Why |
|---|---|---|
| Model / anims | `civilian.glb` (exported from `civilian_cleaned.blend`) | Placeholder body until alien art exists |
| Group size | 5–8, one horde per compartment holding any alien marker | Reads as a horde in a room, still countable |
| Deck density | ~35% of non-safe rooms (generator) | Fewer, bigger encounters with breathing room between |
| Regular | 6–8 HP (1–2 rifle hits), 3-dmg claw | Attrition is the *count*; each kill is ground gained |
| Brute | 1 per horde, 18–22 HP, 5-dmg claw, 1.2x scale | The body to plan around and kill first |
| Pace | Unchanged: 6 AP pool vs 5 AP claw — close OR swing | Keeps the one-turn warning (test_swarm_pace) |
| Initiative | Last tier: drawn only after every other unit has acted | Shambling; the player always moves first |
| Horde turn | One draw moves the whole horde: all walk at once (each up to 0.3 s behind the first), then claws land one after another | A surge, not a queue; blows stay readable |
| Pack pathing | Decided nearest-the-prey first; a body blocked only by mates walks up behind them and waits, and is retried once they've moved | Otherwise bodies inside the huddle (or behind a doorway) lose their turn and lag a round behind |
| Dormant | Huddled; the first to enter combat takes its whole horde in on the same target | A pack that trickles in isn't a horde |
| Surround | No cap on attackers per target | Being surrounded *is* the threat; answer is positioning, chokepoints, doors |
| Nests | Burst of 2–3 Fodder every 3 rounds | Horde feel, more urgency to kill nests |
| Variety | ±5% scale, random start point in looping clips | Breaks up lockstep without new assets |

## Relationship to other systems

- **Spawn table:** the most common spawn from a [Nest](../../design-choices/spawn-nests.md) —
  70% of nest spawns are Fodder.
- Often paired with a [Spitter](../spitter/) trailing behind as ranged support/screen.

## Open items

- Exact HP/damage numbers not yet specified in the GDD — only relative toughness/speed tendencies
  are defined. Numeric tuning is deferred to playtesting, consistent with the rest of the combat
  balance (Section 12).
