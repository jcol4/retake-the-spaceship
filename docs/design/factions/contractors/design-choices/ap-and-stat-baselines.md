# Granular AP + Stat Baselines

*Supersedes GDD Sections 4.0–4.3 (the 2 AP economy and Run/Sprint movement), 4.1's Initiative
composition, 4.6.2/4.6.3 (what Reflexes and Fitness govern), and 11.4's two-speed Fodder movement.
Implemented 2026-08-10. Current source of truth for every number below is
`scripts/unit_stats.gd`, `scripts/combat.gd` and `scripts/unit.gd`.*

Two coupled reworks, done together because they interact:

1. The fixed 2 AP menu becomes a **granular AP pool**. Movement costs a flat 1 AP per tile; pool
   size scales with **Fitness**; the AP cost of Shoot/Melee/Grenade/Reload/Aimed Shot scales down
   with **Reflexes**.
2. Max HP and Initiative move from "one stat is the whole answer" to **a base value with a small
   stat-derived bonus**, and Initiative's class base modifier is removed outright.

## 1. Why, in one paragraph

The GDD's stat system is explicitly modelled on the original *X-COM*'s percentile system (Sec 4.6),
but the 2 AP menu it sat on was *XCOM 2*-style. This aligns the action economy with the stat model
it borrows from. More concretely, it gives each stat exactly one **major** lever and a couple of
minor ones, instead of several stats competing to be the one that matters:

| Stat | Major | Minor |
|---|---|---|
| Fitness | AP pool size | Max HP |
| Reflexes | AP cost discount on actions | Initiative; Shoot/Overwatch accuracy |

Both were the other way round before: Fitness *was* max HP and nothing else, and Reflexes was 60%
of Initiative. Granular AP also gives the AI a shared currency to score actions against, which is
what the rival-merc faction's FEAR-style squad coordination is blocked on.

**Known cost:** the granularity raises player cognitive load relative to a two-action menu. That is
a real tension with design pillar #4 and it has not been playtested away.

## 2. AP pool

```
AP_pool = floor(6 + 0.075 × Fitness)
```

6 AP at Fitness 0 (a floor — every unit can still act), ~13 at Fitness 99. A rolled soldier lands
around 10–12.

**Both terms are 1.5× their original values** (4 + 0.05), so the Fitness spread keeps the same share
of the pool it always had. That multiplier is one half of a pair and only makes sense read with the
other: **every priced action in Sec 4 went up by the same 1.5×, with no exceptions** — so the number
of actions in an activation is unchanged. What did *not* scale is movement (Sec 3, still flat 1 AP
per tile), so the whole of the extra pool cashes out as **ground covered**. A soldier crosses about
half again as much map per activation, while every action it might take at the far end costs the
same fraction of an activation it always did.

## 3. Movement: flat, 1 AP per tile

**1 AP per tile for every unit regardless of stats**, and a diagonal costs the same 1 AP a cardinal
does. That last point is not a simplification — it follows the grid. Movement is eight-way at
uniform cost (GDD Sec 4.0, restored after an interim four-way period), so `GridManager` is a BFS and
N AP reaches a *square* of side 2N+1. Charging 2 AP for a diagonal would make it a Dijkstra and
re-break the reachable set the map's corridors were sized against.

There is no Run band and no Sprint band any more. The move preview is one range overlay, graded by
what each tile costs against the pool, and the hovered destination reports both its price and what
it leaves (`HighlightManager.show_move_range` / `show_path`).

**The one modifier:** an injured leg (GDD Sec 4.2.1) raises AP-per-tile rather than shrinking a tile
allowance, since the allowance is what this rework deleted. It stays a movement-only penalty that
way; routing it through the pool would have quietly cost the unit shots and reloads too. Integer AP
per tile makes the realised cut coarser than the stated 33% — one leg lands on 2 AP/tile, two legs
on 3 — which is the cost-rounding rule below doing its job.

`WeaponData.move_multiplier` was **retired**, not re-expressed. The LMG's 0.75 was the only non-1.0
value the table ever held, and both candidate homes cost more than it was worth.

## 4. Action costs

```
Cost = max(1, ceil(base_cost − k_ref × Reflexes))
```

| Action | Base | k_ref |
|---|---|---|
| Shoot (snap) | 6 AP | 0.03 |
| Melee | 6 AP | 0.03 |
| Throw Grenade | 6 AP | 0.03 |
| Reload | 6 AP | 0.03 |
| Suppress | 8 AP | 0.03 |
| Aimed Shot | per zone, below | 0.015 |
| Hunker Down | 6 AP | — none, fixed |
| Overwatch | 6 AP, same as Shoot | 0.03 — see §5 |
| Flashlight toggle | 0 AP | — always free |

### The target this table is fitted to

