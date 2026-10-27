# Extraction Implementation Plan

Written 2026-10-10 against `3d-models` @ `bda5daef`. **Design source of truth:
[`game-design-document.md`](game-design-document.md) v2.0**, mainly §4.4 (downed, death,
carrying), §7 (mission loop, hangars, ship, economy) and §11.0 (cross-faction hostility). This file
covers *how* to build it. The GDD covers *what* to build. If they disagree, fix the GDD first.

Phases follow GDD §12.2, plus a Phase 0 for groundwork the rest depends on. Each phase ends
playable and tested.

```
0 Groundwork ─┬─> 1 Hangars & ship ──┬─> 3 Inventory & objectives ─> 4 Campaign & economy
              │                       │                                       │
              └─> 2 Downed & carrying ┘                                       v
                                         5 Door gun    6 Gear loot & objectives
                                         7 Cross-faction hostility ─> 8 Merc extraction
```

Phases 1 and 2 are independent of each other once Phase 0 is in. Phases 5, 6 and 7 can run in any
order after 4. Phase 8 needs 1, 3, 5 and 7.

---

## Ground rules (apply to every phase)

- **Host-authoritative.** All new state lives on the host and reaches clients through the existing
  patterns:
  - **Unit state:** the `MultiplayerSynchronizer` property list in `Unit._setup_replication`.
  - **Player commands:** the `_issue` → `_rpc_command` path in `PlayerUnit`. Every new command
    goes into `PlayerUnit._COMMANDS`, or a client's click is silently rejected.
  - **Mission-level state:** `@rpc("authority")` event calls, like `TurnManager._rpc_turn_started`.
- **Rounds are `TurnManager.turn_number`.** Every countdown ticks on `turn_started`. The GDD calls
  this a "round"; the code keeps "turn". Don't rename it.
- **Constants** live as named, commented `const`s beside the code that uses them, matching the
  existing style (see `UnitStats`, `Combat`).
- **Headless tests** follow `tools/test_*.gd`, run with
  `godot --headless --path . --script res://tools/test_<name>.gd`. Each phase lists its tests.
  Pure logic (timers, rules) goes in engine-free classes so it can be tested without a scene, as
  `MapData`, `Faction` and `Combat` already are.
- **Co-op is one crew** (GDD §7.6):
  - Both players' soldiers share crew id 0 in `ExtractionManager`, so there is one claim and one
    ship per mission. Either player can call it or dust off, and departure ends the mission for
    both.
  - Revive, pick up, drop and loot accept **any** contractor target regardless of the target's
    `owner_peer_id`. `_rpc_command` validates the *acting* unit's owner, never the target's.
  - A revived soldier goes back to their own player's control.
  - Every phase's tests include a cross-owner case where the logic can be tested headless.
- **Placeholder art everywhere.** No phase waits on a model or an animation. Art needs are
  collected in the art list at the end.

---

## Phase 0 — Groundwork

Things the later phases all touch. Do these first, as small separate commits.

### 0.1 Round-end hook in `TurnManager`
- The ship departs "at the end of the round" (§7.4), and today nothing marks that moment: an
  empty pool goes straight into `_start_turn()` from `_draw_next`.
- Add `signal turn_ending(turn_number)`, emitted in `_draw_next` when the pool is empty, before
  `_start_turn()`, and awaitable. Departure resolves there.
- Mirror it to clients like `_rpc_turn_started`.

### 0.2 Mission outcome instead of `player_won: bool`
- Replace `mission_ended(player_won: bool)` with `mission_ended(result: MissionResult)`.
  `MissionResult` is a new `RefCounted` holding:
  - `outcome` (`EXTRACTED`, `WIPED`, or `ABANDONED` for a host disconnect),
  - extracted units, lost units,
  - objective complete or not,
  - loot carried out.
- Update `hud.gd` `_on_mission_ended`, the `--auto` path in `main.gd`, and the RPC mirror.
- **Remove "all hostiles down = win"** from `_check_end_conditions`. Keep it behind a
  `clear_out_mode` flag that the old test decks turn on, so the existing tests and `--auto`
  playthroughs keep working.

### 0.3 Life state on `Unit`
- `is_downed` currently means three different things: out of the fight, a corpse, and not in the
  pool. About 115 places read it.
