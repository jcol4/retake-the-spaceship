# Accuracy

*Decided 2026-11-13, implemented the same day. Code: `Combat.compute_accuracy`,
`Combat.ranged_defense`, `scripts/weapon_archetype.gd`; tests: `tools/test_accuracy.gd`.
See [§8](#8-implementation).*

The hit chance is modeled on XCOM 2: the shooter's **Aim** against the target's **Defense**, with
range set by the gun's **archetype**. Every shot used to start so high that it showed 99% at close
range; now most shots start near 60 and have to be earned upward.

## Why

Before this, a Shoot's hit chance was Perception + the gun's base accuracy + Reflexes, all added
whole and clamped to 1–99:

| Who (mid-roll) | Raw Shoot |
|---|---|
| Sniper with Battle Rifle | ~167 |
| Support with SMG | ~145 |
| Assault with Assault Rifle | ~125 |
| Heavy with LMG | ~113 |

Every modifier was sized like XCOM's (cover −40, darkness −30), but every shot started 25–70
points above the cap. Inside 3 tiles there was no distance penalty at all, so a Sniper shooting
into heavy cover in total darkness still showed 97%. Three things followed:
- Gun accuracy barely mattered (20–35 against a Perception spread of 30–90).
- Shoot beat Aimed Shot, since Shoot added Reflexes and Aimed didn't.
- Close range was decided only by damage, penetration and AP.

## 1. The formula

```
Hit % = Aim
      + the gun's aim modifier (+ attachment accuracy)
      + the gun archetype's range-table value at this distance
      + 15 on an Aimed Shot, then the zone (torso 0, limbs −20, head −50)
      + 15 from high ground
      − Overwatch's penalty (−30, reduced by extra reserve; unchanged)
      − 40 if the shooter is suppressed
      − 15 per injured arm
      − the target's Defense (§3)
      clamped to 1–95
```

After the roll, **Luck works as before**. The shooter's Luck can turn a miss into a hit
(Luck/8 %). Crits come from Luck/4 % of hits and can't be dodged. The target's Luck can turn a
non-crit hit into a miss (Luck/8 %). There's **no hidden aim assist** of the XCOM kind.

**Reflexes is out of accuracy.** It still discounts AP and sets initiative. Shoot vs Aimed Shot is
now just a choice: Aimed Shot costs ~3 more AP and buys +15 plus a zone.

**95 is the most a shot can show.** Even a perfect flank misses 1 in 20.

## 2. Aim

**Aim is still called `perception`** in code and saves, because that's the stat it replaced.

- **Recruits roll 55–65, whatever their class.** The classes are placeholders, and a class
  accuracy trait was what hid every modifier.
- **The cap is 87.** There's no progression system yet; the cap is set for when there is.
- **Enemies are at parity:**

| Who | Aim |
|---|---|
| Rival mercs | 55–65 (veterans +10 → 65–75) |
| Auxilium, Sagittarii, Proctor, door gun | 60 |
| Lictor, Securus | 55 |
| Ranged alien | 50–60 |
| Fodder (and brute, brawler), worm | 45–55 (melee only) |
| Agile Hunter | 60–70 (melee only) |

**Saved soldiers.** Records now save under `"aim"`. A save with only the old `"perception"` (0–99)
is mapped linearly from 30–90 onto 55–65 when loaded, so every soldier keeps their rank against
the others (`SoldierRecord.aim_from_old_perception`).

## 3. Defense

Everything that makes a target harder to hit is one number, subtracted from the hit chance
(`Combat.ranged_defense`):

| Source | Defense |
|---|---|
| The target's own stat (`UnitStats.defense`) | 0 for most. **Agile Hunter +20, Proctor drone +20.** Big bodies stay at 0. |
| Cover the shot crosses (none when flanked) | **light +25, heavy +45** (XCOM's 20/40 a notch harder) |
| Hunkered | **+20**, in cover or not |
| Concealment: light on the target's tile | **+30 in the dark** to **−10 fully lit** |

- **Concealment** used to be an aim term; it moved here as the same family as a future camo
  bonus. Robots ignore it entirely (their sensors don't read light). The **Thermal Sight** ignores
  the dark half: a lit target is still easier.
- **The Sagittarii** respects only half of light cover's Defense, as before.
- **New sources belong in `ranged_defense`** (gear like camo), so the HUD preview and the shot
  keep reading one figure.

## 4. Range: archetype tables

Each gun belongs to an **archetype**, and each archetype has a **distance table**: aim added at
1, 2, 3 … tiles, then a per-tile falloff past the end (`WeaponArchetype`). These tables replaced
three older mechanisms: the global distance curve, each gun's optimal-range falloff, and the
close-quarters accuracy penalties on the Battle Rifle and LMG.

| Tiles | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | past the end |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Shotgun | +30 | +25 | +20 | +10 | 0 | −15 | −30 | −45 | | | | | −15/tile |
| SMG | +20 | +18 | +15 | +10 | +8 | +5 | 0 | −6 | −12 | −18 | | | −6/tile |
| Pistol | +15 | +15 | +10 | +5 | +5 | 0 | −8 | −16 | | | | | −8/tile |
| Assault Rifle | +10 | +10 | +10 | +10 | +5 | +5 | +5 | +5 | 0 | 0 | 0 | 0 | −4/tile |
| LMG | −20 | −15 | −10 | 0 | 0 | +5 | +5 | +5 | +5 | +5 | +5 | +5 | −4/tile |
| Battle Rifle | −30 | −25 | −20 | −10 | −5 | 0 | 0 | 0 | +5 | +5 | +5 | +5 | +5 through 18, then −3/tile |

Aim 60 against an open target:

| | 2 tiles | 6 tiles | 10 tiles | 15 tiles |
|---|---|---|---|---|
| Shotgun | 85 | 45 | 1 | 1 |
| SMG | 78 | 65 | 42 | 12 |
| Pistol | 75 | 60 | 28 | 1 |
| Assault Rifle | 70 | 65 | 60 | 48 |
| LMG | 45 | 65 | 65 | 53 |
| Battle Rifle | 35 | 60 | 65 | 65 |

- **Which table each gun reads.** Every roster gun is the first of its archetype. Each gun has an
  **aim modifier** for later guns of the same archetype (0 for all six today).
- **Enemy guns:** Auxilium sentry gun, Sagittarii cannon, Securus wrist gun and door gun → LMG;
  Lictor demolition gun → Shotgun; ranged alien → Assault Rifle.
- **Mods can swap the table.** **Slug Rounds** put the Shotgun on the Assault Rifle's table: +10
  close and about 0 out to 12 tiles, where buckshot is useless past 8.

## 5. Melee

```
Melee % = Aim + the attacker's melee bonus + 15 from high ground
        − the target's own Defense − 20 if hunkered
        − 40 if suppressed − injured arms + the Hunter's ambush bonus
        clamped to 1–95
```

Cover, concealment and range never apply to a swing. Each melee bonus was refit so a swing lands
about as often as before the rescale: **the old odds (capped at 95) minus the new Aim**.

| Who | Melee bonus | Typical odds |
|---|---|---|
| Soldier, merc | +15 | ~75% |
| Fodder, worm | +25 | ~75% |
| Agile Hunter | +20 | ~85% (+25 from ambush) |
| Ranged alien | +30 | ~85% |
| Auxilium | +25 | ~85% |
| Sagittarii, Proctor, Lictor | +30 | 85–90% |
| Securus | +40 | ~95% |

## 6. What it does to close quarters

[Close quarters](../close-quarters/) used to pile −80 (Battle Rifle) and −60 (LMG) onto Shoot
while a hostile was within 3 tiles of the shooter. **The tables replace that.** Being bad up
close now depends on the distance to the *target*, so a Battle Rifle with a zombie at its elbow
shoots a target 10 tiles away at full accuracy. The SMG's and Pistol's −1 AP while engaged is
unchanged.

## 7. Open items

- **The LMG past 12 tiles.** The preview approved with these tables showed −12 at 15 tiles, but
  the table's own rule (+5 through 12, then −4/tile) gives −7. The rule is what was built.
  Lengthen or shorten the LMG's +5 run if 15 tiles should be worse.
- **The AI's "worth taking" floor is still 15%** (`GoapBrain.MIN_VIABLE_ACCURACY`). On the new
  scale more shots fall between 15 and 40%, so mercs will take more long-odds shots than before.
  Measure with `tools/sim_merc_ai.gd`.
- **No leveling yet.** The 87 cap exists only as `UnitStats.AIM_CAP`.
- **The HUD shows only the final %**, with no breakdown of Aim, range and Defense. Players will
  need one more than before, now that the terms actually move the number.

## 8. Implementation

| Where | What |
|---|---|
| `scripts/weapon_archetype.gd` | `WeaponArchetype`: the `Id` enum, `TABLE`, `TAIL`, `range_modifier`. |
| `scripts/combat.gd` | `MIN/MAX_HIT_CHANCE`, `AIMED_SHOT_BONUS`, `COVER_DEFENSE_*`, `HUNKER_DEFENSE`, `CONCEALMENT_*`; `compute_accuracy`, `ranged_defense`, `melee_defense`, `concealment`, `cover_defense`. |
| `scripts/weapon_data.gd`, `weapon_mod.gd` | `archetype`, `aim_modifier` (was `base_accuracy`), `effective_archetype`, `range_modifier`; mods' `archetype_override`. `optimal_range`/`falloff_rate` and the engaged accuracy fields are gone. |
| `scripts/unit_stats.gd` | `AIM_RECRUIT_MIN/MAX`, `AIM_CAP`, `defense`, `weapon_aim_modifier` (was `weapon_base_accuracy`), melee default 15. |
| `scripts/unit.gd`, `sagittarii_unit.gd` | `cover_defense_for` (was `cover_penalty_for`). |
| Presets | `class_presets`, `merc_presets`, `cerberus_presets`, `wrist_gun_presets`, `alien_presets`, `door_gun_unit`, `weapon_presets`, `ammo_presets` (Slug). |
| `scripts/campaign/soldier_record.gd` | `"aim"` save key and the old-save mapping. |
| UI | Loadout shows each gun's range table instead of an accuracy number; the roster shows "Aim". |
