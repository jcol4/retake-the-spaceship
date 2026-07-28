# LMG

| Base Accuracy | Damage | Mag Size | Reserve | Total | Move Speed |
|---|---|---|---|---|---|
| 28 | 14 | 6 | 12 (2 mags) | 18 | 75% |

## Role

**Largest single magazine in the roster (6)** and solid damage, offset by a below-average base
accuracy and, uniquely among the five, a **movement penalty**: carrying it slows the soldier's
Run/Sprint range to 75% of normal (`UnitStats.move_run()`/`move_sprint()`). It reloads less often
than anything else mid-engagement, but only carries 3 mags total (1 loaded + 2 reserve) — its total
ammo (18) is only middle-of-the-roster, tied with the Assault Rifle. It's a sustained-fire weapon
turn-to-turn, not an unlimited one over a whole mission: a soldier who has already committed to a
position and isn't repositioning, not a walking ammo dump.

## Suggested class

[Heavy Weapons](../units/heavy-weapons/) — the class's high Fitness/HP pool absorbs the move-speed
penalty better than any other class: it already has the roster's largest Fitness range (65–90,
Section 4.6.3), so losing a quarter of its movement still leaves it competitive, and its GDD role
("high damage, slow, area-effect") already reads as "not repositioning every turn" before the
weapon's penalty is even applied.

## Relationship to other systems

- The move-speed penalty multiplies `UnitStats.move_run()`/`move_sprint()` directly, and then
  `Unit.move_run()`/`move_sprint()` (`unit.gd`) applies the existing leg-injury speed penalty on
  top of that — the two stack multiplicatively, so an LMG-carrying soldier with an injured leg is
  hit twice, not once.
- Base accuracy (28) pushes toward Aimed Shot (2 AP, Perception-only, GDD Section 4.6.2) over
  Shoot for the same reason the class doc already notes about Heavy Weapons: Reflexes only helps
  Shoot, and this weapon's below-average base number makes that gap sting more than it would on a
  higher-accuracy weapon.
- With only 3 mags total, spending Aimed Shot freely rather than conserving with Shoot burns
  through the mission's ammo budget faster than the big single mag makes it feel like — the large
  mag hides how finite the *total* supply actually is turn-to-turn.
