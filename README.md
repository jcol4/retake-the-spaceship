# Retake the Spaceship

A turn-based, squad-level tactics game aboard derelict spaceships — XCOM's grid logic and a
*Dead Space* tone, built in Godot 4.

**Presentation: isometric.** Levels are real 3D geometry seen through a fixed orthographic
isometric camera; characters are 2D sprites composited into that world. This is the
Divinity/Fallout approach rather than a pure-2D one, and it is the current direction — the
project began as a fully 3D game with a free-orbit camera and rigged characters rendered at
runtime, and that runtime pipeline has been removed. The rig itself did not go: it is now an
*offline* one that renders sprite sheets, which is a different thing in every way that matters
— nothing about a bone reaches the game, and the camera can be fixed because it no longer has
to be right from every angle. [`docs/presentation-direction.md`](docs/presentation-direction.md)
is the source of truth for how the game is drawn; the sections of the GDD it replaces are
marked SUPERSEDED in place and point at it.

| | |
|---|---|
| Camera | Orthographic, pitch fixed at 35.264°, four snapped yaws (Q/E), no zoom |
| Characters | 8-direction sprites, layered, tinted by tile light — **rendered from a rigged 3D character**, Fallout-style, not hand-drawn |
| Movement | Eight-way at uniform cost, guarded against cutting the corner where two walls meet |
| Levels | 3D geometry built at runtime from ASCII decks in [`maps/`](maps/) |
| Turn order | One shared initiative pool — friend and foe drawn from the same weighted bag |
| Signature systems | Continuous light/sound detection; edge-based XCOM cover; VATS-style Aimed Shot |

## What is in the game today

- **Contractors** — the player squad. Four classes, five weapons chosen on a pre-mission
  loadout screen, 2 AP per activation, injuries rather than permadeath.
- **Aliens** — the infestation. Light-and-sound detection, local alert propagation, a melee
  swarm and a ranged type.
- **Security robots** — *Cerberus Applied Sciences*, the ship's own lockdown-mode security
  net, and the second faction. Sensor-driven rather than light-driven, alerted zone-wide over
  a network, armored, and destroyed rather than injured. Alpha implementation of all four
  roster models is in and playable; see
  [`docs/design/factions/security-robots/`](docs/design/factions/security-robots/).

The two enemy factions are deliberately different *problems* rather than different stat
blocks: aliens are a lighting puzzle, robots are a positioning-and-EMP puzzle. Killing the
lights is the answer to one and buys nothing against the other.

![The four Cerberus models beside a contractor, at placeholder-art stage](out/cerberus_lineup.png)

## The character art pipeline

Characters are **prerendered 3D**, not hand-drawn. A rigged character is posed per action in
Blender, turned through eight facings under an orthographic camera locked to the game's exact
pitch and yaw, and rendered to flat PNGs that the game composites as `Sprite3D`s. This is what
Fallout and Diablo did, and the fixed camera is what makes it affordable: with exactly one
viewpoint, the key light can be fixed in world space and genuinely relights a character as it
turns — eight renders per pose rather than the sixty-four a rotatable camera would need.

```sh
# 1. Write a .blend containing the camera and light rig and nothing else — the file to animate into.
blender -b -P tools/render_sprites.py -- --setup art_src/merc_render.blend

# 2. Render the animated .blend to assets/sprites/. Actions are matched to poses by name.
blender -b art_src/merc_anim.blend -P tools/render_sprites.py -- --variant merc

# 3. Collect the loose PNGs into one SpriteFrames per layer. Rerun after every render.
SF_VARIANT=merc SF_LAYERS=body,arm godot --headless --path . --script res://tools/build_sprite_frames.gd

# Review: one looping GIF per direction, at the cadence the game will actually play it.
blender -b art_src/merc_anim.blend -P tools/make_sprite_gif.py -- --variant merc --pose run --out out
```

The filename `[layer]_[variant]_[pose]_[dir]_[frame].png` is the whole contract between the two
halves — step 2 writes those names and step 3 is the only thing that reads them.

**Frame count is a free art decision.** `build_sprite_frames.gd` derives each animation's speed
as frames ÷ the duration that pose is supposed to occupy, so a run drawn in 8 frames and one
drawn in 12 both take 0.666 s and both keep their footplants on the footstep cadence. Chunkiness
is set by `--fps` and costs nothing in timing.

**Authored so far:** the merc's `idle` and `run`. Everything else — and every non-contractor —
still runs on `UnitVisual`'s code-generated placeholder, which draws a readable stand-in per
layer, pose and direction so layering, bucketing, mirroring and gear swaps stay exercisable.
Action *timing* is identical either way: without art, actions resolve on `FALLBACK_TIME`.

See [`docs/presentation-direction.md`](docs/presentation-direction.md) §2 for the direction
system, the pivot contract and the framing arithmetic.

## Running it

Godot 4.7. Open the project and press play, or:

```sh
godot --path .                     # play
godot --headless --path . -- --auto  # headless smoke test: a full skirmish, no input
```

### Checks

All but the last run headless. There is no test framework — each is a `--script` tool that
prints PASS/FAIL lines and exits non-zero on failure.

```sh
godot --headless --path . --script res://tools/test_map_roundtrip.gd   # map format, spawns, room graph
godot --headless --path . --script res://tools/test_edge_cover.gd      # cover direction, diagonals, degradation
godot --headless --path . --script res://tools/test_movement.gd        # 8-way adjacency, diagonal cost, corner guard
godot --headless --path . --script res://tools/test_sprite_direction.gd # direction buckets, mirror rule
godot --headless --path . --script res://tools/test_iso_picking.gd     # mouse picking at all four yaws
godot --headless --path . --script res://tools/test_cerberus.gd        # security-robot faction rules
godot --path . --script res://tools/test_room_visibility.gd            # render gating (needs a window)
```

## Documentation

| Doc | What it is |
|---|---|
| [`game-design-document.md`](game-design-document.md) | The full GDD. Source of truth for system *rules*. |
| [`docs/presentation-direction.md`](docs/presentation-direction.md) | Source of truth for how the game is **drawn**. Supersedes the GDD's camera and rendering sections. |
| [`docs/design/`](docs/design/) | The GDD reorganised and expanded **per faction** — who they are, what they field, and why. |
| [`MIGRATION_PLAN.md`](MIGRATION_PLAN.md) | The 3D → isometric migration: what changed, why, and the two phases still outstanding. |
| [`character-art-plan.md`](character-art-plan.md) | Contractor art direction — the modelling and animation brief the rendered sprites are made against. |
| [`weapon-art-plan.md`](weapon-art-plan.md) | Weapon art direction. Still written against the deleted runtime `.glb`; the shape language survives, the Godot-side sections do not. |

## Still outstanding

**Character art.** Two of the twenty poses are rendered. In priority order:

- The remaining eighteen poses for the merc — the four firing poses (`aim_hold`,
  `begin_shoot`, `fire_shoot`, `end_shoot`) first, since combat is what the player looks at
  most.
- The `arm` layer, authored only for `sw`. Until the other seven exist, the rifle arm falls
  back to the `sw` art in every direction (`build_sprite_frames.gd` `_pick`).
- `idle` for `e`, `s` and `w`, and a re-render of `idle` for `n` and `nw` — seven frames of
  those two came out of Blender truncated and were removed.

**Map art**, both gated on geometry that does not exist yet, with standing task lists in
`MIGRATION_PLAN.md`:

- **Authored `.glb` map modules** (Phase 8). Every wall is still a runtime `BoxMesh`.
- **Baked lighting** (Phase 7b), which needs that geometry to exist at bake time.
