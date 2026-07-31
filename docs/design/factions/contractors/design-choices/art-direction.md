# Art Direction

*Source: `character-art-plan.md` (v2, written against reference supplied 2026-07-26). Summarized
here from the contractor faction's perspective — see the source doc at the repo root for the full
phased implementation plan and tooling notes.*

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

> ✅ **RESOLVED 2026-07-30.** The camera is now fixed orthographic with no zoom, at a
> `Camera3D.size` of 12 — a 1.92 m character over a 12 m vertical extent is **16% of
> viewport height**, inside the reference band. The section's own practical implication
> ("settle framing before investing in detail") has therefore been honoured: framing is
> settled, and it cannot drift, because there is no zoom control left to drift it. See
> [presentation-direction.md](../../../../presentation-direction.md).
>
> The conclusion below still holds and now applies to **sprite** art rather than model
> texture work: at 16% height, detail investment pays.

The reference is framed roughly 4× closer than the game's then-current default zoom (~15–20% of
viewport height vs. ~4%). This isn't just a camera tweak — it inverts an earlier art conclusion:
at 4% height, dark-palette readability was a real worry and detail investment looked wasted; at
15–20% height, texture/AO/pouch colour/lenses all read clearly, detail investment is worth it,
and the flat cartoon outline shader (previously considered necessary for readability) is probably
unnecessary in favor of a rim light for grit. **Practical implication:** camera framing should be
settled *before* investing further in texture/detail work, since the correct art approach depends
on it.

## Weighty movement as a gameplay-feel decision, not just animation polish

> ✅ **RESOLVED 2026-07-30 — declined. Move speed stays 4.5 m/s.** The reasoning below was
> driven by foot-skate, which is a property of a 3D clip's stride against ground travel.
> Sprites have no stride to skate: the walk cycle is now *authored against* 4.5 rather
> than the speed being fitted to a clip that already existed. Doubling move duration was
> a real cost against the 20–40 minute mission target and bought nothing once the
> constraint that motivated it stopped existing.

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
- ~~Texture resolution: 1024² vs 2048².~~ **Moot.** Characters are hand-drawn sprites; the
  question is source canvas size per pose, not texture resolution. See below.
- ~~Movement speed: is ~2.4 m/s acceptable?~~ **Closed — declined, stays 4.5 m/s.**

## Budget

> ⚠️ **SUPERSEDED 2026-07-30.** Characters are hand-drawn 2D sprites, so a triangle and
> material budget no longer describes anything. The equivalent budget is **art volume**:
> layers × poses × directions × frames, where the 5-drawn + 3-mirrored rule and the
> per-character layer set are the two levers that control it. See
> [presentation-direction.md](../../../../presentation-direction.md) §2.
>
> Placeholder art is generated in code at a 64² canvas with `pixel_size` 0.03, putting a
> character at 1.92 m — which is what the 16% framing figure above is measured against.

*(Historical: model was 432 tris, 6 flat materials, no UVs/textures; the target was
6,000–10,000 tris, ~8 materials, one UV set, one texture atlas.)*
