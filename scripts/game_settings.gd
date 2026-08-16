extends Node
## Persists window/display preferences across launches. Autoloaded so it can
## apply the saved mode before the first frame renders (Sec hud.gd settings
## panel is the only thing that flips `fullscreen` at runtime).

const SAVE_PATH := "user://settings.cfg"

var fullscreen: bool = false


func _ready() -> void:
	_load()
	_apply()


## Borderless fullscreen window rather than exclusive fullscreen: instant,
## no display-mode-switch flicker, and alt-tabs cleanly — worth more to a
## turn-based tactics game than the marginal latency win exclusive mode buys.
func set_fullscreen(value: bool) -> void:
	if value == fullscreen:
		return
	fullscreen = value
	_apply()
	_save()


func _apply() -> void:
	DisplayServer.window_set_mode(
		DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED
	)


func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) == OK:
		fullscreen = cfg.get_value("window", "fullscreen", false)


func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("window", "fullscreen", fullscreen)
	cfg.save(SAVE_PATH)
