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
## The display-only layer changed (exploration plan B.12.1): what is DRAWN as
## lit moved during a tick's playback. Never emitted with `lighting_changed`,
## which is the rules' signal — nothing listening here may decide anything.
signal display_lighting_changed

## What a tile no fixture or beam reaches is worth, so the rules agree with the
## faint ambient the scene actually renders (main.tscn ambient_light_energy 0.2).
## At the old 0.0 the screen showed a legible room while Combat.light_modifier
## charged the full -30 for standing in it, which is exactly the divergence
## the barrel-mounted flashlight (unit_visual.gd) is aimed to prevent.
##
## Moved up with that ambient rather than pinned: the two are a pair, and the
## screen showing more than the rules admit is the failure this exists to avoid.
##
## EnemyUnit.sight_light_threshold (25.0) is the hard ceiling, not a guideline:
## at or above it an unlit tile stops hiding anyone and the whole stealth design
## goes with it. 12 keeps clear water under that. The cost is about 5 accuracy
## points against the old floor — Combat.light_modifier's -30 becomes -25.2.
const AMBIENT_FLOOR := 12.0
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
## Tick playback's display layer (plan B.12.1): Vector3i -> the brightest beam
## as DRAWN, each cast from where its model is mid-playback. Only the beams are
## kept: `display_light` adds the base on read, so a playback slot touches the
## beams' tiles rather than rebuilding every tile on the deck. Read only through
## `display_light`, and only while `_display_active`.
var _display_beams: Dictionary = {}
var _display_active := false


func register_source(source: LightSource) -> void:
	_sources.append(source)


func unregister_source(source: LightSource) -> void:
	_sources.erase(source)


func recompute_base() -> void:
	# Static fixtures only. Call once at map load and again whenever a
	# flickering light rerolls.
	_base.clear()
	var tiles: Dictionary = GridManager.tiles
	for pos: Vector3i in tiles:
		_base[pos] = AMBIENT_FLOOR
	# Each source over only the square its range can reach (Chebyshev, so every
	# floor) rather than every tile on the deck: a deck carries ~50 fixtures and
	# a source reaches ~6 tiles, so the all-pairs loop spent ~95% of its calls on
	# tiles out of range — ~22 ms of a 29 ms recompute on the demo deck, and it
	# scales with deck size. Same rays, and each tile still sums its sources in
	# `_sources` order, so the base is bit-for-bit what the all-pairs loop gave.
	var levels: int = GridManager._floors.size()
	for source in _sources:
		var reach := int(source.light_range)
		var span := 2 * reach + 1
		if span * span * levels >= tiles.size():
			for pos: Vector3i in tiles:  # a reach bigger than the deck
				_base[pos] += _contribution(source, pos)
			continue
		var origin: Vector3i = source.grid_pos
		for level: int in GridManager._floors:
			for dz in range(-reach, reach + 1):
				for dx in range(-reach, reach + 1):
					var pos := Vector3i(origin.x + dx, level, origin.z + dz)
					if tiles.has(pos):
						_base[pos] += _contribution(source, pos)
	_full_pass_needed = true  # every tile's base may have moved
	recompute_dynamic()


## Seeded, and off its own RNG rather than the global one, so co-op peers land
## on identical intensities: the host rolls `flicker_seed` and hands the same
## number to every client (TurnManager `_rpc_turn_started`). `_sources` is in
## map-build order, which is the same on every peer.
func reroll_flicker(flicker_seed: int) -> void:
	# Sec 5.3 — called on turn start. Only sources flagged to flicker change;
	# skip the full base recompute if nothing actually did.
	var rng := RandomNumberGenerator.new()
	rng.seed = flicker_seed
	var any_flicker := false
	for source in _sources:
		if source.flickers:
			source.reroll_flicker(rng)
			any_flicker = true
	if any_flicker:
		recompute_base()


func recompute_dynamic() -> void:
	# Flashlights only. Called often (every step of a move), so each unit only
	# walks tiles within its own flashlight range rather than the whole map.
	var previous := _dynamic
	_dynamic = {}
	_dynamic_source.clear()
	for unit: Unit in _flashlight_units():
		var beam := _beam_contribution(unit.grid_pos, unit.global_position, _aim_of(unit), unit)
		for pos: Vector3i in beam:
			# Brightest beam wins the tile, and owns it for detection purposes —
			# whoever is lighting a tile hardest is who gets noticed standing on it.
			if beam[pos] > _dynamic.get(pos, 0.0):
				_dynamic[pos] = beam[pos]
				_dynamic_source[pos] = unit
	# Off the beams, a tile's light is its base. So once a full pass has written
	# the base everywhere, only the tiles the last beams lit and the ones these
	# beams light can differ from it: a step rewrites ~100 tiles, not the deck
	# (2.5k on a generated one, ~1 ms of every lit step). A new base or a new
	# tile set takes the full pass again.
	var tiles: Dictionary = GridManager.tiles
	if _full_pass_needed or GridTileData.topology_version != _lit_topology:
		_full_pass_needed = false
		_lit_topology = GridTileData.topology_version
		for pos: Vector3i in tiles:
			_write_light(tiles, pos)
	else:
		for pos: Vector3i in previous:
			if not _dynamic.has(pos):
				_write_light(tiles, pos)
		for pos: Vector3i in _dynamic:
			_write_light(tiles, pos)
	lighting_changed.emit()


## Whether the next recompute must rewrite every tile (see recompute_dynamic):
## set by a new base, and the tile set it was written over.
var _full_pass_needed := true
var _lit_topology := -1


