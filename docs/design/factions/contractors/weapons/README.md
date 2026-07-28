# Weapons

*Source: GDD Section 4.6.1 (accuracy formula) and 4.3 (ammo/reload); resolves the Section 12 open
item "weapon base accuracy values per weapon type." Implemented in code — see
[Implementation](#implementation) below.*

## Design change: weapon stats move off the class, onto player-selected gear

Previously, each class's doc listed its own Weapon Base Accuracy / Weapon Damage / Magazine Size,
baked in alongside its Perception/Reflexes/Fitness/Luck ranges. That's been pulled out: **weapon
stats now live on the weapon, and the player picks which weapon each soldier carries**, via a
pre-mission loadout screen, independent of class. A class's doc now only covers its four core stat
ranges and Class Base Initiative — see each class's page under [`../units/`](../units/).

Any soldier can equip any weapon. Each class has a **suggested default**, preselected on the
loadout screen, that fits its GDD role — but nothing in the design forces it. An Assault running an
LMG or a Heavy Weapons soldier running an SMG are legal loadouts, just off-archetype ones.

## Roster

| Weapon | Base Accuracy | Damage | Mag Size | Reserve | Total | Optimal Range | Beyond it | Move Speed | Suggested class |
|---|---|---|---|---|---|---|---|---|---|
| [Assault Rifle](assault-rifle.md) | 30 | 12 | 3 | 15 (5 mags) | 18 | — | — | 100% | [Assault](../units/assault/) (baseline) |
| [Shotgun](shotgun.md) | 20 | 22 | 6 | 15 (loose shells) | 21 | 3 tiles | −15%/tile | 100% | [Assault](../units/assault/) (aggressive) |
| [SMG](smg.md) | 35 | 8 | 4 | 20 (5 mags) | 24 | 6 tiles | −6%/tile | 100% | [Support](../units/support/) |
| [LMG](lmg.md) | 28 | 14 | 6 | 12 (2 mags) | 18 | — | — | 75% | [Heavy Weapons](../units/heavy-weapons/) |
| [Battle Rifle](battle-rifle.md) | 35 | 16 | 3 | 12 (4 mags) | 15 | — | — | 100% | [Sniper](../units/sniper/) |

Three new per-weapon axes beyond base accuracy/damage, all added during stat tuning to give the
five weapons a distinct *feel* rather than just different numbers on the same three stats:

- **Mag size vs. reserve** — see [Ammo model](#ammo-model) below. Mag size governs how often a
  soldier reloads mid-engagement; reserve caps the *total* shots available for the whole mission.
  The two numbers tell different stories: SMG (small mag, huge reserve) reloads constantly but
  rarely runs dry; Battle Rifle (small mag, small reserve) does both.
- **Optimal range / falloff** — an *additional* accuracy penalty stacked on top of the existing
  global Distance Penalty curve (GDD Section 6.5), kicking in past the weapon's own optimal range.
  Only the Shotgun and SMG have one; every other weapon relies on the global curve alone.
- **Move speed** — multiplies the carrying soldier's move range (`UnitStats.move_run()`/
  `move_sprint()`). Only the LMG is penalized (75%); it composes with the existing injured-leg
  speed penalty (`unit.gd`'s `_leg_speed_multiplier()`), multiplicatively.

## Ammo model

Reload (1 AP, GDD Section 4.3) no longer refills from an unlimited pool. Each soldier now carries a
**finite reserve** of spare rounds, set per weapon at the start of the mission (via the loadout
screen) and never replenished mid-mission:

- **Mag size** — how many shots (Shoot/Aimed Shot/Overwatch, each costs 1 round regardless of
  action type) the weapon holds before it needs a Reload.
- **Reserve** — spare rounds carried beyond the loaded mag. Reload draws `mag_size − current_ammo`
  rounds from it, or whatever's left if that's less — so the last reload of a mission can come up
  short rather than always topping off fully.
- **Total** — mag size + reserve. The real per-mission ammo budget; this is the number that
  actually differentiates a "sustain" weapon (SMG, 24) from a "scarce" one (Battle Rifle, 15).

Once both `ammo` and `reserve` hit 0, that soldier is **out of ammo for the rest of the mission** —
Reload disables, and Shoot/Aimed Shot/Overwatch all require `can_shoot()` (`ammo > 0`), so all
three lock out too. No emergency reserve, no resupply — ammo discipline is a real mission-length
resource, not just a reload-timer.

Most weapons carry their reserve as whole mags (Assault Rifle: 5 spare mags of 3 = 15). The
**Shotgun is the deliberate exception**: it's pump-action, so instead of discrete mags it has a
loose reserve of 15 individual shells. Mechanically this is the same `reserve` number just not an
exact multiple of `mag_size` (6) — so its last reload or two of a mission can top off the tube
short of a full 6, which reads as "scrounging the last shells" rather than "swap to a fresh mag."

## Implementation

- `scripts/weapon_data.gd` (`WeaponData`, a `Resource`) — the per-weapon stat block: base accuracy,
  damage, magazine size, starting reserve, optimal range, falloff rate, move multiplier.
- `scripts/weapon_presets.gd` (`WeaponPresets`) — the five weapons' numbers (`DATA`) and each
  class's suggested default (`CLASS_DEFAULT`), mirroring how `ClassPresets` holds the four-stat
  ranges.
- `scripts/unit_stats.gd` — `UnitStats.weapon: WeaponData` replaces the old flat
  `weapon_base_accuracy`/`weapon_damage`/`mag_size` export fields. Those three names still exist as
  read-only computed properties (`get:` accessors reading off `weapon`) so `combat.gd`, `unit.gd`,
  and `hud.gd` didn't need call-site changes. `null` means unarmed at range (the Fodder swarm).
- `scripts/combat.gd` — `Combat.weapon_range_penalty()` adds the optimal-range/falloff penalty on
  top of the existing `distance_penalty()` in `compute_accuracy()`.
- `scripts/class_presets.gd` — `ClassPresets.roll()` now sets `stats.weapon` to the class's
  suggested default (`WeaponPresets.default_for_class`) instead of embedding weapon numbers in
  `RANGES`.
- `scripts/unit.gd` — new `reserve: int` (spare rounds; -1 means unlimited, preserving the old
  infinite-reload behavior for anything that doesn't opt into a finite `starting_reserve` — e.g.
  the alien's inline `WeaponData` in `main.gd`, unaffected by this pass). `do_reload()` now draws
  from `reserve` instead of refilling for free; new `can_reload()` gates both the player's Reload
  button (`hud.gd`) and `PlayerUnit.try_reload()`.
- `scripts/loadout_menu.gd` (`LoadoutMenu`) — a pre-mission screen (built in code, no `.tscn`) that
  lists each spawned player unit with an `OptionButton` of all five weapons (showing accuracy,
  damage, mag size, and total ammo), defaulting to its class's suggestion. Confirming ("Deploy")
  assigns the chosen `WeaponData` to each unit and resets its `ammo`/`reserve` to that weapon's
  full mag and starting reserve, then starts the mission. `main.gd` skips this screen entirely in
  `--auto` (headless smoke test) mode, so every unit just deploys with its default.

```
accuracy = shooter.perception + weapon.base_accuracy  (+ Reflexes for Shoot/Overwatch, Section 4.6.2)
           + situational modifiers (cover, light, elevation, Hunker)
           − Distance Penalty (global curve, Section 6.5)
           − weapon range penalty (weapon-specific, past its own optimal range)
move     = (4 + Fitness/20) * weapon.move_multiplier, then * leg-injury multiplier (Sec 4.2)
damage   = weapon.damage * hit-zone multiplier (Aimed Shot) or 1.0 (Shoot)
ammo     = weapon.mag_size to start; Reload (1 AP) draws min(mag_size − ammo, reserve) from reserve
```

## Design intent behind the five

Five weapons, one clear axis each, so the choice reads at a glance rather than needing a spreadsheet:

- **Assault Rifle** — the no-tradeoff baseline. Base accuracy/damage match the old Assault class
  defaults exactly; mag size (3) and total ammo (18) are the middle of the roster on both counts.
- **Battle Rifle** — highest accuracy, tied-highest damage, no range or movement weakness — but the
  **lowest total ammo in the roster (15)**. The precision pick: rewards Aimed Shot (2 AP) and
  punishes spamming Shoot without real Reload discipline, since running dry here is a mission-long
  cost, not just a tempo loss.
- **SMG** — highest accuracy, lowest damage, and the **highest total ammo in the roster (24)** —
  but noticeably worse past 6 tiles (−6%/tile). Built for cheap, reliable Shoot (1 AP) spam at
  short-to-medium range: it can afford to fire far more often than any other weapon before running
  dry, as long as it stays in its effective range.
- **LMG** — biggest single magazine (6), solid damage, weak accuracy, and it slows its carrier down
  (75% move speed) — but its *total* ammo (18) is only middle-of-the-roster (tied with the Assault
  Rifle), fewer mags carried (3) offsetting the bigger mag. It reloads rarely but a mission that
  runs long can still see it go dry.
- **Shotgun** — highest damage per hit, weakest accuracy, and effectively unusable past 3 tiles
  (−15%/tile beyond that — the steepest range penalty in the roster by a wide margin), offset by a
  generous total ammo pool (21, second only to the SMG) via its loose-shell reserve. All-in on
  repeated close-range trades; pairs with Assault's Fitness-driven movement range to actually
  close into that trade rather than getting caught firing from range.

## Relationship to the class system

- Every class's suggested weapon reinforces its GDD Section 4.5 role rather than fighting it:
  Sniper's high Perception makes the Battle Rifle's already-high accuracy hit hardest; Heavy
  Weapons' high Fitness/HP tolerates the LMG's move-speed penalty since the class already leans on
  standing and holding rather than repositioning; Support's balanced stats and ability-focused kit
  pair with an SMG that asks little of Reload timing at the ranges Support usually operates; Assault
  gets a baseline (Assault Rifle) and an aggressive option (Shotgun) that both lean on its
  Fitness-driven mobility to reach effective range.
- **Cover-breaker weapons** (GDD Section 6.1.1) are specified at the *class* level — "Heavy
  Weapons-class attacks" — not the weapon level, so that bonus stays a Heavy Weapons trait
  regardless of which of the five weapons that soldier is actually carrying. *(Open item, per the
  GDD: exact bonus multiplier still TBD.)*
- Magazine size and total ammo no longer vary by class (see the note in
  [`../design-choices/action-economy.md`](../design-choices/action-economy.md)) — they vary by
  weapon, so two different classes carrying the same weapon reload at the same cadence and run dry
  at the same shot count.

## Open items

- Whether weapon choice should also feed `equipment_initiative` (`unit_stats.gd`'s third
  Initiative term, currently a flat per-unit default unrelated to weapon) is unresolved — a heavier
  weapon like the LMG plausibly slowing Initiative, on top of its move-speed penalty, is a natural
  extension but isn't part of this pass.
- Once a soldier is fully dry (0 ammo, 0 reserve) they have no ranged options for the rest of the
  mission — deliberate per this pass's design (no emergency reserve), but there's no fallback
  action or UI treatment yet for what that soldier *does* instead (melee isn't a contractor
  mechanic the way it is for the Fodder swarm, Sec 11.4).
- The loadout screen has no persistence across missions — it's re-shown, and reset to each class's
  suggested default, every time `main.gd`'s `_ready()` runs. Carrying a chosen loadout across a
  multi-mission run is a meta-progression question not yet in scope (GDD Section 7).
- Enemy factions (Cerberus, aliens) don't use `WeaponPresets` — `main.gd`'s `_alien_stats()` still
  builds its own inline `WeaponData`. Intentional for now: the five-weapon roster is player gear,
  not a shared system.
