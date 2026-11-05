class_name DevSpawn
extends Node
## TESTING MODE: the host places any creature on any free tile, mid-mission.
##
##   F8            open / close the spawn menu
##   pick a type   arms it; the tile under the cursor is outlined (green = free)
##   left-click    places one there (stays armed, so you can place several)
##   right-click / Esc   disarms
##
## Available in debug builds (the editor, `godot --path .`) and in any build run
## with `-- --dev`. Host-only in co-op: a client's copy of this node exists only
## to receive the host's spawns, so both boards hold the same unit at the same
## path and the host's state streams onto it like any map-placed unit.
##
## Every creature is built exactly the way main.gd's spawner builds a map-placed
## one (same scene, same preset, same post-add_child fix-ups), so what you test
## is what a deck would have put there. TurnManager, fog and lighting find units
## by group, so a spawned unit joins the fight with nothing else to register.

const ENEMY_SCENE := preload("res://scenes/enemy_unit.tscn")
const SWARM_SCENE := preload("res://scenes/swarm_unit.tscn")
const BRAWLER_SCENE := preload("res://scenes/brawler_unit.tscn")
const MERC_SCENE := preload("res://scenes/merc_unit.tscn")
const HUNTER_SCENE := preload("res://scenes/agile_hunter_unit.tscn")
const WORM_SCENE := preload("res://scenes/worm_unit.tscn")
const NEST_SCENE := preload("res://scenes/nest_unit.tscn")

const TOGGLE_KEY := KEY_F8

## Menu order: [id, label, faction heading]. `horde` and `worm_tide` place more
## than one tile's worth; everything else is one unit on the clicked tile.
const KINDS := [
	["zombie", "Zombie", "Aliens"],
	["brute", "Brute", "Aliens"],
	["horde", "Zombie horde (brute + pack)", "Aliens"],
	["alien", "Ranged alien", "Aliens"],
	["brawler", "Brawler", "Aliens"],
	["hunter", "Agile hunter", "Aliens"],
	["worm", "Worm", "Aliens"],
	["worm_tide", "Worm mass (16)", "Aliens"],
	["nest", "Nest", "Aliens"],
	["auxilium", "QRN-4 Auxilium", "Security robots"],
	["sagittarii", "MKV-9 Sagittarii", "Security robots"],
	["proctor", "XVT-7 Proctor", "Security robots"],
	["securus", "JXM-2 Securus", "Security robots"],
	["lictor", "FRC-6 Lictor", "Security robots"],
	["merc", "Rival merc", "Mercs"],
]
const ROBOT_KIND := {
	"auxilium": MapData.Spawn.AUXILIUM, "sagittarii": MapData.Spawn.SAGITTARII,
	"proctor": MapData.Spawn.PROCTOR, "securus": MapData.Spawn.SECURUS,
	"lictor": MapData.Spawn.LICTOR,
}
const HORDE_SIZE := 6
const TIDE_WORMS := 16

var _main: Node3D = null
var _armed := ""
var _counter := 0
var _ui: CanvasLayer = null
var _panel: PanelContainer = null
var _status: Label = null
var _marker: MeshInstance3D = null
var _marker_mat: StandardMaterial3D = null


## Whether this run offers the testing mode at all (see the class comment).
static func enabled() -> bool:
	return OS.is_debug_build() or "--dev" in OS.get_cmdline_user_args()


func _init(main: Node3D) -> void:
	name = "DevSpawn"
	_main = main


func _ready() -> void:
	set_process(false)
	if not enabled() or not _is_host() or DisplayServer.get_name() == "headless":
		return  # a receiver only (see the class comment)
	_build_ui()
	_build_marker()


func _is_host() -> bool:
	return not SteamLobby.is_networked() or multiplayer.is_server()


# --- Input ---------------------------------------------------------------------