func _write_light(tiles: Dictionary, pos: Vector3i) -> void:
	var t: GridTileData = tiles.get(pos)
	if t:
		t.light_value = clampf(_base.get(pos, AMBIENT_FLOOR) + _dynamic.get(pos, 0.0), 0.0, 100.0)


## One beam's light, tile -> contribution, cast from `origin_tile` /
## `origin_pos` along `aim`. THE beam formula: the rules layer and the display
## layer both call it, so what is drawn lit and what counts as lit cannot drift.
func _beam_contribution(origin_tile: Vector3i, origin_pos: Vector3, aim: Vector3, unit: Node3D) -> Dictionary:
	var out := {}
	# Only the square the beam can reach, on every floor (Chebyshev range ignores
	# floors), rather than every tile on the deck — this runs on each step of a
	# lit walk and each slot of a playback.
	var reach := int(FLASHLIGHT_RANGE)
	var tiles: Dictionary = GridManager.tiles
	# `_within_cone`'s test with its per-beam parts worked out once, not per tile.
	var facing_flat := Vector3(aim.x, 0.0, aim.z).normalized()
	var eye := origin_pos + Vector3(0, 1.2, 0)
	for level: int in GridManager._floors:
		for dz in range(-reach, reach + 1):
			for dx in range(-reach, reach + 1):
				var pos := Vector3i(origin_tile.x + dx, level, origin_tile.z + dz)
				var t: GridTileData = tiles.get(pos)
				if t == null:
					continue
				var dir := t.world_pos - origin_pos
				dir.y = 0.0
				if dir.length() >= 0.001 and facing_flat.dot(dir.normalized()) < _beam_cone_cos:
					continue
				var c := _falloff(origin_tile, pos, FLASHLIGHT_INTENSITY, FLASHLIGHT_RANGE)
				if c <= 0.0:
					continue
				if not GridManager.has_clear_line(unit, eye, t.world_pos + Vector3(0, 0.5, 0)):
					continue
				out[pos] = c
	return out


## cos of the beam's half-angle: the dot-product threshold `_within_cone` uses.
var _beam_cone_cos := cos(deg_to_rad(FLASHLIGHT_CONE_DEGREES / 2.0))


# --- Display layer (exploration plan B.12.1) -----------------------------------
#
# During a tick's playback the rules layer is already FINAL — every beam where
# its unit ended up — while the models are still walking there. Recomputing the
# rules layer along the replayed paths would re-run detection on a tick that has
# already been decided (`lighting_changed` drives awareness), so the drawn light
# gets a layer of its own instead: same base, same beam formula, each beam cast
# from its model. It never writes `light_value` and never emits
# `lighting_changed`.


func begin_display() -> void:
	_display_active = true
	recompute_display()


## Rebuilds the drawn light from where every flashlight's MODEL is and points.
## Playback calls it once per slot, the cadence a real move recomputes at.
func recompute_display() -> void:
	if not _display_active:
		return
	var beams := {}
	for node in get_tree().get_nodes_in_group("units"):
		var unit := node as Unit
		if unit == null or not unit.has_flashlight or not unit.visual.light_shown():
			continue
		var origin: Vector3 = unit.visual.global_position
		var beam := _beam_contribution(GridManager.world_to_grid(origin), origin, _aim_of(unit), unit)
		for pos: Vector3i in beam:
			beams[pos] = maxf(beams.get(pos, 0.0), beam[pos])
	_display_beams = beams
	display_lighting_changed.emit()


## Drops the display layer: the last slot left every model on its final tile, so
## what is drawn now equals the rules layer again.
func end_display() -> void:
	_display_active = false
	_display_beams.clear()
	display_lighting_changed.emit()


## The light a tile is DRAWN with: the display layer during playback, the rules'
## `light_value` otherwise. For the screen only — tile tint, model shading, the
## HUD readout. Accuracy and awareness keep reading `light_value`.
func display_light(pos: Vector3i) -> float:
	if _display_active:
		if not GridManager.tiles.has(pos):
			return 0.0
		return clampf(_base.get(pos, AMBIENT_FLOOR) + _display_beams.get(pos, 0.0), 0.0, 100.0)
	var t: GridTileData = GridManager.get_tile(pos)
	return t.light_value if t else 0.0


func is_displaying() -> bool:
	return _display_active


func flashlight_value(pos: Vector3i) -> float:
	# Flashlight contribution only, deliberately excluding static fixtures — see
	# the note on _dynamic. Aggro reads this, accuracy reads tile.light_value.
	return _dynamic.get(pos, 0.0)


func flashlight_source(pos: Vector3i) -> Unit:
	# Which unit's beam is lighting this tile, or null if none is.
	return _dynamic_source.get(pos)


## Which way a unit's beam points, in world space.
##
## THE RIFLE, NOT THE SHOULDERS. The SpotLight3D is mounted on the model's
## barrel (unit_visual.gd `_build_light`), and this reads the same light's
## forward, so what looks lit and what counts as lit cannot drift apart. That
## agreement is the rule this whole layer exists to hold.
##
## Sampled live, so it carries whatever the animation is doing at the moment of
## a recompute (move, toggle, turn start). The idle sway is a few degrees
## against a 90 degree cone, so only tiles right on the cone's edge can differ.
##
## Falls back to unit facing for anything without a light — headless runs build
## no model, so there it is always facing.
func _aim_of(unit: Unit) -> Vector3:
	var visual: Variant = unit.get("visual")
	if visual is Node3D and (visual as Node3D).has_method("aim_direction"):
		var aim: Vector3 = (visual as Node3D).call("aim_direction")
		if aim.length_squared() > 0.5:
			return aim
	return -unit.global_transform.basis.z


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
