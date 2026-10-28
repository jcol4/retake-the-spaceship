class_name PixelView
extends CanvasLayer
## Draws the 3D world at a reduced resolution and scales it back up with
## hard-edged filtering: the chunky-pixel iso look, from live 3D.
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
##
## Text stays sharp: every Label3D is moved onto TEXT_LAYER, which the low-res
## camera skips. A second, full-resolution SubViewport sees only that layer
## through an unsnapped copy of the rig camera and is laid over the upscaled
## world. The cost is that labels there are not hidden behind walls -- the
## overlay has no world depth to test against -- which the readable-through-
## cover labels already did anyway.

## Texel density is locked to the WORLD, not the screen: a texel is always the
## size it is at the closest zoom, so a merc keeps the same texel count as the
## camera pulls back. The buffer grows instead, and each texel covers fewer
## screen pixels, down to one -- past that, the screen has no more pixels to
## give and the density finally drops. The fractional upscale in between goes
## through sharp_upscale.gdshader rather than nearest filtering.

const CameraRig := preload("res://scripts/camera_rig.gd")
const SHARP_UPSCALE := preload("res://shaders/sharp_upscale.gdshader")

## Screen pixels per rendered texel at the closest zoom (CameraRig.MIN_ZOOM_SIZE).
@export_range(1, 8) var pixel_scale: int = 2

## THE BUFFER NEVER RESIZES WITH ZOOM. It is always the size the widest view
## needs (one texel per screen pixel), and closer views draw it larger than the
## screen and crop the overflow. Resizing to fit each zoom instead reallocates
## the render target and its fog/glow history, and every resize flashed a blank
## or stale, mis-sized frame -- several a second while the zoom was smoothing.
## The price is that close views render world off the screen edges, so every
## zoom costs what the widest one does.

## The rig's camera, which is the one the game reads and moves.
@export var source: Camera3D

## Spare texels on every edge, so the sub-texel slide never shows a gap at the
## screen border. The slide is at most half a texel, so one is enough.
const MARGIN := 1

## Render layer 20, reserved for Label3D text. Nothing else should use it.
const TEXT_LAYER := 1 << 19

var _viewport: SubViewport
var _camera: Camera3D
var _rect: TextureRect
var _text_viewport: SubViewport
var _text_camera: Camera3D
var _text_rect: TextureRect


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
	# Linear, because the shader leans on it for the one-pixel blend band at
	# texel boundaries; everywhere else it samples texel centres.
	_rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var upscale := ShaderMaterial.new()
	upscale.shader = SHARP_UPSCALE
	_rect.material = upscale
	_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_rect.stretch_mode = TextureRect.STRETCH_SCALE
	# Clicks go through to _unhandled_input and the picking code as before.
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_rect)

	_text_viewport = SubViewport.new()
	_text_viewport.name = "Text"
	_text_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_text_viewport.transparent_bg = true
	# Labels are unshaded; no lights need shadow maps drawn a second time.
	_text_viewport.positional_shadow_atlas_size = 0
	add_child(_text_viewport)

	_text_camera = Camera3D.new()
	_text_camera.name = "TextCamera"
	# Its own blank environment, so the world one's glow and tonemap don't
	# bleed haze over the transparent areas or tint the text twice.
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	_text_camera.environment = env
	_text_viewport.add_child(_text_camera)
	_text_camera.current = true

	_text_rect = TextureRect.new()
	_text_rect.name = "TextOverlay"
	_text_rect.texture = _text_viewport.get_texture()
	_text_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_text_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_text_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_text_rect)

	for label in get_tree().root.find_children("*", "Label3D", true, false):
		_to_text_layer(label)
	get_tree().node_added.connect(_to_text_layer)

	root.disable_3d = true
	# After every _process AND every tween, so the snap-rotation tween is never
	# a frame behind.
	RenderingServer.frame_pre_draw.connect(_sync)
	_sync()


func _exit_tree() -> void:
	if _viewport == null:
		return
	get_viewport().disable_3d = false
	if get_tree().node_added.is_connected(_to_text_layer):
		get_tree().node_added.disconnect(_to_text_layer)
	if RenderingServer.frame_pre_draw.is_connected(_sync):
		RenderingServer.frame_pre_draw.disconnect(_sync)


func _sync() -> void:
	if not is_instance_valid(source) or not source.is_inside_tree():
		return
	var screen := get_viewport().get_visible_rect().size
	# Screen pixels per texel: pixel_scale at the closest zoom, shrinking as the
	# view widens so a texel stays the same size in the world, floored at one.
	var px_per_texel := maxf(1.0, pixel_scale * CameraRig.MIN_ZOOM_SIZE / source.size)
	var buffer := Vector2i(screen.ceil()) + Vector2i.ONE * MARGIN * 2
	if _viewport.size != buffer:
		_viewport.size = buffer

	# World units per texel.
	var texel := source.size / (screen.y / px_per_texel)
	_camera.projection = source.projection
	_camera.keep_aspect = source.keep_aspect
	_camera.near = source.near
	_camera.far = source.far
	_camera.cull_mask = source.cull_mask & ~TEXT_LAYER
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
	var slide := Vector2(-error.x, error.y) / texel * px_per_texel
	var drawn := Vector2(buffer) * px_per_texel
	# Enlarged through scale, never size: a Control's size change only reaches
	# the screen when it redraws, a frame later, while its transform applies at
	# once -- resizing put the world a frame behind the text overlay's zoom.
	_rect.size = Vector2(buffer)
	_rect.scale = Vector2.ONE * px_per_texel
	_rect.position = (screen / 2.0 - drawn / 2.0 + slide).round()

	# Text: full resolution, the rig camera exactly, no snapping or slide.
	if _text_viewport.size != Vector2i(screen):
		_text_viewport.size = Vector2i(screen)
	_text_camera.projection = source.projection
	_text_camera.keep_aspect = source.keep_aspect
	_text_camera.near = source.near
	_text_camera.far = source.far
	_text_camera.size = source.size
	_text_camera.fov = source.fov
	_text_camera.cull_mask = TEXT_LAYER
	_text_camera.global_transform = source.global_transform
	_text_rect.position = Vector2.ZERO
	_text_rect.size = screen


func _to_text_layer(node: Node) -> void:
	if node is Label3D:
		(node as Label3D).layers = TEXT_LAYER
