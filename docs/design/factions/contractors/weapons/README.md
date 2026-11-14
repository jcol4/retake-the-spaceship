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

| Weapon | Range table | Damage | Mag Size | Reserve | Total | Close quarters | Suggested class |
|---|---|---|---|---|---|---|---|
| [Assault Rifle](assault-rifle.md) | +10 close, about 0 out to 12 | 8 | 3 | 15 (5 mags) | 18 | — | [Assault](../units/assault/) (baseline) |
| [Shotgun](shotgun.md) | +30 point-blank, useless past ~8 | 14 | 6 | 15 (loose shells) | 21 | — | [Assault](../units/assault/) (aggressive) |
| [SMG](smg.md) | +20 close, 0 at 7, −6/tile after | 6 | 4 | 20 (5 mags) | 24 | Shoot −1 AP | [Support](../units/support/) |
| [LMG](lmg.md) | −20 point-blank, +5 from 6 to 12 | 9 | 6 | 12 (2 mags) | 18 | — | [Heavy Weapons](../units/heavy-weapons/) |
| [Battle Rifle](battle-rifle.md) | −30 point-blank, +5 from 9 to 18 | 10 | 3 | 12 (4 mags) | 15 | — | [Sniper](../units/sniper/) |

**Accuracy** ([system doc](../../../systems/accuracy/)) comes from the soldier's Aim plus the gun
**archetype's distance table**: aim added at each range, in full in the system doc. Each roster gun
is the first of its archetype and adds 0 flat aim; later guns in an archetype will differ by an aim
modifier. The old base accuracy (20–35), optimal-range falloff and the Battle Rifle's/LMG's
close-quarters accuracy penalties all became the tables.

**Close quarters** ([system doc](../../../systems/close-quarters/)) is the SMG's (and the Pistol
sidearm's) 1 AP cheaper Shoot while a hostile its carrier can see is within 3 tiles.

Two per-weapon axes beyond damage and the range table, added during stat tuning to give the
five weapons a distinct *feel* rather than just different numbers on the same three stats:

- **Mag size vs. reserve** — see [Ammo model](#ammo-model) below. Mag size governs how often a
  soldier reloads mid-engagement; reserve caps the *total* shots available for the whole mission.
  The two numbers tell different stories: SMG (small mag, huge reserve) reloads constantly but
  rarely runs dry; Battle Rifle (small mag, small reserve) does both.
- **Move speed** — *retired.* It multiplied the carrier's move range (only the LMG, 75%); the AP
  rework made movement a flat 1 AP per tile and removed it (see `WeaponData`). The LMG's cost is now
  its distance table, bad at 1–3 tiles.

## Ammo model

Reload (1 AP, GDD Section 4.3) no longer refills from an unlimited pool. Each soldier now carries a
**finite reserve** of spare rounds, set per weapon at the start of the mission (via the loadout
screen) and never replenished mid-mission:

- **Mag size** — how many shots (Shoot/Aimed Shot/Overwatch, each costs 1 round regardless of
  action type) the weapon holds before it needs a Reload.
- **Reserve** — spare magazines carried beyond the loaded one. Reload loads the fullest and puts the
  one coming out back with whatever it still holds, so no round is lost, and late in a mission a
  reload can load a part-used mag rather than a full one.
- **Total** — mag size + reserve. The real per-mission ammo budget; this is the number that
  actually differentiates a "sustain" weapon (SMG, 24) from a "scarce" one (Battle Rifle, 15).

Once both `ammo` and `reserve` hit 0, that soldier is **out of ammo for the rest of the mission** —
Reload disables, and Shoot/Aimed Shot/Overwatch all require `can_shoot()` (`ammo > 0`), so all
three lock out too. No emergency reserve, no resupply — ammo discipline is a real mission-length
resource, not just a reload-timer.

Most weapons carry their reserve as whole mags (Assault Rifle: 5 spare mags of 3 = 15), held per mag
in `Unit.reserve_mags`. A magazine attachment enlarges all of them, so an Extended Mag on that rifle
is 5 spare mags of 4 = 20. The **Shotgun is the deliberate exception**: it's pump-action, so instead
of discrete mags it has a loose reserve of 15 individual shells (`WeaponData.loose_reserve`), and its
last reload or two of a mission can top off the tube short of a full 6, which reads as "scrounging
the last shells" rather than "swap to a fresh mag."

## Implementation

- `scripts/weapon_data.gd` (`WeaponData`, a `Resource`) — the per-weapon stat block: archetype
  (which distance table, `WeaponArchetype`), aim modifier, damage, magazine size, starting reserve.
- `scripts/weapon_presets.gd` (`WeaponPresets`) — the five weapons' numbers (`DATA`) and each
  class's suggested default (`CLASS_DEFAULT`), mirroring how `ClassPresets` holds the four-stat
  ranges.
- `scripts/unit_stats.gd` — `UnitStats.weapon: WeaponData` replaces the old flat
  `weapon_base_accuracy`/`weapon_damage`/`mag_size` export fields. Those three names (the first now
  `weapon_aim_modifier`) still exist as
  read-only computed properties (`get:` accessors reading off `weapon`) so `combat.gd`, `unit.gd`,
  and `hud.gd` didn't need call-site changes. `null` means unarmed at range (the Fodder swarm).
- `scripts/combat.gd` — `compute_accuracy()` adds the gun's `range_modifier()` (its archetype's
  table, `scripts/weapon_archetype.gd`); see the [accuracy doc](../../../systems/accuracy/).
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
- **Attachments** ([attachments.md](attachments.md)) — `scripts/attachment_data.gd` (`AttachmentData`)
  holds one attachment's slot and stat bonuses; `scripts/attachment_presets.gd` (`AttachmentPresets`)
  holds the roster from [attachments.md](attachments.md). `WeaponData` has one field per slot (`underbarrel`, `barrel`,
  `optic`, `magazine`, `stock`) plus base `fire_ap_modifier`/`reload_ap_modifier` (all 0 for now) and
  `noise_radius` (gunfire noise in tiles, all 5 for now), and exposes the summed totals through
  `effective_*()` accessors. Each unlock is one copy that fits one soldier at a time: the loadout
  screen reads an inventory (id -> copies owned; one of each until progression exists) and disables
  a copy that's already fitted to another soldier.
