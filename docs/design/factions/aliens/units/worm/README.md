# Worm

*Code: `scripts/worm_unit.gd`, `AlienPresets.worm`, `scenes/worm_unit.tscn`.
Art: `art_src/worm_anims.blend`.*

| Speed | Toughness | Grouping | Core Role |
|---|---|---|---|
| Slowest on the board (1 tile/turn) | Fragile (5 HP) | Placed per map | Hidden bite |

*Size: 0.5 m long, a third of a 1.5 m tile.*

## Role

A half-metre crawler — about half the length of a soldier's leg — with a bite that hits hard for
its size: **5 HP, 5 damage.** It is too slow to
chase anything, so the threat is being where you walk. It feels footsteps in the dark, and a
squad moving through its room will have it crawling at them while they are still looking for
lit targets.

## Behavior

- **Loop:** Fodder's. It crawls at its target and bites once adjacent (`WormUnit` extends
  `SwarmUnit`). It has no ranged attack.
- **Pace: one tile per activation.** This is the one exception to flat movement (contractors
  `ap-and-stat-baselines.md`, Sec 4.1). The AP pool never drops below 6 (`AP_POOL_BASE`), so
  a flat 1 AP per tile can't hold anything under six tiles a turn. That is nine metres, which
  is not a pace for something half a metre long. So a worm's step costs its whole
  6 AP pool (`WormUnit.AP_PER_TILE`).
- **Close OR bite, never both.** The bite is priced at the undiscounted 6 AP (Reflexes 0).
  That keeps Fodder's turn of warning: a worm has to start its draw next to you to bite.
- **Senses: footsteps.** This is the faction's named exception to "no special senses" (see
  [the faction README](../../README.md)). A worm feels any hostile that moved within
  `tremor_range` (4) tiles on its own deck since its last activation, lit or not, in line of
  sight or not. Contact is always felt. Normal sight and hearing still apply on top.
- **Counterplay: stand still.** A locked-on worm that stops feeling its target loses it after
  `lose_contact_turns`, the same rule that makes killing the lights work on sighted aliens.
- **Death:** no death art by decision. The worm's `downed` pose falls through to `idle`.

## Art

`art_src/worm_anims.blend` holds three actions, each a 24-frame loop at 12 fps:

| Action | Plays as |
|---|---|
| `worm idle` | `idle`, and also `melee` (the bite plays the idle thrash, by decision) |
| `walking` | `walk` (the worm is `walks_only`) |
| `just emerged` | not wired to any pose yet |

The rig lies ~93° about X; its bone chain was built upright and laid flat. The armature's
origin sits mid-body on the floor, and its scale makes the worm 0.5 m long (6 cm thick).
`render_sprites.py` sets `VARIANT_BUCKET_ZERO["worm"]` to 20.2. That value was measured off
the rest mesh, not yet checked on a moving unit.

## Open items

- **Texture.** `worm skin.png` is linked from `D:\Art\...` and isn't packed. Current sprites
  are untextured grey (`render_sprites.py` prints a warning on every run). Pack the texture
  into the .blend and re-render.
- **Hit chance.** A half-metre target is hit exactly as easily as a soldier. Nothing in `Combat`
  scales by size.
- **`just emerged`** is unused. It's an obvious fit for `alert_scream` (the reaction when it
  first detects a target) or for a future emerge-from-the-deck spawn.
- **Nest spawn table.** Worms are map-placed (`W` glyph) for now and aren't in the
  [Nest](../../design-choices/spawn-nests.md) table.
