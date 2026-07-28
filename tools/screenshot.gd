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
	## Drops a camera next to the first unit of SHOT_GROUP — the tactical camera
	## is far too high to judge a 1.8 m model's rig. SHOT_GROUP is any of the
	## groups units register in ("player_units", "enemy_units"), so an alien rig
	## can be eyeballed the same way the soldier's is; the weapon diagnostics
	## below simply report NOT FOUND on a character that carries nothing.
	var group := OS.get_environment("SHOT_GROUP") if OS.has_environment("SHOT_GROUP") \
		else "player_units"
	var units := root.get_tree().get_nodes_in_group(group)
	# "enemy_units" holds both the ranged alien and the swarm, so the group alone
	# does not identify a character. SHOT_NAME narrows by node-name substring.
	if OS.has_environment("SHOT_NAME"):
		var want := OS.get_environment("SHOT_NAME")
		units = units.filter(func(n: Node) -> bool: return want in String(n.name))
	if units.is_empty():
		print("[screenshot] no units in group '", group, "'")
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
	# The HUD sits over the unit in a closeup — including the loadout dialog,
	# which covers exactly the part of the body the weapon is held against.
	# Every CanvasLayer, not HUD by name: the loadout menu is built in code by
	# main.gd rather than living in main.tscn, and it covers exactly the chest
	# height where a carried weapon sits. Also typed as CanvasLayer and not
	# CanvasItem -- CanvasLayer descends from Node, so casting to CanvasItem
	# yields null and silently leaves the overlay up.
	var hidden := 0
	for node in root.find_children("*", "CanvasLayer", true, false):
		(node as CanvasLayer).visible = false
		hidden += 1
	print("[screenshot] hid ", hidden, " CanvasLayer(s)")
	var vis: Node = unit.get_node_or_null("Visual")
	var ap: AnimationPlayer = vis.get("anim") if vis else null
	print("[screenshot] visual=", vis, " anim=", ap)
	if ap:
		print("[screenshot] playing=", ap.is_playing(), " current='", ap.current_animation,
			"' root=", ap.root_node, " has_idle=", ap.has_animation("idle"))
		# SHOT_CLIP pins a specific pose. The game boots into idle, which carries
		# the weapon slanted across the body — the one pose where a rifle is both
		# foreshortened and half behind the torso, so it is the worst frame to
		# judge a weapon model on. SHOT_CLIP=aim_hold shows its full length.
		if OS.has_environment("SHOT_CLIP"):
			var clip := OS.get_environment("SHOT_CLIP")
			if ap.has_animation(clip):
				ap.play(clip)
				ap.advance(float(OS.get_environment("SHOT_CLIP_AT")) \
					if OS.has_environment("SHOT_CLIP_AT") else 0.0)
				ap.pause()
				print("[screenshot] pinned clip '", clip, "' at ", ap.current_animation_position)
			else:
				print("[screenshot] no such clip '", clip, "' in ", ap.get_animation_list())
	var mount := unit.get_node_or_null("Visual/soldier/Rig/Skeleton3D/RifleMount")
	if mount == null:
		print("[screenshot] RifleMount NOT FOUND")
		return
	var rifle: Node3D = mount.get_node_or_null("rifle")
	# Read the Muzzle node the GLB ships rather than a copy of its coordinates:
	# this was a hardcoded (0, 0.014, -0.455) that went stale the moment the
	# barrel got longer, and then quietly reported the wrong tip forever after.
	var muzzle_node := rifle.get_node_or_null("Muzzle") as Node3D
	var muzzle: Vector3 = muzzle_node.global_position if muzzle_node \
		else rifle.global_position
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
