class_name LightSource
extends Node3D
## A static light fixture — overhead light, monitor/terminal, flickering light,
## etc. (Sec 5.3). Contributes to nearby tiles' light_value via
## LightingManager and carries its own shadow-casting SpotLight3D, aimed
## straight down, for a harsh beam-of-light look.
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

var grid_pos: Vector3i
var _current_intensity: float
var _visual: SpotLight3D = null


func register_with_grid() -> void:
	grid_pos = GridManager.world_to_grid(global_position)
	_current_intensity = intensity
	_visual = _make_visual()
	LightingManager.register_source(self)


func current_intensity() -> float:
	return _current_intensity


func reroll_flicker() -> void:
	# Sec 5.3: flickering lights fluctuate turn-to-turn. Called by
	# LightingManager.reroll_flicker() at turn start; no-op otherwise.
	if not flickers:
		return
	_current_intensity = randf_range(flicker_min, flicker_max)
	if _visual:
		_visual.light_energy = _energy_for(_current_intensity)


func _make_visual() -> SpotLight3D:
	# Downward cone for a literal beam-of-light look (visual only — the
	# gameplay light_value falloff in LightingManager stays radial/Chebyshev
	# and doesn't know about this cone's shape or angle).
	var light := SpotLight3D.new()
	light.rotation_degrees = Vector3(-90, 0, 0)  # aim straight down
	light.light_color = light_color
	light.light_energy = _energy_for(_current_intensity)
	light.spot_range = light_range * GridManager.TILE_SIZE
	light.spot_angle = 68.0  # wide enough at a ~2m ceiling mount to reach nearby cover
	light.spot_attenuation = 3.0  # hot center, sharp cutoff instead of a gentle wash
	light.spot_angle_attenuation = 1.0  # even brightness across the disc, sharp only at the rim
	light.shadow_enabled = true
	light.shadow_blur = 0.1  # harsh, hard-edged shadows
	add_child(light)
	return light


func _energy_for(value: float) -> float:
	return value / 100.0 * 12.0


func _exit_tree() -> void:
	LightingManager.unregister_source(self)
