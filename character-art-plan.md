# Character Art Plan — v2: gritty USS-operative pass

*Written against reference supplied 2026-07-26. Companion to `game-design-document.md`.*

> ## ⚠️ READ THIS FIRST — the ground under this plan moved twice
>
> **This is still a model plan, and that is once again the right kind of plan.** Two
> corrections have accumulated on top of the original text, in opposite directions:
>
> **Correction 1 (2026-07-30).** The game went isometric with 2D sprite characters, and the
> whole runtime 3D character pipeline was deleted. At that point this document was declared
> half-superseded: the palette and silhouette half survived, the mesh/rig/tooling half was
> said to describe nothing.
>
> **Correction 2 (2026-08-04) — this one puts most of it back.** The sprites turned out to be
> *rendered from a rigged 3D character*, not hand-drawn: `art_src/merc_anim.blend` posed per
> action and turned through eight facings by `tools/render_sprites.py`. See
> [`docs/presentation-direction.md`](docs/presentation-direction.md) §2.1. **There is a model
> again, and it is animated on a rig again.** A plan about mesh quality, silhouette, kit,
> materials and gait cadence therefore describes something real.
>
> What actually changed, then, is *where the model is consumed* — offline into PNGs, rather
> than at runtime — and that changes less of this document than Correction 1 assumed:
>
> | Live | Live, but re-aimed | Genuinely dead |
> |---|---|---|
> | §1.1 palette, §1.2 shape corrections, §1.3 framing (resolved — see that section), §4 the entire run rework including §4.2's foot-skate arithmetic | §2 budget (a per-frame *render* budget now, not a realtime one — see below), §3 phased mesh work (the phases hold; `tools/gen_soldier.py` that they were written against does not), §5 tooling (the tools exist now, in different form — see below) | §3's item 4 (extending `build_boxes`), Phase F's Godot-side post-processing — the sprites are `UNSHADED` and tinted by tile light, so SSAO and bloom cannot reach them |
>
> **§2's budget inverts rather than dying.** It was a realtime triangle budget; rendering is
> offline in Cycles, so triangle count is nearly free and the binding constraint is *render
> time × art volume* — 20 poses × 8 directions × N frames per character. The levers are the
> per-character layer set and the sampling rate, not the mesh.
>
> **§5's tooling mostly exists.** §5.1's frame-strip renderer is `tools/preview_sprite.gd`
> plus `tools/make_sprite_gif.py`, which is better than a strip — it shows the loop seam, the
> frame a contact sheet cannot show. §5.3's pixel-height measurement is
> `render_sprites.report_framing`, and it closed §1.3 with arithmetic. §5.2's numeric
> trajectory dump **does not exist and is now the most valuable missing tool**, for the reason
> below.
>
> **§4.2's foot-skate constraint is live again, and its dismissal was wrong.** It was closed in
> 2026-07-30's decision log on the grounds that "sprites have no stride to skate." That was
> true of hand-drawn sprites and is false of rendered ones: the rig has real feet at real world
> positions, and if they do not travel at `move_speed` the boots slide exactly as they would
> have in 3D. The numbers to hit are now fixed by the pipeline rather than open:
>
> ```
> stride_per_step = move_speed × cycle_time / 2 = 4.5 × 0.666 / 2 = 1.50 m
> ```
>
> `move_speed` stays 4.5 m/s (decided, see §4.2) and `cycle_time` is forced to 0.666 s by the
> footstep cadence, so **the two contact poses must place the feet 1.50 m apart** — and
> `render_sprites.FLOOR_MARGIN` was already raised to 0.45 m to stop a stride that size
> clipping off the bottom of frame, so the geometry is consistent with it. This is a
> measurable number on a posed rig, which is exactly what §5.2's dump would measure.
>
> **§1.3's framing is resolved but its number was wrong**, by a cosine. See the correction in
> that section. A character reads at **14.9% of viewport height at `Camera3D.size` 10.5**, not
> 16% at 12.
>
> **Item 3's outline shader stays dead**, and for a firmer reason than before: the sprites are
> `UNSHADED`, so no shader-based outline is available to them at all. Whatever outline a
> character has is baked into the render.

---

## 1. What the reference establishes

### 1.1 Palette — the current model is wrong about this

v1 is black/grey with cyan lenses. The reference is **not** monochrome. It reads as
black-plus-two-accents:

