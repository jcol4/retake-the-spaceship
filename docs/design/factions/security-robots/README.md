# Faction: Security Robots

> ## ⚙️ ALPHA IMPLEMENTED 2026-07-31
>
> **All four roster models are in code and playable.** The faction was designed on paper first
> (everything below), then built; where the build had to choose, the choices and their reasons
> are recorded in
> [`design-choices/alpha-implementation.md`](design-choices/alpha-implementation.md), which is
> also the design → file map.
>
> | In code | Still on paper |
> |---|---|
> | All four units, their AI, the light exception, motion + sound detection, evidence scanning, zone-wide network alert, Armor, the EMP grenade, Securus's head weak point, Salvage on destruction | Hostility toward the aliens (robots currently engage the squad only — see [Open items](#open-items)), authored multi-room zones, silent takedowns, what Salvage buys |
>
> Numbers live in [`scripts/cerberus_presets.gd`](../../../../scripts/cerberus_presets.gd) and
> on the unit scenes, and are alpha values in exactly the sense this document already meant:
> tunable, not final. `tools/test_cerberus.gd` pins the *rules* rather than the numbers, so
> retuning a stat does not break a test.
>
> The faction is **not yet folded into `game-design-document.md`**, which still describes a
> single enemy faction in Section 11. This folder remains the source of truth for it.

*Everything in this folder was written to slot into the existing systems (initiative pool,
additive accuracy formula, light/sound detection, cover/elevation) without requiring new core
mechanics. Treat numeric values here the same way the GDD treats its own defaults: tunable, not
final.*

## Identity

**Cerberus Applied Sciences**, the automated shipboard security line the vessel was already running before
it went derelict. When the crew evacuated (or stopped responding), the ship's security network
didn't power down — it defaulted to its base lockdown protocol: *treat all unauthorized movement
as an intrusion.* It doesn't know or care that the crew is gone, that aliens have moved in, or
that the contractors clearing the ship are trying to help. It just enforces the same rule it
always has, against everyone.

That framing gives the faction a reason to exist alongside the aliens without needing new lore
machinery: on a mission where both factions are present, Cerberus units will engage aliens and
contractors alike, since both read as "unauthorized" to a lockdown-mode security net. This also
gives a level designer a knob independent of the GDD's existing mission structure (Section 7): a
mission can feature aliens only, robots only, or both as a genuine three-way skirmish, without
changing any core rule.

## Why a second faction, and why *this* faction

The GDD's single existing pillar most worth building a second faction around is **"light is a
weapon and a liability"** (Section 2) — but that pillar is currently only tested from one
direction: darkness helps the player hide, and helps the [Agile Hunter](../aliens/units/agile-hunter/)
ambush. A faction that is **unaffected by light** creates the missing case: an enemy where
turning your flashlight off buys you nothing, forcing the player to actually read the difference
between "I'm fighting something that uses light against me" and "I'm fighting something that
doesn't care." See
[`design-choices/detection-and-network-alert.md`](design-choices/detection-and-network-alert.md).

## Mechanical identity (how it differs from `aliens`)

| Axis | Aliens | Security Robots |
|---|---|---|
| Detection | Light + sound, same rules as the player | Sound + motion only, **plus** a third channel robots alone have: passive scanning for environmental evidence (see [Proctor](units/proctor/)); **light value has no effect on detection or accuracy against them** |
| Alert propagation | Local, room/nest-scoped | **Ship/zone-wide**, over the security network |
| "Downed" state | Injured, recoverable (GDD 4.4) | **Destroyed outright** — no injury state, but drops [Salvage](design-choices/armor-and-destruction.md) |
| Cover interaction | Standard (GDD 6.1–6.2) | Standard, **plus** an armor layer that flattens some of it (see below) |
| Weakness lever | Darkness (Agile Hunter's ambush) | **EMP** (grenades) — though [Securus](units/securus/) is only partially susceptible |
| Reinforcement pattern | Local nest spawns over time | No respawns; alerted units converge from across the zone, or are called in directly by a Proctor |

This is the design intent in one line: **aliens are a lighting puzzle, security robots are a
positioning-and-EMP puzzle.** A mission mixing both factions forces the player to hold two
different mental models at once — extending the game's existing "manage a continuous resource"
pillar into a second axis instead of just adding a reskinned enemy.

## Roster (v1 proposal)

| Type | Speed | Toughness | Grouping | Core Role |
|---|---|---|---|---|
| [Auxilium](units/auxilium/) | Stationary/slow patrol | Moderate, armored | Solo per post | Overwatch anchor — the Fodder-equivalent choke point |
| [Sagittarii](units/sagittarii/) | Slow, heavy | Very tanky | Solo | Ranged, cover-ignoring pressure — the "big threat" unit |
| [Proctor](units/proctor/) | Hovering, ignores terrain movement cost | Fragile, avoids combat | Solo patrol | Detector — flags evidence and spotted targets, calls in nearby units |
| [Securus](units/securus/) | Slow, heavy, walking | Very tanky, partially EMP-resistant | Solo or multiple | Elite melee/breach — the roster's mini-boss-tier threat |

*Interceptor and Warden were cut from the v1 roster — see [Open items](#open-items).*

## Design choices

- [`design-choices/faction-identity.md`](design-choices/faction-identity.md) — lore framing and
  why it stays lightweight.
- [`design-choices/detection-and-network-alert.md`](design-choices/detection-and-network-alert.md)
  — sensor-based detection and ship-wide alert propagation, and why both are the deliberate
  inverse of the alien faction's rules.
- [`design-choices/armor-and-destruction.md`](design-choices/armor-and-destruction.md) — the
  Armor stat, EMP as the counter-lever, no-injury/Salvage-on-destroy, and how this interacts with
  the existing cover/accuracy formula (GDD Section 6.5).
- [`design-choices/ai-behavior.md`](design-choices/ai-behavior.md) — how the state machine model
  from the alien faction is reused, and where it diverges (no Unaware/patrol-and-forget state;
  robots default to a standing post instead).
- [`design-choices/alpha-implementation.md`](design-choices/alpha-implementation.md) — what the
  alpha build actually does, which design → which file, the two places the implementation
  approximates a rule rather than honouring it, and how to put robots on a deck.

## Open items

- Exact HP/Armor/damage numbers — deferred to playtesting, same posture as the GDD's own combat
  numbers (Section 12).
- Whether Cerberus units should ever treat aliens as allies-of-convenience (e.g. ignore them
  entirely) rather than hostile — current proposal is "hostile to everyone," which is simpler to
  implement and avoids needing three-way faction relationship logic in `TurnManager`.
  **Not in the alpha**, and deliberately so: robots acquire player units only. Making them
  shoot aliens is a two-line change to target acquisition, but the aliens have no way to shoot
  *back* at a robot, so a three-way deck would resolve as robots farming an inert faction while
  the player watched. The prerequisite is alien-side hostility, not this side of it.
- Whether missions can be "robots only" as a distinct mission type, or robots are always layered
  onto an existing alien clear-out. Leaning toward supporting both, but no mission-type work has
  been scoped for this yet.
- **Interceptor and Warden were removed from the roster.** Both were cut for redundancy reasons
  raised in review: Interceptor's "fast, fragile, closes distance" niche overlapped too closely
  with Securus once Securus existed, and Warden's "fragile, non-combat, kill-to-degrade-the-zone"
  niche overlapped with Proctor's. Neither concept is dead — if the roster needs a fast
  disruptor or a passive buff-hub again later, revisit these rather than inventing a fifth/sixth
  new unit from scratch.