**A second shot should cost you the activation.** A typical soldier is 10–12 AP and pays 5 for a
snap shot, so shooting twice is 10 — affordable only by a unit that set up and stayed put. Move
first and the second shot is gone. Shoot twice, or shoot once and reposition; never both. What the
1.5× pool buys is *distance*, not *volume of fire*.

Where that lands per class, against a 5 AP shot:

| | Pool | Shoot | AP left after two shots |
|---|---|---|---|
| Assault | 10–12 | 5 | 0–2 |
| Heavy | 10–12 | 5–6 | −2…2 |
| Support | 9–10 | 5 | can't, or exactly |
| Sniper | 8–9 | 5 | **can't** — one shot per activation |
| Merc | 9–11 | 5 | −1…1 |

### Why `k_ref` went DOWN to 0.03

This is the one coefficient in the rework that moved against the grain — it was 0.04 before — and
the table above does not work without it. **Scaling the bases 1.5× alone makes nothing harder**,
because the discount is subtracted from whatever the base is: at 0.04 a Reflexes 55 soldier pays 4
for a 6 AP shot and can still shoot twice with three tiles to spare, which is the opposite of the
intent. At 0.03 the same soldier pays 5, and two shots is the activation.

What it costs is some of Reflexes' bite: the discount now spans 6 AP down to **4** across the whole
0–99 stat, where it used to span 6 down to 2. Still worth two tiles of movement at the top end, and
still the stat's major lever — but it no longer buys a whole extra action on its own, which is
precisely the thing that was undoing the price rise. If Reflexes ends up feeling inert in playtest,
this is the number to argue about, and the argument has to answer "then how is a second shot hard?"

Suppress is 8 against Shoot's 6. The *gap* widened with the scaling, but the property it was written
for survives: both take the same discount, suppression stays strictly dearer than simply shooting at
someone at every Reflexes value, and what it buys for the difference is still a whole enemy
activation spent flinching plus a free reaction shot. Under the shortened HP scale (Sec 6) that
flinch is worth more than it was, since an activation of return fire now kills.

Hunker's zero `k_ref` is a statement rather than an omission: dropping behind a crate is not
something you do faster by being quick.

### 4.1 Aimed Shot cost per zone

Tracks the accuracy-penalty ordering of Sec 4.2.1 — the harder the shot, the longer it takes to line
up. Lives in `Combat.AIMED_SHOT_BASE_AP`, beside the accuracy table it mirrors.

| Zone | Base | @ Reflexes 0 | @ Reflexes 99 |
|---|---|---|---|
| Torso | 8 AP | 8 | 7 |
| Arm (either) | 9 AP | 9 | 8 |
| Leg (either) | 9 AP | 9 | 8 |
| Head | 10 AP | 10 | 9 |

Scaled 1.5× with everything else — an Aimed Shot is an action, and leaving it at 5/6/7 against a
6 AP snap shot would have made the zone menu the *cheap* way to shoot, inverting the whole point of
pricing precision above volume.

**The two ends round in opposite directions**, deliberately: Torso's 7.5 rounds up to 8, Head's 10.5
rounds *down* to 10. Rounded up, the head is 11 AP — more than any soldier but a maximum-Fitness
Assault even has — and a zone nobody can select is not a hard choice, it is a missing feature. 10
keeps it affordable to exactly the classes that could afford it before the rescale.

