extends CanvasLayer
## Minimal HUD: selected-unit panel, action buttons, scrolling combat log.

@onready var unit_info: Label = $UnitPanel/UnitInfo
@onready var log_box: RichTextLabel = $LogPanel/Log
@onready var banner: Label = $Banner
@onready var buttons := {
	"move": $Actions/Move,
	"shoot": $Actions/Shoot, "aimed_shot": $Actions/AimedShot,
	"suppress": $Actions/Suppress, "grenade": $Actions/Grenade,
	"hunker": $Actions/Hunker, "overwatch": $Actions/Overwatch,
	"reload": $Actions/Reload, "face": $Actions/Face,
	"flashlight": $Actions/Flashlight, "end_turn": $Actions/EndTurn,
	"call_ship": $Actions/CallShip, "extract": $Actions/DustOff,
	"revive": $Actions/Revive, "pick_up": $Actions/PickUp, "drop": $Actions/Drop,
	"loot": $Actions/Loot,
}
## GDD §4.4 / extraction plan 2.6: a world-space label over every body on the
## deck — the downed bar in red with the down-count pips, or "DEAD". A downed
## soldier is never the active unit, so the unit panel can never show their bar;
## the label puts it where the player is looking anyway, over the body. Unit ->
## Label3D, parented to the unit itself so it follows a body that is carried and
## dropped, and goes with the unit if it is freed.
var _body_labels: Dictionary = {}
## Seconds between body-label refreshes. Polled rather than signal-driven because
## a client never sees `hp_changed` — the bar arrives by replication — and a few
## labels a quarter-second apart cost nothing.
const BODY_LABEL_REFRESH := 0.25
var _body_label_clock := 0.0
## Metres above the deck the body label floats: low, since the body is lying down.
const BODY_LABEL_HEIGHT := 1.1
## Extraction (GDD §7): the end-of-mission roll call under the banner, and the
## brief radio line across the top that a call-in, a landing or a dust-off puts
## up alongside its combat-log entry.
@onready var end_details: Label = $EndDetails
@onready var radio_banner: Label = $RadioBanner
## Seconds a radio line stays up. Long enough to read twice, short enough that
## two notices in one round don't stack into a backlog.
const RADIO_BANNER_SECONDS := 3.5
## For the K tracer toggle (`_toggle_tracers`); VfxManager has no class_name.
const VFX := preload("res://scripts/vfx_manager.gd")
var _radio_timer: SceneTreeTimer = null
## Hangar index -> its Label3D over the bay. World-space rather than on this
## CanvasLayer so it sits over the hangar wherever the camera is; parented to the
## map (group "map") so a deck rebuild takes the markers with it.
var _hangar_markers: Dictionary = {}
## Metres above the pad the marker floats — over the Dropship's roof.
const HANGAR_MARKER_HEIGHT := 4.0
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

# Same pattern one throw earlier: appears once Grenade is armed and a legal
# tile is clicked, asking which payload (PlayerUnit.GrenadeType) to spend the
# one charge on; picking one throws immediately.
@onready var grenade_menu: Control = $GrenadeMenu
@onready var grenade_type_buttons := {
	PlayerUnit.GrenadeType.EMP: $GrenadeMenu/Panel/VBox/Emp,
	PlayerUnit.GrenadeType.FRAG: $GrenadeMenu/Panel/VBox/Frag,
}
@onready var grenade_cancel: Button = $GrenadeMenu/Panel/VBox/Cancel

@onready var settings_button: Button = $SettingsButton
@onready var settings_panel: Control = $SettingsPanel
@onready var fullscreen_check: CheckButton = $SettingsPanel/Panel/VBox/FullscreenCheck
@onready var settings_close: Button = $SettingsPanel/Panel/VBox/Close

var _aimed_shot_target: Unit = null
var _grenade_target: Vector3i = PlayerUnit.NO_TILE

## Extraction plan 3.3: the contract's one-line status under the radio banner
## ("Retrieve: Data Core — carried by Reyes"), from ObjectiveManager.
@onready var objective_label: Label = $ObjectiveLabel
## Extraction plan 3.2: the loot panel. Built in code rather than in hud.tscn
## because its rows ARE the data — one per item in each source in reach and one
## per item in the soldier's pack — and are rebuilt whenever any of it changes.
## Each "Take" is one command and one AP (PlayerUnit.try_loot); each "Drop" is
## free (try_drop_item) and leaves a pile on the soldier's tile.
var _loot_panel: PanelContainer
var _loot_rows: VBoxContainer
## Extraction plan 4.2: the end panel's way out. The mission's scene no longer
## reloads itself — Continue goes to the Debrief (main.gd listens), where the
## campaign shows what the result was worth. Code-built like the loot panel;
## hidden until the mission ends.
signal continue_pressed
var _continue_button: Button
## Seconds before Continue appears, so a click meant for the last action does not
## land on it and skip the roll call unread.
const CONTINUE_DELAY := 1.0
## Exploration (GDD §4.7, plan B.11): which loop the mission is in and, out of
## combat, the step clock. Code-built beside the other late additions.
var _mode_label: Label
## The squad feed, top-left, in both modes (E24): one SquadFeedCard per soldier,
## a live helmet-cam of their face over an ECG trace of their vitals.
## Unit -> SquadFeedCard. Your own select on click (exploration only); a co-op
## partner's are read-only; whoever is drawn or selected is outlined. The unit
## panel is pushed down beneath it. A co-op squad bigger than four (up to eight,
## MULTIPLAYER_PLAN.md) goes to two columns, so the feed stays four cards tall.
var _portrait_bar: GridContainer
var _portraits: Dictionary = {}
const SQUAD_FEED_MARGIN := 12.0
## The tile the unit panel was last drawn for. Out of combat a walk spends no AP, so
## nothing else says the context buttons (Loot, Call ship) may have changed.
var _shown_tile := Vector3i(0, -9999, 0)
## XCOM-style target bar over the action bar while a shot mode is armed: one
## skull per hostile in line of sight (hover for the odds), then Confirm once
## one is picked (PlayerUnit.pick_target / confirm_target). Code-built, since its
## buttons ARE the target list.
var _target_bar: VBoxContainer
var _target_info: Label
var _confirm_button: Button
var _skull_row: HBoxContainer
## Skull button -> the Unit it targets, and the list they were built from.
var _skulls: Dictionary = {}
var _skull_targets: Array[Unit] = []
var _hovered_skull: Unit = null
var _target_marker: TargetMarker
## The target list re-checks line of sight, so it is polled on a short clock
## rather than every frame. Shorter than BODY_LABEL_REFRESH: it follows a click.
const TARGET_BAR_REFRESH := 0.1
var _target_bar_clock := 0.0
const SKULL_SIZE := 44.0


