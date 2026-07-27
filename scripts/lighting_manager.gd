extends Node
## Autoload. Computes per-tile light_value (Sec 5) from static fixtures
## (LightSource) and unit flashlights, writing the combined result into
## GridTileData.light_value. Recomputed on relevant triggers only — move,
## flashlight toggle, turn start — never every frame (same policy as LOS,
## Sec 10.6).
##
## Split into two layers so a flashlight moving doesn't require re-walking
## every static fixture on the map:
##   base    — static fixtures only; changes only at load and on flicker.
##   dynamic — flashlights only; changes whenever a unit moves/turns/toggles.

## Emitted once per recompute, after every tile's light_value is settled.
## Detection listens to this (Sec 11.2) — the lighting layer itself stays
## ignorant of the AI, and remains the only writer of light_value.
signal lighting_changed

const AMBIENT_FLOOR := 0.0  # tiles no source reaches are pitch dark (Sec 5.3)
const FLASHLIGHT_RANGE := 6.0  # tiles (Sec 5.2)
const FLASHLIGHT_CONE_DEGREES := 90.0  # Sec 5.2
const FLASHLIGHT_INTENSITY := 75.0  # 0-100 contribution at zero distance

var _sources: Array[LightSource] = []
var _base: Dictionary = {}  # Vector3i -> float, static fixtures only
# The dynamic layer, kept rather than summed away, because "is a flashlight on
# this tile" is a different question from "is this tile lit" and detection needs
# the former: an alien standing under an overhead fixture must not read as
# spotted. Aliens set has_flashlight false, so this layer is only ever player
# beams — a non-zero value here means a player is deliberately lighting the tile.
var _dynamic: Dictionary = {}  # Vector3i -> float, flashlights only
var _dynamic_source: Dictionary = {}  # Vector3i -> Unit, whose beam is brightest


func register_source(source: LightSource) -> void:
	_sources.append(source)


func unregister_source(source: LightSource) -> void:
	_sources.erase(source)


func recompute_base() -> void:
	# Static fixtures only. Call once at map load and again whenever a
	# flickering light rerolls.
	_base.clear()
	for pos in GridManager.tiles.keys():
		var total := AMBIENT_FLOOR
		for source in _sources:
			total += _contribution(source, pos)
		_base[pos] = total
	recompute_dynamic()


func reroll_flicker() -> void:
	# Sec 5.3 — called on turn start. Only sources flagged to flicker change;
	# skip the full base recompute if nothing actually did.
	var any_flicker := false
	for source in _sources:
		if source.flickers:
			source.reroll_flicker()
			any_flicker = true
	if any_flicker:
		recompute_base()


func recompute_dynamic() -> void:
	# Flashlights only. Called often (every step of a move), so each unit only
	# walks tiles within its own flashlight range rather than the whole map.
	_dynamic.clear()
	_dynamic_source.clear()
	for unit: Unit in _flashlight_units():
		var facing: Vector3 = -unit.global_transform.basis.z
		for pos in GridManager.tiles.keys():
			if GridManager.chebyshev_dist(unit.grid_pos, pos) > FLASHLIGHT_RANGE:
				continue
			var t: GridTileData = GridManager.get_tile(pos)
			if not _within_cone(unit.global_position, facing, t.world_pos, FLASHLIGHT_CONE_DEGREES):
				continue
			var c := _falloff(unit.grid_pos, pos, FLASHLIGHT_INTENSITY, FLASHLIGHT_RANGE)
			if c <= 0.0:
				continue
			if not GridManager.has_clear_line(unit, unit.global_position + Vector3(0, 1.2, 0), t.world_pos + Vector3(0, 0.5, 0)):
				continue
			# Brightest beam wins the tile, and owns it for detection purposes —
			# whoever is lighting a tile hardest is who gets noticed standing on it.
			if c > _dynamic.get(pos, 0.0):
				_dynamic[pos] = c
				_dynamic_source[pos] = unit
	for pos in GridManager.tiles.keys():
		var t: GridTileData = GridManager.get_tile(pos)
		t.light_value = clampf(_base.get(pos, AMBIENT_FLOOR) + _dynamic.get(pos, 0.0), 0.0, 100.0)
	lighting_changed.emit()


func flashlight_value(pos: Vector3i) -> float:
	# Flashlight contribution only, deliberately excluding static fixtures — see
	# the note on _dynamic. Aggro reads this, accuracy reads tile.light_value.
	return _dynamic.get(pos, 0.0)


func flashlight_source(pos: Vector3i) -> Unit:
	# Which unit's beam is lighting this tile, or null if none is.
	return _dynamic_source.get(pos)


func _flashlight_units() -> Array[Unit]:
	var out: Array[Unit] = []
	for node in get_tree().get_nodes_in_group("units"):
		var unit := node as Unit
		if unit and not unit.is_downed and unit.has_flashlight and unit.flashlight_on:
			out.append(unit)
	return out


func _contribution(source: LightSource, tile_pos: Vector3i) -> float:
	var c := _falloff(source.grid_pos, tile_pos, source.current_intensity(), source.light_range)
	if c <= 0.0:
		return 0.0
	var t: GridTileData = GridManager.get_tile(tile_pos)
	if not GridManager.has_clear_line(source, source.global_position, t.world_pos + Vector3(0, 0.9, 0)):
		return 0.0
	return c


func _falloff(from_pos: Vector3i, to_pos: Vector3i, intensity: float, max_range: float) -> float:
	# Linear falloff — full intensity at the source, zero at max_range.
	var dist := GridManager.chebyshev_dist(from_pos, to_pos)
	if dist > max_range:
		return 0.0
	return intensity * (1.0 - float(dist) / max_range)


func _within_cone(from: Vector3, facing: Vector3, to: Vector3, cone_degrees: float) -> bool:
	if cone_degrees >= 360.0:
		return true
	var dir := to - from
	dir.y = 0.0
	if dir.length() < 0.001:
		return true  # the source's own tile
	var facing_flat := Vector3(facing.x, 0.0, facing.z).normalized()
	return facing_flat.dot(dir.normalized()) >= cos(deg_to_rad(cone_degrees / 2.0))
