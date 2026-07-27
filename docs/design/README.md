# Design Docs

Source of truth for full system rules is [`game-design-document.md`](../../game-design-document.md)
at the repo root. Everything under [`factions/`](factions/) is that document reorganized and
expanded **per faction**, so each side of a fight has one place that describes who they are,
what units they field, and why they were designed that way.

## Factions

- [`aliens/`](factions/aliens/) — the current alien infestation roster (Fodder, Agile Hunter,
  Spitter). Content sourced from the GDD, Section 11.
- [`security-robots/`](factions/security-robots/) — **new faction**, not yet in the GDD or the
  codebase. Designed from scratch in this pass to fit the existing systems (initiative pool,
  light/sound detection, cover/elevation) while giving the player a mechanically distinct kind
  of enemy: armored, sensor-driven, network-alerted, immune to the light-based detection lever
  that aliens are built around.
- [`contractors/`](factions/contractors/) — the player squad. "Contractors" is a documentation
  naming choice (the GDD just calls them "soldiers"); it matches the mercenary/PMC read of the
  reference art in `character-art-plan.md` (no national or corporate insignia, worn tactical
  gear, drop-leg holster, chest rig).

## Folder shape

Each faction folder follows the same layout:

```
<faction>/
  README.md          — identity, tone, role in the game
  units/
    <unit-type>/
      README.md       — stats, behavior, combat role
  design-choices/
    *.md              — the "why" behind faction-wide systems (AI models, detection rules,
                         stat systems, etc.), not just the "what"
```
