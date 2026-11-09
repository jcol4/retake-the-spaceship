# Themed Rooms Implementation Plan

Written 2026-11-08 against `3d-models` @ `5af39cbe`. This file covers the design decisions and how
to build them. Every gameplay choice here was made by the designer in a question-by-question review;
the decisions table at the end is the record. Once a phase lands, fold its decisions into the GDD
(§7.2 and §7.7 change; see "GDD changes").

**Goal:** generated decks that read like a real ship. Rooms have a purpose (bunk rooms, mess hall,
medbay, engine room, bridge…), related rooms sit together (berthing next to its showers, galley next
to the mess), and the deck as a whole follows a warship's layout: command forward, engineering aft,
two main passageways down the length.

**References** (for room kinds and layout rules, not for names or look):
- The USG Ishimura's decks (Flight, Medical, Engineering, Bridge, Hydroponics, Crew, Mining) gave
  the room list and the idea of one purpose per deck.
- Warship general arrangement: zones along the hull, a main fore-aft passageway, berthing in
  clusters with their own heads and showers, galley beside the mess, sick bay central, sensitive
  spaces buried inside.

---

## Where things stand today

- [`MapGenerator`](scripts/map_generator.gd) places hangars first (farthest-point sampling), then
  rejection-samples rooms of random size anywhere they fit, then joins them with a Euclidean MST of
  corridors plus 20% extra links for loops.
- Every room is treated the same: random cover blocks, a 50% chance of loot, a flat chance of an
  enemy spawn. Nothing records what a room is for.
- `room_gap = 2` keeps every pair of rooms at least two tiles apart, so no two rooms share a wall.
- Rooms are not stored in map files; [`MapAscii`](scripts/map_ascii.gd) re-derives them with
  `MapData.compute_rooms`.

---

## Ground rules (apply to every phase)

- **Everything in [`EXTRACTION_PLAN.md`](EXTRACTION_PLAN.md)'s ground rules still holds:**
  host-authoritative state, headless `tools/test_*.gd` tests, named `const`s beside the code that
  uses them.
- **Deterministic in the seed.** Co-op still sends only the seed. Every new draw goes through the
  generator's `_rng`.
- **Seeds break once.** Typed placement changes the order of draws, so every existing seed gives a
  new deck. `Config.themed_rooms` (default on) keeps the old generator reachable for tests and
  comparison.
- **New enums are APPEND-ONLY**, the same as the existing ones, because they are saved or sent as
  ints.
- **Gameplay first, art second.** Every furniture kind ships as a tinted placeholder box; models
  replace boxes one kind at a time with no gameplay change.

---

## Phases

```
A Room data ─> B Zones & spines ─> C Typed placement & suites ─> D Dressing & lighting
                                                                   │
                                     E Power, doors, terminals <───┤
                                     F Spawns, loot, objectives <──┘
                                                                   └─> G Tuning & art
```

E and F are independent of each other once D is in. Each phase ends playable and tested.

### Phase A: Room data (no change to generated decks)

- **A.1 `scripts/room_types.gd` (`RoomTypes`)**, written like the other preset files. Each type has:
  - `id`, display name, `zone`
  - size range per axis (see "Room sizes")
  - count limit (see "Room caps")
  - door rule: dead end allowed, or 2+ doors required
  - soft neighbour weights (see "Neighbour rules")
  - furniture layout, light colour, loot table key, faction spawn weights
- **A.2 Zones enum:** HABITATION, MEDICAL, ENGINEERING, COMMAND, CARGO, UTILITY.
- **A.3 `MapData.room_types: Array[StringName]`**, stored alongside `rooms`. Corridors are
  `&"corridor"`, hangars `&"hangar"`, rooms in hand-authored maps without a section `&"generic"`.
- **A.4 `[rooms]` section in `MapAscii`**: one line per room, `x,z type condition`, keyed by any
  cell in the room so it survives `compute_rooms` re-deriving the indices.
