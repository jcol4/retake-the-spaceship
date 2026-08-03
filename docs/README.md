# Docs

- [`presentation-direction.md`](presentation-direction.md) — **how the game is drawn**, and the
  source of truth for it: a fixed orthographic isometric camera over real 3D levels, with 2D
  sprite characters composited into them. Supersedes `game-design-document.md` §3's Perspective
  bullet, §10.2 (camera) and §10.6 (render gating) — all three are marked SUPERSEDED in place
  and point here.
- [`design/`](design/) — game design documentation, organized by faction and topic.

Source-of-truth top-level docs (not moved, still live at repo root):

| Doc | What it is |
|---|---|
| `README.md` | Project overview: the direction, what is implemented, how to run it and how to check it. |
| `game-design-document.md` | The full GDD — system *rules*. Where it describes presentation, see above. |
| `MIGRATION_PLAN.md` | The 3D → isometric migration: decision log, what was done, and the two phases still outstanding. |
| `character-art-plan.md` | Contractor art direction. Written against the 3D model: its palette and silhouette half still governs the sprites, its mesh-generation phases do not. |
| `weapon-art-plan.md` | Weapon art direction, same caveat. |