| Element | Colour | Notes |
|---|---|---|
| Suit, helmet, gloves, vest shell | Near-black, desaturated | Base. Slightly warm-shifted, not pure neutral. |
| **Chest-rig pouches** | **Olive / khaki-tan** | The dominant accent. Covers most of the chest — this is the single most identity-defining colour choice. |
| **Mask lenses** | **Red, glowing** | Currently cyan. Must change. Round, not rectangular. |
| Knee pads | Light grey | Prominent, large rounded caps. |
| Boots, lower legs | Dusty light brown-grey | Weathered/dirtied, notably lighter than the suit. |
| Rear/hip dump pouch | Olive | Matches the chest rig. |
| Overall | Brown-grey grime | Weathering pushes everything off pure black. |

The olive pouches and red lenses are what make the silhouette recognisable. Both
are missing from v1.

### 1.2 Shape corrections

- **Helmet is a rounded ballistic dome**, not a flat-topped box. Needs a faceted
  dome (8–12 sided). This is the most obvious "low-poly tell" remaining.
- **Mask has a rounded snout/muzzle** at bottom-centre — integrated filter housing,
  protruding forward and down.
- **Round filter disc on the side of the mask** (cheek/ear position), visible in the
  side view.
- **No hose.** I'd previously guessed a corrugated hose to the vest; the reference
  has an integrated filter instead. Dropped.
- **Elbow pads** present — currently absent.
- **Drop-leg holster** on the thigh with a visible pistol grip.
- **Radio + short antenna** on the upper back / shoulder.
- **Boots are taller** and heavier than v1's, with a distinct sole.
- **Knee pads much larger** and rounder than v1's flat plates.

### 1.3 Camera distance — this overturns my readability conclusion

The XCOM screenshots show characters at roughly **15–20% of viewport height**.
At 1080p that is ~160–200 px tall.

Our current default zoom puts them at **~30 px in a 700 px viewport (~4%)** — I
measured this from an in-game screenshot. **The reference camera is roughly 4×
closer than what `camera_rig.gd` currently defaults to.**

Consequences:

1. The dark-palette readability worry largely **evaporates**. At 180 px, texture,
   AO, pouch colour, knee pads and lenses all read clearly.
2. Detail investment is **worth it** — the opposite of what I concluded from our
   current zoom.
3. The flat cartoon outline shader is probably **unnecessary**. A rim light for
   grit is the better call.
4. **Action item:** retune the default zoom / pitch in `camera_rig.gd` toward the
   reference framing. Worth doing early, since every art judgement depends on it.

*Caveat: my percentages are eyeballed off thumbnails. First task next session is a
script that renders at a known resolution and counts the character's pixel height,
so we tune against a real number.*

> ✅ **DONE 2026-07-30 — and the caveat is closed with arithmetic rather than a script.**
> Under the orthographic camera the number is exact, not measured: `Camera3D.size` is the
> vertical world extent on screen, so a character's share of viewport height is
> `height / size`, at any resolution.
>
> ⚠️ **Corrected 2026-08-04: the first answer was 16% and it was wrong by a cosine.**
> The height that matters is not the character's. An upright figure seen at 35.264° is
> foreshortened and occupies `1.92 × cos(35.264°) = 1.568 m` of screen, so `size = 12` gives
> **13.1%** — *below* the reference band — and not the 16% originally computed. `size` is now
> **10.5**, for `1.568 / 10.5 = 14.9%`.
>
> The original 16% was accurate for the code *placeholder*, which is drawn filling its canvas
> and so is foreshortened by nothing. It stopped being accurate the moment rendered art landed.
> Worth dwelling on, because this is the shape of error that survives review: both figures are
> correct arithmetic, performed on the wrong quantity, and the answer landed inside a plausible
> band. It was caught only by deriving the framing a second time from the render side, where
> the cosine is unavoidable because the camera is actually tilted.
>
> `render_sprites.report_framing` now prints the whole derivation — apparent height, pixel
> height, share of viewport, and the `foot_anchor` to paste into the scene — at render time, so
> the next person to touch these constants is shown the consequence rather than trusted to
> recompute it.
>
> Pitch is fixed at 35.264° and there is no zoom control at all, so this framing cannot
> drift out from under the art. That is the point of fixing it, and it matters more now than
> it did: the sprites are *rendered from a camera at that pitch*, so a pitch change does not
> degrade the art, it invalidates it. See
> [docs/presentation-direction.md](docs/presentation-direction.md).
>
> Note what item 3 above now means: the flat cartoon outline shader is not merely
> unnecessary, it is inapplicable — sprites are `UNSHADED`, so whatever outline a character
> has is baked into the render.

