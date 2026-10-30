# Exploration Implementation Plan

Written 2026-10-28 against `3d-models` @ `e269a952`. **Design source of truth:
[`game-design-document.md`](game-design-document.md) v2.2**, mainly §4.7 (exploration mode & turn
mode), §7.6 (co-op) and §12.2 steps 9–10. This file covers *how* to build it. The GDD covers *what*
to build. If they disagree, fix the GDD first. The decisions table at the end is folded into GDD
v2.2.

## Status (2026-10-30)

Phases A, B, C and D.1–D.3 are built. `tools/test_exploration.gd` covers them headless, and
`tools/test_tick_playback.gd` covers playback and the display layer (it needs a window).

**Still open:**
- **The manual two-instance Steam checklist (Phase C).** Only the rules-level co-op tests have run,
  so the RPCs (`_rpc_play_tick`, `_rpc_mode_changed`, `_rpc_clock`, `_rpc_command_rejected`) have
  never crossed a real connection.
- **D.4, retuning, and its playtest checkpoint.** All of it needs a human: `STEPS_PER_ROUND` and the
  round timers are unchanged.

**Where the build differs from the text below:**
- **Redirect (B.5):** the new goal is swapped into the walk in flight at its next tile, rather than
  cancelling, awaiting the stop and walking again. It meets E9 and skips a stop animation per click.
- **Attack to start (B.7):** attacks call `TurnManager.notify_attack` outright. `come_under_fire`
  alone misses a one-shot kill and a target already fighting someone else.
- **Reaction shots (B.8):** `check_overwatch` also reports contact itself, for the same one-shot
  reason, and because a soldier being shot has no `come_under_fire` to reach.
- **Nests (B.4):** they are also excluded from `notify_combat` and `_squad_in_contact`. A nest never
  takes a turn, so it can never lose contact, and would hold the squad in turn mode forever.
- **Mid-tick commands (A.4):** `may_act` also refuses commands while a tick runs or contact is
  pending, except re-aiming a paused walk.
- **`--auto` (D.1):** soldiers keep using the existing helpers on a synthetic AP pool
  (`Unit.auto_budget`) rather than `_issue`, with what each think spent charged to the clock at its
  end. `TurnManager.hold_switch` makes the mode switch wait for a think to finish.
- **Doors (B.6, B.12):** no door command or AI door toggle exists yet, so there is nothing to price
  or record.
- **Commits (Phase A):** A and B share files too closely to split, so they landed as one commit.

---

Steps 9 and 10 are **partially merged**: the groundwork both need is built co-op-correct inside
step 9 (Phase A), and simultaneous co-op input stays its own phase (C) on top of a working
single-player mode (B). Each phase ends playable and tested.

```
A Groundwork ─> B Exploration mode (step 9) ─┬─> C Co-op exploration (step 10)
                                             └─> D --auto & tuning
```

C and D are independent of each other once B is in.

---

## Ground rules (apply to every phase)

- **Everything in [`EXTRACTION_PLAN.md`](EXTRACTION_PLAN.md)'s ground rules still holds:**
  host-authoritative state, every player command in `PlayerUnit._COMMANDS`, headless
  `tools/test_*.gd` tests, named `const`s beside the code that uses them.
- **`TurnManager.turn_number` stays the only clock.** Out of combat it advances through the same
  `_end_round` / `turn_started` path it does in combat, so every round timer (bleed-out, ship
  countdown, Hold terminal, nest spawns, merc leave rounds, escalation) keeps working unchanged.
  No system gets an exploration-specific timer.
- **Turn mode must not change while exploration is off.** A `TurnManager.exploration_enabled`
  flag (like `clear_out_mode`) stays **off** until Phase B lands, so every existing test and the
  `--auto` run pass through Phase A untouched.
- **Pure rules go in an engine-free `ExplorationRules`** (step accounting, carry-over, the
  enter/leave predicates), testable without a scene, as `ExtractionRules` is.

---

## Phase A — Groundwork

The seams both modes and both players need. Small separate commits, all invisible with
exploration off.

### A.1 Per-step occupancy in `Unit.move_along`
- Today a walker nulls its start tile, holds **no tile** for the whole walk, and reclaims only on
  arrival. The comment at `unit.gd:587` states the assumption outright: "only one unit ever moves
  at a time". Exploration and co-op both break it.
