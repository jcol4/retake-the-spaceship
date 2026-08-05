# Presentation direction — isometric camera and sprite characters

**Source of truth for how the game is drawn.** Supersedes `game-design-document.md`
§10.2 (free orbit camera), §1's "Perspective" bullet, and §10.6 (per-unit LOS render
gating). Those sections are marked SUPERSEDED in place and point here; they were left
standing rather than rewritten so the reasoning that produced them stays readable.

Implemented 2026-07-30, from `MIGRATION_PLAN.md`. Phases 8 (`.glb` map modules) and 7b
(baked lighting) are **not** done — they are gated on art that does not exist yet, and
the plan's task lists for them still stand.

---

## 1. The shape of it

Levels are real 3D geometry. Characters are 2D sprites composited into that world as
`Sprite3D`s, so they depth-sort against and are occluded by the architecture. This is the
Divinity / Fallout approach rather than a pure 2D one, and the reason is depth: a
canvas-space `AnimatedSprite2D` cannot hold a position in a 3D world at all.

The sprites are **prerendered from a rigged 3D character**, not hand-drawn — see §2.1. That
was an open choice when this document was first written and it is now settled; wherever the
older text said "hand-drawn", the substance survives unchanged, because nothing downstream of
the PNG cares how the PNG was made.

The camera is **orthographic, at a fixed pitch, with four snapped yaws**. Nothing about
it is free.

| Property | Value | Where |
|---|---|---|
| Projection | Orthographic | `scenes/camera_rig.tscn` |
| Pitch | `atan(1/√2)` ≈ 35.264°, fixed, no input | `camera_rig.gd` `PITCH` |
| Yaw | 45° / 135° / 225° / 315°, Q and E step between them | `camera_rig.gd` `SNAP_STEP` |
| Zoom | **None.** One fixed `Camera3D.size` of 10.5 — a 1.92 m character is 14.9% of viewport height, at the bottom of `character-art-plan.md`'s 15–20% reference band. See the cosine note below | `camera_rig.tscn` |
| Pan | WASD, camera-relative, unchanged from before | `camera_rig.gd` `_process` |

**Why 35.264° specifically.** At that pitch a world-space square projects to a 2:1
diamond. That is a contract with the art, not a preference: the sprites are rendered from
a camera set to that pitch, so changing it invalidates the character art outright — not
"looks slightly off", but every sprite drawn from the wrong angle.

**Why 10.5 and not 12, and why the old 16% figure was wrong.** `Camera3D.size` is the
vertical *world* extent on screen, so a character's share of viewport height is
`height / size` — exact under orthographic, at any resolution. The trap is that the
relevant height is not the character's: an upright figure seen at `PITCH` is foreshortened,
and occupies `1.92 × cos(35.264°) = 1.568 m`. The original 12 came from `1.92 / 12 = 16%`,
which omits that cosine; the true figure at 12 is **13.1%**, under the band rather than
inside it. `1.568 / 10.5 = 14.9%` puts it back.

The 16% *was* right for the code placeholder, which is drawn filling its canvas and is
therefore foreshortened by nothing. It stopped being right the moment rendered art landed —
which is exactly the class of error that survives review, because both numbers are correct
arithmetic on the wrong quantity. `render_sprites.py` `GAME_CAMERA_SIZE` mirrors 10.5 and
`report_framing` prints the whole derivation at render time, so the next person to change it
is told what they changed.

Growing `CANVAS_HEIGHT` instead would have been the wrong lever: it draws characters above
true world scale, and they have to stand in doorways and behind crates modelled at true scale.

**Why the yaw snaps rather than being fixed.** A fixed camera makes every room corner
permanently unviewable. Four yaws give the player a way to look behind something without
reintroducing free orbit — and it costs no additional art, because a quarter turn moves
the eight sprite direction buckets by exactly two whole steps. A *whole number* of steps
is the property that matters; the count follows from 90° ÷ 45°.

**Why the start yaw is 45° and not 0°.** This is the load-bearing number for the whole
direction system, and it is easy to mistake for an aesthetic choice. At 45° the four
*world* grid axes project to the four *screen* diagonals — a unit facing world −Z reads
as up-and-right, not straight up — and the four world diagonals fill in the screen
cardinals. Units may move and face along all eight, so the eight drawn directions are
exactly the eight reachable ones, and the set is closed under a camera snap. At a start
yaw of 0° the same eight directions would land rotated 45°, which is a different art set
and a flatter read.

