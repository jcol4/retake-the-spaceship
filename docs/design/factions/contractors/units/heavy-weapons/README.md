# Heavy Weapons

*Source: GDD Section 4.5 (role), 4.6.5 (stat tendency), `scripts/class_presets.gd` (current code
defaults).*

| Role | Stat tendency |
|---|---|
| High damage, slow, area-effect | High Fitness, lower Reflexes, moderate Perception |

## Role

The squad's heavy hitter — high damage and, per the design intent, area-effect capability
(exact ability not yet specified beyond the tendency table). High Fitness gives it a large HP
pool to survive being a priority target, but low Reflexes makes it slow to act in the initiative
pool and weak on Shoot's accuracy contribution specifically (Section 4.6.2 — Reflexes affects
Shoot only, not Aimed Shot), pushing the class toward Aimed Shot (2 AP, Perception-only)
over snap-shooting.

## Current code defaults (`ClassPresets.RANGES`)

| Stat | Range |
|---|---|
| Perception | 40–60 |
| Reflexes | 25–45 |
| Fitness | 65–90 |
| Luck | 30–60 |
| Class base Initiative | 40 |

**Lowest class base Initiative (40)** of the four classes — the tradeoff for high Fitness
(highest range, 65–90, tied for the roster's top) and high damage.

*(Explicitly marked as placeholder/tunable in the code — see
[`../../design-choices/stat-system.md`](../../design-choices/stat-system.md).)*

## Weapon

Weapon stats (base accuracy, damage, magazine size) are no longer part of the class — they belong
to player-selected gear. See [`../../weapons/`](../../weapons/) for the full roster. Heavy
Weapons' suggested weapon is the [LMG](../../weapons/lmg.md) — its large magazine supports
sustained fire without constant reloading, and its low base accuracy pushes toward Aimed Shot,
matching this class's already-established Reflexes-driven lean away from Shoot.

## Relationship to other systems

- Bonus damage vs. cover objects (GDD Section 6.1.1's "cover-breaker weapons" clause names Heavy
  Weapons-class attacks specifically) gives this class a unique job against the battlefield
  itself, not just against units — it's the class best suited to opening up a dug-in enemy
  position rather than out-shooting it.
- Also the class most likely to matter against [Sagittarii](../../../security-robots/units/sagittarii/)
  and other high-Armor Cerberus units, per that faction's armor-and-destruction design.
