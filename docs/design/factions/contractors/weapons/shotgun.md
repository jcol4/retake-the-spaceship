# Shotgun

*Pump-action.*

| Range table | Damage | Mag Size | Reserve | Total |
|---|---|---|---|---|
| +30 / +25 / +20 at 1 / 2 / 3 tiles, 0 at 5, −45 at 8, −15/tile after | 14 | 6 | 15 loose shells | 21 |

Range table: aim added at each distance on top of the soldier's Aim
([accuracy](../../../systems/accuracy/)). Aim 60 against an open target: 90% at 1 tile, 85% at 2,
60% at 5, 45% at 6, 15% at 8.

## Role

Highest damage per hit of any weapon in the roster, by a wide margin, and the **best point-blank
table** — but its defining trait is range: from 4 tiles on its table drops 10–15 per tile, the
steepest of any weapon by a wide margin. It's built to be **effectively unusable beyond close
range** and to hit hard and often the moment a soldier is nearly on top of a target.

**Slug Rounds** swap it onto the Assault Rifle's table (+10 close, about 0 out to 12 tiles): one
projectile with Battle Rifle penetration instead of splash, and reach instead of point-blank odds.

Unlike the other four weapons, its reserve isn't carried as discrete spare mags — being
pump-action, it's loaded a shell at a time from a loose **15-shell reserve**. Mechanically this is
still just the `reserve` number from [Ammo model](README.md#ammo-model), the only difference is it
isn't an exact multiple of the 6-shell tube, so a soldier's last reload or two of a mission can top
off short of a full 6 — "scrounging the last shells" rather than "swap to a fresh mag."

## Suggested class

[Assault](../units/assault/) — the aggressive alternative to the class's baseline Assault Rifle.
The class's high Fitness (largest movement range, Section 4.6.3) is what the Shotgun leans on
entirely: it only works if a soldier can actually close to point-blank, since nothing about its
own accuracy makes a mid-range trade viable.

## Relationship to other systems

- Its table (`WeaponArchetype`, `scripts/weapon_archetype.gd`) is the whole of its range story —
  there's no separate global curve — and by 8 tiles it's −45: closing distance isn't just the best
  option, it's close to the only one.
- Total ammo (21) is the second-highest in the roster (after the SMG's 24), so despite the small
  6-shot tube this weapon can sustain quite a few close-range trades across a mission — the
  bottleneck is always range, never really ammo.
