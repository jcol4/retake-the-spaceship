# Retake the Spaceship — Game Design Document

*Draft v2.2 (2026-10-28) — a turn-based extraction tactics game. v2.1 added exploration mode and
much bigger decks (§4.7). v2.2 settles exploration mode's open rules: wait, the opening action,
the clock's edge cases, and co-op. Still on paper only.*

> **v2.0 is a rewrite, not a patch.** v1.1 had accumulated a dozen "⚠️ SUPERSEDED" callouts that
> pointed at other documents for the live rule. Those rules are now stated here directly, and the
> v1.1 reasoning they replaced is in git history (`git show bda5daef:game-design-document.md`).
> The biggest change is design, not cleanup: missions are now **extraction runs** (§7), and
> **soldiers can die permanently** (§4.4). Detail still lives in the per-faction and per-system docs
> under [`docs/design/`](docs/design/), which this document links to rather than duplicates.
>
> Status markers: **[built]** in code today · **[partial]** partly in code · **[design]** on paper only.

---

## 1. High-Concept Pitch

A turn-based squad tactics game in the spirit of *XCOM*, structured like an extraction shooter
(*Escape from Tarkov*, *Helldivers 2*). A dropship leaves a small squad of hired contractors in the
hangar of a derelict ship (*Dead Space* tone). From there they cross a dark, procedurally generated
deck to complete a contract and grab what loot they can. Then they have to reach a hangar, call the
ship back and hold out until it lands. Anyone who isn't on the ramp when it leaves is gone for good.

Two systems carry the combat:
- **The initiative pool.** Every unit on the board, friend and foe, is drawn from one shared,
  weighted pool each round.
- **Continuous light and sound visibility.** A soldier's own flashlight is their best tool and also
  a beacon.

The ship is shared with three hostile factions, which are also hostile to each other: an alien
infestation, the ship's own security robots, and rival contractor crews who are running the same
job.

---

## 2. Design Pillars

- **Tactical, not twitchy.** Deliberate, timing- and positioning-focused decisions. No reflex mechanics.
- **Tension through uncertainty.** The shared initiative pool means the "safe" plan can always be
  disrupted, but the odds are knowable and influenceable, not pure chaos.
- **Light is a weapon and a liability.** Visibility is a continuous value that soldiers actively
  manage for themselves and their targets, not a binary line-of-sight check.
- **Push or pull out.** Every mission is a running decision between going deeper for more (the
  objective, better loot) and getting out with what you have. Leaving early is always allowed,
  and never pays well.