- **Ammo types** — `scripts/ammo_data.gd` (`AmmoData`) and `scripts/ammo_presets.gd` (`AmmoPresets`,
  same roster doc). `WeaponData.ammo` holds one type (null = Standard).
  Ammo and attachments are both `WeaponMod`s (`scripts/weapon_mod.gd`), which holds the stacking
  rules; damage that depends on the target goes through `Combat.shot_damage`. Each type has a list of
  weapons it fits. Unlocks are per type, so any number of soldiers can load an unlocked type.

```
accuracy = Aim (shooter.perception, 55–65 recruit, cap 87) + weapon aim modifier (0 today)
           + the archetype's range table at this distance (WeaponArchetype)
           + 15 and the zone on an Aimed Shot, + elevation, − suppressed, − injured arms
           − the target's Defense (own stat, cover, hunker, concealment), then clamped 1–95
shoot AP = (6 + weapon AP modifiers, incl. engaged −1 for SMG / Pistol) − 0.03 × Reflexes, rounded up
damage   = weapon.damage * hit-zone multiplier (Aimed Shot) or 1.0 (Shoot)
ammo     = weapon.mag_size to start; Reload (1 AP) draws min(mag_size − ammo, reserve) from reserve
```

## Design intent behind the five

Five weapons, one clear axis each, so the choice reads at a glance rather than needing a spreadsheet:

- **Assault Rifle** — the generalist. Its table never strays far from 0 (+10 close, 0 out to 12),
  so it is never bad anywhere. Each specialist beats it in its own niche; it is the gun that works on any map and
  at any range. Mag size (3) and total ammo (18) are the middle of the roster on both counts.
- **Battle Rifle** — the best table at range (+5 from 9 to 18 tiles), the highest long-gun damage,
  the most penetration (and so the most armor ignored: 3 points), but the **lowest total ammo in the
  roster (15)** and **clumsy up close** (−30 at 1 tile, −25 at 2). The long-range precision and
  anti-armor pick. Up close, its answer is stepping back.
- **SMG** — a strong short table (+20 close, 0 at 7 tiles, −6/tile after), the lowest damage, and
  the **highest total ammo in the roster (24)**. The close-range volume gun: **Shoot costs 1 AP less
  while engaged** (stacking with a Laser Sight to −2), so it can fire more often than anything else
  once it's in someone's face, and its deep reserve can afford to.
- **LMG** — biggest single magazine (6), solid damage, 60 penetration, but **unwieldy when rushed**
  (−20 at 1 tile, −15 at 2; +5 from 6 to 12). It holds a line at range and hates being closed on. Its *total* ammo (18) is only middle-of-the-roster (tied with the Assault Rifle), fewer mags
  carried (3) offsetting the bigger mag.
- **Shotgun** — highest damage per hit and the best point-blank table (+30 at 1 tile), effectively
  unusable past ~8 tiles (−15/tile from there, the steepest falloff in the roster), offset by a
  generous total ammo pool (21, second only to the SMG) via its loose-shell reserve. All-in on
  repeated close-range trades; pairs with Assault's Fitness-driven movement range to actually
  close into that trade rather than getting caught firing from range.

## Relationship to the class system

- Every class's suggested weapon reinforces its GDD Section 4.5 role rather than fighting it:
  the Sniper hangs back, where the Battle Rifle's table pays (every class rolls the same 55–65 Aim
  now, so it's about position, not a better eye); Heavy Weapons' high Fitness/HP tolerates the
  LMG's clumsiness up close since the class already leans on
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
  weapon like the LMG plausibly slowing Initiative, on top of its close-range penalty, is a natural
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
