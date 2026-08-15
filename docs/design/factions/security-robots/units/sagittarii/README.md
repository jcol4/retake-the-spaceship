# Sagittarii (MKV-9)

*New unit — the faction's "big threat" unit. Loosely fills the Spitter's ranged-pressure slot,
but built tanky rather than fragile, since the roster needed a genuine heavy-armor centerpiece
rather than another fragile unit.*

| Speed | Toughness | Grouping | Core Role |
|---|---|---|---|
| Slow, heavy | Very tanky | Solo | Ranged, cover-ignoring pressure |

## Role

The unit a player has to actively plan around rather than react to — slow enough that it's never
a surprise, but dangerous enough that ignoring it is a mistake. Where the Spitter is a
"kill it fast, it's fragile" problem, Sagittarii is a "you can't kill it fast, so manage your
exposure to it" problem.

## Combat behavior

- **High Armor** (see
  [`../../design-choices/armor-and-destruction.md`](../../design-choices/armor-and-destruction.md))
  — the tankiest unit in either faction's current roster short of Securus. Chipping it down with
  Shoot (1 AP) is inefficient; it's the unit that most rewards bringing Heavy Weapons or EMP.
- **Partial cover-ignoring attack** — its weapon applies a reduced version of the Cover Penalty
  (GDD Section 6.5) against targets in Light Cover specifically (not Heavy Cover), representing
  a heavier-caliber weapon than the rest of the roster carries. This gives it a reason to be
  respected even when the player is behind cover, without fully invalidating the cover system.
- **Slow, low mobility** — like Auxilium, it favors holding a strong position over
  chasing, but unlike Auxilium it does advance deliberately, a tile or two per turn,
  rather than staying fixed at a post.

## Relationship to other systems

- **Primary EMP target.** Its Armor makes standard weapons fights against it expensive; an EMP
  grenade zeroing its Armor for a turn is the intended answer, giving Support/Heavy Weapons
  loadouts a clear reason to bring EMP into a Sagittarii-heavy encounter.
- Pairs naturally with an Auxilium holding a chokepoint behind it — mirrors the aliens'
  Fodder/Spitter pairing (screen + ranged pressure), giving level designers a familiar
  "front unit + support unit" building block that reads the same way across both factions even
  though the underlying mechanics differ.

## Alpha implementation

[`scripts/sagittarii_unit.gd`](../../../../../../scripts/sagittarii_unit.gd) +
[`scenes/sagittarii_unit.tscn`](../../../../../../scenes/sagittarii_unit.tscn). Map glyph `M`.

| | |
|---|---|
| HP / Armor | 20 / 5 |
| Weapon | MKV Support Cannon — 30 accuracy, 10 damage, 5-round magazine |
| Movement | 2 tiles per AP (`move_tiles_per_ap`), `move_speed` 1.8 |
| Cover-ignoring | `light_cover_penalty_mult` 0.5 — half the Light Cover penalty, Heavy untouched |
| Salvage | 4 |

Armor 5 is what makes it the EMP target rather than a damage race, and the arithmetic is meant
to be visible in the combat log: an Assault Rifle's 8 damage delivers **3** against the plate
and **8** into a zeroed-armor window. Seven rounds through the plate against three into the
window — so the EMP is still worth more than twice its weight in ammunition, which is the whole
argument for carrying one.

The lethality rescale (`ap-and-stat-baselines.md` §6.0) moved both sides of that sum but not its
shape: HP came down ~3.5× and Armor came down with *damage* at ~0.65×, deliberately, because Armor
is subtracted from a roll. Left at 8 against the new damage scale it would have swallowed most of a
rifle round and the EMP would have gone from worth a kit slot to mandatory.

The cover reduction is asked of the *shooter* (`Unit.cover_penalty_for`) rather than read from
a flat table, so the HUD's previewed hit chance and the shot that actually fires come from one
code path and cannot disagree.

## Open items

- Exact Armor value, the Light Cover penalty-reduction amount, and movement-per-turn numbers —
  deferred to playtesting.
