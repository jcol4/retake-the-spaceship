# Retake the Spaceship — Game Design Document

*Draft v1.1 — a tactical, initiative-pool combat game*

---

## 1. High-Concept Pitch

A turn-based, squad-level tactics game in the spirit of *XCOM*, played in a fully 3D environment aboard decrepit, derelict spaceships (*Dead Space*-inspired tone). Small squads of sci-fi military soldiers fight stylized, low-poly battles to clear out an alien infestation. Turn order isn't fixed: every unit on the battlefield — friend and foe alike — is drawn from a single shared, weighted pool each turn, with each unit's **Initiative stat** improving its odds of acting sooner. A second core system, **dynamic light and sound-based visibility**, means every soldier's own flashlight is both their greatest tool and a beacon that can get them killed.

---

## 2. Design Pillars

- **Tactical, not twitchy.** Deliberate, timing- and positioning-focused decisions. No reflex mechanics.
- **Tension through uncertainty.** The shared initiative pool means the "safe" plan can always be disrupted — but the odds are knowable and influenceable, not pure chaos.
- **Light is a weapon and a liability.** Visibility isn't a binary line-of-sight check — it's a continuous value that soldiers actively manage, for themselves and their targets.
- **Forgiving, not punishing.** No permadeath. Squad losses cost you tactically (a mission without your best gunner) but not permanently.
- **Small squad, high specialization.** 2–4 units per mission, each meaningfully different via fixed class roles.

---

## 3. Platform & Perspective

