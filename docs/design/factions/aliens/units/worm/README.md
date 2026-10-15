# Worm

*Code: `scripts/worm_unit.gd`, `AlienPresets.worm`, `scenes/worm_unit.tscn`.
Art: `art_src/worm_anims.blend`, `art_src/worm_pile_*.blend`.*

**The pile is the unit. This page is about one worm; the thing the player actually fights is
documented in [worm-mass.md](../../design-choices/worm-mass.md), and nothing here makes sense
without it.**

| Speed | Toughness | Grouping | Core Role |
|---|---|---|---|
| Slowest on the board (1 tile/turn) | Fragile (5 HP) | Placed per map | Seed of the mass |

*Size: 0.5 m long, a third of a 1.5 m tile.*

## Role

A half-metre crawler with a **2-damage bite and 5 HP**. Ten bites to put down a soldier, and it
moves one tile a turn — so on its own it is not a threat and is not meant to be one. It is an
**alarm and a seed**: the thing that notices you, calls the compartment, and starts the pile
that is the actual encounter.

This is a reversal of the unit's first design, which gave it a 5-damage bite and called it a
"hidden bite" — something that hurt disproportionately for its size. That worm was a decent
hazard and a dead end: nothing followed from meeting one. The worm is worth more as the
smallest piece of a thing that grows.

## Behavior

- **Alone:** Fodder's loop, unchanged. It crawls at its target and bites once adjacent
  (`WormUnit` extends `SwarmUnit`). No ranged attack, ever.
- **Not alone:** it does not approach the soldier at all. It calls the compartment and walks to
  the pile. See [worm-mass.md](../../design-choices/worm-mass.md) — the rally, the trample, the
  tier ladder and the decay all live there.
- **Pace: one tile per activation.** The exception to flat movement (contractors
  `ap-and-stat-baselines.md`, Sec 4.1). The AP pool never drops below 6 (`AP_POOL_BASE`), so a
  flat 1 AP per tile cannot hold anything under six tiles a turn — nine metres, which is not a
  pace for something half a metre long. `WormUnit` therefore overrides the pool to a flat 12
  and prices a tile at the whole of it.
- **Close OR bite, never both.** The bite costs the whole 12 AP pool. Fodder's turn of warning,
  kept — **for the lone worm only.** A mass has no attack action and breaks this deliberately.
- **Senses: footsteps.** The faction's named exception to "no special senses" (see
  [the faction README](../../README.md)). A worm feels any hostile that moved within
  `tremor_range` (4) tiles on its own deck since its last activation, lit or not, in line of
  sight or not. Contact is always felt. Normal sight and hearing still apply on top.
- **Counterplay: stand still.** A locked-on worm that stops feeling its target loses it after
  `lose_contact_turns`, the same rule that makes killing the lights work on sighted aliens.
  This matters *more* now, not less: standing still is what stops a pile forming around you.
- **Death:** no death art by decision. The `downed` pose falls through to `idle`.

## Art

`art_src/worm_anims.blend` holds three actions, each a 24-frame loop at 12 fps:

| Action | Plays as |
|---|---|
| `worm idle` | `idle`, and also `melee` (the bite plays the idle thrash, by decision) |
| `walking` | `walk` (the worm is `walks_only`) |
| `just emerged` | not wired to any pose yet |

The rig lies ~93° about X; its bone chain was built upright and laid flat. The armature's
origin sits mid-body on the floor, and its scale makes the worm 0.5 m long (6 cm thick).
`render_sprites.py` sets `VARIANT_BUCKET_ZERO["worm"]` to 20.2, measured off the rest mesh.

**The three pile variants are built from this same armature** by `tools/build_worm_piles.py`,
which instances it 5/9/16 times into a heap and phase-shifts each copy's action so the pile
writhes instead of pulsing as one. They therefore inherit the 20.2 without re-measuring it.

`foot_anchor` is the **minimum** opaque row for the worm and for every pile, where the
humanoids take the mean across idle facings. A body that lies along the ground is nearly all
depth rather than height, and a vertical billboard turns depth into height — anchoring on the
mean buries it under the floor. `render_sprites.py` prints this number as its "no-clip
alternative" and names the worm as the case for it.

## Open items

- **Texture.** `worm skin.png` is linked from `D:\Art\...` and isn't packed. Current sprites
  are untextured grey, piles included (`render_sprites.py` prints a warning on every run), and
  sixteen grey worms read worse than one. Pack the texture into the .blend and re-render
  everything.
- **Hit chance.** A half-metre target is hit exactly as easily as a soldier. Nothing in
  `Combat` scales by size — and a 0.5 m worm and a 1.5 m pile are now hit equally easily too,
  which is harder to defend than it was.
- **`just emerged`** is unused. Still an obvious fit for `alert_scream`, and now also for a
  worm emerging from a nest.
- **Nest spawn table.** Worms are map-placed (`W` glyph) and still aren't in the
  [Nest](../../design-choices/spawn-nests.md) table. This matters more than it used to: with
  no faucet, a tide can only ever be as large as the map author hand-placed.
- **Bucket zero unverified on a moving pile.** 20.2 was measured off the rest mesh and judged
  on a single worm. A pile that walks east while its sprite crawls north-east is the failure,
  and it is invisible in the PNGs — judge it in game, and re-aim by renaming files one bucket
  rather than re-rendering.
