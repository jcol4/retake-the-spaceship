# Close Quarters

*Decided 2026-11-13, implemented the same day; its accuracy half was replaced later that day by
the [accuracy rework](../accuracy/). Code: `Unit.is_engaged`, `engaged_shoot_ap` in
`scripts/weapon_presets.gd`; tests: `tools/test_close_quarters.gd`. See [§6](#6-implementation).*

When an enemy gets close, handy guns get cheaper to fire. **The long guns' clumsiness up close is
now in their distance tables** ([accuracy §4](../accuracy/#4-range-archetype-tables)), not here.

## Why

Two problems this set out to fix:

- **The Battle Rifle won up close.** Hit chance was pinned at 99% inside 3 tiles, so close fights
  came down to damage and penetration, where the Battle Rifle leads. Fixed by the accuracy rework:
  its table is −30 at 1 tile and −25 at 2, the LMG's −20 and −15.
- **The SMG's role was never built.** Its doc promised cheap, reliable Shoot spam, but every gun's
  firing AP modifier was 0. Fixed here.

## 1. Engaged

A soldier is **engaged** while a hostile **it can see** is **within 3 tiles** of it.

- **3 tiles**, counted with diagonals as 1 (Chebyshev): the range where the Shotgun's table is
  strongest and the long guns' tables are worst.
- **Can see** uses the same rays the squad's sight is drawn with (`tiles_have_sight`, either end
  free to lean). A cheaper shot never tells the player about an enemy they can't see, and a
  hostile one deck up or down doesn't count.
- **Aware or dormant both count. Downed bodies never count.**
- **Everyone holding the gun** gets the rule: player soldiers and rival mercs alike.

## 2. The rule

| Gun | While engaged |
|---|---|
| SMG | Shoot **1 AP cheaper** |
| Pistol | Shoot **1 AP cheaper** |
| everything else | nothing |

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

**Superseded: the long-gun accuracy penalties.** The first version also gave the Battle Rifle −80
on Shoot and Overwatch (−20 on Aimed) and the LMG −60 (−15) while engaged. Those numbers were
sized to bite through a hit chance that started at 113–167. The accuracy rework removed that
starting excess and moved "bad up close" into the distance tables. Those judge the distance to the
**target**, so a Battle Rifle with a zombie at its elbow now shoots a target 10 tiles away at full
accuracy.

## 3. What the player sees

**The current tile only.** The Shoot button's price reflects where the soldier stands now. Nothing
previews engagement during movement: no tint and no per-tile price on the move border.
(`shot_ready_cost`, which splits the move border's blue from its yellow, prices the shot at the
soldier's current tile.)

## 4. AI

The AI plans with engaged prices:

- `GoapPlanner` carries each plan's tile from node to node (`GoapAction.planned_tile`, set for
  Flank, RepositionToCover and Advance) and sets `GoapPlanner.PLAN_TILE` while it searches. Shot
  actions price at that tile (`GoapBrain.shot_cost`), so `[Flank, Attack]` is priced with the shot
  the flank tile actually gives.
- The move searches walk as far as the **cheapest** shot allows (`move_reach_keeping_shot`), then
  keep only tiles whose own shot still fits (`GoapBrain.keeps_shot_at`). For a gun with no
  engaged rule, this is exactly the old reach.
- The fire loops (`EnemyUnit._combat_turn`, the merc's finishing and boarding loops, the auto-play
  loops in `main.gd`) re-price Shoot every pass. An SMG's price goes back up when its last nearby
  hostile drops.

No new behaviors: no AI seeks or avoids engagement on purpose. It just sees the right prices.

## 5. Open items

- **Nothing tells the player *why*.** The Shoot price changes with no "engaged" label or tooltip.
- **An engaged merc may shoot before it flanks.** The planner minimizes AP. A merc already within
  3 tiles of its target has a 1 AP cheaper SMG shot where it stands than from a flank tile outside
  that range, so [Attack, Flank] can beat [Flank, Attack]. Having shot, it sometimes lacks the AP
  to reach a flank tile and takes cover instead. Found by `tools/test_goap.gd`'s suppress-then-flank
  check, which now starts its mercs at 4 tiles to keep testing the role hand-off. A tie-break
  toward flanking first would be new behavior, so it's left as a decision.

## 6. Implementation

| Where | What |
|---|---|
| `scripts/weapon_data.gd` | `engaged_shoot_ap`; `ap_modifier(action, engaged)`; `has_engaged_rule` / `has_engaged_ap_rule`. |
| `scripts/weapon_presets.gd` | The SMG's and Pistol's −1, read by `make`. |
| `scripts/unit.gd` | `ENGAGED_RANGE`, `is_engaged` (read through `grid_pos`), `action_cost` passing it for Shoot, `action_cost_at`, `cheapest_shot_cost`. |
| `scripts/unit_stats.gd` | `action_cost(action, engaged)` / `weapon_ap_modifier(action, engaged)`. |
| `scripts/ai/` | `GoapPlanner.PLAN_TILE`, `GoapAction.planned_tile`, `GoapBrain.shot_cost` / `keeps_shot_at`, the move and shot actions. |
| Fire loops | `enemy_unit.gd`, `merc_unit.gd`, `main.gd` re-price Shoot every pass. |
