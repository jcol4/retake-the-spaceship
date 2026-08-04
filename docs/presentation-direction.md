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

Levels are real 3D geometry. Characters are hand-drawn 2D sprites composited into that
world as `Sprite3D`s, so they depth-sort against and are occluded by the architecture.
This is the Divinity / Fallout approach rather than a pure 2D one, and the reason is
depth: a canvas-space `AnimatedSprite2D` cannot hold a position in a 3D world at all.

The camera is **orthographic, at a fixed pitch, with four snapped yaws**. Nothing about
it is free.

| Property | Value | Where |
|---|---|---|
| Projection | Orthographic | `scenes/camera_rig.tscn` |
| Pitch | `atan(1/√2)` ≈ 35.264°, fixed, no input | `camera_rig.gd` `PITCH` |
| Yaw | 45° / 135° / 225° / 315°, Q and E step between them | `camera_rig.gd` `SNAP_STEP` |
| Zoom | **None.** One fixed `Camera3D.size` of 12 — a 1.92 m character is 16% of viewport height, inside `character-art-plan.md`'s 15–20% reference band | `camera_rig.tscn` |
| Pan | WASD, camera-relative, unchanged from before | `camera_rig.gd` `_process` |

**Why 35.264° specifically.** At that pitch a world-space square projects to a 2:1
diamond. That is a contract with the art, not a preference: the sprites are drawn
against that proportion, so changing the pitch invalidates the character art.

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
    ├── Body   (AnimatedSprite3D)
    ├── Head   (AnimatedSprite3D)
    ├── Helmet (AnimatedSprite3D)
    ├── Weapon (AnimatedSprite3D)
    ├── LightMount (Marker3D)
    └── Flashlight (AimedLight) -> Beam
```

The layer set is **data-driven** (`UnitVisual.layers`), not four hardcoded nodes. The
alien has three layers and the swarm two, and if vertical aiming returns as
independently-posed arm layers it must cost art and nothing else. That question is still
open; the exported array is what keeps it cheap to answer either way.

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

**5 drawn + 3 mirrored.** Only `n, ne, e, se, s` are authored. `nw, w, sw` are those
flipped horizontally. A pose where flipping is wrong — anything armed, where the rifle
would end up on the wrong shoulder — may be authored for all eight instead: art for a
mirrored direction wins over the mirror table automatically. That is the path the merc
takes, so its sets are 8 directions × 18 poses = 144 animations per layer.

### The pivot contract

Every layer shares `pixel_size` and `offset`, and the art's origin is the **feet**, not
the canvas centre. That is what makes a gear swap a one-line `set_variant` call: new art
lands exactly where the old art was. Break it and helmets drift off heads.

### Lighting

Sprites are `UNSHADED` and tinted from their tile's `light_value`, rather than lit by the
scene lights. Two reasons, and the second is the important one:

1. Realtime lights fight hand-painted shading.
2. `light_value` is the same number `Combat.light_modifier` and alien detection read. A
   unit that **looks** dark is therefore one the rules also treat as dark. This is the
   principle `aimed_light.gd` was written to defend, applied to characters.

### No authored art yet

`UnitVisual` draws its own placeholder per layer, pose and direction — readable enough to
judge direction, layering and lockstep by eye. Dropping real `SpriteFrames` into
`assets/sprites/[part]_[variant].tres` replaces it silently.

Two **styles** of placeholder, selected by `placeholder_style`: `organic`, the standing biped
everything started as, and `machine` for the security robots — rectangles only, no discs, no
taper, in cold greys against the organic set's warmer palette. The point is not that the
stand-in looks good; it is that faction reads off silhouette and colour at 16% of viewport
height in a dark corridor, which is the condition the real art has to survive too. Testing that
against a placeholder that ignores it would be testing nothing.

Action *timing* does not change when that happens. Without authored art, actions resolve
on `FALLBACK_TIME` — the measured clip lengths from the 3D pipeline that preceded this,
kept because they are what the game's turn rhythm was tuned against.

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
