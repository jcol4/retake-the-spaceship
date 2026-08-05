# Design Docs

Source of truth for full system rules is [`game-design-document.md`](../../game-design-document.md)
at the repo root. Everything under [`factions/`](factions/) is that document reorganized and
expanded **per faction**, so each side of a fight has one place that describes who they are,
what units they field, and why they were designed that way.

How any of it is *drawn* is a separate question with a separate answer:
[`../presentation-direction.md`](../presentation-direction.md). The game is presented
isometrically — 2D sprite characters over real 3D levels — and that doc supersedes the GDD's
camera and rendering sections. It matters here because it constrains faction art directly: a
unit is read at a fixed 35.264° pitch, in eight direction buckets, at roughly **15%** of
viewport height, usually in the dark. Silhouette and palette carry the whole read.

Those sprites are **prerendered from rigged 3D characters** rather than hand-drawn, so a
faction's visual identity is a modelling brief. The cost that imposes on design is worth
knowing before specifying anything: a full character is twenty poses × eight directions, so
every distinct silhouette is a render pass rather than a texture swap.

## Factions

- [`aliens/`](factions/aliens/) — the current alien infestation roster (Fodder, Agile Hunter,
  Spitter). Content sourced from the GDD, Section 11.
- [`security-robots/`](factions/security-robots/) — the second faction: armored, sensor-driven,
  network-alerted, and immune to the light-based detection lever the aliens are built around.
  Designed to fit the existing systems (initiative pool, light/sound detection, cover/elevation)
  rather than to require new core mechanics. **All four roster models now have an alpha
  implementation in code** — see that folder's
  [`design-choices/alpha-implementation.md`](factions/security-robots/design-choices/alpha-implementation.md)
  for what shipped, what was approximated and what is still on paper. Not yet folded into the
  GDD, which still describes a single enemy faction in Section 11.
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
