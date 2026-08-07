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

**Which way a character faces is set by one constant,** `render_sprites.py`
`BUCKET_ZERO_DEGREES`, and it is the sharpest edge in this pipeline. A wrong value is
*invisible in the art* — eight facings are self-consistent at any base, so the contact sheet
looks right and only a unit walking east while its sprite runs north-east gives it away. It
cannot be derived from the axis convention (this rig is posed facing screen-SE) and must never
be read from the `.blend`. Re-aiming the set is a rename, not a re-render. See
[`docs/presentation-direction.md`](docs/presentation-direction.md) §2.1.

**Authored so far:** five of the merc's twenty poses, at all eight directions — `idle`, `run`,
and the three shooting poses `begin_shoot`, `fire_shoot` and `end_shoot` — plus six cover
variants: `idle`, `begin_shoot` and `end_shoot` in both `_low` and `_high`. Only the `body`
layer; the `arm` layer is still `sw` alone. Everything else — and every non-contractor —
still runs on `UnitVisual`'s code-generated placeholder, which draws a readable stand-in per
layer, pose and direction so layering, bucketing, mirroring and gear swaps stay exercisable.
Action *timing* is identical either way: without art, actions resolve on `FALLBACK_TIME`.

A `SpriteFrames` always contains all 160 animations (20 poses × 8 directions) whether or not
the art exists, because `build_sprite_frames.gd` falls back to the nearest pose that *does*
exist. So the presence of `aim_hold_ne` in `body_merc.tres` is not evidence `aim_hold` was
rendered — the loose PNGs under [`assets/sprites/`](assets/sprites/) are.

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
| [`MIGRATION_PLAN_3D_8DIR.md`](MIGRATION_PLAN_3D_8DIR.md) | A proposed reversal of that migration, **overtaken by events** — kept because it is the record of how eight-way movement arrived without the runtime 3D pipeline coming back with it. |
| [`character-art-plan.md`](character-art-plan.md) | Contractor art direction — the modelling and animation brief the rendered sprites are made against. |
| [`weapon-art-plan.md`](weapon-art-plan.md) | Weapon art direction. The shape language and the Blender-side tooling are live, since weapons are modelled and rendered with the character; its Godot-side sections describe the deleted runtime `.glb` and do not. Its banner still says the whole thing is dead, which is a correction behind `character-art-plan.md`'s. |

## Still outstanding

**Character art.** Five of the twenty poses are rendered, plus six cover variants. In priority
order:

- `hit_react` — currently the only pose in the vocabulary the game deliberately *declines* to
  play. `Unit.take_damage` settles into the appropriate idle instead, because playing it would
  resolve to a stand-in that reads as nothing happening while still costing the beat
  `FALLBACK_TIME` charges for. Restoring it is one line; draw `hit_react_low` alongside it, or
  a soldier will stand up out of cover to flinch.
- `aim_hold` — the last of the four firing poses, and the one held longest on screen, since a
  unit sits in it for the whole of an Aimed Shot.
- The `arm` layer, authored only for `sw`. Until the other seven exist, the rifle arm falls
  back to the `sw` art in every direction (`build_sprite_frames.gd` `_pick`).
- The other fourteen body poses — `walk`, `crouch_idle`, `overwatch_hold`, `run_stop`, the
  two crouch transitions, `melee`, `reload`, `throw_grenade`, `interact`, `hit_react`,
  `downed`, `alert_scream` and `idle_fidget`.
- Non-contractors have no authored art at all: the swarm has one placeholder frame
  (`body_swarm_idle_se`) and the four Cerberus models none, which is what the lineup image
  above is showing.

Foot-skate and turn timing (`character-art-plan.md` §4.2–4.3) are more exposed at eight
facings than they were at four — more turns, each smaller — and that is unresolved rather
than solved.

**Map art**, both gated on geometry that does not exist yet, with standing task lists in
`MIGRATION_PLAN.md`:

- **Authored `.glb` map modules** (Phase 8). Every wall is still a runtime `BoxMesh`.
- **Baked lighting** (Phase 7b), which needs that geometry to exist at bake time.
