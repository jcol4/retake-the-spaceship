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

The reference is framed roughly 4× closer than the game's then-current default zoom (~15–20% of
viewport height vs. ~4%). This isn't just a camera tweak — it inverts an earlier art conclusion:
at 4% height, dark-palette readability was a real worry and detail investment looked wasted; at
15–20% height, texture/AO/pouch colour/lenses all read clearly, detail investment is worth it,
and the flat cartoon outline shader (previously considered necessary for readability) is probably
unnecessary in favor of a rim light for grit. **Practical implication:** camera framing should be
settled *before* investing further in texture/detail work, since the correct art approach depends
on it.

## Weighty movement as a gameplay-feel decision, not just animation polish

The run-cycle rework (posture, cadence, ground contact) is explicitly tied to a movement-speed
change: `MOVE_SPEED` dropping from 4.5 m/s to ~2.4 m/s to avoid foot-skate at a slower, heavier
cadence (`stride_per_step = MOVE_SPEED × cycle_time / 2`). This roughly doubles how long a move
takes, which is a genuine gameplay-feel tradeoff flagged as needing a decision, not a pure art
change — worth surfacing here because it interacts with mission pacing (Section 7's 20–40 minute
mission length target).

## Open questions from the source doc

- Squad-colour cue: with the closer camera, keep a small squad-colour marker for readability, or
  rely on HUD + active-unit ring only, per the reference's lack of any bright shoulder marker?
- Texture resolution: 1024² vs 2048².
- Movement speed: is ~2.4 m/s acceptable given it roughly doubles move duration?

## Budget

Current model: 432 tris, 6 flat materials, no UVs/textures. Target: 6,000–10,000 tris, ~8
materials, one UV set, one texture atlas — well within budget for 2–4 on-screen units on PC.
