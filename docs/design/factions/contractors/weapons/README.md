# Weapons

*Source: GDD Section 4.6.1 (accuracy formula) and 4.3 (ammo/reload); resolves the Section 12 open
item "weapon base accuracy values per weapon type." Not yet reflected in code — `scripts/class_presets.gd`
currently hard-codes Weapon Base Accuracy/Damage/Magazine Size per **class**, not per weapon; see
[Relationship to the class system](#relationship-to-the-class-system) below.*

## Design change: weapon stats move off the class, onto player-selected gear

Previously, each class's doc listed its own Weapon Base Accuracy / Weapon Damage / Magazine Size,
baked in alongside its Perception/Reflexes/Fitness/Luck ranges. That's been pulled out: **weapon
stats now live on the weapon, and the player picks which weapon each soldier carries**, independent
of class. A class's doc now only covers its four core stat ranges and Class Base Initiative — see
each class's page under [`../units/`](../units/).

Any soldier can equip any weapon. Each class has a **suggested default** below that fits its GDD
role, but nothing in the design forces it — an Assault running an LMG or a Heavy Weapons soldier
running an SMG are legal loadouts, just off-archetype ones.

## Roster

| Weapon | Base Accuracy | Damage | Magazine Size | Suggested class |
|---|---|---|---|---|
| [Assault Rifle](assault-rifle.md) | 30 | 12 | 6 | [Assault](../units/assault/) (baseline) |
| [Shotgun](shotgun.md) | 20 | 22 | 2 | [Assault](../units/assault/) (aggressive) |
| [SMG](smg.md) | 35 | 8 | 12 | [Support](../units/support/) |
| [LMG](lmg.md) | 22 | 14 | 15 | [Heavy Weapons](../units/heavy-weapons/) |
| [Battle Rifle](battle-rifle.md) | 35 | 16 | 5 | [Sniper](../units/sniper/) |

All three stats plug into the existing formulas unchanged (GDD Section 4.6.1 and `combat.gd`):

```
accuracy = shooter.perception + weapon.base_accuracy  (+ Reflexes for Shoot/Overwatch, Section 4.6.2)
           + situational modifiers (cover, light, elevation, Hunker) − Distance Penalty
damage   = weapon.damage * hit-zone multiplier (Aimed Shot) or 1.0 (Shoot)
ammo     = weapon.mag_size, refilled by Reload (1 AP)
```

## Design intent behind the five

Five weapons, one clear axis each, so the choice reads at a glance rather than needing a spreadsheet:

- **Assault Rifle** — the no-tradeoff baseline. Matches the old Assault class defaults exactly, so
  a squad of default loadouts plays identically to the pre-weapons-system numbers.
- **Battle Rifle** — highest accuracy, tied-highest damage, small magazine. The precision pick:
  rewards Aimed Shot (2 AP) and punishes spamming Shoot without Reload discipline.
- **SMG** — highest accuracy, lowest damage, largest magazine short of the LMG. Built for cheap,
  reliable Shoot (1 AP) spam rather than one big hit — the weapon a Support soldier can fire
  constantly without worrying about Reload timing eating into its ability uptime.
- **LMG** — biggest magazine, solid damage, weak accuracy. A suppression/attrition weapon: it
  isn't going to land the *hardest* single hit, but it will keep firing longest.
- **Shotgun** — highest damage per hit, by far the smallest magazine, weakest accuracy. All-in on
  a single reliable close-range trade before a mandatory Reload; pairs with Assault's Fitness-driven
  movement range to actually close into that trade rather than getting caught reloading at range.

## Relationship to the class system

- Every class's suggested weapon reinforces its GDD Section 4.5 role rather than fighting it:
  Sniper's high Perception makes the Battle Rifle's already-high accuracy hit hardest; Heavy
  Weapons' high Fitness/HP lets it stand and feed an LMG; Support's balanced stats and
  ability-focused kit pair with an SMG that asks little of Reload timing; Assault gets a baseline
  (Assault Rifle) and an aggressive option (Shotgun) that both lean on its Fitness-driven mobility
  to reach effective range.
- **Cover-breaker weapons** (GDD Section 6.1.1) are specified at the *class* level — "Heavy
  Weapons-class attacks" — not the weapon level, so that bonus stays a Heavy Weapons trait
  regardless of which of the five weapons that soldier is actually carrying. *(Open item, per the
  GDD: exact bonus multiplier still TBD.)*
- Magazine size no longer varies by class (see the now-outdated note in
  [`../design-choices/action-economy.md`](../design-choices/action-economy.md), updated to point
  here) — it varies by weapon, so two different classes carrying the same weapon reload at the
  same cadence.

## Open items

- Not yet implemented in code — `ClassPresets.RANGES` still holds per-class weapon stats
  (`scripts/class_presets.gd`); wiring an actual weapon-selection/inventory system is a separate
  implementation task from this doc.
- No stat differentiates weapons by effective range — the Distance Penalty curve (GDD Section
  4.6.1) is currently global to all weapons. A shotgun "falling off harder at range" is flavor
  from its low base accuracy alone, not a distinct falloff curve.
- Whether weapon choice should also feed `equipment_initiative` (`unit_stats.gd`'s third
  Initiative term, currently a flat per-unit default unrelated to weapon) is unresolved — a heavier
  weapon like the LMG plausibly slowing Initiative is a natural extension but isn't part of this pass.
