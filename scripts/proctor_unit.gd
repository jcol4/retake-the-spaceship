class_name ProctorUnit
extends CerberusUnit
## XVT-7 Proctor — the faction's detector.
## Design: docs/design/factions/security-robots/units/proctor/
##
## The only unit in either faction with a *delayed, indirect* detection channel.
## Every other channel in the game — the player's, the aliens', the rest of this
## roster's — fires on something happening right now. Proctor's evidence scan
## fires on something that happened, which is what makes cleaning up after a
## fight a real strategy rather than a flavour preference.
##
## It does not fight. On finding anything it broadcasts and pulls back, and a
## Proctor that stayed to shoot would have failed at its actual job. That is why
## its combat loop is a retreat: giving it usable stats would blur it into the
## Auxilium's chokepoint role and cost the roster its one non-combat unit.

## Radius in tiles the evidence sweep covers, once per activation. No line of
## sight is required — the whole point is that the evidence outlived whatever
## made it, and so did the reason to look.
@export var evidence_scan_radius: int = 4


func _ready() -> void:
	super()
	avoids_combat = true
	ignores_terrain_move_cost = true  # hovers; see CerberusUnit for why this is inert today


func take_turn() -> void:
	# Scan first, so a Proctor that finds a corpse reports it on the same
	# activation rather than a turn late. Runs before the base state machine
	# because the broadcast it produces should also be able to alert *itself*.
	if emp_turns <= 0 and not is_downed:
		_scan_for_evidence()
	await super()


func _scan_for_evidence() -> void:
	var found := SecurityNetwork.scan_evidence(grid_pos, evidence_scan_radius)
	if found.is_empty():
		return
	var first: Dictionary = found[0]
	action_logged.emit("%s scans %s at %s — zone %d flagged compromised" % [
		stats.display_name, SecurityNetwork.evidence_name(first["kind"]), first["pos"], security_zone,
	])
	SecurityNetwork.broadcast(security_zone, first["pos"], true, self)
	rouse(first["pos"])


## Priority traffic, not the standard zone sweep. Mechanically this is the same
## broadcast with a flag on it — it does NOT spawn anything. A zone with no
## Securus placed in it has nothing for a Proctor to call in, which is the lever
## level authoring actually has over how dangerous a Proctor is.
func _propagate_alert() -> void:
	var reached := SecurityNetwork.broadcast(security_zone, last_known_pos, true, self)
	if reached > 0:
		action_logged.emit("%s calls in heavy units to %s — %d respond" % [
			stats.display_name, last_known_pos, reached,
		])


## Replaces the ranged loop wholesale: report, then get out. Never fires, never
## closes, never trades — the value it protects is its own continued existence.
func _combat_turn() -> void:
	var quarry := acquire_target()
	if quarry == null:
		return
	action_logged.emit("%s has eyes on %s and is falling back" % [
		stats.display_name, quarry.stats.display_name,
	])
	while ap > 0 and not is_downed:
		if not await _withdraw_from(quarry):
			ap = 0  # cornered: nowhere further to go, so stop burning AP on it
			return


## Moves to the reachable tile furthest from `threat`. Returns false when
## standing still is already the best available answer.
func _withdraw_from(threat: Unit) -> bool:
	var budget := _move_budget()
	var best := grid_pos
	var best_dist := GridManager.chebyshev_dist(grid_pos, threat.grid_pos)
	for tile in GridManager.get_reachable_tiles(grid_pos, budget):
		var d := GridManager.chebyshev_dist(tile, threat.grid_pos)
		if d > best_dist:
			best_dist = d
			best = tile
	if best == grid_pos:
		return false
	var path := GridManager.find_path(grid_pos, best, budget)
	if path.is_empty():
		return false
	spend_ap(1)
	await move_along(path)
	return true