---

## 2. Budget

> ⚠️ **Reframed 2026-08-04.** The mesh is now consumed *offline*, by Cycles, into PNGs. A
> realtime triangle budget therefore constrains nothing: nothing about this model is ever
> uploaded to a GPU at play time. Spend triangles freely — bevels, dome helmet, round lenses,
> real weight falloff at the joints — because the only thing they cost is render minutes, and
> those are paid once per art change rather than 60 times a second.
>
> **The budget that binds instead is art volume × render time:**
>
> ```
> images per character = poses × 8 directions × frames per pose
> ```
>
> A full character at 20 poses averaging ~10 frames is ~1,600 renders per layer. The levers
> are the per-character layer set (the merc is 2, not 4), the sampling rate (`--fps`, an art
> decision that costs nothing in game timing), and Cycles samples. Triangle count is not on
> that list.
>
> One thing the old budget was right about and still is: **mip discipline** (§3 item 11). No
> fine high-frequency noise. It turns to mush at 157 px tall just as surely as it did at
> distance in 3D, and now it also aliases against a fixed pixel grid.

*(Historical, from the realtime pipeline.)* Current: **432 tris**, 6 flat materials, no UVs,
no textures.

Target: **6,000–10,000 tris**, ~8 materials, one UV set, one texture atlas
(2048², or 1024² if it holds up). With 2–4 units on screen this is free on PC —
v1 was ~20× under budget because it was built to a stylised brief.

---

## 3. Model work, phased

### Phase A — reference-independent wins
Can be done without any further input.

1. **Bevel every edge** (~3–5 mm chamfer). Biggest single change: hard 90° corners
   are *the* signature of programmer art. Bevelled edges catch a highlight line,
   and at distance those lines are most of what the eye resolves.
2. **Faceted dome helmet** replacing the box.
3. **Tapered/segmented forms** — limbs and torso get intermediate cross-sections
   instead of single frustums, so they curve.
4. Extend `build_boxes` to emit **bevelled prisms and revolved domes/cylinders**,
   since round shapes (lenses, filter disc, helmet) are now required.

### Phase B — kit and palette
5. Rewrite `MATERIALS` per §1.1 (olive, red emissive, grey pads, dusty boots).
6. Add: elbow pads, larger knee caps, taller boots, drop-leg holster + pistol,
   rear dump pouch, radio + antenna, mask snout, side filter disc, round lenses.
7. Re-lay the chest rig as a **row of individual olive pouches** rather than two
   dark blocks.

### Phase C — texture, the main realism lever
8. **UV unwrap** (`smart_project` is adequate for this shape language).
9. **Bake AO in Cycles** into the atlas. This is the "gritty" step specifically —
   darkening every strap junction, pouch seam and crevice is most of what makes
   gear look used, and it reinforces form so it survives minification.
10. **Procedural grime layer**: broad dirt gradient rising from the boots, edge
    wear on corners, panel lines, mid-frequency noise.
11. **Mip discipline:** no fine high-frequency noise — it turns to grey mush and
    shimmers at distance. Mid-frequency detail only.

### Phase D — material response
12. Split into fabric (rough), hard plastic (semi-gloss), rubber, and **metal**
    buckles/clasps. Metal matters disproportionately at distance because its
    highlights *move as the camera orbits*, which reads as a real surface in a way
    flat albedo never does.

### Phase E — asymmetry
13. Offset pouches, gear on one side only, one strap angled. v1 is perfectly
    mirrored apart from the holster; real kit never is.

### Phase F — Godot side (independent of the mesh)
14. SSAO, subtle bloom on the lens emissive, film grain, tighter shadow filtering,
    cooler light temperature. Plausibly the largest single "vibe" lever, and it
    costs no art time.

---

## 4. Run animation rework — weighty, hunched, lumbering

### 4.1 What "weighty" means mechanically