func _ready() -> void:
	TurnManager.log_message.connect(append_log)
	TurnManager.unit_activated.connect(_on_unit_activated)
	TurnManager.mission_ended.connect(_on_mission_ended)
	buttons["move"].pressed.connect(_set_mode.bind(PlayerUnit.Mode.MOVE))
	buttons["shoot"].pressed.connect(_set_mode.bind(PlayerUnit.Mode.SHOOT))
	buttons["aimed_shot"].pressed.connect(_set_mode.bind(PlayerUnit.Mode.AIMED_SHOT))
	buttons["suppress"].pressed.connect(_set_mode.bind(PlayerUnit.Mode.SUPPRESS))
	buttons["grenade"].pressed.connect(_set_mode.bind(PlayerUnit.Mode.GRENADE))
	for part in body_part_buttons:
		body_part_buttons[part].pressed.connect(_on_menu_pick.bind(part))
	aimed_shot_cancel.pressed.connect(_on_aimed_shot_cancel)
	for type in grenade_type_buttons:
		grenade_type_buttons[type].pressed.connect(_on_grenade_type_pick.bind(type))
	grenade_cancel.pressed.connect(_on_grenade_cancel)
	buttons["hunker"].pressed.connect(_on_hunker)
	buttons["overwatch"].pressed.connect(_on_overwatch)
	buttons["reload"].pressed.connect(_on_reload)
	buttons["face"].pressed.connect(_set_mode.bind(PlayerUnit.Mode.FACE))
	buttons["flashlight"].pressed.connect(_on_flashlight)
	buttons["end_turn"].pressed.connect(_on_end_turn)
	buttons["call_ship"].pressed.connect(_on_call_ship)
	buttons["extract"].pressed.connect(_on_extract)
	_build_ship_buttons()
	buttons["revive"].pressed.connect(_set_mode.bind(PlayerUnit.Mode.REVIVE))
	buttons["pick_up"].pressed.connect(_set_mode.bind(PlayerUnit.Mode.PICK_UP))
	buttons["drop"].pressed.connect(_on_drop)
	buttons["loot"].pressed.connect(_on_loot)
	_build_terminal_button()
	_build_wait_button()
	_build_mode_label()
	_build_portrait_bar()
	_build_target_bar()
	TurnManager.unit_selected.connect(_on_unit_activated)
	TurnManager.mode_changed.connect(_on_mode_changed)
	TurnManager.clock_changed.connect(func(_s: int, _n: int) -> void: _refresh_mode_label())
	_build_loot_panel()
	_build_continue_button()
	LootManager.container_changed.connect(func(_t: Vector3i) -> void: _refresh_loot_panel())
	ObjectiveManager.objective_changed.connect(_refresh_objective)
	ExtractionManager.hangars_reset.connect(_rebuild_hangar_markers)
	ExtractionManager.hangar_changed.connect(_on_hangar_changed)
	ExtractionManager.notice.connect(_on_extraction_notice)
	TurnManager.turn_started.connect(func(_n: int) -> void: _refresh_hangar_markers())
	settings_button.pressed.connect(_on_settings_pressed)
	settings_close.pressed.connect(_on_settings_close)
	fullscreen_check.toggled.connect(_on_fullscreen_toggled)
	_refresh(null)


func append_log(text: String) -> void:
	log_box.append_text(text + "\n")


func _active_player() -> PlayerUnit:
	return TurnManager.active_unit as PlayerUnit


