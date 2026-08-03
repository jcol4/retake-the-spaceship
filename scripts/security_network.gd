extends Node
## Autoload. The Cerberus security net: zone-scoped alert propagation, the sound
## channel both factions share, the evidence a Proctor scans for, and the Salvage
## a destroyed robot leaves behind.
##
## Design: docs/design/factions/security-robots/design-choices/detection-and-network-alert.md
##
## Deliberately NOT a unit registry. Robots are found through the
## "cerberus_units" group, the same way every other cross-unit query in the
## project works, so a unit that spawns, is destroyed or is freed needs no
## bookkeeping here and nothing can hold a dangling reference.

## Fired when a broadcast goes out, so the HUD (or, later, an audio bus) can play
## the network chirp the faction's audio direction asks for — the player's cue
## that a zone-wide alert just tripped, rather than a silent UI change.
signal alert_broadcast(zone: int, at: Vector3i, priority: bool)
signal salvage_changed(total: int)

## Sec 5.4's alert radius. Gunfire is the one detection channel the aliens and
## the robots share, which is what keeps "stay quiet" a universally useful
## strategy instead of a counter to exactly one faction.
const NOISE_RADIUS := 5

## Things a fight leaves lying around. Only a Proctor reads these — every other
## robot detects what is happening *now* (motion and sound), and this is the one
## channel that punishes a mess made ten turns ago.
enum Evidence { BRASS, CORPSE, WRECKED_COVER }

const EVIDENCE_NAME := {
	Evidence.BRASS: "spent brass",
	Evidence.CORPSE: "a body",
	Evidence.WRECKED_COVER: "shot-up cover",
}

## Zone id meaning "not assigned to any security zone". A robot left on it
## broadcasts to nobody and hears nobody — which is the right behaviour for one
## dropped onto a deck with no room graph, not a crash.
const NO_ZONE := -1

var salvage: int = 0

## [{pos: Vector3i, kind: Evidence, found: bool}]. Never pruned during a mission:
## the whole point of the channel is that evidence outlives the event, so decay
## would have to be a designed number rather than a convenience.
var _evidence: Array = []


func _ready() -> void:
	# Wrecked cover is evidence, and the grid already announces it. Listening here
	# rather than making every shooter report it keeps the one caller that knows a
	# crate came apart the one that says so.
	GridManager.cover_destroyed.connect(_on_cover_destroyed)


## Clears mission-scoped state. Nothing calls this yet — there is no
## between-missions flow — but the alternative is an autoload that silently
## accumulates across a scene reload.
func reset() -> void:
	_evidence.clear()
	salvage = 0
	salvage_changed.emit(salvage)


# --- Alert propagation -------------------------------------------------------


## Rouses every robot registered to `zone`, wherever it is and whether or not it
## could have seen anything. This is the faction's central asymmetry: an alerted
## alien wakes its neighbours within a radius, an alerted robot wakes its zone.
##
## `priority` is a Proctor's targeted call-in. It routes the same broadcast but
## flags it, so units that answer priority traffic first (Securus) can tell the
## two apart. It never spawns anything — a zone with no Securus in it has nothing
## for a Proctor to call in.
func broadcast(zone: int, at: Vector3i, priority: bool = false, except: Node = null) -> int:
	if zone == NO_ZONE:
		return 0
	var reached := 0
	for node in get_tree().get_nodes_in_group("cerberus_units"):
		if node == except or node.is_downed or node.security_zone != zone:
			continue
		if node.receive_broadcast(at, priority):
			reached += 1
	alert_broadcast.emit(zone, at, priority)
	return reached


## A gunshot, an explosion, or anything else loud. Reaches robots by distance
## rather than by zone — sound does not travel over the network, it travels
## through the deck — and, unlike sight, does not care about line of sight.
func report_noise(at: Vector3i, source: Node = null, radius: int = NOISE_RADIUS) -> void:
	for node in get_tree().get_nodes_in_group("cerberus_units"):
		if node == source or node.is_downed:
			continue
		if GridManager.chebyshev_dist(node.grid_pos, at) <= radius:
			node.hear_noise(at)


# --- Evidence ----------------------------------------------------------------


## Flags a tile as carrying something that does not belong. Cheap enough to call
## from any system that makes a mess; nothing reads it until a Proctor walks past.
func report_evidence(pos: Vector3i, kind: Evidence) -> void:
	for entry: Dictionary in _evidence:
		if entry["pos"] == pos and entry["kind"] == kind and not entry["found"]:
			return  # one pile of brass per tile, not one per round fired
	_evidence.append({"pos": pos, "kind": kind, "found": false})


## Unfound evidence within `radius` of `pos`, marked found as it is returned.
##
## Marking on read is deliberate: a Proctor that reports the same corpse every
## activation would keep a zone permanently alerted off one kill, which is a
## nag rather than a threat.
func scan_evidence(pos: Vector3i, radius: int) -> Array:
	var out: Array = []
	for entry: Dictionary in _evidence:
		if entry["found"]:
			continue
		if GridManager.chebyshev_dist(entry["pos"], pos) > radius:
			continue
		entry["found"] = true
		out.append(entry)
	return out


func evidence_name(kind: int) -> String:
	return EVIDENCE_NAME.get(kind, "something")


func _on_cover_destroyed(pos: Vector3i, _side: int, _now: int) -> void:
	report_evidence(pos, Evidence.WRECKED_COVER)


# --- Salvage -----------------------------------------------------------------


## A destroyed robot is gone for good — there is no injury state to recover from,
## since it was never on the player's side. Salvage is what makes clearing one
## worth the ammunition it costs. What it BUYS is deliberately unspecified: that
## belongs with the medical-resource economy (GDD Sec 12 item 7), which does not
## exist yet either, and the two will share a screen.
func add_salvage(amount: int) -> void:
	salvage += amount
	salvage_changed.emit(salvage)
