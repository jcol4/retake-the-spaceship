extends CanvasLayer
## Minimal HUD: selected-unit panel, action buttons, scrolling combat log.

@onready var unit_info: Label = $UnitPanel/UnitInfo
@onready var log_box: RichTextLabel = $LogPanel/Log
@onready var banner: Label = $Banner
@onready var buttons := {
	"move": $Actions/Move,
	"shoot": $Actions/Shoot, "barrage": $Actions/Barrage,
	"hunker": $Actions/Hunker, "overwatch": $Actions/Overwatch,
	"reload": $Actions/Reload, "flashlight": $Actions/Flashlight, "end_turn": $Actions/EndTurn,
}


func _ready() -> void:
	TurnManager.log_message.connect(append_log)
	TurnManager.unit_activated.connect(_on_unit_activated)
	TurnManager.mission_ended.connect(_on_mission_ended)
	buttons["move"].pressed.connect(_set_mode.bind(PlayerUnit.Mode.MOVE))
	buttons["shoot"].pressed.connect(_set_mode.bind(PlayerUnit.Mode.SHOOT))
	buttons["barrage"].pressed.connect(_set_mode.bind(PlayerUnit.Mode.BARRAGE))
	buttons["hunker"].pressed.connect(_on_hunker)
	buttons["overwatch"].pressed.connect(_on_overwatch)
	buttons["reload"].pressed.connect(_on_reload)
	buttons["flashlight"].pressed.connect(_on_flashlight)
	buttons["end_turn"].pressed.connect(_on_end_turn)
	_refresh(null)


func append_log(text: String) -> void:
	log_box.append_text(text + "\n")


func _active_player() -> PlayerUnit:
	return TurnManager.active_unit as PlayerUnit


func _on_unit_activated(unit: Unit) -> void:
	_refresh(unit)
	if unit is PlayerUnit and not unit.ap_changed.is_connected(_on_ap_changed):
		unit.ap_changed.connect(_on_ap_changed)


func _on_ap_changed(unit: Unit) -> void:
	if unit == TurnManager.active_unit:
		_refresh(unit)


func _refresh(unit: Unit) -> void:
	var player := unit as PlayerUnit
	if player and not player.is_downed:
		var reserved := ""
		if player.on_overwatch:
			reserved = "   OVERWATCH"
		elif player.hunkered:
			reserved = "   HUNKERED"
		# Own units only — enemy Initiative stays hidden (Sec 4.1).
		unit_info.text = "%s  [%s]\nHP %d/%d   AP %d   Ammo %d/%d\nInitiative %.0f%s\nFlashlight %s   Standing on %d%% light" % [
			player.stats.display_name,
			UnitStats.UnitClass.keys()[player.stats.unit_class],
			player.current_hp, player.stats.max_hp(), player.ap,
			player.ammo, player.stats.mag_size,
			player.stats.initiative(), reserved,
			"ON" if player.flashlight_on else "OFF",
			roundi(GridManager.get_tile(player.grid_pos).light_value) if GridManager.has_tile(player.grid_pos) else 0,
		]
	elif unit:
		unit_info.text = "%s (hostile)\nacting..." % unit.stats.display_name
	else:
		unit_info.text = "—"
	var is_player := player != null
	buttons["move"].disabled = not is_player or player.ap < 1
	buttons["shoot"].disabled = not is_player or player.ap < 1 or (is_player and not player.can_shoot())
	buttons["barrage"].disabled = not is_player or player.ap < 2 or (is_player and not player.can_shoot())
	buttons["hunker"].disabled = not is_player or player.ap < 1
	buttons["overwatch"].disabled = not is_player or player.ap < 2 or (is_player and not player.can_shoot())
	buttons["reload"].disabled = not is_player or player.ap < 1
	buttons["flashlight"].disabled = not is_player  # free action — no AP gate
	buttons["end_turn"].disabled = not is_player


func _set_mode(mode: PlayerUnit.Mode) -> void:
	var player := _active_player()
	if player:
		player.set_mode(mode)


func _on_hunker() -> void:
	var player := _active_player()
	if player:
		player.try_hunker()
		_refresh(player)


func _on_overwatch() -> void:
	var player := _active_player()
	if player:
		player.try_overwatch()
		_refresh(player)


func _on_reload() -> void:
	var player := _active_player()
	if player:
		player.try_reload()
		_refresh(player)


func _on_flashlight() -> void:
	var player := _active_player()
	if player:
		player.try_toggle_flashlight()
		_refresh(player)


func _on_end_turn() -> void:
	var player := _active_player()
	if player:
		player.end_activation()
		_refresh(null)


func _on_mission_ended(player_won: bool) -> void:
	banner.text = "MISSION WON" if player_won else "MISSION FAILED"
	banner.visible = true
	for key in buttons:
		buttons[key].disabled = true