- **Get them to the ramp.** Soldiers are permanent stakes. Combat downs them, but they die from
  bleeding out, going down too many times, or being left behind. Dragging a body to the ship under
  fire is the defining scene of the game. *(Replaces v1.1's "Forgiving, not punishing — no
  permadeath.")*
- **Small squad, high specialization.** 2–4 units per mission, each meaningfully different via
  fixed class roles.

---

## 3. Platform, Perspective & Players

- **Platform:** PC (Windows), Godot 4.x, distributed on Steam (GodotSteam). **[built]**
- **Players:** Single-player, or **2-player online co-op** over a Steam friends-only lobby. In
  co-op the host owns the simulation (pool draw, combat RNG and AI all run on the host), and each
  player commands the soldiers assigned to them. **[built, prototype]** See §7.6 for how co-op
  affects extraction.
- **Perspective:** A real 3D world seen through a **fixed orthographic isometric camera**. Pitch is
  fixed at ≈35.264° (a world square projects to a 2:1 diamond). Yaw snaps between four 45°-offset
  angles (Q/E). Zoom goes outward only (`Camera3D.size` from 10.5 to 30). **[built]**
- **Characters are rigged 3D models** exported from Blender (`tools/export_models.py` → `.glb`).
  They used to be prerendered sprites; that was replaced because sprites could not plant their
  feet. Units move and face in eight directions. **[built]**
- **Look:** Stylized low-poly. The 3D scene is rendered at reduced resolution and upscaled with
  nearest filtering (`PixelView`, a chunky pixel-art look from live 3D), with screen-space
  inverted-hull outlines on characters. **[built]**
- **Setting/tone:** Decrepit derelict ships: dark corridors, failing power, *Dead Space* atmosphere.

> [`docs/presentation-direction.md`](docs/presentation-direction.md) is still the reference for the
> camera maths. Its sprite-pipeline sections (§2) describe the retired sprite system and are stale.

---

## 4. Core Combat System

### 4.0 The Grid **[built]**

- **Square tile grid** laid over real 3D geometry. One tile ≈ 1.5 m.
- **Elevation:** multiple floors, ledges and stairs. Changing floors costs nothing extra.
  High ground gives an accuracy bonus (§6.4).
- **Eight-way movement; a diagonal costs the same as a cardinal step** (the XCOM rule), so N tiles
  of movement reaches a square of side 2N+1.
  - **Corner-cutting guard (loose form):** a diagonal is blocked only when *both* tiles it passes
    between are walls. Occupied tiles never block a diagonal.
- **Range is Chebyshev** (a diagonal counts as 1) for weapon range, detection, throws and alert
  radii. Anything that must be *walked to* (melee contact, revive, pick-up) uses movement
  adjacency (`GridManager.is_melee_adjacent`) instead, which respects walls and floors.
- **Movement costs a flat 1 AP per tile** for every unit. How far a soldier gets depends on the
  size of its AP pool (§4.2). There is no separate Run/Sprint allowance.
- **Predictive movement preview:** reachable tiles are shown graded by AP cost and shaded by light
  level, so routing through darkness is a visible choice.
- **Movement always completes once committed.** Spotting an enemy mid-path does not interrupt it.
  The only exception is reaction fire: Overwatch, and suppression's break shot (§4.2).
- **One unit per tile.** The exception is a carried body, which shares its carrier's tile (§4.4).

### 4.1 Turn Structure — The Initiative Pool **[built]**

The signature mechanic.

- **Round** = one full cycle of the pool. At the start of each round, **every unit on the board**
  (player, enemy, objects that act such as nests and the dropship's door gun) is placed into one
  shared pool.
- Units are drawn one at a time, weighted by **Initiative**. A higher Initiative makes an earlier
  draw more likely but never guarantees it. A drawn unit takes its whole activation and is
  removed; repeat until the pool is empty, then the next round begins.
- **Initiative = 50 + 0.2 × Reflexes + equipment bonus** (soldier default equipment bonus: 5).
  There is no class modifier. Class shows up in turn order only indirectly, through the Reflexes
  range a class tends to roll.
- **Visibility:** players see their own units' Initiative. **Enemy Initiative is fully hidden.**
- **Modifiability:** abilities, items and status effects can shift Initiative mid-mission.
- **Every timer in this document counts rounds**, and ticks at round start (extraction countdowns,
  bleed-out, nest spawns, cooldowns).
- **The pool only runs in turn mode.** Out of combat the squad moves freely, and rounds pass on the
  exploration clock instead (§4.7). **[design]**

### 4.2 Action Points & Actions **[built]**

Detail and reasoning: [`ap-and-stat-baselines.md`](docs/design/factions/contractors/design-choices/ap-and-stat-baselines.md).

- **AP pool per activation = floor(6 + 0.075 × Fitness)**, so a typical soldier has 10–12 AP.
- **Action cost = base − (k × Reflexes)**, rounded, minimum 1. The weapon's AP modifier (§4.3) is
  added to the base first.
- **The economy's shape:** you can shoot twice, or shoot once and reposition, but not both. Only
  movement did not scale up with the bigger pool, so extra AP buys ground covered rather than more
  actions.

| Action | Base AP | Reflexes k | Effect |
|---|---|---|---|
| **Move** | 1 / tile | — | Flat, undiscounted |
| **Shoot** | 6 | 0.03 | Snap shot (§6.5) |
| **Aimed Shot** | 8 torso / 9 limb / 10 head | 0.015 | VATS-style body-part shot (§4.2.1) |
| **Melee** | 6 | 0.03 | Contact-range attack |
| **Throw Grenade** | 6 | 0.03 | EMP or Frag (§4.2.2) |
| **Reload** | 3 | 0.03 | Refill magazine from reserve (§4.3) |
| **Suppress** | 8 | 0.03 | Pin a target (§4.2.3); costs 3 rounds of ammo |
| **Overwatch** | 6 (floor) | 0.03 | **Ends activation.** Reaction shot when an *enemy* moves into LOS |
| **Hunker Down** | 6 (floor) | 0 | **Ends activation.** −20% to shooters targeting this unit until its next activation |
| **Flashlight toggle** | 0 | — | Free (§5.2) |
| **Door toggle** | 0 | — | Free (§10.5) |
| **Revive** | 3 | — | **[built]** Adjacent (or same-tile) downed ally back up at 25% HP (§4.4) |
| **Pick up** | 2 | — | **[built]** Lift an adjacent (or same-tile) downed ally or corpse (§4.4) |
| **Drop** | 0 | — | **[built]** Put a carried body down on your tile; does not end the activation (§4.4) |
| **Loot** | 1 | — | **[built]** Take an item from an adjacent corpse or container (§4.4, §7.5) |
| **Operate terminal** | 2 | — | **[built]** Start, or restart after a pause, the Hold contract's console from beside it (§7.5) |
| **Call ship** | 1 | — | **[built]** Anywhere in a discovered hangar bay (§7.3) |
| **Board ship** | 1 | — | **[built]** From the 3×3 square of your landed ship: walk up the ramp with whatever you carry. Off the board, safe, and sure to leave with the ship; ends the activation (§7.4) |
| **Extract** | 0 | — | **[built]** The word to the pilot: your ship leaves **now** and the mission ends (§7.4). Any of your soldiers, on their own activation, **from anywhere**, once your ship is down and at least one of yours is aboard or in its square |
| **Switch weapon** | 1 | — | **[built]** Primary ↔ pistol (§4.3). Not while carrying (the pistol is forced); picking up a body draws the pistol as part of its own 2 AP |

The extraction actions are **flat costs with no Reflexes discount**, for now.

- **Turn-ending actions:** Hunker Down and Overwatch end the activation outright, whatever AP is
  left. The listed cost is a minimum, not the whole price.
- **Overwatch** is the pool's one interrupt, and it only triggers on enemy movement. A reaction
  shot takes **−30%** when 1 AP is reserved; each additional reserved AP buys back 10, floored at
  0. Committing a whole activation to watching an angle makes the reaction shot as good as a
  deliberate one, never better.

#### 4.2.1 Aimed Shot — Body-Part Targeting **[built]**

| Zone | Accuracy vs. full-aim baseline | On a landed hit |
|---|---|---|
| Torso | +0% | A **crit** also **stuns** (target loses its next activation) |
| Head | −50% | **Doubled** crit chance; a crit may upgrade to **severe (2×)** |
| Left/Right Arm | −20% | Damage accumulates toward that arm's injury threshold |
| Left/Right Leg | −20% | Damage accumulates toward that leg's injury threshold |

- Aimed Shot uses Perception only (no Reflexes term, §4.6).
- **Body-part injury:** each part tracks the cumulative Aimed Shot damage it takes, against a
  threshold that is a fraction of max HP (Torso 50%, Arms/Legs 35%, Head 25%). Crossing it injures
  that part for the rest of the mission, or until it is treated with the medical resource (§7.5).
  - **Injured leg:** −33% movement per leg.
  - **Injured arm:** −15% ranged and −25% melee accuracy, and ×0.6 melee damage, per arm
    (multiplicative).

#### 4.2.2 Grenades **[built]**

- One charge per soldier in the alpha, thrown as either **EMP** or **Frag**.
- **EMP** is the anti-robot tool (it disables Cerberus units, see the security-robot docs).
  **Frag** does area damage, with bonus damage to cover (§6.1.1).
- Grenade count as a loadout/loot resource is **[design]** (§7.5).

#### 4.2.3 Suppression **[built]**

- The shooter spends 8 AP (base) and **3 rounds** to pin one target. Each shooter can hold one
  suppression at a time.
- **The pinned unit** loses **3 AP** from its next activation (floored) and takes **−40%** on its
  own shots. Suppression makes a unit useless, not safe.
- If the pinned unit moves, the suppressor gets a free reaction shot. Suppression ends if the
  suppressor goes down.

### 4.3 Weapons, Ammo & Attachments **[built]**

Detail: [`docs/design/factions/contractors/weapons/`](docs/design/factions/contractors/weapons/).

- **Five primary weapons**, independent of class. Class only sets the loadout screen's default
  suggestion.

| Weapon | Base acc. | Damage | Hits to down a ~20 HP soldier | Class default |
|---|---|---|---|---|
| Assault Rifle | 30 | 8 | 3 | Assault |
| Battle Rifle | 35 | 10 | 2 | Sniper |
| SMG | 35 | 6 | 4 | Support |
| LMG | 28 | 9 | 3 | Heavy |
| Shotgun | 20 | 14 | 2 (falls off fast past 3 tiles) | — |

- **Fixed magazine plus a limited mission reserve.** An empty magazine means Reload before firing.
  Running out of reserve is a real way for a long mission to go wrong.
- **The reserve is separate magazines, not a pool of rounds.** Reload loads the fullest spare and
  the one coming out goes back on the vest with whatever it still holds, so no round is lost. Any
  swap is allowed while the gun isn't full and a spare has rounds, even one that leaves the gun
  with less. Magazine attachments enlarge every magazine rather than changing how many are carried.
  The Shotgun is the exception: a tube fed from a pool of loose shells. Unlimited weapons (robots,
  aliens, the door gun) have no magazines to swap.
- **Ammo reads off the model.** A bar on the primary's right side drains from the barrel toward the
  grip, and a pip per spare magazine sits beside the health band on the back, fullest at the bottom.
  Both use the same colours for how full a magazine is: 70% and up pale yellow, 35% and up orange,
  below that red, and empty shows nothing lit.
- **Attachments** (underbarrel, optic, muzzle, magazine and so on) and **ammo types** modify
  accuracy, damage, noise, visibility and AP. They are fitted on the pre-mission loadout screen.
  Attachments are designed as **tiered loot** (§7.5).
- **Sidearm (pistol): [built, placeholder stats].** Carrying a body allows pistol fire only
  (§4.4), so carrying depends on a pistol. Every soldier deploys with one as **fixed equipped
  gear** (no inventory slot, not chosen on the loadout screen, shown there as a fixed line), with
  its **own magazine and reserve**. It comes out while carrying, or whenever the soldier
  **switches** to it (**1 AP**, either way; refused while carrying). Putting a body down hands back
  whichever gun the soldier last chose. With the pistol in hand Shoot, Aimed Shot and Overwatch use
  its numbers, and Reload reloads it; Suppress is refused only while carrying. Placeholder stats (extraction plan A5):
  **acc 30, dmg 5, mag 8 + 16 reserve, optimal range 6 then −8%/tile, noise 4**. No model or
  one-handed animations yet: it borrows the rifle's poses and the rifle stays on the model.

### 4.4 Downed, Death & Carrying **[built]**

*Replaces v1.1 §4.4 "Injury, Not Permadeath". Built in extraction plan Phase 2; the numbers below
are the defaults in code (`Unit.DOWNED_DRAIN_FRACTION`, `REVIVE_HP_FRACTION`, `MAX_DOWNS`,
`CARRY_REDIRECT_CHANCE`). Medical consumables (better revive, Stabilize) are still [TBD]; Loot
was built in Phase 3 (§7.5). Rules settled while building it are marked (A3)/(A4) or "built:".*

**Downed**
- A soldier at 0 HP is **downed**: they can't act, they leave the pool, and they get a second
  health bar, the **downed bar**. **It is the same size as their max HP**, for now.
- **The downed bar is tracked across downs within a mission.** It starts full at deployment, and
  whatever it loses stays lost: reviving a soldier does not refill it. A second down starts from
  what the first one left.
- The downed bar **drains a fixed amount at each round start** (default: 1/5 of max HP, so 5
  rounds to live on a full bar), and **damage taken while downed also comes off it**.
- **Downed bar empty → dead.**
- **Third time downed in one mission → dead immediately.** The down count and the downed bar both
  reset after each mission.
- **Revive (3 AP):** an adjacent ally brings them back up at low HP (default 25% of max). A medical
  consumable improves this (more HP, or at range for Support) **[TBD]**. Revived soldiers keep
  their down count.
- **Stabilize:** a medical consumable stops the drain without reviving **[TBD]**.
- **On extraction, bleeding stops.** A downed soldier who reaches the ship survives.

**Who shoots the downed.** Targeting downed soldiers on purpose depends on faction:
- **Aliens** finish downed prey. Built: a downed soldier an alien can see (light and line of sight,
  as for anyone) is prey, but a **live soldier in its sight outranks the body**, so a squad
  standing over its downed protects them. The worm is the exception: its mass attacks by
  trampling occupied tiles, so it leaves bodies alone.
- **Rival mercs** do it only when it is cheap. Built: with AP left over after everything else,
  no live contractor in sight, and the shot affordable from where it stands (no step taken).
- **Cerberus robots** ignore them, because a downed body is not a moving threat.

Downed applies to **player contractors only**. Rival mercs die outright at 0 HP, with no downed
state or bleed-out, and leave a lootable corpse (§11.10). The exception is the Recover contract's
**VIP** (§7.5), who starts downed and **does not bleed** (extraction plan A10: stable, not
bleeding), can't be revived, and is never deliberately finished by hostile AI; they are carried
like a downed soldier, and the 25% redirect applies to them.

Stray area damage (grenades) hits downed soldiers regardless.

**Death**
- Death is **permanent**. The soldier is removed from the roster.
- Their **corpse stays on the map** and can be:
  - **looted (1 AP per item):** an adjacent ally moves its gear into their own inventory slots, or
  - **carried out** like a downed soldier, which recovers everything they had.

**Carrying**
- An adjacent ally spends **2 AP** to pick up a downed soldier or a corpse. Dropping one is free.
- The carried body **shares the carrier's tile** and moves with them.
- **The carrier moves unimpeded** (no movement penalty, for now). They **can fire a pistol and
  throw grenades**, but not long guns. **No Suppress while carrying (A4)**: one-handed pistol fire
  is not volume of fire. Overwatch with the pistol is allowed. Carrying takes both hands, not
  inventory slots, and the carried soldier's own loot comes with them.
- **Fire at a carrier:** if the carrier is in cover from that shot, the body cannot be hit.
  Otherwise, **a landed hit has a 25% chance to strike the carried body instead**, coming off its
  downed bar. A corpse takes no damage, and a carried corpse is never hit at all (it does not soak
  rounds for its carrier). Applies to gunfire only; melee always lands on the carrier.
- **Revive and pick up reach** a body on an adjacent tile or on the soldier's own tile (bodies
  hold no tile, so one can lie under a standing soldier). **Revive onto a taken tile (A3):** if
  someone is standing on the body, the soldier is stood up on the free tile next to the reviver
  nearest the body; with none free, revive is refused. A carried soldier must be put down first.
- **Squad wipe:** if every soldier on the map is downed at the same time, nobody is left to carry
  anyone. The mission ends and **all deployed soldiers are lost**.

### 4.5 Unit Classes **[built]**

| Class | Role | Stat tendency |
|---|---|---|
| Assault | Front-line damage, close range | High Fitness, moderate Reflexes, lower Perception |
| Sniper | Long-range precision | High Perception, lower Fitness, moderate Reflexes |
| Support | Healing/buffs, Initiative manipulation | Balanced, Luck skew |
| Heavy Weapons | High damage, area effect, breaks cover | High Fitness, low Reflexes, moderate Perception |

Classes have stat ranges in code (`ClassPresets`), but **no class abilities are built yet**:
Support's healing and Initiative manipulation and the Heavy's cover-breaking are **[design]**.
Support becomes much more important with revive and stabilize (§4.4).

### 4.6 Soldier Stats **[built]**

Four percentile stats (0–99), rolled within class ranges (`ClassPresets`; ranges are placeholders).

| Stat | Major role | Minor role |
|---|---|---|
| **Perception** | Accuracy for Shoot, Aimed Shot, Overwatch | Max vision/detection range |
| **Reflexes** | **AP cost discount** on actions (§4.2) | Accuracy on Shoot/Overwatch (not Aimed Shot); Initiative (+0.2/pt) |
| **Fitness** | **AP pool size** (§4.2) | Max HP = floor(15 + 0.08 × Fitness), so soldiers have ~17–22 HP |
| **Luck** | Reroll, crit, dodge (below) | — |

**Luck** resolves in three ordered phases on every shot:
1. **Reroll (shooter):** a failed roll succeeds anyway at Luck / 8 %.
2. **Crit (shooter):** a landed hit crits at Luck / 4 %, for **1.5× damage**. A crit cannot be dodged.
3. **Dodge (target):** a landed non-crit becomes a miss at Luck / 8 %.

**Armor** is a per-unit flag (`UnitStats.armored`). Contractors, mercs and robots are armored;
aliens are not. It matters to ammo types and robot damage reduction.

**Progression:** level bonuses exist as zeroed constants. Leveling is **[design]**, and matters more
now that veterans can die (§7.5).

### 4.7 Exploration Mode & Turn Mode **[design]**

*Why: decks are getting much bigger (§7.7) so a run can be a real expedition. Walking a squad
across them one activation (~8 tiles) at a time would be tedious. Like Fallout 1 and 2, the game
is turn-based only when there is a fight. Out of combat, soldiers move and act freely.*

#### 4.7.1 The two modes

- **Exploration mode** is the default. No initiative pool and no AP: the players move and act
  freely, and time passes on the **exploration clock** (§4.7.3).
- **Turn mode** is everything in §4.1–4.6: the initiative pool, AP and activations.
- **Combat is global for the squad.** When turn mode starts, **every** soldier is on turns, however
  far from the fight. A soldier across the deck can run over at turn pace.

#### 4.7.2 Entering and leaving combat

- **Turn mode starts** when any hostile is in **COMBAT targeting the squad**: one of the player's
  soldiers, their door gun, or the Recover VIP.
  - **Not** an ALERT enemy investigating a noise. You can still slip past a searching alien in
    exploration mode.
  - **Not** a fight between other factions (an alien against a robot, a merc crew against
    aliens), wherever it is. Those resolve on the exploration clock, and the squad may hear them
    (§5.4).
- **Detection is checked every step** of a free walk, with the ordinary light and sound rules
  (§5, §11.2). A soldier who is spotted **stops on that tile** and turn mode starts. Any other walk
  in progress stops too, including the other co-op player's.
- **Attacking starts combat.** Shooting, an aimed shot, throwing, melee or Suppress at an enemy
  from exploration mode is the opening action, Fallout-style: it resolves, then turn mode begins.
  - **The opening action is paid for.** Its AP comes off the attacker's first activation.
  - **An opening Suppress is the suppressor's whole first activation.** Suppress ends the
    activation it is used in, so the suppressor sits out the opening round's draw. The pin holds
    through that round and lifts at their next activation, as in turn mode.
- **Opening round:** the **normal weighted initiative draw**. No surprise round, and no free first
  activation for either side.
  - **Contact costs no time by itself.** The round in progress becomes the opening round: no
    round passes when turn mode starts, so a downed soldier doesn't bleed and the ship countdown
    doesn't drop just for being spotted. Steps already walked that round are dropped.
- **Who is in the pool:** the squad, plus every unit **near the fight** (within a radius of a
  soldier, or already in COMBAT). Distant units are left out and keep acting on the clock between
  rounds (§4.7.3), so a round on a deck with dozens of enemies doesn't wait on AI half a map away.
  *Radius TBD.*
- **Turn mode ends** once **no hostile has been in COMBAT with the squad for one full round**:
  every hunter has died or lost track (dropped to ALERT or UNAWARE). Exploration mode resumes at
  the start of the next round.
  - **Activation-scoped states clear when combat ends:** hunker down, suppression (both the
    pinned unit and the suppressor) and stun. None of them can carry into the next fight.
  - **Overwatch is the exception:** it carries over, per §4.7.4.

#### 4.7.3 The exploration clock

Every round-based timer still counts rounds: the ship countdown (§7.3–7.4), bleed-out (§4.4), the
Hold terminal (§7.5), nest spawns (§11.7), the merc crews' leave rounds (§11.10) and cooldowns. Out
of combat, a round is measured in **distance walked**:

- **20 steps = 1 round.** Every tile walked by **any** soldier is one step, and all soldiers' steps
  add to one shared counter. Scouting with one soldier is cheap. Shuffling four soldiers
  separately costs four times as much.
  - **A wounded leg costs more steps.** A tile costs what it costs in AP (§4.2.1): 2 steps with
    one injured leg, 3 with two. A limping soldier burns the squad's clock faster.
- **Actions cost steps equal to their AP price** (loot 1 per item, pick up 2, revive 3, operate
  terminal 2, call ship 1, board 1, switch weapon 1), so stripping a room or reviving in a
  bleed-out race still costs time. Reload and doors stay cheap at their AP price, and actions that
  cost 0 AP cost 0 steps.
- **Each time the counter reaches 20, a round passes:** the round-start timers tick, and **every
  unit not in combat takes its normal UNAWARE/ALERT turn**: patrols walk, merc crews work their job,
  robots sweep, ALERT enemies investigate. A patrol can walk into the squad this way, which starts
  combat.
  - **An action always lands before the round it crosses.** At 19 steps, a revive (3) resolves
    first, then the round passes, and the counter carries the remainder (2). A revive that started
    in time arrives in time.
  - **Walks pause for the round.** Soldiers walking when the counter reaches 20 stop at the next
    tile while the enemies take their turns, then carry on. If those turns start a fight, any
    enemies yet to act lose their turn and simply join the opening round.
  - **The enemies' turns play out together.** They are decided one at a time, in order, but shown
    at once, so a round of patrols doesn't hold the squad up one unit at a time. Their
    flashlights sweep along the paths they walk, and they come into view or leave it where
    their path crosses the edge of what the squad can see.
- **Standing still costs nothing.** Thinking is free.
- **Wait:** one press passes time to the start of the next round. It is how a squad lets a ship
  arrive, holds a terminal, or lets a patrol pass. Pressing it again waits another round. Waiting
  isn't acting, so it never breaks a soldier's overwatch.
- **Reference speeds at 20 steps a round:** a 150-tile crossing is about 8 rounds. Carrying a
  downed soldier (about 5 rounds of bleed) reaches roughly 100 tiles.

#### 4.7.4 What exploration mode allows

- **Movement:** select any of the player's soldiers, in any order, and send them to any reachable
  tile. No AP, no distance cap. Individual control only for now; no group or follow moves.
  - **Selecting:** click the soldier in the world or in the squad portrait bar, or cycle with
    Tab. The portrait bar shows in both modes.
  - **Redirecting:** a new order for a soldier who is still walking takes over at the next tile.
  - **The move preview** shows the path to the cursor and its cost in steps and rounds. There's
    no reachable-area overlay out of combat.
- **Free actions (no AP, but steps per §4.7.3):** loot, doors, flashlight, reload, switch weapon,
  revive, pick up, drop, call ship, board, operate terminal. Extract is also available (§7.4) once
  valid.
- **Not available out of combat:** Hunker Down, which protects against nothing until a fight
  starts. Every attack, Suppress included, starts combat (§4.7.2).
- **Overwatch** can be set in exploration mode, at its AP price in steps. It holds **until it
  fires or that soldier moves or acts**, so a squad can lay an ambush and reposition others around
  it. Waiting doesn't break it. A triggered overwatch shot is an attack and starts combat.
- **Stealth:** no separate sneak stance. The flashlight and the dark are the stealth tools (§5.2,
  §11.2).
- **Co-op:** both players free-move their own soldiers **at the same time**. The host puts the
  moves in order, keeps the one shared step counter, and stops both players when combat starts.
  - **A destination is claimed when it is ordered.** Sending a soldier to a tile the other
    player's soldier is already headed for is refused ("tile taken").
  - **Either player can wait**, and it takes effect at once for both. Walks in progress pause for
    the round like any other.
  - **The portrait bar** shows the partner's soldiers too, greyed and not selectable.

Build plan: [`EXPLORATION_PLAN.md`](EXPLORATION_PLAN.md).

---

## 5. Line of Sight, Lighting & Detection

### 5.1 Light as a Continuous Value **[built]**

- Every tile has a **light value of 0–100**.
- **Light modifier on accuracy:** linear from **−30%** at 0 to **+10%** at 100, applied to the
  target's tile. A tile no light reaches is 0, so pitch dark is a real liability rather than
  neutral.
- **Exception: Cerberus robots** neither read light nor are read by it. The light term is 0 for any
  roll with a robot on either side (§11.9).

### 5.2 Flashlights **[built]**

- Every contractor (and every rival merc) carries a rig light, mounted on the weapon's barrel:
  a **90° cone, 6-tile range, 75 intensity** at the source, falling off linearly.
- **Toggle: free (0 AP).** Off reduces your own vision and how visible you are.
- Aliens and robots carry no lights.

### 5.3 Environmental Light Sources **[built]**

| Fixture | Range | Intensity | Notes |
|---|---|---|---|
| Overhead light | 6 tiles | 90 | Steady |
| Monitor/terminal | 2.5 tiles | 45 | Small pool |
| Flickering light | 6 tiles | 25–90 | Rerolled every round start |

All fixtures are omnidirectional and occluded by walls and closed doors the same way LOS is.
Emergency lighting, fires/sparks and total-darkness zones are level-dressing roles for these
fixtures. **Muzzle flashes emit no gameplay light.** They are a visual effect only.

### 5.4 Sound & Detection **[built]**

- Sound is an **independent detection channel**: gunfire, explosions and loud actions alert units
  regardless of light.
- **Gunfire noise radius = the weapon's `noise_radius`** (5 tiles for every weapon until tuned).
  Suppressors and subsonic ammo shrink it.
- Hearing reveals the **general area** of a sound, not who made it.
- Closed doors block sound.
- **Ship call-ins are the loudest event in the game:** a 15-tile sound event, plus a map-wide radio
  notice (§7.3).

---

## 6. Cover & Elevation

### 6.1 Cover **[built]**

- **Heavy cover: −40%** to shooters targeting a unit behind it. **Light cover: −20%.**
- Two kinds:
  - **Edge cover** sits on the boundary between two tiles (XCOM-style). It is used on
    hand-authored maps.
  - **Block cover** occupies tiles (1×1 up to 3×2). The generator places it.
- Cover only applies when the shot comes through it (see Flanking, §6.2).

### 6.1.1 Destructible Cover **[built]**

- Cover has HP. **Every shot at a unit in cover damages the cover, hit or miss.**
- Suggested: Light 20 HP, Heavy 50 HP. Grenades and Heavy Weapons do bonus damage to cover
  (multiplier TBD).
- **At 0 HP, cover becomes impassable rubble.** It gives no protection and blocks movement, so
  fights reshape the map.

### 6.2 Flanking **[built]**

A shooter with a clear angle to the side or rear of the cover ignores its penalty entirely.

### 6.3 Hunker Down **[built]**

An **extra −20%** to shooters targeting the unit, stacking with cover. It lasts until the unit's
next activation.

### 6.4 Elevation **[built]**

**+15%** when shooting at a target on a lower level. Changing floors costs nothing extra.

### 6.5 Accuracy Formula **[built]**

All modifiers add together. The final value is clamped to 1–99, then Luck resolves (§4.6).

```
Final Accuracy % =
    Perception contribution (+ Reflexes contribution if Shoot/Overwatch)
  + Weapon base accuracy (+ attachment/ammo modifiers)
  + Light modifier            (−30 … +10, target's tile; 0 if a robot is involved)
  + Elevation bonus           (+15 if shooter has high ground)
  + Aimed Shot zone modifier  (0 / −20 / −50)
  − Cover penalty             (−40 heavy / −20 light / 0 if flanked)
  − Hunker penalty            (−20)
  − Overwatch penalty         (−30, reduced by extra reserve)
  − Suppressed penalty        (−40 if the SHOOTER is pinned)
  − Distance falloff          (global curve + weapon's own falloff past its optimal range)
```

**Global distance falloff:** none out to 3 tiles, then −1%/tile to 10 tiles, then −12%/tile past 10.

| Tiles | 3 | 6 | 8 | 10 | 12 | 14 | 16 |
|---|---|---|---|---|---|---|---|
| Penalty | 0 | −3 | −5 | −7 | −31 | −55 | −79 |

**Melee:** attacker Perception + melee base accuracy (45), ± high ground and the target's Hunker,
then Luck. Cover, falloff and light deliberately do not apply to melee. Melee does not damage cover.

**Robot armor** is damage reduction applied *after* a hit lands, not an accuracy term.

---

## 7. Mission & Meta Structure

*Wholly replaces v1.1 §7 (clear-out missions, squad wipe as the only loss). What is built today:
a mission is won by downing every hostile and lost on a squad wipe (`TurnManager`). Everything
below is **[design]** unless marked.*

### 7.1 The Mission Loop

1. **Contract & loadout.** Pick a contract from the mission pool. Choose 2–4 soldiers and fit
   their loadouts (weapons, attachments, ammo, grenades). The loadout screen exists **[built]**.
2. **Insertion.** A dropship lands at the insertion hangar **before round 1** (cinematic, outside
   the pool). The squad deploys onto the 3×3 square in front of the ramp, and the ship leaves.
   Insertion hangars are generated with no enemies on them.
3. **The run.** Explore the deck: find the objective, loot, find other hangars. The deck is
   procedurally generated (§10.4) and populated by any mix of the three hostile factions. Out of
   combat the squad moves freely on the exploration clock; any fight with the squad drops
   everyone into turns (§4.7). **[design]**
4. **Call-in.** At a hangar, call the ship (§7.3), then hold out until it lands.
5. **Board & extract.** Get everyone you can into the 3×3 square. Soldiers there can **board**
   (off the board and safe, with whatever they carry) while others hold the bay. When you choose to
   **Extract**, the ship leaves at once with everyone aboard and everyone in the square; everyone
   else is left behind.
6. **Debrief.** Sell valuables, keep gear, pay for recovery, hire replacements (§7.5).

### 7.2 Hangars

- **3–4 hangars per deck**, scaled by deck size. A hangar is a set-piece room in the generator
  (§10.4): an open bay, a landing pad, and a fixed **3×3 extraction square** in front of where the
  ramp comes down. **[built]**
  - **On the larger decks (§7.7): 4–6 hangars. [design]** That is more than today, but far below
    today's density. A hangar stays a real destination, but the nearest undiscovered one is never
    absurdly far away.
- **Every hangar has its designated square, always usable.** The pad and the square are never
  under a wall, cover, wreck or crate (generated decks are built that way and fuzz-tested; a
  hand-made deck that breaks it is an error on load).
- **The ship's space is reserved: a 5×5 pad** (7.5 m a side), sized for the real dropship model
  rather than the placeholder box. While a ship is down the pad blocks movement, **line of sight
  and light**, like a bulkhead; the 3×3 square in front of it does not. The door gunner on the
  hull still sees over it, and can be seen.
- **Bays are big: 3–4× their landing zone** (the pad and the square with a tile of apron, 7×10 —
  so 210–280 tiles). The rest of the bay is the ground the squad holds while the ship comes in:
  **1–2 wrecked ships** (full-height, indestructible; they block sight and light and give heavy
  cover) and **4–7 ordinary cover pieces**, all kept a tile clear of the pad and square. Wrecks are
  placeholder boxes until the wreck props exist. Decks grew one size to fit them (§7.7).
- **Any hangar can be used for extraction, including the one you inserted at.** A safe run (grab
  nearby loot and walk back) is legal and pays poorly. That is intended.
- **Only the insertion hangar is known at mission start.** Others appear on the map once
  **discovered**: a hangar is discovered when any of the player's soldiers **enters the hangar
  room**, for now. Discovery is shared by the whole squad. Another crew's call-in does not reveal a
  hangar (§7.3), though hearing its 15-tile sound gives the general direction.
- **Rival merc crews discover hangars the same way [built]:** a crew knows a hangar once one of its
  members has entered the room (or spawned in it), and can only call one it knows. They do not
  start with a map of the deck. *(Replaces the extraction plan's assumption A11, "mercs know every
  hangar".)*

### 7.3 Calling the Ship

- A soldier **at a hangar** spends **1 AP** to call the ship. They can stand **anywhere in the hangar bay**;
  there's no console to reach.
- **Every call-in is loud:**
  - a **15-tile sound event** from the hangar, which reaches every faction through the ordinary
    sound channel, and
  - a **map-wide radio notice to every contractor crew**: the player's squad and every rival merc
    squad learn **that** a ship has been called, but **not where**. Only the 15-tile sound gives
    away the location, so a call-in never reveals an undiscovered hangar.
- **Arrival: 3 rounds** after the call. A visible countdown ticks at each round start.
- **First call claims the hangar.** A hangar holds one ship at a time. If mercs called it first, it
  is theirs until their ship leaves. You can still kill them before it lands.
- The ship always arrives on schedule. The countdown cannot be cancelled **[TBD: confirm]**.

### 7.4 The Landed Ship: Board & Extract **[built]**

- Once landed, the ship **waits up to 5 rounds**.
- **Board (1 AP):** a soldier standing in the 3×3 square of **your** landed ship can walk up the
  ramp, taking whatever they carry (a downed squadmate, a corpse, the VIP). They leave the board:
  nothing can target, finish or bleed them, and they are certain to leave with the ship however
  the mission ends from here. Boarding ends their activation and **does not end the mission**.
  So one soldier can hold off the bay while another gets the wounded aboard, then step into the
  square and give the word.
- **Extract (0 AP):** once your ship is down and **at least one of your soldiers is aboard or in
  its square**, any of your soldiers may give the word **on their own activation, wherever they
  stand**. It does not need to be the soldier in the square. The ship leaves **at once** and **the
  mission ends**. The HUD names whoever would be left behind and asks first.
  - Only **your own crew's** ship counts. You can never extract on a rival's ship, even standing
    in its square.
- If nobody gives the word, the ship **leaves when its 5-round window expires**, taking everyone
  aboard and everyone in the square. If anyone left that way, the mission ends.
- If **nobody of yours is left standing on the deck** but some are aboard, the pilot takes off with
  them. That is an extraction, not a wipe.
- **One lift ends the mission, for the player crew:** your ship leaving with at least one of your
  soldiers ends the mission for both players. **A rival crew's lift never ends it** (below).
- **When your ship leaves:**
  - Everyone aboard extracts, and so does every contractor in the 3×3 square that is not dead,
    with anything they are carrying (a downed soldier or a corpse).
  - Every contractor **not** aboard or in the square is **left behind and permanently lost**, with
    everything they carry.
  - If nobody was aboard or in the square, nobody extracts and the mission continues. That hangar
    can be called again after a **5-round cooldown**.
- **Door gun:** a landed ship carries a gunner who joins the initiative pool (hidden Initiative,
  like an enemy) and fires on hostiles near the ramp. Enemies can **disable** it with enough damage,
  and it stays down for the rest of that landing (a re-called ship brings a fresh gunner). **The
  ship itself cannot be damaged.** Gunner stats are TBD. **[built, placeholder stats]**
  (`DoorGunUnit`): HP 30, armored (2 off every hit), LMG accuracy and damage on an endless belt,
  two shots per activation at the best target in LOS within 6 tiles of the square, Initiative 65,
  and the light modifier applies.
- Enemies can stand in the square. They take up tiles your soldiers need but don't block Extract.
- Rival merc ships work the same way, door gun included, and theirs shoots at you. **[built]**
  (Rival crews still leave by the older dust-off rule: they hold the square and signal departure at
  the end of a round. They don't use Board yet.)
  A merc crew's lift ends **their** run, never the player's mission: the mercs in the square leave
  the board with their packs (that loot is gone, and so is a Retrieve item one of them carries);
  a member left outside is stranded and goes on as an ordinary merc, and that crew can never call
  again. A merc crew's empty departure cools the pad down like anyone's. What the player sees: the
  radio line "Another crew has called a ship" (no place), and — only for a hangar they have
  discovered — the marker, the hull on the pad, the square and the landing/lift-off lines; for an
  undiscovered one only "A rival crew's ship has left the deck" over the radio. The debrief lists
  each rival lift (who got out, how many items, how many stranded).

### 7.5 Objectives, Loot & the Economy

**Objectives.** Every contract has one. It is **optional**, and it is the biggest payout and the
only source of campaign progress. Four types:

| Type | What | Builds on |
|---|---|---|
| **Retrieve** | Find an item and extract with it. It takes an inventory slot, and losing its carrier loses it. Built: planted in a crate in a room from the farthest third by path distance; met if it is in the pack of anyone aboard, a carried corpse included | Inventory **[built]** |
| **Destroy** | Destroy a target (nest, server, reactor). Built for the nest: met when it dies, paid only if someone extracts | `NestUnit` **[built]** |
| **Hold a terminal** | Stay at a console for N rounds. Noisy. Built: a console against a wall in a room from the farthest third, blocking its tile. A soldier beside it **operates** it (2 AP flat); at each round start it counts a round if any soldier is standing beside it (either co-op player's), and it makes a **radius-8 noise** the round it starts and every round it counts. Nobody beside it at a round start **pauses** it: the count is kept, but it does not resume until someone operates it again (2 AP again). **4 held rounds** complete it, and that latches; paid only if someone extracts | Sound channel **[built]** |
| **Recover** | Find a downed VIP and carry them out. Built: the VIP lies **downed** in a room from the farthest third. They are **stable** (no bleed, A10), **can't be revived**, and hostile AI never sets out to finish them, though stray damage (a grenade, the 25% redirect while carried) comes off their downed bar and can kill them. Any soldier can pick them up (2 AP). Met if they leave on the ship **alive**: carried aboard, or set down in the square at departure. They are not part of the squad (no roll call, no debrief entry) | Carrying (§4.4) **[built]** |

Placeholder payouts (Medium deck; Small ×0.7, Large ×1.3): Retrieve 500, Destroy 600, **Hold 550**
(four loud rounds pinned to one console, nothing to carry home), **Recover 650** (the walk back is
pistol-only and the VIP can die in the carrier's arms). **[built]**

**Loot.**
- **Valuables** sell for credits. **Gear** (attachments, ammo, consumables, weapons) can be equipped
  next mission. Attachments are already designed as tiered loot, with weaker items being the
  common finds.
- **Salvage** from destroyed robots is one kind of valuable **[built]**: one item per wreck, worth the robot's salvage points, looted off the wreck.
- Each soldier has **4 inventory slots**, for now. Every item takes one slot. **Equipped gear takes
  no slots**: the weapon in hand, the pistol, fitted attachments and grenades are separate from
  the four.
  Carrying a body uses hands, not slots.
- Loot only counts if it extracts. A soldier left behind loses their loadout and everything they
  picked up.
- **Built (extraction plan Phase 3):**
  - **Sources:** loot crates in ordinary rooms (never hangars), and corpses of any faction. A
    corpse holds its pack plus its equipped gear as items: the weapon with its attachments as one
    item, and each grenade as one. The issued pistol is not loot.
  - **Taking:** 1 AP per item, from an adjacent tile or the soldier's own tile, into a free slot.
  - **What can't be looted:** a downed soldier (only corpses), and a carried body.
  - **Dropping** is free and leaves a lootable pile on the tile (A6).
  - **Mercs** carry a few valuables.
  - **Values** are placeholders until the economy lands.
- **Gear in crates [built] (extraction plan Phase 6):** a quarter of crate items are gear rather
  than valuables. Gear is tiered on the shop's price ladder and rolled 60/30/10 like valuables, so
  the weaker attachments are the common finds: tier 1 the flat +3/+5 and magazine attachments
  and grenades (a third of tier-1 finds), tier 2 the sights, suppressor, grips, drum and ergo
  stock plus the FMJ / Subsonic / Hollow Point / Slug ammo unlocks, tier 3 Long Barrel, Scope,
  Thermal and Penetrator. Standard ammo is never loot. A deck carries 3–4 pieces on average.
  At the debrief an attachment becomes a stash copy, an ammo item unlocks its type (or sells for
  its value if already owned), a grenade restocks. A gear item's credit value is about a third of
  its shop price (a signal on the loot panel; gear is equipped, not sold).
- **On the larger decks (§7.7): the same total loot, spread thinner. [design]** A deck carries
  about as many crates as it does today, scattered over roughly nine times the floor, so the
  economy stays as tuned and finding loot becomes part of exploring. Merc pockets and corpses are
  unchanged.

**Economy.**
- **Credits** buy loadouts and gear, and **hire recruits** (rolled within class ranges, like today).
- **Medical resource** (name TBD) clears body-part injuries and other between-mission damage.
- **Game over:** if you can't field a squad and can't afford a recruit, the campaign ends.

### 7.6 Co-op

- Both players' soldiers are **one squad with one extraction**: there's a single ship per mission
  between the two players, not one each. Either player can call it, either player's soldiers count
  in the square, and when it leaves the mission ends for both.
- **Cross-player rescue:** a soldier can revive, pick up, carry and loot **any** friendly
  soldier, including one owned by the other player. The carried soldier stays owned by their
  player; they're just a body until revived.
- **Who can board and extract:** either player, on their own soldier's activation. Either player's
  soldier can carry the other's casualty aboard, and either can give the word to extract, which
  ends the mission for both.
- **Exploration mode [design]:** both players free-move their own soldiers at the same time.
  There is one shared step clock, and combat stops both (§4.7.4).
- Rosters, credits and stash ownership in co-op are **[TBD]**: shared campaign, or each player
  brings their own soldiers.

### 7.7 Mission Length

The target is **20–40 minutes**. Deck size, hangar count and objective placement are the levers.
Deck sizes **[built]**: Small 60×40, Medium 72×48 (the generator default), Large 84×56. Each is one
step up from before, to fit the bigger hangar bays (§7.2).

**Much bigger decks [design].** Exploration mode (§4.7) makes distance cheap, so decks grow
**3× or more per side** (about 9× the area). For example: Medium around 216×144, with Small and
Large scaled to match. The target stays **20–40 minutes**: free movement absorbs the walking, and
most of the time should go to fights.

- **Scaled up:**
  - **Hangars:** 4–6 (§7.2).
  - **Enemies:** the same density as now, so roughly 9× as many alien rooms and nests, and several
    merc crews on a deck.
- **Not scaled up:**
  - **Loot:** about the same total (§7.5).
  - **Objectives:** still in the farthest third, so reaching the objective is a long walk, made
    cheap by exploration mode.
- **Open tension:** 9× the enemies probably means far more fights than fit in 40 minutes. Likely
  fixes are making most of the extra alien rooms dormant (asleep until disturbed), or scaling
  enemies with hangars and objectives rather than area. Settle this by measuring, not on paper
  (§12.1).

**Baseline on today's decks (2026-10-30), before retuning.** Headless `--auto-campaign=4`, one
unseeded run of each mode, every mission extracted. The bot is not a player, so read these as
"rounds still pass at about the old rate", not as playtime.

| Mode | Rounds per mission | Of which out of combat | Contacts per mission |
|---|---|---|---|
| Exploration | 24, 26, 24, 27 | 10, 2, 2, 11 | 1, 1, 1, 2 |
| `--turn-mode` | 17, 31, 22, 27 | none | none |

Steps per round is still the initial 20. Tuning it against a human playtest is open
(`EXPLORATION_PLAN.md` D.4).

---

## 8. Setting & Tone

- **Theme:** Sci-fi / military-contractor, aboard decrepit derelict ships (*Dead Space*).
- **The player's crew** are hired contractors: worn gear, no insignia.
- **Narrative:** No narrative focus for now. Contracts, Cerberus Applied Sciences (the robots'
  manufacturer) and rival crews are the only fiction, and they exist for mechanics.

---

## 9. Production Scope

- **Team:** small (2–5).
- **The main investments:**
  - the two signature systems (the initiative pool, and light/sound visibility),
  - the shared GOAP AI, and
  - the extraction loop.

  The extraction loop is the largest new piece. It brings in carrying, the downed bar, hangars and
  the ship, inventory, an economy and merc extraction AI. See §12 for the proposed build order.
- **Out of scope:** base building, narrative campaign, permanent world state between missions.

---

## 10. Technical Implementation

*Numeric constants live as named, commented constants (or exported resources) beside the code that
uses them. Don't hardcode them anywhere else.*

### 10.1 Engine & Target

Godot 4.x, PC native, Steam (GodotSteam addon). A real 3D scene with the grid as a logical layer
over it.

### 10.2 Camera **[built]**

Orthographic rig (`scenes/camera_rig.tscn`, `camera_rig.gd`):
- Fixed pitch `atan(1/√2)`.
- Yaw snapped to 45/135/225/315° (Q/E).
- WASD pan.
- Scroll zoom over `Camera3D.size` 10.5–30.

`PixelView` mirrors the camera into a low-resolution SubViewport for the pixel look. Picking, audio
and the HUD stay on the root camera.

### 10.3 Grid **[built]**

- One global grid per deck. Key: `Vector3i(x, floor, z)`. Tile 1.5 m, floor height 3 m.
- Per-tile data: passability, cover, occupant, light value, door reference.
- Owned by the `GridManager` autoload, which does BFS range queries and LOS.

### 10.4 Deck Generation **[built: generic decks]**

- `MapGenerator` uses **room-first placement**: independently sized rooms (3–16 tiles per axis) by
  rejection sampling, then corridors (≥2 wide) carved along a spanning tree plus ~20% extra links
  for loops, then a block-cover pass.
- Deterministic in its seed; hundreds of decks per second for headless testing.
- Hand-authored decks are ASCII (`maps/*.txt`, `MapAscii`).
- **Rooms → compartments → room graph** (`MapData.compute_rooms`) drives occlusion, alert scoping
  and robot zones.
- **[design] for extraction:**
  - hangars as set-piece rooms (3–4, spread apart, one tagged as insertion),
  - objective rooms,
  - loot placement, and
  - a connectivity check guaranteeing every hangar is reachable.
- **Bigger decks [design] (§7.7):** 3× or more per side, about 30,000 tiles for a Medium deck. Several
  things that are fine today won't scale and need performance work before decks grow:
  - flashlight lighting rescans every tile on every step;
  - pathfinding searches the whole map on every move;
  - every wall cell gets its own physics body;
  - exploration mode adds a detection check per enemy per step.

  Chunked lighting, bounded pathfinding, merged wall collision and nearby-only detection checks are
  the likely fixes.
- **Rival merc crew [built, placeholder rate]:** about 40% of generated decks (`Config.merc_squad_chance`
  0.4) carry one merc squad of 3, spawned together in one ordinary room — never a hangar, a
  corridor, the insertion's neighbourhood or a room with an alien spawn. Placed as the last draw
  on the deck's RNG, so the rest of a seed's deck is unchanged.

### 10.5 Doors **[built]**

Free to toggle (0 AP). Closed doors block LOS, light and sound.

### 10.6 Line of Sight & Visibility **[built]**

- Raycast LOS with multiple sample points per unit.
- **Shared team vision.**
- Recomputed on state changes (movement, doors, deaths), never per frame.
- **Rendering is gated by room**, not per-unit raycast. Enemies render in rooms the squad can see
  into, which also drives fast-forwarding unseen activations.
- Static geometry is always drawn.

### 10.7 Occupancy **[built]**

One unit per tile. Movement resolution and the preview both exclude occupied tiles. The one
exception is a carried body, which rides on its carrier's tile (§4.4).

### 10.8 Lighting **[built]**

- The `LightingManager` autoload is the only writer of `light_value`. It has two layers:
  - **Base layer:** static fixtures, recomputed at load and when flickers reroll.
  - **Dynamic layer:** flashlights, recomputed on move or toggle.
- Occlusion uses the same wall raycast as LOS. Linear Chebyshev falloff.
- Each `LightSource` carries a visual-only `SpotLight3D`. The flashlight's `SpotLight3D` is mounted
  on the barrel, and the manager reads its direction.

### 10.9 Networking **[built, prototype]**

- `SteamLobby` autoload (GodotSteam + SteamMultiplayerPeer), 2-member friends-only lobby.
- **Host-authoritative:** the host's `TurnManager` draws the pool and resolves combat, then
  broadcasts activations and log lines. A client's `TurnManager` stays inert.
- Each unit carries `owner_peer_id`. Input is gated on local ownership.
- A host leaving returns both players to the menu.

---

## 11. Factions & AI

Three hostile factions, each built on shared systems: the pool, the accuracy formula, light/sound
detection and (for two of them) the shared GOAP planner. Each faction's doc is the source of truth;
this section gives the one-line version and the cross-faction rules.

### 11.0 Cross-Faction Hostility **[built]**

**Every faction is hostile to every other.** Fights happen as each faction's identity would have
them, not through a scripted three-way war:

| Faction | Who it fights | How |
|---|---|---|
| **Aliens** | Anything they detect | Prey is prey. They hunt by light and sound, so a robot patrol making noise or a merc crew with rig lights on draws them exactly as the player does |
| **Cerberus** | Anything that isn't Cerberus | Every non-robot is an intruder. Motion and sound pick out aliens and mercs the same as contractors |
| **Rival mercs** | The player crew always; others when they're in the way | Professionals. They fight aliens and robots that detect them or block the job, and otherwise route around them. Their GOAP goals weigh "is this fight worth it" |

- The result the design wants: a gunfight two rooms away is information, an opening, and a noise
  source all at once. **Third-party fights are legitimate player tools.** Letting robots and
  aliens grind each other down, or arriving after the mercs have cleared a room, is good play.
- **Risk:** a squad that hides while factions attrit each other could farm safety. Extraction
  pressure (nests, ammo, the call-in being loud) is the intended brake. Watch for it in playtest.
- **Built** (extraction plan Phase 7): `Faction.HOSTILE_TO` is the full matrix, and the
  per-faction choices live in `CrossFactionRules`:
  - **Aliens** pick the nearest thing they detect, whatever it is. They see by light, so an unlit
    robot is invisible to them until it fires: a shot always tells the target who fired it.
    Rig lights and robot gunfire draw them like the squad's do.
  - **Cerberus** ranks every detected intruder by one faction-blind threat score: has it fired
    on a robot in this zone (remembered zone-wide), is it armed, is it moving, how close. A robot
    already fighting switches only for a clearly bigger threat, and anything that shoots the
    network always qualifies.
  - **Rival mercs** always engage the player crew, and rank the crew first. They engage an alien
    or robot only when it is hunting the squad (fighting a member, or has hit or shot one), sits
    on the next ~6 tiles of their route, or is within 3 tiles of a member. Otherwise they leave it
    alone and route around it (a path surcharge within 2 tiles of any third party the squad can
    see). A merc fighting a third party breaks off when none of those holds any more.
  - Overwatch and suppression already asked `is_hostile_to`, so both work across factions.
  - Generated decks still spawn aliens only, so three-way fights happen on the authored decks
    (`test_deck`, `coordination_deck`) until spawn mixes are designed.

*Subsections 11.1–11.8 keep their v1.1 numbers because a lot of code and docs cite them. The two
newer factions come after, at 11.9 and 11.10.*

### 11.1 Shared AI Model **[built]**

- **Awareness states:** Unaware → Alert/Investigating → Combat. **Search** (sweep the
  last-known position before standing down) is **[design]**.
- **GOAP coordination** ([`docs/design/systems/coordinated-ai/`](docs/design/systems/coordinated-ai/)):
  - A* planning over a shared action library, costed by the real AP formulas.
  - Per-squad blackboards and role assignment. Claims outlive activations because the pool
    interleaves turns.
  - A **doctrine** per faction (which actions it may use, and in what goal order).
  - Fodder-tier units are deliberately planner-free.
- Every AI unit is a normal pool participant. Its state decides *what* it does when drawn, never
  *whether* it is drawn.

### 11.2 Alien Detection & Alerts **[built]** — the lighting puzzle

Faction doc: [`docs/design/factions/aliens/`](docs/design/factions/aliens/)

- **Detection:** the same light and sound rules as the player, and no lights of their own. The one
  exception is the Worm, which feels footsteps through the deck.
- **Alerts are local to the compartment** (room graph, §10.4). Closing doors isolates fights.
- **`AlienHivemind`:** a few loud events escalate ship-wide *once*. Roused aliens walk toward the
  noise in Alert, not Combat. Escalation settles after 4 rounds. A ship call-in (§7.3) does **not**
  escalate: its 15-tile noise already reaches every alien in range through the ordinary sound
  channel, and an escalation on top would make every call-in a deck-wide wake-up.

### 11.3 Alien Roster

| Unit | Role | Status |
|---|---|---|
| Fodder (swarm) | Slow melee attrition | built |
| Brawler | Heavy of the melee tier | built |
| Agile Hunter | Darkness ambusher (planner-driven) | built |
| Worm / worm mass | Alarm and seed; piles grow into the real encounter | built |
| Spitter | Hitscan ranged support | **design** |
| Nest | Spawner and Destroy objective | **built** |

Aliens finish downed soldiers (§4.4).

### 11.4 Fodder **[built]**

- Slow, tanky, melee only. The threat is **attrition**: it drains AP and ammo rather than doing
  big damage per hit.
- **A 6 AP pool against a 5 AP claw:** it can step one tile and swing, but anything two or more
  tiles away can't arrive and strike in the same activation. That one round of warning is the
  design, so keep it (`tools/test_swarm_pace.gd` asserts it).
- Melee: base accuracy 45, damage 3. Contact uses movement adjacency. Unit doc:
  [`units/fodder/`](docs/design/factions/aliens/units/fodder/).

### 11.5 Agile Hunter **[built]**

Fast and fragile. It ambushes only when **both** the target's tile is dark enough **and** it is
close enough (both thresholds TBD). Solo or in pairs. Planner-driven.

### 11.6 Spitter **[design]**

Slow-moderate and fragile, with a **hitscan** ranged attack. It keeps its distance and screens
Fodder. Range, falloff and minimum range are TBD.

### 11.7 Spawn Nests **[built]**

- An HP object (50 HP) and the natural **Destroy** objective (§7.5).
- **Spawns 1 unit every 3 rounds** while alive (70% Fodder / 20% Spitter / 10% Agile Hunter).
- **Built:** HP, destruction, spawning (one unit every 3 of its activations into the first free adjacent tile; the unbuilt Spitter's 20% spawns Fodder), and the hookup to
  `AlienHivemind.report_nest_destroyed` on death.
- On an extraction map, a living nest is a slow clock that raises the cost of lingering.

### 11.8 Implementation Notes

- `EnemyUnit` is the alien base class (the state machine and senses). The subclasses are
  `SwarmUnit`, `BrawlerUnit`, `AgileHunterUnit`, `WormUnit` and `NestUnit`.
- Per-type stats live in `AlienPresets`, alongside `ClassPresets`, `MercPresets` and
  `CerberusPresets`.
- Spawn points are deck data (`MapData.*_spawns`). Spawning by objective or difficulty is
  **[design]**.

### 11.9 Cerberus Applied Sciences — security robots **[built: alpha]** — the positioning puzzle

[`docs/design/factions/security-robots/`](docs/design/factions/security-robots/)

- **Light-blind:** they detect by **motion and sound** only, and the light modifier is 0 in both
  directions. Standing still beats killing the lights.
- **Network alert** across a zone (currently one compartment plus its doorways).
- **Armored** (damage reduction after the hit) and **destroyed outright** at 0 HP. They drop
  **Salvage**.
- **EMP** is the counter.
- **Roster:** Securus (elite), Proctor (detector), Sagittarii (heavy ranged), Auxilium
  (chokepoint anchor), Lictor (cover-breaker).
- Ignores downed soldiers (§4.4).
- Treats aliens and mercs as intruders too, ranked by threat (§11.0).

### 11.10 Rival Mercs **[built: alpha]** — the mirror

[`docs/design/factions/rival-mercs/`](docs/design/factions/rival-mercs/)

- A contractor crew running the same game as the player: light + sound detection, rig lights,
  same cover posture.
- **Mercs die outright at 0 HP**, with no downed state or bleed-out (simpler than the player's
  rules, for now). The corpse stays on the map and can be looted (1 AP per item) for its gear and
  whatever it was carrying. *(Supersedes the merc doc's "injured, recoverable".)*
- **Squad-wide radio alert:** engage one and you engage them all.
- **Built:** GOAP Suppress → Flank doctrine, role assignment, map-wide patrol while Unaware.
- **Built for extraction (extraction plan Phase 8):** mercs carry loot, pursue their own job,
  **call hangars on the same rules as the player** (§7.3–7.4, door gun included), and can be
  killed for their loot. On an extraction deck each merc squad is its own crew with a job
  (`MercJob`, placeholder numbers):
  - **Job:** loot 2–3 containers (crates or piles, counted once each; through the same 1 AP loot
    action as the player's; they leave the player's objective item alone), or — on a Retrieve
    contract, half the time — **contest the player's item**: go to wherever it is (crate, pile or
    body) and take it first.
  - **Scouting:** they know containers in rooms they have walked through and hangars they have
    entered (§7.2); with nothing known they head for the nearest room they have not seen.
  - **Leaving** when any holds: the job is done, every pack is full, half the crew is down, or a
    rolled round limit (16–24) is reached. They make for the nearest hangar they know that can be
    called, call from the bay (1 AP), hold the square, and **board before they fight** once the ship
    is down (they shoot from the square, never leaving it). Dust-off when everyone alive is in the
    square, or at least half of them and the ship has waited 3 rounds.
  - An extracting crew does not wander off after noises, and its routes avoid hostile door guns'
    fields of fire (+4 per tile) on top of the third-party avoidance.
  - They hear every call-in over the map-wide radio notice (that a ship was called, not where):
    another crew's call brings their own leave round forward to at most 6 rounds away. Where it
    was reaches them only through the 15-tile noise. The player hears theirs.
  - Not a GOAP goal: the planner only runs in Combat, and all of this happens out of it, so the job
    is an activation-level layer over the patrol it replaces. On legacy decks (no hangar) mercs
    patrol and fight exactly as before.
  - Two merc crews are both RIVAL_MERCS, so they are allies to each other (no crew-vs-crew fights);
    they still contest hangars.
- Finish downed soldiers only when it's cheap (§4.4).
- **Built:** fight aliens and robots only when it's worth it, and route around them otherwise
  (§11.0).

---

## 12. Open Questions & Build Order

### 12.1 Open design questions

*Extraction (§7):*
1. **Countdown cancel:** can a called ship be called off? (Assumed no.)
2. **Door gun stats:** accuracy, damage, HP, and whether it obeys the light modifier. *(Placeholders in `DoorGunUnit`: see §7.4. Light: yes.)*
3. **Co-op economy:** are rosters and credits shared?
4. **Merc extraction AI:** what a merc crew's "job" is on the map, and when it decides to leave. *(Built with placeholders, §11.10: loot 2–3 containers or contest a Retrieve item 50%; leave on job done / packs full / half down / round 16–24; a rival call-in pulls that to within 6 rounds. Tune in playtest.)*
5. **Mission pool & campaign end:** is there a final contract, or an endless pool with rising
   difficulty?
6. **Cross-faction target priorities** (§11.0): how each faction's AI weighs a non-player target. *(Placeholders in `CrossFactionRules`: Cerberus threat weights 10/4/2/0.5 per tile, switch margin 3; mercs engage within 3 tiles or ~6 tiles of route, avoid within 2 at +3 per tile. Tune in playtest.)*

*Exploration mode & big decks (§4.7, §7.7):*

- **Enemy count vs mission length:** same density on a 9× deck, or dormant rooms, or scaling with
  hangars and objectives? Measure with `--auto` once exploration mode exists.
- **Pool radius:** how near the fight a unit must be to join the turn-mode pool (§4.7.2).
- ~~**Wait action:** how a squad spends steps on purpose.~~ Settled (2026-10-28): one press waits
  to the next round (§4.7.3).
- **Clock rate:** 20 steps per round is the starting value; tune against bleed-out, merc leave
  rounds and nest spawns.
- **Group moves:** individual control only for now. A follow or formation move may be wanted
  once decks are big.

*Downed & death (§4.4):*

7. **Drain rate** (default 1/5 of max HP per round) and **revive HP** (default 25%).
8. **Extracted while downed:** comes home injured, or simply recovers? *(Parked.)*
9. **Sidearm:** pistol stats. It is equipped gear, so it takes no inventory slot (§7.5).

*Carried over from v1.1:*

10. Exact per-class stat ranges (placeholders in `ClassPresets`).
11. Spitter range, falloff and minimum range.
12. Agile Hunter ambush thresholds.
13. Cover HP per tier, and the grenade/Heavy bonus-damage multiplier.
14. Medical resource: name, sources, prices.
15. Class abilities (Support heal/Initiative, Heavy cover-breaking). *(Parked; Support stays as is.)*
16. Leveling curve.

### 12.2 Proposed build order for extraction

1. **Hangar and ship:** hangar set-piece in the generator, call-in action, countdown, landing,
   3×3 square, board & extract, departure. Replaces the clear-out win check.
2. **Downed bar, revive, death, carrying, and the pistol** (gameplay code only; model and
   animations later). Mercs switch to dying outright.
3. **Slot inventory with valuables**, the Retrieve objective, and Destroy (finish nest HP).
4. **Debrief economy:** credits, hiring, the roster carrying over between missions, game over.
5. **Door gun.** **[built]**
6. **Gear loot, Hold-terminal and Recover objectives.** **[built]**
7. **Cross-faction hostility** (§11.0): open the matrix, then add per-faction target priorities. **[built]**
8. **Merc extraction AI and hangar contention.** **[built]**

**Next: exploration mode and big decks (§4.7, §7.7).** In this order, so free movement can be
played on today's deck sizes before anything grows. Steps 9 and 10 are planned together in
[`EXPLORATION_PLAN.md`](EXPLORATION_PLAN.md): the groundwork co-op needs is built into step 9.

9. **Exploration mode on current decks:** **[built; not yet human-playtested or retuned]**
   - the mode switch (enter on squad combat, leave after one quiet round, or at once when the last kill leaves nothing fighting the squad or alert nearby);
   - free movement and free actions;
   - the step clock driving every round timer and the non-combat AI;
   - per-step detection and interrupts;
   - overwatch carried into combat;
   - attack-to-start.
10. **Co-op exploration:** simultaneous free moves, host-ordered, with the shared step counter.
    **[built; the two-instance Steam checklist has not been run]**
11. **Performance for big decks:** lighting, pathfinding, wall collision, nearby-only detection, and
    the near-the-fight pool.
12. **Big decks:** 3× sizes, 4–6 hangars, same-density enemies, same-total loot. Then measure
    mission length and settle the enemy-count question.

---

*This is a living document. Keep it current rather than stacking supersession notices. When a
rule changes, rewrite the section and let git hold the old version.*