func _on_unit_activated(unit: Unit) -> void:
	_hide_aimed_shot_menu()
	_hide_grenade_menu()
	_hide_loot_panel()
	_refresh(unit)
	_refresh_portraits()
	if unit is PlayerUnit and not unit.command_rejected.is_connected(_on_command_rejected):
		unit.command_rejected.connect(_on_command_rejected)
	if unit is PlayerUnit and not unit.inventory_changed.is_connected(_on_inventory_changed):
		unit.inventory_changed.connect(_on_inventory_changed)
	if unit is PlayerUnit and not unit.ap_changed.is_connected(_on_ap_changed):
		unit.ap_changed.connect(_on_ap_changed)
	if unit is PlayerUnit and not unit.aimed_shot_target_picked.is_connected(_on_aimed_shot_target_picked):
		unit.aimed_shot_target_picked.connect(_on_aimed_shot_target_picked)
	if unit is PlayerUnit and not unit.grenade_target_picked.is_connected(_on_grenade_target_picked):
		unit.grenade_target_picked.connect(_on_grenade_target_picked)
	if unit is PlayerUnit and not unit.target_picked.is_connected(_on_target_picked):
		unit.target_picked.connect(_on_target_picked)
	_refresh_target_bar()


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
		# The weapon IN HAND (UnitStats.active_weapon): a carrier is firing the
		# pistol, and every number on this line — mag, reserve, the button prices
		# — is the pistol's, so the name must say so loudly.
		var in_hand := player.active_weapon()
		var weapon_name := in_hand.display_name if in_hand else "Unarmed"
		if player.stats.sidearm_drawn:
			weapon_name = weapon_name.to_upper()
		if player.carrying != null:
			reserved += "   CARRYING %s%s" % [player.carrying.stats.display_name,
				" (body)" if player.carrying.life_state == Unit.LifeState.DEAD else ""]
		if player.down_count > 0:
			injury_line += "\nDowns %s" % _down_pips(player)
		# GDD §7.5: the four slots, and what fills them — loot only counts if it
		# extracts, so what this soldier is holding is worth seeing every turn.
		injury_line += "\nPack %d/%d%s" % [player.inventory.size(), Unit.INVENTORY_SLOTS,
			(": " + ", ".join(PackedStringArray(player.inventory.map(func(i: ItemData) -> String: return i.display_name)))) \
				if not player.inventory.is_empty() else ""]
		var reserve_text := "∞" if player.reserve < 0 else str(player.reserve)
		# Own units only — enemy Initiative stays hidden (Sec 4.1).
		# AP shows the POOL alongside what's left: the pool is per-soldier now
		# (Fitness-derived, Sec 4.2), so a bare "AP 5" doesn't say whether that is
		# a full activation or the tail of one.
		# Out of combat there is no AP to read; the clock is on the mode banner.
		var ap_text := "" if TurnManager.in_exploration() else "   AP %d/%d" % [player.ap, player.ap_pool()]
		_shown_tile = player.grid_pos
		unit_info.text = "%s  [%s]   %s\nHP %d/%d%s   Ammo %d/%d   Reserve %s\nInitiative %d%s\nFlashlight %s   Standing on %d%% light%s" % [
			player.stats.display_name,
			UnitStats.UnitClass.keys()[player.stats.unit_class],
			weapon_name,
			player.current_hp, player.stats.max_hp(), ap_text,
			player.ammo, player.stats.mag_size, reserve_text,
			player.stats.initiative(), reserved,
			"ON" if player.flashlight_on else "OFF",
			roundi(LightingManager.display_light(player.grid_pos)),
			injury_line,
		]
	elif unit:
		# A non-soldier on the squad's side (the ship's door gun, Phase 5) is not
		# "hostile"; Initiative stays hidden for it all the same (Sec 4.1).
		unit_info.text = "%s (%s)\nacting..." % [unit.stats.display_name,
			"friendly" if unit.faction == Faction.Id.CONTRACTORS else "hostile"]
	else:
		unit_info.text = "—"
	var is_player := player != null
	# The whole row goes, rather than greying, whenever there is nothing this player
	# can do: the enemy's activation, or a co-op partner's soldier.
	$Actions.visible = is_player and not player.is_downed and player.is_owned_by_local_player()
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
		_label_cost(buttons["overwatch"], "Overwatch", player.action_cost(UnitStats.Action.OVERWATCH))
		_label_cost(buttons["reload"], "Reload", player.action_cost(UnitStats.Action.RELOAD))
		# Charges are per soldier, so the label has to say how many are left too —
		# a Grenade button showing only its AP cost hides the real constraint.
		# EMP and Frag draw from the same charge (PlayerUnit.GrenadeType picks
		# which one it's spent on), so one count covers both.
		buttons["grenade"].text = "Grenade (%d)  x%d" % [
			player.action_cost(UnitStats.Action.GRENADE), player.grenade_charges]
	buttons["move"].disabled = not is_player or not player.can_afford(player.move_ap_per_tile())
	buttons["shoot"].disabled = not is_player \
		or not player.can_afford(player.action_cost(UnitStats.Action.SHOOT)) or not player.can_shoot()
	# Gated on the Torso, the cheapest zone — the per-zone prices are on the menu
	# itself, where the zone is actually chosen.
	buttons["aimed_shot"].disabled = not is_player \
		or not player.can_afford(player.min_aimed_shot_cost()) or not player.can_shoot()
	buttons["suppress"].disabled = not is_player \
		or not player.can_afford(player.action_cost(UnitStats.Action.SUPPRESS)) or not player.can_suppress()
	buttons["grenade"].disabled = not is_player \
		or not player.can_afford(player.action_cost(UnitStats.Action.GRENADE)) or player.grenade_charges <= 0
	buttons["hunker"].disabled = not is_player or not player.can_afford(player.action_cost(UnitStats.Action.HUNKER))
	buttons["overwatch"].disabled = not is_player \
		or not player.can_afford(player.action_cost(UnitStats.Action.OVERWATCH)) or not player.can_shoot()
	buttons["reload"].disabled = not is_player \
		or not player.can_afford(player.action_cost(UnitStats.Action.RELOAD)) or not player.can_reload()
	# Both free actions (Sec 4.2) — no AP gate on either.
	buttons["face"].disabled = not is_player
	buttons["flashlight"].disabled = not is_player
	buttons["end_turn"].disabled = not is_player
	# Out of combat: no activation to end and nothing to hunker against (E21), and
	# the one way to pass time without acting (plan B.10).
	var exploring := TurnManager.in_exploration()
	buttons["hunker"].visible = not exploring
	buttons["end_turn"].visible = not exploring
	buttons["wait"].visible = exploring
	buttons["wait"].disabled = not is_player
	buttons["move"].text = "Move" if exploring else "Move (1-2)"
	# Extraction (GDD §7.3–7.4): SHOWN only where they could work — in a callable
	# bay, in the square of our landed ship — rather than greyed out everywhere,
	# since for most of a mission neither applies and two dead buttons are noise.
	# The where is ExtractionManager's question; the AP is priced here like the
	# rest (both flat, so Reflexes never moves these numbers).
	#
	# Board shows in the square of our landed ship. Extract shows on EVERY one of
	# the crew's activations once it is valid (our ship down, somebody aboard or
	# in its square) — the soldier asking need not be anywhere near it.
	var call_ok := is_player and ExtractionManager.callable_hangar_for(player) >= 0
	var board_ok := is_player and ExtractionManager.board_hangar_for(player) >= 0
	var extract_ok := is_player and ExtractionManager.extract_blocker(player) == ""
	buttons["call_ship"].visible = call_ok
	buttons["board"].visible = board_ok
	buttons["extract"].visible = extract_ok
	if is_player:
		_label_cost(buttons["call_ship"], "Call ship", player.action_cost(UnitStats.Action.CALL_SHIP))
		_label_cost(buttons["board"], "Board ship", player.action_cost(UnitStats.Action.BOARD_SHIP))
		_label_cost(buttons["extract"], "EXTRACT", player.action_cost(UnitStats.Action.EXTRACT))
		buttons["call_ship"].disabled = not player.can_afford(player.action_cost(UnitStats.Action.CALL_SHIP))
		buttons["board"].disabled = not player.can_afford(player.action_cost(UnitStats.Action.BOARD_SHIP))
		buttons["extract"].disabled = false
	# GDD §4.3: primary <-> pistol. Hidden while carrying (the pistol is forced)
	# and for anyone without a sidearm.
	var switch_ok := is_player and player.switch_weapon_blocker() == ""
	buttons["switch"].visible = switch_ok
	if switch_ok:
		var other: WeaponData = player.stats.weapon if player.stats.sidearm_drawn else player.stats.sidearm
		_label_cost(buttons["switch"], "Switch to %s" % (other.display_name if other else "weapon"),
			player.action_cost(UnitStats.Action.SWITCH_WEAPON))
		buttons["switch"].disabled = not player.can_afford(player.action_cost(UnitStats.Action.SWITCH_WEAPON))
	# GDD §4.4, same rule as the ship buttons: shown only when there is a body in
	# reach the action would accept (any player's — cross-player rescue, §7.6),
	# greyed only on AP. Drop is shown whenever something is carried, and is free.
	var revive_ok := is_player and not player.body_targets(PlayerUnit.Mode.REVIVE).is_empty()
	var pick_ok := is_player and not player.body_targets(PlayerUnit.Mode.PICK_UP).is_empty()
	buttons["revive"].visible = revive_ok
	buttons["pick_up"].visible = pick_ok
	buttons["drop"].visible = is_player and player.carrying != null
	if is_player:
		_label_cost(buttons["revive"], "Revive", player.action_cost(UnitStats.Action.REVIVE))
		_label_cost(buttons["pick_up"], "Pick up", player.action_cost(UnitStats.Action.PICK_UP))
		buttons["revive"].disabled = not player.can_afford(player.action_cost(UnitStats.Action.REVIVE))
		buttons["pick_up"].disabled = not player.can_afford(player.action_cost(UnitStats.Action.PICK_UP))
		buttons["drop"].disabled = false
	# Extraction plan 3.2, the same rule again: shown when there is something in
	# reach to take (a crate, a pile, a corpse with anything on it — any player's,
	# GDD §7.6) or something in the pack to drop. Never greyed: dropping is free,
	# and each Take row inside greys itself on AP and on a full pack.
	var sources: Array = player.loot_sources() if is_player else []
	buttons["loot"].visible = is_player and (not sources.is_empty() or not player.inventory.is_empty())
	if is_player:
		buttons["loot"].text = "Loot (%d)" % player.action_cost(UnitStats.Action.LOOT) \
			if not sources.is_empty() else "Pack"
		buttons["loot"].disabled = false
	if _loot_panel != null and _loot_panel.visible:
		_refresh_loot_panel()
	# Hold (extraction plan Phase 6), the same rule as the rest: shown only beside
	# a console that can be started or restarted, greyed only on AP.
	var terminal_ok := is_player and ObjectiveManager.operate_blocker(player) == ""
	buttons["terminal"].visible = terminal_ok
	if is_player:
		var cost := player.action_cost(UnitStats.Action.OPERATE_TERMINAL)
		var resume := ObjectiveManager.terminal_rules != null \
			and ObjectiveManager.terminal_rules.state == TerminalRules.State.PAUSED
		_label_cost(buttons["terminal"], "Restart terminal" if resume else "Operate terminal", cost)
		buttons["terminal"].disabled = not player.can_afford(cost)


## Wait (plan B.10), beside the hud.tscn action buttons like the terminal's.
func _build_wait_button() -> void:
	var b := Button.new()
	b.name = "Wait"
	b.visible = false
	$Actions.add_child(b)
	buttons["wait"] = b
	b.pressed.connect(func() -> void:
		var player := _active_player()
		if player:
			player._issue(&"try_wait"))


## The objective line and the mode banner share a stack under the radio banner,
## so a multi-line objective (status + door gun) pushes the banner down instead
## of drawing over it. Hidden rows take no space.
func _build_mode_label() -> void:
	var stack := VBoxContainer.new()
	stack.name = "TopCenterStack"
	stack.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	stack.offset_left = -300.0
	stack.offset_right = 300.0
	stack.offset_top = 56.0
	stack.offset_bottom = 56.0
	stack.grow_horizontal = Control.GROW_DIRECTION_BOTH
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_theme_constant_override("separation", 4)
	add_child(stack)
	objective_label.reparent(stack, false)
	objective_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mode_label = Label.new()
	_mode_label.name = "ModeLabel"
	_mode_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mode_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mode_label.visible = false
	stack.add_child(_mode_label)


