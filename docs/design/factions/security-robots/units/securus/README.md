# Securus (JXM-2)

*New unit — the roster's elite/mini-boss-tier threat. Large, walking, melee/breach-focused;
Sagittarii already owns "tanky ranged pressure," so Securus is built around forcing the
player out of range entirely rather than punishing them for staying in it.*

| Speed | Toughness | Grouping | Core Role |
|---|---|---|---|
| Slow, heavy, walking | Very tanky, partially EMP-resistant | Solo or multiple | Elite melee/breach |

## Role

The unit the player has to commit real resources to, not just cover discipline. Where Sagittarii
is a "manage your exposure" problem, Securus is a "you cannot out-position this, you
have to out-damage or out-plan it" problem — it closes distance regardless of cover and punishes
standing still in melee range the way Sagittarii punishes standing still at range.

## Combat behavior

- **Melee/breach-focused.** Unlike the rest of the ranged-leaning roster, Securus's threat is
  close-range: it advances toward the nearest target and its primary attack is a melee strike,
  with breach capability against destructible cover (GDD Section 6.1.1) that lets it remove a
  player's cover outright rather than just shooting through it the way Sagittarii's weapon does.
- **Very high Armor/HP** — the tankiest single unit in the faction, consistent with its
  "elite" billing.
- **Partially EMP-resistant.** EMP still stuns it and zeroes its Armor, but for a **shorter
  duration** than the roster default — see
  [`../../design-choices/armor-and-destruction.md`](../../design-choices/armor-and-destruction.md#securus-is-only-partially-susceptible).
  The counter-lever still works, but the armor-bypass window it opens is narrower than against
  Sagittarii or Auxilium.
- **No low-HP retreat** — follows the roster default with no exception (unlike Proctor);
  see [`../../design-choices/ai-behavior.md`](../../design-choices/ai-behavior.md).
- **Multiple can appear in the same encounter.** Unlike Sagittarii/Auxilium (solo-only), a
  level can place more than one Securus. This is the lever that actually makes it "elite" rather
  than just a reskinned Sagittarii with more HP — a single Securus is a hard fight; two converging
  is a set-piece.

## The head: a component-HP weak point

Securus carries a separate **head-HP pool** on top of its normal Armor/HP, broken specifically by
landing **Aimed Shot** hits (the existing 2 AP, VATS-style targeting action — GDD/contractors
`action-economy.md`) against the Head zone. Snap-shots and Aimed Shots to other zones never
touch it. Once it hits 0, the head breaks off and Securus takes major bonus damage on all
subsequent hits for the rest of the fight. Full mechanical detail and rationale in
[`../../design-choices/armor-and-destruction.md`](../../design-choices/armor-and-destruction.md#securuss-head-a-component-hp-weak-point-using-the-existing-aimed-shot-system).

This is the intended shape of a Securus fight: grind the head down with committed Aimed Shots
(trading move-and-shoot flexibility for it, same tradeoff Aimed Shot always asks) while managing
its melee range and Armor, then finish it off fast once the head breaks.

## Relationship to other systems

- **Called in directly by [Proctor](../proctor/).** A Proctor detecting a live target or evidence
  in a zone that has a Securus placed will route it toward the alert location faster than the
  standard zone-wide broadcast — see
  [`../../design-choices/detection-and-network-alert.md`](../../design-choices/detection-and-network-alert.md).
  This is the pairing that gives Proctor its threat: it's not dangerous itself, but it's the thing
  that turns a manageable fight into a Securus fight.
- **EMP is still worth bringing**, just not a full answer on its own, unlike against every other
  Cerberus unit — reinforces Heavy Weapons/Support loadouts needing a real plan (cover management,
  Aimed Shot commitment, EMP timing) rather than one dominant tool.
- Drops **Salvage** on destruction like the rest of the roster (no injury state), likely at a
  premium rate given its elite billing — exact amount deferred alongside the rest of the faction's
  Salvage economy (GDD Section 12, item 7).

## Alpha implementation

[`scripts/securus_unit.gd`](../../../../../../scripts/securus_unit.gd) +
[`scenes/securus_unit.tscn`](../../../../../../scenes/securus_unit.tscn). Map glyph `J`.

| | |
|---|---|
| HP / Armor | 26 / 6 — the thickest plate in either roster |
| Attack | Melee only: 60 accuracy, 12 damage. No ranged weapon at all |
| Movement | 3 tiles per AP, `move_speed` 2.6 — slow, but it walks the whole way |
| Head | `head_hp` 12; once broken, `broken_head_damage_mult` 1.75 on every subsequent hit |
| EMP | `emp_stun_duration_mult` 0.5 — half the roster's window |
| Salvage | 8 |

**The head.** `apply_body_part_damage` is the hook, which `Unit.fire_at` calls for an Aimed
Shot and nothing else — so a snap shot cannot touch the pool even on a crit, exactly as
designed. It takes the **raw** damage roll: armor is subtracted for HP and not for the head,
because a weak point covered by the unit's own plating is not a weak point. Two committed
Aimed Shots break it at typical rifle damage; after that, ordinary gunfire finally works.

**Breach** takes one tier off the cover between it and its target on the way in, reusing the
existing degradation rule (`GridManager.damage_cover_edge`) rather than adding a second
destruction path — so heavy goes to light and light goes to nothing. Stated against Sagittarii:
that one shoots *through* light cover, this one removes cover outright. Hunkering behind a
crate is an answer to one and an invitation to the other.

## Open items

- Exact head-HP threshold, bonus-damage multiplier once broken, and EMP stun-duration reduction —
  deferred to playtesting, same posture as the rest of the faction's numeric tuning.
- Exact HP/Armor numbers, and how many Securus units a single encounter can reasonably place
  before it stops feeling like an elite fight and starts feeling like an attrition fight — the
  faction's "no reinforcement economy" design intent (see main faction README) argues for keeping
  this number small (two, maybe three at most), but not locked in.
- Breach-vs-cover specifics (does it destroy cover outright in one hit, or apply bonus damage to
  cover HP the way Sagittarii's weapon does to unit Armor) — needs to be decided alongside
  Sagittarii's own open Light-Cover-penalty-reduction number, since both are cover-interaction
  levers on the same underlying system.