- Claim each tile on entry and release the one left behind. A unit downed mid-walk releases its
  tile (a body holds none, as today). A carried body still shares the carrier's tile via
  `_carry_follow`.
- If the next tile on the path has become occupied mid-walk, repath once from the current tile to
  the goal; if there is no path, stop where you stand (E18).
- Audit callers that relied on a walker holding no tile: `GridManager.is_free`, the occupancy
  checks in line of sight and cover, and overwatch's per-step check.

### A.2 Goal reservation in `GridManager`
- `reserve(tile, unit)` / `release_reservation(unit)`. A reserved tile is closed **as a
  destination** for every other unit but stays open to pass through.
- Reserved by the host when it accepts a move. Released on arrival, cancel, redirect, death, or
  the owning peer leaving.

### A.3 Walk cancel
- `Unit.cancel_walk()` sets a flag that `move_along` checks after each tile, beside its existing
  `is_downed` break. The walker **finishes the tile it is stepping onto** and stops there (E7),
  then runs the normal arrival tail (cover snap, idle settle, `moved`).
- `TurnManager` tracks in-flight walkers (`_walking`, maintained by `move_along`).
  `cancel_all_walks()` cancels every one and awaits them all; the mode switch (B.3) needs this
  drain before any initiative draw.

### A.4 `may_act` replaces the `active_unit` gates
- Three places treat `TurnManager.active_unit == self` as authorization:
  - `PlayerUnit._accepting_input` (`player_unit.gd:673`),
  - `PlayerUnit._rpc_command` (`player_unit.gd:597`),
  - `TurnManager._rpc_request_end_activation` / `_finish_activation`.
- Replace them with `TurnManager.may_act(unit, peer_id, method) -> String`, a blocker string that
  is `""` when allowed, in the style of `revive_blocker`:
  - **Turn mode:** `unit` is the drawn `active_unit`. Identical to today.
  - **Exploration:** `peer_id` owns `unit` and it is not mid-action, except `_try_move`, which is
    allowed mid-walk so that it can redirect (E9).
- The client's `_accepting_input` asks the same function with the local peer id.

### A.5 Cost seam: `Unit.pay(cost)` and `can_afford(cost)`
- Turn mode: `pay` is `spend_ap`, and `can_afford` is `ap >= cost`.
- Exploration: `pay` adds `cost` steps to the clock (B.2), and `can_afford` is always true.
- Move the 12 `spend_ap` sites in `player_unit.gd` onto `pay`, and their `ap < cost` checks onto
  `can_afford`. Prices still come from `Unit.action_cost` / `UnitStats.FLAT_AP_COST`, so "steps
  equal to AP price" (§4.7.3) needs no second table.
- AI `spend_ap` sites stay as they are: AI only ever acts inside a round, with AP from
  `begin_activation`. The 18 `--auto` sites in `main.gd` are Phase D.

### A.6 `active_unit` as per-peer selection
- In turn mode nothing changes: the host draws and syncs it.
- In exploration each peer sets its **own** `TurnManager.active_unit` when its player selects a
  soldier. There is no RPC, and the host never reads it for authority (A.4). The HUD's 13 reads
  and `active_marker.gd` work unchanged.

**Tests:** extend `test_movement.gd`:
- two crossing walkers never share a tile,
- a reserved goal refuses a second unit but lets it pass through,
- a cancel stops on the next tile boundary with occupancy correct,
- `may_act` in turn mode matches today's gate exactly.

All existing tests and `--auto` pass with exploration off.

---

## Phase B — Exploration mode (GDD step 9)

### B.1 Mode state in `TurnManager`
- `enum Mode { EXPLORATION, TURN }`, `var mode`, `signal mode_changed(mode)`, mirrored to clients
  by `_rpc_mode_changed`. It lives in `TurnManager` rather than a new autoload so `turn_number` and
  its signals keep one owner (E2).
- Split `_start_turn` into:
  - `_begin_round()`: increment, bleed, flicker reroll, `turn_started` plus its RPC.
  - The pool snapshot and draw.

  Turn mode runs both. The exploration tick (B.2) runs `_begin_round` plus the AI pass.
- `start_mission` with exploration enabled: begin round 1 in `EXPLORATION`.

