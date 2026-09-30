class_name LoadoutMenu
extends CanvasLayer
## Pre-mission loadout screen: lets the player assign one of the five weapons
## (design doc `weapons/`) and its attachments (`weapons/attachments.md`) to
## each squad member before the mission starts. Attachments come from
## `inventory`: each copy owned fits on one soldier at a time, so a copy already
## fitted to one squad member shows disabled on everyone else's picker. Ammo
## comes from `unlocked_ammo`, and an unlocked type can go in any number of guns.
## Built entirely in code — no separate .tscn — since it's a one-off overlay
## shown once per mission start, not a reusable HUD element.

signal deployed

var _units: Array[PlayerUnit] = []
var _pickers: Array[OptionButton] = []
# Per unit, one OptionButton per AttachmentData.Slot, in slot order.
var _slot_pickers: Array = []
var _ammo_pickers: Array[OptionButton] = []
var _stat_labels: Array[Label] = []

## AttachmentPresets id -> copies owned. Set before `setup`; left empty, it
## falls back to one of everything until progression hands out unlocks.
var inventory: Dictionary = {}
## AmmoPresets ids unlocked. Standard is offered regardless. Left empty, it
## falls back to every type.
var unlocked_ammo: Array = []


func setup(units: Array[PlayerUnit]) -> void:
	# Co-op: each peer only picks loadouts for the mercs it owns — a squadmate's
	# weapon choice isn't this client's call. Solo play owns everything (see
	# Unit.is_owned_by_local_player), so the filter is a no-op there.
	_units = units.filter(func(u: PlayerUnit) -> bool: return u.is_owned_by_local_player())
	if inventory.is_empty():
		inventory = AttachmentPresets.placeholder_inventory()
	if unlocked_ammo.is_empty():
		unlocked_ammo = AmmoPresets.placeholder_unlocks()
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
	var block := VBoxContainer.new()
	block.add_theme_constant_override("separation", 4)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	block.add_child(row)

	var name_label := Label.new()
	name_label.text = "%s (%s)" % [unit.stats.display_name, UnitStats.UnitClass.keys()[unit.stats.unit_class]]
	name_label.custom_minimum_size = Vector2(160, 0)
	row.add_child(name_label)

	var picker := OptionButton.new()
	var default_id := WeaponPresets.default_for_class(unit.stats.unit_class)
	var selected_index := 0
	for id in WeaponPresets.all_ids():
		var d: Dictionary = WeaponPresets.DATA[id]
		var total: int = d["mag_size"] + d["starting_reserve"]
		picker.add_item("%s  (Acc %d / Dmg %d / Mag %d / %d total)" % [d["display_name"], d["base_accuracy"], d["damage"], d["mag_size"], total])
		picker.set_item_metadata(picker.item_count - 1, id)
		if id == default_id:
			selected_index = picker.item_count - 1
	picker.select(selected_index)
	row.add_child(picker)
	_pickers.append(picker)

	var index := _pickers.size() - 1
	var slot_row := HBoxContainer.new()
	slot_row.add_theme_constant_override("separation", 8)
	block.add_child(slot_row)
	var slot_pickers: Array[OptionButton] = []
	for slot in AttachmentData.Slot.values():
		var slot_picker := OptionButton.new()
		slot_picker.item_selected.connect(func(_i: int) -> void: _on_attachment_selected(index))
		slot_row.add_child(slot_picker)
		slot_pickers.append(slot_picker)
	_slot_pickers.append(slot_pickers)
	var ammo_picker := OptionButton.new()
	ammo_picker.item_selected.connect(func(_i: int) -> void: _on_attachment_selected(index))
	slot_row.add_child(ammo_picker)
	_ammo_pickers.append(ammo_picker)

	var stats := Label.new()
	block.add_child(stats)
	_stat_labels.append(stats)

	picker.item_selected.connect(func(_i: int) -> void: _refresh_slots(index))
	_refresh_slots(index)
	return block


