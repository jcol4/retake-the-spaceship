@tool
extends EditorInspectorPlugin

class ChanceEditor extends EditorProperty:
	var sliders: Array[HSlider] = []
	var updating := false
	func _init() -> void:
		var box := VBoxContainer.new()
		add_child(box)
		set_bottom_editor(box)
		for label in ["Intact", "Ransacked", "Barricaded", "Overrun"]:
			var row := HBoxContainer.new()
			var title := Label.new()
			title.text = label
			title.custom_minimum_size.x = 100
			row.add_child(title)
			var slider := HSlider.new()
			slider.min_value = 0
			slider.max_value = 1
			slider.step = 0.01
			slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			slider.value_changed.connect(_changed)
			row.add_child(slider)
			var spin := SpinBox.new()
			spin.min_value = 0
			spin.max_value = 1
			spin.step = 0.01
			spin.share(slider)
			row.add_child(spin)
			box.add_child(row)
			sliders.append(slider)

	func _update_property() -> void:
		updating = true
		var value: PackedFloat32Array = get_edited_object().get(get_edited_property())
		for i in 4: sliders[i].value = value[i] if i < value.size() else 1
		updating = false

	func _changed(_value: float) -> void:
		if updating: return
		var value := PackedFloat32Array()
		for slider in sliders: value.append(slider.value)
		emit_changed(get_edited_property(), value)

func _can_handle(object: Object) -> bool:
	return object is DeckPiece or object is DeckLight or object is DeckMarker

func _parse_property(_object: Object, _type: Variant.Type, name: String, _hint_type: PropertyHint, _hint_string: String, _usage_flags: int, _wide: bool) -> bool:
	if name != "chance": return false
	add_property_editor(name, ChanceEditor.new())
	return true
