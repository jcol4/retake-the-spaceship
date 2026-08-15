extends CanvasLayer
## Minimal HUD: selected-unit panel, action buttons, scrolling combat log.

@onready var unit_info: Label = $UnitPanel/UnitInfo
@onready var log_box: RichTextLabel = $LogPanel/Log
@onready var banner: Label = $Banner
@onready var buttons := {
	"move": $Actions/Move,
	"shoot": $Actions/Shoot, "aimed_shot": $Actions/AimedShot,
	"suppress": $Actions/Suppress, "emp": $Actions/Emp,
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
	buttons["suppress"].pressed.connect(_set_mode.bind(PlayerUnit.Mode.SUPPRESS))
	buttons["emp"].pressed.connect(_set_mode.bind(PlayerUnit.Mode.EMP))
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
		# Read BEFORE the postures above would matter, because it is the one the
		# player most needs and the only one imposed from outside: a pinned
		# soldier is down AP and shooting at -40%, and nothing else on this panel
		# would explain why.
		if player.is_suppressed():
			reserved = "   SUPPRESSED by %s" % player.suppressed_by.stats.display_name
		if player.suppressing != null:
			reserved += "   (suppressing %s)" % player.suppressing.stats.display_name
		var injuries := player.injured_summary()
		var injury_line := "\nInjuries: %s" % injuries if injuries != "None" else ""
		var weapon_name := player.stats.weapon.display_name if player.stats.weapon else "Unarmed"
		var reserve_text := "∞" if player.reserve < 0 else str(player.reserve)
		# Own units only — enemy Initiative stays hidden (Sec 4.1).
		# AP shows the POOL alongside what's left: the pool is per-soldier now
		# (Fitness-derived, Sec 4.2), so a bare "AP 5" doesn't say whether that is
		# a full activation or the tail of one.
		unit_info.text = "%s  [%s]   %s\nHP %d/%d   AP %d/%d   Ammo %d/%d   Reserve %s\nInitiative %d%s\nFlashlight %s   Standing on %d%% light%s" % [
			player.stats.display_name,
			UnitStats.UnitClass.keys()[player.stats.unit_class],
			weapon_name,
			player.current_hp, player.stats.max_hp(), player.ap, player.ap_pool(),
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
	# Every price is per-soldier now (Reflexes discounts them, Sec 4.3), so the
	# buttons carry their own cost rather than the player memorising a fixed
	# table — the same number the gate below is testing against.
	if is_player:
		_label_cost(buttons["shoot"], "Shoot", player.action_cost(UnitStats.Action.SHOOT))
		_label_cost(buttons["aimed_shot"], "Aimed Shot", player.min_aimed_shot_cost())
		# Carries the AMMO cost too, because that is the binding constraint far
		# more often than the AP is — a soldier with two rounds left cannot
		# suppress at any price.
		buttons["suppress"].text = "Suppress (%d)  %dr" % [
			player.action_cost(UnitStats.Action.SUPPRESS), Unit.SUPPRESS_AMMO_COST]
		_label_cost(buttons["hunker"], "Hunker", player.action_cost(UnitStats.Action.HUNKER))
		_label_cost(buttons["reload"], "Reload", player.action_cost(UnitStats.Action.RELOAD))
		# Charges are per soldier, so the label has to say how many are left too —
		# an EMP button showing only its AP cost hides the real constraint.
		buttons["emp"].text = "EMP (%d)  x%d" % [
			player.action_cost(UnitStats.Action.GRENADE), player.emp_charges]
	buttons["move"].disabled = not is_player or player.ap < player.move_ap_per_tile()
	buttons["shoot"].disabled = not is_player \
		or player.ap < player.action_cost(UnitStats.Action.SHOOT) or not player.can_shoot()
	# Gated on the Torso, the cheapest zone — the per-zone prices are on the menu
	# itself, where the zone is actually chosen.
	buttons["aimed_shot"].disabled = not is_player \
		or player.ap < player.min_aimed_shot_cost() or not player.can_shoot()
	buttons["suppress"].disabled = not is_player \
		or player.ap < player.action_cost(UnitStats.Action.SUPPRESS) or not player.can_suppress()
	buttons["emp"].disabled = not is_player \
		or player.ap < player.action_cost(UnitStats.Action.GRENADE) or player.emp_charges <= 0
	buttons["hunker"].disabled = not is_player or player.ap < player.action_cost(UnitStats.Action.HUNKER)
	# Overwatch alone has no fixed price: it commits whatever is left (Sec 4.4),
	# so any AP at all is enough to take it.
	buttons["overwatch"].disabled = not is_player or player.ap < 1 or not player.can_shoot()
	buttons["reload"].disabled = not is_player \
		or player.ap < player.action_cost(UnitStats.Action.RELOAD) or not player.can_reload()
	# Both free actions (Sec 4.2) — no AP gate on either.
	buttons["face"].disabled = not is_player
	buttons["flashlight"].disabled = not is_player
	buttons["end_turn"].disabled = not is_player


func _label_cost(button: Button, label: String, cost: int) -> void:
	button.text = "%s (%d)" % [label, cost]


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
	# The zone menu is now a price list as well as an odds list: Sec 4.3a makes a
	# head shot cost more AP than a torso one, on top of costing accuracy, so the
	# player cannot choose between zones without seeing both numbers. Zones the
	# remaining pool cannot cover are disabled rather than hidden — knowing the
	# head was 7 AP away is the information that shapes the NEXT activation.
	for part in body_part_buttons:
		var acc := Combat.compute_accuracy(player, target, Combat.ShotAction.AIMED_SHOT, part)
		var cost := player.aimed_shot_cost(part)
		body_part_buttons[part].text = "%s — %d AP (%d%%)" % [Combat.body_part_name(part), cost, acc]
		body_part_buttons[part].disabled = player.ap < cost
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
