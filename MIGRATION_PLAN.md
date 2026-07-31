# 3D → 2D Isometric Migration Plan

Audit performed 2026-07-30 against `main` @ `cb89b85`.

> ## ✅ IMPLEMENTED 2026-07-30
>
> **Phases 1, 2, 3, 3a, 4, 5a, 5b, 6, 6a, 6b, 7a and 9 are done.** The presentation doc
> written for Phase 9 — [docs/presentation-direction.md](docs/presentation-direction.md) —
> is now the source of truth for how the game is drawn. This file stays as the record of
> *why*, and as the outstanding task list for what is left.
>
> **Not done, and both gated on art that does not exist:**
>
> | Phase | Blocked on |
> |---|---|
> | **8** — map module pipeline | Authored `.glb` modules from the Rhino → Blender pipeline, which has not started. |
> | **7b** — baked lighting | Phase 8. `LightmapGI` needs geometry present at bake time with UV2, and every wall is still a runtime `BoxMesh`. |
>
> Their task lists below stand unchanged. Everything else here is history.
>
> ### Decisions taken during implementation, beyond Q1–Q15
>
> | # | Decision | Why |
> |---|---|---|
> | **Q15** | **Sprite layer set is data-driven**, not fixed at four. `UnitVisual.layers` is an exported array; the soldier has 4, the alien 3, the swarm 2. | Answers Q15 by making it cheap to answer either way later. Adding an arm layer for per-pitch-band vertical aim then costs art and nothing else — which was the whole worry. |
> | **A** | **Rooms are derived, not authored.** `MapData.compute_rooms` finds bulkhead *lines* (rows/columns that are mostly wall), then floods between them; walkable cells on a bulkhead line are doorways and become corridors. | A plain flood-fill of walkable space merges every compartment on any deck with a doorway in it — which is every deck. Deriving also means the graph cannot drift out of sync with the layout. |
> | **B** | **Edge cover is authored in a `[cover]` section**, canonical sides `E`/`S` only. | Cover cannot be a glyph, because a per-tile grid cannot name a boundary. Restricting to canonical sides stops one edge being authored twice with two different values. |
> | **C** | **Destroyed heavy cover degrades to light**; light degrades to nothing. | There is no tile left to turn into impassable rubble under the edge model, and a wrecked crate is still something to crouch behind. |
> | **D** | **Diagonal shots test both adjacent sides**, stronger applies (XCOM rule). | A diagonal crosses a corner, not an edge. |
> | **E** | **Hunker still does not require cover**, and crouch poses are not direction-aware. | Both were listed as optional tightening in §2.10. Deliberately not taken — change one thing at a time. |
> | **F** | **Ambient is `0.20`, `AMBIENT_FLOOR` is `12.0`** — not the §2.7.1 proposal of `0.10` / `8.0`. | Judged on screen against 0.1 and 0.25 once the ortho camera was in, exactly as §2.7.1 asked. At 0.1 bulkheads went black, and a fixed camera cannot be orbited to re-read the space. The `sight_light_threshold` 25.0 ceiling is untouched. |
> | **G** | **`Camera3D.size` is 12**, putting a character at 16% of viewport height. | Closes `character-art-plan.md`'s open action item with arithmetic instead of a measuring script: under orthographic, share-of-height is `height / size` exactly, at any resolution. |
> | **H** | **Placeholder sprite art is generated in code**, not shipped as PNGs. | Nothing to mistake for real art later, and nothing to delete when the real art lands. Every pose and direction exists, so layering, bucketing, mirroring, gear swap and lockstep are all exercisable now. |
>
> ### One bug found and fixed during implementation
>
> Unit render gating was initially computed inside the same early-return as the wall
> occlusion pass, which needs a camera. That made turn *pacing* depend on a camera
> existing — `tools/test_room_visibility.gd` caught it. Visibility is now computed ahead
> of the camera check.

Target: keep levels as real 3D geometry, render through an **orthographic isometric camera at
fixed pitch with four snapped yaws**, and composite hand-drawn 2D character sprites over the
world (Divinity/Fallout approach). New art pipeline is Rhino → Blender → `.glb` → Godot.

---

## Decisions log

Resolved 2026-07-30. Question IDs in §5 are kept stable and marked RESOLVED rather than
renumbered, so links from commits and notes stay valid. **All 12 original questions are now
answered**; two new ones (Q13, Q14) were opened by the answers.

| # | Decision | Consequence |
|---|---|---|
| **Q1** | **Sprites are `Sprite3D` / `AnimatedSprite3D`**, not `CharacterBody2D` / `AnimatedSprite2D`. | Sprites live in the 3D world, so they depth-sort against and are occluded by real geometry. Every other part of the sprite spec — layering, 5+3 mirroring, pivot contract, `SpriteFrames` gear swaps, file naming — carries over unchanged. See §2.6. |
| **Q2** | **Keep 90° snap rotation.** Free orbit (MMB drag, continuous Q/E) goes; Q/E become a four-position yaw snap. Pitch is fixed. | Costs **no additional art** — the 8 direction buckets shift by whole steps. Softens but does not solve wall occlusion (§2.4). Adds one requirement: sprite direction must re-evaluate on camera yaw change, not only on unit turn. |
| **Q3** | **Dark ship confirmed as the intent.** Fix is *not* restoring the commented `0.015`; see §2.7.1 for the proposed values. | Numeric tuning moves out of Phase 0 to **after Phase 1**. Only the design intent was blocking. |
| **Q4** | **Placeholder wall occlusion — IMPLEMENTED.** Geometric rule in `map_builder.gd`; see §2.4.1. | Phase 4's real implementation still pending, but the fixed camera is no longer unusable in the meantime. |
| **Q5** | **Yes — map visuals become authored `.glb` modules.** | Unblocks Phase 7b (baked lighting) and Phase 8 (module pipeline). **Nothing is blocked any more.** Also means the placeholder occlusion's hide-target changes: it currently hides a `"Mesh"` child, and a module instance has no such child (§2.4.1). |
| **Q6** | **No — move speed stays 4.5 m/s.** | `Unit.move_speed` untouched. Closes the open question in `art-direction.md`. Sprite walk-cycle cadence is authored against 4.5, not 2.4. |
| **Q7** | **No — 3D characters do not survive anywhere.** | Large deletion, now its own **Phase 5a**. Simplifies Phase 5 substantially: with no second implementation to support, `UnitVisual` is *rewritten* as the sprite version rather than split into a base class + two subclasses. Risk drops Medium-High → Low-Medium. |
| **Q8** | **Supersede the GDD with a new doc**, don't amend §10.2 in place. | Phase 9 becomes "write new presentation doc + mark GDD sections superseded with pointers". |
| **Q9** | **Vertical aiming: no for now**, may return with the multi-arm layer plan. | `aim_pitch.gd` is deleted with the rest of the rig (Q7). If vertical aim returns it will be per-pitch-band sprite variants on an arm/weapon layer, **not** a bone solve — so nothing about deleting it now forecloses it. See Q14. |
| **Q10** | **Remove zoom entirely for now.** | Simpler than porting it to `Camera3D.size`: delete the wheel handling, `ZOOM_*` constants and both input actions, and set one fixed `Camera3D.size`. **Dissolves Q10's original concern** — with no zoom there is no zoom-dependent `Label3D.fixed_size` behaviour to verify. Also makes `SpringArm3D` pointless: collapse it to a fixed offset. |
| **Q11** | **The cover system needs reworking.** | Scope of the rework is not yet defined → new **Q13**. Gets its own Phase 6a because it couples to sprite sorting, the module pipeline and occlusion all at once. |
| **Q12** | **Render sprites only in rooms containing a player character.** | Room granularity, deliberately coarser than GDD §10.6's per-unit LOS raycast (fine — §10.6 is being superseded by Q8). ⚠️ **Requires `MapData.rooms` to be populated for hand-authored decks, which it is not today** — see the shared prerequisite below. |
| **Q13** | **Cover goes edge-based, XCOM-style.** Cover becomes a property of a tile *boundary*; units stand *on* the tile and are protected from directions whose edge carries cover. | Fixes sprite sorting by construction, deletes the 60° flank heuristic, reclaims floor area, and enables direction-aware crouch poses. Costs a map-format change — which **Phase 3a is already making** for the room graph, so it rides along. Full design in §2.10. |
| **Q14** | **Unseen units fast-forward; log leakage accepted.** Reuse the existing `_instant` path for units the player cannot see, snapping to `IDLE` when one becomes visible mid-activation. | The combat log is slated for removal once the game runs smoothly, so narration of unseen units is a non-issue and needs no suppression work. Animation *processing* was never the concern — see §2.11. |