func _build_portrait_bar() -> void:
	_portrait_bar = GridContainer.new()
	_portrait_bar.name = "SquadFeed"
	_portrait_bar.columns = 1
	_portrait_bar.position = Vector2(SQUAD_FEED_MARGIN, SQUAD_FEED_MARGIN)
	_portrait_bar.add_theme_constant_override("v_separation", 4)
	_portrait_bar.add_theme_constant_override("h_separation", 8)
	# Only the cards may take a click from the deck.
	_portrait_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_portrait_bar)
	# The unit panel (and the loot panel pinned under it) sits below the feed.
	var unit_panel: Control = $UnitPanel
	var place := func() -> void:
		var below := _portrait_bar.get_rect().end.y if _portrait_bar.get_child_count() > 0 \
			else SQUAD_FEED_MARGIN - 8.0
		unit_panel.position.y = below + 8.0
	_portrait_bar.resized.connect(place)
	place.call()


## The banner and the clock: "EXPLORING — round 7 · 12 / 20 steps", or just the
## round in a fight. Also what the Wait button promises.
func _refresh_mode_label() -> void:
	if _mode_label == null:
		return
	_mode_label.visible = TurnManager.turn_number > 0 and not TurnManager.mission_over
	if TurnManager.in_exploration():
		_mode_label.text = "EXPLORING — round %d  ·  %d / %d steps" % [
			TurnManager.turn_number, TurnManager.steps, TurnManager.STEPS_PER_ROUND]
	else:
		_mode_label.text = "COMBAT — round %d" % TurnManager.turn_number
	buttons["wait"].text = "Wait → round %d" % (TurnManager.turn_number + 1)


func _on_mode_changed(_mode: int) -> void:
	_hide_aimed_shot_menu()
	_hide_grenade_menu()
	# The soldiers disarm themselves, but by now none is selected to own the overlay.
	var highlights := get_tree().get_first_node_in_group("highlights")
	if highlights:
		highlights.clear_highlights()
	_refresh_mode_label()
	_refresh(TurnManager.active_unit)
	_refresh_portraits()


## One button per soldier on the board, read off replicated state, so a co-op
## partner's soldiers need no sync of their own (plan C.5). Polled with the body
## labels; a soldier gone aboard drops off the bar.
func _refresh_portraits() -> void:
	if _portrait_bar == null:
		return
	var squad: Array[Unit] = []
	for node in get_tree().get_nodes_in_group("player_units"):
		var unit := node as Unit
		if unit:
			squad.append(unit)
	squad.sort_custom(func(a: Unit, b: Unit) -> bool: return String(a.name) < String(b.name))
	for unit: Variant in _portraits.keys():
		if not is_instance_valid(unit) or not squad.has(unit):
			_portraits[unit].queue_free()
			_portraits.erase(unit)
	_portrait_bar.columns = 2 if squad.size() > CampaignEconomy.MAX_SQUAD else 1
	# No renderer, no faces: a headless run keeps the cards (and their vitals)
	# but skips the cameras.
	var live_feed := DisplayServer.get_name() != "headless"
	for i in squad.size():
		var unit := squad[i]
		var card: SquadFeedCard = _portraits.get(unit)
		if card == null:
			card = SquadFeedCard.new()
			_portrait_bar.add_child(card)
			card.setup(unit, live_feed)
			_portraits[unit] = card
		if card.get_index() != i:
			_portrait_bar.move_child(card, i)
		card.refresh(unit == TurnManager.active_unit, unit.is_owned_by_local_player())


## J: NORMAL -> ALL (debug builds only) -> NONE -> NORMAL. Every label owner
## re-applies the new mode now, not on its next refresh, so the press is instant.
func _cycle_name_tags() -> void:
	NameTags.cycle()
	get_tree().call_group("units", "_sync_label")
	get_tree().call_group(NameTags.PROP_GROUP, "apply_name_tag_mode")
	_refresh_body_labels()
	_refresh_hangar_markers()
	_show_radio_banner("Labels: %s" % NameTags.mode_name())


## K: bullet tracers on/off (VfxManager.tracers_enabled). Local to this client;
## a round in flight when it is pressed finishes its flight.
func _toggle_tracers() -> void:
	VFX.tracers_enabled = not VFX.tracers_enabled
	_show_radio_banner("Tracers: %s" % ("ON" if VFX.tracers_enabled else "OFF"))


func _on_command_rejected(reason: String) -> void:
	_on_extraction_notice(reason, true)


## Tab walks this player's own standing soldiers (E24), exploration only: in a
## fight the draw decides who is up. With a shot mode armed it walks the targets
## instead, in either mode, Shift+Tab backwards.
func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == KEY_J:
		_cycle_name_tags()
		get_viewport().set_input_as_handled()
		return
	if key != null and key.pressed and not key.echo and key.keycode == KEY_K:
		_toggle_tracers()
		get_viewport().set_input_as_handled()
		return
	if key == null or not key.pressed or key.echo or key.keycode != KEY_TAB:
		return
	if _target_bar != null and _target_bar.visible and not _skull_targets.is_empty():
		_cycle_target(-1 if key.shift_pressed else 1)
		get_viewport().set_input_as_handled()
		return
	if not TurnManager.in_exploration():
		return
	var squad := TurnManager.own_squad()
	if squad.is_empty():
		return
	var at := squad.find(TurnManager.active_unit) if is_instance_valid(TurnManager.active_unit) else -1
	TurnManager.select(squad[(at + 1) % squad.size()])
	get_viewport().set_input_as_handled()


## The Hold console's button (Phase 6). Built in code beside the hud.tscn action
## buttons rather than added to the scene, like the loot panel.
func _build_terminal_button() -> void:
	var b := Button.new()
	b.name = "Terminal"
	b.text = "Operate terminal"
	b.visible = false
	$Actions.add_child(b)
	buttons["terminal"] = b
	b.pressed.connect(_on_terminal)


func _on_terminal() -> void:
	_hide_aimed_shot_menu()
	_hide_grenade_menu()
	var player := _active_player()
	if player:
		await player._issue(&"try_operate_terminal")
		_refresh(TurnManager.active_unit)


## "●●○" — downs taken against the downs a soldier can survive (Unit.MAX_DOWNS - 1;
## the next one past that kills).
func _down_pips(unit: Unit) -> String:
	var survivable := Unit.MAX_DOWNS - 1
	var pips := ""
	for i in survivable:
		pips += "●" if i < unit.down_count else "○"
	return pips


func _label_cost(button: Button, label: String, cost: int) -> void:
	button.text = "%s (%d)" % [label, cost]


func _set_mode(mode: PlayerUnit.Mode) -> void:
	_hide_aimed_shot_menu()
	_hide_grenade_menu()
	var player := _active_player()
	if player:
		player.set_mode(mode)
	_refresh_target_bar()


func _build_target_bar() -> void:
	_target_bar = VBoxContainer.new()
	_target_bar.name = "TargetBar"
	_target_bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	# Over the portrait bar, which sits over the action bar.
	_target_bar.offset_top = -236.0
	_target_bar.offset_bottom = -120.0
	_target_bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_target_bar.alignment = BoxContainer.ALIGNMENT_END
	_target_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_target_bar.visible = false
	add_child(_target_bar)

	_target_info = Label.new()
	_target_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_target_info.add_theme_constant_override("outline_size", 6)
	_target_info.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_target_info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_target_bar.add_child(_target_info)

	_confirm_button = Button.new()
	_confirm_button.name = "Confirm"
	_confirm_button.text = "Confirm"
	_confirm_button.focus_mode = Control.FOCUS_NONE
	_confirm_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_confirm_button.custom_minimum_size = Vector2(140, 0)
	_confirm_button.visible = false
	_confirm_button.pressed.connect(_on_confirm_target)
	_target_bar.add_child(_confirm_button)

	_skull_row = HBoxContainer.new()
	_skull_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_skull_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_target_bar.add_child(_skull_row)

	_target_marker = TargetMarker.new()
	add_child(_target_marker)


