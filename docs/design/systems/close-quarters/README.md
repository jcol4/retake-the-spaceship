# Close Quarters

*Decided 2026-11-13, implemented the same day. Code: `Unit.is_engaged`, the `engaged_*` columns in
`scripts/weapon_presets.gd`; tests: `tools/test_close_quarters.gd`. See [§6](#6-implementation).*

Some guns change when an enemy gets close. Long guns get clumsy and handy guns get cheaper to fire.
The goal is that **each gun is a real choice** rather than one gun winning everywhere.

## Why

Three problems, all visible in the numbers before this change:

- **The Battle Rifle won up close.** Hit chance is capped at 99%, and inside 3 tiles there's no
  distance penalty. A Sniper's Battle Rifle Shoot is about 167 before the cap (Perception 77 +
  35 + Reflexes 55). Even into heavy cover (−40) it still showed 99%. Accuracy differences
  disappeared up close, so close fights came down to damage, penetration and AP. The Battle Rifle
  leads on the first two.
- **The SMG's role was never built.** Its doc promised "cheap, reliable Shoot spam", but every
  gun's firing AP modifier was 0. The SMG paid the same AP per shot as everything else for the
  least damage.
- **The LMG had no downside.** Once the AP rework removed its 75% move speed, it beat the Assault
  Rifle on damage (9 vs 8), penetration (60 vs 45) and magazine (6 vs 3) at the same total ammo.
  Its 2 points of lower accuracy are erased by the cap.

## 1. Engaged

A soldier is **engaged** while a hostile **it can see** is **within 3 tiles** of it.

- **3 tiles**, counted with diagonals as 1 (Chebyshev). This matches the global distance curve's
  no-penalty zone and the Shotgun's optimal range, so "close" means one thing across the game.
- **Can see** uses the same rays the squad's sight is drawn with (`tiles_have_sight`, either end
  free to lean). A cheaper shot or a worse hit chance never tells the player about an enemy they
  can't see, and a hostile one deck up or down doesn't count.
- **Aware or dormant both count.** Being close is what makes a long gun awkward, not being
  noticed. **Downed bodies never count.**
- **It belongs to the shooter, not the target.** An engaged Battle Rifle is clumsy whoever it's
  pointed at, including a target 10 tiles away.
- **Everyone holding the gun** gets the rule: player soldiers and rival mercs alike.

## 2. The roster

| Gun | While engaged |
|---|---|
| Battle Rifle | **−80** Shoot and Overwatch · **−20** Aimed Shot |
| LMG | **−60** Shoot and Overwatch · **−15** Aimed Shot |
| SMG | Shoot **1 AP cheaper** |
| Pistol | Shoot **1 AP cheaper** |
| Assault Rifle | nothing: the generalist, never bad anywhere |
| Shotgun | nothing: already lives at this range (14 damage, splash) |

### Accuracy penalties

They apply **before** the 1–99 clamp, like every other term in `Combat.compute_accuracy`, which is
why they're large. A soldier far above 99 loses only what was above it.

**Battle Rifle Shoot**, mid-roll stats (open / behind heavy cover). The table also shows how
heavily stats dominate:

| Class | Raw | Not engaged | Engaged (−80) |
|---|---|---|---|
| Sniper | ~167 | 99 / 99 | 87 / 47 |
| Support | ~145 | 99 / 99 | 65 / 25 |
| Assault | ~130 | 99 / 90 | 50 / 10 |
| Heavy | ~120 | 99 / 80 | 40 / 1 |

**Aimed Shot is penalized less**, a quarter of the Shoot figure for both guns. Aimed Shot has no
Reflexes in it, so its raw number is ~55 lower. At −20, an Aimed torso stays a little better than
the −80 Shoot (Sniper 92 vs 87, Assault 55 vs 50). Up close the Battle Rifle's answer is "slow down
and aim" at 3 more AP. Around −25 the two break even, and above that aiming isn't worth it at all.

The **Suppress break shot** (fired when a pinned target moves) rolls as a Shoot, so it takes the
Shoot penalty. A pinned enemy running *at* the gunner is exactly the weakness these guns are meant
to have.

### SMG and Pistol: cheaper Shoot

Only Shoot is affected; Aimed Shot, Overwatch, Suppress and Reload keep their prices. The −1 joins
the gun's other Shoot modifiers **before** the `MAX_AP_DISCOUNT` floor, so it **stacks with a Laser
Sight to −2 and no further**.