### ⚠️ Shared prerequisite surfaced by these answers

**`MapData.rooms` is only filled by `MapGenerator` and is empty for every hand-authored deck**
(`map_data.gd:54`, and `maps/test_deck.txt` is the only deck in play). Both **Q12's sprite
visibility gating** and **Phase 4's preferred per-room wall cull** need that graph. Populating
room data for ASCII decks is therefore a single upstream task that unblocks two accepted
decisions — worth doing once, early, rather than twice badly. Added as **Phase 3a**.

---

## 0. Executive summary

The project is already a turn-based grid tactics game (`Vector3i(x, floor, z)` grid,
initiative pool, click-to-move, AP economy). **Nothing in it is fundamentally incompatible
with a fixed isometric camera.** There is no free-look, no WASD character movement, no
physics simulation, no camera-relative aiming, no first-person mechanics, and no skybox.

The migration is therefore small in the places the task description expected it to be large
(camera, controller, physics, HUD) and large in two places it did not anticipate:

| Surprise | Why it matters |
|---|---|
| **No authored level scenes exist.** All geometry is built at runtime in code by `map_builder.gd` from a `MapData` description. | Nothing to convert — but also no module/prefab instancing layer for the `.glb` pipeline, and **runtime geometry cannot be lightmapped**. |
| **No wall-occlusion system exists.** Free orbit was the answer to "a wall is in the way." | Fixed iso makes this permanent. This is a *new* system, and the highest-risk item here. |

**Q1–Q14 are all resolved** (see the decisions log above), so **no phase is blocked on a decision
any more.** A placeholder wall occlusion is already implemented (§2.4.1), which was the one thing
making a fixed camera unusable. One low-stakes question remains open (Q15, confirming what the
"multi-arm plan" means before the sprite layer set is fixed at four).

The critical path is now: camera rig (Phase 1–2) → map format extension carrying **both** the
room graph and edge-cover data (3a) → delete the 3D pipeline (5a) → sprite visual (5b–6) in
parallel with the module pipeline (8) → baked lighting (7b).

The single highest-leverage sequencing note: **Phase 3a's format change is a prerequisite for
three separate accepted decisions** — room-based sprite visibility (Q12), edge-based cover (Q13),
and the preferred wall-occlusion approach (Q4/Phase 4). Making it once, carrying all three
payloads, avoids breaking the map format three times.

---

## 1. Inventory — what exists today

### 1.1 Camera system

