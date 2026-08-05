# Art Direction

*Source: `character-art-plan.md` (v2, written against reference supplied 2026-07-26). Summarized
here from the contractor faction's perspective — see the source doc at the repo root for the full
phased implementation plan and tooling notes.*

> **How this art reaches the screen (2026-08-04).** Contractors are **prerendered**: a rigged
> 3D character is posed per action in Blender and turned through eight facings under a camera
> locked to the game's own pitch and yaw, producing flat sprites. So everything below about
> palette, silhouette, kit and gait describes a **model**, and describes it literally — this
> is a modelling brief, not a painting brief. See
> [presentation-direction.md](../../../../presentation-direction.md) §2.1.
>
> Rendered so far: `idle` and `run`, of twenty poses. Everything else is placeholder.

## The mercenary/PMC read

The reference art is deliberately **not** a clean, uniformed military look — no faction insignia,
worn/dirtied gear, mismatched wear patterns. This is what motivates naming the faction
"Contractors" in this doc set even though the GDD itself just says "soldiers": the visual
identity reads as hired operators, not a standing army.

## Palette — black-plus-two-accents, not monochrome

| Element | Colour | Notes |
|---|---|---|
| Suit, helmet, gloves, vest shell | Near-black, desaturated, slightly warm-shifted | Base |
| **Chest-rig pouches** | **Olive/khaki-tan** | The dominant, identity-defining accent |
| **Mask lenses** | **Red, glowing, round** | Not cyan, not rectangular |
| Knee pads | Light grey, large rounded caps | |
| Boots, lower legs | Dusty light brown-grey | Weathered, lighter than the suit |
| Rear/hip dump pouch | Olive | Matches chest rig |

The olive pouches and red lenses are called out as *the* two things that make the silhouette
recognisable — both were missing from the v1 model and are the highest-priority fix.

## Shape corrections over v1

Rounded ballistic-dome helmet (not a flat box), rounded snout/muzzle mask with an integrated
filter housing (no hose), round filter disc at the cheek/ear, elbow pads, drop-leg holster with
visible pistol grip, radio + short antenna on the back/shoulder, taller heavier boots, larger
rounder knee pads.

## Why camera distance changes the whole art calculus

> ✅ **RESOLVED 2026-07-30, corrected 2026-08-04.** The camera is fixed orthographic with no
> zoom, at a `Camera3D.size` of **10.5** — putting a character at **14.9% of viewport
> height**, inside the reference band. The section's own practical implication ("settle
> framing before investing in detail") has therefore been honoured: framing is settled, and
> it cannot drift, because there is no zoom control left to drift it. See
> [presentation-direction.md](../../../../presentation-direction.md).
>
> *The first answer was `size = 12` for "16%", and it was wrong by a cosine.* An upright
> figure seen at 35.264° is foreshortened and occupies `1.92 × cos(pitch) = 1.568 m` of
> screen, so 12 really gave 13.1% — under the band. The 16% was accurate for the code
> placeholder, which fills its canvas and is foreshortened by nothing, and stopped being
> accurate the moment rendered art landed.
>
> The conclusion below still holds and applies to the **model and its render** rather than to
> realtime texture work: at ~15% height, detail investment pays.

The reference is framed roughly 4× closer than the game's then-current default zoom (~15–20% of
viewport height vs. ~4%). This isn't just a camera tweak — it inverts an earlier art conclusion:
at 4% height, dark-palette readability was a real worry and detail investment looked wasted; at
15–20% height, texture/AO/pouch colour/lenses all read clearly, detail investment is worth it,
and the flat cartoon outline shader (previously considered necessary for readability) is probably
unnecessary in favor of a rim light for grit. **Practical implication:** camera framing should be
settled *before* investing further in texture/detail work, since the correct art approach depends
on it.

## Weighty movement as a gameplay-feel decision, not just animation polish

> ✅ **RESOLVED 2026-07-30 — declined. Move speed stays 4.5 m/s.** Doubling move duration was
> a real cost against the 20–40 minute mission target.
>
> ⚠️ **But half the reasoning was wrong, and was corrected 2026-08-04.** The original said
> "sprites have no stride to skate — the walk cycle is *authored against* 4.5 rather than the
> speed being fitted to an existing clip." That is true of **hand-drawn** sprites. The sprites
> turned out to be **rendered from a rigged 3D character**, which has feet at real world
> positions, so the skate constraint applies exactly as it did in 3D. The medium changed; the
> kinematics did not.
>
> **The decision stands, the constraint comes back with it.** Both inputs are now fixed rather
> than open — `move_speed` 4.5 m/s, and a cycle forced to 0.666 s by the footstep cadence — so
> the formula below has one answer:
>
> ```
> 4.5 × 0.666 / 2 = 1.50 m between contact poses
> ```
>
> That is a sprint stride, and it is the honest cost of keeping 4.5 m/s: the run cannot be
> made heavier by slowing its cadence, so weight has to come from posture, ground contact and
> interpolation instead. Nothing currently checks the 1.50 m. See `character-art-plan.md`
> §4.2.

The run-cycle rework (posture, cadence, ground contact) is explicitly tied to a movement-speed
change: `MOVE_SPEED` dropping from 4.5 m/s to ~2.4 m/s to avoid foot-skate at a slower, heavier
cadence (`stride_per_step = MOVE_SPEED × cycle_time / 2`). This roughly doubles how long a move
takes, which is a genuine gameplay-feel tradeoff flagged as needing a decision, not a pure art
change — worth surfacing here because it interacts with mission pacing (Section 7's 20–40 minute
mission length target).

## Open questions from the source doc

- Squad-colour cue: with the closer camera, keep a small squad-colour marker for readability, or
  rely on HUD + active-unit ring only, per the reference's lack of any bright shoulder marker?
  **Still open**, and cheaper to answer than it was: a squad-colour cue is now a sprite layer,
  so it can be added and removed without touching a model.
- ~~Texture resolution: 1024² vs 2048².~~ **Moot.** Nothing is sampled at runtime. The
  equivalent question is the render resolution, currently 256 px (1 px = 1 cm), and it is a
  free choice — the game derives `pixel_size` from the PNG.
- ~~Movement speed: is ~2.4 m/s acceptable?~~ **Closed — declined, stays 4.5 m/s**, with the
  1.50 m stride constraint that follows from it (above).

## Budget

> ⚠️ **SUPERSEDED 2026-07-30, revised 2026-08-04.** A realtime triangle and material budget
> describes nothing: the model is consumed **offline**, by Cycles, into PNGs, and nothing
> about it is uploaded to a GPU at play time. Triangles are effectively free — spend them on
> bevels, the dome helmet, round lenses and real joint weighting.
>
> The budget that binds is **art volume × render time**:
>
> ```
> images per character = poses × 8 directions × frames per pose
> ```
>
> Twenty poses averaging ~10 frames is ~1,600 renders per layer. The levers are the
> per-character layer set (the merc is 2 — `body` and `arm` — not 4), the sampling rate
> (`--fps`, which costs nothing in game timing), and Cycles samples. See
> [presentation-direction.md](../../../../presentation-direction.md) §2.1.
>
> Placeholder art — still what every character but the merc uses — is generated in code at a
> 64² canvas, putting a character at 1.92 m. Rendered art uses a 2.56 m canvas at 256 px, and
> the framing figure above is measured against the character's 1.92 m within it.

*(Historical: model was 432 tris, 6 flat materials, no UVs/textures; the target was
6,000–10,000 tris, ~8 materials, one UV set, one texture atlas.)*