## Refills unit `index`'s slot pickers with the owned attachments that fit its
## current weapon, keeping each slot's pick where it still fits.
func _refresh_slots(index: int) -> void:
	var weapon_id: int = _pickers[index].get_selected_metadata()
	for slot in AttachmentData.Slot.values():
		var slot_picker: OptionButton = _slot_pickers[index][slot]
		var previous: int = slot_picker.get_selected_metadata() if slot_picker.item_count > 0 else -1
		slot_picker.clear()
		slot_picker.add_item("%s: None" % AttachmentData.Slot.keys()[slot].capitalize())
		slot_picker.set_item_metadata(0, -1)
		slot_picker.select(0)
		for aid in AttachmentPresets.ids_for(slot, weapon_id):
			if inventory.get(aid, 0) <= 0:
				continue
			slot_picker.add_item("%s  (%s)" % [AttachmentPresets.DATA[aid]["display_name"], AttachmentPresets.describe(aid)])
			var i := slot_picker.item_count - 1
			slot_picker.set_item_metadata(i, aid)
			if aid == previous:
				slot_picker.select(i)
	_refresh_ammo(index, weapon_id)
	_on_attachment_selected(index)


## Same as the slots, for ammo: what fits this weapon and is unlocked, keeping
## the pick if it still fits, else back to Standard.
func _refresh_ammo(index: int, weapon_id: int) -> void:
	var ammo_picker := _ammo_pickers[index]
	var previous: int = ammo_picker.get_selected_metadata() if ammo_picker.item_count > 0 else AmmoPresets.AmmoId.STANDARD
	ammo_picker.clear()
	for ammo_id in AmmoPresets.ids_for(weapon_id):
		if ammo_id != AmmoPresets.AmmoId.STANDARD and not (ammo_id in unlocked_ammo):
			continue
		var summary := AmmoPresets.describe(ammo_id)
		ammo_picker.add_item("Ammo: %s%s" % [AmmoPresets.DATA[ammo_id]["display_name"],
			"  (%s)" % summary if summary != "" else ""])
		var i := ammo_picker.item_count - 1
		ammo_picker.set_item_metadata(i, ammo_id)
		if ammo_id == previous:
			ammo_picker.select(i)
	if ammo_picker.selected < 0:
		ammo_picker.select(0)  # Standard, always first


func _selected_attachments(index: int) -> PackedInt32Array:
	var ids := PackedInt32Array()
	for slot_picker: OptionButton in _slot_pickers[index]:
		var aid: int = slot_picker.get_selected_metadata()
		if aid >= 0:
			ids.append(aid)
	return ids


## Readout of the weapon's numbers WITH its attachments — built the same way
## deploy will build it, so what's shown is what's fired.
func _on_attachment_selected(index: int) -> void:
	var w := WeaponPresets.make(_pickers[index].get_selected_metadata(), _selected_attachments(index),
		_ammo_pickers[index].get_selected_metadata())
	var ammo_total := "∞" if w.effective_reserve() < 0 else str(w.effective_mag_size() + w.effective_reserve())
	# Damage at range 99 so a close-range-only percent (Slugs) doesn't show.
	var text := "Acc %d / Dmg %d vs armor, %d vs unarmored / Mag %d / %s total / Noise %d" % [
		w.effective_accuracy(), w.damage_against(true, 99), w.damage_against(false, 99),
		w.effective_mag_size(), ammo_total, w.effective_noise_radius()]
	var ap_parts: PackedStringArray = []
	for action in WeaponData.ApAction.values():
		var mod := w.ap_modifier(action)
		if mod != 0:
			ap_parts.append("%s %+d" % [WeaponData.ApAction.keys()[action].capitalize(), mod])
	if not ap_parts.is_empty():
		text += " / AP: " + ", ".join(ap_parts)
	_stat_labels[index].text = text
	_update_availability()


func _on_deploy() -> void:
	for i in _units.size():
		# Routed through the unit, not an RPC on this menu — see
		# PlayerUnit.choose_loadout for why the menu can't be the address.
		_units[i].choose_loadout(_pickers[i].get_selected_metadata(), _selected_attachments(i),
			_ammo_pickers[i].get_selected_metadata())
	deployed.emit()
	queue_free()


## Greys out, on every picker, any attachment whose copies are all fitted to
## OTHER soldiers. A unit's own current pick is never disabled for it — it is
## holding one of the copies being counted.
func _update_availability() -> void:
	var in_use := {}
	for index in _slot_pickers.size():
		for aid in _selected_attachments(index):
			in_use[aid] = in_use.get(aid, 0) + 1
	for index in _slot_pickers.size():
		for slot_picker: OptionButton in _slot_pickers[index]:
			var mine: int = slot_picker.get_selected_metadata()
			for i in range(1, slot_picker.item_count):
				var aid: int = slot_picker.get_item_metadata(i)
				slot_picker.set_item_disabled(i, aid != mine and in_use.get(aid, 0) >= inventory.get(aid, 0))
