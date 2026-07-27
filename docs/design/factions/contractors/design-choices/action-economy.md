# Action Economy

*Source: GDD Section 4.2 (Action Points), 4.3 (Ammo & Reload).*

## 2 AP per activation

| Action | AP Cost | Effect |
|---|---|---|
| Run | 1 AP | Move up to half movement range |
| Sprint | 2 AP | Move up to full movement range |
| Shoot | 1 AP | Fire at an accuracy penalty (snap shot) |
| Aimed Shot | 2 AP | VATS-style: pick a body-part zone, fire at that zone's own accuracy |
| Throw Grenade | 1 AP | Throw at a target location |
| Hunker Down | 1 AP | Improve own Cover stat until next activation |
| Overwatch | 1 AP | Reserve action, at a significant accuracy penalty; interrupts the pool to fire when an enemy enters LOS |
| Reload | 1 AP | Refill magazine |

Flashlight toggle is a **separate free action (0 AP)**, usable alongside any of the above.

## Why 2 AP, and why this specific menu

Two points per turn keeps the decision space small enough to reason about quickly (Run+Shoot,
Aimed Shot alone, Sprint alone, Overwatch+something, etc.) without needing a deep action-point economy —
consistent with the "tactical, not twitchy" pillar (Section 2): the interesting decision is
*which pair of actions*, not managing a large point budget. Every action costs either 1 or 2,
which means the menu of viable combinations per turn is small and mostly memorizable, which
matters for a game whose other core system (the initiative pool) already asks the player to
track state across many units' turns.

## Shoot vs. Aimed Shot as the central per-turn choice

This is the game's clearest embodiment of "deliberate, timing-focused decisions" (Section 2):
Shoot lets a soldier move-and-shoot in one activation at a penalty; Aimed Shot trades the ability
to also move for a VATS-style pick of *which body part* to hit, each with its own accuracy and its
own consequence (Section 4.2.1 of the GDD) — a reliable torso hit, a punishing-but-crippling limb
shot, or a low-odds, high-payoff headshot. Reflexes only helps Shoot (Section 4.6.2), so which
action is "correct" for a given soldier is partly a function of their own stats, not just the
tactical situation — a high-Reflexes Assault gets comparatively more value from Shoot than a
Sniper would.

## Ammo/Reload as the counterweight to Aimed Shot

Fixed magazine sizes (Section 4.3) mean Aimed Shot's payoff isn't free over a whole mission —
burning through ammo faster forces Reload (1 AP) more often, which is itself a full action that
can't also move or shoot. This is the mechanism that keeps "just always Aimed Shot" from being a
dominant strategy: it's locally better per-shot, but globally more expensive in activations spent
reloading. Magazine size varies significantly by class (Sniper 4, Support 8, Heavy Weapons 10 in
current `ClassPresets` defaults — see each class's doc under [`../units/`](../units/)), so this
tradeoff lands differently per class by design.

## Overwatch as the pool's one interrupt

Overwatch (1 AP) is the single action that breaks the normal draw order, and only in one
direction: it lets a unit interrupt the pool to fire when an *enemy* enters its LOS, but never
triggers off allied movement. Its cost dropped from 2 AP to 1 specifically so it can be paired
with a second action in the same activation (e.g. Hunker+Overwatch), but that convenience is paid
for with a significant flat accuracy penalty on the reserved shot — a snap reaction, not a lined-up
aim. This is what makes holding a position a genuine tactical choice against a fast-closing enemy —
see how it's specifically called out as the counter to the
[Agile Hunter](../../aliens/units/agile-hunter/)'s ambush — without letting the player chain
Overwatches into a way to bypass the pool's turn order entirely for their whole squad for free,
since it still costs a real AP and lands meaningfully less reliably than choosing to Shoot outright.
