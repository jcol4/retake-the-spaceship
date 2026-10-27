# Extraction loop — gameplay decisions

This document records every gameplay decision made while building the extraction loop
(EXTRACTION_PLAN.md, Phases 0–8). For each decision it gives the choice, the reason, and the
code it lives in.

It sorts decisions into three kinds:

- **Locked.** You decided these in the design grilling and the GDD v2.0 revision. They are
  listed briefly in §1 so the rest of the document has context, and are not argued again.
- **Interpretation.** The GDD or plan gave a rule, and the build had to choose how to read it.
- **Placeholder.** A number or behaviour picked so the system works end to end, meant to be
  tuned in playtest. These are tagged **[tune]**.

§13 lists the calls that deserve your review first.

The GDD (`game-design-document.md`) is still the rules reference, and its [built]/[partial]
markers were updated as each phase landed. This document is the *why*.

---

## 1. Locked design (context only)

- **Loop.** Cold drop at a hangar before round 1. Traverse the deck. Optionally do an
  objective and/or loot. Call a ship at a hangar, wait for it, then board from a 3x3 square in
  front of the ramp. Only friendlies in the square leave. Everyone else is lost permanently,
  with their gear.
- **The ship.**
  - **The call:** costs 1 AP and can be made from anywhere in the bay. It is always loud: a
    15-tile noise, plus a map-wide radio notice to every crew. The notice says *that* a ship
    was called, never *where*.
  - **Timings:** arrives in 3 rounds, waits 5, and a re-call has a 5-round cooldown. The first
    call claims the hangar.
  - **Board and Extract (revision 2):** a soldier in the square of your landed ship can
    **board**, leaving the board safe along with whatever they carry. **Extract** ends the
    mission at once. It is available on any of your soldiers' activations, from anywhere, once
    at least one of yours is aboard or in the square, and only on your own crew's ship.
  - **One lift ends the mission, for the player crew only.** A rival crew's lift never does.
  - **Door gun:** the ship has one. It joins the initiative pool and can be disabled. The ship
    itself is invulnerable.
- **Hangars.** 3–4 per deck, scaled by size. Only the insertion hangar is known at the start;
  others are discovered by entering their room. Any of them can be used.
  - **Revision 2:** each hangar has a designated 3x3 square that is always valid. The bay has
    plenty of cover, none of it in the square or the ship's space. The ship's space blocks line
    of sight and light, but the square doesn't. Bays are 3–4x the landing zone, with wrecked
    ships as set dressing.
- **Weapon switch (revision 2).** A soldier can switch primary ↔ pistol for 1 AP. Picking up a
  body still costs 2 AP and draws the pistol with no extra charge.
- **Downed and death.**
  - **Downed bar:** equal to max HP, persisting across downs within a mission. It drains
    ceil(max_hp/5) per round and takes damage while down. At 0 the soldier is dead, and the
    third down is death.
  - **Actions:** revive 3 AP and pick up 2 AP (adjacent).
  - **Carrying:** carrying is unimpeded. The carrier can use only the pistol and grenades. A
    landed hit on the carrier goes into the body 25% of the time, or 0% if the carrier is in
    cover from that shot.
  - **Downed targeting:** depends on the faction.
- **Loot.**
  - **Inventory:** 4 slots. Equipped weapon, pistol, attachments and grenades are equipped
    and use no slots.
  - **Action:** looting costs 1 AP per item. Corpses can be looted or carried out.
  - **Contents:** valuables plus usable gear.
- **Objectives.** Optional, but they pay the most. There are four: Retrieve, Destroy, Hold
  terminal, Recover.
- **Campaign.** Paid recruits, permanent death, game over when broke with an empty roster, and
  squad wipe = whole squad lost.
- **Factions.** All hostile to one another, each in a way true to its identity. Rival mercs
  die outright (no downed state), leave lootable corpses, and extract on the player's rules.
- **Co-op.** Two players are **one crew** (crew 0). They share **one** extraction: either
  player can call, board or extract, and any soldier aboard or in the square leaves regardless
  of owner. Either player can revive, carry and loot the other player's soldiers.

---

## 2. Mission framework (Phase 0)

