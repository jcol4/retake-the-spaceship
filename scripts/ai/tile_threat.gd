class_name TileThreat
extends RefCounted
## Overwatch-lane awareness (docs/design/factions/rival-mercs/README.md Sec 5).
## A merc's movement-tile scoring reads which of its own hostiles are holding an
## angle right now, and treats a tile one of them covers as EXPENSIVE ground —
## not impassable, since sometimes crossing a covered lane is the least-bad
## option, but a plan that avoids it should almost always outscore one that
## doesn't.
##
## Scoped to MOVEMENT actions only (`Flank`, `RepositionToCover` today), and
## deliberately not to `Attack`/`Suppress`: `TurnManager.check_overwatch` fires
## from `Unit.move_along` per tile crossed, never on a unit that holds still to
## shoot, so a stationary shot was never the thing an overwatch reservation
## threatens in the first place.
##
## Not yet wired into `Advance` — it walks a single shortest path toward the
## target (`GridManager.find_path`) rather than choosing among candidate
## destinations the way `Flank`/`RepositionToCover` already do, and there is no
## cost-weighted pathfinder to route it around a covered tile instead of merely
## refusing to stop on one. Revisit if that gap turns out to matter in play.

## Every LIVING hostile of `unit` currently holding an overwatch reservation.
## `Unit.on_overwatch` is a plain, unhidden bool — nothing has ever needed to
## ask about it before this, so there is no existing accessor to reuse.
## `Unit.hostiles()` already filters to the living, so no `is_downed` check is
## needed here on top of it.
static func watchers(unit: Unit) -> Array[Unit]:
	var out: Array[Unit] = []
	for hostile: Unit in unit.hostiles():
		if hostile.on_overwatch:
			out.append(hostile)
	return out


## Whether ANY of `watcher_list` threatens `tile` — asked of the tile itself,
## not of wherever a watcher's current target stands, since an overwatch shot
## fires on whoever walks into the covered angle, not on one pre-decided unit.
##
## Explicit world points via `GridManager.has_clear_line`, the same pattern
## `Flank._best_tile` already uses to test a CANDIDATE tile's line to the
## target — `GridManager.has_line_of_sight` only works from a unit's OWN
## current position, which is no help for "would this tile I have not moved to
## yet be seen".
static func is_covered(tile: Vector3i, watcher_list: Array[Unit]) -> bool:
	if watcher_list.is_empty():
		return false
	var to := GridManager.grid_to_world(tile) + Vector3(0, 0.9, 0)
	for watcher: Unit in watcher_list:
		var from := GridManager.grid_to_world(watcher.grid_pos) + Vector3(0, 1.4, 0)
		if GridManager.has_clear_line(watcher, from, to):
			return true
	return false
