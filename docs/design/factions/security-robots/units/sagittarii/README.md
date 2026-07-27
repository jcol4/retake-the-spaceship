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

## Open items

- Exact Armor value, the Light Cover penalty-reduction amount, and movement-per-turn numbers —
  deferred to playtesting.
