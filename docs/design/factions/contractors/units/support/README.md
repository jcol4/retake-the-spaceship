# Support

*Source: GDD Section 4.5 (role), 4.6.5 (stat tendency), `scripts/class_presets.gd` (current code
defaults).*

| Role | Stat tendency |
|---|---|
| Healing/buffs, Initiative manipulation | Balanced across all four, slight Luck skew |

## Role

The squad's force-multiplier class — rather than leaning hard into one stat like the other three
classes, Support stays balanced and instead brings *abilities* (healing/buffs, Initiative
manipulation, GDD Section 4.1's "Modifiability" clause) as its specialization. The slight Luck
skew fits a support archetype: more consistent rerolls/crit resistance for itself and, per the
ability design implied by the GDD, likely extends some of that benefit to allies.

## Current code defaults (`ClassPresets.RANGES`)

| Stat | Range |
|---|---|
| Perception | 45–65 |
| Reflexes | 45–65 |
| Fitness | 45–65 |
| Luck | 45–75 |
| Class base Initiative | 50 |
| Weapon base accuracy | 30 |
| Weapon damage | 10 |
| Magazine size | 8 |

Every combat stat sits at the midpoint of the roster's range — the only class with no stat below
45 — while **Luck's range (45–75) is shifted meaningfully higher** than any other class's Luck
range, the one deliberate skew. **Largest magazine (8)** and **lowest weapon damage (10)** reads
as a suppression/utility weapon rather than a primary damage dealer.

*(Explicitly marked as placeholder/tunable in the code — see
[`../../design-choices/stat-system.md`](../../design-choices/stat-system.md).)*

## Relationship to other systems

- Initiative manipulation (implied ability set, Section 4.1's "Modifiability") makes Support the
  class most directly interacting with the game's signature mechanic — buffing an ally's draw
  odds or debuffing an enemy's is a lever no other class has natively.
- The Luck skew compounds with all three of Luck's phases (Section 4.6.4: reroll, crit, dodge) —
  a Support unit is both slightly more likely to turn its own misses into hits and slightly more
  likely to shrug off incoming non-crit hits.
