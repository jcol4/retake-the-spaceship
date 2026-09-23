extends SceneTree
## The muzzle-flash overlay: that a layer drawn on a bigger canvas still REGISTERS
## with the body art, and that the tile-light tint leaves it alone.
##
##   godot --headless --path . --script res://tools/test_sprite_layers.gd
##
## Asserted as arithmetic rather than judged from a render, and that is the whole
## reason this file exists. A flash half a head off the barrel is a perfectly
## plausible-looking image, the error would be a different amount on each of the
## eight facings, and the only way to see it at all is to already know where it
## was supposed to be. The identity is exact, so it can be checked exactly.
##
## The identity: `render_sprites.py --flash` renders through the SAME camera at
## the SAME centre with the ortho extent and the resolution both multiplied by
## FLASH_CANVAS_SCALE. Metres-per-pixel is therefore unchanged, and a world point
## at fraction f of the body canvas sits at 0.5 + (f - 0.5) / scale of the larger
## one -- which `UnitVisual._layer_anchor` undoes. Both halves are checked here,
## because either one alone is satisfiable by art that is simply the wrong size.
##
## Scripts are load()ed rather than named, for the reason test_sprite_direction
## gives: unit_visual.gd touches autoloads at compile time and a --script tool is
## compiled before autoloads register.

## The merc's, copied from player_unit.tscn. Copied rather than read off the
## scene because the point is the ARITHMETIC, and a scene that stopped declaring
## the flash layer should fail the last check below rather than silently skip
## every check above it.
const CANVAS_HEIGHT := 2.56
const FOOT_ANCHOR := Vector2(0.5, 0.93359375)
const BODY_PX := 256

## Mirrors render_sprites.py FLASH_CANVAS_SCALE. If that number moves, this one
## moves with it -- they are the same number twice, on the two sides of the
## render, and a disagreement is exactly what this file is here to catch.
const FLASH_SCALE := 2.0

var _failures := 0
var _visual


func _initialize() -> void:
	_visual = load("res://scripts/unit_visual.gd")
	_check_registration()
	_check_plain_layers_untouched()
	_check_unrendered_overlay_is_invisible()
	_check_flash_is_not_dimmed()
	_check_scene_declares_it()

	print("")
	if _failures == 0:
		print("sprite layers: ALL CHECKS PASSED")
		quit(0)
	else:
		print("sprite layers: %d CHECK(S) FAILED" % _failures)
		quit(1)


## The load-bearing one: body and flash must resolve to the same world scale and
## the same world origin, from two canvases that share neither size nor anchor.
func _check_registration() -> void:
	var visual = _fixture()
	var body := _scaled(visual, &"body", BODY_PX)
	var flash := _scaled(visual, &"flash", int(BODY_PX * FLASH_SCALE))

	_check(is_equal_approx(body.pixel_size, flash.pixel_size),
		"both layers draw at the same metres per pixel (%f vs %f)"
			% [body.pixel_size, flash.pixel_size])

	# The pivot in METRES from each card's own centre. Equal means the two cards
	# put the unit's origin at the same place, which is the only sense in which
	# art on two different canvases can be said to line up.
	var body_origin := body.offset * body.pixel_size
	var flash_origin := flash.offset * flash.pixel_size
	_check(body_origin.is_equal_approx(flash_origin),
		"both layers put the unit origin at the same point (%v vs %v)"
			% [body_origin, flash_origin])

	var flash_metres := BODY_PX * FLASH_SCALE * flash.pixel_size
	_check(is_equal_approx(flash_metres, CANVAS_HEIGHT * FLASH_SCALE),
		"the flash card is %s m tall, %sx the body's" % [flash_metres, FLASH_SCALE])

	# The headroom this whole arrangement was built to buy. The body canvas
	# leaves the barrel tip 29 px of the 256 (see muzzle_merc.json, fire_shoot
	# frame 0 facing nw); the flash canvas adds a full body canvas of margin on
	# every side, which is what a flash of any real size needs.
	var gained := (flash_metres - CANVAS_HEIGHT) / 2.0
	_check(gained > 1.0,
		"the flash canvas clears the body's by %.2f m on every side" % gained)
	# Freed here rather than left to the tree: these sprites were never added to
	# one, so nothing else is going to.
	body.free()
	flash.free()
	visual.free()


