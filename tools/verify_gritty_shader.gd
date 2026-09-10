extends Node3D
## Throwaway visual check for shaders/gritty_fallout.gdshader — not part of the
## game, just a fast way to confirm the merc renders with the filter instead
## of trusting a screenshot from the full game scene.

func _ready() -> void:
	var world_env := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.05, 0.07)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 1.0
	world_env.environment = env
	add_child(world_env)

	var cam := Camera3D.new()
	cam.position = Vector3(0, 1.3, 1.7)
	add_child(cam)
	cam.current = true

	var visual := preload("res://scripts/unit_visual.gd").new()
	visual.layers = [&"body"]
	visual.variant = &"merc"
	visual.has_light = false
	visual.canvas_height = 2.56
	visual.foot_anchor = Vector2(0.5, 0.984375)
	visual.test_shader = load("res://shaders/gritty_fallout_test.tres")
	var host := Node3D.new()
	add_child(host)
	host.add_child(visual)
	visual.setup()  # plays IDLE — otherwise the screenshot shows whichever
	# animation AnimatedSprite3D happened to default to, not a representative pose

	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://tools/gritty_check.png")
	print("saved screenshot")
	get_tree().quit()