| Lever | Change |
|---|---|
| Posture | Hips lowered ~4–6 cm; spine + chest forward lean increased well past the current 12°; head pushed forward and slightly down. Permanent hunch. |
| Cadence | Cycle from **0.80 s → 1.05–1.20 s**. Slower is heavier. |
| Vertical bob | Larger amplitude, and hips **dip sharply on contact** (impact absorption) then rise slowly on push-off. Currently the direction is right but the amplitude is tiny and the timing is even. |
| Ground contact | Longer flat-footed plant; add a **compression key just after contact** where the knee buckles and the hips settle. That settle *is* the read of weight. |
| Interpolation | **Never touched so far.** All keys are default Bézier, which floats. Contact needs ease-in (fast into the ground), then a brief hold. This is a large, cheap win. |
| Lateral sway | Hip roll + shoulder counter-roll side to side. Heavy gait shifts weight visibly. |
| Arms | Less pumping. Braced on the weapon, letting the torso and hips do the work. |
| Head | Slight lag/counter-motion against the bob. |

### 4.2 The foot-skate constraint (the part that's easy to get wrong)

Stride and cadence must match actual movement speed or the feet slide and all the
weight is lost:

```
stride_per_step = MOVE_SPEED × cycle_time / 2
```

> ✅ **RESOLVED 2026-08-04 — the constraint is live, and both of its inputs are now fixed.**
>
> This was closed once, in 2026-07-30's decision log, on the reasoning that "sprites have no
> stride to skate." **That reasoning was wrong**, or rather it was right about hand-drawn
> sprites and the sprites turned out to be rendered. A rendered character has feet at real
> world positions, and if they do not travel at `move_speed` the boots slide exactly as they
> would have in 3D — the medium changed, the kinematics did not.
>
> Neither input is a proposal any more:
>
> - **`move_speed` stays 4.5 m/s.** Decided, and it stands: halving it doubled every move
>   against a 20–40 minute mission target and bought nothing that the render pipeline does not
>   now give for free.
> - **`cycle_time` is 0.666 s**, and it is *forced*, not chosen. `UnitVisual` emits a footstep
>   every `FOOTSTEP_GAP` (0.333 s), so a two-step cycle has exactly one length available to it.
>
> ```
> 4.5 × 0.666 / 2 = 1.50 m per step
> ```
>
> **The two contact poses must place the feet 1.50 m apart.** That is a wide stride, and it is
> the direct consequence of keeping 4.5 m/s — the run is a sprint and has to be posed as one,
> which fights §4.1's "lumbering" brief and is the honest cost of that decision. Do not narrow
> the stride to make it look heavier; that is precisely the skate this section exists to
> prevent. Heaviness has to come from the other levers in §4.1 — posture, the compression key,
> interpolation, lateral sway.
>
> Corroboration that the number is real: `render_sprites.FLOOR_MARGIN` was raised from 0.25 m
> to 0.45 m specifically because a stride this size pushed the lead foot 5.2 px *past* the
> bottom of frame. The pipeline had already measured the consequence before the constraint was
> re-derived.
>
> **§5.2's trajectory dump is the missing piece**, and this is what makes it the most valuable
> unbuilt tool: 1.50 m is checkable by printing foot positions on the posed rig, and checkable
> by nothing else. By eye, a 10% skate is invisible in a still and obvious in motion.

*(Original proposal, superseded above.)* `unit.gd` currently has `MOVE_SPEED = 4.5` m/s, which
is a genuine sprint and fights the whole brief. Proposal: **MOVE_SPEED ≈ 2.4 m/s** with a
1.10 s cycle →

```
2.4 × 1.10 / 2 = 1.32 m per step
```

So the contact poses must place the feet ~1.32 m apart. That's a checkable number,
and I can verify it by measuring foot positions on the posed rig rather than
guessing. Alternative if 2.4 m/s feels too slow to play: drive
`anim.speed_scale` from actual speed so the cycle always matches.

*Note: this changes how long a move takes, so it's a gameplay-feel decision, not
purely cosmetic.*

### 4.3 Heavy stomps

> ✅ **DONE.** `UnitVisual` emits a `footstep` signal, and the timing is cleaner than this
> section proposed: rather than a `FOOTSTEP_TIME` table listing contact frames, the cadence is
> a constant — `FOOTSTEP_GAP` 0.333 s with `FOOTSTEP_OFFSET` **0.0** — and the *animation* is
> authored to match it.
>
> Inverting the dependency that way is what makes the offset zero, and the zero is the
> authoring contract: **frame 0 of the run is a contact**, and so is the frame at the halfway
> point. The offset was 0.10 while the run was a Mixamo clip, which recorded nothing about a
> soldier — only where that take's frame 0 happened to fall relative to the first footplant.
>
> The SFX and camera-shake hooks the section asks for are still unconnected; the signal is
> there for them.