Torso is always ≥1 AP above a snap shot at the same Reflexes, so an Aimed Shot never gets cheaper
than a snap shot — but the gap is small enough to stay a real in-budget choice. Aimed Shot's
discount is weaker than a snap shot's because its accuracy formula excludes Reflexes entirely
(Sec 4.6.2 — precision is Perception's domain): a cost discount says "readies faster" without
implying "aims truer".

The zone menu shows AP alongside hit chance and disables zones the pool cannot cover, because with
per-zone pricing the player cannot choose between zones from accuracy alone.

### 4.2 Rounding

- **Values a unit receives round DOWN** — AP pool, Max HP, Initiative.
- **Costs round UP**, floored at 1 AP.

*A unit never has more than the formula gives it, and never pays less than the formula charges it.*
Deliberately asymmetric rather than round-to-nearest, so there is no favourable rounding boundary to
hunt for.

## 5. Overwatch — priced as a Shoot

Overwatch now has a fixed price, identical to Shoot's: `UnitStats.Action.OVERWATCH` shares Shoot's
6 AP base and 0.03 Reflexes discount. `Unit.overwatch_reserve` is set to that fixed cost — not to
whatever AP happened to be left — so the reaction shot's accuracy reads the same regardless of when
in the activation Overwatch is taken.

It still **ends the activation outright**, exactly as before: the listed cost is a FLOOR, not the
whole price, and any AP left over once it is paid is forfeited by `Unit._end_activation_ap`, same as
Hunker Down.

## 6. Max HP and Initiative baselines

```
Max HP     = floor(base_hp     + 0.08 × Fitness + level_bonus_hp)
Initiative = floor(base_init   + 0.2  × Reflexes + equipment_bonus + level_bonus_init)
```

`base_hp` is **15 for the player faction** and `base_init` is **50**. The level bonus terms are named
and currently **zero** — the leveling system is deliberately not designed here; the formula shape is
future-proofed without inventing a curve.

### 6.0 The lethality rescale

`base_hp` was 50, for a ~70 HP soldier, and `HP_PER_FITNESS` was 0.3. **The whole HP scale came down
about 3.5×, while weapon damage came down only ~1.5×** (`WeaponPresets`), and that gap *is* the
lethality change. Concretely, hits to kill:

| Weapon | Damage | vs a 20 HP soldier | vs a 17 HP merc |
|---|---|---|---|
| Shotgun | 14 | 2 | 2 |
| Battle Rifle | 10 | 2 | 2 |
| LMG | 9 | 3 | 2 |
| Assault Rifle | 8 | 3 | 3 |
| SMG | 6 | 4 | 3 |

Where it used to be five or six across the board. **Nothing about accuracy, cover, flanking or crits
changed** — the fight is shorter because the bars are shorter. That moves weight onto cover,
first contact and who wins the opening exchange, and off attrition.

Target bands, and what the numbers were fitted to: **player soldiers 17–22 max HP** (Sniper lowest
off its 30–50 Fitness, Heavy highest off 65–90, centred on 20); **rival mercs 16–17**, a notch under
as they always were. `HP_PER_FITNESS` dropped to 0.08 with the scale — held at 0.3, the Fitness term
alone would have spanned 9–27 HP across the class ranges, i.e. more than a whole soldier's health
bar, and the roster's toughest and frailest would not have been in the same fight.

**Crit multipliers came down with it**, in `Combat`: an ordinary crit is now **1.5×** (was 2×) and a
headshot severe crit **2×** (was 3×). At the old multipliers a single lucky roll took a soldier from
untouched to dead or all but — an LMG crit was 18 against 20 HP, a Battle Rifle crit 20, and a severe
crit one-shot every weapon in the table bar the SMG. At 1.5× the same crits are 14 and 15: still most
of a health bar and still the best thing that can happen to one shot, but the target survives to be
finished deliberately rather than the fight being decided by the roll. Both constants are floats now,
and both call sites `roundi` the product.

Two consequences that follow from a subtractive term meeting a smaller scale:

- **Robot Armor scaled with DAMAGE (~0.65×), not with HP** — 10/8/4/3 → 6/5/3/2. Armor is subtracted
  *from* a damage roll, so it has to track the damage scale or plate stops being a tax and becomes
  immunity, and EMP stops being worth a kit slot and becomes mandatory.
- **Securus's head pool scaled with damage too** (24 → 12), because what that number is for is "how
  many Aimed Shots break it" — still two.

**Initiative has no class base modifier.** The old 60/30/10 (Reflexes / class / equipment)
composition is gone entirely. Class identity in turn order is now *indirect only*, via whatever
Reflexes range a class tends to roll in. If a direct "this class acts first on principle" lever is
wanted back, that is a new decision — not a bug in this rework.

`equipment_initiative` is now an **additive bonus**, where it used to be a 0–99 value taken at 10%
weight. Its stored values are therefore an order of magnitude smaller than before; porting an old
value across unchanged would make gear the loudest term on the board.

### 6.1 Two downstream effects worth watching in playtest

- **Injury thresholds compress, hard.** Body-part thresholds are fractions of Max HP (Sec 4.2.1),
  and the shortened scale makes them small absolute numbers: a head is 25% of 20 HP, i.e. **5 raw
  damage**, and an arm or leg is 7. One Aimed Shot from most weapons now crosses a limb threshold
  outright, where it used to take two or three. Probably desirable — the VATS system is a lot more
  present — but it is a consequence rather than a decision, and it is the single most likely thing
  in this rework to want a tuning pass after playtest.
- **Draw weights compress for the squad.** Initiative feeds a roulette-wheel draw. Player soldiers
  now cluster around 62–68 where they used to spread 38–56, so Initiative differentiates *within*
  the squad much less than it did. Cross-faction spread is preserved, because non-player types
  hand-set their own base (§7).

## 7. Non-player units: hand-set, not rolled

Aliens and security robots do **not** go through the player's percentile class-roll system. Each
type hand-sets `fitness` (pace), `base_hp` (toughness) and `base_initiative` (draw standing)
independently — see `AlienPresets` and `CerberusPresets`.

That independence is the rework's most useful side effect. Those three used to be one number, so
"tanky but slow" was a contradiction the roster had to work around with private movement-rate
overrides. Sagittarii is 20 HP on a 6 AP pool and Proctor is 6 HP on a 10 AP pool, stated directly.

Both rosters were rescaled by Sec 6.0's factors — HP ~0.3×, damage ~0.65× — and the **ordering is
what to check a change against**, not the absolute values. Security robots run 26 / 20 / 14 / 9 / 6
across Securus, Sagittarii, Auxilium, Lictor, Proctor, which is the same shape as the old
85 / 65 / 45 / 30 / 20.

**Sagittarii still fires *or* walks, never both** — 6 AP pool against a 6 AP shot. Worth recording
that this property briefly broke and came back: while the pool scaled 1.5× and Shoot did not, it
became "fires *and* shuffles two tiles", and scaling Shoot with everything else restored it exactly.
It is an invariant of **two** numbers, and nothing in the stat block says so on its own. The same
holds for Lictor (6 vs 6, one shot and the activation is over) and for the swarm's claw in §7.1.

### 7.1 Fodder's two-speed movement was removed

GDD Sec 11.4's shamble (1 tile/AP) and lunge (4 tiles/AP, latched at activation start) were built on
"tiles per 1 AP", the unit of measure this rework deletes. Pace is the AP pool now, so both were
removed along with `SwarmUnit._move_budget`.

What survives is the property the lunge's **latch** existed to protect: the player's turn of
warning. A swarm's pool (6 AP) against its claw (5 AP) means anything standing two or more tiles out
cannot both arrive and land a blow, while the one-step-then-swing reach it always had still fits.
That invariant survived the 1.5× scaling only because pool and claw scaled *together* — it is
exactly the kind of thing the pairing in Sec 2 exists to protect.
`tools/test_swarm_pace.gd` asserts exactly that, because nothing in the stat block announces that
those two numbers have to stay in that relationship.

The swarm's Reflexes is **authored (40) rather than rolled**, for a reason the rework created: it
used to be near-decorative (a swarm has no gun, and melee accuracy is Perception), but it now sets
the price of the claw, and across the old 15–30 roll that price came out 3 AP or 4 depending on the
roll — the tier's signature action behaving differently between two identical-looking creatures.

That 40 is **a dial set to buy a price, not a characterisation**, and it has already had to move
once: at `k_ref` 0.04 the value was 28, and when `k_ref` dropped to 0.03 that same 28 started buying
a 6 AP claw — the swarm's entire pool — which would have meant a shambler had to stand still to
swing and could never reach anyone at all. If `k_ref` or the Melee base moves again, this moves with
it. `test_swarm_pace.gd` is what makes that failure loud instead of silent.

Re-adding a burst of speed is a deliberate design decision, and it would be an AP grant or a
move-cost discount now, not a tiles-per-AP override.

## 8. Still open

1. **Overwatch reserve → accuracy penalty formula** (§5). Flat −30% until resolved.
2. **Equipment Initiative bonus magnitude** (§6). Never numerically pinned down, old or new.
3. **Whether "movement always completes once committed" (GDD Sec 4.0) still holds** when a committed
   move leaves AP the unit cannot spend on anything.
4. **Every constant here is a proposed starting point, not locked balance** — the pool base and
   coefficient, the 6/8 AP action bases, both k_ref values, the per-zone Aimed Shot costs, the
   15/0.08/0.2 HP and Initiative numbers, the crit multipliers, and the whole damage column of §6.0.

### Playtest checks this rework specifically asks for

- **Is a single shot per activation too few for the Sniper and Support?** They sit at 8–10 AP against
  a 5 AP shot, so they cannot double-tap at all. That follows directly from the "second shot costs
  the activation" target, and for the Sniper it is arguably correct — but it is the sharpest edge of
  the change and the first thing to look at if a class feels starved. The lever is Fitness in
  `ClassPresets`, not `k_ref`.
- **Does Reflexes still feel worth rolling for?** Its discount is a 2 AP swing across the full stat
  now (§4), down from 4. It buys two tiles of movement, never an extra action.
- **Do the compressed injury thresholds (§6.1) make Aimed Shots the dominant action?** They are the
  one thing in this pass deliberately left un-rescaled, so this is the most likely follow-up.
- Does the compressed HP band flatten class HP differentiation more than intended (§6.1)? At 0.08 a
  class's whole Fitness range is worth ~2 HP, so the class ranges are now near-purely an AP-pool and
  accuracy statement rather than a durability one.
- Does a hand-set low Fitness reproduce Fodder's slow-shuffle feel now that its private rate is gone
  (§7.1)?
- Is the granularity itself too much bookkeeping (design pillar #4)?
