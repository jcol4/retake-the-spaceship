# Armor, EMP, and Destruction (no injury state)

## Armor as a distinct layer from Cover

Cerberus units carry a personal **Armor** value in addition to normal HP, layered *underneath*
the existing cover system rather than replacing it:

- **Cover (GDD Section 6.1)** still applies normally — Heavy/Light cover penalties, flanking
  (6.2), destructible cover HP (6.1.1) all work identically against a robot standing behind
  cover.
- **Armor** is a flat damage *reduction* applied after the accuracy roll succeeds, at the point
  damage is dealt — conceptually similar to how Luck's crit/dodge phases (Section 4.6.4) resolve
  after the accuracy formula rather than inside it. A shot that hits a heavily-armored Sagittarii
  does less raw damage than the same shot would do to an unarmored Fodder, independent of cover
  or lighting.
- **Why layer it instead of just giving robots more HP:** flat armor makes weapon choice matter
  in a way raw HP doesn't — the GDD already sets up "cover-breaker" bonus damage for grenades and
  Heavy Weapons against cover objects (6.1.1); giving robots an armor stat lets the same
  itemization idea apply to *units*, not just cover, without inventing a new number type. A
  future "armor-piercing" weapon mod or Heavy Weapons bonus vs. Armor is a natural, cheap
  extension of a system the GDD already has half-built.

## EMP as the counter-lever

Every faction needs a lever the player can pull that the enemy is specifically weak to — for
aliens it's darkness/light (Agile Hunter, GDD 11.5); for Cerberus units it's **EMP**:

- An EMP grenade (parallel item slot to the existing frag grenade, GDD Section 4.2's Throw
  Grenade action) deals no direct damage to organic units but applies a **stun/disable** status
  to any Cerberus unit in its radius — skipped from the initiative pool for its next draw, and
  its Armor value is treated as 0 for the duration (so a follow-up shot bypasses the armor layer
  entirely).
- This gives Heavy Weapons/Support-leaning loadouts (GDD Section 4.5) a reason to bring EMP into
  a robot-heavy mission the same way they'd bring frags into an alien-heavy one — the two
  factions reward slightly different loadout choices without changing the base action economy.
- [Sagittarii](../units/sagittarii/) is the primary EMP target on the standard roster: disabling
  its Armor for a turn is the intended answer to a unit that's otherwise too tanky to burn down
  efficiently with normal weapons fire.

### [Securus](../units/securus/) is only partially susceptible

Every other Cerberus unit resolves an EMP hit identically (full stun duration, Armor zeroed for
that duration). Securus is the one deliberate exception: it takes the same stun/Armor-zero effect,
but for a **shorter duration** than the roster default. This is specifically an "elite" tell —
if EMP solved Securus exactly as cleanly as it solves Sagittarii, Securus would just be a bigger
Sagittarii with more HP. A narrower armor-bypass window means a player still gets real value out
of an EMP grenade against it, but can't rely on the same "EMP then dump ammo" sequence they'd use
on the rest of the roster without also planning for the window closing faster than expected.

## No injury state — destroyed outright, drops Salvage

Where a downed player soldier is injured and recoverable via a medical resource (GDD Section
4.4), a destroyed Cerberus unit is simply gone — there's no equivalent "recover a robot" concept,
since it was never on the player's side. Instead, destroying one drops **Salvage**, a resource
parallel to (but distinct from) the medical-resource economy referenced in GDD Section 12 item 7:

- **Why give it a drop at all, rather than nothing:** without some payoff, a heavily-armored
  robot is pure friction — more HP/Armor to burn through for no benefit beyond mission completion.
  Salvage gives the player a reason to actually want a robot-heavy mission on the mission-pool
  selection screen (GDD Section 7), rather than universally preferring alien-only missions
  because they're cheaper to clear.
- **Exact economy (what Salvage buys, how much drops per unit) is intentionally left open** —
  this should be designed alongside the medical-resource economy (Section 12, item 7) once that's
  settled, since the two resources will likely share the same between-missions spending screen.

## Securus's head: a component-HP weak point, using the existing Aimed Shot system

Securus does not get a bespoke targeting mechanic — it reuses the **Aimed Shot** action (2 AP,
VATS-style body-part selection) already defined in
[`../../contractors/design-choices/action-economy.md`](../../contractors/design-choices/action-economy.md)
and implemented in `Combat.BodyPart`/`ZONE_ACCURACY_MOD` (`HEAD: -50` relative to full-aim). What's
new is unique to Securus, not to the action:

- Securus carries a separate **head-HP pool**, distinct from its main Armor/HP. Only damage from
  an Aimed Shot targeting `BodyPart.HEAD` that connects reduces this pool — a Shoot (snap-shot) or
  an Aimed Shot to any other zone never touches it, even if it happens to land a crit.
- Once head-HP hits 0, the head **breaks off**. This isn't cosmetic: while broken, Securus takes
  **major bonus damage** on all subsequent hits, to any zone, for the rest of the fight — the
  intended read is a two-phase fight, "grind through the head" then "finish it off fast," instead
  of one flat damage-sponge phase from start to end.
- **Why gate it behind Aimed Shot specifically, rather than any headshot/crit:** the existing
  Aimed Shot design already frames the head zone as "low-odds, high-payoff" via its -50 accuracy
  (see `action-economy.md`'s "Shoot vs. Aimed Shot" section) — Securus's weak point is a direct
  payoff for a choice the game already asks the player to make, rather than a new decision layered
  on top. It also keeps the mechanic legible: the player always knows *when* they're contributing
  to breaking the head, because it's tied to an explicit action choice, not an invisible RNG roll.
- This is currently Securus-exclusive. Whether component HP generalizes to other zones (e.g. a
  crippled leg reducing movement) on Securus or any other unit is an open item, not proposed here.

## Interaction with the accuracy formula

No change to GDD Section 6.5's formula itself — Armor is applied as a post-roll damage reduction,
not an accuracy modifier, so it doesn't stack with or replace Cover/Elevation/Light/Hunker Down.
This keeps the existing formula authoritative for "did the shot land," and gives Armor a single,
easy-to-reason-about job: "how much did it hurt."
