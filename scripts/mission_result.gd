class_name MissionResult
extends RefCounted
## How a mission ended, and with what. Carried by `TurnManager.mission_ended`.
##
## Replaces a `player_won: bool`, which could only say "everything hostile is
## down" or "the squad is". Extraction (GDD §7) ends missions in ways a boolean
## cannot hold: the squad got out but left two soldiers behind, got out without
## the objective, got out with loot — and the campaign (extraction plan Phase 4)
## needs every one of those facts to settle the debrief and the economy.
##
## Plain data, no autoload references, so a --script headless tool can load() it.
## Built by whoever ends the mission (TurnManager for a wipe or a clear-out, the
## ExtractionManager of extraction plan Phase 1 for a departure) and handed to
## `TurnManager.end_mission`.

## EXTRACTED  the ship left with at least one soldier aboard (GDD §7.4).
## WIPED      no soldier left standing and none extracted.
## ABANDONED  the mission was cut off from outside it — in co-op, the host
##            disconnected (main.gd `_on_host_left`). Not a loss: nothing was
##            decided, so the campaign must not book it as one.
## CLEARED    the legacy "all hostiles down" win, which only exists while
##            `TurnManager.clear_out_mode` is on (hand-authored test decks with no
##            hangar to extract from). Kept as its own outcome rather than folded
##            into EXTRACTED so nothing downstream mistakes a test-deck sweep for
##            a real departure.
##
## APPEND-ONLY: the value crosses the wire as an int (see `to_dict`).
enum Outcome { EXTRACTED, WIPED, ABANDONED, CLEARED }

const _OUTCOME_TEXT := {
	Outcome.EXTRACTED: "EXTRACTED",
	Outcome.WIPED: "FAILED — squad wiped",
	Outcome.ABANDONED: "ABANDONED",
	Outcome.CLEARED: "WON — all hostiles down",
}

var outcome: Outcome = Outcome.WIPED

## Soldiers who left aboard the ship. For CLEARED, the soldiers still standing:
## with nothing left on the deck there is nothing to extract FROM, and they are
## the ones who make it home.
##
## INCLUDES carried corpses (GDD §4.4: a body carried out "recovers everything
## they had"), which is why it is not the list of who survived — that is
## `survivors()`. A corpse here is ALSO in `recovered_corpses`, so a reader can
## tell "came home" from "was brought home".
var extracted_units: Array[Unit] = []

## The dead among `extracted_units`: corpses carried aboard (extraction plan 2.3).
## Their soldier is gone from the roster, but the body and its gear came back —
## Phase 4 credits the gear, and the debrief names them as recovered rather than
## as lost. Always a subset of `extracted_units`, never of `lost_units`.
var recovered_corpses: Array[Unit] = []

## Soldiers who did not make it out: dead, or downed and left behind (GDD §4.4 —
## a downed soldier not carried aboard is lost with the deck).
var lost_units: Array[Unit] = []

## Whether the mission's objective (GDD §7.5) was met. True for CLEARED, where
## killing everything WAS the objective.
var objective_complete: bool = false

## What was carried out (extraction plan 3.3): one entry per extracted unit with
## anything in its pack, `{"unit": node path, "name": display name, "items":
## Array[String] of ItemPresets codes}` — built by `manifest_for`. Every element is
## RPC-serialisable (strings, never an Object), because the array crosses the wire
## as-is in `to_dict`. A recovered corpse's entry includes its converted gear
## (Unit._stow_gear_as_items), so Phase 4 credits a carried-out body's kit from
## here. Price a code with ItemPresets.value_of; rebuild one with from_code.
var loot: Array = []

## The mission's contract as `Contract.to_dict()` ({} if there was none), so the
## debrief can say what the objective was and Phase 4 can pay `payout` when
## `objective_complete`.
var contract: Dictionary = {}

## Rival merc crews that flew out during this mission (extraction plan Phase 8),
## one wire-safe entry per lift: `{"crew": int, "aboard": int, "stranded": int,
## "items": Array[String] of codes, "turn": int}` (ExtractionManager.rival_report,
## attached by TurnManager.end_mission for every outcome). Intel for the debrief:
## what got away, never anything the player is paid or charged for.
var rivals: Array = []


func _init(p_outcome: Outcome = Outcome.WIPED) -> void:
	outcome = p_outcome


