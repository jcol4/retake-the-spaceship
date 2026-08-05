# Faction Identity — Cerberus Applied Sciences

## The lockdown-protocol framing

Cerberus Applied Sciences is the ship's original automated security contractor — installed and
running long before the ship went derelict. Nothing about the robots themselves changed when the
crew left; what changed is that nobody has since told the network to stand down. It's still
running its default posture: **unauthorized movement is an intrusion, and intrusions get
neutralized.**

This is deliberately the *only* piece of lore load-bearing enough to matter for design:

1. **It explains hostility to everyone** (contractors and aliens alike) without needing a
   three-way faction relationship system — "intruder" isn't a species check.
2. **It explains why the robots don't chase past their zone** — a security net is built to
   defend zones/checkpoints, not hunt across an entire ship, which motivates the
   [zone-scoped network alert](detection-and-network-alert.md) design.
3. **It stays out of the way of Section 8's "no narrative focus for now."** No characters, no
   named incident, no questions the game has to answer later. If narrative gets added in a later
   pass, "corrupted lockdown protocol" is a hook that can absorb more story without requiring
   any of the mechanics below to change.

## Naming

- Faction: **Cerberus Applied Sciences**
- **No shared company-wide unit prefix.** Each unit line ships its own alphanumeric model code
  (three letters + a digit) followed by a model name — `XVT-7 Proctor`, `JXM-2 Securus`,
  `QRN-4 Auxilium`, `MKV-9 Sagittarii`. This is a deliberate change from the faction's earlier
  "IS-series" draft naming: a single shared prefix read as a themed toy line (IS-1 through IS-8,
  in order); disparate per-model codes read like actual unrelated defense-contractor hardware
  that happens to share a manufacturer, closer to how real military/industrial nomenclature works
  and a better match for the "cold megacorp," not "friendly robot squad," tone the faction is
  going for.
- `QRN-4 Auxilium` is a placeholder picked to fit this scheme — not yet confirmed, unlike
  `XVT-7 Proctor`, `JXM-2 Securus`, and `MKV-9 Sagittarii`, which are locked in.

## Visual/audio direction

*Placeholder art built 2026-07-31; no authored art for this faction. The contractors are the
only character with real art so far, and it is **rendered from a rigged 3D model** rather than
drawn — see [`../../../../presentation-direction.md`](../../../../presentation-direction.md)
§2.1, since that is the pipeline this faction will go through too. See
[`alpha-implementation.md`](alpha-implementation.md) §5 for what the stand-in draws.*

**What the presentation imposes.** The game is isometric — 2D sprites over 3D levels, at a fixed
35.264° pitch, in eight direction buckets, with a character occupying about 15% of viewport
height, usually in a dark corridor (see
[`../../../../presentation-direction.md`](../../../../presentation-direction.md)). Three consequences
for this faction specifically:

- **Silhouette does the work, not detail.** At that size a robot is a shape and two or three
  colours. Each model therefore owns a *proportion* — squat post, wide platform, small hovering
  drone, tall elite — rather than being distinguished by panel lines nobody will resolve.
- **Four buckets, two drawn.** The 2-drawn + 2-mirrored rule applies here as everywhere.
  Anything asymmetric — a shoulder-mounted weapon — must either be authored for all four or be
  designed symmetric. A machine is the easiest thing in the game to design symmetric, and that
  is worth taking. Halving the buckets doubles the value of that: a symmetric robot now needs
  two drawn directions per pose where the merc needs four.
- **The status light is not decoration, it is the HUD.** See below; it is also why it is the one
  sprite layer exempt from the tile-light tint.

Kept intentionally distinct from both the aliens (organic, biological silhouettes) and the
contractors (`character-art-plan.md`'s worn tactical-gear read) so a player can tell factions
apart at a glance even in low light, which matters since low light is exactly where fights happen
most:

- **Silhouette:** hard-edged, geometric, industrial — the opposite of the aliens' organic
  shapes. Reads as "built," not "grown."
- **Light behavior:** robots do **not** carry flashlights (like aliens, they don't use the
  player's light system — see [`detection-and-network-alert.md`](detection-and-network-alert.md))
  but should carry a small, constant **status-light** (idle blue/standing green, alert amber,
  combat red) as a readability aid — since the player can't read a robot's "alert state" from
  body language the way they might infer an alien's, a status light is a cheap, diegetic HUD.
- **Audio:** servo/hydraulic movement sounds, distinct from alien vocalizations, and — important
  for the sound-detection channel (GDD Section 5.4) — a **audible network chirp** when a robot
  broadcasts an alert, giving the player a sound cue that a zone-wide alert just triggered, not
  just a UI popup. *Not built: the game has no audio at all yet. The broadcast is announced in
  the combat log instead, and `SecurityNetwork.alert_broadcast` is the signal an audio bus would
  hang off when there is one.*