## Rebuilt only when the list of targets changes, so a skull under the cursor is
## not freed out from under its hover between two polls.
func _refresh_target_bar() -> void:
	if _target_bar == null:
		return
	var player := _active_player()
	var armed := player != null and player.is_owned_by_local_player() and not player.is_downed \
		and not player.is_busy and not TurnManager.mission_over \
		and player.mode in [PlayerUnit.Mode.SHOOT, PlayerUnit.Mode.AIMED_SHOT, PlayerUnit.Mode.SUPPRESS]
	var targets: Array[Unit] = []
	if armed:
		targets = player.shot_targets()
	if targets != _skull_targets:
		_skull_targets = targets
		for skull in _skulls:
			skull.queue_free()
		_skulls.clear()
		for target in targets:
			_skulls[_make_skull(target)] = target
	if armed and player.picked_target != null and not targets.has(player.picked_target):
		player.pick_target(null)  # died, or slipped out of sight
	if _hovered_skull != null and not targets.has(_hovered_skull):
		_hovered_skull = null
	_target_bar.visible = armed
	var picked: Unit = player.picked_target if armed else null
	_target_marker.target = picked
	_confirm_button.visible = picked != null
	for skull: Button in _skulls:
		skull.set_pressed_no_signal(_skulls[skull] == picked)
		skull.queue_redraw()
	var shown := _hovered_skull if _hovered_skull != null else picked
	if shown != null:
		_target_info.text = _target_line(player, shown)
	elif not targets.is_empty():
		_target_info.text = "Pick a target"
	else:
		_target_info.text = "No targets in sight"


func _make_skull(target: Unit) -> Button:
	var skull := Button.new()
	skull.toggle_mode = true
	skull.focus_mode = Control.FOCUS_NONE
	skull.custom_minimum_size = Vector2(SKULL_SIZE, SKULL_SIZE)
	# A child rather than the button's own _draw, so it lands over the panel.
	var glyph := SkullGlyph.new()
	glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glyph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	glyph.picked = func() -> bool: return skull.button_pressed
	skull.add_child(glyph)
	skull.pressed.connect(_on_skull_pressed.bind(target))
	skull.mouse_entered.connect(_on_skull_hover.bind(target, true))
	skull.mouse_exited.connect(_on_skull_hover.bind(target, false))
	_skull_row.add_child(skull)
	return skull


## "Lurker — 64% to hit": the odds the shot would be taken at, read fresh.
func _target_line(player: PlayerUnit, target: Unit) -> String:
	var who := target.stats.display_name
	match player.mode:
		PlayerUnit.Mode.SUPPRESS:
			return "%s — suppress (pins them, no roll)" % who
		PlayerUnit.Mode.AIMED_SHOT:
			return "%s — %d%% to hit (torso; pick a zone next)" % [who, player.target_hit_chance(target)]
	return "%s — %d%% to hit" % [who, player.target_hit_chance(target)]


func _on_skull_pressed(target: Unit) -> void:
	var player := _active_player()
	if player:
		player.pick_target(target)
	_refresh_target_bar()


## Hovering a skull also puts the map's hit-chance label over that target, so
## the player can see WHICH alien the skull is.
func _on_skull_hover(target: Unit, entered: bool) -> void:
	if entered:
		_hovered_skull = target
	elif _hovered_skull == target:
		_hovered_skull = null
	var highlights := get_tree().get_first_node_in_group("highlights")
	if highlights and is_instance_valid(target):
		highlights.set_hovered_target(target.grid_pos if entered else PlayerUnit.NO_TILE)
	_refresh_target_bar()


## Picks the next skull along (`step` 1 or -1), wrapping; from no pick, the
## first (or the last, going backwards).
func _cycle_target(step: int) -> void:
	var player := _active_player()
	if player == null:
		return
	var at := _skull_targets.find(player.picked_target)
	if at == -1:
		at = -1 if step > 0 else 0
	var next := posmod(at + step, _skull_targets.size())
	player.pick_target(_skull_targets[next])
	_refresh_target_bar()


func _on_target_picked(_target: Unit) -> void:
	_refresh_target_bar()


func _on_confirm_target() -> void:
	var player := _active_player()
	if player == null:
		return
	player.confirm_target()
	_refresh_target_bar()


## A skull drawn in code (no icon asset to import): a round cranium over a jaw,
## dark sockets, and teeth. Bone-white, red once its target is picked.
class SkullGlyph extends Control:
	const BONE := Color(0.92, 0.9, 0.84)
	const PICKED := Color(1.0, 0.25, 0.2)
	var picked: Callable

	func _draw() -> void:
		var s := minf(size.x, size.y)
		var o := (size - Vector2(s, s)) / 2.0
		var color: Color = PICKED if picked.is_valid() and picked.call() else BONE
		var dark := Color(0.08, 0.06, 0.06)
		draw_circle(o + Vector2(0.5, 0.42) * s, 0.3 * s, color)
		draw_rect(Rect2(o + Vector2(0.32, 0.55) * s, Vector2(0.36, 0.22) * s), color)
		draw_circle(o + Vector2(0.38, 0.45) * s, 0.085 * s, dark)
		draw_circle(o + Vector2(0.62, 0.45) * s, 0.085 * s, dark)
		draw_colored_polygon(PackedVector2Array([o + Vector2(0.5, 0.55) * s,
			o + Vector2(0.46, 0.63) * s, o + Vector2(0.54, 0.63) * s]), dark)
		for x: float in [0.41, 0.5, 0.59]:
			draw_line(o + Vector2(x, 0.68) * s, o + Vector2(x, 0.77) * s, dark, maxf(1.0, s * 0.03))


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
	var through := Penetration.through_penalty(player, target)
	for part in body_part_buttons:
		var acc := clampi(Combat.compute_accuracy(player, target, Combat.ShotAction.AIMED_SHOT, part) - through, 1, 99)
		var cost := player.aimed_shot_cost(part)
		body_part_buttons[part].text = "%s — %d AP (%d%%)" % [Combat.body_part_name(part), cost, acc]
		body_part_buttons[part].disabled = not player.can_afford(cost)
	aimed_shot_menu.visible = true


func _on_menu_pick(part: int) -> void:
	var player := _active_player()
	var target := _aimed_shot_target
	_hide_aimed_shot_menu()
	if player == null or target == null:
		return
	await player._issue(&"fire_aimed_shot", [target, part])
	_refresh(TurnManager.active_unit)


func _on_aimed_shot_cancel() -> void:
	_hide_aimed_shot_menu()


func _hide_aimed_shot_menu() -> void:
	aimed_shot_menu.visible = false
	_aimed_shot_target = null


## Mirrors `_on_aimed_shot_target_picked` one throw earlier: a legal tile has
## already been clicked (`_try_pick_grenade_target` re-validated it), so this
## just asks which payload to spend the charge on. Both payloads draw from the
## same charge, so neither button is disabled independently of the other —
## `buttons["grenade"]` being enabled already means the charge and AP are there.
func _on_grenade_target_picked(target: Vector3i) -> void:
	var player := _active_player()
	if player == null:
		return
	_grenade_target = target
	grenade_menu.visible = true