## Whether the squad got out — EXTRACTED or CLEARED. Says nothing about the
## objective or the casualties; read those fields for the debrief.
func is_success() -> bool:
	return outcome == Outcome.EXTRACTED or outcome == Outcome.CLEARED


## The extracted soldiers who are alive: `extracted_units` minus the recovered
## corpses. A downed soldier carried (or lying) aboard is alive — bleeding stops
## on extraction (GDD §4.4).
func survivors() -> Array[Unit]:
	var out: Array[Unit] = []
	for unit in extracted_units:
		if not recovered_corpses.has(unit):
			out.append(unit)
	return out


## Whether `unit` came home as a body rather than a soldier.
func is_recovered_corpse(unit: Unit) -> bool:
	return recovered_corpses.has(unit)


## The `loot` manifest for `units`: each one's pack, as codes. Units with an empty
## pack are left out. Units must be in the tree (paths), like `to_dict`.
static func manifest_for(units: Array) -> Array:
	var out: Array = []
	for unit in units:
		if not (unit is Unit) or not is_instance_valid(unit) or unit.inventory.is_empty():
			continue
		out.append({
			"unit": String(unit.get_path()) if unit.is_inside_tree() else "",
			"name": unit.stats.display_name,
			"items": Array(unit.inventory_codes.duplicate()),
		})
	return out


## Every item code carried out, flattened across `loot`.
func loot_codes() -> Array[String]:
	var out: Array[String] = []
	for entry in loot:
		for code in (entry as Dictionary).get("items", []):
			out.append(String(code))
	return out


## One line for the log and the end-of-mission banner.
func describe() -> String:
	return _OUTCOME_TEXT[outcome]


## One debrief line per rival lift (`rivals`), e.g. "A rival crew flew out at
## round 18: 2 aboard with 5 item(s), 1 stranded on the deck."
func rival_lines() -> Array[String]:
	var out: Array[String] = []
	for entry: Dictionary in rivals:
		var items: Array = entry.get("items", [])
		var line := "A rival crew flew out at round %d: %d aboard with %d item(s)" % [
			int(entry.get("turn", 0)), int(entry.get("aboard", 0)), items.size()]
		var stranded := int(entry.get("stranded", 0))
		if stranded > 0:
			line += ", %d stranded on the deck" % stranded
		out.append(line + ".")
	return out


## The form that crosses the wire to clients (`TurnManager._rpc_mission_ended`).
## A RefCounted cannot be an RPC argument, so it goes as a Dictionary, and units
## go as node paths — valid on every peer because every unit is named
## deterministically at spawn (see main.gd `_spawn_and_start`).
##
## A unit must still be IN the tree when this is called, or its path is lost:
## whoever ends a mission builds and sends the result before freeing anything.
func to_dict() -> Dictionary:
	return {
		"outcome": int(outcome),
		"extracted": _paths(extracted_units),
		"lost": _paths(lost_units),
		"recovered_corpses": _paths(recovered_corpses),
		"objective_complete": objective_complete,
		"loot": loot.duplicate(true),
		"contract": contract.duplicate(true),
		"rivals": rivals.duplicate(true),
	}


## Rebuilds a result on the receiving peer. Paths resolve against `root` (the
## scene tree's root); one that no longer resolves is dropped rather than kept as
## a null, so every entry in the unit arrays is always a live Unit.
static func from_dict(data: Dictionary, root: Node) -> MissionResult:
	var result := MissionResult.new(data.get("outcome", Outcome.WIPED))
	result.extracted_units = _resolve(data.get("extracted", []), root)
	result.lost_units = _resolve(data.get("lost", []), root)
	result.recovered_corpses = _resolve(data.get("recovered_corpses", []), root)
	result.objective_complete = data.get("objective_complete", false)
	result.loot = (data.get("loot", []) as Array).duplicate(true)
	result.contract = (data.get("contract", {}) as Dictionary).duplicate(true)
	result.rivals = (data.get("rivals", []) as Array).duplicate(true)
	return result


static func _paths(units: Array[Unit]) -> Array[String]:
	var out: Array[String] = []
	for unit in units:
		if is_instance_valid(unit) and unit.is_inside_tree():
			out.append(String(unit.get_path()))
	return out


static func _resolve(paths: Array, root: Node) -> Array[Unit]:
	var out: Array[Unit] = []
	if root == null:
		return out
	for path in paths:
		var unit := root.get_node_or_null(NodePath(path)) as Unit
		if unit != null:
			out.append(unit)
	return out
