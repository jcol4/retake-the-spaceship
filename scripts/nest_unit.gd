class_name NestUnit
extends EnemyUnit
## A spawn nest, Sec 11.7. Design:
## docs/design/factions/aliens/design-choices/spawn-nests.md
##
## FINISHED in extraction plan 3.3: it has HP and can be destroyed (the Destroy
## objective, Contract.Type.DESTROY), it spawns one alien every SPAWN_INTERVAL
## rounds from the 70/20/10 table into a free tile beside it, and its death is
## reported to AlienHivemind as the ship-wide escalation trigger the design ranks
## first. On an extraction map a living nest is a slow clock on lingering (GDD
## §11.7): every few rounds there is one more thing between the squad and the
## ship.
##
## WHY IT IS A UNIT AND NOT A PROP. `CoverObject` is the other obvious base --
## a StaticBody3D whose HP GridManager owns -- and it was the wrong one. A nest
## needs a rendered, animated, eight-facing sprite, a name label, a hit
## reaction, and a place in the damage system that already prices every shot on
## the board. `Unit` has all of that; `CoverObject` has none of it and would
## have meant reimplementing the sprite pipeline for one prop. The cost is that
## a nest is drawn from the turn pool like anything else, which `take_turn`
## below answers: its activation IS its spawn clock.
##
## It extends `EnemyUnit` rather than `Unit` for the faction plumbing (alert
## state, the room-graph hooks, the action log), not for the senses -- see
## `take_turn`.

## GDD §11.7: one unit every 3 rounds while alive. Counted in the nest's own
## activations, which is one per round — it is in the pool every round it lives
## and never loses a turn (no senses to stun, nothing it does costs AP).
const SPAWN_INTERVAL := 3

## What a nest can produce. SPITTER is in the table because the design's table
## has it; it is not built (GDD §11.6), so `roll_spawn_kind` resolves it through
## BUILT_FALLBACK — plan 3.3: "fall back to a Fodder roll for its 20%".
enum SpawnKind { FODDER, SPITTER, HUNTER }

## [kind, weight in percent] — GDD §11.7: 70% Fodder / 20% Spitter / 10% Agile Hunter.
const SPAWN_TABLE := [
	[SpawnKind.FODDER, 70],
	[SpawnKind.SPITTER, 20],
	[SpawnKind.HUNTER, 10],
]

## Unbuilt kinds and what spawns in their place. Delete an entry when the unit
## lands and its share of the table goes live.
const BUILT_FALLBACK := {SpawnKind.SPITTER: SpawnKind.FODDER}

const FODDER_SCENE_PATH := "res://scenes/swarm_unit.tscn"
const HUNTER_SCENE_PATH := "res://scenes/agile_hunter_unit.tscn"

## Activations taken since the nest was placed. The spawn lands on every
## SPAWN_INTERVAL-th, so the first comes at the end of round 3 — the squad gets
## a couple of rounds before the clock first bites.
var activations := 0
## How many it has produced, for naming the spawn (node names must agree across
## peers — see `_spawn_at`).
var spawned := 0


func _ready() -> void:
	super()
	# Sec 6 trigger 1 of the escalation design: destroying a nest stops the
	# bleeding but risks waking the deck. `died` is host-side (only the host runs
	# `die`), so this escalates once, where the AI lives.
	died.connect(_on_nest_died)


## Spawns on its schedule, and otherwise passes without looking.
##
## Deliberately does NOT call `super()`. `EnemyUnit.take_turn` opens with
## `_look_for_targets`, and a nest has no senses at all: it does not see, hear,
## feel footsteps, acquire, alert or propagate. It is a thing that sits in a
## room and bleeds aliens until someone kills it, and the moment it can notice
## a squad it stops reading as scenery and starts reading as a monster that
## forgot to attack.
func take_turn() -> void:
	activations += 1
	if activations % SPAWN_INTERVAL != 0:
		return
	var tile := free_spawn_tile()
	if tile == NO_SPAWN_TILE:
		action_logged.emit("%s heaves, but there is no room beside it" % stats.display_name)
		return
	spawn_unit(roll_spawn_kind(), tile)


## One draw from SPAWN_TABLE, with unbuilt kinds resolved to what spawns instead.
## Rolls the global RNG (or `rng`), so a seeded caller gets a repeatable answer.
static func roll_spawn_kind(rng: RandomNumberGenerator = null) -> SpawnKind:
	var total := 0
	for entry: Array in SPAWN_TABLE:
		total += entry[1]
	var roll := rng.randi_range(0, total - 1) if rng != null else randi_range(0, total - 1)
	var kind: SpawnKind = SPAWN_TABLE[-1][0]
	for entry: Array in SPAWN_TABLE:
		roll -= entry[1]
		if roll < 0:
			kind = entry[0]
			break
	return BUILT_FALLBACK.get(kind, kind)


const NO_SPAWN_TILE := Vector3i(-99999, -99999, -99999)


## The first free tile beside the nest, in GridManager.STEPS order (cardinals,
## then diagonals) so every peer and every test agrees which; NO_SPAWN_TILE when
## the nest is boxed in. Movement-adjacent only — a spawn never appears on the far
## side of a wall corner.
func free_spawn_tile() -> Vector3i:
	for n in GridManager.neighbors(grid_pos):
		if n.y == grid_pos.y and GridManager.is_free(n):
			return n
	return NO_SPAWN_TILE


## Host: brings one `kind` into the world on `tile`, and tells the clients to do
## the same. The node name and a stat seed are picked HERE and sent along: names
## because every RPC and synchronizer addresses a unit by path, the seed because
## AlienPresets rolls stats off the global RNG and the client's copy must roll
## the same body (the worm's shed uses the same name-first pattern).
func spawn_unit(kind: SpawnKind, tile: Vector3i) -> Unit:
	spawned += 1
	var node_name := "%s_spawn_%d" % [name, spawned]
	var stat_seed := randi()
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		_rpc_spawn.rpc(node_name, int(kind), tile, stat_seed)
	var unit := _spawn_at(node_name, kind, tile, stat_seed)
	if unit != null:
		action_logged.emit("%s spawns a %s" % [stats.display_name,
			"Fodder" if kind == SpawnKind.FODDER else "Hunter"])
	return unit


@rpc("authority", "call_remote", "reliable")
func _rpc_spawn(node_name: String, kind: int, tile: Vector3i, stat_seed: int) -> void:
	_spawn_at(node_name, kind, tile, stat_seed)


func _spawn_at(node_name: String, kind: int, tile: Vector3i, stat_seed: int) -> Unit:
	var scene := load(HUNTER_SCENE_PATH if kind == SpawnKind.HUNTER else FODDER_SCENE_PATH) as PackedScene
	if scene == null:
		return null
	var unit: Unit = scene.instantiate()
	unit.name = node_name
	seed(stat_seed)
	var label := "%s'%s" % [stats.display_name, node_name.get_slice("_spawn_", 1)]
	unit.stats = AlienPresets.hunter(label) if kind == SpawnKind.HUNTER else AlienPresets.swarm(label)
	unit.position = GridManager.grid_to_world(tile)
	get_parent().add_child(unit)
	# Same reasoning as the worm's shed: the combat log is wired per unit by
	# whoever spawned the first ones, and a spawn has no such sponsor.
	for connection in action_logged.get_connections():
		unit.action_logged.connect(connection["callable"])
	return unit


func _on_nest_died(_unit: Unit) -> void:
	AlienHivemind.report_nest_destroyed(grid_pos)