### B.2 The step clock
- `var steps`, `const STEPS_PER_ROUND := 20` (§4.7.3; tune in D.4). Host-only.
- `add_steps(n)` only **records** steps. Crossing 20 queues a tick and keeps the remainder:
  19 + 3 → tick, counter at 2 (E6).
- `settle_clock()` runs any queued tick, or awaits one already running. It is called at two
  points:
  - **Each tile of a walk:** after the per-tile checks in `move_along`. Each tile adds
    `move_ap_per_tile()` steps (1, or 2–3 on a wounded leg; E17). This is the pause in
    pause-tick-resume (E5): every walker reaching a tile boundary while a tick runs waits there.
  - **The end of each command:** the 15 existing `_check_activation_end()` calls in
    `player_unit.gd`. In exploration, `_check_activation_end` awaits `settle_clock` instead of
    ending an activation, so an action always lands before the round it crossed ticks (E6).
- **The tick:**
  1. `_end_round()`: hooks, so a departure can still end the mission.
  2. `_begin_round()`.
  3. An AI pass: every non-player unit not downed takes `begin_activation` + `take_turn` in a
     weighted-initiative order, **resolved one at a time as logic only and recorded**, then played
     back together (B.12). Player units take no activation.
- If turn mode starts during a tick (a patrol walks into the squad), the rest of that tick's AI
  turns are dropped (E20). The units already resolved still play back; the one that started the
  fight is always the last recorded.
- **Standing still adds nothing.** Wait (B.10) is the only way to pass time without acting.

