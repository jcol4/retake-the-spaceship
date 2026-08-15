# Shotgun

*Pump-action.*

| Base Accuracy | Damage | Mag Size | Reserve | Total | Optimal Range | Beyond it |
|---|---|---|---|---|---|---|
| 20 | 14 | 6 | 15 loose shells | 21 | 3 tiles | −15% accuracy per tile |

## Role

Highest damage per hit of any weapon in the roster, by a wide margin, and the **lowest base
accuracy** — but its defining trait is range: past 3 tiles, accuracy craters at −15% per tile on
top of the game's existing global falloff (GDD Section 6.5), the steepest penalty of any weapon by
a wide margin. It's built to be **effectively unusable beyond close range** and to hit hard the
moment a soldier is actually adjacent to (or nearly on top of) a target.

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

- `Combat.weapon_range_penalty()` (`combat.gd`) applies the −15%/tile falloff on top of the global
  Distance Penalty curve, so at range this weapon is losing accuracy from *two* stacked penalties
  at once, not one — closing distance isn't just the best option, it's close to the only one.
- Total ammo (21) is the second-highest in the roster (after the SMG's 24), so despite the small
  6-shot tube this weapon can sustain quite a few close-range trades across a mission — the
  bottleneck is always range, never really ammo.