- **Platform:** PC (native build via Godot Engine)
- **Engine:** Godot (4.x recommended for its Vulkan-based 3D renderer)
- **Perspective:** ⚠️ **SUPERSEDED** — see [docs/presentation-direction.md](docs/presentation-direction.md). The environment is still fully 3D, but it is viewed through a fixed orthographic isometric camera with four snapped yaws, and characters are 2D sprites composited into it — **prerendered from rigged 3D characters** (Fallout-style), in eight directions, not modelled in the scene and not hand-drawn. *(Was: fully 3D environment viewed via a free-moving camera defaulting to a bird's-eye angle, §10.2.)*
- **Art style:** Stylized, low-poly
- **Setting/tone:** Decrepit, derelict spaceships — dark corridors, failing power, *Dead Space*-inspired atmosphere

---

## 4. Core Combat System

### 4.0 The Grid

- **Square tile grid** underlying a fully 3D environment (reference: *XCOM*'s grid logic, presented in true 3D rather than fixed-angle 2.5D).
- **Elevation matters** — the grid supports multiple height levels/floors (high ground, ledges, stairs), affecting line of sight and accuracy (Section 6.4).
- **Movement is eight-way, and a diagonal costs the same 1 tile an orthogonal step does** (the XCOM rule). A unit may step to any of the eight surrounding tiles, so N tiles of movement reaches a *square* of side 2N+1.
  - *Restores the original rule, after an interim period of four-way movement.* Four-way existed for a presentational reason that no longer applies: characters were drawn in four directions, so a diagonal step would have faced a unit at an angle no art existed for. Characters are now drawn in **eight** (`docs/presentation-direction.md`), which is exactly the eight directions a unit can step and face, so nothing is left unreachable by the art.
  - **Corner-cutting is guarded, in the loose form:** a diagonal is blocked only when *both* tiles it passes between are walls. A unit may round the end of a bulkhead in one step, but cannot thread the zero-width gap where two bulkheads meet at a point. Occupied tiles do not count — a squadmate is not a wall, and two units should not be able to seal a corner by standing beside it.
  - **Range is measured square (Chebyshev)** — weapon range, detection, EMP throw and alert propagation all count a diagonal as 1, which now agrees with movement cost on flat open ground. The two are still not interchangeable: Chebyshev ignores both walls and floor level, so anything that must be *walked* to asks `GridManager.is_melee_adjacent` instead.
  - Move allowances are back to base 4 tiles per AP, +1 per 20 Fitness — the ×1.5 that four-way needed is undone. **These have not been playtested.**
- **Elevation traversal has no extra cost** — moving between floors (stairs/ramps) is treated like any other tile move, no additional AP or tile penalty.
- **Movement is predictive**: before committing, the player sees a highlighted set of reachable tiles for Run and Sprint, so positioning decisions are made with full information about where a soldier *can* end up — not just a raw tile-count number.
- **The movement preview also shows light level per tile.** Since light is a continuous, tactically important value (Section 5), the reachable-tile overlay visually communicates which destination tiles are lit vs. dark, letting players route through darkness deliberately.
- **Movement always completes once committed.** Spotting an enemy mid-path does *not* interrupt movement — a soldier finishes their Run/Sprint regardless of what they encounter along the way.
- **Movement range values:** Run = 4 tiles, Sprint = 8 tiles (double Run). One tile ≈ 1.5m for level-design scale reference. *(Tunable default — adjust once corridor/room dimensions are prototyped.)*
- Fitness (Section 4.6.3) modifies these base values per soldier.

### 4.1 Turn Structure — The Initiative Pool

This is the signature mechanic of the game.

- At the start of each turn, **every unit on the battlefield** — player and enemy alike — is placed into a single shared pool.
- Each unit has an **Initiative stat**, which weights the odds of it being drawn earlier from the pool — but never guarantees it.
- Once drawn, a unit acts, is removed from the pool, and the draw repeats until all units have acted; the pool then resets for the next turn.
- **Visibility:** Players see their own units' Initiative stats. **Enemy Initiative is fully hidden** — no exact value, tier, or icon is shown, preserving full uncertainty about enemy draw order.
- **Modifiability:** Abilities, items, and status effects can buff or debuff Initiative odds mid-mission.
- **Composition:** Initiative = Reflexes (60%) + class base modifier (30%) + equipment bonus (10%). *(Tunable default — adjust after playtesting.)*

### 4.2 Action Points

Every soldier has **2 Action Points (AP)** per activation, spent on the following actions:

| Action | AP Cost | Effect |
|---|---|---|
| **Run** | 1 AP | Move up to half movement range |
| **Sprint** | 2 AP | Move up to full movement range |
| **Shoot** | 1 AP | Fire weapon at an accuracy penalty (snap shot) |
| **Aimed Shot** | 2 AP | VATS-style targeted shot at a chosen body part — Head, Torso, either Arm, or either Leg (Section 4.2.1) |
| **Throw Grenade** | 1 AP | Throw a grenade at a target location (separate action from Shoot) |
| **Hunker Down** | 1 AP | Improve unit's Cover stat for incoming attacks until its next activation |
| **Overwatch** | 1 AP | Reserve action, fired at a significant accuracy penalty; unit interrupts the pool draw to fire when an **enemy** unit moves into its line of sight (does not trigger against allies) |
| **Reload** | 1 AP | Refill weapon magazine (see 4.3) |

**Overwatch & the pool:** Overwatch is the one action that breaks the normal draw order — but only in one direction. A unit on Overwatch can interrupt and act when an enemy walks into its sightline, regardless of whose "turn" the pool would otherwise draw. It does **not** trigger off allied movement. Its low AP cost is paid for by accuracy: the reserved shot carries a **flat −30% penalty** on top of a normal Shoot's math, reflecting a reactive snap-shot rather than one lined up in advance.

**Flashlight toggle** (Section 5.2) is a separate, **free action (0 AP)** — not part of the table above, and can be used freely alongside any activation.

### 4.2.1 Aimed Shot — VATS-Style Body-Part Targeting

Replaces the old flat "full accuracy" Barrage. Aimed Shot lets the shooter pick one of six zones on the target before firing, Fallout-VATS-style:

| Zone | Accuracy vs. the full-aim baseline | On landing a hit |
|---|---|---|
| Torso | +0% (the reliable, default target) | A **critical** hit also **stuns** the target for its next activation |
| Head | **−50%** (severe penalty) | **Doubled** crit chance vs. normal, and a landed crit has a further chance to upgrade to a **severe critical (3× damage)** |
| Left/Right Arm | −20% each | Damage accumulates toward that arm's own injury threshold |
| Left/Right Leg | −20% each | Damage accumulates toward that leg's own injury threshold |

**Body-part health & injury:** independently of the unit's own HP pool (which an Aimed Shot's damage also depletes as normal — an Aimed Shot can still down its target), each body part tracks the cumulative damage landed on it, against its own threshold (a fraction of the unit's max HP: Torso 50%, Arms/Legs 35% each, Head 25%). Once a part's threshold is exceeded, it becomes **injured** for the rest of the mission (or until treated by a future medical-resource action, Section 4.4) and applies a passive debuff:

- **Injured leg:** movement range (Run/Sprint tile counts) reduced by 33% per injured leg.
- **Injured arm:** −15% ranged accuracy and −25% melee accuracy per injured arm; melee damage cut 40% per injured arm (multiplicative, so both arms injured is a much harder cut than one).

Torso and Head injuries are tracked the same way for future medical-system purposes, but their combat effect (stun / crit upgrade) triggers per landed crit on that zone rather than requiring the threshold to be crossed first.

### 4.3 Ammo & Reload

- Weapons have a **fixed magazine size**.
- Once empty, the soldier must spend **Reload (1 AP)** before firing again.
- Creates a tradeoff around Aimed Shot (2 AP) burning through ammo faster than Shoot, and makes Reload timing a real decision.

### 4.4 Injury, Not Permadeath

- Units that fall in battle are **downed/injured**, not permanently killed.
- **Recovery is resource-based:** spending a medical resource (item/consumable, exact name/economy TBD) heals an injured soldier instantly or accelerates their recovery, rather than a passive timer or automatic free healing. This is also where a body-part injury from Aimed Shot (Section 4.2.1) gets cleared.
- Keeps emotional stakes without classic *XCOM*-style permadeath, while giving the meta-game (Section 7) a resource to manage.

### 4.5 Unit Classes

Fixed class roles:

| Class | Suggested Role |
|---|---|
| Assault | Front-line damage, close-range engagement |
| Sniper | Long-range precision, positioning-dependent |
| Support | Healing/buffs, Initiative manipulation |
| Heavy Weapons | High damage, slow, area-effect |

### 4.6 Soldier Stats

A SPECIAL-inspired stat system (minus Charisma, and deliberately trimmed to four stats), using **percentile values (0–99)** in the style of the original *X-COM* stat system.

| Stat | Governs |
|---|---|
| **Perception** | Ranged accuracy contribution to **Shoot, Aimed Shot, and Overwatch**; also determines a unit's maximum vision/detection range |
| **Reflexes** | Ranged accuracy contribution to **Shoot and Overwatch only** (not Aimed Shot); contributes to the Initiative stat (Section 4.1) alongside class and equipment factors |
| **Fitness** | Max HP; movement range (Run/Sprint tile counts, Section 4.0) |
| **Luck** | Crit chance/severity on successful hits; chance of a "second chance" reroll on failed rolls |

**4.6.1 Perception**

- Contributes to the shooter's accuracy roll for **Shoot, Aimed Shot, and Overwatch**.
- Defines the unit's **maximum vision/detection range** — a hard distance cutoff beyond which the LOS raycast (Section 10.6) isn't even attempted, regardless of lighting.

**4.6.2 Reflexes**

- Contributes to accuracy for **Shoot and Overwatch only** — Aimed Shot relies on Perception (and the chosen zone's own modifier) alone.
- Contributes to the unit's **Initiative** value (Section 4.1) alongside class base modifiers and equipment bonuses (60% weighting, see 4.1).

**4.6.3 Fitness**

- **+1 max HP per Fitness point.**
- **+1 movement tile per 20 Fitness points**, added to the base Run/Sprint values (Section 4.0).

**4.6.4 Luck**

Resolved in three ordered phases, Fallout-style, whenever a shot is fired:

1. **Reroll (shooter's Luck).** If the accuracy roll fails, there is a small chance the shot succeeds anyway: **Reroll chance ≈ Luck / 8 (%)**. This check only fires on an already-failed roll — it doesn't make already-successful shots "more" successful.
2. **Critical hit (shooter's Luck).** Any landed hit — whether from the original roll or the reroll above — has a chance to crit: **Crit chance ≈ Luck / 4 (%)**. **Crit severity: double damage.** A critical hit is guaranteed once rolled and skips step 3 entirely — it cannot be dodged.
3. **Dodge (target's Luck).** Any landed *non-crit* hit gives the target a chance to turn it back into a miss: **Dodge chance ≈ Luck / 8 (%)**, the same formula as the shooter's reroll. This is the symmetric, defensive half of Luck — being shot at and hit can still whiff if the target is lucky.

- *(All three rates are tunable defaults — adjust after playtesting.)*

**4.6.5 Stat Generation**

- Stats are **class-based and rolled within a range** — each class has a stat range/tendency, and individual soldiers roll within that range, giving variance between two soldiers of the same class.
- Suggested tendencies (exact numeric ranges still TBD, pending playtesting):

| Class | Tendency |
|---|---|
| Assault | High Fitness, moderate Reflexes, lower Perception |
| Sniper | High Perception, lower Fitness, moderate Reflexes |
| Support | Balanced across all four, slight Luck skew |
| Heavy Weapons | High Fitness, lower Reflexes, moderate Perception |

---

## 5. Line of Sight, Lighting & Detection

Line of sight is a core system — visibility is a **continuous, manageable resource** for every unit on the field, player and enemy alike.

### 5.1 Light as a Continuous Value

- Every tile/position has a **light value from 0–100%**, driven by the environment (see 5.3).
- Accuracy scales with target visibility: shooting at a poorly-lit target incurs a penalty; a fully-lit target grants a bonus. Applies symmetrically to player and enemy units.
- **Stacking math is additive**: all modifiers (cover, light, elevation, stats) add to/subtract from a base accuracy percentage rather than multiplying against each other (see Section 6.5 for the full formula).
- **Light modifier formula:** linear between a **−30% penalty** at 0% light and a **+10% bonus** at 100% light. A tile no fixture or flashlight reaches defaults to 0% (pitch dark), not neutral — total darkness is a real tactical liability, not a wash. *(Tunable default.)*
- **One faction is exempt.** The security robots (see the note in Section 11) neither read light nor are read by it, in either direction. That exemption is the second faction's whole reason to exist: this pillar was only ever tested from one side — darkness helps you hide — and an enemy that does not care about it is the missing case. See Section 6.5.

### 5.2 Flashlights

- Every soldier carries a **flashlight**, providing a cone of light around their forward-facing direction, improving their own vision range.
- **Toggle: free action (0 AP).** Toggling off reduces the soldier's own effective vision range but also reduces how visible they are to enemies — a genuine stealth/awareness tradeoff.
- **Cone spec:** 90° cone, 6-tile range, rotating with facing direction. *(Tunable default.)*
- **Light contribution:** 75/100 at the shooter's own tile, falling off linearly to 0 at the edge of the cone's range.

### 5.3 Environmental Light Sources

- **Static working lights** — reliable, fully-lit tiles
- **Flickering/failing lights** — light value fluctuates turn-to-turn
- **Emergency lighting** — dim, often red-tinted, partial illumination
- **Environmental fires/sparks** — from damaged systems, may double as a hazard
- **Terminals/screens** — small, localized dim light sources
- **Muzzle flashes/grenade detonations** — brief, dynamic light spikes when weapons fire
- **Total darkness zones** — no power at all, forcing reliance on flashlights

| Fixture | Range | Intensity | Notes |
|---|---|---|---|
| Overhead light | 6 tiles | 90/100 | steady, matches flashlight range |
| Monitor/terminal | 2.5 tiles | 45/100 | small pool of light, doesn't fill a room |
| Flickering light | 6 tiles | 25–90/100, rerolled | intensity rerolled at the start of every turn |

*(All tunable defaults. All fixtures are omnidirectional and occluded by wall geometry the same way weapon line-of-sight is — light doesn't pass through walls or closed doors.)*

### 5.4 Sound & Detection

- Sound is a **second, independent detection channel** alongside light: gunfire, sprinting, explosions, and similar loud actions can alert or reveal units regardless of darkness.
- **Alert radius: 5 tiles** from the source of a loud action. *(Tunable default.)*
- **Information revealed:** general direction/area of the sound, not the exact position of whoever caused it — preserving some uncertainty and atmosphere rather than pinpoint alerts.

---

## 6. Cover & Elevation

### 6.1 Cover Types

- **Heavy Cover:** −40% accuracy to a shooter targeting a unit behind it.
- **Light Cover:** −20% accuracy to a shooter targeting a unit behind it.
- *(Tunable defaults.)*
- Cover is a property of the environment/tile edge a soldier is positioned against, not a stat on the soldier.

### 6.1.1 Cover Durability (Destructible Cover)

Cover objects have their own HP pool and degrade under fire, forcing players to keep repositioning rather than holding one spot indefinitely.

- **Every shot fired at a unit in cover damages the cover object** — hit or miss. A miss isn't "wasted" from the cover's perspective; it's chipping away the shooter's own future options as much as the defender's.
- **Heavy Cover has more HP than Light Cover**, reflecting its sturdier material. *(Suggested starting values: Light Cover 20 HP, Heavy Cover 50 HP — tunable.)*
- **Cover-breaker weapons:** grenades and Heavy Weapons-class attacks deal **bonus damage specifically to cover objects**, giving that class a distinct "break the enemy's cover" identity beyond raw damage output. *(Exact bonus multiplier TBD.)*
- **At 0 HP, cover is destroyed and becomes impassable rubble** — it no longer grants any accuracy bonus, and the tile can no longer be walked through or occupied (it doesn't just vanish or turn into open, passable ground).
- This means destroyed cover can also reshape the battlefield mid-fight — a former choke point or flanking route may become blocked once its cover object is shot down, and previously-open lines of sight may open up where cover used to stand.
- *Open item: exact HP values per cover tier, and the exact bonus-damage multiplier for grenades/Heavy Weapons against cover.*

### 6.2 Flanking

- **Cover can be flanked.** If the shooter has a clear angle to the side or behind the cover object, the cover's accuracy bonus is ignored entirely.

### 6.3 Hunker Down

- **Hunker Down (1 AP)** applies an **additional −20% accuracy penalty** to shooters targeting this unit, stacking with Heavy or Light Cover rather than replacing it. *(Tunable default.)*
- **Duration:** persists until that unit's **next activation**, then clears once the unit acts again.

### 6.4 Elevation / High Ground

- **High ground grants a +15% accuracy bonus** when shooting at a target on lower elevation. *(Tunable default.)*
- **Traversal:** moving between elevation levels has no extra AP/tile cost (Section 4.0) — high ground is a positioning reward, not a costly investment to reach.

### 6.5 Accuracy Formula (Additive Stacking)

All modifiers combine additively into a single final hit-chance percentage:

```
Final Accuracy % =
    Base Stat Contribution (Perception, + Reflexes if Shoot)
  + Weapon Base Accuracy
  + Light Modifier (target's light value, Section 5.1)
  + Elevation Bonus (+15% if shooter has high ground)
  − Cover Penalty (−40% Heavy / −20% Light / 0% if flanked)
  − Hunker Down Penalty (−20% if target used Hunker Down)
  − Distance Penalty (falloff by range, see below)
```

- **Exception — the security robots (Section 11's note).** The Light Modifier term is treated as **0** for any roll where either side is a Cerberus unit, in both directions: their sensors do not read light, so a dark tile and a lit one are the same tile to them. Nothing else in this formula changes for them; Armor is a *damage* reduction applied after the roll succeeds, not an accuracy term, so it neither stacks with nor replaces Cover. See [`docs/design/factions/security-robots/design-choices/`](docs/design/factions/security-robots/design-choices/).
- Perception/Reflexes (Section 4.6) are the shooter's own base accuracy contribution, applied before situational modifiers.
- Luck (Section 4.6.4) is applied **after** this formula resolves — governing crit chance/severity on a hit, and reroll odds on a miss.

**Distance falloff curve:** flat out to 3 tiles (no penalty), a gentle −1%/tile climb out to 10 tiles, then a steep −12%/tile beyond 10 — a soft effective-range cutoff rather than a hard weapon range, since none is otherwise modeled.

| Tiles | 3 | 6 | 8 | 10 | 12 | 14 | 16 | 18 |
|---|---|---|---|---|---|---|---|---|
| Penalty | 0% | −3% | −5% | −7% | −31% | −55% | −79% | −99%+ (floored by the overall 1-99 clamp) |

- *Open item: weapon base accuracy values per weapon type.*

---

## 7. Mission & Meta Structure

- **Structure:** Level-based / stage progression. **Campaign structure: player picks the next mission from a pool** (branching, not a fixed linear sequence).
- **Mission length:** Medium, roughly 20–40 minutes per mission.
- **Between missions:** Character progression, loadout customization, and spending medical resources (Section 4.4) to recover injured soldiers — no base-building/resource-management layer beyond this.

### 7.1 Win/Loss Conditions

- **Mission failure: squad wipe** — if all deployed soldiers are downed, the mission is failed. (Objective-specific fail conditions, e.g. a timed escort or destructible objective, may be layered in per mission type — TBD.)
- **Mission success:** clear-out missions are won by eliminating the alien presence (including destroying spawn nests, Section 11.7) in the target area.
- *Open item: exact campaign-level win condition (is there an end state / final mission, or an ongoing mission pool?).*

---

## 8. Setting & Tone

- **Theme:** Sci-fi / military, aboard decrepit derelict spaceships (*Dead Space*-inspired)
- **Narrative:** No narrative focus for now — this is a pure gameplay loop. Story/lore may be layered in later, but is not a current design priority.

---

## 9. Production Scope

- **Team size:** Small (2–5 people)
- **Implications:** The dual signature systems — the initiative pool and the continuous light/sound visibility model — are the design's main investment. Both are relatively cheap to implement compared to procedural level generation or a full base-management meta-layer, which fits a small team well.

---

## 10. Technical Implementation Spec

*This section is written for direct implementation reference. Numeric constants marked TBD/tunable should be exposed as easily-adjustable values (e.g., an exported Godot resource/config), not hardcoded.*

### 10.1 Engine & Target

- **Engine:** Godot 4.x
- **Platform:** PC native build (not browser-targeted)
- **Rendering:** Fully 3D scene — the grid is a logical/gameplay layer over real 3D geometry.

### 10.2 Camera System

> ⚠️ **SUPERSEDED** by [docs/presentation-direction.md](docs/presentation-direction.md).
> The camera is orthographic at a fixed 35.264° pitch with four snapped yaws, and has no
> zoom at all. Left standing rather than rewritten: the free-orbit spec below is what the
> game was built against, and the reasoning is worth being able to read.

- **Type:** Free-moving camera — pan and rotate (orbit) around a focus point, with zoom.
- **Default state:** Bird's-eye angle on load/scene start.
- **Pitch clamp: 35°–75° from horizontal** — cannot reach a fully level or fully top-down angle. *(Tunable default.)*
- **Suggested implementation:** A camera rig (`Node3D` pivot with a `Camera3D` or `SpringArm3D` child) orbiting a focus point; clamp pitch in code each input update.

### 10.3 Grid & Coordinate System

- **One global grid** spans the entire ship — a single continuous coordinate space.
- **Coordinate suggestion:** `Vector3i(x, floor, z)`.
- **Tile data structure** (suggested fields per tile):
  - `passable: bool`
  - `cover_type: enum { NONE, LIGHT, HEAVY }`
  - `cover_hp: int` (current HP of the cover object on this tile, if any; Section 6.1.1)
  - `occupant: UnitReference | null`
  - `light_value: float` (0.0–100.0)
  - `door_ref: DoorReference | null`
- **No stacking:** validate destination tile's `occupant` is `null` before resolving movement; the reachable-tile preview excludes impassable and occupied tiles.

### 10.4 Procedural Generation

- **Hybrid approach:** hand-authored "set piece" rooms (fixed layout/cover) combined with procedurally generated connective rooms/corridors.
- **Suggested architecture:** graph-based level generator — set-piece rooms as fixed nodes with defined entry/exit points, procedurally generated connective rooms/corridors as edges between them, doors placed at boundaries as needed.
- **Scale defaults:** 3–6 set-piece rooms per mission; connective rooms sized roughly 5×5 to 10×10 tiles; ~15% of connective-room tiles populated as cover/obstacles. *(Tunable defaults.)*
- **Validation pass:** after procedural obstacle placement, run a connectivity check (flood-fill/pathfinding) to guarantee traversability.

### 10.5 Doors

- Discrete, interactive objects tied to a specific tile boundary.
- **States:** Open / Closed. **Cost: free action (0 AP)** to toggle.
- Closed doors block both LOS raycasts (10.6) and sound propagation (5.4); open doors block neither.

### 10.6 Line of Sight & Rendering

> ⚠️ **The rendering rule below is SUPERSEDED** by
> [docs/presentation-direction.md](docs/presentation-direction.md) §4: unit sprites are
> gated by **room**, not by a per-unit LOS raycast. A room is a piece of space the player
> can reason about, where a per-unit ray gives a flickering set with no shape — and the
> room rule also drives fast-forwarding unseen activations, which the raycast version had
> nothing to say about.
>
> The **LOS calculation** itself (raycast, shared team vision, recompute on state change)
> is unaffected and still current; only the render gating changed.

- **Calculation method:** true raycast/line-trace per potential target.
- **Sampling:** **multiple sample points per unit** (not just center-mass) for more accurate partial-cover detection, at the cost of more raycasts per check.
- **Team vision: shared.** Any player unit spotting an enemy reveals it to the whole squad — a unit is visible if seen by ANY player unit, not just the currently selected one.
- **Rendering rule:** Enemy unit models are only rendered when at least one player-controlled unit has valid, unobstructed LOS to that enemy's tile — independent of what the free camera itself can geometrically see.
- **No environmental fog-of-war memory:** the ship's static geometry is always rendered; only enemy unit visibility is gated by the LOS check.
- **Recomputation:** re-evaluate on relevant state changes (unit movement, door open/close, unit death) rather than every frame.

### 10.7 Unit Occupancy Rules

- Exactly one unit may occupy a given tile at any time; movement resolution and the reachable-tile preview both check and exclude occupied tiles.

### 10.8 Lighting System

- **`LightSource` node** — a static fixture (overhead light, monitor, flickering light). Exported `light_range`, `intensity`, `light_color`, and optional `flickers`/`flicker_min`/`flicker_max`. Carries its own shadow-casting `SpotLight3D`, aimed straight down, for a harsh beam-of-light look; this is a visual-only cone, decoupled from the radial/Chebyshev falloff `LightingManager` uses for gameplay `light_value` below. Registers into the grid explicitly via `register_with_grid()` (same pattern as `CoverObject`) rather than from `_ready()`, so placement code controls exact ordering.
- **Muzzle flashes** emit a transient, unshadowed, room-filling `OmniLight3D` (`VfxManager.muzzle_flash()`) timed to the shot's muzzle animation frame — a brief white flood rather than a lit pool, decaying to nothing within a fraction of a second.
- **`LightingManager` autoload** — the only writer of `GridTileData.light_value`. Split into two layers to keep recomputation cheap:
  - **Base layer** — static fixtures only. Computed once at map load and again whenever a flickering fixture rerolls (turn start).
  - **Dynamic layer** — flashlights only. Recomputed whenever a flashlight-carrying unit moves a tile, toggles its light, or a mission starts — never every frame, matching the LOS recomputation policy (10.6).
- **Occlusion:** both layers reuse the same wall raycast as weapon line-of-sight (`GridManager.has_clear_line`, collision layer 1) — light doesn't pass through walls or closed doors, consistent with 5.1.
- **Falloff:** linear, full intensity at the source's own tile to zero at `light_range` tiles, using the same Chebyshev distance metric as movement and accuracy range.
- **Flashlight toggle:** a free action (0 AP, Sec 4.2) on `Unit`, gated to the unit's own activation. `EnemyUnit` opts out (`has_flashlight = false`) — aliens rely on their own senses, not a rig-mounted light, reinforcing the Agile Hunter's darkness-dependent ambush (11.5).
- **Movement preview:** the run/sprint highlight tiles (Sec 4.0) are darkened proportionally to `light_value`, so routing through darkness is a visible choice at the point of deciding a move, not just a stat a player has to check.

---

## 11. AI & Enemy Design

*Theme: an alien infestation aboard the derelict ship. Current mission archetype: clear-out.*

> ⚠️ **This section describes ONE of the game's two enemy factions.** A second — **Cerberus
> Applied Sciences**, the ship's own security robots — was designed after this document was
> written and now has an alpha implementation in code. It is deliberately the mechanical
> inverse of the aliens on every axis below: sensor-driven rather than light-driven,
> zone-alerted rather than locally alerted, armored, and destroyed outright rather than
> injured. It reuses the state machine in 11.1 and the formula in 6.5 rather than replacing
> either, with one flat exception noted in 6.5.
>
> It is **not folded into this document**; its source of truth is
> [`docs/design/factions/security-robots/`](docs/design/factions/security-robots/). The design
> intent in one line: *aliens are a lighting puzzle, security robots are a positioning-and-EMP
> puzzle*, and a mission with both makes the player hold two mental models at once.

### 11.1 AI Decision Model

**Layered state machine** (Unaware → Alert/Investigating → Combat → Search) with a **lightweight utility-scoring pass inside Combat** to choose the best action each activation.

| State | Behavior |
|---|---|
| **Unaware** | Patrols/rests near its nest/spawn area. No awareness of any player unit. |
| **Alert / Investigating** | Detected a stimulus but has no confirmed target; moves toward the last known stimulus location. |
| **Combat** | Has a confirmed target; participates in the initiative pool with utility-scored target/action selection. |
| **Search** | Lost track of all player targets; searches around the last known position before reverting to Unaware. |

**Utility scoring weights (defaults):** **flanking opportunity** and **low-HP retreat** are the two highest-weighted factors in action selection, above raw "can I take a shot now." *(Tunable — refine after playtesting.)*

### 11.2 Detection & Alert Propagation

- Aliens use the **same light- and sound-based detection rules as the player** (Section 5) — no special alien senses.
- **Alert propagation is local**, scoped to the same room/nest cluster (via the room-graph structure from Section 10.4) — not ship-wide. Isolating rooms via doors is a valid, intentional player strategy.

### 11.3 Enemy Roster (v1)

| Type | Speed | Toughness | Grouping | Core Role |
|---|---|---|---|---|
| **Fodder** | Slow | Tanky | Swarms (groups) | Attrition — drains player AP/ammo, not raw damage |
| **Agile Hunter** | Fast | Fragile-moderate | Solo or pairs | Ambush striker — punishes bad positioning/lighting |
| **Spitter** | Slow-moderate | Fragile | Solo, or supports Fodder swarms | Ranged pressure from a distance |

### 11.4 Fodder — Swarm

- Slow, tanky, individually weak damage output.
- Threat is **attrition** — forces the player to spend AP/ammo/turns on numbers rather than posing serious per-hit risk.
- Combat bias: direct approach toward the nearest player unit, low priority on flanking/repositioning.
- **No ranged weapon at all.** Its only action is a **melee attack at contact range**, so the whole loop is: crawl toward the target, claw it once adjacent.
- **Movement: 3 tiles per 1 AP** — a fixed rate below what its Fitness would otherwise allow (contrast the general 4 + Fitness/20 of Sec 4.0). Deliberately outrunnable: a squad that keeps moving should be able to disengage, which is what makes a swarm a resource cost rather than a chase.
- **Melee costs 1 AP**, so a 2 AP activation is *crawl 3 and swing*, *crawl 6*, or — already in contact — *two swings*.
- **Contact range** is the same adjacency movement uses (8-way, subject to the corner-cutting guard, stair links count), **not** a raw Chebyshev distance of 1: the latter ignores floor level and would let a swarm on the deck claw a unit standing on the platform above it.
- **Melee accuracy** = attacker Perception + melee base accuracy, ± the high-ground bonus and the target's Hunker penalty, then both sides' Luck (Sec 4.6.4) exactly as for a shot. Defaults: **melee base accuracy 45, damage 5.**
- **Cover, distance falloff, and the light modifier deliberately do not apply to melee.** All three exist to model *distance*: cover can't shield a body something is already on top of, falloff is zero at one tile, and letting darkness reduce a claw's accuracy would make standing in the dark a *defence* against the swarm — backwards for a game built on darkness being the danger. Melee also does not damage cover, since the swing never travels through it.

### 11.5 Agile Hunter — Ambusher

- Fast, lower toughness than Fodder — a real threat if it connects, killable once caught out of hiding.
- **Ambush trigger: combination condition** — requires both sufficient darkness (light value below a threshold, TBD) **and** player proximity within a close range (TBD) before committing to an ambush attack.
- Solo or pairs, never swarms.
- Combat bias: heavily favors reaching/holding ambush setups over direct engagement.

### 11.6 Spitter — Ranged

- Slow-moderate, fragile — dies quickly if focused.
- **Attack type: hitscan** — instant, guaranteed to travel in a straight line if unobstructed (not a projectile with travel time/arc).
- Favors maximum distance/LOS opportunities; can trail behind a Fodder swarm as a soft screen.
- Combat bias: maintain distance, retreat rather than engage at close range.
- *Open item: exact range, damage falloff, and minimum effective range.*

### 11.7 Spawn Nests

- Destructible mission objective (HP-bearing object).
- **HP: 50.** **Spawn rate: 1 unit every 3 turns** if undestroyed.
- **Spawn table:** 70% Fodder / 20% Spitter / 10% Agile Hunter.
- *(All tunable defaults — adjust after playtesting; escalation-over-time not currently planned, spawn rate is constant until destroyed.)*

### 11.8 Implementation Scaffold (Godot)

- **`AlienUnit` base class** (extends the shared `Unit` class) — holds a state machine component with the four states from 11.1.
- **Per-type behavior via exported parameters** (`preferred_engagement_range`, `flanking_bias_weight`, `retreat_health_threshold`, `prefers_darkness: bool`, `ambush_light_threshold`, `ambush_proximity_range`) rather than three separate codebases.
- **`Nest` node/scene** — HP, spawn timer (3-turn interval), spawn table (70/20/10 weighted), spawns into a valid unoccupied/passable tile (Section 10.7); removed from spawn population at 0 HP.
- **Alert propagation** via the room-graph structure from Section 10.4 — an alerted unit signals its current room node, propagation reaches only `AlienUnit`s registered to that node or its associated nest cluster.
- Each `AlienUnit` participates in the shared initiative pool (Section 4.1) like any other unit — its state machine determines what it *does* when drawn, not whether it's drawn.

**Current state of the scaffold.** `EnemyUnit` is the shared alien base described above (it predates the name `AlienUnit` and holds the iteration-1 ranged loop directly); `SwarmUnit extends EnemyUnit` is the first real roster type, overriding `take_turn` for the melee loop and `_move_budget` for the crawl rate. The state machine of 11.1 does **not** exist yet. Its seam is `EnemyUnit.acquire_target()` — the single point every AI loop gets a target from, currently omniscient (nearest living player, no sight or awareness check). Detection, alert propagation and the four states replace the body of that one method; returning `null` already means "no target, end the activation", which is what an Unaware alien idling at its nest should do. `Nest` (11.7) does not exist either — per-type stat rolls live in `main.gd` for now and want moving into its spawn table.

---

## 12. Remaining Open Questions

Most prior open items now have concrete (tunable) defaults set throughout this document. What's genuinely still undecided:

1. Weapon base accuracy values per weapon type.
2. Exact per-class stat numeric ranges (Section 4.6.5) — tendencies are set, ranges are not.
3. Campaign-level win condition / end state, beyond the mission-pool structure (Section 7).
4. Objective-specific mission fail conditions beyond squad wipe (timers, escort failure, etc.) (Section 7.1).
5. Spitter exact range, damage falloff, and minimum effective range (Section 11.6).
6. Exact ambush thresholds (light value cutoff, proximity range) for the Agile Hunter (Section 11.5).
7. Medical resource economy — what it's called, how it's earned/spent (Section 4.4).
8. Exact cover HP values per tier and bonus-damage multiplier for grenades/Heavy Weapons against cover (Section 6.1.1).

---

*This is a living document — sections will be expanded and revised as design decisions are made.*
