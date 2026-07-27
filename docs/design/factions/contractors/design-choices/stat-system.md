# Stat System

*Source: GDD Section 4.6, current implementation in `scripts/unit_stats.gd` and
`scripts/class_presets.gd`.*

## Four stats, percentile scale

A SPECIAL-inspired system, deliberately trimmed to four stats (no Charisma — no dialogue/social
system exists) and using **percentile values (0–99)** in the style of the original *X-COM*.

| Stat | Governs |
|---|---|
| Perception | Ranged accuracy contribution to Shoot, Aimed Shot, and Overwatch; max vision/detection range |
| Reflexes | Ranged accuracy contribution to Shoot and Overwatch only; contributes to Initiative |
| Fitness | Max HP; movement range (Run/Sprint) |
| Luck | Crit chance/severity; reroll/dodge chances |

## Why Perception and Reflexes are split the way they are

Perception governs *every* ranged action, while Reflexes governs *Shoot and Overwatch only* — this
asymmetry is what gives the Sniper/Assault stat tendencies real mechanical daylight between them
rather than just being reskinned damage-dealers. A high-Perception, low-Reflexes unit (Sniper) is
disproportionately better at Aimed Shot than Shoot, which nudges it toward the "aim carefully,
don't snap-shoot" playstyle its role implies. A high-Reflexes unit gets relatively more value out
of cheaper Shoot (and reactive Overwatch) actions, since it isn't paying the Reflexes-shaped hole
in its Aimed Shot accuracy.

## Formulas (from `unit_stats.gd`)

```
max_hp = fitness
move_run = 4 + fitness / 20
move_sprint = move_run * 2
initiative = reflexes * 0.6 + class_base_initiative * 0.3 + equipment_initiative * 0.1
```

These match GDD Sections 4.6.3 and 4.1 exactly — the code is the current source of truth for the
tunable constants (0.6/0.3/0.1 weighting, +1 HP/Fitness, +1 tile/20 Fitness).

## Class-based rolling, not free allocation

Stats are **class-based and rolled within a range** (Section 4.6.5) — each class has a tendency,
and individual soldiers of the same class vary within it, rather than the player freely
allocating points. This keeps squad composition meaningfully different between classes (small
squad, high specialization — Section 2) while still giving two Assaults in the same squad
individual identity.

`ClassPresets.RANGES` in `scripts/class_presets.gd` holds the current numeric ranges per class —
see each class's own doc under [`../units/`](../units/) for its specific numbers. The code
comment on that file explicitly flags these as **placeholder guesses pending playtesting**, matching
GDD Section 12 item 2 (exact per-class ranges are still an open item).