## A layer with no override must be untouched by any of this -- the overlay is an
## addition to the pivot contract, not a change to it.
func _check_plain_layers_untouched() -> void:
	var visual = _fixture()
	_check(visual._layer_anchor(&"body") == FOOT_ANCHOR,
		"an unscaled layer keeps foot_anchor exactly")

	# A scale of zero is not a smaller canvas, it is a division by zero in
	# pixel_size and a character that vanishes. It has to read as "no override".
	visual.layer_canvas_scale = {&"body": 0.0}
	_check(is_equal_approx(visual._canvas_scale(&"body"), 1.0),
		"a zero scale falls back to 1 rather than dividing by it")
	visual.free()


## Declaring the layer BEFORE rendering its art is the normal order of work, so
## it has to be the safe one: an overlay with no PNGs shows nothing, where a
## character layer with no PNGs shows the code placeholder.
func _check_unrendered_overlay_is_invisible() -> void:
	var visual = _fixture()
	var overlay: SpriteFrames = visual._unauthored_frames(&"flash")
	_check(overlay.get_animation_names().is_empty(),
		"an unrendered overlay resolves to nothing, not to a placeholder body")

	var character: SpriteFrames = visual._unauthored_frames(&"body")
	_check(not character.get_animation_names().is_empty(),
		"an unrendered character layer still gets its placeholder")
	visual.free()


## That the merc scene actually asks for the layer, at the scale the renderer
## writes. Everything above is arithmetic and would keep passing with the layer
## switched off entirely.
func _check_scene_declares_it() -> void:
	var scene: PackedScene = load("res://scenes/player_unit.tscn")
	var unit: Node = scene.instantiate()
	var visual: Node = unit.get_node("Visual")
	_check(visual.layers.has(&"flash"), "player_unit declares the flash layer")
	_check(visual.layers[visual.layers.size() - 1] == &"flash",
		"the flash layer is LAST, so it draws in front of the body")
	_check(is_equal_approx(float(visual.layer_canvas_scale.get(&"flash", 0.0)),
			FLASH_SCALE),
		"it is declared at the scale render_sprites.py writes (%s)" % FLASH_SCALE)
	unit.free()


## A UnitVisual carrying the merc's numbers, never added to the tree: `_ready`
## is what builds the real layers, and it declines to in a headless build.
func _fixture():
	var visual = _visual.new()
	visual.canvas_height = CANVAS_HEIGHT
	visual.foot_anchor = FOOT_ANCHOR
	visual.layer_canvas_scale = {&"flash": FLASH_SCALE}
	return visual


## One layer's sprite, sized by the same code path the game sizes it with.
func _scaled(visual, layer: StringName, pixels: int) -> AnimatedSprite3D:
	var texture := PlaceholderTexture2D.new()
	texture.size = Vector2(pixels, pixels)
	var frames := SpriteFrames.new()
	frames.add_frame(&"default", texture)
	var sprite := AnimatedSprite3D.new()
	sprite.sprite_frames = frames
	visual._apply_frame_scale(sprite, frames, layer)
	return sprite




## The flash is LIGHT, not a thing being lit. Neither the tile tint nor the
## faction tint may touch it -- a shot in an unlit corridor is the brightest
## thing on screen, and it is fired at the same instant VfxManager floods the
## room with an OmniLight.
func _check_flash_is_not_dimmed() -> void:
	var visual = _fixture()
	# The rival mercs' rust, which every body layer on that unit is multiplied
	# by. A flash is a flash whoever fired it.
	visual.faction_tint = Color(1, 0.66, 0.48)
	_check(visual.SELF_LIT_LAYERS.has(&"flash"),
		"the flash layer is exempt from the tile-light tint")
	_check(visual._emitted_tint(&"flash") == Color.WHITE,
		"an exempt flash draws at full white, faction tint and all")

	# The status colour is the one thing a self-lit layer DOES take, and it must
	# not leak onto a flash if a character ever carries both.
	visual.set_status_color(Color(0, 1, 0))
	_check(visual._emitted_tint(&"flash") == Color.WHITE,
		"a status colour does not leak onto the flash")
	_check(visual._emitted_tint(&"status") == Color(0, 1, 0),
		"the status layer still takes the colour its unit assigned")
	visual.free()


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