- Add `enum LifeState { ACTIVE, DOWNED, DEAD }` and `var life_state`. Keep `is_downed` as a
  **derived read-only property** (`life_state != ACTIVE`), so every existing "is this unit out of
  action" check stays correct untouched. Only the code that needs to tell downed from dead reads
  `life_state`.
- Replicate `life_state` instead of `is_downed`.

### 0.4 `is_player_controlled` must mean PlayerUnit
- It is currently `faction == CONTRACTORS`. The Phase 5 door gun and the Phase 6 VIP are
  contractor-side units the player doesn't control.
- Change it to "this is a `PlayerUnit`". Audit the 16 references across `turn_manager.gd`,
  `unit.gd`, `enemy_unit.gd`, `main.gd`, `map_builder.gd`, `player_unit.gd`, `ai/barks.gd` and
  `ai/squad_coordinator.gd`. Some of them really mean "contractor faction"; switch those to the
  faction test.
- Extend `tools/test_faction.gd`.

### 0.5 Flat-cost actions
- `UnitStats.BASE_AP_COST` is always Reflexes-discounted. The four extraction actions are flat
  (§4.2): revive 3, pick up 2, loot 1, call ship 1.
- Add a `FLAT_AP_COST` table, read by `Unit.action_cost`, so the planner and HUD price them the
  same way as everything else. **Don't** hardcode the costs in `PlayerUnit`.

**Tests:** `test_turn_hooks.gd` (`turn_ending` fires once per round, before `turn_started`).
Existing tests still pass with `clear_out_mode`.

---

## Phase 1 — Hangars & the ship (GDD §7.1–7.4)

### 1.1 Hangar data
- `MapData.hangars: Array[Hangar]`. `Hangar` is an inner class with:
  - `room_index`
  - `bay_cells` (every cell of the room, used for "anywhere in the bay")
  - `square` (the 3×3 cells in front of the ramp)
  - `pad_center`, `ramp_side` (a `Side`)
  - `is_insertion`
- **ASCII format** (`MapAscii`): a `[hangars]` section, the same style as `[cover]`, listing the
  pad centre, ramp side and the insertion flag per hangar. The bay is derived from the room the
  pad sits in. Round-trip it in `test_map_roundtrip.gd`.
- **Test deck:** `maps/extraction_test.txt`. Two hangars and a corridor between them, so Phase 1
  can be played before the generator work lands.

### 1.2 Generator (`MapGenerator`)
- `Config`: `hangar_count_min/max` (3–4, scaled by `width × depth`) and `hangar_min_size`
  (suggest 9×9, enough for a pad, the 3×3 square and room to fight).
- **Placement:**
  1. Reserve hangar rects **first**, before ordinary rooms.
  2. Spread them with farthest-point sampling over the deck.
  3. Pick the insertion hangar at random, then route corridors as today.
  4. After carving, run a BFS from the insertion square that must reach every other hangar's
     square. Reroll the seed if it fails.
- **Spawns:** `_place_spawns` currently puts the squad in `real_rooms[0]`. Put them on the
  insertion square instead. **No enemy spawns in the insertion hangar** or its corridor
  neighbours.
- No cover blocks on the pad or the square.
- **Tests:** extend the generator checks (or add `test_hangar_gen.gd`) over a few hundred seeds:
  - hangar count in range,
  - all hangars reachable,
  - insertion hangar enemy-free,
  - squares fully walkable.

### 1.3 Building it (`MapBuilder`)
- A hangar visual: pad markings and a floor decal on the 3×3 square. The square is also
  highlighted through `HighlightManager` while a ship is landed.
- **`Dropship` node** (a `Node3D`, **not a `Unit`**, so the ship itself can never be targeted):
  a placeholder box mesh with a ramp, and tweens for descend, land, lower ramp and take off.
  It is scene-only; the timers live in the manager below.

### 1.4 `ExtractionManager` (new autoload)
- **An engine-free rules core plus a thin node wrapper.** The rules core is `ExtractionRules`
  (`RefCounted`), which owns per-hangar state and is what the tests drive.
- **Per-hangar state:**
  - `UNDISCOVERED` → `DISCOVERED` → `CALLED` (`arrive_round`) → `LANDED` (`depart_by_round`,
    `dust_off_requested`) → `COOLDOWN` (`ready_round`) → `DISCOVERED`.
  - Plus `claimed_by` (a crew id; player = 0, each merc squad gets its own id later).
