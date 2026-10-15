# The Worm Mass

*Source: decided 2026-09-22. Supersedes the worm's "hidden bite" role in
[units/worm/](../units/worm/). Code: `scripts/worm_unit.gd`, `AlienPresets.worm`,
`scenes/worm_unit.tscn`.*

## What it is

A worm alone is nearly harmless. Worms together are the one thing on the board the squad
cannot kill fast enough to stop.

A single worm bites for **2**. It does not approach a target it cannot kill — it *calls*, and
crawls toward the other worms. When enough of them arrive on one tile they stop being
individuals the player can ignore and become a **mass**: one tile-sized pile that grows in
damage, in toughness, and — this is the part that makes it a tide rather than a wall — **in
speed**.

At sixteen worms it does 32 against a soldier's 19-21 HP, and it does not stop to do it — it
walks through the tile the soldier is standing on. It does not need to hit twice.

## The tier table

`count` is worms. Everything else is derived from it, and nothing else is authored.

| Tier | Count | Tiles/turn | Damage | HP | Attacks by | Reads as |
|---|---|---|---|---|---|---|
| — | 1 | 1 | 2 | 5 | biting | a worm |
| 1 — Clutch | 2-5 | 1 | 4-10 | 10-25 | trampling | something is gathering |
| 2 — Knot | 6-9 | 2 | 12-18 | 30-45 | trampling | it is moving now |
| 3 — Swell | 10-13 | 3 | 20-26 | 50-65 | trampling | **it can kill a soldier outright** |
| 4 — Tide | 14-16 | 4 | 28-32 | 70-80 | trampling | get off this deck |

- **Damage = 2 x count.** Uncapped. Ten worms is 20 damage, which one-shots most of the roster;
  eleven one-shots all of it. That is where the Swell tier boundary is drawn, so the tier the
  player can *see* is the tier that changed what the mass can do to them.
- **HP = 5 x count**, the worm's own HP, sixteen times over.
- **Cap: 16.** A worm arriving at a full mass does not merge. It stops adjacent and seeds a
  second mass, which is how a tide becomes a front rather than a single very angry tile.

## Damage removes worms

`count = ceil(current_hp / 5)`. Shooting the mass does not chip an abstract pool — it kills
worms, and the mass gets **weaker, slower and smaller** on the same hit.

This is the whole counterplay loop and it is why the numbers are arranged this way:

- An assault rifle does 8. Four hits kills six worms, which drops a Tide out of Swell and out
  of one-shot range. **Four hits, not ten.**
- Grenades are the designed answer and now genuinely are one, rather than incidentally.
- Killing a Tide outright takes 80 damage. **That is intended and it is not the goal.** The
  mass is meant to be degraded and evaded, not cleared. A player who reads 80 HP as "I must
  kill this" has misread the encounter, and the sprite shrinking on every volley is what
  tells them otherwise.

## Speed scales — and what that does NOT mean

Stated plainly because it will otherwise look like a bug in playtest: **a Tide still cannot
catch anybody.** A soldier's pool is 9-11 AP at 1 AP per tile, so a merc who turns and walks
outruns four tiles a turn forever.

What speed buys is *arrival inside the lifetime of a fight*. At one tile a turn a worm is
scenery — it reaches you in twelve turns, which is to say never. At four it crosses a
compartment in three, cuts off a door, and reaches the squad while the squad is still doing
the thing it came here to do. The mass is a threat to a squad that is **pinned**: holding an
objective, reloading, dragging a downed merc, or backed into a room with one exit.

So the tier's oldest invariant survives intact, and by accident rather than by rule: the
player always has the option to leave. The mass takes the option to *stay* away from them.

## It does not stop

**A mass has no attack action. It walks through you.**

A worm alone still bites, and the bite still costs its whole pool — that unit is unchanged.
But from count 2 upward there is no swing to price, because movement *is* the attack:

- The mass paths toward its quarry, treating hostile-occupied tiles as traversable.
- When its next step is onto a tile a hostile is standing on, it **resolves the step as an
  attack instead of taking it** — `2 x count` damage, rolled through `Combat.resolve_melee`
  so accuracy, crit, armor, the log line and `_report_incoming` all work unchanged.
- **If that kills, the tile clears and the mass keeps going** on whatever movement it has
  left. `Unit.take_damage` already calls `GridManager.set_occupant(grid_pos, null)` at 0 HP,
  so the corpse stops blocking and the Tide rolls on into the next soldier.
- **If the target survives, the mass stops there** and its activation ends. It got its one
  blow and the body in front of it held.

