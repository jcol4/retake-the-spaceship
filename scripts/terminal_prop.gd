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
	_screen_mat = StandardMaterial3D.new()
	_screen_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	screen.material_override = _screen_mat
	# On both broad faces, so it reads from any camera angle without knowing
	# which way the wall is.
	screen.position = Vector3(0, BODY_SIZE.y * 0.7, 0)
	screen.scale = Vector3(1.0, 1.0, BODY_SIZE.z / SCREEN_SIZE.z + 0.2)
	add_child(screen)
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.fixed_size = true
	_label.font_size = 14
	_label.outline_size = 5
	_label.position = Vector3(0, LABEL_HEIGHT, 0)
	add_child(_label)
	global_position = GridManager.grid_to_world(tile)


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
