extends CanvasLayer
## Minimal HUD: selected-unit panel, action buttons, scrolling combat log.

@onready var unit_info: Label = $UnitPanel/UnitInfo
@onready var log_box: RichTextLabel = $LogPanel/Log
@onready var banner: Label = $Banner
@onready var buttons := {
	"move": $Actions/Move,
	"shoot": $Actions/Shoot, "aimed_shot": $Actions/AimedShot,
	"hunker": $Actions/Hunker, "overwatch": $Actions/Overwatch,
	"reload": $Actions/Reload, "face": $Actions/Face,
	"flashlight": $Actions/Flashlight, "end_turn": $Actions/EndTurn,
}
# VATS-style target-zone popup (Sec 4.2/6.5), Fallout-style: appears once the
# player has Aimed Shot armed and clicks a target, listing that target's own
# per-zone accuracy; picking one fires immediately.
@onready var aimed_shot_menu: Control = $AimedShotMenu
@onready var body_part_buttons := {
	Combat.BodyPart.HEAD: $AimedShotMenu/Panel/VBox/Head, Combat.BodyPart.TORSO: $AimedShotMenu/Panel/VBox/Torso,
	Combat.BodyPart.ARM_L: $AimedShotMenu/Panel/VBox/ArmL, Combat.BodyPart.ARM_R: $AimedShotMenu/Panel/VBox/ArmR,
	Combat.BodyPart.LEG_L: $AimedShotMenu/Panel/VBox/LegL, Combat.BodyPart.LEG_R: $AimedShotMenu/Panel/VBox/LegR,
}
@onready var aimed_shot_cancel: Button = $AimedShotMenu/Panel/VBox/Cancel

var _aimed_shot_target: Unit = null


func _ready() -> void:
	TurnManager.log_message.connect(append_log)
	TurnManager.unit_activated.connect(_on_unit_activated)
	TurnManager.mission_ended.connect(_on_mission_ended)
	buttons["move"].pressed.connect(_set_mode.bind(PlayerUnit.Mode.MOVE))
	buttons["shoot"].pressed.connect(_set_mode.bind(PlayerUnit.Mode.SHOOT))
	buttons["aimed_shot"].pressed.connect(_set_mode.bind(PlayerUnit.Mode.AIMED_SHOT))
	for part in body_part_buttons:
		body_part_buttons[part].pressed.connect(_on_menu_pick.bind(part))
	aimed_shot_cancel.pressed.connect(_on_aimed_shot_cancel)
	buttons["hunker"].pressed.connect(_on_hunker)
	buttons["overwatch"].pressed.connect(_on_overwatch)
	buttons["reload"].pressed.connect(_on_reload)
	buttons["face"].pressed.connect(_set_mode.bind(PlayerUnit.Mode.FACE))
	buttons["flashlight"].pressed.connect(_on_flashlight)
	buttons["end_turn"].pressed.connect(_on_end_turn)
	_refresh(null)


func append_log(text: String) -> void:
	log_box.append_text(text + "\n")


func _active_player() -> PlayerUnit:
	return TurnManager.active_unit as PlayerUnit


func _on_unit_activated(unit: Unit) -> void:
	_hide_aimed_shot_menu()
	_refresh(unit)
	if unit is PlayerUnit and not unit.ap_changed.is_connected(_on_ap_changed):
		unit.ap_changed.connect(_on_ap_changed)
	if unit is PlayerUnit and not unit.aimed_shot_target_picked.is_connected(_on_aimed_shot_target_picked):
		unit.aimed_shot_target_picked.connect(_on_aimed_shot_target_picked)


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
		var injuries := player.injured_summary()
		var injury_line := "\nInjuries: %s" % injuries if injuries != "None" else ""
		var weapon_name := player.stats.weapon.display_name if player.stats.weapon else "Unarmed"
		var reserve_text := "∞" if player.reserve < 0 else str(player.reserve)
		# Own units only — enemy Initiative stays hidden (Sec 4.1).
		unit_info.text = "%s  [%s]   %s\nHP %d/%d   AP %d   Ammo %d/%d   Reserve %s\nInitiative %.0f%s\nFlashlight %s   Standing on %d%% light%s" % [
			player.stats.display_name,
			UnitStats.UnitClass.keys()[player.stats.unit_class],
			weapon_name,
			player.current_hp, player.stats.max_hp(), player.ap,
			player.ammo, player.stats.mag_size, reserve_text,
			player.stats.initiative(), reserved,
			"ON" if player.flashlight_on else "OFF",
			roundi(GridManager.get_tile(player.grid_pos).light_value) if GridManager.has_tile(player.grid_pos) else 0,
			injury_line,
		]
	elif unit:
		unit_info.text = "%s (hostile)\nacting..." % unit.stats.display_name
	else:
		unit_info.text = "—"
	var is_player := player != null
	buttons["move"].disabled = not is_player or player.ap < 1
	buttons["shoot"].disabled = not is_player or player.ap < 1 or (is_player and not player.can_shoot())
	buttons["aimed_shot"].disabled = not is_player or player.ap < 2 or (is_player and not player.can_shoot())
	buttons["hunker"].disabled = not is_player or player.ap < 1
	buttons["overwatch"].disabled = not is_player or player.ap < 1 or (is_player and not player.can_shoot())
	buttons["reload"].disabled = not is_player or player.ap < 1 or (is_player and not player.can_reload())
	# Both free actions (Sec 4.2) — no AP gate on either.
	buttons["face"].disabled = not is_player
	buttons["flashlight"].disabled = not is_player
	buttons["end_turn"].disabled = not is_player


func _set_mode(mode: PlayerUnit.Mode) -> void:
	_hide_aimed_shot_menu()
	var player := _active_player()
	if player:
		player.set_mode(mode)


func _on_aimed_shot_target_picked(target: Unit) -> void:
	var player := _active_player()
	if player == null:
		return
	_aimed_shot_target = target
	for part in body_part_buttons:
		var acc := Combat.compute_accuracy(player, target, Combat.ShotAction.AIMED_SHOT, part)
		body_part_buttons[part].text = "%s (%d%%)" % [Combat.body_part_name(part), acc]
	aimed_shot_menu.visible = true


func _on_menu_pick(part: int) -> void:
	var player := _active_player()
	var target := _aimed_shot_target
	_hide_aimed_shot_menu()
	if player == null or target == null:
		return
	await player.fire_aimed_shot(target, part)
	_refresh(TurnManager.active_unit)


func _on_aimed_shot_cancel() -> void:
	_hide_aimed_shot_menu()


func _hide_aimed_shot_menu() -> void:
	aimed_shot_menu.visible = false
	_aimed_shot_target = null


func _on_hunker() -> void:
	_hide_aimed_shot_menu()
	var player := _active_player()
	if player:
		player.try_hunker()
		_refresh(player)


func _on_overwatch() -> void:
	_hide_aimed_shot_menu()
	var player := _active_player()
	if player:
		player.try_overwatch()
		_refresh(player)


func _on_reload() -> void:
	_hide_aimed_shot_menu()
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
	_hide_aimed_shot_menu()
	var player := _active_player()
	if player:
		player.end_activation()
		_refresh(null)


func _on_mission_ended(player_won: bool) -> void:
	_hide_aimed_shot_menu()
	banner.text = "MISSION WON" if player_won else "MISSION FAILED"
	banner.visible = true
	for key in buttons:
		buttons[key].disabled = true
