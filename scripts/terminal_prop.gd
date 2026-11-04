class_name TerminalProp
extends Node3D
## The Hold-a-terminal objective's console (GDD §7.5, extraction plan Phase 6). A
## prop like LootContainer, NOT a Unit: it never acts, is never in the pool and
## cannot be shot. It BLOCKS its tile (ObjectiveManager marks the GridManager tile
## impassable, as LootManager does for a crate) and is operated from a
## neighbouring tile — `Unit.within_reach`, the same reach as looting a crate.
##
## It holds no state of its own: the clock is ObjectiveManager's TerminalRules,
## and `refresh` just draws it. Named after its tile (`node_name_for`) on every
## peer, like a crate, so both peers' copies sit at the same path.
##
## Placeholder look (extraction plan art list: "Terminal prop"): a dark console
## box with a self-lit screen whose colour is the state — dim while idle, amber
## while running, red when paused, green when complete — and a label with the
## count.

const BODY_SIZE := Vector3(0.9, 1.1, 0.6)
const SCREEN_SIZE := Vector3(0.7, 0.45, 0.05)
const BODY_COLOR := Color(0.18, 0.2, 0.24)
const SCREEN_COLOR := {
	TerminalRules.State.IDLE: Color(0.25, 0.4, 0.55),
	TerminalRules.State.RUNNING: Color(1.0, 0.7, 0.2),
	TerminalRules.State.PAUSED: Color(1.0, 0.25, 0.2),
	TerminalRules.State.COMPLETE: Color(0.35, 1.0, 0.45),
}
const LABEL_HEIGHT := 1.6

var tile: Vector3i
var _screen_mat: StandardMaterial3D
var _label: Label3D


static func node_name_for(at: Vector3i) -> String:
	return "Terminal_%d_%d_%d" % [at.x, at.y, at.z]


## Call before add_child.
func setup(at: Vector3i) -> void:
	tile = at
	name = node_name_for(at)


func _ready() -> void:
	_screen_mat = StandardMaterial3D.new()
	_screen_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if not _add_kit_visual():
		_add_box_visual()
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.fixed_size = true
	_label.font_size = 14
	_label.outline_size = 5
	_label.position = Vector3(0, LABEL_HEIGHT, 0)
	add_child(_label)
	add_to_group(NameTags.PROP_GROUP)
	apply_name_tag_mode()
	global_position = GridManager.grid_to_world(tile)


## The kit's terminal piece (ModuleCatalog socket "terminal"), sized by its
## manifest entry to stay inside BODY_SIZE, with its screen surface — the one
## whose material the manifest names `screen_material` — redrawn in the state
## colour. Turned to face the first neighbouring tile that exists, since it is
## operated from there. False when the kit has no terminal.
func _add_kit_visual() -> bool:
	var catalog := ModuleCatalog.shared()
	var p := catalog.pick("terminal", ModuleCatalog.hash_of(["terminal", tile]))
	if p.is_empty():
		return false
	var visual := catalog.instance(p)
	for side: int in [MapData.Side.SOUTH, MapData.Side.EAST, MapData.Side.NORTH, MapData.Side.WEST]:
		var step: Vector3i = MapData.SIDE_STEP[side]
		if GridManager.has_tile(tile + step):
			visual.rotation.y = atan2(float(step.x), float(step.z))
			break
	add_child(visual)
	var screen_name := String(p.get("screen_material", ""))
	for mesh: MeshInstance3D in visual.find_children("*", "MeshInstance3D", true, false):
		for s in mesh.mesh.get_surface_count():
			var mat := mesh.mesh.surface_get_material(s)
			if mat != null and mat.resource_name == screen_name:
				mesh.set_surface_override_material(s, _screen_mat)
	return true


func _add_box_visual() -> void:
	var body := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = BODY_SIZE
	body.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = BODY_COLOR
	body.material_override = mat
	body.position = Vector3(0, BODY_SIZE.y / 2.0, 0)
	add_child(body)
	var screen := MeshInstance3D.new()
	var pane := BoxMesh.new()
	pane.size = SCREEN_SIZE
	screen.mesh = pane
	screen.material_override = _screen_mat
	# On both broad faces, so it reads from any camera angle without knowing
	# which way the wall is.
	screen.position = Vector3(0, BODY_SIZE.y * 0.7, 0)
	screen.scale = Vector3(1.0, 1.0, BODY_SIZE.z / SCREEN_SIZE.z + 0.2)
	add_child(screen)


## Hides the label under the J key's NONE mode (NameTags).
func apply_name_tag_mode() -> void:
	if _label:
		_label.visible = NameTags.shows_prop()


## Redraws the screen and label from `rules` (every peer, on every change).
func refresh(rules: TerminalRules) -> void:
	if rules == null or _label == null:
		return
	_screen_mat.albedo_color = SCREEN_COLOR.get(rules.state, Color.WHITE)
	match rules.state:
		TerminalRules.State.IDLE:
			_label.text = "Terminal"
		TerminalRules.State.COMPLETE:
			_label.text = "Terminal — done"
		TerminalRules.State.PAUSED:
			_label.text = "Terminal — paused %d/%d" % [rules.progress, TerminalRules.HOLD_ROUNDS]
		_:
			_label.text = "Terminal %d/%d" % [rules.progress, TerminalRules.HOLD_ROUNDS]
	_label.modulate = SCREEN_COLOR.get(rules.state, Color.WHITE).lightened(0.3)