**Why zoom went entirely.** Under orthographic projection, camera distance no longer
changes apparent scale, so zoom would have had to become `Camera3D.size`. One scale is
simpler, and it also dissolved a question about `Label3D.fixed_size` behaviour that only
existed because zoom did.

---

## 2. Sprite characters

```
PlayerUnit (Node3D)          -- grid_pos and yaw, unchanged
└── Visual (UnitVisual)      -- builds everything below in code
    ├── Body   (AnimatedSprite3D)   -- the whole figure, head and helmet painted in
    ├── Arm    (AnimatedSprite3D)   -- the rifle arm
    ├── LightMount (Marker3D)
    └── Flashlight (AimedLight) -> Beam
```

The layer set is **data-driven** (`UnitVisual.layers`), not four hardcoded nodes. The
default is `body, head, helmet, weapon`; the alien has three, the swarm two, and the merc
has **two — `body` and `arm`**. Adding or dropping one must cost art and nothing else, and
the exported array is what keeps that true.

**Why the merc flattened to two.** Once the sprites are rendered rather than drawn (§2.1),
separate head and weapon layers stop buying anything and start costing something: the
renderer resolves self-occlusion between the rifle, the arms and the torso correctly and for
free, and slicing that render back apart into layers would be work spent to reintroduce the
seams it just solved. So the whole figure goes into `body`, and `arm` exists only because the
rifle arm has to pose independently of the gait. Fallout made the same trade for the same
reason. The cost is real and should be named: **a gear swap is now a re-render of a character
rather than a reassignment of one layer.**

One trap that follows from it. An unused layer does *not* stay empty — `UnitVisual` falls
back to the code placeholder for any layer it finds no art for, so leaving `head` in the list
paints a grey disc over the merc's face. Dropping a layer means dropping it from `layers`.

The security robots are the first character to take that promise up, and it cost exactly what
it was supposed to: they carry a `status` layer nothing else has — the diegetic alert-state
light from their
[faction identity](design/factions/security-robots/design-choices/faction-identity.md), since a
player cannot read a machine's posture off its body language the way they can an alien's.
`CerberusUnit` recolours it per state; `UnitVisual.set_status_color` is the whole interface.

That layer is also the one exception to the lighting rule below. `SELF_LIT_LAYERS` is exempt
from the tile-light tint, because a status light is the thing *emitting* — dimming it in a dark
room would put out the one readability aid the faction has in exactly the conditions it exists
for.

### 2.1 Where the sprites come from

They are **rendered, not drawn**. `tools/render_sprites.py` runs inside Blender against a
rigged character (`art_src/merc_anim.blend`), and for each named action turns the character
through the eight facings under one orthographic camera, writing a flat PNG per
pose × direction × frame.

**The camera in that script is the game's camera.** `PITCH` and `YAW` mirror `camera_rig.gd`
exactly, and that is the whole reason the pipeline is affordable:

- The character rotates; **the camera and the lights do not**. With one fixed viewpoint a
  world-fixed key light genuinely relights a unit as it turns — a soldier facing into the key
  is lit differently from one facing away, at no art cost. A rotatable camera would have
  needed 8 × 8 renders to get the same thing.
- The lighting is deliberately flat and heavily ambient-supported. Whatever is baked in
  competes with the in-game tile-light tint rather than adding to it (see Lighting below), so
  strong directional shading would read as wrong in a dark corridor.

The three constants worth knowing, all in `render_sprites.py`:

| | | |
|---|---|---|
| `CANVAS_HEIGHT` | 2.56 m | The frame's world height — **not** the character's 1.92 m. The extra is headroom for a raised rifle or a grenade wind-up, which a canvas cut to the character would clip. |
| `RESOLUTION` | 256 px | Makes 1 px = 1 cm exactly. A free choice: the game derives `pixel_size` from the PNG, so dropping to 96 or 128 for chunkier pixels needs no Godot-side change. |
| `FLOOR_MARGIN` | 0.45 m | Floor kept *below* the world origin, and the reason the origin is not on the bottom edge. |