- **Discovery:** on `Unit.moved` for a `PlayerUnit`, look up `MapData.room_index_at`. Entering a
  hangar room sets `DISCOVERED` for the whole squad. The insertion hangar starts discovered.
- **Call-in** (`PlayerUnit.try_call_ship`, 1 AP flat):
  - Valid if the active soldier is on any `bay_cell` of a discovered hangar that is unclaimed and
    not in cooldown.
  - Sets `CALLED` with `arrive_round = turn_number + 3`, and sets `claimed_by`.
  - **Noise:** `SecurityNetwork.report_noise(pad_center, null, 15)`. This is the existing sound
    channel, so aliens, robots and mercs all hear it by their own rules.
  - **Radio notice:** `signal ship_called(crew_id)`, with no position. The HUD logs "A ship has
    been called." Phase 8 mercs listen to it.
  - Decide in 1.4 whether a call-in also triggers `AlienHivemind` escalation (GDD §11.2 lists it
    as TBD). Default: no.
- **Landing** on `turn_started`, when `turn_number == arrive_round`: spawn or animate the
  `Dropship` and set `LANDED` with `depart_by_round = turn_number + 5`.
- **Dust-off** (`PlayerUnit.try_dust_off`): valid when the active soldier is in the `square` of
  a hangar their crew has landed. It sets `dust_off_requested`. **AP cost is unspecified in the
  GDD.** This plan assumes 0 AP (it's a signal, not an action); add it to GDD §4.2 when built.
- **Departure** on `turn_ending`, when `dust_off_requested` is set or
  `turn_number >= depart_by_round - 1` (5 full rounds on the ground):
  - Collect `PlayerUnit`s whose `grid_pos` is in `square` and whose `life_state != DEAD`, plus
    whatever each of them carries (Phase 2).
  - **If any:** build the `MissionResult` (extracted = those; lost = every other contractor,
    dead or alive) and end the mission.
  - **If none:** the ship takes off, and the hangar goes to `COOLDOWN` with
    `ready_round = turn_number + 5`.
- **Insertion:** before `TurnManager.start_mission()`, `main.gd` plays the dropship landing at
  the insertion hangar. Units are already placed on the square, hidden, and revealed when the ramp
  drops. Then the ship takes off. Skipped under `--auto`. Outside the pool, so no round passes.
- **Network:** the host runs the manager. State changes go to clients as one
  `@rpc("authority") _rpc_hangar_state(hangar_index, state, rounds)` call. The clients' managers
  only mirror and animate.

### 1.5 HUD
- Discovered hangar markers (an icon over the bay), with a countdown label when called or landed
  ("Ship in 2", "Departs in 4").
- **Call ship** and **Dust off** buttons, shown only when valid for the active soldier. Labelled
  with cost through the existing `_label_cost`.
- Radio notices in the combat log, and a brief banner.
- The end-of-mission panel lists who extracted and who was left behind.

**Tests:** `test_extraction.gd`, driving `ExtractionRules` directly:
- the 3-round arrival, the 5-round window and the 5-round cooldown,
- dust-off resolves at round end, not immediately,
- square membership decides extracted vs lost,
- an empty-square departure goes to cooldown and the mission continues,
- a claimed hangar refuses a second crew's call,
- discovery on room entry.

**Done when:** on `extraction_test.txt` and on generated decks, you can insert, walk to a second
hangar, call, survive 3 rounds, dust off, and the result screen is correct. Leaving a soldier
outside the square lists them as lost.

---

## Phase 2 — Downed, death, carrying, pistol (GDD §4.4, §4.3)

### 2.1 Downed bar and death (`Unit`)
- **New fields:**
  - `downed_hp` (initialised to `stats.max_hp()` at spawn; persists through the mission)
  - `down_count`
  - `can_be_downed` (true on `PlayerUnit` only; mercs, aliens and robots die outright)
- **`take_damage`, when `life_state == ACTIVE` and HP reaches 0:**
  - If `can_be_downed` and `down_count < 2`: `down_count += 1` and become `DOWNED`. The existing
    downed code runs: clear occupancy, drop overwatch and suppression, play `DOWNED`, report
    evidence.
  - Otherwise: become `DEAD`.
- **`take_damage` while `DOWNED`:** damage comes off `downed_hp` (armour still applies). At 0 →
  `DEAD`.
- **Bleed:** on `turn_started`, every `DOWNED` unit loses `ceil(max_hp / 5)` from `downed_hp`
  (a named constant, `DOWNED_DRAIN_FRACTION`).
- **`die()`:** sets `DEAD` and keeps the body on the map as a corpse with its gear. Use the
  existing downed pose with a desaturate or tint as a placeholder for "dead".
- **Squad wipe** in `_check_end_conditions`: no `PlayerUnit` is `ACTIVE` → `MissionResult`
  `WIPED`, and every deployed soldier goes on the lost list.
- Replicate `downed_hp` and `down_count`.

### 2.2 Revive (3 AP flat)
- `PlayerUnit.try_revive(target)`: the target is a `DOWNED` ally that is movement-adjacent
  (`GridManager.is_melee_adjacent`).
- Effect: `life_state = ACTIVE`, `current_hp = ceil(0.25 × max_hp)` (named constant), restore
  occupancy, play the stand-up animation.
- `downed_hp` and `down_count` are untouched. The revived unit joins the pool **next** round.
  `TurnManager.pool` is a snapshot, so this needs no extra work.
- **Tile conflict:** downed bodies don't hold occupancy, so someone may be standing on the
  body's tile. Revive onto the nearest free tile adjacent to the reviver; if there isn't one,
  revive is invalid.

### 2.3 Carrying (pick up 2 AP flat, drop free)
- `Unit.carrying: Unit` and `Unit.carried_by: Unit`, replicated as node paths.
- **`try_pick_up(target)`:** the target is an adjacent `DOWNED` or `DEAD` contractor (later also a
  merc corpse or VIP). The carrier must not already be carrying. The body is hidden (placeholder)
  and a "carrying" marker is shown on the carrier.
- **Movement:** in `Unit.move_along`, after each tile, set `carrying.grid_pos` to the carrier's.
  No occupancy (bodies never hold it). No movement penalty.
- **`try_drop()`:** free. The body appears on the carrier's tile.
- **If the carrier goes down or dies**, the body drops automatically on their tile.
- **Weapons while carrying:**
  - The active weapon switches to the pistol (2.5): Shoot, Aimed Shot and Overwatch use pistol
    stats, magazine and reserve.
  - **Suppress is unavailable** (one-handed fire isn't volume of fire; this is an assumption,
    add it to the GDD).
  - Grenades are allowed.
  - Reload reloads the pistol.
- **Fire at a carrier** (in the shot resolution in `Unit.fire_at` / `Combat`): on a **landed**
  hit, if the target is carrying a downed body:
  - If the carrier was **in cover from that shot** (cover penalty applied, not flanked), the hit
    stays on the carrier.
  - Otherwise roll 25% (named constant): if it succeeds, the damage goes to the carried body's
    `downed_hp` instead.
  - A carried corpse takes nothing.
  - Log it ("the round hits Okafor, slung over Reyes's shoulder").
- **Extraction:** Phase 1's departure check already counts whatever an extracting soldier
  carries. A carried corpse returns its gear (Phase 4 credits it).

### 2.4 AI and downed targets (§4.4, faction-dependent)
- `Unit.hostiles()` excludes downed units, which is right for normal targeting.
- Add `Faction.DOWNED_POLICY = { ALIENS: ALWAYS, RIVAL_MERCS: OPPORTUNISTIC, SECURITY: NEVER }`
  and `Unit.downed_targets()`.
- **Aliens:** `EnemyUnit` target acquisition considers downed contractors it has detected as
  valid targets, ranked as low-risk prey. Swarm and Brawler melee them too.
- **Mercs:** a GOAP goal "finish downed" with low priority, valid only when no active hostile is
  in LOS and the shot costs at most the AP that remains after repositioning.
- **Cerberus:** never.

### 2.5 Pistol (gameplay only)
- `WeaponPresets.WeaponId.PISTOL`, kept out of the primary picker.
  - Placeholder stats: base accuracy 30, damage 5, mag 8, reserve 16, `optimal_range` 6,
    falloff 8, noise 4.
  - Rifle ammo already lists "the pistol, once there is one" as a fit (`attachments.md`).
- `UnitStats.sidearm: WeaponData`. Every soldier gets one at spawn; it is **equipped gear** and
  takes no inventory slot.
- `Unit.active_weapon()` returns the sidearm while carrying, otherwise the primary. Route the
  weapon getters on `UnitStats` (`weapon_base_accuracy`, `weapon_damage`, `mag_size`,
  `noise_radius` and so on) through it. Keep separate ammo and reserve for the sidearm.
- **Visual:** reuse the rifle poses and leave the rifle mesh visible. Pistol model and one-handed
  animations are on the art list.
- The loadout screen shows the pistol as a fixed line.

### 2.6 HUD
- The downed soldier's panel shows the downed bar (red) and down-count pips.
- **Revive**, **Pick up** and **Drop** buttons. Revive and Pick up enter a target mode where the
  player clicks an adjacent body. Bodies need a click collider even though they hold no occupancy.
- A "Carrying" indicator, with the weapon line showing PISTOL.

**Tests:** `test_downed.gd`:
- `downed_hp` carries across downs,
- drain per round,
- third down = death,
- `downed_hp` 0 = death,
- revive HP and adjacency,
- revive onto an occupied tile picks a free neighbour,
- mercs and aliens die outright,
- squad wipe = `WIPED`.

`test_carry.gd`:
- the body follows the carrier,
- it auto-drops when the carrier goes down,
- the pistol is used while carrying and Suppress is refused,
- the redirect rate is about 25% in the open and 0% in cover (seeded loop),
- corpses take no redirected damage.

**Done when:** a soldier can go down, bleed, be revived, go down again, die on the third, and be
carried as a corpse to the ship. That corpse's owner is on the extracted list and not the lost one.

---

## Phase 3 — Inventory, loot, Retrieve & Destroy (GDD §7.5)

### 3.1 Items
- `ItemData` (`Resource`): `id`, `display_name`, `kind`, `value` (credits), `payload`.
  - `kind` is `VALUABLE`, `GEAR` or `OBJECTIVE`.
  - `payload` is the attachment, ammo or weapon id for `GEAR`.
- `ItemPresets`: a table like `AttachmentPresets`. Start with 6–8 valuables across three value
  tiers, plus **Salvage** as a valuable (replacing the bare counter in `SecurityNetwork.add_salvage`;
  destroyed robots drop a Salvage item on their tile instead).
- `Unit.inventory: Array[ItemData]`, with `INVENTORY_SLOTS := 4`. Equipped gear (primary, pistol,
  attachments, grenades) is not inventory. Replicated as an array of ids.

### 3.2 Loot sources
- **`LootContainer`:** a prop node (crate or locker; a placeholder box). It holds items, blocks
  its tile like block cover, and is interactable from adjacent tiles. It is **not** a `Unit`.
- **Generator:** place containers in ordinary rooms (`loot_per_room` chance, 1–2 per room) and
  roll contents from a value-tiered table. Hangars get none. Give it a glyph in `MapAscii`.
- **Corpses:** a dead contractor's or dead merc's inventory **plus their equipped gear converted
  into `GEAR` items** (weapon with attachments as one item, each grenade as one) become lootable.
  Mercs get a small rolled inventory at spawn (`MercPresets`).
- **Loot action** (`try_loot(source, item_index)`, 1 AP flat per item): needs a free slot. A loot
  panel lists the source's contents; each "Take" click is one command and one AP.
  **Drop item** (free) leaves it in a pile container on the tile.

### 3.3 Objectives
- `Contract` (`RefCounted`): `type`, `target` placement, `payout`. Phase 4 generates contracts;
  until then `main.gd` picks one at random.
- `ObjectiveManager` (part of `ExtractionManager`, or a sibling autoload) tracks completion and
  writes it to `MissionResult`.
- **Retrieve:** an `OBJECTIVE` item placed in a container in a room far from insertion (the
  farthest third by path distance). Complete if it is in an extracted soldier's inventory **or on a
  carried corpse** at departure.
- **Destroy:** reuses `NestUnit`. **Finish the nest (§11.7):**
  - spawn one unit every 3 rounds from the 70/20/10 table (with Spitter not built, fall back to
    a Fodder roll for its 20%),
  - into a free adjacent tile,
  - call `AlienHivemind.report_nest_destroyed` on death.

  Complete when the target nest dies, whether or not anyone extracts. The payout still needs
  someone to extract.
- HUD: objective line ("Retrieve: Data Core — not found / carried by Reyes / complete").

**Tests:** `test_inventory.gd`:
- slot cap,
- the loot AP cost,
- corpse gear converts to items,
- Retrieve counts from a carried corpse.

`test_nest.gd`:
- spawn cadence,
- spawn table weights,
- the destroyed callback.

---

## Phase 4 — Campaign & economy (GDD §7.5, §7.6)

Today there is no meta layer: `main.gd` hardcodes a three-soldier `SQUAD`, and the scene reloads
after a mission.

### 4.1 `Campaign` (new autoload) and save
- **State:**
  - `roster`: `SoldierRecord`s holding name, class, rolled stats, primary + attachments + ammo
    loadout, body-part injuries, missions survived
  - `credits`
  - `stash`: item ids, attachment copies (feeds `LoadoutMenu.inventory`), unlocked ammo
  - `contract_pool`
  - `medical`: count of the medical resource
- Saved to `user://campaign.json` with a `version` field. Saved after every debrief and hub
  action. **Ironman by design:** one save slot, written on mission end, so a bad extraction can't
  be reloaded away.

### 4.2 Scene flow
- `Title` → `Hub` → `main.tscn` (mission) → `Debrief` → `Hub`.
- **Hub** is code-built overlays, like `LoadoutMenu` and `HostJoinMenu`, with tabs:
  - **Roster** (view, treat injuries with the medical resource)
  - **Recruit** (2–4 rolled candidates per visit through `ClassPresets.roll`, priced)
  - **Stash/Shop** (buy attachments, ammo unlocks and grenades)
  - **Contracts** (pick from 3; each shows type, deck size and payout)
- **Deploy:** choose 2–4 roster soldiers, then the existing `LoadoutMenu`, now fed from the stash.
  `main.gd` spawns from the chosen records instead of `SQUAD`.
- **Debrief**, applying the `MissionResult`:
  - extracted soldiers return with their gear, and their inventory moves to the stash,
  - lost soldiers are removed from the roster, and their equipped gear is removed from the stash,
  - valuables sell for credits,
  - the contract payout is added if the objective is complete.
- **Game over:** if the roster has fewer than 2 soldiers and credits are below the cheapest
  recruit, show the campaign-over screen and wipe the save.

### 4.3 Co-op
- **Interim rule until GDD §12.1 #3 is decided:** the host's campaign is the campaign. The client
  controls the host's soldiers assigned to them (today's ownership split) and owns no save.
  The debrief is applied on the host only.