func _on_grenade_type_pick(type: int) -> void:
	var player := _active_player()
	var target := _grenade_target
	_hide_grenade_menu()
	if player == null or target == PlayerUnit.NO_TILE:
		return
	await player._issue(&"_try_throw_grenade", [target, type])
	_refresh(TurnManager.active_unit)


func _on_grenade_cancel() -> void:
	_hide_grenade_menu()


func _hide_grenade_menu() -> void:
	grenade_menu.visible = false
	_grenade_target = PlayerUnit.NO_TILE


func _on_hunker() -> void:
	_hide_aimed_shot_menu()
	_hide_grenade_menu()
	var player := _active_player()
	if player:
		player._issue(&"try_hunker")
		_refresh(player)


func _on_overwatch() -> void:
	_hide_aimed_shot_menu()
	_hide_grenade_menu()
	var player := _active_player()
	if player:
		player._issue(&"try_overwatch")
		_refresh(player)


func _on_reload() -> void:
	_hide_aimed_shot_menu()
	_hide_grenade_menu()
	var player := _active_player()
	if player:
		player._issue(&"try_reload")
		_refresh(player)


func _on_flashlight() -> void:
	var player := _active_player()
	if player:
		player._issue(&"try_toggle_flashlight")
		_refresh(player)


func _on_drop() -> void:
	_hide_aimed_shot_menu()
	_hide_grenade_menu()
	var player := _active_player()
	if player:
		await player._issue(&"try_drop")
		_refresh(TurnManager.active_unit)


# --- Loot panel and objective line (extraction plan 3.2–3.3) ---------------------

## Panel width in pixels. Wide enough for "Assault Rifle (Holo Sight, Suppressor)".
const LOOT_PANEL_WIDTH := 420


func _build_loot_panel() -> void:
	_loot_panel = PanelContainer.new()
	_loot_panel.name = "LootPanel"
	_loot_panel.visible = false
	# Left side, under the unit panel: the board stays visible on the right, where
	# the log is, and the soldier being looted for is described right above it.
	# Pinned under the unit panel's actual bottom, which moves with its line count
	# (injuries, downs, pack contents).
	var unit_panel: Control = $UnitPanel
	var place := func() -> void:
		_loot_panel.position = Vector2(12, unit_panel.get_rect().end.y + 10.0)
	# item_rect_changed, not resized: the squad feed above moves the panel too.
	unit_panel.item_rect_changed.connect(place)
	_loot_panel.custom_minimum_size = Vector2(LOOT_PANEL_WIDTH, 0)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(LOOT_PANEL_WIDTH, 320)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_loot_rows = VBoxContainer.new()
	_loot_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_loot_rows)
	_loot_panel.add_child(scroll)
	add_child(_loot_panel)
	place.call()


func _on_loot() -> void:
	_hide_aimed_shot_menu()
	_hide_grenade_menu()
	if _loot_panel.visible:
		_hide_loot_panel()
		return
	_loot_panel.visible = true
	_refresh_loot_panel()


func _hide_loot_panel() -> void:
	if _loot_panel:
		_loot_panel.visible = false


func _on_inventory_changed(unit: Unit) -> void:
	if unit == TurnManager.active_unit:
		_refresh(unit)


## Rebuilds every row from the active soldier's sources in reach and pack. Rows
## carry the item's CODE as well as its index, so a source that changed between
## the draw and the click takes nothing rather than the wrong item (try_loot's
## `expect_code`).
func _refresh_loot_panel() -> void:
	if _loot_panel == null or not _loot_panel.visible:
		return
	for child in _loot_rows.get_children():
		_loot_rows.remove_child(child)
		child.queue_free()
	var player := _active_player()
	if player == null or player.is_downed or not player.is_owned_by_local_player():
		_hide_loot_panel()
		return
	var cost := player.action_cost(UnitStats.Action.LOOT)
	var can_take := player.can_afford(cost) and player.has_free_slot()
	for source in player.loot_sources():
		_loot_rows.add_child(_loot_heading(source.loot_name()))
		var items: Array = source.loot_items()
		for i in items.size():
			var item: ItemData = items[i]
			var take := Button.new()
			take.text = "Take (%d AP)" % cost
			take.disabled = not can_take
			take.pressed.connect(_on_take.bind(source, i, item.code))
			_loot_rows.add_child(_loot_row(item, take))
	_loot_rows.add_child(_loot_heading("Pack %d/%d" % [player.inventory.size(), Unit.INVENTORY_SLOTS]))
	for i in player.inventory.size():
		var drop := Button.new()
		drop.text = "Drop (0)"
		drop.pressed.connect(_on_drop_item.bind(i))
		_loot_rows.add_child(_loot_row(player.inventory[i], drop))
	var close := Button.new()
	close.text = "Close"
	close.pressed.connect(_hide_loot_panel)
	_loot_rows.add_child(close)