`FLOOR_MARGIN` is the one that is not obvious. **The floor is not a horizontal line in this
frame.** Under the tilted camera a floor point projects to screen height
`0.4082 × (y − x)`, so the bottom edge of the frame corresponds to the floor *diagonal*
running toward the camera — and a character straddles the origin, so whichever foot is
forward falls off-frame. Measured: 8.4 px of 256 for a standing rest pose, 19.1 px at a
0.45 m run stride, on a character only ~157 px tall. 0.45 m of margin clears both, and it is
cheap, spending half the dead space that was above the head anyway.

The output filename is the contract:

```
[layer]_[variant]_[pose]_[dir]_[frame].png      e.g. body_merc_run_se_3.png
```

`tools/build_sprite_frames.gd` is the only thing that reads it, collecting the loose PNGs
into one `SpriteFrames` per layer at `assets/sprites/[layer]_[variant].tres`. Hand-writing
those is not viable — a character is 20 poses × 8 directions × N layers — and it must be
**rerun after every render**, since it is a build step and not a watcher.

Two properties of that step matter beyond convenience:

- **Frame count never affects timing.** Each animation's `speed` is set to
  frames ÷ the duration the pose is supposed to occupy, so a run drawn in 8 frames and one
  drawn in 12 both take 0.666 s. Chunkiness is an art dial (`--fps`), not a timing one. The
  merc's `idle` is 24 frames over 2.0 s and its `run` is 12 over 0.666 s, and neither number
  is load-bearing.
- **Missing art degrades to the nearest thing that exists**, never to nothing: the exact
  pose+direction, else the same pose in any direction (facing wrong, action right), else
  anything at all. This is what lets a half-rendered character run without a layer resolving
  to empty and hiding itself mid-turn.

`run` is the one duration that is forced rather than chosen. `UnitVisual` emits a footstep
every `FOOTSTEP_GAP` (0.333 s), so a two-step cycle must occupy 0.666 s or the sound drifts
off the footplant — and `FOOTSTEP_OFFSET` is 0.0, which is the authoring contract that
follows: **frame 0 is a contact**, and so is the frame at the halfway point. Prefer sampling
rates that divide the cycle into an even number of frames, or the second contact lands
between frames and the cadence limps.

`tools/make_sprite_gif.py` renders one looping GIF per direction at the cadence the game will
actually play, for review only. The seam where the last frame meets the first is the frame
most likely to be wrong and the one a contact sheet cannot show. It carries its own GIF
encoder because this machine has no ffmpeg, no ImageMagick and no PIL, and a review artefact
did not justify a dependency.

### Direction

Sprite direction is **unit yaw minus camera yaw**, quantised into eight 45° buckets,
offset so each bucket is *centred* on a drawn direction rather than straddling two.
Subtracting the camera is what makes the snap work, and it adds one requirement: a snap
changes every character's apparent facing without any unit having turned, so
`_sync_direction` is driven by the rig's `yaw_changed` signal as well as by unit facing.

**The eight directions are `ne, n, nw, w, sw, s, se, e`.** They are named for where they
point *on screen*, and the 45° rig inverts what you would expect: the four **world grid
axes** project to the four **screen diagonals**, and the four world diagonals project to
the screen cardinals. So a unit facing world −Z reads as `ne`. Bucket 0 is up-right and
the index rises anticlockwise on screen. `tools/test_sprite_direction.gd` pins that
mapping down; it is exactly the kind of thing that looks plausible in a screenshot and is
obvious in a table.

**Two invariants keep this honest, and both are enforced in code:**

1. Movement is eight-way — `GridManager.STEPS` has exactly eight entries, matching the
   eight drawn directions one-for-one, so a walked path can never produce a yaw with no
   art behind it.
2. Facing is quantised — `Unit._yaw_toward` snaps to 45°, because the Face action is
   driven by a raw mouse click and would otherwise hold a yaw between two drawn
   directions. A unit in that state has **no art at all** and the sprite layer hides
   itself, which is why this is a hard requirement and not a polish item.

