# LMG

| Range table | Damage | Mag Size | Reserve | Total | Penetration |
|---|---|---|---|---|---|
| −20 / −15 / −10 at 1 / 2 / 3 tiles, 0 at 4–5, +5 at 6–12, −4/tile after | 9 | 6 | 12 (2 mags) | 18 | 60 |

Range table: aim added at each distance on top of the soldier's Aim
([accuracy](../../../systems/accuracy/)). Aim 60 against an open target: 45% at 2 tiles, 65% from
6 to 12, 53% at 15.

## Role

**Largest single magazine in the roster (6)**, solid damage and the second-most penetration (60,
which ignores 2 points of armor). It is **unwieldy when rushed**. It reloads less often than
anything else mid-engagement, but only carries 3 mags total (1 loaded + 2 reserve), so its total
ammo (18) is only middle-of-the-roster, tied with the Assault Rifle. It holds a line at range and
hates being closed on.

## Up close

Its table is **−20 at 1 tile, −15 at 2, −10 at 3**: about two-thirds of the Battle Rifle's
clumsiness. An Aim 60 soldier has a 45% Shoot at 2 tiles, against 65% from 6 tiles out.

This is the LMG's cost now. It used to slow its carrier to 75% move speed, but the AP rework
removed that (movement is a flat 1 AP per tile for everyone; see `WeaponData`). Without a
replacement, the LMG out-stats the Assault Rifle everywhere: more damage, more penetration, double
the magazine, the same total ammo. It briefly carried a −60 "engaged" accuracy penalty
([close quarters](../../../systems/close-quarters/)); the [accuracy rework](../../../systems/accuracy/)
replaced it with this table, which judges the distance to the *target*.

## Suggested class

[Heavy Weapons](../units/heavy-weapons/). The class's GDD role ("high damage, slow, area-effect")
already reads as "hold a position", which is what this gun wants. Its high Fitness and HP also make
it the class best able to absorb being closed on while it backs off.

## Relationship to other systems

- **Suppression.** Six rounds is two full bursts of suppressing fire (3 rounds each), which is why
  the merc squad's designated gun carries one. The break shot rolls as a Shoot off the same table,
  so a pinned enemy that runs *at* the gunner gets the close-range penalty on the shot it triggers.
- **Overwatch.** From 6 to 12 tiles its table is +5, so a held angle down a room is its best use;
  an angle that ends 2 tiles away is its worst.
- With only 3 mags total, spending Aimed Shot freely rather than conserving with Shoot burns
  through the mission's ammo budget faster than the big single mag makes it feel.
