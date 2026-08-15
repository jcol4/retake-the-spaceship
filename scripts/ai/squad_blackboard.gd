class_name SquadBlackboard
extends RefCounted
## Per-squad shared intent. The thing the whole GOAP framework exists to buy:
## a unit checks here before committing to a role, so two units never
## independently decide to be the flanker.
## Design: docs/design/systems/coordinated-ai/
##
## CLAIMS OUTLIVE ACTIVATIONS, and that is forced by the initiative pool rather
## than chosen. Units are drawn ONE AT A TIME from a shared random pool
## (TurnManager) — there is no squad turn — so a merc that suppresses and its
## ally that flanks are separate draws with anything at all in between: the
## player's whole squad, an alien, three other mercs. A claim that expired at the
## end of its owner's activation would therefore never once be read by the ally
## it was meant for, and the coordination would be decoration.
##
## The cost of that is staleness, so every claim is REVALIDATED when its owner is
## next drawn (`revalidate`), and dropped the moment its reason stops holding.
## Coordination degrades gracefully when the draw order is unkind, which is the
## honest outcome: the pool is supposed to be able to spoil a plan.

## One entry per (squad, role) — the intents units negotiate over.
enum Role { SUPPRESSOR, FLANKER, COVER_BREAKER, ADVANCER }

## Turns a claim may go unrefreshed before it is treated as abandoned.
##
## A backstop, not the main release path — the four explicit releases in
## `revalidate` catch every case anyone has thought of, and this catches the ones
## nobody has. Two full turns, so a claim survives an unlucky draw order but not
## an owner that has quietly stopped pursuing it.
const CLAIM_STALE_TURNS := 2

## Role -> claim. A claim is a Dictionary rather than a class because it is pure
## data that crosses no boundary: {owner, target, tile, turn}.
var _claims: Dictionary = {}
## Squad-wide facts written as a side effect of what units DO, read by planners
## as preconditions. The `ally_is_engaging_target` route by which Fodder feeds
## Agile Hunter without Fodder itself ever coordinating (doc Sec 5.3).
var _facts: Dictionary = {}
## Unit -> Role, written by `SquadCoordinator` before anybody acts (fix D).
##
## Distinct from a CLAIM, and the distinction matters: an assignment is what the
## squad thinks this unit should try, decided while everyone is still standing
## still; a claim is what a unit has actually committed to while acting. Merging
## them would fire a suppressor's bark on a turn it might never be drawn for.
var _assignments: Dictionary = {}
var assigned_on_turn: int = -1


## Whether `role` is free for `claimant` to take. True when nobody holds it, or
## when the holder is this unit already — re-claiming your own role is a refresh,
## not a conflict.
func can_claim(role: Role, claimant: Unit) -> bool:
	var claim: Dictionary = _claims.get(role, {})
	if claim.is_empty():
		return true
	return claim.get("owner") == claimant


## Takes `role` for `claimant`, or refreshes it if already held by them. Returns
## false when somebody else holds it — the caller must then plan something else,
## which is the entire point of the blackboard.
func claim(role: Role, claimant: Unit, target: Unit = null, tile: Vector3i = Vector3i.ZERO) -> bool:
	if not can_claim(role, claimant):
		return false
	var previous = _claims.get(role, {}).get("owner")
	# Read BEFORE the write, so a flanker claiming while somebody already holds
	# the suppressor role can answer that fire rather than narrate itself.
	var responding := holder(Role.SUPPRESSOR) != null and role != Role.SUPPRESSOR
	_claims[role] = {
		"owner": claimant, "target": target, "tile": tile,
		"turn": TurnManager.turn_number,
	}
	# Only on a CHANGE of holder. Re-claiming your own role is a refresh — that is
	# deliberate, or a unit would lose its role by continuing to pursue it — so
	# barking on every claim would have a suppressor announce itself once per turn
	# for as long as it kept firing.
	if previous != claimant:
		_announce(role, claimant, target, responding)
	return true