**5 drawn + 3 mirrored, or all 8.** The cheap path authors only `n, ne, e, se, s` and gets
`nw, w, sw` by flipping horizontally — the `MIRROR` table. It is wrong for any pose that is
not symmetric: mirroring an armed character moves the rifle to the wrong shoulder. Such a
character may be authored for all eight instead, and no flag says so — `_resolve` prefers art
for the direction itself and only falls back to the mirror table, so authoring the mirrored
direction is how you opt out.

**The merc takes the all-eight path**, because it carries a rifle. That is why
`render_sprites.py` renders eight facings and not five, and why the turntable is nearly free:
the character rotates while the camera and key light hold still, so a facing costs one render
and nothing else. Full coverage is 8 directions × 20 poses = **160 animations per layer**.
The code placeholder deliberately generates only the five, so the mirror table stays genuinely
exercised rather than bypassed everywhere.

### The pivot contract

Every layer resolves to the same world height with its origin at the **feet**, not the canvas
centre. That is what makes a gear swap a one-line `set_variant` call: new art lands exactly
where the old art was. Break it and helmets drift off heads.

Two exported properties carry it, and `_apply_frame_scale` derives both **per layer from that
layer's own texture size** — so a 256 px rendered sheet and the 64 px code placeholder
composite against each other with nothing rescaled by hand:

| | Placeholder | Rendered art (merc) |
|---|---|---|
| `canvas_height` | 1.92 m — canvas cut to the character | **2.56 m** — must equal `render_sprites.CANVAS_HEIGHT` |
| `foot_anchor.y` | 1.0 — feet flush to the bottom edge | **0.82421875** = `1 − FLOOR_MARGIN / CANVAS_HEIGHT` |

The defaults on `UnitVisual` describe the placeholder; a character with rendered art
**must override both on its scene** (`scenes/player_unit.tscn` does). Rendered art cannot use
the placeholder's values for the reason in §2.1 — the floor projects to a diagonal, so the
origin sits `FLOOR_MARGIN` above the bottom edge rather than on it. Get the anchor wrong and
every unit of that variant floats or sinks by the difference, uniformly and quietly.
`render_sprites.report_framing` prints the two values to paste in.

### Lighting

Sprites are `UNSHADED` and tinted from their tile's `light_value`, rather than lit by the
scene lights. Two reasons, and the second is the important one:

1. Realtime lights fight the shading already baked into the render.
2. `light_value` is the same number `Combat.light_modifier` and alien detection read. A
   unit that **looks** dark is therefore one the rules also treat as dark. This is the
   principle `aimed_light.gd` was written to defend, applied to characters.

This is also why the render lighting in §2.1 is kept flat: it is competing with the tint, not
adding to it.

### 2.2 The pose vocabulary

Twenty poses, and every one of them is a Blender action name, a PNG filename fragment and a
`SpriteFrames` animation prefix — the same string end to end, which is what stops any of the
three drifting. The list is spelled out identically in `unit_visual.gd` `PLACEHOLDER_POSES`,
`build_sprite_frames.gd` `POSES` and `render_sprites.py` `POSES`; that triplication is
deliberate, because a `--script` tool that names `UnitVisual` compiles it, and `unit_visual.gd`
reads autoloads that are not registered at tool-compile time.

| Kind | Poses | How it ends |
|---|---|---|
| **Stances** | `idle`, `run`, `walk`, `crouch_idle`, `overwatch_hold` | Loop until something changes them |
| **Firing** | `aim_hold`, `begin_shoot`, `fire_shoot`, `end_shoot` | Driven by `play_burst`, not one animation per shot type |
| **Transitions** | `run_stop`, `stand_to_crouch`, `crouch_to_stand` | One-shot bridging one stance into another |
| **Actions** | `melee`, `reload`, `throw_grenade`, `interact`, `hit_react`, `downed`, `alert_scream` | One-shot, then back to the stance |
| **Scenery** | `idle_fidget` | Slipped in at random while `idle` holds; nothing may ever await it |

**Firing is three phases plus a hold, not one animation per shot type**, because burst length
is rolled per shot and no fixed animation can match a count it does not know. `begin_shoot`
brings the rifle up once, `fire_shoot` is one round's kick replayed from frame 0 per round,
`end_shoot` lowers back out of it, and `aim_hold` is the fallback each phase degrades to.

