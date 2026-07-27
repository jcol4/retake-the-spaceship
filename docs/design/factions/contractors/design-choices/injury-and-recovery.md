# Injury, Not Permadeath

*Source: GDD Section 4.4.*

## The rule

Contractors who fall in battle are **downed/injured**, not permanently killed. Recovery is
**resource-based**: spending a medical resource (exact item/economy TBD) heals a soldier
instantly or accelerates recovery — not a passive timer, not automatic free healing.

## Why resource-based rather than a timer or free healing

The GDD frames this directly as a meta-game design choice: it keeps emotional stakes without
classic *XCOM*-style permadeath (Section 2's "forgiving, not punishing" pillar), while still
giving the meta-game (Section 7) something to manage. A free/automatic recovery would remove the
stakes entirely — losing a soldier would cost nothing. A pure timer removes player agency — you'd
just wait. Tying it to a spendable resource keeps a real cost (the resource) and a real choice
(spend it now vs. save it) without resorting to permanent loss, which is the actual design
target: *tactical* cost (a mission without your best gunner) without *permanent* cost.

## Why this only applies to contractors

Neither enemy faction has an equivalent state:

- Aliens are simply killed — there is no alien-side economy to protect, since the player isn't
  meant to feel bad about losing an alien.
- [Cerberus Applied Sciences](../../security-robots/) units are destroyed outright and drop Salvage (see
  [`../../security-robots/design-choices/armor-and-destruction.md`](../../security-robots/design-choices/armor-and-destruction.md))
  — deliberately the *inverse* framing: contractors losing a unit costs a resource to fix,
  robots losing a unit *grants* one. This is meant to reinforce, mechanically, which side of a
  fight the player is meant to feel bad about being on.

## Open items (GDD Section 12, item 7)

- What the medical resource is called.
- How it's earned and spent — this should likely be designed alongside the security-robot
  faction's proposed Salvage resource, since both are meta-layer resources that will probably
  share the same between-missions spending screen (Section 7).
