@tool
extends EditorPlugin
## Main-screen authoring UI. Every document edit is an undo action, including strokes.

const Canvas = preload("res://addons/deck_editor/deck_canvas.gd")
const ChanceInspector = preload("res://addons/deck_editor/chance_inspector.gd")
var screen: VBoxContainer
var canvas: Control
var document: Resource
var inspector: EditorInspectorPlugin
var path_dialog: EditorFileDialog
var new_dialog: ConfirmationDialog
var warnings: ItemList
var palette: ItemList
var socket_filter: OptionButton
var tool_picker: OptionButton
var terrain_picker: OptionButton
var zone_picker: OptionButton
var type_picker: OptionButton
var subtype_picker: OptionButton
var condition_picker: OptionButton
var seed_spin: SpinBox
var status: Label
var preview: TextureRect
var group_edit: LineEdit
var name_edit: LineEdit
var width_spin: SpinBox
var depth_spin: SpinBox
var mode_picker: OptionButton
var deck_picker: OptionButton
var hint_label: Label
var selected: Array = []
var palette_ids: Array[String] = []
var issues: Array = []
var current_piece := ""
var rotation := 0
var drag_start := Vector2i(-1, -1)
var opening := true
var preview_pid := -1
var preview_path := ""
var preview_timer: Timer
var thumb_viewport: SubViewport
var thumb_root: Node3D
var thumb_camera: Camera3D
var _thumb_busy := false
var _thumb_queue: Array[String] = []

func _enter_tree() -> void:
	inspector = ChanceInspector.new()
	add_inspector_plugin(inspector)
	_build_ui()
	EditorInterface.get_editor_main_screen().add_child(screen)
	screen.hide()
	set_process(true)

func _exit_tree() -> void:
	if preview_pid > 0 and OS.is_process_running(preview_pid): OS.kill(preview_pid)
	remove_inspector_plugin(inspector)
	if is_instance_valid(screen): screen.free()
	if is_instance_valid(path_dialog): path_dialog.free()
	if is_instance_valid(new_dialog): new_dialog.free()

func _has_main_screen() -> bool: return true
func _get_plugin_name() -> String: return "Deck Editor"
func _get_plugin_icon() -> Texture2D: return EditorInterface.get_base_control().get_theme_icon("GridContainer", "EditorIcons")
func _make_visible(value: bool) -> void:
	if screen: screen.visible = value
func _handles(object: Object) -> bool: return object is ParcelData or object is PlotData
func _edit(object: Object) -> void:
	if _handles(object): _set_document(object)

