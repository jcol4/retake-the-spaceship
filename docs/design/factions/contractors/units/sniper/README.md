# Sniper

*Source: GDD Section 4.5 (role), 4.6.5 (stat tendency), `scripts/class_presets.gd` (current code
defaults).*

| Role | Stat tendency |
|---|---|
| Long-range precision, positioning-dependent | High Perception, lower Fitness, moderate Reflexes |

## Role

The long-range specialist — high Perception drives both halves of what makes a sniper work: the
accuracy contribution to Shoot/Aimed Shot (Section 4.6.1) and the largest maximum vision/detection
range in the squad (also governed by Perception). Positioning-dependent because low Fitness means
short movement range and low HP, so the class rewards finding a strong position and holding it
rather than repositioning turn to turn.

## Current code defaults (`ClassPresets.RANGES`)

| Stat | Range |
|---|---|
| Perception | 65–90 |
| Reflexes | 45–65 |
| Fitness | 30–50 |
| Luck | 30–60 |
| Class base Initiative | 45 |

*(Explicitly marked as placeholder/tunable in the code — see
[`../../design-choices/stat-system.md`](../../design-choices/stat-system.md).)*

## Weapon

Weapon stats (base accuracy, damage, magazine size) are no longer part of the class — they belong
to player-selected gear. See [`../../weapons/`](../../weapons/) for the full roster. Sniper's
suggested weapon is the [Battle Rifle](../../weapons/battle-rifle.md) — its high accuracy compounds
with the class's high Perception (the accuracy contributor to every ranged action, Section 4.6.2),
and its small magazine reinforces the class's positioning-dependent, not-spray-and-pray identity.

## Relationship to other systems

- **Lowest class base Initiative (45)** of the four — combined with only moderate Reflexes, a
  Sniper tends to act later in the draw pool (Section 4.1) than an Assault, which fits "get into
  position, then take the shot" rather than "act first."
- Perception's maximum vision/detection range (Section 4.6.1) makes a Sniper the best class for
  spotting units at range for the squad's shared vision (Section 10.6 — any unit spotting an
  enemy reveals it to the whole squad), even before it takes a shot.