Each phase must be authored to the timer that drives it, because `play_burst` waits that long
regardless of what the art does — a phase authored longer is cut off, one authored shorter
freezes on its last frame:

| Pose | Length | Constant |
|---|---|---|
| `begin_shoot` | 0.45 s | `RAISE_TIME` |
| `fire_shoot` | 0.11 s | `BURST_CADENCE` — the tight one. It is *restarted* every cadence, so anything past 0.11 s of it is never seen |
| `end_shoot` | 0.20 s | `SETTLE_TIME` |

Those three numbers appear in `unit_visual.gd`, `build_sprite_frames.gd` `ONE_SHOT_TIME` and
`render_sprites.py` `ONE_SHOT_TIME`, and are commented as a set in all three.

Missing art degrades differently per kind, and the differences are deliberate:

- A missing **action** still costs its `FALLBACK_TIME`, so turn pacing is identical before and
  after the art lands.
- A missing **transition** costs *nothing* and degrades to a hard cut — otherwise every move
  in the game would pause mysteriously until `run_stop` was drawn.
- A missing **firing phase** falls back to `aim_hold` for the same beat, and each phase
  degrades independently: a character with only `fire_shoot` still fires, it just cuts to the
  kick and back.

### 2.3 Placeholder art, for everything not yet rendered

`UnitVisual` draws its own stand-in per layer, pose and direction, in code rather than as
shipped PNGs — so there is nothing to mistake for real art later and nothing to delete when
the real art lands. It is readable enough to judge direction, layering and lockstep by eye.
Dropping real `SpriteFrames` into `assets/sprites/[layer]_[variant].tres` replaces it silently,
per layer: the merc's `body` and `arm` are rendered while every other character is still a
placeholder, and the two coexist with no switch anywhere.

Two **styles**, selected by `placeholder_style`: `organic`, the standing biped everything
started as, and `machine` for the security robots — rectangles only, no discs, no taper, in
cold greys against the organic set's warmer palette. The point is not that the stand-in looks
good; it is that faction reads off silhouette and colour at ~15% of viewport height in a dark
corridor, which is the condition the real art has to survive too. Testing that against a
placeholder that ignores it would be testing nothing.

Action *timing* does not change across the swap. Without authored art, actions resolve on
`FALLBACK_TIME` — the measured clip lengths from the runtime-3D pipeline that preceded this,
kept because they are what the game's turn rhythm was tuned against.

### 2.4 What is actually rendered today

| Variant | Layer | Poses | Directions |
|---|---|---|---|
| `merc` | `body` | `run` | all 8, 12 frames each |
| `merc` | `body` | `idle` | `n`, `ne`, `nw`, `se`, `sw` — `e`, `s`, `w` missing |
| `merc` | `arm` | `idle`, `run` | `sw` only |
| everything else | — | — | code placeholder |

Two of nineteen poses, then. The gaps are covered by `build_sprite_frames.gd` `_pick` rather
than being holes — the arm falls back to its `sw` art in all eight directions, and every
unrendered pose falls back to `idle` — so the game runs and reads, it just reads wrong in
those places. Combat is the worst of it: all four firing poses are placeholder, which is why
they head the outstanding list in the README.

Seven `idle` frames (`n` 18–23, `nw` 5) came out of Blender truncated — no `IEND` chunk — and
were removed rather than shipped, because Godot's importer rejects them and the whole
`SpriteFrames` build fails on the first one. Those two directions want a re-render.

---

## 3. Wall occlusion

The one genuinely new system. A camera that cannot be orbited past a bulkhead would leave
the near-side walls of every compartment permanently between the player and the room.

A wall is hidden when **both**:

1. the cell one step further from the camera is walkable floor — that set is exactly the
   near-side boundary of each compartment, and a wall backed by another wall or by the
   void outside the hull is far-side structure that must stay up or the deck opens onto
   nothing; **and**
2. that floor belongs to a **revealed** region — one holding a player unit, or a corridor
   joined to one.

Rule 2 is what makes it read as the squad's own field of view rather than as x-ray: an
empty room has no interior worth opening, so the far side of the deck stays sealed.