func _button(parent: Node, title: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = title
	button.pressed.connect(action)
	parent.add_child(button)
	return button

func _option(parent: Node, values: Array) -> OptionButton:
	var option := OptionButton.new()
	for value in values: option.add_item(str(value))
	parent.add_child(option)
	return option

func _build_ui() -> void:
	screen = VBoxContainer.new()
	screen.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	screen.size_flags_vertical = Control.SIZE_EXPAND_FILL
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bar := HBoxContainer.new()
	screen.add_child(bar)
	_button(bar, "New…", func() -> void: new_dialog.popup_centered(Vector2i(420, 350)))
	_button(bar, "Open…", _open)
	_button(bar, "Save", _save)
	_button(bar, "Save as…", _save_as)
	_button(bar, "Inspect document", func() -> void:
		if document: EditorInterface.inspect_object(document))
	tool_picker = _option(bar, ["Select [S]", "Terrain [T]", "Piece [P]", "Light [L]", "Marker [M]", "Cover [C]", "Socket [D]", "Corridor [K]", "Slot [Q]"])
	tool_picker.item_selected.connect(_tool_changed)
	terrain_picker = _option(bar, ["Floor", "Wall", "Door", "Hull / void"])
	subtype_picker = _option(bar, ["0", "1", "2", "3", "4", "5"])
	subtype_picker.tooltip_text = "Light: Overhead / Monitor / Flicker / Wall lamp / Alarm (0–4). Marker: Enemy / Patrol / Nest / Loot / Player / Pad (0–5). Corridor: Corridor / Spine (0–1)."
	_button(bar, "Rotate [R]", func() -> void: rotation = (rotation + 1) % 4; _status())
	var tools := HBoxContainer.new()
	screen.add_child(tools)
	zone_picker = _option(tools, ["Habitation", "Medical", "Engineering", "Command", "Cargo", "Utility", "None", "Hangar"])
	type_picker = _option(tools, ["Any room type"])
	zone_picker.item_selected.connect(func(_i: int) -> void: _types())
	group_edit = LineEdit.new()
	group_edit.placeholder_text = "Pick-one group"
	tools.add_child(group_edit)
	_button(tools, "Set group on selection", _group)
	_button(tools, "Duplicate", _duplicate)
	_button(tools, "Delete", _delete)
	for spec in [["Light heatmap", "heatmap"], ["Powered", "powered"], ["Walk lanes", "lanes"], ["Cover", "cover"], ["Sockets", "sockets"]]:
		var check := CheckBox.new()
		check.text = spec[0]
		check.button_pressed = canvas != null and canvas.get(spec[1])
		if spec[1] in ["powered", "cover", "sockets"]: check.button_pressed = true
		check.toggled.connect(func(value: bool) -> void: canvas.set(spec[1], value); canvas.queue_redraw())
		tools.add_child(check)
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	screen.add_child(split)
	canvas = Canvas.new()
	canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(canvas)
	canvas.tile_pressed.connect(_press)
	canvas.tile_released.connect(_release)
	canvas.key_pressed.connect(_key)
	var right := VBoxContainer.new()
	right.custom_minimum_size.x = 390
	split.add_child(right)
	var controls := HBoxContainer.new()
	right.add_child(controls)
	_button(controls, "Preview", _preview)
	seed_spin = SpinBox.new()
	seed_spin.max_value = 2147483647
	seed_spin.value = 1
	controls.add_child(seed_spin)
	_button(controls, "Reroll optionals", func() -> void: seed_spin.value += 1; _preview())
	condition_picker = _option(right, ["Intact", "Ransacked", "Barricaded", "Overrun", "Seeded mix"])
	condition_picker.item_selected.connect(func(i: int) -> void: canvas.condition = mini(i, 3); canvas.queue_redraw())
	preview = TextureRect.new()
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.custom_minimum_size = Vector2(380, 250)
	preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(preview)
	warnings = ItemList.new()
	warnings.custom_minimum_size.y = 180
	warnings.item_selected.connect(func(i: int) -> void:
		canvas.focus_cell = issues[i].cell
		canvas.pan = Vector2(40, 40) - Vector2(issues[i].cell) * canvas.zoom
		canvas.queue_redraw())
	right.add_child(warnings)
	var bottom := HBoxContainer.new()
	screen.add_child(bottom)
	socket_filter = _option(bottom, ["All sockets"])
	var sockets := {}
	for p: Dictionary in ModuleCatalog.shared().all_pieces(): sockets[p.socket] = true
	var names := sockets.keys()
	names.sort()
	for name in names: socket_filter.add_item(name)
	socket_filter.item_selected.connect(func(_i: int) -> void: _palette())
	status = Label.new()
	bottom.add_child(status)
	palette = ItemList.new()
	palette.custom_minimum_size.y = 130
	palette.max_columns = 0
	palette.fixed_column_width = 175
	palette.fixed_icon_size = Vector2i(64, 64)
	palette.icon_mode = ItemList.ICON_MODE_TOP
	palette.item_selected.connect(func(i: int) -> void:
		current_piece = palette_ids[i]
		if not _thumb_queue.has(current_piece): _thumb_queue.append(current_piece)
		_status())
	screen.add_child(palette)
	path_dialog = EditorFileDialog.new()
	path_dialog.add_filter("*.tres", "Deck resource")
	path_dialog.file_selected.connect(_path_chosen)
	EditorInterface.get_base_control().add_child(path_dialog)
	_new_dialog()
	_types()
	_palette()
	preview_timer = Timer.new()
	preview_timer.wait_time = 0.3
	preview_timer.timeout.connect(_poll_preview)
	screen.add_child(preview_timer)
	_thumbnail_viewport()
	_tool_changed(0)

func _tool_changed(index: int) -> void:
	subtype_picker.clear()
	var labels: Array = ["—"]
	if index == 3: labels = ["Overhead", "Monitor", "Flicker", "Wall lamp", "Alarm"]
	elif index == 4: labels = ["Enemy", "Patrol", "Nest spot", "Loot", "Player", "Pad"]
	elif index == 7: labels = ["Corridor", "Spine"]
	for label in labels: subtype_picker.add_item(label)

func _new_dialog() -> void:
	new_dialog = ConfirmationDialog.new()
	new_dialog.title = "New deck resource"
	EditorInterface.get_base_control().add_child(new_dialog)
	var box := VBoxContainer.new()
	new_dialog.add_child(box)
	mode_picker = _option(box, ["Parcel", "Plot"])
	name_edit = LineEdit.new()
	name_edit.placeholder_text = "Display name"
	box.add_child(name_edit)
	deck_picker = _option(box, ["Small — 72 × 48", "Medium — 84 × 56", "Large — 96 × 64"])
	width_spin = SpinBox.new()
	depth_spin = SpinBox.new()
	for spin in [width_spin, depth_spin]:
		spin.min_value = 1
		spin.max_value = 512
		box.add_child(spin)
	width_spin.value = 8
	depth_spin.value = 10
	hint_label = Label.new()
	hint_label.text = "Parcel uses the zone/type selected above.\nWidth and depth are unrestricted; suggested sizes appear below."
	box.add_child(hint_label)
	new_dialog.confirmed.connect(_new_resource)

func _types() -> void:
	type_picker.clear()
	type_picker.add_item("Any room type")
	var types := RoomTypes.types_in(zone_picker.selected)
	for type: StringName in types:
		type_picker.add_item(String(type))
		type_picker.set_item_metadata(type_picker.item_count - 1, type)
	if hint_label:
		hint_label.text = "Suggested room sizes are hints; dimensions are unrestricted."
	if not type_picker.item_selected.is_connected(_type_hint): type_picker.item_selected.connect(_type_hint)

func _type_hint(_i: int) -> void:
	if hint_label and type_picker.selected > 0:
		var info := RoomTypes.info(type_picker.get_item_metadata(type_picker.selected))
		hint_label.text = "Suggested short / long: %s / %s (not enforced)" % [info.get("short", "—"), info.get("long", "—")]

func _new_resource() -> void:
	var resource: Resource
	if mode_picker.selected == 0:
		var parcel := ParcelData.new()
		parcel.zone = zone_picker.selected
		parcel.room_type = RoomTypes.HANGAR if parcel.zone == ParcelData.ZONE_HANGAR else (type_picker.get_item_metadata(type_picker.selected) if type_picker.selected > 0 else &"generic")
		parcel.size = Vector2i(int(width_spin.value), int(depth_spin.value))
		resource = parcel
	else:
		var plot := PlotData.new()
		plot.deck_size = deck_picker.selected
		plot.size = [Vector2i(72, 48), Vector2i(84, 56), Vector2i(96, 64)][plot.deck_size]
		resource = plot
	resource.display_name = name_edit.text
	resource.terrain.resize(resource.size.x * resource.size.y)
	resource.terrain.fill(MapData.Terrain.FLOOR if resource is ParcelData else MapData.Terrain.WALL)
	_set_document(resource)
	_save_as()

func _set_document(resource: Resource) -> void:
	document = resource
	canvas.document = resource
	selected.clear()
	canvas.selected = selected
	canvas.pan = Vector2(20, 20)
	canvas.zoom = minf(40, minf((maxf(450, canvas.size.x) - 40) / maxf(1, document.size.x), (maxf(350, canvas.size.y) - 40) / maxf(1, document.size.y)))
	if not resource.changed.is_connected(_refresh): resource.changed.connect(_refresh)
	_refresh()

func _open() -> void:
	opening = true
	path_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	path_dialog.current_dir = "res://maps"
	path_dialog.popup_centered_ratio(0.6)

func _save_as() -> void:
	if document == null: return
	opening = false
	path_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	path_dialog.current_dir = "res://maps/plots" if document is PlotData else "res://maps/parcels"
	path_dialog.current_file = "new_plot.tres" if document is PlotData else "new_parcel.tres"
	path_dialog.popup_centered_ratio(0.6)

func _path_chosen(path: String) -> void:
	if opening:
		var resource := load(path)
		if resource is ParcelData or resource is PlotData: _set_document(resource)
		else: status.text = "Choose a ParcelData or PlotData resource"
	else:
		document.take_over_path(path)
		_save()

func _save() -> void:
	if document == null: return
	if document.resource_path == "":
		_save_as()
		return
	# Validation is advisory by design, even for hard errors.
	var result := ResourceSaver.save(document, document.resource_path)
	status.text = "Saved " + document.resource_path if result == OK else "Save failed: %s" % error_string(result)
	EditorInterface.get_resource_filesystem().scan()
	_refresh()
	_preview()

func _refresh() -> void:
	if document == null: return
	canvas.queue_redraw()
	warnings.clear()
	issues = DeckValidator.parcel(document, PlotAssembler.resources("res://maps/plots")) if document is ParcelData else DeckValidator.plot(document, PlotAssembler.resources("res://maps/parcels"))
	for issue: Dictionary in issues: warnings.add_item(("ERROR: " if issue.hard else "Note: ") + issue.message)
	_status()

func _status() -> void:
	status.text = "%s | %s | facing %d | %d selected" % [document.display_name if document else "Open or create a plot/parcel", current_piece, rotation, selected.size()]

func _edit_properties(label: String, changes: Array) -> void:
	if document == null or changes.is_empty(): return
	var undo := get_undo_redo()
	undo.create_action(label, UndoRedo.MERGE_DISABLE, document)
	for change: Array in changes:
		undo.add_do_property(change[0], change[1], change[2])
		undo.add_undo_property(change[0], change[1], change[0].get(change[1]))
	undo.add_do_method(self, "_refresh")
	undo.add_undo_method(self, "_refresh")
	undo.commit_action()

func _array_add(property: String, entry: Resource) -> void:
	var values: Array = document.get(property).duplicate()
	values.append(entry)
	_edit_properties("Add " + property, [[document, property, values]])
	_select([entry])

func _select(entries: Array) -> void:
	selected = entries
	canvas.selected = entries
	if entries.size() == 1: EditorInterface.inspect_object(entries[0])
	for entry: Resource in entries:
		if not entry.changed.is_connected(_refresh): entry.changed.connect(_refresh)
	canvas.queue_redraw()
	_status()

func _entries() -> Array:
	var values: Array = []
	if document:
		values.append_array(document.pieces)
		values.append_array(document.lights)
		values.append_array(document.markers)
		if document is PlotData: values.append_array(document.slots)
	return values

func _nearest_side(cell: Vector2i) -> int:
	# Cursor's fractional tile position chooses an edge; prefer an actual wall.
	var local: Vector2 = (canvas.get_local_mouse_position() - canvas.pan) / canvas.zoom - Vector2(cell)
	var distances := [1.0 - local.x, 1.0 - local.y, local.x, local.y]
	var best := 0
	for i in 4:
		if distances[i] < distances[best]: best = i
	return best

func _wall(cell: Vector2i) -> int:
	var options: Array[int] = []
	for side in 4:
		var step := MapData.SIDE_STEP[side]
		var at := cell + Vector2i(step.x, step.z)
		if not Rect2i(Vector2i.ZERO, document.size).has_point(at) or document.terrain[at.y * document.size.x + at.x] == MapData.Terrain.WALL: options.append(side)
	var preferred := _nearest_side(cell)
	return preferred if preferred in options else (options[0] if not options.is_empty() else preferred)

func _press(cell: Vector2i, event: InputEventMouseButton) -> void:
	if document == null or not Rect2i(Vector2i.ZERO, document.size).has_point(cell): return
	if event.button_index == MOUSE_BUTTON_RIGHT:
		_select(_entries().filter(func(e: Resource) -> bool: return (e.rect.has_point(cell) if e is PlotSlot else e.cell == cell)))
		return
	if event.button_index != MOUSE_BUTTON_LEFT: return
	drag_start = cell
	match tool_picker.selected:
		0:
			var found := _entries().filter(func(e: Resource) -> bool:
				if e is PlotSlot: return e.rect.has_point(cell)
				if e is DeckPiece: return PlotAssembler.piece_rect(e, ModuleCatalog.shared().piece(String(e.piece_id))).has_point(cell)
				return e.cell == cell)
			if not found.is_empty(): _select(selected + [found[-1]] if event.shift_pressed and found[-1] not in selected else [found[-1]])
			elif not event.shift_pressed: _select([])
		2: _place_piece(cell, event.alt_pressed)
		3:
			var light := DeckLight.new()
			light.cell = cell
			light.preset = mini(subtype_picker.selected, 4)
			if light.preset in [3, 4]: light.wall_side = _wall(cell)
			_array_add("lights", light)
		4:
			if subtype_picker.selected == 5 and (not document is ParcelData or document.zone != ParcelData.ZONE_HANGAR):
				status.text = "PAD markers belong in hangar parcels"
				return
			var marker := DeckMarker.new()
			marker.cell = cell
			marker.kind = subtype_picker.selected
			marker.ramp_side = rotation
			_array_add("markers", marker)
		5:
			var values: Dictionary = document.cover_edges.duplicate()
			var key := Vector3i(cell.x, cell.y, _nearest_side(cell))
			values[key] = (values.get(key, 0) + 1) % 3
			if values[key] == 0: values.erase(key)
			_edit_properties("Cycle cover edge", [[document, "cover_edges", values]])
		6: _socket(cell)

func _release(cell: Vector2i, event: InputEventMouseButton) -> void:
	if document == null or event.button_index != MOUSE_BUTTON_LEFT or drag_start.x < 0: return
	cell = cell.clamp(Vector2i.ZERO, document.size - Vector2i.ONE)
	var rect := Rect2i(drag_start.min(cell), drag_start.max(cell) - drag_start.min(cell) + Vector2i.ONE)
	match tool_picker.selected:
		0:
			if selected.is_empty() and cell != drag_start:
				_select(_entries().filter(func(e: Resource) -> bool: return rect.intersects(e.rect) if e is PlotSlot else rect.has_point(e.cell)))
			elif cell != drag_start:
				_move(cell - drag_start)
		1:
			var terrain: PackedByteArray = document.terrain.duplicate()
			for y in range(rect.position.y, rect.end.y):
				for x in range(rect.position.x, rect.end.x): terrain[y * document.size.x + x] = [MapData.Terrain.FLOOR, MapData.Terrain.WALL, MapData.Terrain.DOOR, MapData.Terrain.VOID][terrain_picker.selected]
			_edit_properties("Paint terrain", [[document, "terrain", terrain]])
		7:
			if document is PlotData:
				var corridors: Array[Rect2i] = document.corridor_rects.duplicate()
				var types: Array[StringName] = document.corridor_types.duplicate()
				while types.size() < corridors.size(): types.append(RoomTypes.CORRIDOR)
				corridors.append(rect)
				types.append(RoomTypes.SPINE if subtype_picker.selected == 1 else RoomTypes.CORRIDOR)
				var terrain: PackedByteArray = document.terrain.duplicate()
				for y in range(rect.position.y, rect.end.y):
					for x in range(rect.position.x, rect.end.x): terrain[y * document.size.x + x] = MapData.Terrain.FLOOR
				_edit_properties("Add corridor", [[document, "corridor_rects", corridors], [document, "corridor_types", types], [document, "terrain", terrain]])
		8:
			if document is PlotData:
				var slot := PlotSlot.new()
				slot.rect = rect
				slot.zone = zone_picker.selected
				if type_picker.selected > 0: slot.required_type = type_picker.get_item_metadata(type_picker.selected)
				_array_add("slots", slot)
	drag_start = Vector2i(-1, -1)

func _place_piece(cell: Vector2i, free: bool) -> void:
	if current_piece == "": return
	var catalog := ModuleCatalog.shared().piece(current_piece)
	var piece := DeckPiece.new()
	piece.piece_id = StringName(current_piece)
	piece.cell = cell
	piece.rot = rotation
	if catalog.mount == "wall": piece.wall_side = _wall(cell)
	elif free and not catalog.gameplay:
		var local: Vector2 = (canvas.get_local_mouse_position() - canvas.pan) / canvas.zoom - Vector2(cell) - Vector2(0.5, 0.5)
		piece.offset = Vector3(local.x * 1.5, 0, local.y * 1.5)
		for i in document.pieces.size():
			var base: DeckPiece = document.pieces[i]
			if PlotAssembler.piece_rect(base, ModuleCatalog.shared().piece(String(base.piece_id))).has_point(cell): piece.stack_on = i
	_array_add("pieces", piece)

func _socket(cell: Vector2i) -> void:
	var owner: Resource = document
	var size: Vector2i = document.size
	var local := cell
	var property := "sockets_ok"
	if document is PlotData:
		owner = null
		for slot in document.slots:
			if slot.rect.has_point(cell):
				owner = slot
				size = slot.rect.size
				local = cell - slot.rect.position
				break
		if owner == null: return
		property = "sockets"
	var distances := [size.x - 1 - local.x, size.y - 1 - local.y, local.x, local.y]
	var side := distances.find(distances.min())
	var index := local.y if side % 2 == 0 else local.x
	var length := size.y if side % 2 == 0 else size.x
	var socket := Vector3i(side, mini(index, maxi(0, length - 2)), mini(2, length))
	var values: Array[Vector3i] = owner.get(property).duplicate()
	if socket in values: values.erase(socket)
	else: values.append(socket)
	_edit_properties("Toggle door socket", [[owner, property, values]])

func _move(delta: Vector2i) -> void:
	var changes: Array = []
	for entry: Resource in selected:
		if entry is PlotSlot:
			var rect: Rect2i = entry.rect
			rect.position += delta
			changes.append([entry, "rect", rect])
		else: changes.append([entry, "cell", entry.cell + delta])
	_edit_properties("Move selection", changes)

func _group() -> void:
	var changes: Array = []
	for entry: Resource in selected:
		if not entry is PlotSlot: changes.append([entry, "group", StringName(group_edit.text)])
	_edit_properties("Set pick-one group", changes)

func _delete() -> void:
	if document == null: return
	var changes: Array = []
	for property in (["pieces", "lights", "markers", "slots"] if document is PlotData else ["pieces", "lights", "markers"]):
		var values: Array = document.get(property).duplicate()
		for i in range(values.size() - 1, -1, -1):
			if values[i] in selected: values.remove_at(i)
		if property == "pieces":
			for piece: DeckPiece in values:
				if piece.stack_on < 0: continue
				var parent: DeckPiece = document.pieces[piece.stack_on] if piece.stack_on < document.pieces.size() else null
				var new_index := values.find(parent) if parent != null else -1
				changes.append([piece, "stack_on", new_index])
		changes.append([document, property, values])
	_edit_properties("Delete selection", changes)
	_select([])

func _duplicate() -> void:
	if document == null: return
	var changes: Array = []
	var copies: Array = []
	var piece_copies := {}
	for property in (["pieces", "lights", "markers", "slots"] if document is PlotData else ["pieces", "lights", "markers"]):
		var values: Array = document.get(property).duplicate()
		for entry: Resource in selected:
			if property == "pieces" and not entry is DeckPiece: continue
			if property == "lights" and not entry is DeckLight: continue
			if property == "markers" and not entry is DeckMarker: continue
			if property == "slots" and not entry is PlotSlot: continue
			var copy := entry.duplicate(true)
			if copy is PlotSlot: copy.rect.position += Vector2i.ONE
			else: copy.cell += Vector2i.ONE
			values.append(copy)
			copies.append(copy)
			if copy is DeckPiece: piece_copies[entry] = copy
		if property == "pieces":
			for original: DeckPiece in piece_copies:
				if original.stack_on >= 0 and original.stack_on < document.pieces.size():
					var parent: DeckPiece = document.pieces[original.stack_on]
					if piece_copies.has(parent): piece_copies[original].stack_on = values.find(piece_copies[parent])
		changes.append([document, property, values])
	_edit_properties("Duplicate selection", changes)
	_select(copies)

func _key(event: InputEventKey) -> void:
	var shortcuts := {KEY_S: 0, KEY_T: 1, KEY_P: 2, KEY_L: 3, KEY_M: 4, KEY_C: 5, KEY_D: 6, KEY_K: 7, KEY_Q: 8}
	if event.ctrl_pressed:
		if event.keycode == KEY_S: _save()
		elif event.keycode == KEY_D: _duplicate()
		return # Editor handles Ctrl+Z / Ctrl+Shift+Z.
	if shortcuts.has(event.keycode):
		tool_picker.select(shortcuts[event.keycode])
		_tool_changed(shortcuts[event.keycode])
	elif event.keycode == KEY_R:
		rotation = (rotation + 1) % 4
		var changes: Array = []
		for entry: Resource in selected:
			if entry is DeckPiece: changes.append([entry, "rot", (entry.rot + 1) % 4])
		_edit_properties("Rotate selection", changes)
	elif event.keycode in [KEY_DELETE, KEY_BACKSPACE]: _delete()
	elif event.keycode in [KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN]:
		_move({KEY_LEFT: Vector2i.LEFT, KEY_RIGHT: Vector2i.RIGHT, KEY_UP: Vector2i.UP, KEY_DOWN: Vector2i.DOWN}[event.keycode])

func _palette() -> void:
	palette.clear()
	palette_ids.clear()
	var all := ModuleCatalog.shared().all_pieces()
	all.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return (a.socket + a.id) < (b.socket + b.id))
	for p: Dictionary in all:
		if socket_filter.selected > 0 and p.socket != socket_filter.get_item_text(socket_filter.selected): continue
		var index := palette.item_count
		palette.add_item(p.id)
		palette.set_item_tooltip(index, "%s\n%s | %s | footprint %s" % [p.id, p.socket, p.mount, p.get("footprint", [1, 1])])
		palette_ids.append(p.id)
		var path := "res://.godot/deck_editor_thumbs/" + String(p.id).validate_filename() + ".png"
		if FileAccess.file_exists(path): palette.set_item_icon(index, ImageTexture.create_from_image(Image.load_from_file(path)))
		elif not _thumb_queue.has(p.id): _thumb_queue.append(p.id)