Extend the existing `MUZZLE_TIME` pattern in `unit_visual.gd`: add
`FOOTSTEP_TIME` listing the two contact frames of `run`, and emit a `footstep`
signal. That gives a clean hook for footstep SFX and a subtle camera shake —
"heavy stomps in a space station" is at least half audio and impact feedback, not
just joint angles.

---

## 5. Tooling I need to build first

> **Status 2026-08-04: three of four exist, and the missing one is the important one.**
>
> | | Status |
> |---|---|
> | 1. Frame-strip renderer | ✅ `tools/preview_sprite.gd` (contact sheets and strips) and `tools/make_sprite_gif.py` (looping GIF per direction, at the cadence the game plays). The GIF is *better* than a strip for the stated purpose: the frame most likely to be wrong is the loop seam, and a strip cannot show a seam. |
> | 2. **Numeric trajectory dump** | ❌ **Still missing, and now the highest-value tool on this list.** §4.2's constraint became a hard number — 1.50 m between contacts — the moment the sprites turned out to be rendered off a rig, and a stride error of 10% is invisible in a still and obvious in motion. This is the one thing that would check it. |
> | 3. Pixel-height measurement | ✅ `render_sprites.report_framing`, which closed §1.3 — and caught the cosine error in it. |
> | 4. Candidate variants | ⚠️ Possible but unbuilt. `render_sprites.py --poses run --directions se` renders one cycle in about a minute, so the loop exists; nothing automates generating several and laying them out side by side. |

This is the answer to "how do we get you what you need." Right now I have only
verified **static poses**; I have never actually seen a clip in motion, which is
exactly why the run is the weak one.

1. **Frame-strip renderer** — render N evenly spaced frames of one clip as a
   horizontal strip. I can read a strip, so I can judge arc and timing from it.
   This is the single most important missing tool.
2. **Numeric trajectory dump** — print hip height, foot positions, and derived
   stride length per frame. Lets me verify the §4.2 constraint and confirm the hip
   dips on contact instead of floating, objectively rather than by eye.
3. **Pixel-height measurement** — render the game at a known resolution and report
   the character's height in pixels, to tune the camera against §1.3.
4. **Candidate variants** — generate 3–4 run cycles with different weight/cadence
   settings, render each as a strip, and you pick. Given how hard motion is to
   describe in words, choosing between rendered options will be far faster than
   me iterating on adjectives.

---

## 6. What I still need from you

1. **Run-cycle stills.** 2–4 frames from the side of a gait you like — contact,
   lowest compression, passing. Frames pulled from a gif are perfect. Even *one*
   still showing the lean and hunch you want is high value. I can't watch video,
   so stills are the format.
2. ~~**Movement speed decision**~~ — **closed, declined.** Stays 4.5 m/s. See §4.2 for what
   that costs: the run must be posed at a 1.50 m stride, i.e. as a sprint, and heaviness has
   to come from posture and timing rather than from cadence.
3. **Squad colour** — the reference has no bright shoulder marker. With the closer
   camera, do we keep a small squad-colour cue for readability, or go full
   reference fidelity and distinguish units by HUD and the active-unit ring only?
   **Still open**, and cheaper to answer than it was: it is a sprite layer, so it can be added
   and removed without touching the model.
4. ~~**Texture resolution** — 1024² or 2048².~~ **Moot.** Nothing is sampled at runtime. The
   equivalent question is the render's `RESOLUTION`, currently **256 px** (1 px = 1 cm), and
   it is a free choice: the game derives `pixel_size` from the PNG, so dropping to 96 or 128
   for visibly chunky Fallout-scale pixels needs no code change at all.

---

## 7. Honest limits

- **Textures are generated in code.** I can produce convincing AO, grime, edge
  wear and panel lines. I cannot hand-paint, and I can't source photo textures.
  Expect "convincingly worn generic tactical gear," not an art-directed hero
  asset. This is the clearest place a texture artist beats me.
- **Round forms cost tris and code.** Domes and cylinders need new primitives in
  the generator; the box builder can't express them. *(Moot for the current character, which
  is a modelled asset rather than a generated one — and triangles are free offline anyway.)*