## Says the thing out loud. Routed through the claim itself rather than through
## each action, because this is the one place a role is ever taken: a bark fired
## from here cannot drift out of step with what the unit actually did, and no new
## action can forget to announce itself.
func _announce(role: Role, claimant: Unit, target: Unit, responding: bool) -> void:
	var text := Barks.line(
		claimant.faction, role, claimant.stats.display_name,
		target.stats.display_name if is_instance_valid(target) else "them",
		responding)
	if text != "":
		claimant.report_action(text)


func release(role: Role, claimant: Unit) -> void:
	var claim: Dictionary = _claims.get(role, {})
	if claim.get("owner") == claimant:
		_claims.erase(role)


## Drops every claim held by `unit` — one call for "this unit died", "this unit
## lost its target", or "this unit finished".
func release_all(unit: Unit) -> void:
	for role: Role in _claims.keys():
		if _claims[role].get("owner") == unit:
			_claims.erase(role)


func holder(role: Role) -> Unit:
	var owner = _claims.get(role, {}).get("owner")
	return owner if is_instance_valid(owner) else null


func claimed_tile(role: Role) -> Vector3i:
	return _claims.get(role, {}).get("tile", Vector3i.ZERO)


## Whether any live claim already spoken for this tile. Stops two units flanking
## onto the same square, which reads as one unit's plan simply failing.
func is_tile_claimed(tile: Vector3i, by_other_than: Unit = null) -> bool:
	for role: Role in _claims:
		var claim: Dictionary = _claims[role]
		if claim.get("owner") == by_other_than:
			continue
		if claim.get("tile", Vector3i.ZERO) == tile:
			return true
	return false


## Sweeps out claims whose reason has stopped holding. Called at the top of every
## planning unit's activation, which is what keeps a claim honest without needing
## a signal wired to every way it can die.
##
## Four release conditions, and they fail differently — a dangling claim on a
## dead unit blocks a role permanently, a claim on a dead TARGET makes an ally
## flank an empty room, and a stale one does both quietly.
func revalidate() -> void:
	for role: Role in _claims.keys():
		var claim: Dictionary = _claims[role]
		var owner = claim.get("owner")
		var target = claim.get("target")
		if not is_instance_valid(owner) or owner.is_downed:
			_claims.erase(role)
			continue
		if target != null and (not is_instance_valid(target) or target.is_downed):
			_claims.erase(role)
			continue
		if TurnManager.turn_number - int(claim.get("turn", 0)) > CLAIM_STALE_TURNS:
			_claims.erase(role)


func assign(unit: Unit, role: Role) -> void:
	_assignments[unit] = role


func clear_assignments() -> void:
	_assignments.clear()


## The role the squad wants `unit` to attempt, or -1 for none.
##
## ADVISORY. A unit that cannot carry out its assignment falls back to its own
## doctrine ranking rather than doing nothing — which is what makes the whole
## scheme safe under the initiative pool, where an assignment may be several
## draws stale by the time its owner is finally drawn.
func assignment_for(unit: Unit) -> int:
	return _assignments.get(unit, -1)


func set_fact(key: StringName, value: Variant) -> void:
	_facts[key] = value


func fact(key: StringName, fallback: Variant = false) -> Variant:
	return _facts.get(key, fallback)


func clear_facts() -> void:
	_facts.clear()


## Human-readable dump of live claims. Required by the prototype's acceptance
## criteria — role negotiation that cannot be inspected cannot be debugged, since
## the only on-screen difference between "coordinated" and "got lucky" is nothing
## at all.
func describe() -> String:
	if _claims.is_empty():
		return "no claims"
	var parts: Array[String] = []
	for role: Role in _claims:
		var claim: Dictionary = _claims[role]
		var owner = claim.get("owner")
		var target = claim.get("target")
		parts.append("%s=%s%s" % [
			Role.keys()[role],
			owner.stats.display_name if is_instance_valid(owner) else "?",
			" -> %s" % target.stats.display_name if is_instance_valid(target) else "",
		])
	return ", ".join(parts)
