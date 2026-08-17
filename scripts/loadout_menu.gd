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
	# Co-op: each peer only picks loadouts for the mercs it owns — a squadmate's
	# weapon choice isn't this client's call. Solo play owns everything (see
	# Unit.is_owned_by_local_player), so the filter is a no-op there.
	_units = units.filter(func(u: PlayerUnit) -> bool: return u.is_owned_by_local_player())
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
		var total: int = d["mag_size"] + d["starting_reserve"]
		picker.add_item("%s  (Acc %d / Dmg %d / Mag %d / %d total)" % [d["display_name"], d["base_accuracy"], d["damage"], d["mag_size"], total])
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
		# The unit node this client sees is its OWN local instance (every peer
		# spawns the squad independently — see main.gd), but combat is resolved
		# against the HOST's instance. A client editing its local copy alone
		# would never reach the sim, so the pick is sent to the host and
		# applied there; the local copy is cosmetic until the host's echo of
		# unit state (once that exists) catches it up.
		if not multiplayer.has_multiplayer_peer() or multiplayer.is_server():
			_apply_loadout(unit, id)
		else:
			_rpc_request_loadout.rpc_id(1, unit.get_path(), id)
	deployed.emit()
	queue_free()


func _apply_loadout(unit: PlayerUnit, weapon_id: int) -> void:
	unit.stats.weapon = WeaponPresets.make(weapon_id)
	unit.ammo = unit.stats.mag_size  # refill to the newly-chosen weapon's magazine
	unit.reserve = unit.stats.weapon.starting_reserve


@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_loadout(unit_path: NodePath, weapon_id: int) -> void:
	if not multiplayer.is_server():
		return
	var unit := get_tree().root.get_node_or_null(unit_path) as PlayerUnit
	if unit == null:
		return
	var sender := multiplayer.get_remote_sender_id()
	if unit.owner_peer_id != 0 and sender != unit.owner_peer_id:
		push_warning("LoadoutMenu: rejected loadout pick from peer %d for %s (owned by %d)" % [
			sender, unit.stats.display_name, unit.owner_peer_id])
		return
	_apply_loadout(unit, weapon_id)