- **A.5 Test:** round-trip a deck with typed rooms through `MapAscii` (extend
  `tools/test_map_roundtrip.gd`).

### Phase B: Zones and spines

- **B.1 Deck profile** rolled per contract: a primary zone (about 60% of rooms) and a secondary
  zone (see "Deck profiles").
- **B.2 Deck sizes move up one step** in `CampaignEconomy.DECK_DIMENSIONS`:
  Small 72x48 (Mixed profile only), Medium 84x56, Large 96x64. The generator default follows
  Medium. Hangar count stays 3–4.
- **B.3 Bow to stern:** the deck's X axis is bow (low X) to stern (high X). The interior between
  the hangar flanks is split into zone bands in the fixed order COMMAND → HABITATION → MEDICAL →
  ENGINEERING, keeping only the deck's primary and secondary zones plus a UTILITY share. Jitter:
  neighbouring bands may swap, and band widths vary ±20%.
- **B.4 Hangars on the flanks:** hangar placement keeps farthest-point sampling but candidates are
  restricted to strips along the port (low Z) and starboard (high Z) hull. Ramps face inward.
- **B.5 Two parallel spines:** port and starboard passageways run the length of the deck between
  the hangar strips and the zone bands, 2 tiles wide (same as today's corridors), with small jogs.
  Cross-corridors join them at each zone boundary and at the ends. Spines are corridor entries in
  `rooms`, so occlusion, zones and alert propagation treat them as before.
- **B.6 Test:** 500 seeds per profile and size. Spines connect bow to stern, every hangar touches a
  spine, the existing hangar reachability check passes. Print the reroll rate per deck size.

### Phase C: Typed placement and suites

Rooms are placed in priority order, inside their zone band:

- **C.1 Anchor rooms:** mess, engine room, bridge, medbay, security station. Each is placed near the
  middle of its band, touching a spine.
- **C.2 Suites:** a cluster of rooms carved as one rectangle, then split into sub-rooms that share
  walls and connect through internal doors. The gap rule applies between suites, not inside them.
  - Berthing: 2–3 bunk rooms + bathroom block + locker/laundry room
  - Galley + mess + cold store
  - Medbay + surgery/ICU (+ morgue/cryo)
  - Lab + clean room + specimen hold
  - Bridge + comms/navigation (+ captain's quarters)

  Needs a suite-door variant of `_punch_entrance_at`. `compute_rooms` and the bulkhead logic must
  still split a suite into its sub-rooms on a round trip; verify before building on it.
- **C.3 Satellite rooms:** for each remaining required or optional type, try about 40 candidate
  spots in its band and keep the best score: neighbour weights to rooms already placed, plus band
  fit, minus distance to a spine. Same best-of-N approach as the hangars.
- **C.4 Filler:** the existing rejection sampler runs last over the leftover space, drawing only
  UTILITY types (storage closets, elevator/stair lobbies).
- **C.5 Corridors:** the MST router runs on top, with the spines as rooms, so side passages and
  loops still form. It must respect door rules: dead-end types get one link at most; 2+ door types
  get at least two.
- **C.6 Hard ban, enforced as a rejection:** fuel storage connects only to Engineering rooms or a
  spine.
- **C.7 Missing required room → reroll** from a derived seed, the same as an unreachable hangar.
- **C.8 Test (`tools/test_room_themes.gd`):** across 500 seeds per profile and size:
  - every required room is present, and the caps hold
  - every bunk room reaches a bathroom without crossing another zone
  - the fuel storage ban holds
  - door rules hold (dead ends only where allowed)
  - hangar reachability still passes
  - same seed gives the same deck
  - report how often a bunk room opens onto machinery or cargo (target: about 1 deck in 20)
- **C.9 `tools/preview_map.gd`** prints one letter per room type in the ASCII view.

### Phase D: Dressing and lighting

- **D.1 Obstacles get a `kind`:** `data.obstacles` entries become `[footprint, tier, kind]`.
  `MapAscii` stores the kind; old files default to `&"crate"`.
- **D.2 Arranged furniture by room type:**
  - mess: tables in rows (light, 1x3)
  - bunk room: bunks along the walls (light, 1x2)
  - lab: benches as islands (light)
  - locker room: rows of tall lockers (heavy, block sight)
  - server room: racks in rows (heavy, block sight)
  - engine room, life support: machinery clusters (heavy, 2x2 and 3x2)
  - bridge, comms: console rows (light)

  The existing tile of clearance to walls and between pieces stays, so paths stay open without a
  flood check. A type with no layout falls back to random placement.
- **D.3 Furniture follows cover tier:** light pieces are low and destructible; heavy pieces are
  tall, block sight and are hard to destroy. Same rules as today's cover blocks.
- **D.4 Room conditions**, rolled per room: intact 20%, ransacked 50%, barricaded 15%, overrun 15%.
  - Ransacked: furniture knocked out of its arrangement, some pieces missing.
  - Barricaded: extra cover at each door and a loot bonus. Nothing else.
  - Overrun: worm mass on the floor (existing `worm_counts`), fewer and smaller cover pieces, many
    already damaged, and always dark.
- **D.5 Lighting by room type:** floor tint and light colour per type (clinical white in medical,
  sodium orange in engineering, dim blue in quarters).
- **D.6 Map builder:** picks a mesh per obstacle `kind`, falling back to a tinted box.
- **D.7 Hazards:** fuel tanks, gas canisters and electrical panels placed by room type (fuel
  storage, galley, engineering). A hazard is a low-HP cover block that explodes when destroyed:
  radius 2, about a frag grenade's damage. It can set off hazards in range, and enemies can trigger
  it.
- **D.8 Noise by zone:** movement noise multiplier: Engineering and Cargo 1.5x, Habitation and
  Command 0.75x, Medical 1.0x. Feeds `SecurityNetwork.report_noise` and the alien `hear_noise`
  paths.
- **D.9 Room names in the UI:** a room's name appears in the hover tooltip once the room has been
  seen (`_room_under_cursor`).

### Phase E: Power, doors and terminals

- **E.1 Power by zone:** each zone has a 1 in 3 chance of rolling "no power". Dark zones use red
  emergency lighting and sight range drops to about 60%. On a deck without an Engineering zone, a
  dark zone stays dark for the whole mission.
- **E.2 Power switch:** the engineering control room holds a single-purpose switch (not a
  terminal). Each use restores one dark zone, including its doors. Overrun rooms stay dark.
- **E.3 Locked rooms:** armory, brig, server room, bridge and captain's quarters. Three ways in:
  - Keycard: opens instantly. Placed as loot in a related room (armory/brig card in the security
    station; server/bridge card in the captain's quarters or comms), always reachable without the
    door it opens.
  - Hack: a full turn of AP at a terminal.
  - Breach: a breaching charge or 2 turns of AP, and it alerts the whole zone.
- **E.4 Terminals:** only on the bridge and the security station. Each has the full menu: reveal
  the deck's room map, turn security robots on or off (ties into
  [`security_network.gd`](scripts/security_network.gd)), unlock doors.

### Phase F: Spawns, loot, services and objectives

- **F.1 Faction home rooms:** about 60% of a faction's spawns land in its home rooms; the rest go
  anywhere eligible.
  - Aliens: labs, morgue, cryo, specimen hold
  - Security robots: security station, bridge, armory, server room
  - Rival mercs: cargo, armory
- **F.2 Themed loot tables** in `ItemPresets.roll_container(table)`. Three in four rolls come from
  the room's table, one in four from the generic table.
  - Quarters: credits, personal valuables, keycards (captain's quarters)
  - Medical: medkits, stims
  - Research: research data, specimens (high value, heavy)
  - Engineering: scrap, grenades, armour patches
  - Command/Security: ammo, weapons, attachments
  - Mess/galley: low-value supplies
- **F.3 Station services**, one use per room:
  - Medbay: fully heals one soldier or revives a downed one in the room; costs that soldier's turn.
  - Armory: refills one soldier's ammo and adds a grenade.
  - Fabrication shop: one soldier swaps one attachment from the squad's stash. Crafting from loot
    is deferred to its own design pass.
- **F.4 Objectives pick their room:** reactor in the engine room, data in a server room or the
  bridge, specimen in a lab, VIP in quarters or the brig. The objective also shifts the deck
  profile odds toward its zone.
- **F.5 Insertion:** a random hangar from the half farthest (by path) from the objective room.
- **F.6 Contract screen** shows the profile before accepting, e.g. "Crew Deck (Medical wing)".

### Phase G: Tuning and art

- Playtest the reroll rate, mission length per deck size, and room-scale feel.
- Model furniture one kind at a time on `3d-models`: bunk, mess table, lab bench, server rack,
  engine block first.

---

## Reference tables

### Deck profiles

Primary odds before the objective shifts them: Habitation 35%, Medical 25%, Engineering 25%,
Command 15%. Small decks always roll Mixed (one band of each zone, no suites larger than 2 rooms).

| Primary | Secondary (pick one) |
|---|---|
| Habitation | Medical, Command |
| Medical (+ Research) | Habitation, Command |
| Engineering | Command, Cargo |
| Command (+ Security) | Habitation, Engineering |

### Rooms per zone

| Zone | Always present | Can roll |
|---|---|---|
| Habitation | Berthing suites (bunk rooms + bathroom block), mess + galley | Lounge, gym, officer cabins, captain's quarters, laundry, locker room |
| Medical + Research | Medbay, lab | Surgery, ICU, morgue, cryo, clean room, specimen hold, imaging, data storage |
| Engineering | Engine/reactor room, engineering control | Fuel storage, life support, fabrication shop, maintenance crawlways |
| Command + Security | Bridge, security station | Armory, brig, comms, navigation, server room |
| Utility (filler) | — | Storage closets, elevator/stair lobbies |

Berthing suites: 2 on Medium, 3 on Large, 1 when Habitation is the secondary zone.

### Room sizes (tiles, "tactically roomy" scale)

| Room | Size range |
|---|---|
| Closet | 3–5 per side |
| Bathroom block | 4x6 to 5x8 |
| Bunk room | 6x8 to 8x10 |
| Cabin | 4x5 to 5x6 |
| Mess | 12x14 to 14x18 |
| Lab | 8x10 to 10x12 |
| Medbay | 8x10 to 10x14 |
| Engine room | 16x18 to 20x22 |
| Bridge | 10x12 to 12x16 |

Rooms not listed are sized in Phase A relative to these and reviewed before Phase C.

### Room caps

- Exactly 1: bridge, engine room, engineering control, security station, armory, captain's quarters.
- At most 2: lab, medbay, mess.
- Unlimited (driven by suites and space): bunk rooms, cabins, bathrooms, closets.

### Neighbour rules

- **One hard ban:** fuel storage connects only to Engineering rooms or a spine.
- **Strong preference:** bunk rooms do not open onto machinery or cargo (target: about 1 deck in 20
  breaks it, only when space forces it).
- **Soft preferences:** strong within a zone (galley next to mess, morgue near surgery, bunk rooms
  near the bathroom block). Across zones only a few pairings matter: medbay near the mess and a
  hangar, armory near the security station. Everything else is neutral.

### Door rules

- Usually one door: closets, armory, brig, server room, quarters.
- Always 2+ doors: mess, labs, engineering rooms, medbay.

---

## GDD changes

- **§7.2:** hangars sit along the port and starboard flanks; the insertion hangar is chosen by
  distance from the objective, not at random.
- **§7.7:** deck sizes move up one step (Small 72x48, Medium 84x56, Large 96x64). Payouts and
  mission timers will need retuning.
- **New section:** deck profiles, zones, room types, power, locked doors, services.

## Risks

- **Space:** an engine room is up to 440 tiles. On Medium (84x56) it shares the deck with 3–4
  hangars of 210–280 tiles each and two spines. Measure the reroll rate in B.6 and C.8 before
  locking room sizes or deck sizes.
- **Suites and `compute_rooms`:** rooms sharing a wall must still be split correctly when a map
  file is re-derived. Prove this in C.2 before building dressing on top of it.
- **Scope:** power, locked doors and terminals form one connected system (Phase E). Keep it out of
  the layout phases so layouts can be judged first.

---

## Decisions

| # | Topic | Decision |
|---|---|---|
| 1 | Deck purpose | Primary zone (about 60% of rooms) + one secondary zone |
| 2 | Secondary zone | Realistic pairings (see Deck profiles) |
| 3 | Primary odds | Habitation 35%, Medical 25%, Engineering 25%, Command 15%; objective shifts odds |
| 4 | Zone order | Fixed bow to stern with jitter |
| 5 | Corridors | Two parallel spines (port and starboard) with cross-corridors |
| 6 | Hangars | 3–4 per deck, on the port and starboard flanks |
| 7 | Multi-deck | One deck per mission for now |
| 8 | Deck size | One step up per contract size: 72x48 (Mixed only), 84x56, 96x64 |
| 9 | Room scale | Tactically roomy, about 1.5x realistic |
| 10 | Old seeds | Break once, keep a `themed_rooms` toggle |
| 11 | Suites | Rooms inside a suite share walls with internal doors |
| 12 | Zones in v1 | Habitation, Medical + Research, Engineering, Command + Security |
| 13 | Hard bans | Fuel storage only |
| 14 | Bunk rooms vs machinery/cargo | Strong soft preference (about 1 deck in 20) |
| 15 | Preference weights | Strong within zone, light across |
| 16 | Missing required room | Reroll the deck |
| 17 | Dead ends | By room type |
| 18 | Filler | Storage closets, elevator/stair lobbies |
| 19 | Room caps | Unique + limited (see Room caps) |
| 20 | Cover | Arranged furniture by room type |
| 21 | Furniture | Follows cover tier |
| 22 | Room condition | Intact 20%, ransacked 50%, barricaded 15%, overrun 15% |
| 23 | Barricaded | Door cover + loot bonus only |
| 24 | Overrun | Worm mass, broken furniture, always dark |
| 25 | Lighting | Mood per room type + power state |
| 26 | Power | Per zone, 1 in 3 dark; restored at the engineering control switch |
| 27 | No Engineering zone | Dark zones stay dark |
| 28 | Darkness | Red emergency lighting, sight about 60% |
| 29 | Hazards | Explode when destroyed, radius 2, grenade-level, chain, enemy-triggerable |
| 30 | Terminals | Bridge and security station only, full menu |
| 31 | Locked rooms | Armory, brig, server room, bridge, captain's quarters |
| 32 | Unlocking | Keycard free, hack a full turn of AP, breach loud |
| 33 | Keycards | In a related room, always reachable |
| 34 | Services | One use per room |
| 35 | Medbay | Full heal or revive one soldier, costs their turn |
| 36 | Armory | Refill one soldier's ammo + one grenade |
| 37 | Fabrication | One attachment swap; crafting deferred |
| 38 | Spawns | Faction home rooms, about 60% pull |
| 39 | Loot | Themed tables (see F.2), 25% generic |
| 40 | Objectives | Objective picks its room and shifts the profile |
| 41 | Insertion | Random among the farthest half from the objective |
| 42 | Room names | Revealed by exploring; terminals reveal the whole deck |
| 43 | Contract screen | Shows primary + secondary |
| 44 | Noise | Engineering/Cargo 1.5x, Habitation/Command 0.75x, Medical 1.0x |
| 45 | Art | Tinted boxes first, models one kind at a time |