| Reflexes 45–65 | Shoot |
|---|---|
| plain | 5 AP |
| engaged | 4 AP |
| engaged + Laser Sight | 3 AP |

A 12 AP soldier with an SMG, engaged and carrying a Laser Sight, fires 4 times. That empties the
4-round magazine for up to 24 damage, enough to kill a ~20 HP soldier if every shot lands. It only
works up close, it burns the whole magazine every turn, and the Laser Sight makes the carrier
1.5× easier to spot.

## 3. What the player sees

**The current tile only.** The Shoot button's price and the hit chance both reflect where the
soldier stands now. Nothing previews engagement during movement: no tint and no per-tile price on
the move border. (`shot_ready_cost`, which splits the move border's blue from its yellow, prices
the shot at the soldier's current tile.)

## 4. AI

The AI plans with engagement taken into account:

- `GoapPlanner` carries each plan's tile from node to node (`GoapAction.planned_tile`, set for
  Flank, RepositionToCover and Advance) and sets `GoapPlanner.PLAN_TILE` while it searches. Shot
  actions price at that tile (`GoapBrain.shot_cost`), so `[Flank, Attack]` is priced with the shot
  the flank tile actually gives.
- The move searches walk as far as the **cheapest** shot allows (`move_reach_keeping_shot`), then
  keep only tiles whose own shot still fits (`GoapBrain.keeps_shot_at`). For a gun with no
  engaged AP rule, this is exactly the old reach.
- `GoapBrain.accuracy_from` already swaps the candidate tile into `grid_pos`, so an engaged
  penalty at a candidate tile is seen without any change. That matters for the mercs' LMGs.
- The fire loops (`EnemyUnit._combat_turn`, the merc's finishing and boarding loops, the auto-play
  loops in `main.gd`) re-price Shoot every pass. An SMG's price goes back up when its last nearby
  hostile drops.

No new behaviors: no AI seeks or avoids engagement on purpose. It just sees the right prices.

## 5. Open items

- **Nothing tells the player *why*.** The hit chance drops and the Shoot price changes with no
  "engaged" label or tooltip. A tag on the Shoot button or the hit chance is the obvious next step.
- **The 99% cap still erases most accuracy differences**, not just up close. Base accuracies span
  20–35 while class Perception spans 30–90, so the soldier matters far more than the gun. This
  change works around that with large pre-cap penalties rather than fixing it.
- **Tuned against today's classes.** The tables above use the current Assault, Sniper, Support and
  Heavy stat ranges, which are expected to change.
- **AI deliberately does nothing new.** If merc SMGs should rush and merc LMGs should back off,
  that's new behavior, not pricing.
- **An engaged merc may shoot before it flanks.** The planner minimizes AP. A merc already within
  3 tiles of its target has a 1 AP cheaper SMG shot where it stands than from a flank tile outside
  that range, so [Attack, Flank] can beat [Flank, Attack]. Having shot, it sometimes lacks the AP
  to reach a flank tile and takes cover instead. Found by `tools/test_goap.gd`'s suppress-then-flank
  check, which now starts its mercs at 4 tiles to keep testing the role hand-off. A tie-break
  toward flanking first would be new behavior, so it's left as a decision.

## 6. Implementation

| Where | What |
|---|---|
| `scripts/weapon_data.gd` | `engaged_accuracy`, `engaged_aimed_accuracy`, `engaged_shoot_ap`; `ap_modifier(action, engaged)`; `has_engaged_rule` / `has_engaged_ap_rule`. |
| `scripts/weapon_presets.gd` | The roster's values (§2), read by `make`. |
| `scripts/unit.gd` | `ENGAGED_RANGE`, `is_engaged` (read through `grid_pos`), `action_cost` passing it for Shoot, `action_cost_at`, `cheapest_shot_cost`. |
| `scripts/unit_stats.gd` | `action_cost(action, engaged)` / `weapon_ap_modifier(action, engaged)`. |
| `scripts/combat.gd` | `compute_accuracy` adds the engaged term before the clamp. |
| `scripts/ai/` | `GoapPlanner.PLAN_TILE`, `GoapAction.planned_tile`, `GoapBrain.shot_cost` / `keeps_shot_at`, the move and shot actions. |
| Fire loops | `enemy_unit.gd`, `merc_unit.gd`, `main.gd` re-price Shoot every pass. |
