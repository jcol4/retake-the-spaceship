@tool
extends Control
## Drawing and coordinate conversion only; mutations belong to the undo-aware plugin.
signal tile_pressed(cell: Vector2i, event: InputEventMouseButton)
signal tile_released(cell: Vector2i, event: InputEventMouseButton)
signal key_pressed(event: InputEventKey)

var document: Resource
var selected: Array = []
var zoom := 22.0
var pan := Vector2(20, 20)
var heatmap := false
var powered := true
var lanes := false
var sockets := true
var cover := true
var condition := 0
var cursor := Vector2i.ZERO
var focus_cell := Vector2i(-1, -1)
var slot_labels: Dictionary = {}
var dragging := false

func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	clip_contents = true
	custom_minimum_size = Vector2(450, 350)

func tile(position: Vector2) -> Vector2i:
	return Vector2i(((position - pan) / zoom).floor())

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		grab_focus()
		if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] and event.pressed:
			var before: Vector2 = (event.position - pan) / zoom
			zoom = clampf(zoom * (1.15 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.15), 4, 80)
			pan = event.position - before * zoom
		elif event.button_index == MOUSE_BUTTON_MIDDLE: dragging = event.pressed
		elif event.pressed: tile_pressed.emit(tile(event.position), event)
		else: tile_released.emit(tile(event.position), event)
		accept_event()
	elif event is InputEventMouseMotion:
		cursor = tile(event.position)
		if dragging: pan += event.relative
	elif event is InputEventKey and event.pressed:
		key_pressed.emit(event)
		accept_event()
	queue_redraw()

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("171d27"))
	if document == null: return
	var bounds := Rect2i(Vector2i.ZERO, document.size)
	for y in document.size.y:
		for x in document.size.x:
			var at := Vector2i(x, y)
			var index: int = y * document.size.x + x
			var terrain: int = document.terrain[index] if index < document.terrain.size() else 0
			var color: Color = [Color("11151d"), Color("4b5664"), Color("8792a0"), Color.MAGENTA, Color("bd9861"), Color("64525b")][clampi(terrain, 0, 5)]
			if heatmap and document is ParcelData:
				color = color.lerp(Color(1, 0.75, 0.05), DeckValidator.light_level(document.lights, at, powered, condition) / 100.0 * 0.8)
			if lanes and terrain == MapData.Terrain.FLOOR: color = color.lerp(Color(0.1, 0.9, 0.5), 0.2)
			draw_rect(Rect2(pan + Vector2(at) * zoom, Vector2.ONE * (zoom - 1)), color)
	if document is PlotData:
		for slot in document.slots:
			var rect := Rect2(pan + Vector2(slot.rect.position) * zoom, Vector2(slot.rect.size) * zoom)
			var label: String = slot_labels.get(document.slots.find(slot), "Zone %d" % slot.zone)
			var color := Color("e69a55") if label.begins_with("ERROR") else Color("63d1ba")
			draw_rect(rect, Color(color, 0.2), true)
			draw_rect(rect, color, false, 2)
			_text(rect.position + Vector2(3, 15), label, color)
			if sockets: _sockets(slot.sockets, slot.rect.size, slot.rect.position)
	elif sockets: _sockets(document.sockets_ok, document.size, Vector2i.ZERO)
	for piece: DeckPiece in document.pieces:
		var catalog := ModuleCatalog.shared().piece(String(piece.piece_id))
		var rect := PlotAssembler.piece_rect(piece, catalog)
		var screen := Rect2(pan + Vector2(rect.position) * zoom, Vector2(rect.size) * zoom)
		draw_rect(screen.grow(-2), Color("447eb0"), true)
		draw_rect(screen.grow(-2), Color.YELLOW if piece in selected else Color("9ac5ef"), false, 2)
		var center := screen.get_center()
		var direction := Vector2(0, 0.38 * zoom).rotated(piece.rot * PI / 2)
		draw_line(center, center + direction, Color.WHITE, 2)
		if piece.wall_side >= 0:
			var step := MapData.SIDE_STEP[piece.wall_side]
			draw_circle(pan + (Vector2(piece.cell) + Vector2(0.5, 0.5) + Vector2(step.x, step.z) * 0.45) * zoom, 3, Color.CYAN)
	for light: DeckLight in document.lights:
		var at := pan + (Vector2(light.cell) + Vector2(0.5, 0.5)) * zoom
		draw_circle(at, 4, Color.YELLOW)
		if light in selected: draw_arc(at, float(light.overrides.get("light_range", 6.0)) * zoom, 0, TAU, 48, Color(1, 1, 0, 0.35))
	for marker: DeckMarker in document.markers:
		_text(pan + (Vector2(marker.cell) + Vector2(0.2, 0.8)) * zoom, ["E", "P", "N", "L", "S", "PAD"][clampi(marker.kind, 0, 5)], Color.YELLOW if marker in selected else Color("f7a3c4"))
	if cover:
		for edge: Vector3i in document.cover_edges:
			var cell := Vector2(edge.x, edge.y)
			var a := cell
			var b := cell
			match edge.z:
				0: a += Vector2(1, 0); b += Vector2.ONE
				1: a += Vector2(0, 1); b += Vector2.ONE
				2: b += Vector2(0, 1)
				3: b += Vector2(1, 0)
			draw_line(pan + a * zoom, pan + b * zoom, Color.ORANGE if document.cover_edges[edge] == 2 else Color.LIME_GREEN, 3)
	if bounds.has_point(cursor): draw_rect(Rect2(pan + Vector2(cursor) * zoom, Vector2.ONE * zoom), Color.WHITE, false)
	if bounds.has_point(focus_cell): draw_rect(Rect2(pan + Vector2(focus_cell) * zoom, Vector2.ONE * zoom), Color.RED, false, 3)

func _sockets(values: Array[Vector3i], dimensions: Vector2i, origin: Vector2i) -> void:
	for socket in values:
		for index in range(socket.y, socket.y + socket.z):
			var at := ParcelTransform.edge_cell(socket.x, index, dimensions) + origin
			draw_rect(Rect2(pan + Vector2(at) * zoom, Vector2.ONE * zoom).grow(-3), Color.CYAN, false, 2)

func _text(at: Vector2, value: String, color: Color) -> void:
	draw_string(ThemeDB.fallback_font, at, value, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, color)