| Decision | Why | Where |
|---|---|---|
| Four mission outcomes: EXTRACTED, WIPED, ABANDONED, **CLEARED**. CLEARED is the legacy "all hostiles down" win, kept for test decks with no hangars. | Folding a test-deck sweep into EXTRACTED would let the campaign book a sweep as a real departure. | `mission_result.gd` |
| Clear-out still exists, but a deck **with hangars turns it off**. Killing everything ends nothing, and only extraction or a wipe ends the mission. | Extraction decks must not auto-win. Legacy decks and tests keep working. | `turn_manager.gd`, `main.gd` |
| When the host disconnects, the client sees ABANDONED (unless the mission was already decided). | The campaign and HUD need to hear "stopped, undecided" instead of overwriting a real result. | `turn_manager.gd` |
| End-of-round work (ship timers, terminal ticks, bleed) runs through registered **round-end hooks**, executed in order. A hook that ends the mission stops everything after it. | Deterministic ordering; one way to end a mission on every peer. | `turn_manager.gd` |
| Flat action costs (revive 3, pick up 2, loot 1, call 1, operate terminal 2, board 1, switch weapon 1, extract 0; mercs' dust off 0) bypass **everything**: Reflexes, weapon modifiers and the 1-AP minimum. | The GDD says flat. A 0-AP action would otherwise be floored to 1. | `unit_stats.gd` |

---

## 3. Hangars and the ship (Phase 1)

### 3.1 Geometry and generation (revised in revision 2, §14)
- **Layout.** A hangar is a pad centre plus a ramp side; everything else is derived. The pad,
  which is the space reserved for the ship, is **5x5**. The boarding square is 3x3, directly in
  front of the ramp, with its first row touching the pad.
- **Size.** Generated bays are 3–4x their landing zone (210–280 tiles) and 12–22 tiles per
  axis. The pad sits one tile off the back wall and the ramp faces the middle of the deck, which
  is where corridors arrive. **[tune]**
- **Count.** 3, plus a chance of a 4th that scales with area. The default (Medium, 72x48) deck
  gets a 4th about 40% of the time. A roll was used instead of a size threshold so that
  same-size decks vary. A deck that can't fit three is rerolled. **[tune]**
- **Reachability.** Every hangar square must be reachable from the insertion square. A failing
  deck is rerolled with a seed derived from the original, so co-op peers that receive only the
  seed still agree. In a 300-seed fuzz no reroll was needed.
- **Safe insertion.** No enemies spawn in the insertion bay or in any room one corridor away
  from it. The squad shouldn't step off the ramp into a firing line.

### 3.2 Discovery
- **Trigger.** Discovery fires per tile walked, so walking straight through a bay counts.
  Spawning in a bay also discovers it.
- **Kept apart from ship state.** Discovery is tracked separately so that a rival ship calling
  an undiscovered hangar never reveals it. When that ship leaves, the pad goes back to unknown.

### 3.3 Timings (exact semantics)
- **Arrival.** Called in round N, the ship lands at the **start** of round N+3.
- **Window.** Landed in round L, it leaves at the **end** of round L+4: five full rounds,
  counting the landing round.
- **Dust-off (rival crews only since revision 2).** The ship leaves at the end of the current
  round. It costs 0 AP and doesn't end the activation (A1). The player crew uses Board and
  Extract instead (§14.2).
- **Empty departure.** The pad cools down for 5 rounds before it can be called again.
- **Claims.** One per crew: a crew with a ship called or landed can't call a second hangar.

### 3.4 Call noise
- **Noise.** The 15-tile noise comes from the **pad**, not the caller, so calling from the
  back of the bay doesn't hide the source.
- **Hivemind.** A call does **not** escalate the alien hivemind (A2). The noise already
  reaches aliens through the normal sound channel, and escalating as well would double-punish.
- **Radio notice.** It fires for every call, including your own, so you can't tell your own
  call from another crew's by its absence.

### 3.5 Who leaves on the ship
- **Aboard (revision 2).** Everyone who already boarded leaves, whatever the square holds.
- **The square.** Every crew member in the square who is not dead goes too. A downed soldier
  lying in the square goes.
- **Bodies.** A carried body (downed or corpse) boards with its carrier.
- **Everyone else** of the crew is lost, whether alive or dead.

### 3.6 Landed ship and presentation
- **Impassable pad.** A landed ship makes its 5x5 pad impassable. Anyone standing on it, or
  any body lying there, is nudged to the nearest free tile for free, with a combat-log line.
  Since revision 2 the pad also **blocks line of sight and light** while the ship is down
  (§14.1).
- **Insertion cinematic.** The ship descends, drops the ramp, the squad appears, and the ship
  lifts off: about 5 seconds, played locally on each co-op peer, and skipped under `--auto`.
- **Dropship.** The placeholder is a box hull with a hinged ramp, untargetable and
  non-colliding.
- **HUD.**
  - **Hangar markers:** "[ Hangar B ] Ship in 2 / Departs in 4 / Cooldown 3".
  - **Ship buttons:** Call ship, Board ship and EXTRACT are hidden unless they are valid for
    the active soldier. Extract asks for confirmation when anyone would be left behind.
  - **Radio:** radio lines also show as a 3.5 s top banner.

---

## 4. Downed, death and carrying (Phase 2)

### 4.1 States and the bleed
- **Life states.** Units are ACTIVE, DOWNED or DEAD. Existing "downed" listeners keep meaning
  "left the fight", so a merc killed outright still fires them. New `died` / `revived` /
  `carry_changed` signals cover the rest.
- **Down count.** The third down increments the count, then kills.
- **The bleed.** It ticks at **round start, before anything else looks at the round**, so a
  soldier who bleeds out is a corpse before the ship, the HUD or the AI act on that round. The
  bleed ignores armour and causes no flinch. Damage taken while down does go through armour.

### 4.2 Revive and pick up
- **Reach.** Adjacent, **or the same tile.** Bodies don't occupy tiles, so a soldier is often
  standing on one.
- **Revive tile (A3).** The body's own tile if free. Otherwise the reviver's free neighbour
  nearest the body, with a fixed tie-break order so every co-op peer picks the same tile. With
  no free tile, the revive is refused.
- **Carried bodies.** A body that is being carried must be put down before it can be revived.
  Drop costs 0 AP.
- **Revived soldier.** They act next round, even if they went down and came back up within
  one activation.
- **Carry limits.** One body per carrier, and a downed soldier can't carry.

### 4.3 The pistol and carrying
- **Sidearm.** Every soldier has a fixed pistol sidearm: accuracy 30, damage 5, magazine 8,
  reserve 16 (A5). **[tune]**
- **Drawn automatically.** Picking up a body draws the pistol. Each weapon keeps its own ammo.
- **Switching (revision 2).** 1 AP either way, refused while carrying. Dropping a body hands
  back whichever gun the soldier last chose, so a soldier who chose the pistol keeps it. With
  the pistol chosen (not carrying), Suppress is allowed if the magazine covers it.
- **Allowed while carrying.** Pistol overwatch and aimed shot are allowed. Suppress is refused
  everywhere: HUD, commands and AI (A4). Grenades are allowed.

### 4.4 The 25% redirect (interpretations)
- **Timing.** It is decided **after** the hit roll on the carrier. Carrying never changes how
  often you are hit, only *who* takes it.
- **Cover.** "In cover from that shot" means the shot actually suffered a cover penalty. A
  weapon that ignores cover (Sagittarii) doesn't count as cover.
- **Corpses.** A carried **corpse is never** a redirect target, so you can't use a corpse as
  armour.
- **Melee.** Melee always hits the carrier.
- **Injuries.** A redirected round doesn't roll body-part injuries on the carried soldier.
- **Grenades.** A frag hits every downed body in the blast, carried or not, because an
  explosion doesn't care whose shoulder you are on. Corpses take nothing.

### 4.5 Who finishes the downed (faction-dependent policy)
- **Contractors:** never.
- **Aliens: opportunistic.**
  - A live hostile in view outranks a body.
  - An alien that isn't yet aware of anyone will go for a lit body in its line of sight.
  - Ranged aliens never "suppress" a body.
  - Worms never finish the downed, because their trample would march over a body forever.
- **Mercs.** They take a finishing shot only when nothing they'd fight is in view, the body is
  within 8 tiles and in line of sight, and the AP is spare. They never walk toward a body.
- **Robots (Cerberus):** never.

### 4.6 Extraction accounting
- **Recovered corpses.** A carried corpse appears in the extracted list **and** as a recovered
  corpse, so the debrief can say "body recovered" and bank their kit.
- **Wipe.** On a WIPED result, every soldier is lost.

---

## 5. Loot, inventory and objectives (Phases 3 and 6)

### 5.1 Items
- **Item codes.** Every item is a compact text code, so it can sync to clients, save and
  reload without loss. Gear codes carry their attachments and ammo.
- **Valuables (placeholders) [tune].** Each tier is worth a good fraction of a contract but
  never more, so the objective stays the big payout.
  - **T1:** Sealed Rations 15, Scrap Electronics 20, Crew Tags 25.
  - **T2:** Encrypted Drive 70, Pharma Case 85.
  - **T3:** Gold Chronometer 160, Fusion Cell 200, Prototype Chip 240.
- **Robot salvage.** 10 cr per salvage point, found as one item on the wreck.
- **Objective items** (Data Core, Flight Recorder, Sample Case) are worth 0. The contract pays.

### 5.2 Containers
- **Density.** Half of all ordinary rooms get 1–2 crates, about 7 per default deck. **[tune]**
- **Contents.** Each crate holds 1–3 items with tier weights 60/30/10. Crates are never empty.
- **Placement.**
  - **Where:** against a wall, in ordinary rooms only (not bays or corridors).
  - **Clearance:** never next to a door, cover or another crate.
  - **Connectivity:** a crate must never split a room's walkable area or cut off a hangar.
- **Blocking.** A crate blocks its tile but **gives no cover**. It's a prop, not cover.
- **Gear share (Phase 6).** Each crate item is gear 25% of the time, otherwise a valuable.
  That's about 3.6 gear pieces per deck. **[tune]**
  - **Gear tiers:** these follow the shop's price ladder (90 / 140 / 200 cr) and roll 60/30/10,
    so weaker items are the common finds.
  - **Ammo:** unlocks are never tier 1 (an unlock outlasts any copy); Penetrator is tier 3.
  - **Grenades:** a third of tier-1 gear, since the squad burns them and must restock.
  - **No guns in crates.** Primaries are free issue, so a crate gun would just be scrap. Guns
    are corpse-only finds.
  - **Gear value:** about ⅓ of shop price. It is shown on the loot panel and used to sell a
    duplicate ammo unlock.

### 5.3 Corpses and who can be looted
- **Death converts gear.** On death, the corpse's equipped gear becomes items in its pack: the
  primary with its attachments and ammo, plus any unthrown grenades.
  - **Pistol excluded:** the issued pistol is not added, since everyone has one.
  - **Built-in weapons:** alien and robot weapons yield nothing.
  - **No cap on corpses:** a corpse may hold more than 4 items.
- **Lootable.** Crates, piles, and **dead, uncarried** units of any faction.
- **Not lootable.** A downed friendly. Stripping a bleeding squadmate is a revive's job, and
  allowing it would let one co-op player empty the other's downed soldier.
- **Carrying and looting.** They are compatible. Carrying uses hands, not slots.
- **Dropping.** Free, and makes a lootable pile on the tile (A6).
- **Co-op race.** The loot panel sends the item it showed, so two players clicking the same
  item takes nothing instead of the wrong thing.
- **Merc pockets.** Always one valuable, plus a 30% chance of a second, from a poorer table
  than crates (75/20/5).

### 5.4 Contracts
- **Placement.** The target goes in a room in the **farthest third** of the deck by walking
  distance from insertion. **[tune]**
- **Payouts (Medium deck; Small ×0.7, Large ×1.3) [tune].**

  | Contract | Small | Medium | Large | Rationale |
  |---|---|---|---|---|
  | Retrieve | 350 | 500 | 650 | Baseline: find it, carry it home. |
  | Hold terminal | 390 | 550 | 720 | Four loud rounds pinned to a console, but nothing to carry. |
  | Destroy | 420 | 600 | 780 | The nest keeps spawning, and killing it wakes the deck. |
  | Recover | 450 | 650 | 850 | Pistol-only walk home, and every hit on the carrier can kill the contract. |

- **Payment needs extraction.** Every payout requires someone to extract. Completion latches,
  but money is only written into an EXTRACTED result.
- **Retrieve.** Done if the item is in the pack of *anyone* who boards: a living soldier, a
  carried downed soldier, or a carried corpse.
- **Destroy.** Done if the nest is dead, by any hand, including a robot's (see §8.2).
  - **Spawning:** the nest spawns on every 3rd of its activations. The mix is 90% Fodder and
    10% Agile Hunter; Spitters fall back to Fodder until built. **[tune]**
- **Hold terminal (Phase 6).**
  - **Operate:** 2 AP, from an adjacent tile. It's a deliberate action, but a soldier can
    still shoot in the same activation.
  - **Counting:** at each round start, it counts a round if any **standing** soldier of
    either player is beside it. A downed soldier doesn't hold it.
  - **Leaving pauses it; it doesn't reset.** The count is kept, but the console **doesn't
    resume by itself**: someone must operate it again for 2 AP.
    - A reset would let one bad round void the contract.
    - A self-resuming pause would make walking away free.
    - A paid restart is the middle ground.
  - **Length:** **4 held rounds**, about one ship cycle. **[tune]**
  - **Noise:** 8 tiles when started and at every counted round. That's a firefight's worth of
    noise per round, which is the point: it brings the deck to you.
  - **Console:** against a wall in a far room. Its placement is verified never to cut a path.
- **Recover (Phase 6).**
  - **The VIP:** spawns already downed in a far room, with 20 HP. **[tune]**
  - **No bleed (A10).** They can't be revived, because a revived VIP would be a unit nobody
    controls.
  - **Carrying:** any soldier can carry the VIP (2 AP), and the 25% redirect applies.
  - **AI never deliberately finishes the VIP.** Otherwise a wandering alien could kill them
    before you arrive, and the contract would be a coin flip outside your control. Stray
    damage (grenades, redirected rounds) still lands.
  - **Success:** the VIP leaves **alive**, either carried aboard or **set down in the square**
    at departure. Setting them down one tile early mustn't read as a bug.
  - **The VIP doesn't count as the crew boarding.** A VIP alone in an otherwise empty square
    doesn't make the ship count as boarded.
  - **Kept out of the roster:** the VIP never appears in the squad's roll call, loot manifest
    or debrief.

---

## 6. The door gun (Phase 5)

- **What it is.** A stationary unit fighting for the **calling crew's** faction:
  Contractors for the player crew, mercs for a merc ship. One code path serves both.
- **Position.** On the pad's ramp-side corner, under the gun mount. It takes none of the
  square's 9 tiles, but it **is adjacent to the square, so melee aliens can reach it.**
- **Stats (all placeholder) [tune].**
  - **HP 30, armoured:** 2 off every hit, minimum 1 through. That's about 4–5 rifle hits to
    disable, so it soaks fire but can be silenced in one determined round.
  - **Weapon:** LMG accuracy and damage. **Two shots per activation**; it never reloads.
  - **Hidden Initiative:** 65, in the middle of a typical squad's range, so it isn't reliably
    first or last.
  - **Light:** obeys the light modifier (A9).
- **Targeting.**
  - **Reach:** standing hostiles within **6 tiles of the square**, in line of sight. That
    covers the bay without sniping down the corridor.
  - **Choice:** highest hit chance, then nearest to the square (the threat to the people
    boarding), then a deterministic tie-break. It re-chooses for each shot, so a kill frees
    the second shot for someone else.
  - **Known issue:** raw accuracy usually hits the 99% cap, so in practice it picks the target
    nearest the square. **[tune]**
- **Disabled.**
  - **At 0 HP:** dead, with no downed step. The model stays on the roof, dark, labelled
    DISABLED. It can't be looted, carried, revived or extracted.
  - **Lifetime:** it stays disabled for that ship. A re-called ship brings a fresh gun.
- **Excluded from all crew accounting:** it never appears in the squad, the wipe check,
  boarding or the debrief. A door gun standing alone can't keep a mission alive.
- **Draws fire.** Hostile AI targets it like any unit. The ship itself stays untouchable.

---

## 7. Campaign and economy (Phase 4)

### 7.1 Economy shape [tune]
The target: a decent run (Medium contract completed, 4–5 ordinary finds, nobody lost) pays
about **750 cr**. That buys one average recruit (~400), an attachment or ammo unlock, and
restocked grenades and medkits. A safe early exit pays only its loot (~100–250 cr). Losing a
soldier costs about a recruit plus the attachment copies they carried.

- **Recruits.** 300 + 200 × quality (300–500, typically ~400). 2–4 on offer per visit, from a
  random class.
- **Shop.**
  - **Attachments:** 90 / 140 / 200 by tier.
  - **Ammo unlocks:** permanent, 150–250.
  - **Consumables:** grenade 40, medkit 60.
- **Starting state.** 4 soldiers (one per class), 500 cr, 4 grenades, 2 medkits, one each of
  four starter attachments, standard ammo only, 3 contracts and 2–4 recruits. Roster cap 8.
- **Contract board.** Deck size is weighted 30/45/25 across Small/Medium/Large. The board is
  re-dealt only after a debrief, and the deal is saved, so quitting can't reroll it.

### 7.2 Debrief rules
- **Booking.** The debrief is booked the moment the mission ends, before any click (ironman).
- **Fates.**
  - **Survived:** keeps the loadout they carried and their injuries; their pack is banked.
  - **Recovered corpse:** removed from the roster, but their kit comes home (net: copies kept,
    gun scrapped for 40).
  - **Lost:** removed with everything they carried.
- **Looted gear.**
  - **Attachment:** +1 stash copy.
  - **Ammo:** unlocks the type, or sells if already owned.
  - **Gun:** its attachments go to the stash and the gun is scrapped for 40.
  - **Grenade:** +1 stock.
- **Downed-but-extracted.** No extra penalty (parked, per GDD). Only real body-part injuries
  carry over, and one medkit clears one part.
- **Grenades are stocked gear.** They are allotted in the hub (up to 2 per soldier, while stock
  lasts) rather than on the loadout screen, so two co-op loadout screens can't both spend the
  same stock.

### 7.3 Game over and the save
- **Game over.** It isn't "credits < cheapest recruit". It's "**roster plus every recruit on
  offer you could afford is fewer than 2**". The board only re-deals after a mission, which
  needs 2 soldiers, so an unaffordable board is a real dead end.
- **Save.** One ironman slot, saved after every hub action and at mission end, with atomic
  writes.
- **Quitting mid-mission.** A save that was quit mid-mission is booked as a **wipe**: the
  squad and its kit are lost and there is no payout. This is strict by design, and it means a
  crash also costs the squad.

---

## 8. Cross-faction hostility (Phase 7)

Every faction is hostile to every other, and the hostility table is symmetric. Each faction's
*character* lives in how it picks fights, not in the table.

### 8.1 Aliens: nearest prey, whatever it is
- **Rule.** Nothing new: they go for the nearest detected hostile.
- **Consequences** (deliberately left in):
  - Aliens see by light and **robots carry no lights**, so an alien can't see a robot in the
    dark.
  - Robot gunfire is noise, though, and being shot always hands an alien its shooter. Robots
    can't farm an inert faction.
  - Merc rig lights set off alien light aggro.

### 8.2 Security robots: faction-blind threat score
- **Score.** Every intruder is scored by one formula: +10 if it fired on a robot in this
  zone, +4 if it carries a ranged weapon, +2 if it moved recently, +0.5 per tile closer than 8.
  "Intruder" is not a species check. **[tune]**
- **Re-ranking.** Unlike aliens, robots re-rank every activation. They switch target only if
  the new one beats the old by 3 points, but shooting a robot always clears that bar.
- **Memory.** Who fired on a robot is remembered zone-wide for the rest of the mission.
- **Nests.** Robots will shoot a nest within 4 tiles. A robot can therefore complete your
  Destroy contract for you, and set off the hive escalation. This was kept as legitimate
  third-party play.

### 8.3 Mercs: "is this fight worth the rounds?"
- **The player crew** (including your door gun): always engaged, and ranked first.
- **Aliens and robots: only if one of these holds:**
  - it is hunting the merc squad;
  - it blocks their route (within 1 tile of the next 6 tiles);
  - it is within 3 tiles of any squad member.

  Being shot at always qualifies. **[tune]**
- **Breaking off.** A merc fighting a third party that no longer qualifies **breaks off**: it
  goes back to its job, not to alert (which would walk it straight back in).
- **Routing around third parties.** Mercs path around known third parties (+3 cost per tile
  within 2 tiles of one a squadmate can see). An unlit, motionless robot is therefore walked
  straight into, and then the fight is on.

### 8.4 Unchanged rules
Overwatch, suppression, trample and win/loss already worked off "is hostile", so they apply
across factions automatically. Third parties killing each other just shortens a clear-out.

---

## 9. Rival merc extraction (Phase 8)

### 9.1 Plan deviation: mercs discover hangars
The plan's A11 said "mercs know every hangar". Your locked design ("discovered by entering
their room, any crew") overrides it. A merc crew learns a hangar only when one of its members
enters the room, and may call only hangars it knows. A11 is struck through in the plan.

### 9.2 Crews and the job
- **Crews.** Each merc squad is its own crew. All merc squads still share one faction, so two
  merc crews are allies in a fight but **compete for hangars**.
- **The job.** Each crew gets one shared job, rolled from the deck seed. **[tune]**
  - **Loot:** clear 2–3 containers, 1 AP per item (the player's price), best value first. They
    only know containers in rooms they've been through, and they **leave your objective item
    alone**.
  - **Contest (Retrieve contracts, 50%):** go for **your** objective item wherever it is
    (crate, pile, or uncarried corpse) and take it first. If it's already in living hands
    that aren't theirs, they fall back to looting.
  - **Nothing known to do:** scout the nearest unvisited room, moving as a squad.
- **Not a GOAP goal.** The planner only runs in combat, and all of this happens outside it.

### 9.3 When they leave
- **Triggers.** Any one of: job done, every pack full, half the crew down, or a rolled round
  limit of 16–24 (around the player's pace, so merc calls really do contest hangars).
  **[tune]**
- **Hurry-up.** **Another crew's call** pulls their departure to at most 6 rounds away: the
  competition is leaving, and the deck is about to get loud. They learn *where* only from the
  15-tile noise, exactly like you.
- **Call.** They go to the nearest callable hangar they know, call from the bay with the
  player's rules (claim, noise, radio), then hold the square.
- **Ship down beats fighting.** Once their ship lands they move into the square and shoot from
  there, never leaving it.
- **Dust-off.** When everyone alive is in the square, **or** at least half are and the ship
  has waited 3 rounds. **[tune]**
- **Routing.** They route around a hostile door gun they know about (+4 cost per covered
  tile), but will still go under it if it's the only way.

### 9.4 A rival lift
- **Never ends your mission.**
- **Boarded mercs** leave the board with their packs. If **your Retrieve item** is aboard, the
  objective reads "flown out by a rival crew" and can no longer be met.
- **Corpses** stay lootable.
- **Stranded mercs.** Living mercs outside the square are stranded: their crew can't call
  again, and they revert to plain merc behaviour.
- **Empty departures.** An empty rival departure, or a crew wiped before landing, means the
  ship sits out its window, cools down, and the hangar is free again.
- **Claims block both ways.**

### 9.5 What you see
- **Rival call.** Radio: "Another crew has called a ship." No location. Your own call reads
  "A ship has been called."
- **Discovered hangars.** For hangars you know, you see the rival hull, square and door gun,
  and the landing and lift-off lines name the hangar.
- **Unknown hangars.** Nothing is shown. When the ship lifts you hear only "A rival crew's ship
  has left the deck."
- **Debrief.** Each rival lift appears on the end panel and in the debrief as **intel only**:
  no money changes hands.
- **Fixed in passing.** A rival lift used to hide any of *your* soldiers standing in the rival
  square. Only your own lift hides soldiers now.

### 9.6 Generated decks get mercs
- **Spawn chance.** 40% of generated decks get one 3-merc squad in an ordinary room, away from
  insertion and from aliens. **[tune]** Without this, merc extraction would only ever happen
  on one hand-made deck.
- **Determinism.** It is the last random draw, so every seed's deck is otherwise unchanged.

---

## 10. Co-op (your additional request)

Both players are **one crew** throughout.

- **One extraction between them.**
  - Either player can call the ship, board it, or give the word to extract. Extract ends the
    mission for both.
  - Any soldier aboard or in the square leaves, whoever owns them. Either player's soldier can
    carry the other's casualty aboard.
  - There is never a second ship for the "other" player. The one-claim-per-crew rule makes
    that impossible.
- **Revive and carry across owners.** Either player's soldier can revive or pick up the other
  player's downed soldiers and corpses. A command is validated only against *the acting
  soldier's* owner, never the target's.
- **Cross-player looting.** Either player can loot the other's **dead** soldiers. The
  other's **downed** soldiers can't be looted (§5.3).
- **Shared objectives.** Either player's standing soldier holds the terminal, and either can
  carry the VIP.
- **Host-authoritative throughout.**
  - **Deterministic on every peer:** the deck, crates, the objective, the door gun and merc
    crews are built on every peer from shared seeds.
  - **Host-only:** all timers, the terminal clock, merc AI and looting run on the host and
    are mirrored to the client.
  - **Campaign:** the host's campaign, one save. The client owns nothing persistent (A7).
    Each player's loadout screen sees the stash minus the copies fitted to the other player's
    soldiers.
- **Untested.** None of this has been run with a live second client yet (see §12).

---

## 11. `--auto` harness behaviour (test tooling, not design)

These choices only affect the headless auto-player. They are recorded so test results can be
read correctly.

- **Hunting and calling.** The squad hunts until nothing it can act on is left, round 20
  arrives, or a ship is claimed. Then it calls the ship and walks to the square. Each soldier
  who reaches it boards, and the last one in gives the word to extract.
- **Tending the downed.** It revives in reach, else carries (downed before dead), else walks
  up to 8 tiles to a body.
- **Loot and objectives.** It loots cheaply when quiet. One "fetcher" works the objective.
  The ship call waits while a reachable objective task is pending, until round 28.
- **`--auto-campaign=N`** chains N missions through a temporary save that is deleted at the
  end.

---

## 12. Known gaps and risks

- **Co-op is untested live.** Only the headless code paths and RPC ordering have been checked.
  The two-player run needs doing next.
- **Placeholder art everywhere:** box dropship, box console, roof-box door gun, pistol using
  rifle poses, box on the carrier's back.
- **Door gun rarely fires in `--auto`.** Enemies are usually dead before the ship lands.
  Firing is covered by tests, but its feel is unknown.
- **Contested objectives.** Only Retrieve can be contested by mercs. Destroy, Hold and Recover
  contests aren't built.
- **Generated decks spawn no robots.** Aliens plus (now) one merc crew only. Three-way fights
  with robots happen only on hand-made decks.
- **Merc crews are allies of each other.** They all share one faction.
- **The hold console tile** is blocked in the live grid but not in the map data. It's
  harmless with one contract per mission. On hand-made decks without generator metadata it
  can land in a corridor.
- **Fog leak.** AI action lines reach the combat log regardless of fog. This predates the
  extraction work.
- **Economy untuned.** The harness hub never spends, so credits pile up in `--auto`.
- **Strict mid-mission quit.** A crash or quit mid-mission costs the squad.
- **Flaky test.** `test_goap` flips between 8 and 9 failures (an unseeded merc-vs-soldier
  check). It is pre-existing and unrelated.
- **Revision 2 gaps (§14):**
  - **Rival crews don't board.** They still leave by dust-off at the end of a round.
  - **Missions run longer** on the bigger decks. Two of ten `--auto` seeds wiped on Hold
    contracts walking to a far console.
  - **Hand-made test decks are too small for the new bay rule.** Their 11x11 bays only fit the
    5x5 pad and the square. The rule is enforced on generated decks only.
  - **Pistol model.** Switching to the pistol has no model or animation yet.

---

## 13. Review first

These are the calls most likely to change how the game *feels*. Please confirm or overturn
them:

1. **Hold terminal pauses, and restarting costs 2 AP** (§5.4). The alternatives are a hard
   reset or an automatic resume.
2. **The VIP is never deliberately finished by AI** (§5.4). The alternative makes Recover much
   harsher and more random.
3. **Robots can complete your Destroy contract** (§8.2).
4. **Mercs contest your Retrieve item half the time, and can fly it out** (§9.2, §9.4). This
   is the main source of rival pressure.
5. **Downed friendlies can't be looted** (§5.3), including by the other co-op player.
6. **A crashed or quit mission counts as a wipe** (§7.3).
7. **Game over is "can't field 2 soldiers"**, not "can't afford a recruit" (§7.3).
8. **The door gun's reach is 6 tiles from the square**, and it is effectively always 99%
   accurate (§6). Tuning is needed.
9. **40% of generated decks have a rival merc crew** (§9.6).
10. **Payout ordering** Retrieve < Hold < Destroy < Recover (§5.4).
11. **Extract is immediate** (§14.2). It used to leave at the end of the round. With Board as
    the safe way in, waiting to the end of the round only gave enemies a free round at the
    stragglers.
12. **Board costs 1 AP and ends the activation** (§14.2).
13. **Bays are 3–4x the landing zone, and decks grew a size to fit them** (§14.1). This is the
    biggest change to mission feel in this revision.

---

## 14. Revision 2: hangars, Board & Extract, weapon switch

These requests came after the first build: designated squares, cover, a blocking ship space,
big bays, Board and Extract as separate actions, and weapon switching.

### 14.1 Hangar design
- **Designated square, always valid.** The pad and the square are never under a wall, cover,
  wreck or crate. `MapData.hangar_problem` checks this. Hand-made decks that break it are an
  error on load, and generated decks are fuzzed over 300 seeds.
- **Reserved ship space: 5x5** (`HANGAR_PAD_RADIUS = 2`, 7.5 m a side). It is sized for a real
  dropship model rather than the box placeholder, so the asset can grow into it without
  moving a hangar. The hull, door-gun corner, bay sizing and square offset all derive from
  this one constant. **[tune once the model exists]**
- **The ship blocks sight and light** while it is down. A wall-height blocker
  (`Dropship.make_blocker`, collision layer 1, what LOS and lighting raycast) sits on the pad
  from the LANDED transition until it leaves, and the light map is recomputed around it. The
  square in front stays open.
  - **The door gun is the exception.** Its own line of sight ignores its own ship's blocker,
    because it is mounted on the hull. The blocker also leaves out the gun's corner tile, so
    that tile is still lit and the gun can still be shot at and disabled.
- **Bay size: 3–4x the landing zone.** I read "3–4x the size of the hangar" as 3–4x the space
  the ship and the square need. That is the pad and the square with a one-tile apron:
  7x10 = 70 tiles, so bays are 210–280 tiles, 12–22 tiles per axis. **[tune]**
- **Hangar cover.**
  - **Wrecks:** 1–2 wrecked ships per bay, 2–3 by 3–4 tiles. They are full height,
    indestructible, block sight and light, and give heavy cover to anyone beside them.
  - **Ordinary cover:** 4–7 blocks per bay, more than an ordinary room gets. Measured: 1.5
    wrecks and 5.5 blocks per bay.
  - **Clearance:** every piece is kept a tile clear of the pad and square, off any spawn, and
    a tile off the walls. That spacing keeps the bay connected without a flood check.
  - **Art:** wrecks are placeholder boxes; there is a `[wrecks]` map section.
- **Decks grew one size.** At the old sizes, a tenth of default decks couldn't fit three bays,
  and bays took 55–73% of the walkable floor.
  - **New sizes:** Small 60x40, Medium and the generator default 72x48, Large 84x56.
  - **Rerolls:** a deck that still fits fewer than three hangars is rerolled.
  - **Hangar count:** thresholds were rescaled, so Small gets 3, Medium gets a 4th about 40% of
    the time, and Large nearly always gets 4.
  - **Fuzz:** over 300 default seeds, 185 had 3 hangars and 115 had 4, with no rerolls needed.
  - **[tune]** Missions are longer as a result.

### 14.2 Board and Extract
- **Board (1 AP, ends the activation).** It is available from the square of your own landed
  ship.
  - **Who goes:** the soldier and whatever they carry (a downed squadmate, a corpse, the VIP)
    leave the board.
  - **Safety:** they leave every group the AI, pool and end checks read. Nothing can target,
    finish or bleed them, and they're certain to leave with the ship however the mission ends.
  - **Mission:** boarding never ends the mission.
  - **Why 1 AP:** it costs the same as calling, so a soldier who reaches the square with a point
    left can always get in. It ends the activation because the soldier is no longer on the
    board.
- **Extract (0 AP, ends the mission at once).** Any player soldier can use it on their own
  activation, wherever they stand.
  - **When it is valid:** your crew's own ship is down, and at least one of yours is aboard or
    alive (standing or downed) in its square. A corpse in the square doesn't count.
  - **Never on a rival's ship.** You can't extract on a rival's ship even while standing in its
    square.
  - **Aboard counts as well as the square.** You asked for at least one soldier in the square.
    I also count anyone aboard, because otherwise boarding everyone would make extracting
    impossible.
  - **Confirmation:** the HUD names who would be left behind and asks first.
- **Immediate, not end of round.** This replaces the old dust-off rule for the player crew. The
  extract action is the moment the mission ends, and holding the ship to the end of the round
  would only give enemies a free round at the stragglers.
- **The window still runs out.** If nobody gives the word, the ship leaves at the end of its
  5th round with everyone aboard and everyone in the square, and the mission ends if anyone
  went.
- **Pilot's call.** If nobody of yours is left standing on the deck but someone is aboard, the
  ship takes off with them. That is an extraction, not a wipe; otherwise nobody would be left
  to give the word.
- **One lift ends the mission, for the player crew.** Your ship leaving with at least one of
  your soldiers ends it. A rival crew's lift never does (§9.4).
- **Rival crews** still leave by dust-off. They don't board yet.

### 14.3 Weapon switch
- **Cost:** 1 AP flat, primary ↔ pistol. Each gun keeps its own magazine and reserve.
- **Carrying:** switching is refused while carrying, because carrying forces the pistol.
  Picking up a body still costs only its own 2 AP and draws the pistol with no switch charge.
- **Dropping a body** hands back whichever gun the soldier last chose. A soldier who switched to
  the pistol keeps it; one who didn't gets the primary back.
- **Suppress** is refused only while carrying. With the pistol chosen, it is allowed if the
  magazine covers the 3-round cost.
- **Who it applies to:** player soldiers. Rival mercs have no sidearm, so I read "mercs" in the
  request as your own soldiers.
