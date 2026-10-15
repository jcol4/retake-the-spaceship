extends Node
## Persists window/display and audio preferences across launches. Autoloaded so
## it can apply the saved mode before the first frame renders (the hud.gd
## settings panel is the only thing that flips these at runtime).

const SAVE_PATH := "user://settings.cfg"

## Bus names as they appear in default_bus_layout.tres. Volumes are stored as a
## 0..1 LINEAR fraction, not decibels: that's what a slider hands us and what a
## player means by "half volume", and linear_to_db does the conversion at the
## one point it matters. Storing db instead would put -80..0 in the config file
## and make a hand-edit or a future slider rescale a trap.
const BUS_SFX := &"SFX"
const BUS_MUSIC := &"Music"
const BUS_UI := &"UI"

var fullscreen: bool = false
var sfx_volume: float = 1.0
var music_volume: float = 0.7
var ui_volume: float = 1.0


func _ready() -> void:
	_load()
	_apply()
	_apply_audio()


## Borderless fullscreen window rather than exclusive fullscreen: instant,
## no display-mode-switch flicker, and alt-tabs cleanly — worth more to a
## turn-based tactics game than the marginal latency win exclusive mode buys.
func set_fullscreen(value: bool) -> void:
	if value == fullscreen:
		return
	fullscreen = value
	_apply()
	_save()


func set_sfx_volume(value: float) -> void:
	sfx_volume = clampf(value, 0.0, 1.0)
	_apply_bus(BUS_SFX, sfx_volume)
	_save()


func set_music_volume(value: float) -> void:
	music_volume = clampf(value, 0.0, 1.0)
	_apply_bus(BUS_MUSIC, music_volume)
	_save()


func set_ui_volume(value: float) -> void:
	ui_volume = clampf(value, 0.0, 1.0)
	_apply_bus(BUS_UI, ui_volume)
	_save()


func _apply() -> void:
	DisplayServer.window_set_mode(
		DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED
	)


func _apply_audio() -> void:
	_apply_bus(BUS_SFX, sfx_volume)
	_apply_bus(BUS_MUSIC, music_volume)
	_apply_bus(BUS_UI, ui_volume)


func _apply_bus(bus: StringName, linear: float) -> void:
	var index := AudioServer.get_bus_index(bus)
	# -1 means the bus layout didn't load — an editor run before
	# default_bus_layout.tres existed, or someone renamed a bus. Silently doing
	# nothing is right: every player falls back to the Master bus at full volume
	# rather than the game erroring out over a volume slider.
	if index == -1:
		push_warning("Audio bus '%s' not found — volume setting ignored" % bus)
		return
	# Muted rather than -80 dB of near-silence: a slider at 0 should be OFF.
	AudioServer.set_bus_mute(index, is_zero_approx(linear))
	AudioServer.set_bus_volume_db(index, linear_to_db(linear))


func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	fullscreen = cfg.get_value("window", "fullscreen", false)
	sfx_volume = cfg.get_value("audio", "sfx", 1.0)
	music_volume = cfg.get_value("audio", "music", 0.7)
	ui_volume = cfg.get_value("audio", "ui", 1.0)


func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("window", "fullscreen", fullscreen)
	cfg.set_value("audio", "sfx", sfx_volume)
	cfg.set_value("audio", "music", music_volume)
	cfg.set_value("audio", "ui", ui_volume)
	cfg.save(SAVE_PATH)
