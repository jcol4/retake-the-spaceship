extends SceneTree
## Boots the real game, waits, and writes a PNG of the frame. Used to eyeball
## model/rig wiring that a headless run can't show.
##   godot --path . --script res://tools/screenshot.gd
## Honours SHOT_PATH and SHOT_DELAY environment variables.

var _elapsed := 0.0
var _delay := 2.0
var _done := false
var _prepared := false
var _settle := 0


func _initialize() -> void:
	_delay = float(OS.get_environment("SHOT_DELAY")) if OS.has_environment("SHOT_DELAY") else 2.0
	change_scene_to_file.call_deferred("res://scenes/main.tscn")


func _closeup() -> void:
	## Drops a camera next to the first player unit — the tactical camera is far
	## too high to judge a 1.8 m model's rig.
	var units := root.get_tree().get_nodes_in_group("player_units")
	if units.is_empty():
		print("[screenshot] no player units found")
		return
	var unit: Node3D = units[0]
	var focus := unit.global_position + Vector3(0.0, 0.95, 0.0)
	var cam := Camera3D.new()
	root.add_child(cam)
	# Units face -Z, so a -Z camera offset sees the front.
	var off := Vector3(1.5, 0.9, -2.3)
	if OS.has_environment("SHOT_BACK"):
		off = Vector3(1.9, 1.1, 2.3)
	elif OS.has_environment("SHOT_SIDE"):
		# Straight off the right shoulder: the only angle that shows the
		# weapon's full length instead of foreshortening it.
		off = Vector3(3.0, 0.85, 0.0)
	cam.global_position = focus + off
	cam.look_at(focus)
	cam.fov = 45.0
	cam.make_current()
	# Modest fill: the ship is deliberately dark, but 1.6 blew the suit to white.
	var light := DirectionalLight3D.new()
	root.add_child(light)
	light.global_position = focus + Vector3(2.0, 3.0, -2.0)
	light.look_at(focus)
	light.light_energy = 0.55
	print("[screenshot] closeup on ", unit.name, " at ", unit.global_position)
	# Objective check on the weapon mount, which is hard to judge from pixels.
	# MUZZLE is (0, 0.455, 0.014) in Blender rifle space; Blender (x,y,z) maps to
	# Godot (x, z, -y), hence (0, 0.014, -0.455) here.
	var vis: Node = unit.get_node_or_null("Visual")
	var ap: AnimationPlayer = vis.get("anim") if vis else null
	print("[screenshot] visual=", vis, " anim=", ap)
	if ap:
		print("[screenshot] playing=", ap.is_playing(), " current='", ap.current_animation,
			"' root=", ap.root_node, " has_idle=", ap.has_animation("idle"))
	var mount := unit.get_node_or_null("Visual/soldier/Rig/Skeleton3D/RifleMount")
	if mount == null:
		print("[screenshot] RifleMount NOT FOUND")
		return
	var rifle: Node3D = mount.get_node_or_null("rifle")
	var muzzle: Vector3 = rifle.to_global(Vector3(0.0, 0.014, -0.455))
	var barrel := -rifle.global_transform.basis.z.normalized()
	print("[screenshot] mount(local to unit)=", unit.to_local(mount.global_position))
	print("[screenshot] muzzle(local to unit)=", unit.to_local(muzzle))
	print("[screenshot] barrel dir=", barrel, "  (want ~(0,~0,-1) = unit forward)")


func _process(delta: float) -> bool:
	_elapsed += delta
	if _done or _elapsed < _delay:
		return false
	# Never await in here: _process must keep returning a bool, and awaiting
	# turns it into a coroutine that silently never reaches the save.
	if not _prepared:
		_prepared = true
		if OS.has_environment("SHOT_CLOSEUP"):
			_closeup()
		return false
	if _settle < 2:
		_settle += 1  # let the new camera actually render
		return false
	_done = true
	var path := OS.get_environment("SHOT_PATH")
	var image := root.get_texture().get_image()
	var err := image.save_png(path)
	print("[screenshot] ", path, " err=", err, " size=", image.get_size())
	quit()
	return true
