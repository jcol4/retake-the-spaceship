# Assault

*Source: GDD Section 4.5 (role), 4.6.5 (stat tendency), `scripts/class_presets.gd` (current code
defaults).*

| Role | Stat tendency |
|---|---|
| Front-line damage, close-range engagement | High Fitness, moderate Reflexes, lower Perception |

## Role

The front-line class — built to be in the fight, take hits, and close distance rather than sit
back. High Fitness gives it both the HP pool (Section 4.6.3: +1 max HP per Fitness point) and the
movement range (+1 tile per 20 Fitness) to actually reach close range and survive being there.

## Current code defaults (`ClassPresets.RANGES`)

| Stat | Range |
|---|---|
| Perception | 30–50 |
| Reflexes | 45–65 |
| Fitness | 60–85 |
| Luck | 30–60 |
| Class base Initiative | 60 |

Notably has the **highest class base Initiative (60)** of the four classes — combined with
moderate Reflexes (which also feeds Initiative, Section 4.1), this makes Assault the class most
likely to act early in the draw pool, fitting a "gets into the fight first" identity.

*(Explicitly marked as placeholder/tunable in the code — see
[`../../design-choices/stat-system.md`](../../design-choices/stat-system.md).)*

## Weapon

Weapon stats (base accuracy, damage, magazine size) are no longer part of the class — they belong
to player-selected gear. See [`../../weapons/`](../../weapons/) for the full roster. Assault's
suggested weapons are the [Assault Rifle](../../weapons/assault-rifle.md) (baseline) and the
[Shotgun](../../weapons/shotgun.md) (aggressive, close-range), both leaning on this class's
Fitness-driven movement range to actually reach effective range.

## Relationship to other systems

- Lower Perception means weaker Aimed Shot/Shoot accuracy contribution (Section 4.6.1) than a
  Sniper — the class is balanced around closing distance to reduce the Distance Penalty
  (Section 6.5) rather than out-aiming targets from range.
- Highest Fitness means the largest Sprint range of any class, letting it reach flanking
  positions (Section 6.2) other classes can't in one activation.