func _thumbnail_viewport() -> void:
	thumb_viewport = SubViewport.new()
	thumb_viewport.size = Vector2i(128, 128)
	thumb_viewport.own_world_3d = true
	thumb_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	screen.add_child(thumb_viewport)
	thumb_root = Node3D.new()
	thumb_viewport.add_child(thumb_root)
	thumb_camera = Camera3D.new()
	thumb_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	thumb_camera.position = Vector3(6, 7, 9)
	thumb_viewport.add_child(thumb_camera)
	thumb_camera.rotation = Basis.looking_at(Vector3(0, 0.6, 0) - thumb_camera.position).get_euler()
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -30, 0)
	sun.light_energy = 1.8
	thumb_viewport.add_child(sun)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("202630")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 0.6
	thumb_viewport.add_child(environment)

func _process(_delta: float) -> void:
	if screen == null or not screen.visible or _thumb_busy or _thumb_queue.is_empty(): return
	if EditorInterface.get_resource_filesystem().is_scanning() or DisplayServer.get_name() == "headless": return
	_render_thumb(_thumb_queue.pop_front())

func _render_thumb(id: String) -> void:
	_thumb_busy = true
	for child in thumb_root.get_children(): child.free()
	var piece := ModuleCatalog.shared().piece(id)
	thumb_root.add_child(ModuleCatalog.shared().instance(piece))
	var footprint: Array = piece.get("footprint", [2, 2])
	thumb_camera.size = maxf(4, maxf(footprint[0], footprint[1]) * 2.1)
	thumb_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	if not is_instance_valid(screen): return
	var image := thumb_viewport.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute("res://.godot/deck_editor_thumbs")
	image.save_png("res://.godot/deck_editor_thumbs/" + id.validate_filename() + ".png")
	var index := palette_ids.find(id)
	if index >= 0: palette.set_item_icon(index, ImageTexture.create_from_image(image))
	_thumb_busy = false