### What this deletes, stated plainly

This is a **deliberate break of the fodder tier's oldest invariant**. "Close OR swing, never
both" — the one turn of warning between *that thing is near* and *that thing is on me*, which
`SwarmUnit` is built around and `tools/test_swarm_pace.gd` exists to defend — does not
survive here. A Tide four tiles out can cross the gap and kill in the same activation.

It is kept for the single worm and deleted for the mass, and the reason is that **the mass
pays for its warning in advance.** A shambler gives you one turn because it arrives out of
nowhere. A Tide gives you the eight or ten turns you spent watching worms crawl toward each
other and the pile grow across the room. The warning moved from the moment of contact to the
whole approach, which is a better place for it — and it is the only version of this creature
that earns the word *unstoppable*.

`test_swarm_pace.gd` must be told this in writing, not simply have the case removed.

### Overwatch is the answer, and it falls out for free

`Unit.move_along` fires `TurnManager.check_overwatch` and `check_suppression_break` **on every
tile**. A Tide crossing four tiles into a prepared squad eats up to four reserved shots before
it arrives — and because damage removes worms, each one that lands cuts the damage it arrives
*with*.

So the counter to an unstoppable force is reserved fire, which is a good thing for a squad
game to teach and which no new system had to be built to say. A squad that spends its turn
shooting a Tide does worse than a squad that spends its turn aiming at where the Tide will be.

## Growing also costs the turn

A mass that absorbs a worm drops to 0 AP for the rest of its activation.

Without this, a Knot can be joined by its sixth worm and immediately act at Swell pace and
Swell damage in the same turn the player watched it grow. With it, every tier change is
followed by one turn of the mass sitting still at its new size — the player sees the thing
get bigger, and gets the turn of warning at exactly the moment the warning matters most.

## Behaviour

**Alone, or below what it takes to kill:** a worm that enters COMBAT does not approach its
quarry. It calls, and walks to the rally. It still bites anything melee-adjacent — contact is
always felt, and a worm you stand on should hurt, even for 2.

**The call** reuses `EnemyUnit._propagate_alert`'s compartment scoping rather than inventing
a channel. Worms inherit "a closed door stops an alert" for free, and isolating rooms stays
the valid player strategy it already is. What the worm's call adds is a **rally tile** the
ordinary `rouse` does not carry.

**The rally tile is the largest mass in the compartment**, or the discoverer's tile if there
is no mass yet. Deliberately not the player: worms converging on the player arrive from every
side at once and read as noise, where worms converging on each other produce one growing,
visible, shootable blob. The player should be able to look at a room and point at the problem.

**Merging** happens when a worm's move ends melee-adjacent to another worm or mass. The
smaller is absorbed into the larger.

**Terminal:** a mass at or above Swell (count 10) stops rallying and goes for the quarry. It
has enough to kill, so it spends itself.

**A mass below terminal still tramples whatever is in its way.** It is walking to the rally,
not to the soldier — but it does not go around, because going around is a thing that stops,
and this does not stop. A Clutch that crosses a doorway a merc is holding rolls over them for
8 on its way past. That is how the player learns what the growing pile does, at a price they
can survive, well before the Tide arrives to do it for 32.

**Decay:** a mass that settles to UNAWARE sheds one worm per turn onto free adjacent tiles
until it is singles again. This is what makes "kill the lights and back off" a real answer to
a forming tide rather than a delay, and it keeps a stalled mission from ending as one 80 HP
blob the board can never recover granularity from.

## No new alert state

`AlertState` stays UNAWARE / ALERT / COMBAT. Massing branches inside the worm's combat turn
instead. The `!` glyph is still honest — the thing has found you — and the player reads the
massing off sprites converging on a tile, which is better feedback than a label could be.
Adding a fourth state would touch the shared enum, its glyph and colour tables, and every
subclass including the security robots, to say something the board already says.

## One node type, not two

**The mass is a `WormUnit` with `count > 1`.** There is no separate mass scene, and this is a
correction of the obvious first design rather than a shortcut.

A separate `WormMassUnit` node means every merge frees nodes mid-turn, and
`TurnManager.pool` is snapshotted at turn start and filtered with `not u.is_downed` — a freed
node in that array is a crash, and a worm removed via the ordinary damage path would emit
`SecurityNetwork.report_evidence(CORPSE)` and litter the deck with corpses that were never
killed. Promoting in place means only the *absorbed* node is ever removed, the absorber keeps
its identity and its place in the draw, and count 1 needs no special case anywhere.