### B.3 Entering turn mode
- One entry point: `EnemyUnit._enter_combat` calls `TurnManager.notify_combat(self)`. Every
  channel that starts a fight already funnels through `_enter_combat` (sight, beam,
  `come_under_fire`, a merc's radio relay), so none needs its own hook.
- `ExplorationRules.targets_squad(enemy)`: the enemy's target is on the squad's side, meaning one
  of the player's soldiers, their door gun, or the Recover VIP (contractor faction). An ALERT enemy
  investigating does not count; it never reaches `_enter_combat`. A fight between two other
  factions does not count either: it enters COMBAT, but not against the squad.
- **On trigger:**
  1. `cancel_all_walks()` and await the drain (A.3), and any tick playback (B.12).
  2. Set `mode = TURN` and discard the leftover steps. **The round in progress becomes the
     opening combat round** (E19): same `turn_number`, no `_begin_round`, so contact by itself
     ticks no timer. Snapshot the pool and run the normal weighted draw. There is no surprise
     round. The round-end hooks and the next round's timers fire when that round's pool empties,
     as in any combat round.

### B.4 Per-step detection
- In `move_along`, after `stepped` and only for player-controlled walkers in exploration: every
  `EnemyUnit` within its own `detection_range` of the walker, not downed and not already in
  COMBAT, runs its **own `_look_for_targets()`** (E23). Cerberus and merc overrides keep their
  faction rules that way, and an alien that spots a robot instead of the soldier stays a
  cross-faction fight that does not start turn mode.
- **Skip `NestUnit`**: it has no senses, but it inherits `_look_for_targets` from `EnemyUnit`.
- The beam channel is already per-step: `move_along` recomputes lighting each tile, which drives
  `_on_lighting_changed`.
- A spotted walker stops on that tile: `notify_combat` → `cancel_all_walks`, and the walker has
  just finished it.

### B.5 Free move
- `_try_move` in exploration: an uncapped `find_path`, no AP check, reserve the goal (A.2), and pay
  steps per tile inside the walk (B.2) rather than up front.
- Redirect (E9): a `_try_move` on a walking soldier cancels the walk, awaits the stop, and paths
  from the tile reached.
- No area overlay (E13). The HUD previews the path to the hovered tile, labelled with its step cost
  and the rounds it will pass ("23 steps · 1 round"). Recompute only when the hovered tile
  changes.

### B.6 Free actions
- Everything §4.7.4 lists goes through `pay`: loot, doors, flashlight, reload, switch weapon,
  revive, pick up, drop, call ship, board, operate terminal, extract.
- **Unavailable in exploration:** Hunker (E21). It protects against nothing until a fight starts.
- Shoot, aimed shot, grenade, melee and **Suppress** are attacks (B.7). Overwatch is B.8. Face is
  free.
- **HUD:** hide the AP readout and show the clock instead ("12 / 20 · round 7").

### B.7 Attack to start
- Shoot, aimed shot, grenade or melee from exploration resolves normally. The target's
  `come_under_fire` reaches `notify_combat`, and turn mode starts (B.3).
- The shooter records `pre_spent_ap = cost` (host-only). `begin_activation` then gives them
  `ap_pool() - pre_spent_ap` (floored at 0) and clears it (E8). There's no free alpha strike:
  either side's opening is still a normal draw.
- **An opening Suppress is the suppressor's whole first activation** (E21). Suppress ends the
  activation it is used in, and `begin_activation` releases the suppressor's pin, so a suppressor
  drawn early would drop the pin before anyone used it. Instead the suppressor is left out of the
  opening round's pool. The pin holds through that round and releases at their round-2
  activation, exactly as a Suppress made in turn mode does. No `pre_spent_ap` for it.

### B.8 Overwatch across the boundary
- Settable in exploration, at its AP price in steps (E22).
- Holds until it fires or **that soldier** moves or acts: `pay` and `move_along` clear the unit's
  own `on_overwatch` in exploration. **Wait is not acting** (E26): it never clears overwatch,
  which is what lets a squad sit in an ambush and pass rounds (B.10).
- It fires on AI movement during a tick. `check_overwatch` already runs in every `move_along`, and
  the shot's `come_under_fire` starts combat.
- Into turn mode it behaves as today: `begin_activation` clears it at that soldier's first
  activation.

### B.9 Leaving turn mode
- Track `_last_squad_combat_round`, set by `notify_combat` and by any enemy still in COMBAT
  against the squad at a draw. At each turn-mode `_end_round`, once a full round has passed with
  none (`ExplorationRules.quiet_for_a_round`), switch to `EXPLORATION` at the start of the next
  round.
- **On the switch (E10):**
  - clear `hunkered`, both ends of suppression (`release_suppression`, `suppressed_by`) and
    `stunned` on every unit, and **keep** `on_overwatch`;
  - clear the pool, set `active_unit = null` so each peer reselects, and set `steps = 0`.

### B.10 Wait
- `try_wait` on `PlayerUnit` (added to `_COMMANDS`): add the steps remaining to the boundary, then
  settle. It always advances exactly one round (E11), and repeated presses wait longer.
- It lives on a soldier only so it can ride the `_issue` → `_rpc_command` path. It calls
  `TurnManager.add_steps` directly, **not** `pay`, so it doesn't count as that soldier acting
  (E26).
- **HUD:** a "Wait → round N+1" button, shown in exploration only.

### B.11 HUD
- A mode banner, the step clock, and the path readout.
- The Wait button.
- The AP bar and turn-only buttons are hidden in exploration.
- **Squad portrait bar, in both modes** (E24):
  - one portrait per soldier with HP, downed and carry status;
  - your own soldiers select on click (and Tab cycles them); in co-op the partner's are shown
    greyed and read-only;
  - in turn mode, the drawn unit is highlighted, and clicks don't change selection;
  - clicking a soldier in the world still selects them.

### B.12 Tick playback
Every AI turn in a tick is **decided in order and animated together** (E25). The decisions stay
sequential, so no AI code changes and results stay repeatable. Only the presentation runs in
parallel.

- **Record.** During the AI pass every unit runs in logic-only mode, the same path a hidden unit
  takes today (`is_instant`). Grid state, occupancy, HP and life state settle immediately. Each
  unit appends events to a tick timeline:
  - each tile stepped, with the facing (yaw) on arrival,
  - turns in place,
  - flashlight toggles,
  - shots (shooter, target, result),
  - downs and deaths,
  - nest spawns,
  - door toggles.
- **Schedule.** Each event gets the earliest time slot that is after the unit's own previous event
  *and* after every event it depended on. Two dependencies matter:
  - **A tile vacated.** B stepping into a tile that A left at A's slot *j* is scheduled at *j* + 1
    or later. This stops the passing-through overlap.
  - **A target in place.** A shot at a unit that moved this tick waits until that unit's last
    step has played, so the shot lands where the target is drawn.

  One pass over the events, in the order they were recorded.
- **Play.** Walk the slots at the usual step speed. Each unit's **root** is already at its final
  tile (logic truth). The **`UnitVisual` child** is what animates along the recorded path, then
  re-zeroes onto the root. Shots, hit reactions, downs and spawns play at their slots. This needs
  replay entry points for a shot and a down that do the visuals only, no rolls or damage.
- The tick isn't done until playback finishes. Paused walks resume, and `settle_clock` returns,
  only after that.
#### B.12.1 Beams follow the replayed path (E27)
- **The visible beam already follows for free.** It is a `SpotLight3D` on the model's barrel
  (`unit_visual.gd` `_build_light`), so it rides the animating `UnitVisual` along the recorded
  path.
- **What doesn't follow is the tile light.** The rules' `light_value` is already final, and three
  on-screen readers use it:
  - tile highlight brightness, `highlight_manager.gd:93`;
  - model shading, `unit_visual.gd:582` (`_apply_floor`);
  - the HUD light readout, `hud.gd:216`.

  Left alone, the beam would sweep the floor while those stay frozen at the final state. That
  breaks the rule `LightingManager._aim_of` exists to hold: what looks lit is what counts as lit.
- **The rules layer must not move during playback.** Every `recompute_dynamic` emits
  `lighting_changed`, and `EnemyUnit._on_lighting_changed` changes alert states on it. Replaying
  the path through the real layer would re-run detection on a tick that has already been decided.
- **So `LightingManager` gets a display-only layer:**
  - `begin_display()` / `end_display()` bracket a playback.
  - `recompute_display()` runs at every slot, the same per-tile cadence a real move recomputes
    at. It combines the base layer with each flashlight unit's beam, cast from its **model's**
    tile and `aim_direction()`. Units not in the tick use their real position.
  - It never writes `light_value` and never emits `lighting_changed`. It emits
    `display_lighting_changed` for the highlight refresh instead.
  - `display_light(pos)` returns the display value during playback, and `light_value` otherwise.
- **One beam formula.** Factor the per-unit loop of `recompute_dynamic` into a shared
  `_beam_contribution(origin_tile, origin_pos, aim, unit)`, so the display layer and the rules
  layer can't drift apart.
- **The three readers switch to `display_light`.** The rules readers (`Combat`, `EnemyUnit`,
  `AgileHunterUnit`) keep `light_value`.
- **No jump at the end.** The last slot is each unit's final tile and facing, so the display layer
  equals the rules layer when `end_display()` drops it.
- **Headless runs skip the display layer** entirely.

#### B.12.2 Visibility follows the replayed path (E28)
- Today a unit is drawn if its room is revealed (`MapBuilder` → `Unit.set_rendered`), judged from
  its **root**, which during playback is already at the final tile.
- Add `Unit.set_display_visible(bool)`. It toggles only `visual.visible`, never `_rendered`,
  which gates logic through `is_instant`. At each slot, a unit is drawn if its **model's** tile is
  in a revealed room, so a patrol visibly walks into view and out of it. `end_display()` restores
  every unit to its `_rendered` state.
- Use the revealed set as it stands at the end of the tick. The squad is paused, so nothing
  reveals mid-playback.
- A unit whose model is never on a revealed tile during the tick isn't animated at all. Its beam
  still feeds the display layer, as it feeds the rules layer today.

**Tests:** new `tools/test_exploration.gd` on `maps/test_deck.txt` / `maps/extraction_test.txt`,
with the pure parts in `ExplorationRules`:

- 20 steps tick one round, and 19 + 3 ticks with 2 carried;
- a wounded leg's tile costs 2 steps (one leg) or 3 (two legs);
- a revive started at 19 steps lands before that round's bleed tick;
- bleed, ship countdown and Hold terminal advance on steps; standing still advances nothing; wait
  advances exactly one round;
- a walker spotted mid-path stops on that tile and the mode is TURN, with `turn_number` unchanged
  and no bleed tick;
- an ALERT enemy, and an alien fighting a robot, start nothing;
- the opening shooter's first activation has `ap_pool - cost`;
- an opening Suppress leaves the suppressor out of round 1's pool, and the pin holds until their
  round-2 activation;
- wait on a soldier holding overwatch keeps their overwatch;
- the tick scheduler: a step into a just-vacated tile is slotted after the vacating step, and a
  shot at a mover after the mover's last step;
- the display layer, built from a recorded path, matches `recompute_dynamic` for the same tile and
  aim; it leaves `light_value` untouched and emits no `lighting_changed`; at the last slot it
  equals the rules layer (needs a window, like `test_room_visibility.gd`, since aim comes from the
  model);
- a quiet round returns to exploration with hunker, suppression and stun cleared and overwatch
  kept;
- overwatch set in exploration fires on a patrol during a tick and starts combat.

---

## Phase C — Co-op exploration (GDD step 10)

Small if Phase A is right. Most of the work is verification.

### C.1 Concurrent commands
- The host accepts moves and actions from both peers at once through `may_act` (A.4). Each walk is
  its own coroutine on the host. Per-step occupancy (A.1) and reservations (A.2) keep two
  concurrent walks safe.

### C.2 Goal clash
- A move to a tile another unit has reserved is **rejected** (E15). The host answers with
  `_rpc_command_rejected(reason)` to the sender, and the client shows "tile taken". Keep the RPC
  generic: other refused commands can use it too.

### C.3 The host-ordered step counter
- `add_steps` runs only on the host, in arrival order. The host broadcasts
  `_rpc_clock(steps, turn_number)` on each change for the clients' HUD.

### C.4 Global pause and interrupt
- `settle_clock` and `cancel_all_walks` already act on every walker on the host, whichever peer
  owns it. Nothing new, but test it: one player's soldier spotted stops both players' walks.

### C.5 Mode sync
- Entering turn mode: the synced `active_unit` from the draw overwrites each client's selection.
- Entering exploration: each peer keeps its last selection if it still owns a standing soldier,
  else selects its first.
- The portrait bar (B.11) reads every soldier's replicated HP and life state, so the partner's
  greyed portraits need no new sync.

### C.6 Wait from either player
- Either player's `try_wait` passes the round immediately (E16). Walks in flight pause for the tick
  and resume, as with any tick.

### C.7 Disconnects
- `main.gd _on_squadmate_left`: cancel the leaving peer's walks and release their reservations
  before control passes back.

### C.8 No client prediction
- Clients see every walk, their own included, through the streamed `global_position`, as they do
  today. Accept the latency.

### C.9 Tick playback on clients
- Without this, a client sees every AI unit in a tick teleport: logic-only resolution moves each
  root straight to its final tile, and `global_position` streams that.
- The host sends the scheduled timeline (B.12) as `_rpc_play_tick(timeline)`: units as node
  paths, tiles, events and slots. Each client plays it on the `UnitVisual` children, exactly as
  the host does.
- Because only the visual child animates, the streamed root position needs no suppression. It is
  already final, and the visual catches up to it.
- Each client runs its own display layer (B.12.1) and per-slot visibility (B.12.2) from the
  timeline. The facings and toggles it carries are all they need, so there is no extra sync.
- The host's paused walks resume when the **host's** playback ends; there is no client ack.
  Clients play the same slots at the same speed, so they finish in step with the host, give or
  take latency.

**Tests:** headless, rules-level:
- a reservation refuses the other owner's goal;
- `may_act` refuses a non-owner in exploration;
- the counter sums both owners' steps.

**Manual two-instance Steam checklist:**
- simultaneous walks, and crossing paths;
- one player spotted stops both;
- a clash rejection shows on the client;
- wait from the client;
- the mode switches both ways;
- a peer leaving mid-walk.

---

## Phase D — `--auto` and tuning

### D.1 Auto-play in exploration
- `_auto_play` is driven per activation today (`unit_activated`). In exploration, loop the squad
  instead: plan each soldier with GOAP against a synthetic budget of `ap_pool()` per think, and
  issue commands through `_issue`.
- Re-check `AUTO_EXTRACT_ROUND` (20) and `AUTO_FETCH_GIVE_UP_ROUND` (28) against step-clock
  rounds.

### D.2 `--turn-mode` flag
- It forces `exploration_enabled = false` for the whole run, and keeps the old loop as the
  regression baseline (E12). Run both.

### D.3 Measure
- Rounds, steps and wall-clock per mission on today's decks. Record them in GDD §7.7. They're
  the baseline for the enemy-count and mission-length questions in §12.1.

### D.4 Retune against step-clock rounds
- `STEPS_PER_ROUND`.
- `EnemyUnit.lose_contact_turns` (breaking contact gets easier when a round is a long walk).
- `CerberusUnit.MOTION_MEMORY_TURNS`.
- `AlienHivemind.DE_ESCALATION_TURNS`.
- `NestUnit.SPAWN_INTERVAL`.
- **Playtest checkpoint.**

---

## Out of scope

- **The near-the-fight pool** and the distant-unit clock during combat (§4.7.2): deferred to step
  11, big-deck performance (E14). Step 9's pool takes every unit, as now.
- Group and follow moves; a sneak stance; wait-until-event.

---

## Decisions

### Settled (2026-10-28)

| # | Decision | Phase |
|---|---|---|
| E1 | Partial merge: groundwork co-op-correct inside step 9, simultaneous input stays step 10 | all |
| E2 | Mode and step counter live inside `TurnManager` | B.1 |
| E3 | `active_unit` becomes per-peer selection; authorization moves to `may_act` | A.4, A.6 |
| E4 | Occupancy is claimed per step, and the goal is reserved at click time | A.1, A.2 |
| E5 | A round tick mid-walk pauses walks at the next tile, runs the AI round, then resumes | B.2 |
| E6 | An action resolves before the round it crosses ticks; the counter carries the remainder | B.2 |
| E7 | On interrupt, other walkers finish the tile they're entering and stop | A.3 |
| E8 | The opening shot's AP comes out of the shooter's first activation | B.7 |
| E9 | A new move order mid-walk redirects at the next tile | B.5 |
| E10 | Hunker, suppression and stun clear when combat ends; overwatch carries | B.9 |
| E11 | Wait is in step 9: one press burns to the next round | B.10 |
| E12 | `--auto` moves to exploration; `--turn-mode` keeps the old baseline | D.1, D.2 |
| E13 | No area overlay out of combat: a path to the cursor with its step and round cost | B.5 |
| E14 | The near-the-fight pool is deferred to step 11 | — |
| E15 | Co-op goal clash: reject and show "tile taken" | C.2 |
| E16 | Either co-op player can wait, effective immediately | C.6 |
| E17 | A wounded leg costs `move_ap_per_tile()` steps a tile (2 or 3), not 1 | B.2 |
| E18 | A walker whose next tile becomes occupied mid-walk repaths once, else stops | A.1 |
| E19 | Contact doesn't tick a round: the round in progress becomes the opening combat round, and leftover steps are discarded | B.3 |
| E20 | Turn mode starting mid-tick drops the rest of that tick's AI turns | B.2 |
| E21 | Suppress is an attack-to-start, and an opening Suppress is the suppressor's whole first activation; Hunker is unavailable out of combat | B.6, B.7 |
| E22 | Overwatch costs its AP price in steps, like any action | B.8 |
| E23 | Per-step detection reuses each enemy's own `_look_for_targets()` | B.4 |
| E24 | Squad portrait bar in both modes: your soldiers select, the partner's show read-only; click and Tab too | B.11 |
| E25 | Tick AI turns are decided in order and played back together on a dependency-scheduled timeline | B.12, C.9 |
| E26 | Wait doesn't count as the soldier acting, so it never clears overwatch | B.8, B.10 |
| E27 | Beams follow the replayed path through a display-only light layer; the rules' `light_value` stays final during playback | B.12.1 |
| E28 | During playback a unit is drawn by its model's tile, not its final tile | B.12.2 |

### Assumed, not yet confirmed

None open.

### GDD edits this plan needs — done in GDD v2.2 (2026-10-28)

The §10.2 presentation note was folded into §4.7.3 instead, beside the round tick it describes.

- §4.7.3:
  - the **wait action** is no longer TBD (E11), and wait doesn't break overwatch (E26);
  - the carry-over rule (E6);
  - a wounded leg costs 2–3 steps a tile (E17), which amends "every tile walked is one step".
- §4.7.2:
  - contact ticks no round, because the round in progress becomes the opening round (E19);
  - the opening-shot cost (E8), and an opening Suppress taking the whole first activation (E21);
  - clearing hunker, suppression and stun when combat ends (E10).
- §4.7.4:
  - co-op goal clash (E15) and who can wait (E16);
  - Hunker unavailable, Suppress as an attack (E21);
  - overwatch's step cost (E22);
  - the portrait bar (E24).
- §10.2 or a new presentation note: AI turns in a tick play back together (E25).
- §12.1: close the **wait action** open question.