func _preview() -> void:
	if document == null: return
	var dir := "res://.godot/deck_editor_preview"
	DirAccess.make_dir_recursive_absolute(dir)
	var resource_path := dir + "/document.tres"
	ResourceSaver.save(document, resource_path)
	var seed_value := int(seed_spin.value)
	var condition := condition_picker.selected if condition_picker.selected < 4 else -1
	canvas.slot_labels.clear()
	if document is PlotData:
		var assembler := PlotAssembler.new()
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_value
		assembler.assemble(document, rng, [], condition)
		for i in document.slots.size():
			var candidates := PlotAssembler.candidates(document.slots[i], PlotAssembler.resources("res://maps/parcels"))
			canvas.slot_labels[i] = "ERROR: no matching parcel" if candidates.is_empty() else (assembler.assignments[i].parcel.display_name if i < assembler.assignments.size() and assembler.assignments[i] != null else "ERROR: constraints")
		for message in assembler.errors: warnings.add_item(message)
	canvas.queue_redraw()
	# Isolate runtime autoloads/physics from the editor: the real MapBuilder renders
	# in a child game process, then we display its captured SubViewport image.
	if preview_pid > 0 and OS.is_process_running(preview_pid): OS.kill(preview_pid)
	preview_path = ProjectSettings.globalize_path(dir + "/preview_%d.png" % Time.get_ticks_msec())
	preview_pid = OS.create_process(OS.get_executable_path(), ["--path", ProjectSettings.globalize_path("res://"), "--script", "res://tools/preview_parcel.gd", "--log-file", ProjectSettings.globalize_path(dir + "/preview.log"), "--", "--resource=" + resource_path, "--out=" + preview_path, "--preview-seed=%d" % seed_value, "--condition=%d" % condition], false)
	status.text = "Rendering runtime preview…"
	preview_timer.start()

func _poll_preview() -> void:
	if FileAccess.file_exists(preview_path):
		preview.texture = ImageTexture.create_from_image(Image.load_from_file(preview_path))
		preview_timer.stop()
		_status()
	elif preview_pid <= 0 or not OS.is_process_running(preview_pid):
		preview_timer.stop()
		status.text = "Preview failed; see .godot/deck_editor_preview/preview.log"
