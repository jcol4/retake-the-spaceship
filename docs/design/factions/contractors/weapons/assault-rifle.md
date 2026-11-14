# Assault Rifle

| Range table | Damage | Mag Size | Reserve | Total |
|---|---|---|---|---|
| +10 at 1–4 tiles, +5 at 5–8, 0 at 9–12, −4/tile after | 8 | 3 | 15 (5 mags) | 18 |

Range table: aim added at each distance on top of the soldier's Aim
([accuracy](../../../systems/accuracy/)). Aim 60 against an open target: 70% at 2 tiles, 65% at 6,
60% at 10, 48% at 15.

## Role

The no-tradeoff baseline weapon — a range table that never strays far from 0, median damage, and (at 18) squarely
middle-of-the-roster total ammo (see [the roster table](README.md#roster)). It's the weapon every
other weapon is a deliberate deviation from, rather than a niche pick itself.

Damage is exactly the old Assault class default from before weapon stats were
pulled off the class (see [`../units/assault/`](../units/assault/)). Mag size (3) and reserve (15,
5 spare mags) reflect the newer, tighter ammo pass — every weapon's mag size dropped and gained a
finite reserve, so nothing plays *identically* to the original numbers anymore, but this one still
plays closest to them. Unlike the Shotgun and SMG it doesn't fall off a cliff at range, and unlike
the LMG and Battle Rifle it isn't clumsy up close: the generalist's table is good everywhere and
best nowhere.

## Suggested class

[Assault](../units/assault/) — pairs a no-surprises weapon with the class's high-Fitness mobility,
so the soldier's identity comes from closing distance and taking hits, not from an unusual weapon
profile.

## Relationship to other systems

- With no extreme in any stat, it's the weapon least likely to make Reload timing (GDD Section 4.3)
  a sharp decision within a single engagement — but see [Ammo model](README.md#ammo-model): the
  soldier carries exactly 6 mags total (1 loaded + 5 reserve) for the whole mission, same as every
  other weapon's total is now finite rather than an assumed-infinite pool.