func _input(event: InputEvent) -> void:
	if _ui == null:
		return
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo:
		if key.keycode == TOGGLE_KEY:
			_set_open(not _panel.visible)
			get_viewport().set_input_as_handled()
		elif key.keycode == KEY_ESCAPE and _armed != "":
			_arm("")
			get_viewport().set_input_as_handled()
		return
	var click := event as InputEventMouseButton
	if click == null or not click.pressed or _armed == "":
		return
	# Clicks on the menu itself go to its buttons.
	if _panel.visible and _panel.get_global_rect().has_point(click.position):
		return
	if click.button_index == MOUSE_BUTTON_RIGHT:
		_arm("")
		get_viewport().set_input_as_handled()
	elif click.button_index == MOUSE_BUTTON_LEFT:
		# Consumed either way: an armed click must never also order a soldier.
		get_viewport().set_input_as_handled()
		var tile := _tile_under_mouse()
		var err := spawn(_armed, tile)
		_status.text = err if err != "" else "Placed %s at %s — click again, or right-click to stop" % [
			_label(_armed), tile]


func _process(_delta: float) -> void:
	var tile := _tile_under_mouse()
	var ok := GridManager.has_tile(tile)
	_marker.visible = ok
	if ok:
		_marker.global_position = GridManager.grid_to_world(tile) + Vector3(0, 0.03, 0)
		_marker_mat.albedo_color = Color(0.2, 1.0, 0.3, 0.45) if GridManager.is_free(tile) \
				else Color(1.0, 0.2, 0.15, 0.45)


func _tile_under_mouse() -> Vector3i:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return PlayerUnit.NO_TILE
	var mouse := get_viewport().get_mouse_position()
	return GridManager.tile_under_ray(camera.project_ray_origin(mouse), camera.project_ray_normal(mouse))


# --- Spawning (host) -------------------------------------------------------------


## Places `kind` at `tile`, on this board and every ready client's. Host only.
## Returns "" on success, or why nothing was placed.
func spawn(kind: String, tile: Vector3i) -> String:
	if not _is_host():
		return "Only the host can spawn"
	if not GridManager.has_tile(tile):
		return "No tile there"
	if not GridManager.is_free(tile):
		return "That tile is blocked or occupied"
	if TurnManager.resolving_tick:
		return "Busy resolving a tick — try again in a moment"
	match kind:
		"horde":
			var tiles: Array[Vector3i] = _main._horde_tiles(_main.map, tile, HORDE_SIZE, {})
			var horde := "dev_horde_%d" % (_counter + 1)
			for i in tiles.size():
				_send(&"brute" if i == 0 else &"zombie", tiles[i], {"horde_id": horde})
		"worm_tide":
			_send(&"worm", tile, {"worms": TIDE_WORMS})
		_:
			_send(StringName(kind), tile, {})
	LightingManager.recompute_dynamic()
	return ""


func _send(kind: StringName, tile: Vector3i, extra: Dictionary) -> void:
	_counter += 1
	var unit_name := "Dev_%s_%d" % [kind, _counter]
	for peer_id in (SteamLobby.ready_peers if SteamLobby.is_networked() else []):
		_rpc_spawn.rpc_id(peer_id, kind, tile, unit_name, extra)
	_build(kind, tile, unit_name, extra)


@rpc("authority", "call_remote", "reliable")
func _rpc_spawn(kind: StringName, tile: Vector3i, unit_name: String, extra: Dictionary) -> void:
	_build(kind, tile, unit_name, extra)
	LightingManager.recompute_dynamic()


