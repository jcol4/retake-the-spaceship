# Faction: Contractors

*Source: `game-design-document.md` Sections 4.5/4.6 (classes, stats) and 7 (mission/meta
structure), plus `character-art-plan.md` for visual direction. "Contractors" is a documentation
naming choice — the GDD itself just says "soldiers"; the name is chosen here because it matches
the mercenary/PMC read of the reference art (no national or corporate insignia, worn gear, drop-leg
holster) rather than a standing military force.*

## Identity

A small squad (2–4 units per mission, Section 2) of hired operators sent aboard derelict ships to
clear them out — no narrative specifics beyond that are defined yet (Section 8: "no narrative
focus for now"). The tone is gritty and functional rather than heroic-military: worn tactical
gear, mismatched wear patterns, no unit insignia (see
[`design-choices/art-direction.md`](design-choices/art-direction.md)).

## Mechanical identity

- **No permadeath.** Downed soldiers are injured, not killed — recoverable with a medical
  resource between/during missions (GDD Section 4.4). This is the faction-defining design
  pillar: "forgiving, not punishing" (Section 2).
- **Visible Initiative.** Unlike both alien factions, the player can see their own units'
  Initiative values in the shared pool (Section 4.1) — full information on your own side, none on
  the enemy's.
- **Flashlight-equipped**, unlike either enemy faction — every contractor carries a flashlight as
  a free-action toggle (Section 5.2), the primary tool/liability tradeoff the whole lighting
  system (Section 5) is built around.
- **Fixed class roles**, each with a distinct stat tendency and role, rather than a flexible
  build system (Section 4.6.5) — small squad, high specialization (Section 2).

## Roster

| Class | Suggested Role | Stat tendency |
|---|---|---|
| [Assault](units/assault/) | Front-line damage, close-range engagement | High Fitness, moderate Reflexes, lower Perception |
| [Sniper](units/sniper/) | Long-range precision, positioning-dependent | High Perception, lower Fitness, moderate Reflexes |
| [Support](units/support/) | Healing/buffs, Initiative manipulation | Balanced, slight Luck skew |
| [Heavy Weapons](units/heavy-weapons/) | High damage, slow, area-effect | High Fitness, lower Reflexes, moderate Perception |

## Weapons

- [`weapons/`](weapons/) — the five player-selectable weapons (Assault Rifle, Shotgun, SMG, LMG,
  Battle Rifle) and their stats. Weapon choice is independent of class: each class has a suggested
  default that fits its role, but any soldier can carry any weapon.

## Design choices

- [`design-choices/stat-system.md`](design-choices/stat-system.md) — the four-stat percentile
  system and how each stat resolves.
- [`design-choices/initiative-pool.md`](design-choices/initiative-pool.md) — how contractors
  participate in the shared draw pool, and why their Initiative is visible.
- [`design-choices/action-economy.md`](design-choices/action-economy.md) — the 2 AP action table
  and ammo/reload tradeoffs.
- [`design-choices/injury-and-recovery.md`](design-choices/injury-and-recovery.md) — the
  no-permadeath model and its open economy questions.
- [`design-choices/art-direction.md`](design-choices/art-direction.md) — visual identity, from
  `character-art-plan.md`.

## Open items (from GDD Section 12)

- Exact per-class stat numeric ranges — tendencies are set (and partially rolled out as code
  defaults in `scripts/class_presets.gd`), but not fully finalized/playtested.
- Medical resource economy — name, and how it's earned/spent.
- ~~Weapon base accuracy values per weapon type~~ — resolved and implemented, see
  [`weapons/`](weapons/).