func _loot_heading(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", Color(1, 0.85, 0.4))
	return label


func _loot_row(item: ItemData, button: Button) -> HBoxContainer:
	var row := HBoxContainer.new()
	var label := Label.new()
	var kind := "OBJECTIVE" if item.is_objective() else ("gear" if item.is_gear() else "%d cr" % item.value)
	label.text = "%s  [%s]" % [item.display_name, kind]
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.clip_text = true
	row.add_child(label)
	row.add_child(button)
	return row


func _on_take(source: Object, index: int, code: String) -> void:
	var player := _active_player()
	if player and is_instance_valid(source):
		await player._issue(&"try_loot", [source, index, code])
		_refresh(TurnManager.active_unit)
		_refresh_loot_panel()


func _on_drop_item(index: int) -> void:
	var player := _active_player()
	if player:
		await player._issue(&"try_drop_item", [index])
		_refresh(TurnManager.active_unit)
		_refresh_loot_panel()


func _refresh_objective() -> void:
	var text: String = ObjectiveManager.status_text()
	# The player's ship's door gun (GDD §7.4, plan Phase 5) shares the line: it is
	# the other thing about the way out the player has to keep an eye on, and the
	# hangar marker that also shows it is off screen as often as not.
	if ExtractionManager.is_active():
		var gun_line := _door_gun_line()
		text = gun_line if text.is_empty() else "%s\n%s" % [text, gun_line]
	objective_label.text = text
	objective_label.visible = text != ""


## "Door gun: none / ACTIVE 24/30 / DISABLED" for the player crew's ship.
func _door_gun_line() -> String:
	match ExtractionManager.door_gun_status(ExtractionRules.PLAYER_CREW):
		ExtractionManager.DoorGunStatus.ACTIVE:
			var gun := ExtractionManager.door_gun(ExtractionManager.claim_of(ExtractionRules.PLAYER_CREW))
			return "Door gun: ACTIVE %d/%d" % [gun.current_hp, gun.stats.max_hp()]
		ExtractionManager.DoorGunStatus.DISABLED:
			return "Door gun: DISABLED"
	return "Door gun: none"


# --- Bodies: downed bars over the deck (extraction plan 2.6) -------------------


func _process(delta: float) -> void:
	_target_bar_clock -= delta
	if _target_bar_clock <= 0.0:
		_target_bar_clock = TARGET_BAR_REFRESH
		_refresh_target_bar()
	_body_label_clock -= delta
	if _body_label_clock > 0.0:
		return
	_body_label_clock = BODY_LABEL_REFRESH
	_refresh_body_labels()
	_refresh_portraits()
	_refresh_exploration_selection()
	# Polled on the same clock for the same reason as the body labels: a client
	# hears no `downed` for the nest or `inventory_changed` for a squadmate's
	# corpse until replication lands, and the line is one cheap string.
	if ObjectiveManager.is_active() or ExtractionManager.is_active():
		_refresh_objective()
	# The door gun's HP line (Phase 5) moves with every hit it takes, and a
	# client learns those through replication rather than any signal it hears.
	if ExtractionManager.is_active():
		_refresh_hangar_markers()


## Out of combat, on the same poll: the soldier this peer had selected may have gone
## down or aboard (plan C.5), and one that walked somewhere new may have new things
## in reach. Compared first, because `_refresh` rebuilds an open loot panel.
func _refresh_exploration_selection() -> void:
	if not TurnManager.in_exploration() or TurnManager.mission_over:
		return
	if not is_instance_valid(TurnManager.active_unit) or TurnManager.active_unit.is_downed \
			or TurnManager.active_unit.aboard:
		TurnManager.reselect_local()
		return
	if TurnManager.active_unit.grid_pos != _shown_tile:
		_refresh(TurnManager.active_unit)


## One label per body: "Okafor ▮▮▮▯▯ 12/20 ●○" in red while downed (the bar, its
## numbers, the pips), grey "Okafor — DEAD" once a corpse. Hidden while the body
## is carried (it is hidden itself) or its unit is out of the rendered set.
func _refresh_body_labels() -> void:
	# The Recover VIP (Phase 6) gets one too — it is a body the player is looking
	# for — reading "VIP <name> — stable 20/20" (it does not bleed).
	var bodies: Array = get_tree().get_nodes_in_group("player_units")
	bodies.append_array(get_tree().get_nodes_in_group(VipUnit.GROUP))
	for node in bodies:
		var unit := node as Unit
		if unit == null or not is_instance_valid(unit):
			continue
		var label: Label3D = _body_labels.get(unit)
		if unit.life_state == Unit.LifeState.ACTIVE:
			if label and is_instance_valid(label):
				label.visible = false
			continue
		if label == null or not is_instance_valid(label):
			label = Label3D.new()
			label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			label.no_depth_test = true
			label.fixed_size = true
			label.font_size = 18
			label.outline_size = 6
			label.outline_modulate = Color(0, 0, 0, 0.85)
			label.position = Vector3(0, BODY_LABEL_HEIGHT, 0)
			unit.add_child(label)
			_body_labels[unit] = label
		if unit.life_state == Unit.LifeState.DEAD:
			label.text = "%s — DEAD" % unit.stats.display_name
			label.modulate = Color(0.65, 0.65, 0.68)
		elif unit is VipUnit:
			label.text = "VIP %s — stable %d/%d" % [unit.stats.display_name, unit.downed_hp, unit.downed_bar_max()]
			label.modulate = Color(0.6, 0.85, 1.0)
		else:
			label.text = "%s %s %d/%d %s" % [unit.stats.display_name,
				_bar(unit.downed_hp, unit.downed_bar_max()), unit.downed_hp,
				unit.downed_bar_max(), _down_pips(unit)]
			label.modulate = Color(1.0, 0.3, 0.25)
		# The J key's NONE mode keeps this side's own bodies but drops the VIP's.
		label.visible = unit.visible and unit.carried_by == null \
			and not (unit is VipUnit and NameTags.mode == NameTags.Mode.NONE)


## A five-cell text bar for `value` out of `max_value`, rounded up so a sliver of
## bar left never draws as empty.
func _bar(value: int, max_value: int) -> String:
	const CELLS := 5
	var filled := ceili(float(value) / maxf(1.0, float(max_value)) * CELLS)
	return "▮".repeat(filled) + "▯".repeat(CELLS - filled)


func _on_call_ship() -> void:
	_hide_aimed_shot_menu()
	_hide_grenade_menu()
	var player := _active_player()
	if player:
		await player._issue(&"try_call_ship")
		_refresh(TurnManager.active_unit)


## Board ship and Switch weapon (GDD §7.4, §4.3), built in code beside the
## hud.tscn action buttons like the terminal's. The scene's DustOff button is
## reused as EXTRACT — the player crew no longer signals dust-off.
func _build_ship_buttons() -> void:
	for spec in [["board", "BoardShip", "Board ship", _on_board],
			["switch", "SwitchWeapon", "Switch weapon", _on_switch_weapon]]:
		var b := Button.new()
		b.name = spec[1]
		b.text = spec[2]
		b.visible = false
		$Actions.add_child(b)
		buttons[spec[0]] = b
		b.pressed.connect(spec[3])
	_extract_confirm = ConfirmationDialog.new()
	_extract_confirm.title = "Extract"
	_extract_confirm.ok_button_text = "Extract"
	_extract_confirm.confirmed.connect(_issue_extract)
	add_child(_extract_confirm)


var _extract_confirm: ConfirmationDialog = null


func _on_board() -> void:
	_hide_aimed_shot_menu()
	_hide_grenade_menu()
	var player := _active_player()
	if player:
		await player._issue(&"try_board_ship")
		_refresh(TurnManager.active_unit)


func _on_switch_weapon() -> void:
	_hide_aimed_shot_menu()
	_hide_grenade_menu()
	var player := _active_player()
	if player:
		await player._issue(&"try_switch_weapon")
		_refresh(TurnManager.active_unit)


## Extract ends the mission and leaves everyone outside the square behind, for
## good — so when that is anyone, it asks first, naming them.
func _on_extract() -> void:
	_hide_aimed_shot_menu()
	_hide_grenade_menu()
	var left := _left_behind_if_extracting()
	if left.is_empty():
		_issue_extract()
		return
	_extract_confirm.dialog_text = "Extract now? The ship leaves at once.\nLeft behind for good: %s" \
		% ", ".join(left)
	_extract_confirm.popup_centered()


func _issue_extract() -> void:
	var player := _active_player()
	if player:
		await player._issue(&"try_extract")


## Names of the squad still on the board and outside the claimed square: who an
## Extract right now would leave behind (dead included — their bodies stay).
func _left_behind_if_extracting() -> PackedStringArray:
	var out := PackedStringArray()
	var index := ExtractionManager.claim_of(ExtractionRules.PLAYER_CREW)
	if index < 0:
		return out
	var h := ExtractionManager.hangar(index)
	for node in get_tree().get_nodes_in_group("player_units"):
		var unit := node as Unit
		if unit == null:
			continue
		# A carried body goes wherever its carrier goes.
		var mover: Unit = unit.carried_by if unit.carried_by != null else unit
		if h.in_square(mover.grid_pos) and mover.life_state != Unit.LifeState.DEAD:
			continue
		out.append(unit.stats.display_name + (" (dead)" if unit.life_state == Unit.LifeState.DEAD else ""))
	return out


# --- Extraction: markers, radio ------------------------------------------------


func _on_extraction_notice(text: String, radio: bool) -> void:
	append_log(text)
	if not radio:
		return
	_show_radio_banner(text)


## Puts `text` across the top for RADIO_BANNER_SECONDS, with no log entry.
func _show_radio_banner(text: String) -> void:
	radio_banner.text = text
	radio_banner.visible = true
	# One timer per notice; a newer notice replaces the text and only ITS timer
	# may hide it, so a stale timeout cannot cut the fresh line short.
	var timer := get_tree().create_timer(RADIO_BANNER_SECONDS)
	_radio_timer = timer
	timer.timeout.connect(func() -> void:
		if _radio_timer == timer:
			radio_banner.visible = false)


func _on_hangar_changed(_index: int) -> void:
	_refresh_hangar_markers()
	# A landing or a call changes which of Call ship / Board / Extract the active
	# soldier can use, without that soldier having done anything.
	_refresh(TurnManager.active_unit)


## A fresh marker per hangar on the new deck. Hidden until discovered.
func _rebuild_hangar_markers() -> void:
	for index in _hangar_markers:
		var old: Node = _hangar_markers[index]
		if is_instance_valid(old):
			old.queue_free()
	_hangar_markers.clear()
	if not ExtractionManager.is_active():
		return
	var map := get_tree().get_first_node_in_group("map") as Node3D
	if map == null:
		return
	for i in ExtractionManager.rules.hangar_count():
		var label := Label3D.new()
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true  # readable through the walls round the bay
		label.fixed_size = true
		label.font_size = 22
		label.outline_size = 6
		label.outline_modulate = Color(0, 0, 0, 0.85)
		label.visible = false
		map.add_child(label)
		label.global_position = GridManager.grid_to_world(ExtractionManager.hangar(i).pad_center) \
			+ Vector3(0, HANGAR_MARKER_HEIGHT, 0)
		_hangar_markers[i] = label
	_refresh_hangar_markers()


## Text and visibility for every marker, from the state the rules hold now plus
## the current round. Undiscovered hangars stay hidden even mid-call by another
## crew: hearing a call-in never reveals where it was (GDD §7.3).
func _refresh_hangar_markers() -> void:
	var rules: ExtractionRules = ExtractionManager.rules
	var turn := TurnManager.turn_number
	for i in _hangar_markers:
		var label: Label3D = _hangar_markers[i]
		if not is_instance_valid(label) or not rules.is_valid(i):
			continue
		label.visible = NameTags.shows_hangar(rules.is_discovered(i))
		var title := "[ %s ]" % ExtractionManager.hangar_name(i)
		var s := rules.states[i]
		var ours := s.claimed_by == ExtractionRules.PLAYER_CREW
		var line := ""
		var color := Color(0.75, 0.9, 1.0)
		match s.state:
			ExtractionRules.State.CALLED:
				var n := rules.rounds_until_arrival(i, turn)
				line = ("Ship in %d" % n) if ours else "Claimed"
				color = Color(1.0, 0.85, 0.3)
			ExtractionRules.State.LANDED:
				var left := rules.rounds_until_departure(i, turn)
				line = ("Departs in %d" % left) if left > 0 else "Departs this round"
				if not ours:
					line = "Another crew's ship"
				color = Color(0.4, 1.0, 0.5)
				# The ship's gunner (GDD §7.4, plan Phase 5): its HP while it
				# fights, DISABLED once it has been shot quiet. HP and disabled
				# state only — its Initiative stays hidden like any non-soldier's.
				var gun := ExtractionManager.door_gun(i)
				if gun != null:
					line += "\nDoor gun DISABLED" if gun.is_disabled() \
						else "\nDoor gun %d/%d" % [gun.current_hp, gun.stats.max_hp()]
			ExtractionRules.State.COOLDOWN:
				line = "Cooldown %d" % rules.rounds_until_ready(i, turn)
				color = Color(0.7, 0.7, 0.7)
		label.text = title if line.is_empty() else "%s\n%s" % [title, line]
		label.modulate = color


func _on_end_turn() -> void:
	_hide_aimed_shot_menu()
	_hide_grenade_menu()
	var player := _active_player()
	if player:
		player.end_activation()
		_refresh(null)


func _on_settings_pressed() -> void:
	fullscreen_check.button_pressed = GameSettings.fullscreen
	settings_panel.visible = true


func _on_settings_close() -> void:
	settings_panel.visible = false


func _on_fullscreen_toggled(pressed: bool) -> void:
	GameSettings.set_fullscreen(pressed)


## End-of-mission banner per outcome. A placeholder for the debrief screen the
## campaign brings (extraction plan Phase 4), which reads the rest of the result.
const _BANNER_TEXT := {
	MissionResult.Outcome.EXTRACTED: "EXTRACTED",
	MissionResult.Outcome.WIPED: "MISSION FAILED",
	MissionResult.Outcome.ABANDONED: "MISSION ABANDONED",
	MissionResult.Outcome.CLEARED: "MISSION WON",
}


func _on_mission_ended(result: MissionResult) -> void:
	_hide_aimed_shot_menu()
	_hide_grenade_menu()
	banner.text = _BANNER_TEXT[result.outcome]
	# Extraction is the one outcome where the casualties and the objective are
	# news: "you got out" alone hides whether it was a good day.
	if result.outcome == MissionResult.Outcome.EXTRACTED:
		banner.text += "\n%d out, %d lost — objective %s" % [
			result.extracted_units.size(), result.lost_units.size(),
			"complete" if result.objective_complete else "failed"]
	banner.visible = true
	# The roll call (extraction plan 1.5): who made it onto the ship and who was
	# left on the deck. Listed for every outcome that has a squad to list — a
	# wipe's lost list is the whole squad, which is still worth seeing.
	if result.outcome != MissionResult.Outcome.ABANDONED:
		end_details.text = "Extracted: %s\nLeft behind: %s" % [
			_roll_call(result.extracted_units, result), _roll_call(result.lost_units, result)]
		# Extraction plan 3.3: the contract and the haul. Placeholder for Phase 4's
		# debrief, which prices all of this.
		if not result.contract.is_empty():
			end_details.text += "\n%s — %s" % [Contract.from_dict(result.contract).title(),
				"complete" if result.objective_complete else "not complete"]
		var codes := result.loot_codes()
		if not codes.is_empty():
			var names := PackedStringArray()
			var credits := 0
			for code in codes:
				var item := ItemPresets.from_code(code)
				if item:
					names.append(item.display_name)
					credits += item.value
			end_details.text += "\nLoot (%d cr): %s" % [credits, ", ".join(names)]
		# Phase 8: what the competition got away with.
		for line in result.rival_lines():
			end_details.text += "\n" + line
		end_details.visible = true
	_hide_loot_panel()
	radio_banner.visible = false
	$Actions.visible = false
	# Continue takes their spot at the bottom centre.
	_portrait_bar.visible = false
	_target_bar.visible = false
	for key in buttons:
		buttons[key].disabled = true
	_reveal_continue()


## Shows Continue after CONTINUE_DELAY, off a Timer CHILD rather than a
## SceneTreeTimer and not by awaiting inside `_on_mission_ended`: a suspended frame
## there would hold the MissionResult (and through it every unit) alive, and a
## tree timer still pending at a headless `--auto` quit is reported as a leak. The
## child dies with the HUD.
func _reveal_continue() -> void:
	var timer := Timer.new()
	timer.one_shot = true
	timer.wait_time = CONTINUE_DELAY
	timer.timeout.connect(func() -> void:
		_continue_button.visible = true
		timer.queue_free())
	add_child(timer)
	timer.start()


func _build_continue_button() -> void:
	_continue_button = Button.new()
	_continue_button.text = "Continue"
	_continue_button.custom_minimum_size = Vector2(200, 44)
	_continue_button.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_continue_button.offset_left = -100
	_continue_button.offset_right = 100
	_continue_button.offset_top = -120
	_continue_button.offset_bottom = -76
	_continue_button.visible = false
	_continue_button.pressed.connect(func() -> void:
		_continue_button.disabled = true
		continue_pressed.emit())
	add_child(_continue_button)


func _roll_call(units: Array[Unit], result: MissionResult) -> String:
	var names := PackedStringArray()
	for unit in units:
		var tag := ""
		if unit.life_state == Unit.LifeState.DEAD:
			# On the extracted list a corpse is one somebody carried aboard
			# (MissionResult.recovered_corpses) — dead, but brought home.
			tag = " (body recovered)" if result.is_recovered_corpse(unit) else " (dead)"
		elif unit.life_state == Unit.LifeState.DOWNED:
			tag = " (downed)"
		names.append(unit.stats.display_name + tag)
	return ", ".join(names) if not names.is_empty() else "nobody"