## One unit, built on THIS peer. Mirrors main.gd's `_spawn_and_start`.
func _build(kind: StringName, tile: Vector3i, unit_name: String, extra: Dictionary) -> Unit:
	# The presets roll stats off the global RNG. Reseeding from the unit's own
	# name puts every peer on the same sequence first, so the host's copy and a
	# client's roll the same stat block — and stay in lockstep afterwards.
	seed(hash(unit_name))
	var display := unit_name.trim_prefix("Dev_").capitalize()
	var unit: Unit = null
	match kind:
		&"zombie", &"brute":
			var swarm: SwarmUnit = SWARM_SCENE.instantiate()
			swarm.is_brute = kind == &"brute"
			swarm.stats = AlienPresets.brute(display) if swarm.is_brute else AlienPresets.swarm(display)
			swarm.horde_id = String(extra.get("horde_id", ""))
			unit = swarm
		&"alien":
			unit = ENEMY_SCENE.instantiate()
			unit.stats = AlienPresets.ranged(display)
		&"brawler":
			unit = BRAWLER_SCENE.instantiate()
			unit.stats = AlienPresets.brawler(display)
		&"hunter":
			unit = HUNTER_SCENE.instantiate()
			unit.stats = AlienPresets.hunter(display)
		&"worm":
			unit = WORM_SCENE.instantiate()
			unit.stats = AlienPresets.worm(display)
		&"nest":
			unit = NEST_SCENE.instantiate()
			unit.stats = AlienPresets.nest(display)
		&"merc":
			var merc: MercUnit = MERC_SCENE.instantiate()
			merc.stats = MercPresets.rifleman(display)
			# Its own squad: a dev merc is not drafted into a placed team's plan.
			merc.squad_id = "dev_" + unit_name
			merc.inventory = MercPresets.roll_inventory()
			unit = merc
		_:
			if not ROBOT_KIND.has(String(kind)):
				push_warning("DevSpawn: unknown kind %s" % kind)
				return null
			var robot_kind: int = ROBOT_KIND[String(kind)]
			var robot: CerberusUnit = CerberusPresets.scene_for(robot_kind).instantiate()
			robot.stats = CerberusPresets.make_stats(robot_kind, 1)
			robot.security_zone = _main.map.zone_at(tile)
			unit = robot
	unit.name = unit_name
	unit.position = GridManager.grid_to_world(tile)
	_main.add_child(unit)  # Unit._ready snaps to the grid and takes the tile
	unit.action_logged.connect(_main._on_unit_log)
	# A mass is the same unit carrying more HP, written AFTER add_child — see
	# the worm loop in main.gd for why the order matters.
	var worms := int(extra.get("worms", 1))
	if kind == &"worm" and worms > 1:
		var worm := unit as WormUnit
		worm.current_hp = mini(worms, WormUnit.MAX_WORMS) * WormUnit.HP_PER_WORM
		worm._apply_count()
	_main.hud.append_log("[DEV] %s spawned at %s" % [unit.stats.display_name, tile])
	return unit


# --- Menu ------------------------------------------------------------------------


func _set_open(open: bool) -> void:
	_panel.visible = open
	if not open:
		_arm("")


func _arm(kind: String) -> void:
	_armed = kind
	set_process(kind != "")
	if _marker:
		_marker.visible = false
	if kind == "":
		_status.text = "Pick a creature, then click a tile"
	else:
		_status.text = "Placing %s — click a tile, right-click or Esc to stop" % _label(kind)


func _label(kind: String) -> String:
	for k in KINDS:
		if k[0] == kind:
			return k[1]
	return kind


func _build_ui() -> void:
	_ui = CanvasLayer.new()
	_ui.name = "DevSpawnUI"
	_ui.layer = 60
	add_child(_ui)
	_panel = PanelContainer.new()
	_panel.visible = false
	# Left edge, clear of the combat log (top right) and the portraits (bottom).
	_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_panel.position = Vector2(16, 100)
	_panel.custom_minimum_size = Vector2(260, 0)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.06, 0.07, 0.09, 0.92)
	bg.border_color = Color(0.9, 0.55, 0.1)
	bg.set_border_width_all(1)
	bg.set_content_margin_all(10)
	_panel.add_theme_stylebox_override("panel", bg)
	_ui.add_child(_panel)
	var box := VBoxContainer.new()
	_panel.add_child(box)
	var title := Label.new()
	title.text = "TESTING — spawn (F8)"
	box.add_child(title)
	var heading := ""
	for k in KINDS:
		if k[2] != heading:
			heading = k[2]
			var h := Label.new()
			h.text = heading
			h.modulate = Color(0.7, 0.75, 0.85)
			box.add_child(h)
		var b := Button.new()
		b.text = k[1]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(_arm.bind(k[0]))
		box.add_child(b)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(240, 0)
	box.add_child(_status)
	_arm("")


func _build_marker() -> void:
	_marker = MeshInstance3D.new()
	_marker.name = "DevSpawnMarker"
	var plane := PlaneMesh.new()
	plane.size = Vector2(GridManager.TILE_SIZE, GridManager.TILE_SIZE) * 0.9
	_marker.mesh = plane
	_marker_mat = StandardMaterial3D.new()
	_marker_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_marker_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_marker_mat.no_depth_test = true
	_marker.material_override = _marker_mat
	_marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_marker.visible = false
	_main.add_child(_marker)