**Tests:** `test_campaign.gd`:
- debrief accounting (extracted, lost, a carried corpse's gear recovered, valuables sold,
  objective paid),
- game-over threshold,
- save round-trip,
- version mismatch handled.

---

## Phase 5 — Door gun (GDD §7.4)

- `DoorGunUnit extends EnemyUnit`. It is an AI pool participant with hidden Initiative. Its
  faction is the calling crew's (`CONTRACTORS` for the player's ship), and it is not a
  `PlayerUnit` (this is why 0.4 exists).
- Spawned on landing at the ramp. It **never moves**, and each activation it shoots the
  best-scored hostile in LOS within N tiles of the square.
  - Placeholder stats: LMG-like accuracy and damage, effectively infinite ammo, HP 30, armored.
  - Whether the light modifier applies to it is open question #2 in GDD §12.1. Default: yes.
- **Disabled at 0 HP:** `DEAD`, but the mesh stays and goes dark. Nothing revives it this landing.
  It is removed (freed) on takeoff. A re-called ship spawns a fresh one.
- Hostile AI may target it like any unit. The `Dropship` node itself stays untargetable.
- **Tests:** it joins the pool only while landed, is removed on departure, and stays disabled
  until departure.

---

## Phase 6 — Gear loot, Hold-terminal, Recover (GDD §7.5)

