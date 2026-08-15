# Stat System

*Source: GDD Section 4.6, current implementation in `scripts/unit_stats.gd` and
`scripts/class_presets.gd`.*

## Four stats, percentile scale

A SPECIAL-inspired system, deliberately trimmed to four stats (no Charisma — no dialogue/social
system exists) and using **percentile values (0–99)** in the style of the original *X-COM*.

| Stat | Major role | Minor roles |
|---|---|---|
| Perception | Ranged accuracy for Shoot, Aimed Shot and Overwatch | max vision/detection range |
| Reflexes | **AP cost discount** on Shoot/Melee/Grenade/Reload/Aimed Shot | Initiative; accuracy for Shoot and Overwatch only |
| Fitness | **AP pool size** | Max HP |
| Luck | Crit chance/severity; reroll/dodge chances | — |

> Reflexes' and Fitness' major roles changed on 2026-08-10 — see
> [`ap-and-stat-baselines.md`](ap-and-stat-baselines.md). Both were previously the reverse of what
> this table now says: Fitness *was* Max HP and the movement allowance, and Reflexes was 60% of
> Initiative. The point of the split is that each stat now owns exactly one major lever, so no two
> compete to be the one that matters.

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
ap_pool     = floor(6 + 0.075 * fitness)
action_cost = max(1, ceil(base_cost - k_reflexes * reflexes))
max_hp      = floor(base_hp   + 0.08 * fitness + level_bonus_hp)     # base_hp   15 for a soldier
initiative  = floor(base_init + 0.2 * reflexes + equipment_initiative + level_bonus_init)
```

Movement is not in this list any more: it costs a flat 1 AP per tile for every unit regardless of
stats. The level bonus terms are named and currently **zero** — the leveling system is not designed
yet, and the placeholder exists so the formula shape is right when it is.

These supersede GDD Sections 4.6.3 and 4.1; the code remains the source of truth for the tunable
constants, and [`ap-and-stat-baselines.md`](ap-and-stat-baselines.md) is where the reasoning and the
per-action cost table live.

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
