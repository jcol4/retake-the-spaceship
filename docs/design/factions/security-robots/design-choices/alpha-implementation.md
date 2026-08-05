# Alpha Implementation

*Written 2026-07-31, alongside the build. The rest of this folder says what the faction **is**;
this file says what the code currently **does**, where the two differ, and why.*

The faction was designed on paper first and built afterwards, which means most of this document
is a map rather than a set of new decisions. Where the build had to decide something the design
left open, it is called out as a decision with its reasoning, not slipped in as detail.

---

## 1. Design → file

| Design | Where it lives |
|---|---|
| Base robot: light exception, motion + sound detection, network alert, Armor, EMP, Standing Post, no injury state | [`scripts/cerberus_unit.gd`](../../../../../scripts/cerberus_unit.gd) |
| The network itself: zone broadcast, sound channel, evidence log, Salvage tally | [`scripts/security_network.gd`](../../../../../scripts/security_network.gd) (autoload `SecurityNetwork`) |
| QRN-4 Auxilium — overwatch at a post, leashed | [`scripts/auxilium_unit.gd`](../../../../../scripts/auxilium_unit.gd) |
| MKV-9 Sagittarii — slow advance, partial light-cover ignoring | [`scripts/sagittarii_unit.gd`](../../../../../scripts/sagittarii_unit.gd) |
| XVT-7 Proctor — evidence scan, priority call-in, broadcast-then-withdraw | [`scripts/proctor_unit.gd`](../../../../../scripts/proctor_unit.gd) |
| JXM-2 Securus — melee, breach, head weak point, EMP resistance | [`scripts/securus_unit.gd`](../../../../../scripts/securus_unit.gd) |
| Roster stats and per-model weapons | [`scripts/cerberus_presets.gd`](../../../../../scripts/cerberus_presets.gd) |
| Per-model armor, leash, salvage, EMP resistance, silhouette | `scenes/{auxilium,sagittarii,proctor,securus}_unit.tscn` |
| EMP grenade (the player's side of it) | [`scripts/player_unit.gd`](../../../../../scripts/player_unit.gd) — `Mode.EMP` and `_try_throw_emp` |
| The rules, as executable checks | [`tools/test_cerberus.gd`](../../../../../tools/test_cerberus.gd) |

`CerberusUnit` extends `EnemyUnit` rather than `Unit`: the awareness state machine, the ranged
combat loop and the target bookkeeping are faction-neutral, and
[`ai-behavior.md`](ai-behavior.md) already said to reuse them. Four things are overridden, and
they are exactly the four axes the faction README lists as its identity.

## 2. How the rules landed

**Light.** `Combat.compute_accuracy` drops the Section 6.5 light term entirely for any roll
where either side is light-agnostic. The design specifies the `Unit vs CerberusUnit` half; the
build made it **symmetric**, because a sensor package that cannot be blinded cannot be blinded
when it is the one shooting either — and a one-directional rule would let a player hide in the
dark from a machine that demonstrably does not see that way.

**Motion.** Detection range is split in two: `detection_range` for a target that moved within
the last turn, `motionless_detection_range` for one holding still. This is the robot-facing
equivalent of the flashlight decision — the one stealth lever that still works against the
faction — and it is why `Unit` now records `last_moved_turn`.

**Sound** is implemented for this faction only, matching the docs: the aliens' sound channel is
still deferred. `Unit.fire_at` reports every shot to `SecurityNetwork.report_noise`, radius 5,
no line-of-sight test. Throwing an EMP grenade reports it too — the grenade bypasses armor, not
the fact that an explosion is loud.

**Evidence** is a flat list on the autoload, written by three existing systems (a shot leaves
brass, a death leaves a body, `GridManager.cover_destroyed` leaves wrecked cover) and read only
by a Proctor. Entries are **consumed on read**, so one corpse cannot re-alert a zone every
activation, and are never pruned, because the channel's whole point is that evidence outlives
the event.

**Armor** is a flat reduction inside `Unit.take_damage`, which now returns what actually landed
so the combat log can report the real figure and name the absorption: `HIT for 8 dmg (-8 armor)`.
A player who cannot see the plate eating half the shot has no way to work out that the EMP
grenade in their kit is the answer. Two build decisions here:

- **A floor of 1 damage** gets through any plate. Without it, a weapon whose damage is at or
  below a unit's Armor does literally nothing, and the SMG stops being a weapon rather than
  becoming a poor choice.
- **Armor does not protect a component pool.** Securus's head takes the raw roll. A weak point
  covered by the unit's own plating is not a weak point.

**EMP** is a real action, not just a receiving end: 1 AP, range 6, 3×3 burst, one charge per
soldier, armed from the HUD and thrown at a tile. A robot in the burst loses its next
activation(s) and reads Armor 0 for the window. One charge per soldier is the balance
statement — enough to open a window on a fight's hardest target, not enough to answer every
armored unit on a deck, so positioning stays the plan and EMP stays what rescues it.

**Salvage** accrues on `SecurityNetwork`. What it buys is still unspecified, exactly as
[`armor-and-destruction.md`](armor-and-destruction.md) leaves it — that belongs with the
medical-resource economy the two will share a screen with.

## 3. The two places the build approximates the design

Both are honest gaps rather than oversights, and both are cheap to close later.

### Zones are one compartment, not a cluster of them

The design asks for a zone **coarser** than a room — "everything behind one checkpoint". The
alpha derives it as one compartment plus its doorways (`MapBuilder.zone_at`), which is a
compartment exactly.

The reason is that the room graph cannot express anything between the two. Rooms are derived,
not authored (`MapData.compute_rooms`), and every room on a deck connects to every other
through corridors — so unioning rooms across their links collapses the whole level into a
single zone, and one tripped sentry alerts the map. That is the failure
[`detection-and-network-alert.md`](detection-and-network-alert.md) explicitly argues against.
Given a choice between too coarse and too fine, too fine is the recoverable one.

Closing it needs no code: `CerberusUnit.security_zone` is exported, so an authored level can
already assign zones by hand, and `MapBuilder.zone_at` is only the default.

### Robots are hostile to the squad, not to everyone

See the faction README's open items. The blocker is on the alien side, not this one.

## 4. Putting robots on a deck

One glyph per model, taken from the first letter of the **model code** rather than of the name
— the names collide with glyphs already spoken for (`S` is the swarm, `s` is a stair), the
codes do not:

| Glyph | Model |
|---|---|
| `Q` | QRN-4 Auxilium |
| `M` | MKV-9 Sagittarii |
| `X` | XVT-7 Proctor |
| `J` | JXM-2 Securus |

Zone assignment, stats and scene selection all follow from the glyph; nothing else has to be
authored. [`maps/test_deck.txt`](../../../../../maps/test_deck.txt) places one of each in the
middle compartment, which makes that deck a genuine three-way skirmish — squad, infestation and
security net, all on one floor — and is what `test_cerberus.gd` runs against.

## 5. Art

Placeholder only, drawn in code like every other character (see
[`../../../../presentation-direction.md`](../../../../presentation-direction.md) §2). `UnitVisual`
gained a `machine` placeholder style for this faction: rectangles only — no discs, no taper,
nothing rounded — against the organic set's warmer, dirtier palette, so the two factions are
told apart by silhouette and colour in a dark corridor at ~15% of viewport height, which is
where and how most of this game is read.

Each model owns a proportion rather than just a colour: a squat armored post, a wide weapons
platform, a small hovering drone, and something a head taller than a soldier.

The **status light** from [`faction-identity.md`](faction-identity.md) is implemented as a
sprite layer (`status`) that `CerberusUnit` recolours per alert state — green at post, amber
alerted, red in combat, blue while EMP has it down. It is deliberately **exempt from the tile
light tint** (`UnitVisual.SELF_LIT_LAYERS`): a status light is the thing emitting, and dimming
it in a dark room would put out the one readability aid the faction has in exactly the
conditions it exists for.

The audible network chirp is **not** implemented — the game has no audio at all yet. The
broadcast is announced in the combat log instead, and `SecurityNetwork.alert_broadcast` is the
signal an audio bus would hang off.
