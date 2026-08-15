# Action Economy

*Source: GDD Section 4.2 (Action Points), 4.3 (Ammo & Reload).*

> ⚠️ **The 2 AP TABLE below is SUPERSEDED** (2026-08-10) by
> [`ap-and-stat-baselines.md`](ap-and-stat-baselines.md). AP is a granular per-soldier pool
> (`floor(6 + 0.075 × Fitness)`), movement costs 1 AP per tile, and the actions below cost a 6–10 AP
> base discounted by Reflexes. Only movement was left unscaled, so the bigger pool buys **distance,
> not extra actions** — a second shot still costs a soldier its whole activation. Read that document
> for the live numbers and for the lethality rescale that came with them (~20 HP soldiers, two or
> three hits to kill, crits at 1.5×). This one is kept for the
> *reasoning*, most of which survives the change and some of which the change directly contradicts.
> Each section below says which.

## 2 AP per activation

| Action | AP Cost | Effect |
|---|---|---|
| Run | 1 AP | Move up to half movement range |
| Sprint | 2 AP | Move up to full movement range |
| Shoot | 1 AP | Fire at an accuracy penalty (snap shot) |
| Aimed Shot | 2 AP | VATS-style: pick a body-part zone, fire at that zone's own accuracy |
| Throw Grenade | 1 AP | Throw at a target location |
| Hunker Down | 1 AP, ends activation | Improve own Cover stat until next activation |
| Overwatch | 1 AP, ends activation | Reserve action, at a significant accuracy penalty; interrupts the pool to fire when an enemy enters LOS |
| Reload | 1 AP | Refill magazine |

Flashlight toggle is a **separate free action (0 AP)**, usable alongside any of the above.

## Why 2 AP, and why this specific menu

> **This is the section the rework CONTRADICTS**, and it is worth being blunt about rather than
> quietly deleting. The argument below is that a small memorisable budget serves the "tactical, not
> twitchy" pillar. The rework accepts a higher bookkeeping cost in exchange for a stat system whose
> levers do not overlap and an AI currency fine enough to score actions against — and it lists
> "is the granularity itself too much" as an explicit playtest check. If that check comes back badly,
> the argument below is the case for reverting, already written down.

Two points per turn keeps the decision space small enough to reason about quickly (Run+Shoot,
Aimed Shot alone, Sprint alone, Run+Overwatch, etc.) without needing a deep action-point economy —
consistent with the "tactical, not twitchy" pillar (Section 2): the interesting decision is
*which pair of actions*, not managing a large point budget. Every action costs either 1 or 2,
which means the menu of viable combinations per turn is small and mostly memorizable, which
matters for a game whose other core system (the initiative pool) already asks the player to
track state across many units' turns.

## Shoot vs. Aimed Shot as the central per-turn choice

> **Survives, and sharpens.** Aimed Shot now also costs more AP *per zone* (Torso 5, limbs 6, Head 7
> before the Reflexes discount), so the choice is priced in two currencies rather than one — and the
> stat-dependence argued below gets stronger, since Reflexes discounts a snap shot nearly three times
> as hard as it discounts an Aimed Shot.

This is the game's clearest embodiment of "deliberate, timing-focused decisions" (Section 2):
Shoot lets a soldier move-and-shoot in one activation at a penalty; Aimed Shot trades the ability
to also move for a VATS-style pick of *which body part* to hit, each with its own accuracy and its
own consequence (Section 4.2.1 of the GDD) — a reliable torso hit, a punishing-but-crippling limb
shot, or a low-odds, high-payoff headshot. Reflexes only helps Shoot (Section 4.6.2), so which
action is "correct" for a given soldier is partly a function of their own stats, not just the
tactical situation — a high-Reflexes Assault gets comparatively more value from Shoot than a
Sniper would.

## Ammo/Reload as the counterweight to Aimed Shot

Fixed magazine sizes (Section 4.3) mean Aimed Shot's payoff isn't free within a single engagement —
burning through ammo faster forces Reload (1 AP) more often, which is itself a full action that
can't also move or shoot. This is the mechanism that keeps "just always Aimed Shot" from being a
dominant strategy at the activation level: it's locally better per-shot, but globally more
expensive in activations spent reloading. Magazine size varies by **weapon**, not class (Battle
Rifle and Assault Rifle 3, Shotgun and LMG 6, SMG 4 — see [`../weapons/`](../weapons/)), so this
tradeoff lands differently depending on the soldier's loadout rather than being fixed by class.

**Reload also now draws from a finite per-mission reserve**, not an unlimited pool — see
[`../weapons/`](../weapons/#ammo-model). Each weapon's total ammo (mag size + reserve) is a fixed
mission-length budget: 24 for the SMG down to 15 for the Battle Rifle. This adds a second,
longer-horizon version of the same Aimed-Shot-vs.-Shoot tension: even a weapon a soldier never
actually reloads *mid-fight* can still run out over the course of a full mission, and once both the
loaded mag and the reserve hit zero, that soldier has no ranged options (Shoot/Aimed Shot/Overwatch
all require ammo) for the rest of it — no emergency reserve, no resupply.

## Overwatch as the pool's one interrupt

> **Survives, with the price replaced.** Overwatch no longer costs 1 AP — it commits a *variable
> reserve* of whatever the unit has left. Everything the section argues still holds: it is still the
> one interrupt, still enemy-movement-only, still terminal, and still paid for with a significant
> accuracy penalty. The flat −30% is now a placeholder for a penalty that scales with the amount
> reserved, which is the open item that motivated making the reserve a number at all.

Overwatch (1 AP) is the single action that breaks the normal draw order, and only in one
direction: it lets a unit interrupt the pool to fire when an *enemy* enters its LOS, but never
triggers off allied movement. Its cost dropped from 2 AP to 1 specifically so it can *follow* a
first action in the same activation — Run+Overwatch, Shoot+Overwatch — but it is **terminal**: it
ends the activation whatever AP is left, so it can never be the first half of a pair. That
convenience is paid for twice over, with a significant flat accuracy penalty on the reserved shot
— a snap reaction, not a lined-up aim. This is what makes holding a position a genuine tactical choice against a fast-closing enemy —
see how it's specifically called out as the counter to the
[Agile Hunter](../../aliens/units/agile-hunter/)'s ambush — without letting the player chain
Overwatches into a way to bypass the pool's turn order entirely for their whole squad for free,
since it still costs a real AP and lands meaningfully less reliably than choosing to Shoot outright.
