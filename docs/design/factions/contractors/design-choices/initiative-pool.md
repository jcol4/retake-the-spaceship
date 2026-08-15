# Initiative Pool — the Contractor's-eye view

*Source: GDD Section 4.1. This doc covers the pool from the player-faction perspective; see each
enemy faction's own docs for how they participate on their side.*

## Full information on your own side, none on theirs

Every unit on the battlefield — contractors and both enemy factions — is drawn from one shared,
weighted pool each turn, with Initiative weighting (not guaranteeing) draw order. The player sees
their **own** units' Initiative values in full. **Enemy Initiative is fully hidden** — no exact
value, tier, or icon, for either the aliens or the [security robots](../../security-robots/).

**Why visible-for-mine, hidden-for-theirs, rather than both hidden or both visible:** full
visibility on the player's own side keeps the "tension through uncertainty" pillar (Section 2)
honest — the player can *reason* about their own draw odds ("my Assault has 60 base Initiative,
it'll probably act before my Sniper") and make decisions accordingly, which is what "the odds are
knowable and influenceable, not pure chaos" means for the player's own squad. Hiding enemy
Initiative preserves the actual uncertainty the pillar is about — the player never knows if the
next draw is their own unit or the enemy's, which is where the tension in "the safe plan can
always be disrupted" comes from. If enemy Initiative were also visible, the pool would become a
fully solved puzzle each turn rather than a probabilistic one.

## Contractor Initiative composition

`initiative = floor(50 + 0.2 * Reflexes + equipment_initiative)`

*Revised 2026-08-10 — see [`ap-and-stat-baselines.md`](ap-and-stat-baselines.md). Was
`Reflexes * 0.6 + class_base_initiative * 0.3 + equipment_initiative * 0.1`.*

Both remaining components are things the player can see and influence:

- **Reflexes** — rolled per-soldier within the class's range (see
  [`stat-system.md`](stat-system.md)), visible on the unit. A small, explicit bonus now rather than
  a dominant weighted share: Reflexes' major job moved to the AP cost discount.
- **equipment_initiative** — a flat additive bonus modifiable by loadout, giving equipment choices
  before a mission (Section 7's between-mission customization) a small, legible lever on draw order.
  Additive now, where it used to be a 0–99 value taken at 10% weight, so its stored magnitude is an
  order of magnitude smaller than before. The right magnitude is still an open question.

**`class_base_initiative` is gone.** There is no per-class flat addition to Initiative anywhere in
the calculation. A class acts early because of the Reflexes range it tends to roll in, not because
the roster grants it a head start — so the "my Assault has 60 base Initiative, it'll probably act
before my Sniper" reasoning the section above describes is now *weaker within a squad* than it was.
That is a real cost of the change rather than an oversight: player soldiers cluster around 62–68
where they used to spread 38–56. Enemy factions hand-set their own base value, so the cross-faction
spread that makes the draw tense is unaffected.

If a direct "this class acts first on principle" lever is wanted back, reintroducing a class term is
a new design decision — not a regression to fix.

## Support's Initiative-manipulation ability

Per Section 4.1's "Modifiability" clause (abilities/items/status effects can buff or debuff
Initiative mid-mission) and the Support class's stated role (Section 4.5: "Initiative
manipulation"), Support is the class expected to interact with this most directly in play — see
[`../units/support/`](../units/support/). No specific ability numbers are defined yet; this is
the class's headline mechanical identity but remains an open implementation item.
