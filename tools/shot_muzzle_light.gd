extends SceneTree
## Tunes the room-flooding muzzle light (VfxManager.MUZZLE_LIGHT_*) by eye: boots
## the real game, centres on a soldier, and writes two PNGs — the room as it is,
## and the same frame with one muzzle pulse held at peak from that soldier's
## barrel — plus how much of each frame is clipped and how bright it is overall.
##   godot --path . --script res://tools/shot_muzzle_light.gd
## Windowed only (headless builds no model). Env: SHOT_DIR (default user://),
## SHOT_UNIT (index into player_units, default 0), SHOT_SCALE (weapon scale,
## default the unit's own), SHOT_ZOOM (Camera3D.size).

var _elapsed := 0.0
var _step := 0
var _wait := 0
var _dir := ""
var _unit: Node3D
var _base: Image


func _initialize() -> void:
	_dir = OS.get_environment("SHOT_DIR") if OS.has_environment("SHOT_DIR") else "user://"
	change_scene_to_file.call_deferred("res://scenes/main.tscn")


func _process(delta: float) -> bool:
	_elapsed += delta
	if _wait > 0:
		_wait -= 1
		return false
	match _step:
		0:
			if _elapsed < 4.0:
				return false
			_prepare()
			_step = 1
			_wait = 30  # camera smoothing lands
		1:
			_base = root.get_texture().get_image()
			_save(_base, "muzzle_base.png")
			_fire()
			_step = 2
			_wait = 3  # shadow map renders
		2:
			var lit := root.get_texture().get_image()
			_save(lit, "muzzle_lit.png")
			_report("base", _base)
			_report("lit ", lit)
			quit()
			return true
	return false


func _prepare() -> void:
	for node in root.find_children("*", "CanvasLayer", true, false):
		if not (node is PixelView):
			(node as CanvasLayer).visible = false
	var units := root.get_tree().get_nodes_in_group("player_units")
	var index := int(OS.get_environment("SHOT_UNIT")) if OS.has_environment("SHOT_UNIT") else 0
	_unit = units[clampi(index, 0, units.size() - 1)]
	var rig := root.get_tree().get_first_node_in_group("camera_rig")
	rig.call("focus_on", _unit.global_position)
	if OS.has_environment("SHOT_ZOOM"):
		var zoom := float(OS.get_environment("SHOT_ZOOM"))
		rig.set("_zoom_target", zoom)
		(rig.get_node("Camera3D") as Camera3D).size = zoom
	print("[muzzle] unit ", _unit.name, " at ", _unit.get("grid_pos"))


## One pulse from the unit's barrel, frozen at peak (its fade tween killed).
func _fire() -> void:
	var vfx := root.get_tree().get_first_node_in_group("vfx")
	var visual: Node3D = _unit.get("visual")
	var scale: float = float(OS.get_environment("SHOT_SCALE")) if OS.has_environment("SHOT_SCALE") \
		else visual.call("_muzzle_light_scale")
	var slot: int = vfx.get("_muzzle_next")
	vfx.call("muzzle_light", visual.call("barrel_tip"), visual.call("_bore"), scale)
	(vfx.get("_muzzle_tweens")[slot] as Tween).kill()
	print("[muzzle] scale ", scale)


func _save(image: Image, file: String) -> void:
	var path := _dir.path_join(file)
	print("[muzzle] ", ProjectSettings.globalize_path(path), " err=", image.save_png(path))


## Fraction of pixels with a channel at 255 (blown out) and mean luminance.
func _report(label: String, image: Image) -> void:
	var w := image.get_width()
	var h := image.get_height()
	var clipped := 0
	var lum := 0.0
	var n := 0
	for y in range(0, h, 4):
		for x in range(0, w, 4):
			var c := image.get_pixel(x, y)
			if maxf(c.r, maxf(c.g, c.b)) >= 0.999:
				clipped += 1
			lum += 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			n += 1
	print("[muzzle] %s clipped %.1f%%  mean lum %.3f" % [label, 100.0 * clipped / n, lum / n])
