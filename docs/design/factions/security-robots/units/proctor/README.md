# Proctor (XVT-7)

*New unit — the faction's dedicated detector. Nothing in the existing roster occupies this slot:
Auxilium detects as a byproduct of holding a chokepoint, but nothing actively hunts for signs
of trouble the way Proctor does, and nothing else in either faction has a delayed, indirect
detection channel at all.*

| Speed | Toughness | Grouping | Core Role |
|---|---|---|---|
| Hovering, ignores terrain movement cost | Fragile, avoids combat | Solo patrol | Detector |

## Role

Proctor doesn't fight. Its job is to move through a zone looking for anything that reads as
"doesn't belong" — a live target, or evidence one was recently there — and to report it. Where the
rest of the roster is built to be fought, Proctor is built to be *found and silenced quickly*,
before it can do its actual job.

## Combat behavior

- **Avoids combat outright**, not just retreat-biased — see
  [`../../design-choices/ai-behavior.md`](../../design-choices/ai-behavior.md). On detecting
  anything worth reporting, its response is broadcast-then-disengage: it doesn't linger to shoot,
  it pulls back toward its patrol route or nearest cover.
- **Low HP, no meaningful Armor.** A single solid hit should be enough to drop one — the design
  intent is that Proctor is never the thing a fight is decided by directly, only by what it
  brought with it.
- **Hovers, and ignores terrain movement cost** when pathing its patrol route or retreating —
  pits, hazards, and other terrain that slows/blocks ground units don't slow it down. It still
  cannot end a move on genuinely impassable terrain (a wall, a sealed door) — this is a mobility
  advantage over the ground-based roster, not a way to clip through geometry.

## Detection: the faction's third channel

Proctor is the only unit that runs **evidence scanning** in addition to the standard
motion+sound detection every other Cerberus unit uses — see
[`../../design-choices/detection-and-network-alert.md`](../../design-choices/detection-and-network-alert.md#a-third-channel-evidence-scanning-proctor-only)
for the full mechanic. In short: it can flag a zone as compromised from breached doors, alien
residue, corpses, spent brass, or damaged cover, without needing to have seen whatever caused it
happen.

## Relationship to other systems

- **Calls in nearby units, doesn't spawn new ones.** On flagging evidence or a live target,
  Proctor issues a priority broadcast that specifically routes already-placed heavy units —
  [Securus](../securus/) foremost — toward its location, faster than the standard zone-wide alert
  would. This is a targeted version of the existing network-alert rule, not an exception to
  "no new spawns": a zone with no Securus in it has nothing for a Proctor to call in.
- **The unit most worth silently disabling before it reports.** Auxilium's own doc flags
  silent takedowns as "not currently proposed, but a natural extension" — Proctor is the unit that
  extension would matter most for, since it's the one detector whose entire value is in *not*
  fighting back once found.
- Pairs as a force multiplier with Securus specifically: a zone with both means the player has to
  deal with the detector before it turns a manageable fight into one with an elite unit converging
  on their position.

## Alpha implementation

[`scripts/proctor_unit.gd`](../../../../../../scripts/proctor_unit.gd) +
[`scenes/proctor_unit.tscn`](../../../../../../scenes/proctor_unit.tscn). Map glyph `X`.

| | |
|---|---|
| HP / Armor | 20 / 0 |
| Weapon | None. `weapon` is null, so `can_shoot()` is false forever — the same way the alien swarm is unarmed |
| Movement | `move_speed` 5.0 — the only unit in the faction that outruns a soldier |
| Scan | `evidence_scan_radius` 4, once per activation, no line of sight required |
| Salvage | 3 |

Its combat loop is a *retreat*: `_combat_turn` is overridden to report and then move to the
reachable tile furthest from the threat, every activation, until cornered. It never fires,
never closes and never trades, because the value it protects is its own continued existence.

`_propagate_alert` sends the **priority** broadcast rather than the standard one. That flag is
the whole of the call-in: it spawns nothing, it routes already-placed heavy units, and a zone
with no Securus in it has nothing for a Proctor to call — which is the lever level authoring
actually has over how dangerous one is.

`ignores_terrain_move_cost` is declared and currently inert: no terrain costs more than one
tile yet, so hovering changes nothing today. It is on the unit that owns the behaviour so that
adding hazard tiles later is a change to the pathfinder rather than to the roster.

## Open items

- Exact evidence-flag radius and scan frequency — deferred to playtesting, same posture as the
  rest of the faction's numeric tuning.
- Whether a silent-takedown mechanic against Proctor gets scoped now or waits for a broader
  stealth pass — currently leaning toward "waits," consistent with Auxilium's own open item.
- Whether Proctor's call-in has a range/zone limit distinct from the standard network alert's zone
  scope, or always reaches every Securus in the same zone — leaning toward the latter for
  consistency with the rest of the network-alert design, but not locked in.
