# Docs

- [`presentation-direction.md`](presentation-direction.md) — **how the game is drawn**, and the
  source of truth for it: a fixed orthographic isometric camera over real 3D levels, with 2D
  sprite characters composited into them. Those sprites are **prerendered from a rigged 3D
  character** rather than hand-drawn — §2.1 is the pipeline, §2.2 the pose vocabulary, §2.4
  what is actually rendered so far. Supersedes `game-design-document.md` §3's Perspective
  bullet, §10.2 (camera) and §10.6 (render gating) — all three are marked SUPERSEDED in place
  and point here.
- [`design/`](design/) — game design documentation, organized by faction and topic.

Source-of-truth top-level docs (not moved, still live at repo root):

| Doc | What it is |
|---|---|
| `README.md` | Project overview: the direction, what is implemented, how to run it and how to check it. |
| `game-design-document.md` | The full GDD — system *rules*. Where it describes presentation, see above. |
| `MIGRATION_PLAN.md` | The 3D → isometric migration: decision log, what was done, and the two phases still outstanding. |
| `character-art-plan.md` | Contractor art direction — the modelling and animation brief the rendered sprites are made against. Mostly live again: the sprites come off a 3D model, so a model plan describes something real. |
| `weapon-art-plan.md` | Weapon art direction. Its shape language survives; its Godot-side sections targeted a runtime `.glb` that no longer exists. |
