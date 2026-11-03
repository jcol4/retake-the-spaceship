# Bullet Penetration

*Decided 2026-11-03, implemented the same day. Code: `scripts/penetration.gd`; tests:
`tools/test_penetration.gd`. See [§9](#9-implementation).*

Every firearm can now hit more than the body it was aimed at. The point is **crowd control against
Fodder hordes**: a well-lined-up shot down a corridor of zombies damages several of them for one
round of ammo. It is faction-agnostic, so it cuts both ways — a rival merc's LMG through a zombie can
hit the player's soldier standing behind it.

## 1. The path

- Draw a **Bresenham** tile line from the shooter through the intended target, and keep extending it
  past the target until something stops it.
- Height is interpolated along the line at the shooter → target slope. The line ends at the first
  tile where its height drops below that tile's floor — so a shot fired down from high ground runs
  into the floor a few tiles behind the target, and a level shot runs on until something else stops
  it.
- **Stops the line:** walls, closed doors, **heavy cover**, map edge.
  - Heavy cover protecting a body on the path still lets that body be hit (with its cover penalty,
    exactly as a primary target would be). The line stops *behind* that body.
- **Light cover** does not stop the line, but the bullet pays to cross it — the same cost as an
  armored body (§2).
- Both cover tiers the line crosses take damage (see §5).
- Bodies **do not need to be visible** to anyone. A stray round into the dark can hit — and wake —
  what is sitting there.

## 2. Penetration stat

`pen` is a percentile stat, 0–100, on the weapon. It is never rolled per soldier; ammo and
attachments modify it.

```
b      = pen / 25                 # effective body count, unfloored
bodies = floor(b)                 # how many bodies the round passes THROUGH (the first hit is free)
keep   = b / (b + 1)              # fraction of damage kept per body passed through
damage at the nth body behind the first = base × keep^n   (rounded)
```

Brackets: 0–24 → 0, 25–49 → 1, 50–74 → 2, 75–99 → 3, 100 → 4.

| Weapon | Pen | Bodies | Keep | Damage chain |
|---|---|---|---|---|
| Pistol | 25 | 1 | 50% | — |
| SMG | 30 | 1 | 55% | 6 → 3 |
| Assault Rifle | 45 | 1 | 64% | 8 → 5 |
| LMG | 60 | 2 | 71% | 9 → 6 → 5 |
| Battle Rifle | 80 | 3 | 76% | 10 → 8 → 6 → 4 |
| Shotgun (buckshot) | — | — | — | splash instead, §4 |
| Shotgun (Slug Rounds) | 80 | 3 | 76% | line penetration like the Battle Rifle |
| Cerberus weapons, extraction door gun | 60 | 2 | 71% | LMG tier |
| Spitter | 0 | 0 | — | no penetration |

**Spending pen.** The first body is hit for free. Passing *through* a body that was hit spends 25 pen
(one bracket) and one `keep` step. These cost **an extra 25 pen and an extra `keep` step** on top:

- an **armored** body (`UnitStats.armored`). Armor still reduces that body's damage as normal.
- a **light cover** edge. A body's own light cover is paid when passing it, hit or miss. An edge
  crossed into an empty tile behind the target is paid when crossed.

The round reaches the next body as long as it could pay to pass the last one. When it can't pay to
pass a body, the line ends inside that body. Example: an LMG (60) hits an armored merc for free,
pays 50 to pass through it, hits the zombie behind, and can't pay to pass that one with 10 left.

A body's own cover never reduces the damage it takes, only its hit chance (as before). What it costs
only comes off the rest of the round.

**Ammo:**
- **Penetrator Rounds** — now **+20 pen** only (BR → 100: 4 bodies, 80% keep).
- **FMJ** — takes Penetrator's old job: **+34% damage vs armored**. Loses its +2 accuracy.

**Attachments** can modify pen (which ones and by how much: open, §8).

## 3. Rolls

Every body on the path rolls separately, with all of its own modifiers — cover, hunker, light,
distance — and both Luck layers (the shooter's reroll, the victim's lucky dodge).

**Secondary hits are never crits.** They take flat torso damage: no crit, no headshot, no stun, no
body-part injury. Aimed Shot stays about the body you picked.

### Shooting at a target behind bodies

Every body between the shooter and the intended target is a tax on the shot:

- The intended target's accuracy takes **−30 per body in front of it**.
- Every body on the whole path rolls `min(that reduced accuracy, its own accuracy)`.
- If pen runs out before the line reaches the intended target, **that target can't be selected**.

### Misses

- **The first roll on the path missing ends the shot.** Everything behind is safe — including the
  intended target when you aimed through a crowd. Shooting through bodies at a Brute is a gamble.
- **A later miss does not end the shot.** The round goes past that body and carries on. A missed body
  costs **no pen and no `keep` step**.

## 4. Shotgun splash (buckshot)

Buckshot has no line penetration. Instead, a **hit on the primary target** splashes into the five
tiles of a half-ring around the target, facing the shooter: **front, front-left, front-right, left,
right**. The facing is the shooter → target direction snapped to the nearest of 8.

- Each body in those tiles rolls separately, under the same rules as penetration (own modifiers,
  both Luck layers, never crits).
- Damage is **full**, not reduced.
- A miss on the primary means no splash.
- Buckshot can't target a body with another body in front of it; you shoot the front one.

Slug Rounds swap the shotgun to line penetration at 80 pen (§2).

## 5. Side effects

- **Friendly fire: none.** The shooter's own faction "ducks" — they are invisible to the round,
  cost nothing, and the line passes their tile. (An animation may come later; mechanically it doesn't
  exist.) Every other faction is fair game.
- **Secondaries count as shot at:** their cover takes damage, and they are alerted (a stray round
  can wake a dormant horde).
- **Cover damage** from a secondary is the **reduced damage that reached that body**, not the
  weapon's full `weapon_damage`.
- **Carried bodies:** a hit on a carrier goes to the carrier *or* the carried body under the existing
  redirect rule (`Unit.redirects_hit_to_carried`), never both.
- **Downed units** are never hit by collateral — only when they are the intended target.
- **The worm** is a single-tile mass (one `WormUnit` whose HP is the pile), so it's one body like
  any other.

## 6. Which actions

| Action | Penetrates |
|---|---|
| Shoot | yes |
| Aimed Shot | yes (secondaries take flat torso hits, §3) |
| Overwatch | yes |
| Suppress | **no** |

Each trigger pull is still one round of ammo.

## 7. Not doing (for now)

- **No preview.** The HUD doesn't show the path or who else will be hit.
- **AI doesn't use penetration when choosing targets.** Rival mercs and Cerberus pick targets as they
  do now, and collateral is a side effect. *Follow-up: teach target scoring to value lined-up shots
  (and to prefer targets it can actually reach under §3's "can't be selected" rule).*
- Horde size and spawn frequency stay as they are until playtesting says how much penetration shifts
  the Fodder attrition math.

## 8. Open items

- Which attachments modify pen, and by how much. Natural candidates: Long Barrel (+), Suppressor (−).
- The "target can't be selected when pen runs out" rule (§3) reads the user's answer as "untargetable"
  rather than "you just hit the front bodies" — confirm in playtest.
- The combat log shows a multi-body shot as one line: the target's result, then
  `| also: <name> (<acc>%): <result>; ...`. Splitting it into one line per victim is a later call.
- Collateral hits show the impact flash but there's no tracer to the bodies behind.
- `GoapBrain.read_state`'s `has_los` fact is still plain line of sight. A merc whose plan picks a
  target it can't reach finds out when the shoot action's `execute` refuses it (`has_shot_at`) and
  replans. Fold reach into the fact when AI target scoring learns about penetration (§7).

## 9. Implementation

| Where | What |
|---|---|
| `scripts/penetration.gd` | `trace` (the path), `can_reach`, `through_penalty`, `resolve` (all rolls), buckshot `splash_tiles`. |
| `scripts/combat.gd` | `resolve_shot` takes an accuracy cap, damage scale and `collateral` flag. `ShotResult` carries `collateral`, `unit`, `blocked_by`. `describe` prints the collateral. |
| `scripts/unit.gd` | `has_shot_at` (line of sight + reach). `fire_at` resolves through `Penetration` and lands collateral (`_land_collateral`). Suppression's break shot passes `penetrates = false`. |
| `scripts/weapon_data.gd`, `weapon_mod.gd` | `penetration`, `splash`; mods add `penetration` and can set `replaces_splash`. |
| Presets | Weapon pen values; Penetrator/FMJ/Slug in `ammo_presets.gd`; Cerberus and door gun at 60. |
| Targeting | Shoot / Aimed Shot / Overwatch checks use `has_shot_at`: player actions and target bar, auto-play, overwatch, GOAP shoot actions, alien, merc and door gun. Suppress still uses plain line of sight. The HUD's hit chance and Aimed Shot zone menu include the −30 per body in front. |
