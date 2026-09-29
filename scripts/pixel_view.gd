class_name PixelView
extends CanvasLayer
## Draws the 3D world at 1/pixel_scale resolution and scales it back up with
## nearest filtering: the chunky-pixel iso look, from live 3D.
##
## THE WORLD IS NOT MOVED INTO THE SUBVIEWPORT. A SubViewport with no world of
## its own shares its parent viewport's World3D, so a mirror camera in here sees
## the same scene the rig's camera does. The root viewport then stops drawing 3D
## (`disable_3d`) but keeps the rig's camera as its current one — so every
## `get_viewport().get_camera_3d()` + mouse-position pick in the codebase, the
## audio listener, and the HUD are all untouched. The mirror camera is set up so
## one screen pixel maps to the same world point through either camera.
##
## Pixel-snapped: the mirror camera moves only in whole texels across the screen
## plane, and the leftover sub-texel error slides the upscaled image instead.
## Without that, panning makes every edge in frame crawl as it flips between
## neighbouring texels.

## Screen pixels per rendered texel.
@export_range(1, 8) var pixel_scale: int = 2

## The rig's camera, which is the one the game reads and moves.
@export var source: Camera3D

## Spare texels on every edge, so the sub-texel slide never shows a gap at the
## screen border. The slide is at most half a texel, so one is enough.
const MARGIN := 1

var _viewport: SubViewport
var _camera: Camera3D
var _rect: TextureRect


func _ready() -> void:
	# No frames to draw headless, and nothing to mirror without a source.
	if DisplayServer.get_name() == "headless" or source == null:
		return
	var root := get_viewport()
	_viewport = SubViewport.new()
	_viewport.name = "LowRes"
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# Smoothing would blur the very edges this exists to keep hard.
	_viewport.msaa_3d = Viewport.MSAA_DISABLED
	_viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	_viewport.use_taa = false
	# A SubViewport's shadow atlas defaults smaller than the root's, and every
	# rig light is a shadowed spot. Taken from the root so they look the same.
	_viewport.positional_shadow_atlas_size = root.positional_shadow_atlas_size
	_viewport.positional_shadow_atlas_16_bits = root.positional_shadow_atlas_16_bits
	add_child(_viewport)

	_camera = Camera3D.new()
	_camera.name = "PixelCamera"
	_viewport.add_child(_camera)
	_camera.current = true

	_rect = TextureRect.new()
	_rect.name = "Upscaled"
	_rect.texture = _viewport.get_texture()
	_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_rect.stretch_mode = TextureRect.STRETCH_SCALE
	# Clicks go through to _unhandled_input and the picking code as before.
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_rect)

	root.disable_3d = true
	# After every _process AND every tween, so the snap-rotation tween is never
	# a frame behind.
	RenderingServer.frame_pre_draw.connect(_sync)
	_sync()


func _exit_tree() -> void:
	if _viewport == null:
		return
	get_viewport().disable_3d = false
	if RenderingServer.frame_pre_draw.is_connected(_sync):
		RenderingServer.frame_pre_draw.disconnect(_sync)


func _sync() -> void:
	if not is_instance_valid(source) or not source.is_inside_tree():
		return
	var screen := get_viewport().get_visible_rect().size
	var buffer := Vector2i((screen / pixel_scale).ceil()) + Vector2i.ONE * MARGIN * 2
	if _viewport.size != buffer:
		_viewport.size = buffer

	# World units per texel — the rig camera's scale, times pixel_scale.
	var texel := source.size / (screen.y / pixel_scale)
	_camera.projection = source.projection
	_camera.keep_aspect = source.keep_aspect
	_camera.near = source.near
	_camera.far = source.far
	_camera.cull_mask = source.cull_mask
	# The buffer is taller than the screen by the margins, so its vertical
	# extent grows with it; the per-texel scale is what has to match.
	_camera.size = texel * buffer.y

	# Snap the camera's position along its own right/up axes to the texel grid.
	# Along its forward axis nothing changes in an orthographic image, so that
	# component is left alone.
	var xf := source.global_transform
	var local := xf.basis.transposed() * xf.origin
	var on_grid := Vector3(roundf(local.x / texel) * texel,
		roundf(local.y / texel) * texel, local.z)
	_camera.global_transform = Transform3D(xf.basis, xf.basis * on_grid)

	# The snapped camera sees the world shifted by the error; slide the image
	# the other way so the true camera centre stays at the screen centre. Screen
	# y runs down while camera up is +y, hence the sign flip.
	var error := local - on_grid
	var slide := Vector2(-error.x, error.y) / texel * pixel_scale
	var drawn := Vector2(buffer) * pixel_scale
	_rect.size = drawn
	_rect.position = (screen / 2.0 - drawn / 2.0 + slide).round()