The pick collider is already tile-sized at count 1 — see the comment in `worm_unit.tscn`,
which oversizes it deliberately so a half-metre worm is clickable at camera distance. That
decision pays for this one.

## Numbers that are dials, not characterisations

Per the convention the rest of the alien roster is written to:

- `ap_pool()` is **overridden to a flat 12** rather than bought with Fitness. 12 is the
  smallest pool that divides cleanly into 1, 2, 3 and 4 tiles (12/12, 12/6, 12/4, 12/3), and
  buying it with Fitness 80 instead would leak +6 HP into a unit whose HP is supposed to be
  `5 x count` and nothing else.
- **A mass never calls `action_cost(MELEE)` at all.** The trample is paid for with the tile it
  was going to step on and nothing else, so the Reflexes-derived melee price — the number
  `AlienPresets.swarm` has to re-pin every time `K_REFLEXES` moves — simply does not apply to
  this unit. It still applies to the lone worm, unchanged.
- A trample costs **one tile of movement**, which means a Tide with four tiles can kill and
  keep rolling. Four soldiers in a line is four dead soldiers in one activation. That is
  arithmetic nobody will hit in practice and it is left unclamped deliberately: the situation
  it describes — a squad standing in a row in front of a Tide — should be catastrophic.
- Melee accuracy gets **+2 per worm, capped at +30**. Many mouths. A 55% one-shot is a
  coin-flip the player cannot plan around, and a Tide that whiffs is an anticlimax; at count
  16 this lands around 75%. **Tunable — this number was invented for this doc and has not
  been felt on screen.**

## Open items

- **The worm's own damage drops 5 -> 2**, and with it the "hits hard for its size" role the
  unit README currently describes. Intended: a lone worm is now a seed and an alarm, not a
  threat. The README needs rewriting, not patching.
- **Art.** Three variants (`worm_clutch` / `worm_knot` / `worm_tide`), each the existing worm
  mesh instanced into a heap with per-instance animation phase offsets so the pile writhes
  rather than sitting still. Swapped at runtime by `UnitVisual.set_variant`, with
  `canvas_height` lerped across each tier's count range — sixteen on-screen sizes from three
  sheets. `foot_anchor` is MEASURED off the rendered PNGs per tier, never guessed.

  **Two poses per tier, `idle` and `walk`.** No `melee` and no `downed`, and neither is an
  omission. There is no melee pose because there is no melee action — the trample is the walk
  cycle. There is no death pose because a mass shrinks rather than dies: it only reaches 0 HP
  from count 1, which is a worm, which by existing decision has no death art either.

  `foot_anchor` is the **minimum** opaque row for every pile, not the mean the humanoids use.
  A pile lies along the deck, so like the single worm it is nearly all depth rather than
  height, and a vertical billboard turns depth into height — the mean buries it under the
  floor. `render_sprites.py` prints this as its "no-clip alternative" and names the worm as
  the case for it; the piles are the same case, larger.

  The `NameLabel` carries the count, because sprite size is not a number a player can read
  precisely enough to decide whether to spend a grenade on it.
- **The worm's texture is still unpacked** and rendering untextured grey. A grey pile will
  read worse than a grey worm.
- **Cover.** A mass takes none and gets no cover bonus, so it stays shootable. Physically
  arguable; kept for legibility.
- **`tremor_range` stays flat at 4** regardless of count. A bigger pile feeling further is an
  obvious extension and is deliberately not taken yet.
- **Nests.** `art_src/worm_spawn_scaled.blend` is the obvious faucet, and without one the
  tide can only ever be as big as the map author hand-placed. Not decided here — see
  [spawn-nests.md](spawn-nests.md), whose 70/20/10 table has no worm entry.
- **`tools/test_swarm_pace.gd`** must grow the mass cases: the lone worm's move-OR-bite still
  holding, the mass being exempt from it **by decision and in writing**, `2 x count` damage,
  count-follows-HP, growing zeroes AP, a trample that kills continuing the move, a trample
  that does not killing stopping it, and absorption emitting no corpse evidence.
- **Pathing needs a third mode.** `GridManager.find_path` gates neighbours on `is_free` and
  makes a single exception for `allow_occupied_goal`. Trampling needs hostile-occupied tiles
  traversable *en route*, not just as a destination.
- **`Unit.move_along` cannot host the trample.** It clears the mover's occupancy up front and
  walks the whole path without re-checking what is in the way, so stepping into an occupied
  tile would stomp that tile's `occupant` reference. The mass needs its own tile-by-tile walk
  that resolves the attack before each step.
