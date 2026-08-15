# Spawn Nests

*Source: GDD Section 11.7, implementation scaffold Section 11.8.*

## What it is

A destructible mission objective (HP-bearing object) that continuously spawns Fodder while
undestroyed, giving clear-out missions a source of escalating pressure and a clear "stop the
bleeding" objective beyond just killing what's currently on the field.

| Property | Value |
|---|---|
| HP | 50 |
| Spawn rate | 1 unit every 3 turns, if undestroyed |
| Spawn table | 70% [Fodder](../units/fodder/) / 20% [Spitter](../units/spitter/) / 10% [Agile Hunter](../units/agile-hunter/) |

*(All tunable defaults — escalation-over-time is not currently planned; spawn rate is constant
until the nest is destroyed.)*

## Why a flat spawn rate, not escalation

Keeping the rate constant rather than ramping it over time keeps the objective's math legible to
the player: "every 3 turns this thing produces roughly one Fodder-weighted spawn" is something a
player can plan around and race against. An escalating rate would make the correct play
timing-sensitive in a way that's hard to communicate without a visible countdown UI, which isn't
in scope per Section 12.

## Why the spawn table skews so heavily to Fodder

70/20/10 keeps the nest's output aligned with each type's designed role: Fodder is the
attrition/numbers unit (GDD Section 11.4), so it should be what a nest mostly produces. Spitter
and Agile Hunter spawning less often keeps them feeling like distinct threats when they do show
up, rather than diluting the roster into a uniform mix.

## Implementation

`Nest` node/scene: HP, spawn timer (3-turn interval), spawn table (70/20/10 weighted), spawns
into a valid unoccupied/passable tile (Section 10.7); removed from the spawn population at 0 HP.
Win condition for clear-out missions requires destroying all nests in the target area, not just
clearing units currently on the field (Section 7.1).

## Open items

- Exact bonus-damage multiplier for grenades/Heavy Weapons against cover doesn't apply to nests
  directly, but nest HP interacts with the same damage system — no nest-specific damage rules are
  defined yet beyond its flat 50 HP. **That 50 predates the lethality rescale**
  (`../../contractors/design-choices/ap-and-stat-baselines.md` §6.0) and was never repriced with the
  rest of the board, because no Nest exists to reprice. Read literally it is now roughly *twice the
  toughest unit in the game* — so whoever builds the Nest picks a number against the current scale
  rather than porting this one across.