| Item | Location | Finding |
|---|---|---|
| Rig scene | [scenes/camera_rig.tscn](scenes/camera_rig.tscn) | `Node3D` pivot → `SpringArm3D` → `Camera3D` |
| Projection | same | **Perspective** — the `Camera3D` node is bare, so `projection` is the default `PROJECTION_PERSPECTIVE` at 75° FOV. No `size` set. |
| Controller | [scripts/camera_rig.gd](scripts/camera_rig.gd) | Free orbit on MMB drag and Q/E; WASD pan in camera-relative space; wheel zoom via `SpringArm3D.spring_length` clamped 5–30; pitch clamped 35°–75°, default −65°. |
| Camera collision | `camera_rig.tscn:10` | `collision_mask = 0` — the SpringArm is used purely as a zoom boom. **No camera-vs-wall clipping system exists to remove.** |
| Focus | `camera_rig.gd:62` `focus_on()` | Called once from [main.gd:61](scripts/main.gd#L61) to centre on the first player spawn. No follow logic, no dynamic FOV, no shake. |
| Input actions | [project.godot](project.godot) | `camera_orbit` (MMB), `camera_orbit_left/right` (Q/E), `camera_pan_*` (WASD), `camera_zoom_in/out` (wheel), `select_unit` (LMB) |
| Design spec | `game-design-document.md` §10.2 | Explicitly specifies the free-orbit camera. **The GDD now contradicts the new direction** and needs amending. |

### 1.2 Player / character controller

[scripts/player_unit.gd](scripts/player_unit.gd) — **already isometric-native.**

- Input is **click-to-act on a grid**, driven by a HUD-armed mode enum
  (`NONE / MOVE / SHOOT / AIMED_SHOT / FACE`). There is no directional character input at
  all; WASD belongs to the camera.
- `_raycast_mouse()` ([player_unit.gd:173](scripts/player_unit.gd#L173)) uses
  `camera.project_ray_origin()` + `project_ray_normal()`. **Both are projection-correct
  under orthographic** in Godot 4 (origin slides across the near plane, normal is constant),
  so tile picking and unit picking need no maths changes.
- Per-frame re-raycast ([player_unit.gd:109](scripts/player_unit.gd#L109)) is deliberate and
  still correct — panning slides new geometry under a stationary cursor. Only its comment
  ("panning or orbiting") goes stale.
- Movement ([unit.gd:126](scripts/unit.gd#L126) `move_along`) is a `Tween` on
  `global_position` along a BFS path, with an elaborate deceleration system driven off the
  Mixamo `run_stop` clip's measured travel curve. All 3D-animation-specific; see §2.5.
- Facing is a plain yaw on the unit `Node3D` (`_yaw_toward`, `face_toward`). **This yaw is
  the exact hook the 8-direction sprite system needs** — see §2.6.

**Verdict: reusable as-is.** No camera-relative input to rewrite.

### 1.3 Physics & collision

Every collision body in the project is a `StaticBody3D` with `collision_mask = 0`. There are
**no `RigidBody3D` and no `CharacterBody3D` nodes anywhere.** Nothing is simulated; collision
shapes exist solely as raycast targets:

| Layer | Owner | Consumed by |
|---|---|---|
| 1 | Map geometry: walls, platforms, and one big flat ground box (`map_builder.gd` `build_ground_collision`) | Mouse-pick raycast (`mask 1\|2`), LOS (`has_line_of_sight`), lighting occlusion (`has_clear_line`) |
| 2 | Unit body capsules (`Body/Collision` in all three unit scenes) | Mouse-pick raycast only |
| 4 | Cover blocks (`cover_object.gd`) | **Nothing.** Deliberately excluded from LOS so rays pass over cover and the accuracy penalty represents it instead. |

LOS is its own eye-height→chest-height raycast (1.4 m → 0.9 m), completely independent of
the camera. Lighting occlusion likewise.

**Verdict: zero physics-behaviour risk from the camera change.** No gameplay physics exists
to behave differently.

### 1.4 Level / scene structure

**There are no level scene files to migrate.** [scenes/test_map.tscn](scenes/test_map.tscn)
is a two-node stub: a `Node3D` with `test_map.gd` attached.

The pipeline is data → code → nodes:

```
maps/test_deck.txt  (ASCII)  ─┐
                              ├→ MapData ─→ MapBuilder.build() ─→ StaticBody3D + BoxMesh/PlaneMesh
MapGenerator (BSP procgen)  ─┘             (per cell, at runtime)
```

- [map_data.gd](scripts/map_data.gd) — engine-free cell description keyed
  `Vector3i(x, deck, z)`, matching the grid key exactly. `Terrain{VOID,FLOOR,WALL,PLATFORM}`,
  `Cover`, `Fixture`, `Spawn`, stair links.
- [map_builder.gd](scripts/map_builder.gd) — the only half needing a scene tree. Builds one
  `StaticBody3D` + `BoxMesh` per wall/platform/cover, one `PlaneMesh` per floor tile, one
  `LightSource` per fixture, all with code-created `StandardMaterial3D`s.
- [map_generator.gd](scripts/map_generator.gd) — deterministic BSP compartment generator,
  touches no scene tree.
- Metrics: `TILE_SIZE = 1.5`, `FLOOR_HEIGHT = 3.0`, `WALL_HEIGHT = 3.0`,
  `PLATFORM_HEIGHT = 3.0`.

**Verdict: excellent architecture, wrong shape for the new art pipeline.** It is fully
modular and tile-like at the *data* level, but the visual layer is code-generated primitives.
Two consequences: (a) the `.glb` module pipeline needs a new prefab-table layer in
`MapBuilder`; (b) `LightmapGI` is **impossible** against runtime-generated geometry — see
§2.7 and Q5.

The only `.glb` instancing today is characters and the rifle (`assets/soldier_mixamo.glb`,
`swarm_mixamo.glb`, `rifle.glb`).

### 1.5 Lighting

**Entirely realtime. Zero baked lighting.**

| Source | Location |
|---|---|
| `WorldEnvironment` — ambient colour source, volumetric fog, glow/bloom | [scenes/main.tscn:10-30](scenes/main.tscn#L10) |
| `DirectionalLight3D` "Sun", `shadow_enabled = true` | `main.tscn:50` |
| Per-fixture shadow-casting `SpotLight3D`, aimed down | [light_source.gd](scripts/light_source.gd) `_make_visual()`, built at runtime |
| Per-unit helmet `SpotLight3D` (`AimedLight`, `top_level`, 7.0 energy, shadows on) | [character_base.tscn:123](scenes/character_base.tscn#L123) |
| Visible beam cone — custom shader | [shaders/flashlight_beam.gdshader](shaders/flashlight_beam.gdshader) + [flashlight_beam.gd](scripts/flashlight_beam.gd) |
| Transient `OmniLight3D` muzzle flashes | [vfx_manager.gd:76](scripts/vfx_manager.gd#L76) |

Note `main.tscn:13-15`: `ambient_light_energy = 1.0` is a **`TESTING:` override**, with the
intended dark-scene values (`0.015` ambient, `0.02` sun, shadows off) preserved in a comment.
See Q3.

**Critical constraint:** lighting here is not decoration. [lighting_manager.gd](scripts/lighting_manager.gd)
computes per-tile `light_value` (0–100) split into a `_base` layer (static fixtures) and a
`_dynamic` layer (flashlights only, kept separate on purpose). That value drives shot
accuracy *and* alien detection ([enemy_unit.gd](scripts/enemy_unit.gd) `_can_see`,
`_on_lighting_changed`), and `recompute_dynamic()` fires **once per tile mid-walk**. The
gameplay lighting model is irreducibly dynamic.

**Verdict: only the static-fixture layer is bakeable, and only if the geometry becomes
authored assets.** The flashlight layer must stay realtime or the detection design breaks.

### 1.6 UI / HUD

[scenes/hud.tscn](scenes/hud.tscn) is a `CanvasLayer` of anchored `Control` nodes
(unit panel, action bar, combat log, VATS-style zone menu, banner) plus a code-built
`LoadoutMenu` overlay. **Fully camera-agnostic and reusable as-is.**

**There are no `unproject_position` / `project_position` calls anywhere in the project.**
No floating health bars, no worldspace-to-screen code. The only camera coupling in the
presentation layer is billboarding:

| Item | Location | Under fixed ortho |
|---|---|---|
| `NameLabel` `Label3D`, `billboard = 1` | all three unit `.tscn`s | Harmless but pointless — nothing rotates. Cheap to leave. |
| Target-% and AP-cost `Label3D`, `billboard = ENABLED`, **`fixed_size = true`**, `no_depth_test = true` | [highlight_manager.gd:147-158](scripts/highlight_manager.gd#L147) | `fixed_size`'s comment says "constant on-screen size at any zoom" — an assumption about perspective. Interaction with `Camera3D.size` needs re-verification (Q10). |
| Flashlight `LensGlow` billboarded quad | [flashlight_beam.gd:101](scripts/flashlight_beam.gd#L101) | Fine. |
| Tile-overlay quads (move bands, path pips, target markers) | `highlight_manager.gd` | Flat `PlaneMesh` at stacked Y offsets — **improve** under ortho (no perspective foreshortening). |

### 1.7 Systems assuming free camera rotation

| System | Status |
|---|---|
| Orbit input (MMB, Q/E) + `camera_orbit*` actions | **Reduce to a 90° snap** (Q2). MMB free drag goes; Q/E are repurposed. |
| `SpringArm3D` zoom via `spring_length` | **Rework** — under ortho, distance no longer changes apparent scale. Zoom becomes `Camera3D.size`. |
| Camera-vs-wall clipping | **Does not exist** (`collision_mask = 0`). Nothing to remove. |
| Skybox | **Does not exist** — `ambient_light_source = 2` (colour), no `Sky` resource. Nothing to remove. |
| Dynamic FOV | **Does not exist.** |
| Wall occlusion / cutaway | **Does not exist — and is now required.** See §2.4. |
| GDD §10.2 | **Contradicts the new direction.** Amend. |

---

## 2. Per-system migration verdicts

### 2.1 Camera rig — *modify* · risk **Low**

Keep the pivot + `focus_on()` + pan. Set `Camera3D.projection = PROJECTION_ORTHOGONAL`, fix
pitch, move zoom to `Camera3D.size`. The `SpringArm3D` can stay (as a fixed boom to keep the
near plane clear) or collapse into a plain offset — either is fine; it is inert.

Classic true-iso is yaw 45°, pitch 35.264° (`atan(1/√2)`). The existing 35°–75° clamp already
brackets that, so tile proportions will not be shocking.

**Per Q2, yaw becomes a four-position snap** (45° / 135° / 225° / 315°) rather than fixed.
That means:

- Free-look input goes: the `_orbiting` flag, the MMB branch, `ORBIT_SPEED`, and the pitch
  clamp constants. Pitch loses its input entirely.
- Q/E change from continuous rotation (`KEY_ORBIT_SPEED`) to "snap to the next/previous
  quarter", ideally tweened rather than cut so the player keeps their bearings.
- **Pan needs no change at all.** `camera_rig.gd:57-58` already recomputes its forward/right
  basis from `rotation.y` every frame, so pan stays camera-relative across snaps for free.
- **New requirement:** the rig should expose a yaw-changed signal. Sprite direction is derived
  from unit yaw *minus camera yaw* (§2.6), so a snap re-buckets every character on screen even
  though no unit turned. A signal is cleaner than having each `SpriteVisual` poll.

### 2.2 Player controller — *reuse as-is* · risk **Low**

No changes required. Optionally refresh the stale "or orbiting" comment.

### 2.3 Physics & collision — *reuse as-is* · risk **Low**

No changes required. Layer scheme, LOS, and lighting occlusion are all camera-independent.

### 2.4 Wall occlusion — *build from scratch* · risk **High** ⚠️

**The highest-risk item in this migration, and it is an addition, not a conversion.**

`WALL_HEIGHT = 3.0` bulkheads on the camera-near side of a compartment will permanently hide
its interior. Under free orbit the player simply rotated; the Q2 snap keeps a *reduced* version
of that escape hatch.

**The snap is a mitigation, not a solution.** With only four yaws, any given room corner is
hidden from two of them, and asking the player to rotate to see what they are standing next to
is friction rather than agency. Occlusion handling is still required — the snap just lowers the
bar for how aggressive it has to be, which may make option 1 or 2 below sufficient where a
fully fixed camera would have forced option 3.

A placeholder is now in place (§2.4.1); what follows is the menu for the real implementation.
Options, roughly cheapest first:

1. **Lower near-side walls** — `MapBuilder` builds camera-facing walls short (~1.0 m) and
   far-side walls full height. Cheap, static, no shader. Changes the look substantially.
2. **Per-room roof/wall culling** — hide the walls of whichever compartment holds the active
   unit. `MapData.rooms` already carries the compartment graph (`map_data.gd:54`), so the
   data exists. Medium cost, reads well, needs the procgen room graph populated for
   hand-authored decks too (currently empty for those).
3. **Dither/fade shader on near-camera geometry** — most flexible, most expensive; needs a
   custom material on every wall, which conflicts with `MapBuilder`'s code-created
   `StandardMaterial3D`s.

Recommendation: prototype (2) first — but note the room graph does **not** in fact already
exist for hand-authored decks (see the shared prerequisite in the decisions log; Phase 3a).
Decide with a real deck on screen, not on paper.

#### 2.4.1 Placeholder — implemented 2026-07-30 · risk **Low**

Lives in [map_builder.gd](scripts/map_builder.gd) (`_process`, `_away_step`,
`_apply_wall_occlusion`, `_hides_interior`). The rule:

> Hide a wall when the cell one step **further from the camera** is walkable floor.

That set is exactly the near-side boundary of each compartment. A wall backed by another wall
or by the void outside the hull stays up, so the deck never opens onto nothing.

Why this shape, given the plan prefers per-room culling:

- **Needs no room graph.** It reads `MapData.is_walkable` only, so it works on the hand-authored
  deck today rather than waiting on Phase 3a.
- **Camera yaw is snapped, not read as a fixed angle.** `_away_step` quantises the camera's
  look direction into one of 8 grid steps and recomputes only when the bucket changes — so it
  costs one `Vector3i` compare per frame while the camera is still, and **works unchanged
  before and after Phase 1**: under today's free orbit it re-buckets as the yaw sweeps, and
  under snapped yaws a snap simply *is* a bucket change.
- **Only the mesh is hidden; collision stays live.** LOS and lighting occlusion both raycast
  layer 1, so a wall you can see past must still be one you cannot shoot through.
- **Cover and platforms are left alone.** Cover is being reworked (Q11/Q13) and platform tops
  are walkable — hiding one would leave units standing on nothing.

`OCCLUSION_DEPTH = 1` is deliberate rather than a first guess: a wall that *directly* fronts
floor is the near boundary. Raising it only becomes wanted if the camera pitch is flattened
well below 35°.

Verified with [tools/_debug_occlusion.gd](tools/_debug_occlusion.gd), which prints the hidden
set as ASCII at all four iso yaws for eyeballing against `maps/test_deck.txt`: 48 of 86 walls
hidden per yaw, correctly mirrored between opposite yaws. The `--auto` headless smoke test
still completes a full mission.

**Known limitations, all deferred to Phase 4 proper:** it is per-wall and geometric, so it
cannot know that a room is empty and its walls need not open; it pops rather than fades on a
yaw change; and once walls become `.glb` module instances (Q5) the hide-target changes — it
currently reaches for a `"Mesh"` child that `_add_box_body` happens to create.

### 2.5 `UnitVisual` → sprite rewrite · risk **Low-Medium**

> **Revised after Q7.** With no 3D characters surviving there is no second implementation to
> support, so this is a *rewrite of one class*, not a base class plus two subclasses. The
> analysis below still explains why the seam is clean; ignore its talk of parallel
> implementations.


[unit_visual.gd](scripts/unit_visual.gd) is genuinely well-factored for this: `Unit` drives
it **by intent** (`set_stance`, `play_action`, `play_burst`), never by clip name, and it
already documents a working no-`AnimationPlayer` fallback path where stances no-op and
actions resolve on timers of the eventual clip length.

But it is a hard-typed dependency — `@onready var visual: UnitVisual = $Visual`
([unit.gd:35](scripts/unit.gd#L35)) — and `Unit.move_along` calls a wide 3D-specific surface:
`run_stop_travel()`, `run_stop_rate()`, `run_stop_time_at()`, `run_stop_travel_at()`,
`begin_run_stop()`, `finish_run_stop()`, `has_walk()`, plus `muzzle_origin()`,
`set_aim_pitch()`, `clear_aim_pitch()`.

**The clean seam already exists.** A sprite implementation that returns `run_stop_travel() → 0.0`
and `has_walk() → false` makes the entire deceleration system inert — that is precisely the
documented degradation path ("a zero-length stop is simply never entered, and the move ends
as it used to"). So: extract a base class / shared API, and implement `SpriteVisual` against
it. `Unit` itself needs almost no change.

Dead-for-sprites, keep for any surviving 3D characters:
[aim_pitch.gd](scripts/aim_pitch.gd), [weapon_mount.gd](scripts/weapon_mount.gd),
`RUN_STOP_CURVE`, `run_speed_scale`, the whole `art_src/anims/*.fbx` + `tools/build_anims.py`
+ `docs/mixamo-pipeline-plan.md` chain. These already no-op when their `NodePath`s are empty
(the capsule alien takes that path today), so they cost nothing left in place — but the
measurement work behind them becomes sunk. Flagging explicitly rather than quietly: see Q7.

`muzzle_origin()` needs a per-direction offset table for sprites, or can fall back to the
existing `FALLBACK_MUZZLE_HEIGHT = 1.4` constant.

### 2.6 8-direction layered sprites — *build from scratch* · risk **High** (art-gated)

**Resolved per Q1: `Sprite3D` / `AnimatedSprite3D`.** The spec's `CharacterBody2D` +
`AnimatedSprite2D` are canvas-space nodes — they cannot hold a position in a 3D world, cannot
depth-sort against 3D walls, and cannot be occluded by geometry. (A `SubViewport` composite is
the other way to put 2D nodes over a 3D scene, but it is strictly more complex and loses
per-sprite depth, which is the one thing this game most needs.) Structure:

```
PlayerUnit (Node3D)                 -- unchanged, keeps grid_pos + yaw
└── Visual (SpriteVisual)           -- implements the UnitVisual API
    ├── BodySprite   (AnimatedSprite3D)
    ├── HeadSprite   (AnimatedSprite3D)
    ├── HelmetSprite (AnimatedSprite3D)
    └── WeaponSprite (AnimatedSprite3D)
```

Everything else in the spec survives that substitution unchanged: the 5-drawn + 3-mirrored
rule for symmetric poses, hand-drawn 8 for armed/asymmetric, layer split
(body/head/helmet/weapon), gear swap by reassigning `SpriteFrames`, and the
`[part]_[variant]_[animation]_[direction]_[frame].png` convention. Pivot consistency maps to
`Sprite3D` with identical `pixel_size` and `offset` across all four layers.

**Direction derivation is trivial and already available:** the unit's yaw
(`Unit._yaw_toward` / `rotation.y`) minus the camera yaw, quantised into 8 buckets of 45°. A
single `_sync_direction()` on `SpriteVisual` drives all four layers in lockstep.

Because the Q2 snap moves yaw in multiples of 90°, it shifts every bucket by exactly two steps
— so **the snap costs no additional art**, only a re-bucket. That re-bucket is a real
requirement though: a snap changes every character's apparent facing without any unit having
turned, so `_sync_direction()` must be driven by the rig's yaw-changed signal (§2.1) as well as
by unit facing changes.

Sprite lighting: `Sprite3D` in `SHADED` mode will receive the realtime lights, which fights
hand-painted shading; `UNSHADED` + `modulate` driven from the tile's `light_value` is the
more controllable route and keeps the screen agreeing with the rules (the principle
`aimed_light.gd` already argues for).

### 2.7 Lighting → hybrid baked + dynamic · risk **High**

The static-fixture layer is a legitimate `LightmapGI` candidate. The flashlight layer is not
— it moves mid-walk and drives detection.

**Blocker:** `LightmapGI` requires geometry present at bake time with a UV2 lightmap channel.
Today every wall is a `BoxMesh` created in `_add_box_body()` at runtime. Baking is impossible
until the visual layer becomes authored `.glb` modules instanced from a saved scene — which
couples this phase to §2.8. Resolve as Q5.

#### 2.7.1 Ambient light — proposed fix (Q3) · risk **Low**

**The current state is not an aesthetic problem, it is the screen disagreeing with the rules.**
At `ambient_light_energy = 1.0` a room renders fully lit, while `AMBIENT_FLOOR = 0.0` gives
every tile no source reaches `light_value 0` — which `Combat.light_modifier` turns into a
**−30 accuracy penalty** (`lerp(-30, +10, light/100)`), and which puts the tile below the
aliens' `sight_light_threshold = 25.0` so units on it are unseeable. This is exactly the class
of divergence [aimed_light.gd](scripts/aimed_light.gd) was written to prevent.

**Restoring the commented `0.015` is also wrong.** That value was tuned when 3D character
meshes were lit by the same lights as the world, so ambient had to sit near zero for the
flashlight to read at all. Under Phase 6 (sprites `UNSHADED`, modulated from tile
`light_value`), character legibility decouples from scene ambient entirely — so ambient now
governs *only* whether architecture silhouettes read. At `0.015` an unlit corridor is literally
black, which is worse under a fixed camera than under free orbit, because the player can no
longer rotate to re-read the space.

So: choose ambient for architectural legibility, then make the rules agree with it.

| Change | From | To | Rationale |
|---|---|---|---|
| `main.tscn` `ambient_light_energy` | `1.0` (`TESTING:`) | **`0.10`** | Keeps the existing cool `Color(0.5, 0.52, 0.58)`. Enough to silhouette a bulkhead, nowhere near enough to read as "lit". |
| `LightingManager.AMBIENT_FLOOR` | `0.0` | **`8.0`** | Makes the rules match the visible faint ambient. Costs ~3 accuracy points (−30 → −26.8) and stays far below the 25.0 sight threshold, so the stealth design is untouched. |
| `main.tscn` Sun `DirectionalLight3D` | `light_energy 1.0`, shadows **on** | **delete** (or `0.05`, shadows **off**) | There is no sun inside a hull. A directional shadow map in an interior costs real frame time for a meaningless read. |

Supporting evidence that dark was always the intent: `volumetric_fog_density = 0.01` only reads
as light-beams against a dark scene — at ambient `1.0` it washes to milk. And this matters
*more* after baking, not less: once static fixtures are baked, ambient is the only thing filling
non-fixture space.

**Unlike most constants in this codebase, these three are not measured** — they are starting
points to judge on screen. Tune them **after Phase 1**, since the ortho angle and zoom change
how much light reaches the eye. Also replace the `TESTING:` comment with a rationale comment in
the house style rather than deleting it silently.

### 2.8 Map module pipeline — *extend* · risk **High**

`MapData` → `MapBuilder` is the right architecture; it just needs a prefab layer. Add a
module table mapping `Terrain`/`Cover`/`Fixture` values to `.glb` `PackedScene`s and instance
those instead of code-built primitives, keeping the existing `StaticBody3D` collision (which
gameplay depends on) either from the `.glb` or still generated. `TILE_SIZE = 1.5` /
`FLOOR_HEIGHT = 3.0` become the authoring contract for Rhino/Blender.

This also unblocks §2.7: instanced modules with UV2 can be lightmapped.

### 2.9 HUD — *reuse as-is* · risk **Low**

No changes. Q10 removed zoom, which dissolved the `Label3D.fixed_size` concern.

### 2.10 Cover → edge-based (XCOM model) — *rebuild* · risk **High**

**Diagnosis: the problem is not the art, it is that cover occupies its own impassable tile.**
`CoverObject.register_with_grid` claims a whole tile and sets `passable = false`, so units stand
*adjacent* to cover, and `Combat.find_defending_cover` then scans the target's four orthogonal
neighbours and applies a 60° dot-product test to guess which crate was protecting them. Under a
fixed iso camera that causes three problems at once:

1. **Ambiguous sprite sorting.** Transparent `Sprite3D`s sort by origin distance. A unit one tile
   from a 0.85-tile crate can be near-coincident in depth at some yaws, and the sort flickers.
   This is the original Q11 symptom.
2. **The player cannot express intent.** Which side you are covered from is inferred from
   geometry, never chosen — and under a camera that cannot freely orbit, it is also hard to *see*
   which neighbour the engine picked.
3. **It reads wrong.** A sprite beside a crate reads as "near a crate". There is no pose
   relationship, and the layered 8-direction system is exactly what could sell one.

**The model: cover is a property of a tile edge.** A unit stands *on* the tile and is protected
against shots crossing an edge that carries cover. Light/heavy tiers, the 20/40 accuracy
penalties and destructibility all carry over unchanged.

Why this specifically:

- **Sorting is fixed by construction.** A prop on a tile boundary is never depth-coincident with
  a unit at tile centre, so ordering is consistent at every yaw. Partial occlusion then becomes
  *desirable*: at 35° pitch a 1.0–1.4 m prop on the camera-near edge covers the sprite's lower
  body and clears the head, and that silhouette **is** the "in cover" read, for free.
- **The flank heuristic disappears.** Cover direction becomes discrete, so "is this shot covered"
  is a comparison of the incoming octant against the covered edges — cheaper *and* more legible
  than `dot() > 0.5`. `find_defending_cover` largely dissolves.
- **Floor area is reclaimed.** Cover-heavy rooms stop being mazes, which matters more now that
  obstructions cannot be orbited around.
- **Crouch poses become direction-aware.** `do_hunker` / `STAND_TO_CROUCH` can crouch *toward*
  the covered edge — the strongest available readability cue, and native to the layered sprites.

**Cost is the map format**, since `MapAscii` is one glyph per tile and cannot express edges.
`MapData`'s own header already flags that limit as known, and **Phase 3a is extending the format
for the room graph anyway** — edge cover should ride along in that same change rather than
forcing a second format break later.

**The affected surface is small and fully enumerated** (grep, 2026-07-30): `combat.gd` (lines
67–86 `find_defending_cover`, 126–129, 182–186), `grid_manager.gd` (`damage_cover`,
`adjacent_cover_tiles`), `cover_object.gd`, `tile_data.gd` (`cover_type`, `cover_node`),
`player_unit.gd:268-271` (one log line), and `map_builder.gd` `_add_cover`. Nothing else touches
cover.

**Knock-ons to decide during implementation, not now:**

- **Cover tiles become passable**, which adds legal destinations and changes `get_reachable_tiles`
  output. A real balance shift, not just a refactor.
- **Diagonal shots cross a corner, not an edge.** XCOM resolves this by testing both adjacent
  sides; pick a rule and document it.
- **Destroyed cover.** Today rubble makes the tile impassable. Edge cover has no tile to make
  impassable — does destroyed heavy cover degrade to light, or to nothing?
- **Hunker currently does not require cover** (flat −20 regardless). XCOM ties them together.
  Optional tightening.

### 2.11 Unseen units — fast-forward · risk **Low**

Q14. Two separate things, and the one that bites is not the obvious one.

**Animation processing is not the concern.** Hiding a node in Godot does not stop animation:
visibility is a rendering property, a hidden `AnimatedSprite3D` keeps ticking its frame timer,
and `AnimationPlayer` keeps advancing. Nothing auto-culls. At 2–4 units that costs nothing.

**Pacing is the concern, because turn resolution `await`s animations.** `await
visual.play_action(...)`, `await visual.play_burst(rounds)`, `await move_along(path)` — an
enemy's activation takes as long as its animations take, so an unseen unit currently burns full
wall-clock time against a completely static screen.

**The mechanism already exists.** `Unit._instant` (set from `DisplayServer.get_name() ==
"headless"`) already makes `play_action` return immediately, `play_burst` fire its muzzle signals
with no delay, and `_step_to` teleport. Generalising it from "headless" to "not currently
rendered" gets the XCOM behaviour out of an existing, documented path rather than a new one.

Two caveats: `_instant` is set once in `_ready()` and must become per-action; and a unit that
becomes visible **mid-move** would pop across the map if resolved instantly — but `move_along`
already does per-tile work (`recompute_dynamic`, `check_overwatch`), so a per-tile visibility
check drops in naturally: fast-forward while hidden, animate the remainder once seen, snapping to
`IDLE` at the handover rather than trying to join a one-shot already in progress.

**Log leakage is accepted.** `action_logged` will still narrate unseen units; the log is slated
for removal once the game runs smoothly, so no suppression work is warranted.

---

## 3. Prioritised to-do list

Ordered by dependency. Phases 1, 2, 3 and 7a are unblocked and can start immediately.

### Phase 0 — Decisions · **COMPLETE**

All resolved 2026-07-30; see the decisions log for answers and consequences.

- [x] **Q1** Sprite node type → **`Sprite3D` / `AnimatedSprite3D`**
- [x] **Q2** Camera yaw policy → **90° snap rotation retained**
- [x] **Q3** Dark ship confirmed; values proposed in §2.7.1, tuned after Phase 1
- [x] **Q4** Wall occlusion → **placeholder implemented** (§2.4.1); real one is Phase 4
- [x] **Q5** Map visuals → **authored `.glb` modules**; unblocks Phases 7b and 8
- [x] **Q6** Move speed → **stays 4.5 m/s**
- [x] **Q7** 3D characters → **no survivors**; becomes Phase 5a
- [x] **Q8** GDD → **superseded by a new doc**, not amended
- [x] **Q9** Vertical aiming → **no for now**; recoverable via arm layers (Q15)
- [x] **Q10** Zoom → **removed entirely**; dissolves the `fixed_size` question
- [x] **Q11/Q13** Cover → **edge-based, XCOM model** (§2.10, Phase 6b)
- [x] **Q12/Q14** Unseen units → **hidden by room, fast-forwarded**; log leak accepted (§2.11)
- [x] **Q15** Confirm what the "multi-arm plan" means before fixing the sprite layer set at four

### Phase 1 — Camera rig · **Low**

- [x] Set `Camera3D.projection = PROJECTION_ORTHOGONAL` in `camera_rig.tscn`
- [x] Fix pivot pitch to the chosen iso angle (suggest 35.264°); set initial yaw 45°
- [x] Set one fixed `Camera3D.size` — **zoom is removed entirely** (Q10), not ported
- [x] Delete zoom handling: the wheel branches, `ZOOM_STEP`, `ZOOM_MIN`, `ZOOM_MAX`
- [x] Delete free-look from `camera_rig.gd`: `_orbiting`, the MMB branch, `ORBIT_SPEED`, `PITCH_MIN`/`PITCH_MAX`, and all pitch input
- [x] Convert Q/E from continuous orbit (`KEY_ORBIT_SPEED`) to a tweened 90° yaw snap
- [x] Add a yaw-changed signal for `SpriteVisual` to re-bucket direction on (§2.1, §2.6)
- [x] Collapse `SpringArm3D` to a fixed offset — with no zoom it has no remaining purpose
- [x] Leave pan alone — it already recomputes its basis from `rotation.y` every frame, so it follows the snap for free
- [x] Keep `focus_on()`
- [x] Re-run `tools/_debug_occlusion.gd` to confirm the placeholder still buckets correctly

### Phase 2 — Input map · **Low**

- [x] Remove `camera_orbit` (MMB free drag) from `project.godot`
- [x] Remove `camera_zoom_in` / `camera_zoom_out` (Q10)
- [x] **Keep** `camera_orbit_left` / `camera_orbit_right` (Q/E) — repurposed as the 90° snap; consider renaming to `camera_snap_left/right` since the names now describe the old behaviour
- [x] Leave `camera_pan_*` and `select_unit` untouched

### Phase 3 — Verify under orthographic · **Low-Medium**

- [x] Confirm mouse-pick raycast resolves correct tiles (`player_unit.gd` `_raycast_mouse`, `_tile_under_mouse`)
- [x] Confirm unit picking on collision layer 2 still hits
- [x] ~~Verify `Label3D.fixed_size` sizing vs. `Camera3D.size`~~ — moot, Q10 removes zoom
- [x] Verify tile-overlay quad Y offsets (`RANGE_Y` … `TARGET_Y`) don't z-fight at the new angle
- [x] Confirm `no_depth_test` labels still read correctly
- [x] Confirm tile picking stays correct at **all four** snap yaws, not just the initial 45°
- [x] Confirm pan direction still reads as camera-relative after a snap
- [x] Run the `--auto` headless smoke test (`main.gd:20`) to confirm nothing regressed

### Phase 3a — Map format extension: room graph + edge cover · **Medium** ⭐

**The highest-leverage single task in the plan** — prerequisite for three accepted decisions
(Q12 room visibility, Q13 edge cover, Q4/Phase 4's preferred occlusion). Break the format once.

Shared prerequisite for Q12 (room visibility) **and** Q13 (edge cover) — both need the map format
extended past one-glyph-per-tile. Make the format change **once**, here, carrying both payloads.

- [x] Populate `MapData.rooms` / `room_links` for ASCII decks (today only `MapGenerator` fills them)
- [x] Decide whether rooms are inferred from the ASCII by flood-fill between bulkheads, or authored explicitly as a second layer in the map file
- [x] **Carry edge-cover data in the same format change** (§2.10) rather than breaking the format twice
- [x] Keep it engine-free so it stays headlessly testable alongside `tools/test_map_roundtrip.gd`
- [x] Extend `test_map_roundtrip.gd` to assert both the room decomposition and the edge-cover set of `test_deck.txt`
- [x] Preserve the byte-identical round-trip property the existing test guarantees

### Phase 4 — Wall occlusion, real implementation · **High** ⚠️

Placeholder already shipped (§2.4.1) — this replaces it.

- [x] Choose an approach (lowered near walls / per-room culling / dither-fade). The Q2 snap lowers the pressure, so re-judge the cheap options first
- [x] Whatever is chosen must re-evaluate on camera yaw snap — "near-side" changes with the camera
- [x] Fade rather than pop on a yaw change
- [x] Retarget from the `"Mesh"` child to the module instance root once Q5's `.glb` modules land
- [x] Implement and evaluate on `maps/test_deck.txt` with real geometry on screen
- [x] Check interaction with LOS and lighting occlusion — hidden walls **must still block rays**
- [x] Retire `tools/_debug_occlusion.gd`, or repoint it at the new implementation

### Phase 5a — Remove the 3D character pipeline · **Medium** (Q7 = no survivors)

Do this *before* Phase 5b — deleting the second implementation is what makes the rewrite simple
rather than an abstraction exercise. Land it as its own commit so it is easy to revert.

- [x] Delete `art_src/anims/*.fbx` (23 clips) and `art_src/anims/swarm_anims/`
- [x] Delete `tools/build_anims.py`, `add_ik_controls.py`, `bake_run_ik.py`, `verify_ik_controls.py`, `verify_run_ik.py`, `make_tpose.py`, `make_character_only.py`, `export_soldier_rig.py`, `measure_grip_pose.py`, `measure_support.py`, `gen_soldier.py`
- [x] Delete `scripts/aim_pitch.gd` (Q9 — nothing about this forecloses vertical aim returning) and `scripts/weapon_mount.gd`
- [x] Delete `scenes/character_base.tscn` and the `soldier_mixamo` / `swarm_mixamo` / `rifle` GLBs + textures
- [x] Delete the deceleration system from `unit.gd` / `unit_visual.gd`: `RUN_STOP_CURVE`, `RUN_STOP_ENTRY_SPEED`, `run_stop_*`, `begin_run_stop`, `finish_run_stop`, `_decelerate_to`, `_slide`, `run_speed_scale`
- [x] Simplify `move_along` once the above is gone — it collapses to a plain tween walk
- [x] **Keep** `aimed_light.gd`, but simplify: it already takes orientation from the unit and only *position* from a helmet bone, so it becomes a fixed offset on the unit. The flashlight is a gameplay system (detection), not character art
- [x] **Keep** the generic parts of `unit_visual.gd`: `footstep`, the fidget system, the intent-driven API shape
- [x] Delete `docs/mixamo-pipeline-plan.md`
- [x] Confirm `--auto` still completes after each deletion step

### Phase 5b — Sprite visual · **Low-Medium** (was Medium-High before Q7)

- [x] Rewrite `UnitVisual` as the sprite implementation — **no base class or interface needed**, since Q7 leaves only one implementation
- [x] Preserve the intent-driven API (`set_stance` / `play_action` / `play_burst`) so `Unit` needs no changes
- [x] Keep the no-art fallback path (timer-based action durations) — it is what keeps pacing identical before and after the art lands

### Phase 6 — Sprite characters · **High** (art-gated)

- [x] Implement `SpriteVisual` with the four-layer `AnimatedSprite3D` node structure
- [x] Implement `_sync_direction()` — 8-bucket quantisation of unit yaw minus camera yaw
- [x] Drive `_sync_direction()` from the rig's yaw-changed signal as well as from unit facing, so a snap re-buckets every character on screen
- [x] Implement lockstep animation sync across all four layers
- [x] Decide how sprites sort against 1.0–1.4 m cover blocks (Q11)
- [x] Implement mirroring for symmetric poses (5 drawn + 3 flipped)
- [x] Establish the shared canvas/pivot contract (fixed canvas size, common anchor, matching `pixel_size` + `offset`)
- [x] Implement gear swap via `SpriteFrames` reassignment
- [x] Per-direction muzzle-offset table for `muzzle_origin()`, or fall back to `FALLBACK_MUZZLE_HEIGHT`
- [x] Decide sprite lighting: `UNSHADED` + `light_value` modulate (recommended) vs. `SHADED`
- [x] Adopt the `[part]_[variant]_[animation]_[direction]_[frame].png` naming convention in `assets/`
- [x] Author walk/run cadence against **4.5 m/s** (Q6 — the 2.4 change was declined)

### Phase 6a — Room visibility + unseen-unit fast-forward · **Medium** (Q12/Q14, needs Phase 3a)

- [x] Hide unit sprites in any room containing no player character
- [x] Decide the rule for units in corridors / outside any room (`MapData.corridors` exists but is unpopulated for ASCII decks)
- [x] Generalise `Unit._instant` from "headless" to "headless **or** not currently rendered" (§2.11)
- [x] Make `_instant` per-action rather than set once in `_ready()`
- [x] Add a per-tile visibility check in `move_along` so a unit becoming visible mid-move animates the remainder instead of popping
- [x] Snap to `IDLE` at the visibility handover rather than joining a one-shot in progress
- [x] Confirm overwatch still triggers correctly for fast-forwarded moves — `check_overwatch` is awaited per tile and must not be skipped
- [x] **No log suppression** — Q14 accepts the leak; the log is going away
- [x] Note this is deliberately coarser than GDD §10.6's per-unit LOS raycast; §10.6 is superseded by Q8

### Phase 6b — Edge-based cover · **High** (Q13 = XCOM model, design in §2.10)

Needs Phase 3a's format change first.

- [x] Move cover from `GridTileData.cover_type` (per tile) to per-edge data on the tile
- [x] Stop marking cover tiles impassable in `cover_object.gd` — units now stand *on* them
- [x] Replace `Combat.find_defending_cover`'s 60° dot test with an incoming-octant vs. covered-edge comparison
- [x] Decide the diagonal rule — a diagonal shot crosses a corner, not an edge (XCOM tests both adjacent sides)
- [x] Retarget `GridManager.damage_cover` from a tile to an edge; decide whether destroyed heavy cover degrades to light or to nothing
- [x] Replace `GridManager.adjacent_cover_tiles` with a covered-edges query
- [x] Update `map_builder.gd` `_add_cover` to place props on tile boundaries
- [x] Update the one log line at `player_unit.gd:268-271` (its "impassable rubble" wording no longer applies)
- [x] Keep the 20/40 `COVER_PENALTY_LIGHT/HEAVY` values initially — change one thing at a time
- [x] Re-check balance: cover tiles becoming passable widens `get_reachable_tiles` output
- [x] Optional: make crouch poses direction-aware, crouching toward the covered edge
- [x] Optional: tie `do_hunker` to actually having cover (today it is a flat −20 regardless)
- [x] Coordinate with Phase 8 — cover becomes authored props under Q5

### Phase 7a — Ambient light fix · **Low** (do right after Phase 1, not gated on Q5)

Per §2.7.1. Independent of baking, so it need not wait for Phase 8.

- [x] `main.tscn`: `ambient_light_energy` `1.0` → `0.10`, keeping `Color(0.5, 0.52, 0.58)`
- [x] `lighting_manager.gd`: `AMBIENT_FLOOR` `0.0` → `8.0`, so the rules match the visible ambient
- [x] Delete the Sun `DirectionalLight3D`, or drop it to `0.05` with `shadow_enabled = false`
- [x] Replace the `TESTING:` comment with a rationale comment in the house style
- [x] Re-check that unlit tiles stay below `sight_light_threshold = 25.0` — the stealth design depends on it
- [x] Judge all three values on screen **after** the ortho camera is in; they are not measured

### Phase 7b — Baked lighting · **High** (Q5 = yes; sequenced after Phase 8)

- [ ] Split fixtures into a bakeable static layer and keep flashlights realtime
- [ ] Ensure authored modules carry UV2 for lightmapping
- [ ] Add `LightmapGI` and bake against instanced module geometry
- [ ] Verify `LightingManager`'s per-tile `light_value` still agrees with what's on screen (the `aimed_light.gd` principle: screen must not disagree with rules)
- [ ] Re-evaluate volumetric fog / glow / beam shader at the new camera distance

### Phase 8 — Map module pipeline · **High** (Q5 = yes, no longer gated)

- [ ] Add a module/prefab table to `MapBuilder` mapping terrain+feature → `.glb` `PackedScene`
- [ ] Replace `_add_wall` / `_add_platform` / `_add_cover` / `_add_floor_quad` primitives with instanced modules
- [ ] Preserve the existing collision-layer scheme (1 = geometry, 2 = units, 4 = cover) exactly — LOS and lighting depend on it
- [ ] Keep `_wall_meshes` (or its successor) populated — the occlusion pass depends on being able to reach each wall's visual node
- [ ] Document `TILE_SIZE = 1.5` / `FLOOR_HEIGHT = 3.0` as the Rhino/Blender authoring contract
- [ ] Keep `MapData` and `MapGenerator` engine-free (their headless-fuzzing property is worth protecting)

### Phase 9 — Documentation · **Low** (Q8 = supersede, don't amend)

- [x] Write a new presentation/camera design doc as the source of truth for the iso direction
- [x] Mark GDD §10.2 (free camera), §1's "Perspective" bullet, and §10.6 (per-unit LOS render gating, now superseded by Q12's room rule) as **SUPERSEDED**, each pointing at the new doc — do not rewrite them in place
- [x] Update `art-direction.md` — its "camera distance changes the art calculus" argument now resolves, its 3D-model tri/material budget is superseded by sprites, and its move-speed open question is closed by Q6 (staying at 4.5)
- [x] Delete `docs/mixamo-pipeline-plan.md` with the rest of the 3D pipeline (Phase 5a)

---

## 4. Fundamentally incompatible systems

**None found.** Explicitly checked and clear:

- No first-person or over-the-shoulder mode
- No camera-relative aiming — `fire_at` takes a target `Unit`, and facing comes from
  `face_toward(target.global_position)`, i.e. world space
- No mouse-look, no WASD character movement
- No physics-driven gameplay (no rigid bodies, no character bodies, every `collision_mask = 0`)
- No skybox, no dynamic FOV, no camera collision

**Resolved by the Q4–Q12 answers — all of these are now deletions, not discussions:**

| System | Outcome |
|---|---|
| **Vertical aiming** ([aim_pitch.gd](scripts/aim_pitch.gd)) | **Deleted** (Q7 + Q9). Substantial measured work — bore-aiming to 0.3° — that a sprite has no spine to express. Multi-floor shots will read flatter. Recoverable later as per-pitch-band arm/weapon layers; see Q14. |
| **Weapon mount** ([weapon_mount.gd](scripts/weapon_mount.gd)) | **Deleted** (Q7). Solves a problem sprites don't have. |
| **Deceleration system** (`RUN_STOP_CURVE`, `_decelerate_to`, `_slide`) | **Deleted** (Q7). Careful clip-driven foot-skate elimination, made moot by sprites. |
| **Move speed** | **Stays 4.5 m/s** (Q6). Closes `art-direction.md`'s open question. |
| **Cover system** | **Being reworked** (Q11), scope pending Q13. Phase 6b. |
| **Flashlight beam shader** | **Kept**, needs re-evaluation at the new camera distance. The flashlight is a detection mechanic, not character art. |
| **`aimed_light.gd`** | **Kept but simplified** (Phase 5a). It already takes orientation from the unit and only position from a helmet bone, so it becomes a fixed offset. |

---

## 5. Open questions

**Q1–Q12 are all resolved** (2026-07-30) — see the decisions log at the top for the answers and
their consequences. They are kept here, marked, rather than renumbered, so existing references
stay valid. **Q13 and Q14 are new and open.**

- **Q1 — Sprite node type.** ✅ **RESOLVED 2026-07-30 → `Sprite3D` / `AnimatedSprite3D`.** The
  spec's `CharacterBody2D` + `AnimatedSprite2D` cannot be positioned in or depth-sorted against
  a 3D world. Every other part of the sprite spec carries over unchanged. See §2.6.
- **Q2 — Camera yaw.** ✅ **RESOLVED 2026-07-30 → keep 90° snap rotation.** Costs no extra art
  (buckets shift by whole steps) and softens wall occlusion. Adds the requirement that sprite
  direction re-buckets on camera yaw change. See §2.1, §2.6.
- **Q3 — Ambient light.** ✅ **RESOLVED 2026-07-30 → dark ship confirmed; fix is not the
  commented `0.015`.** Proposed values in §2.7.1: ambient `0.10`, `AMBIENT_FLOOR` `8.0`, Sun
  deleted. Tune on screen after Phase 1.
- **Q4 — Wall occlusion approach.** ✅ **RESOLVED → placeholder implemented** (§2.4.1). The
  choice between lowered walls / per-room culling / dither-fade is deferred to Phase 4 proper,
  now that the camera is usable in the meantime.
- **Q5 — Do map visuals become authored `.glb` modules?** ✅ **RESOLVED → yes.** Unblocks
  Phase 7b and Phase 8. Nothing in the plan is blocked any more.
- **Q6 — Move speed.** ✅ **RESOLVED → no, stays 4.5 m/s.** Closes the open question in
  `art-direction.md`; sprite cadence is authored against 4.5.
- **Q7 — Do 3D characters survive anywhere?** ✅ **RESOLVED → no.** Becomes Phase 5a, and
  simplifies Phase 5b to a rewrite rather than an abstraction.
- **Q8 — Is the GDD the source of truth?** ✅ **RESOLVED → supersede with a new doc**, marking
  the affected GDD sections rather than rewriting them.
- **Q9 — Vertical aiming.** ✅ **RESOLVED → no for now**, may return with the multi-arm layer
  plan. `aim_pitch.gd` goes with the rig; if it returns it will be per-pitch-band sprite
  variants on an arm/weapon layer, not a bone solve, so nothing is foreclosed. See Q14.
- **Q10 — `Label3D.fixed_size` under orthographic.** ✅ **DISSOLVED → zoom removed entirely.**
  With one fixed `Camera3D.size` there is no zoom-dependent sizing left to verify.
- **Q11 — Sprite vs. 3D depth interaction.** ✅ **RESOLVED → the cover system needs reworking.**
  Scope undefined, so this hands off to Q13 and Phase 6b.
- **Q12 — Enemy render gating.** ✅ **RESOLVED → render sprites only in rooms containing a
  player character.** Room granularity rather than GDD §10.6's per-unit LOS. Requires Phase 3a.
  Raises Q14.

- **Q13 — What does the cover rework actually change?** ✅ **RESOLVED → handle it like XCOM:
  edge-based cover.** Full design in §2.10, tasks in Phase 6b.
- **Q14 — Do unseen units leak through the log?** ✅ **RESOLVED → accepted; the log is being
  removed once the game runs smoothly.** The substantive half — that unseen units burn wall-clock
  time because turn resolution awaits animations — is handled by fast-forwarding them through the
  existing `_instant` path (§2.11, Phase 6a).

### Still open

- **Q15 — What is the "multi-arm plan"?** From Q9's *"maybe... with multi arm plan it could
  change"*. I have read this as **independently-posed arm layers** added to the sprite layer set,
  which is what would make vertical aiming expressible again without a bone solve. Worth
  confirming before Phase 6 fixes the layer set at four (body/head/helmet/weapon) — adding a
  fifth layer later is cheap in code but expensive in already-drawn art.