Walls fade rather than cut, over `OCCLUSION_FADE`. Two shared materials carry the fade
rather than one per wall — a yaw snap moves every wall at once, so at most two alphas are
ever in flight.

**Only the mesh is hidden.** Collision stays live, because line of sight and lighting
occlusion both raycast layer-1 geometry: a wall you can see past must still be one you
cannot shoot through.

---

## 4. Render gating and pacing

Unit sprites are drawn **only in rooms holding a player unit** (`MapBuilder`
`_apply_unit_visibility`). This is deliberately coarser than the per-unit LOS raycast the
GDD's §10.6 specified: a room is a piece of space the player can hold in their head,
where a per-unit ray gives a flickering set with no shape.

The half that matters more is pacing. Turn resolution `await`s animations, so an unseen
enemy would otherwise burn its full wall-clock time against a static screen. An undrawn
unit reports `Unit.is_instant()` and fast-forwards instead — reusing the path the
headless smoke test already used rather than inventing one.

Two things this has to get right, both covered by `tools/test_room_visibility.gd`:

- **Visibility is re-read per tile during a move**, so a unit walking into view animates
  the *rest* of its move instead of popping across the deck. At that handover the stance
  is re-asserted from the top rather than joining a one-shot already in progress.
- **Fast-forwarding must not skip the per-tile work**, overwatch above all. A reserved
  shot that silently fails to fire is a rule quietly not applying.

The combat log still narrates fast-forwarded units. That leak is accepted: the log is
slated for removal, so suppressing it would be work spent on something being deleted.

---

## 5. Cover is edge-based

Cover is a property of a tile **boundary**, not of a tile. A unit stands *on* the tile and
is protected from directions whose edge carries cover — the XCOM model. See
`MIGRATION_PLAN.md` §2.10 for the full argument; the short version:

- **Sprite sorting is fixed by construction.** A prop on a boundary is never
  depth-coincident with a unit at a tile centre, so ordering is consistent at every yaw.
  Partial occlusion then becomes *desirable*: at 35° a 1.0–1.4 m prop on the near edge
  crosses the sprite's legs and clears its head, and that silhouette **is** the "in cover"
  read, for free.
- **The 60° flank heuristic is gone.** Cover direction is discrete, so the test is the
  sign of the shooter's offset on each axis. A diagonal shot crosses a corner rather than
  an edge, so both adjacent sides are tested and the stronger applies.
- **Floor area is reclaimed.** Cover tiles are passable now, which widens
  `get_reachable_tiles` output — a real balance shift, not just a refactor.
- **Destroyed heavy cover degrades to light**, and light to nothing. There is no tile left
  to turn into impassable rubble, and a wrecked crate is still something to crouch behind.

The 20/40 accuracy penalties are unchanged. Hunker is still a flat −20 that does not
require cover; tying them together is available and was not taken.

---

## 6. Map format

`maps/*.txt` is a grid block, optionally followed by named sections:

```
####################
#.P..#........#..E.#
####################

[cover]
8,4 E light
9,6 S heavy
```

Cover has no glyph because a per-tile grid cannot name a boundary. Only the canonical
sides `E` and `S` may be written: every edge has two names, and accepting both would let
one edge be authored twice with two different values.

Spawns *do* get glyphs: `P` player, `E` alien, `S` swarm, and one per security-robot model —
`Q` Auxilium, `M` Sagittarii, `X` Proctor, `J` Securus. The robots are per-type where the
aliens are per-kind because a security roster is placed deliberately (this doorway gets a
sentry, that hall gets the heavy) where an infestation is placed in bulk. Letters come from the
model codes rather than the names, since the names collide with glyphs already taken.

**Rooms are not stored.** They are derived from the layout by `MapData.compute_rooms`, so
they cannot drift out of sync with it. The rule is the one a ship deck is actually built
to: find the **bulkhead lines** (rows and columns that are mostly wall), then flood-fill
between them. Walkable cells sitting *on* a bulkhead line are doorways; they flood into
regions of their own and become corridors, linked to every region they touch. A plain
flood-fill of walkable space would merge every compartment on any deck with a doorway in
it, which is every deck.

