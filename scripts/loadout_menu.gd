class_name LoadoutMenu
extends CanvasLayer
## Pre-mission loadout screen: lets the player assign one of the five weapons
## (design doc `weapons/`) to each squad member before the mission starts.
## Built entirely in code — no separate .tscn — since it's a one-off overlay
## shown once per mission start, not a reusable HUD element.

signal deployed

var _units: Array[PlayerUnit] = []
var _pickers: Array[OptionButton] = []


func setup(units: Array[PlayerUnit]) -> void:
	_units = units
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var panel := PanelContainer.new()
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "Choose Loadout"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	vbox.add_child(title)

	for unit in _units:
		vbox.add_child(_build_unit_row(unit))

	var deploy := Button.new()
	deploy.text = "Deploy"
	deploy.pressed.connect(_on_deploy)
	vbox.add_child(deploy)


func _build_unit_row(unit: PlayerUnit) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)

	var name_label := Label.new()
	name_label.text = "%s (%s)" % [unit.stats.display_name, UnitStats.UnitClass.keys()[unit.stats.unit_class]]
	name_label.custom_minimum_size = Vector2(160, 0)
	row.add_child(name_label)

	var picker := OptionButton.new()
	var default_id := WeaponPresets.default_for_class(unit.stats.unit_class)
	var selected_index := 0
	for id in WeaponPresets.all_ids():
		var d: Dictionary = WeaponPresets.DATA[id]
		picker.add_item("%s  (Acc %d / Dmg %d / Mag %d)" % [d["display_name"], d["base_accuracy"], d["damage"], d["mag_size"]])
		picker.set_item_metadata(picker.item_count - 1, id)
		if id == default_id:
			selected_index = picker.item_count - 1
	picker.select(selected_index)
	row.add_child(picker)
	_pickers.append(picker)

	return row


func _on_deploy() -> void:
	for i in _units.size():
		var unit := _units[i]
		var id: int = _pickers[i].get_selected_metadata()
		unit.stats.weapon = WeaponPresets.make(id)
		unit.ammo = unit.stats.mag_size  # refill to the newly-chosen weapon's magazine
	deployed.emit()
	queue_free()