- **Gear loot:** add `GEAR` items to container tables, using attachments' tiers ("weaker items are
  the easy finds", `attachments.md`), ammo unlocks and grenades. Extracted gear goes to the stash
  through the Phase 4 debrief.
- **Hold a terminal:**
  - A `Terminal` prop with an interact action (decide the AP cost then).
  - It counts rounds while any contractor stands adjacent and the terminal hasn't been
    interrupted (N rounds, named constant).
  - It emits noise every round it runs (`report_noise` at radius 8).
  - Complete when the count finishes.
- **Recover:**
  - A VIP spawned **`DOWNED`** in a far room. It is a non-player contractor-side `Unit`, with its
    `downed_hp` drain **off** (they're stable, not bleeding; confirm in the GDD).
  - Carried like a soldier (Phase 2). Complete if carried onto the ship.
  - The 25% redirect applies to them.
- **Tests:** the terminal count resets or pauses correctly; VIP extraction counts.

---

## Phase 7 — Cross-faction hostility (GDD §11.0)

1. **Matrix:** `Faction.HOSTILE_TO`, with every faction hostile to every other. Update
   `test_faction.gd`.
2. **Audit for two-sided assumptions.** Every place that assumes "the enemy" means contractors:
   - target acquisition in `EnemyUnit`,
   - `SecurityNetwork` intruder logic,
   - `AlienHivemind` rousing,
   - `ai/squad_coordinator.gd`, `ai/barks.gd` and the GOAP world-state readers in
     `ai/goap_brain.gd` and `ai/tile_threat.gd`,
   - win/loss logic (already reworked in Phase 0).
3. **Per-faction target priority:**
   - **Aliens:** anything detected by light or sound, nearest first. No change in principle; it
     just stops filtering to contractors.
   - **Cerberus:** any non-Cerberus unit detected by motion or sound is an intruder, ranked by
     threat.
   - **Mercs:** contractors always. Aliens and robots only if they've detected the merc, block its
     current GOAP goal's path, or are within N tiles of a squad member; otherwise route around
     them (path cost penalty near known non-player hostiles).
4. **Overwatch and suppression** already ask `is_hostile_to`, so they work across factions
   without changes. Check this.
5. **Playtest checkpoint:** watch whether hiding while factions attrit each other becomes
   dominant (the risk named in §11.0).
- **Tests:** a deck with one alien next to one robot, no contractors in range: they fight. A merc
  ignores a distant unaware robot that isn't on its path.

---

## Phase 8 — Merc extraction (GDD §11.10, §7.3)

- **Merc squad "job":** each squad gets a goal at spawn: loot K containers, or the same objective
  type as the player's contract (contested). Squad state lives on its `SquadBlackboard`.
- **Mercs know every hangar.** They're a crew with a map; discovery is a player-only constraint.
  Confirm in the GDD.
- **Leave decision:** a new GOAP goal `Extract`. It ranks above looting when any of these holds:
  the job is done, inventory is full, casualties reach 50%, or a round limit is passed.
  - Pick the nearest unclaimed hangar.
  - Path there, call (claims it, uses the same `ExtractionRules`, and triggers the noise and radio
    notice), and hold the square.
  - Board on landing: the squad's units in the square are removed from the map, the ship departs,
    and the claim clears.
- **Merc door gun:** the Phase 5 unit with the merc crew's faction.
- **Hearing the player:** on `ship_called` from another crew, mercs that aren't extracting may
  move toward the noise if they heard it. The notice itself carries no position.
- **Loot:** mercs pick up from containers via the same loot action (AI cost path). Killing one
  drops its inventory on the corpse (Phase 3).
- **Tests:**
  - a merc squad with its job done calls and extracts,
  - its claim blocks the player's call on that hangar,
  - killing the squad before landing frees the hangar after departure.

---

## Decisions this plan assumes (fold into the GDD as each phase lands)

| # | Assumption | Phase |
|---|---|---|
| A1 | Dust-off signal costs 0 AP | 1 |
| A2 | Call-ins don't trigger `AlienHivemind` escalation | 1 |
| A3 | Revive onto an occupied body tile uses the nearest free neighbour, else it is invalid | 2 |
| A4 | No Suppress while carrying (pistol only, grenades allowed) | 2 |
| A5 | Placeholder pistol stats (acc 30, dmg 5, mag 8) | 2 |
| A6 | Dropped items form a lootable pile on the tile | 3 |
| A7 | Co-op: host's campaign, single save, client owns nothing | 4 |
| A8 | One ironman save slot | 4 |
| A9 | Door gun obeys the light modifier | 5 |
| A10 | VIP doesn't bleed | 6 |
| A11 | ~~Mercs know all hangar locations~~ — superseded when built: a merc crew discovers a hangar by entering its room, like the player (GDD §7.2) | 8 |

## Art list (none of it blocks a phase)

- Dropship model: land, ramp, takeoff.
- Door gunner on the ship.
- Hangar room module (pad, bay, square markings).
- Pistol model and one-handed poses: idle, aim, fire, reload.
- Carry poses (carrier and body), and a dead/corpse pose distinct from downed.
- Revive animation.
- Loot container props (crate, locker, item pile).
- Terminal prop.
- HUD icons (hangar, countdown, downed bar, inventory slots).
