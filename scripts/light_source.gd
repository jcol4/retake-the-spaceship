class_name LightSource
extends Node3D
## A static light fixture — overhead light, monitor/terminal, flickering light,
## etc. (Sec 5.3). Contributes to nearby tiles' light_value via
## LightingManager and carries its own shadow-casting SpotLight3D for a harsh
## beam-of-light look: straight down by default, or tilted along this node's
## -Z by `beam_pitch` for a fixture mounted on a wall (MapBuilder._add_wall_lamp).
##
## Registration is explicit (register_with_grid), not done from _ready, to
## match CoverObject's pattern: the caller controls exactly when this fixture
## is wired into the grid relative to floor-tile creation.

@export var light_range: float = 6.0  # tiles
@export var intensity: float = 80.0  # 0-100 contribution at zero distance
@export var light_color: Color = Color(1.0, 0.95, 0.85)
@export var flickers: bool = false
@export var flicker_min: float = 30.0
@export var flicker_max: float = 100.0
## The beam's angle below this node's -Z, in degrees: -90 is straight down.
@export var beam_pitch: float = -90.0
@export var spot_angle: float = 68.0  # wide enough at a ~2m mount to reach nearby cover
## SpotLight3D.spot_angle_attenuation: 1.0 fades evenly out to the rim; higher
## holds the disc bright and drops it off hard at the edge, like a flashlight.
@export var spot_edge: float = 1.0
## Visual only: scales the SpotLight3D's energy without touching `intensity`,
## which the rules read for light_value.
@export var beam_energy_scale: float = 1.0
## SpotLight3D.spot_attenuation: higher fades the beam out sooner with distance.
@export var beam_falloff: float = 3.0
@export var casts_shadows: bool = true

var grid_pos: Vector3i
var _current_intensity: float
var _visual: SpotLight3D = null
var room_index := -1
var normal_color := Color.WHITE


func set_powered(powered: bool) -> void:
	_current_intensity = intensity if powered else intensity * 0.15
	light_color = normal_color if powered else Color(1.0, 0.12, 0.08)
	if _visual:
		_visual.light_color = light_color
		_visual.light_energy = _energy_for(_current_intensity)


func register_with_grid() -> void:
	grid_pos = GridManager.world_to_grid(global_position)
	var map := GridManager.world_node
	if map != null and map.get("data") != null:
		if room_index < 0:
			room_index = map.data.room_index_at(grid_pos)
		if map.data.room_type(room_index) not in [RoomTypes.GENERIC, RoomTypes.CORRIDOR, RoomTypes.HANGAR]:
			light_color = RoomTypes.light_of(map.data.room_type(room_index))
	normal_color = light_color
	_current_intensity = intensity
	_visual = _make_visual()
	if map != null and map.get("data") != null:
		set_powered(not (map.data.room_is_dark(room_index) or map.data.is_dark_at(grid_pos)))
	LightingManager.register_source(self)


func current_intensity() -> float:
	return _current_intensity


func reroll_flicker(rng: RandomNumberGenerator) -> void:
	# Sec 5.3: flickering lights fluctuate turn-to-turn. Called by
	# LightingManager.reroll_flicker() at turn start; no-op otherwise.
	if not flickers:
		return
	_current_intensity = rng.randf_range(flicker_min, flicker_max)
	if _visual:
		_visual.light_energy = _energy_for(_current_intensity)


func _make_visual() -> SpotLight3D:
	# Downward cone for a literal beam-of-light look (visual only — the
	# gameplay light_value falloff in LightingManager stays radial/Chebyshev
	# and doesn't know about this cone's shape or angle).
	var light := SpotLight3D.new()
	light.rotation_degrees = Vector3(beam_pitch, 0, 0)
	light.light_color = light_color
	light.light_energy = _energy_for(_current_intensity)
	light.spot_range = light_range * GridManager.TILE_SIZE
	light.spot_angle = spot_angle
	light.spot_attenuation = beam_falloff
	light.spot_angle_attenuation = spot_edge
	light.shadow_enabled = casts_shadows
	light.shadow_blur = 0.1  # harsh, hard-edged shadows
	add_child(light)
	return light


func _energy_for(value: float) -> float:
	return value / 100.0 * 12.0 * beam_energy_scale


func _exit_tree() -> void:
	LightingManager.unregister_source(self)