`tools/test_map_roundtrip.gd` asserts the format still round-trips byte-identically, and
that the decomposition of `test_deck.txt` is the expected three rooms and two doorways.

---

## 7. Lighting

Entirely realtime still — baking (`LightmapGI`) needs authored `.glb` module geometry that
does not exist yet, and is Phase 7b.

- Ambient `0.2`, judged on screen against `0.1` and `0.25` once the ortho camera was in.
  Ambient now governs **only** whether architecture silhouettes read, because character
  legibility decoupled from it when sprites went `UNSHADED`.
- `LightingManager.AMBIENT_FLOOR` `12.0`, moved up with it. The two are a pair; the screen
  showing more than the rules admit is exactly the failure being avoided.
  `EnemyUnit.sight_light_threshold` (25.0) is the hard ceiling — at or above it an unlit
  tile stops hiding anyone and the stealth design goes with it.
- **The Sun `DirectionalLight3D` is deleted.** There is no sun inside a hull, and a
  directional shadow map over an interior costs real frame time for a meaningless read.

---

## 8. What is gone

The entire 3D character pipeline, with no survivors: Mixamo FBX sources, `build_anims.py`
and its ten sibling scripts, `character_base.tscn`, the soldier/swarm/rifle GLBs and their
textures, `aim_pitch.gd`, `weapon_mount.gd`, the measured `RUN_STOP_CURVE` deceleration
system, and the rig-specific debug tools.

Two of those represent careful measured work that a sprite cannot use: bore-aiming solved
to 0.3°, and a foot-skate-free deceleration driven off a clip's own travel curve.
Multi-floor shots read flatter now. That was the accepted cost of the direction change,
not an oversight — it is recorded here so it is not rediscovered as a bug.

`aimed_light.gd` and `flashlight_beam.gd` were **kept**. The flashlight is a detection
mechanic, not character art. It hangs off a fixed offset on the unit now instead of a
helmet bone.

---

## 9. Tools

### Checks

| Tool | Checks |
|---|---|
| `tools/test_map_roundtrip.gd` | text round-trip, spawns, stairs, edge cover, room graph |
| `tools/test_iso_picking.gd` | mouse picking at all four yaws, pan basis follows the snap |
| `tools/test_edge_cover.gd` | cover direction, diagonals, degradation, passability |
| `tools/test_sprite_direction.gd` | bucket mapping, mirror rule, snap re-bucketing |
| `tools/test_movement.gd` | 8-way adjacency, uniform diagonal cost, the corner-cutting guard |
| `tools/test_room_visibility.gd` | render gating, fast-forward, overwatch survives it |
| `tools/test_cerberus.gd` | the security-robot faction's rules, against the built deck |
| `tools/_debug_occlusion.gd` | prints hidden walls as ASCII at all four yaws |

All but `test_room_visibility.gd` run headless; that one needs a window, because headless
would make `is_instant()` answer the trivial question instead of the interesting one.

### The sprite pipeline

| Tool | Runs in | Does |
|---|---|---|
| `tools/render_sprites.py` | Blender | `--setup` writes the camera/light rig to animate into; otherwise renders a `.blend` to `assets/sprites/*.png`. Source of the framing constants in §2.1 |
| `tools/stage_merc_for_render.py` | Blender | Appends the rigged character + rifle into that rig and sizes it to the 1.92 m / feet-at-origin / facing-`+Y` contract |
| `tools/build_sprite_frames.gd` | Godot, headless | Collects the loose PNGs into `[layer]_[variant].tres`. **Rerun after every render** |
| `tools/make_sprite_gif.py` | Blender | Review GIFs, one per direction, at the cadence the game plays. Disposable; nothing reads them |
| `tools/preview_sprite.gd` | Godot | Contact sheets and strips of a variant's poses |

`render_sprites.py` guards the one failure that is invisible in its own output: an action that
animates the *object* transform fights the turntable and wins, producing eight identical
renders with the right file count, the right names and plausible images. It mutes such curves
and asserts the rotation survived `frame_set`, rather than trusting a comment telling you not
to key in Object Mode.

New PNGs need `godot --headless --path . --import` before `build_sprite_frames.gd` can load
them; without it every `load()` returns "No loader found for resource".
