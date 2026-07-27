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

`initiative = Reflexes * 0.6 + class_base_initiative * 0.3 + equipment_initiative * 0.1`

All three components are things the player can see and influence:

- **Reflexes** — rolled per-soldier within the class's range (see
  [`stat-system.md`](stat-system.md)), visible on the unit.
- **class_base_initiative** — fixed per class (Assault 60, Support 50, Sniper 45, Heavy Weapons
  40 in the current code defaults), a known quantity the player learns just by knowing the
  roster.
- **equipment_initiative** — the 10% slice modifiable by loadout, giving equipment choices before
  a mission (Section 7's between-mission customization) a small, legible lever on draw order.

## Support's Initiative-manipulation ability

Per Section 4.1's "Modifiability" clause (abilities/items/status effects can buff or debuff
Initiative mid-mission) and the Support class's stated role (Section 4.5: "Initiative
manipulation"), Support is the class expected to interact with this most directly in play — see
[`../units/support/`](../units/support/). No specific ability numbers are defined yet; this is
the class's headline mechanical identity but remains an open implementation item.