- **Rigid skinning will start to show** at this fidelity. Right now every vertex
  is weighted 1.0 to one bone, which suits blocky shapes but will crease badly on
  a curved, bevelled torso. Phase A may force real weight falloff at the
  shoulder, hip and elbow joints — worth flagging as scope risk. *(Still true, and cheaper to
  fix than it was: skinning quality is paid in render time, not frame time.)*
- **Proportion changes invalidate the weapon mount.** `level_weapon()` and the
  grip offset both depend on arm geometry, so every proportion change needs the
  numeric barrel-direction check re-run. Cheap now, but it is a step.

> ### Limits added 2026-08-04, from the render pipeline
>
> - **A change to the character means re-rendering it.** There is no live model in the game to
>   tweak: proportions, palette and kit are all baked into ~1,600 PNGs per layer. Iteration is
>   in units of "re-render a pose", which is why `--poses` and `--directions` exist.
> - **A gear swap is a re-render, not a layer swap.** The merc's head, helmet and weapon are
>   flattened into `body` so the renderer resolves self-occlusion for free (see
>   `docs/presentation-direction.md` §2). Variants cost art volume, and that is the accepted
>   trade.
> - **Baked shading fights the tile-light tint.** Sprites are `UNSHADED` and modulated by their
>   tile's `light_value`, so whatever the render bakes in competes with room lighting rather
>   than adding to it. This is why `build_lights` is flat and heavily ambient-supported, and it
>   caps how much form the render can carry — the model has to read on silhouette and local
>   value, not on a dramatic key.
> - **An object-level keyframe silently collapses all eight facings into one.** The turntable
>   rotates the character object; an action that also animates that transform overrides it, and
>   the failure produces the right file count, the right names and eight plausible identical
>   images. `render_sprites.py` mutes such curves and asserts the rotation survived
>   `frame_set`. Keep keys on bones.
> - **Truncated renders are a real failure mode.** Eight of the merc's idle frames came out of
>   Blender without an `IEND` chunk; Godot's importer rejects them and the whole `SpriteFrames`
>   build fails on the first one. Worth a byte-level check after a long render.

---

## 8. Suggested order

> **Revised 2026-08-04.** Steps 1 and 2 of the original are done or partly done; the ordering
> principle behind it — settle framing, then motion, then the model — held up and is kept.
>
> 1. ~~Pixel-height measurement + camera retune (§1.3)~~ ✅ **Done**, and the retune landed
>    twice: once to `size = 12`, then to **10.5** when the cosine error surfaced.
> 2. ~~Frame-strip renderer~~ ✅ **Done** (`make_sprite_gif.py`, `preview_sprite.gd`).
>    **Trajectory dump (§5.2) is still the next thing to build**, and it is now more valuable
>    than when it was first listed: §4.2's 1.50 m stride is a hard number that nothing
>    currently checks.
> 3. **Finish the pose set before improving any single pose.** Two of twenty are rendered.
>    Combat is entirely placeholder — `begin_shoot`, `fire_shoot`, `end_shoot`, `aim_hold` —
>    and that is what the player looks at most. A crude full set beats two good poses.
> 4. **The `arm` layer**, authored only for `sw`. Until the other seven exist the rifle arm is
>    wrong in seven of eight facings, which undoes the reason the merc is rendered in eight
>    directions at all.
> 5. Run-cycle variants against the 1.50 m constraint (§4.2, §5.4).
> 6. Phase A geometry (bevels, dome helmet) — now cheap, since triangles are free offline.
> 7. Phase B palette and kit (§1.1, §1.2). Still the highest-leverage *look* work: olive
>    pouches and red lenses are what make the silhouette legible at 15% of viewport height.
> 8. Phase C texture + AO bake. Note that Phase F (Godot-side SSAO/bloom) is **not** available
>    to sprites — anything of that kind has to be baked here instead.

*(Original.)*

1. Pixel-height measurement + camera retune (§1.3) — everything else is judged
   against this framing.
2. Frame-strip renderer + trajectory dump (§5.1, §5.2).
3. Run-cycle variants, you pick (§5.4). Ship the weighty run early — it changes
   game feel more than the model does.
4. Phase A geometry (bevels, dome helmet).
5. Phase B palette and kit.
6. Phase C texture + AO bake.
