# Assault Rifle

| Base Accuracy | Damage | Mag Size | Reserve | Total |
|---|---|---|---|---|
| 30 | 8 | 3 | 15 (5 mags) | 18 |

## Role

The no-tradeoff baseline weapon — median accuracy, median damage, and (at 18) squarely
middle-of-the-roster total ammo (see [the roster table](README.md#roster)). It's the weapon every
other weapon is a deliberate deviation from, rather than a niche pick itself.

Base accuracy and damage are exactly the old Assault class defaults from before weapon stats were
pulled off the class (see [`../units/assault/`](../units/assault/)). Mag size (3) and reserve (15,
5 spare mags) reflect the newer, tighter ammo pass — every weapon's mag size dropped and gained a
finite reserve, so nothing plays *identically* to the original numbers anymore, but this one still
plays closest to them. Unlike the Shotgun and SMG, it has no weapon-specific range falloff, and
unlike the LMG, no movement penalty — it just has the plain global Distance Penalty curve (GDD
Section 6.5) and nothing else layered on top.

## Suggested class

[Assault](../units/assault/) — pairs a no-surprises weapon with the class's high-Fitness mobility,
so the soldier's identity comes from closing distance and taking hits, not from an unusual weapon
profile.

## Relationship to other systems

- With no extreme in any stat, it's the weapon least likely to make Reload timing (GDD Section 4.3)
  a sharp decision within a single engagement — but see [Ammo model](README.md#ammo-model): the
  soldier carries exactly 6 mags total (1 loaded + 5 reserve) for the whole mission, same as every
  other weapon's total is now finite rather than an assumed-infinite pool.
