class_name FaceFeed
extends TextureRect
## A live helmet-cam view of one soldier's face, for the squad feed.
##
## NOTHING IS DUPLICATED. The SubViewport here has no world of its own, so it
## shares the battle's World3D -- the same trick PixelView uses -- and its
## camera simply looks at the real soldier: real animation, real lighting,
## smoke, muzzle flash, and the ragdoll when they fall.
##
## The camera hangs off a BoneAttachment3D on the model's `head` bone (an
## attachment, not `get_bone_global_pose`, because only an attachment follows
## the post-modifier pose -- see AimModifier). While the soldier is up it sits
## in front of the face along the unit's facing; that position is also kept in
## the head's own frame, and once they go down the camera rides the head in
## that frame instead, so a fall tumbles the feed with them.

const HEAD_BONE := &"head"
## Feed resolution in texels: drawn upscaled with nearest filtering.
const RES := Vector2i(80, 60)
## Where the camera sits relative to the head bone, world metres.
const FACE_DISTANCE := 0.65
const CAM_RAISE := 0.08
## The head bone's origin is the base of the skull; aim a little above it.
const LOOK_RAISE := 0.08
## Frames per second for a feed that is not the active soldier's.
const IDLE_FPS := 15.0
## Higher = the camera sticks closer to the head (less sway).
const FOLLOW := 10.0
## The feed's low-light gain over the world's environment (see _build_environment).
const AMBIENT_GAIN := 4.0
const EXPOSURE_GAIN := 1.6

var unit: Unit
## Full-rate rendering, for the soldier being commanded.
var active := false:
	set(value):
		active = value
		_apply_update_mode()
## Stop rendering: the last frame stays up (a dead feed).
var frozen := false:
	set(value):
		frozen = value
		_apply_update_mode()

var _vp: SubViewport
var _cam: Camera3D
var _skel: Skeleton3D
var _head: BoneAttachment3D
## The camera's spot in the head's frame, captured while the soldier stands.
var _head_local := Transform3D.IDENTITY
var _has_head_local := false
var _snap := true
var _idle_clock := 0.0


func setup(for_unit: Unit) -> void:
	unit = for_unit
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stretch_mode = TextureRect.STRETCH_SCALE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vp = SubViewport.new()
	_vp.name = "FeedViewport"
	_vp.size = RES
	_vp.own_world_3d = false
	_vp.msaa_3d = Viewport.MSAA_DISABLED
	_vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	# Every positional light would otherwise redraw its shadow map per feed.
	_vp.positional_shadow_atlas_size = 0
	_vp.audio_listener_enable_3d = false
	add_child(_vp)
	_cam = Camera3D.new()
	_cam.fov = 34.0
	_cam.near = 0.03
	_cam.far = 40.0
	# Name tags live on TEXT_LAYER; they would float across every face.
	_cam.cull_mask = 0xFFFFF & ~PixelView.TEXT_LAYER
	_vp.add_child(_cam)
	_cam.current = true
	texture = _vp.get_texture()
	_apply_update_mode()


func _exit_tree() -> void:
	if is_instance_valid(_head):
		_head.queue_free()


func _apply_update_mode() -> void:
	if _vp == null:
		return
	if frozen:
		_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	elif active:
		_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	else:
		_vp.render_target_update_mode = SubViewport.UPDATE_ONCE


func _process(delta: float) -> void:
	if _vp == null or not is_instance_valid(unit):
		return
	if not frozen and not active:
		_idle_clock -= delta
		if _idle_clock <= 0.0:
			_idle_clock = 1.0 / IDLE_FPS
			_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	if frozen:
		return
	if _cam.environment == null:
		_build_environment()
	_track(delta)


## The feed's own copy of the world's Environment, brighter: a helmet cam's
## low-light gain. Not a lamp -- any light added to the shared world would also
## brighten the soldier in the main view, where what is drawn as lit should
## match what the rules count as lit (LightingManager).
func _build_environment() -> void:
	var world := _cam.get_world_3d()
	var base: Environment = world.environment if world else null
	if base == null:
		var we := get_tree().root.find_child("*WorldEnvironment*", true, false) as WorldEnvironment
		base = we.environment if we else null
	var env: Environment = base.duplicate() if base else Environment.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.75, 0.85, 0.8)
	env.ambient_light_energy = maxf(env.ambient_light_energy, 0.2) * AMBIENT_GAIN
	env.tonemap_exposure *= EXPOSURE_GAIN
	env.fog_enabled = false
	env.volumetric_fog_enabled = false
	_cam.environment = env


func _track(delta: float) -> void:
	if not _resolve_head():
		_track_fallback(delta)
		return
	var head := _head.global_transform.orthonormalized()
	var target: Transform3D
	var look_at_point: Vector3
	var up := Vector3.UP
	if unit.life_state == Unit.LifeState.ACTIVE or not _has_head_local:
		var forward := -unit.visual.global_basis.z
		forward.y = 0.0
		forward = forward.normalized() if forward.length() > 0.01 else Vector3.FORWARD
		look_at_point = head.origin + Vector3.UP * LOOK_RAISE
		var pos := look_at_point + forward * FACE_DISTANCE + Vector3.UP * (CAM_RAISE - LOOK_RAISE)
		target = Transform3D(Basis.IDENTITY, pos).looking_at(look_at_point, Vector3.UP)
		_head_local = head.affine_inverse() * target
		_has_head_local = true
	else:
		# Down: ride the head, so the fall tumbles the view.
		target = head * _head_local
		up = target.basis.y
		look_at_point = head.origin + head.basis.y * LOOK_RAISE
		# Never under the deck.
		var floor_y := unit.global_position.y + 0.05
		if target.origin.y < floor_y:
			target.origin.y = floor_y
	_move_camera(target.origin, look_at_point, up, delta)


func _track_fallback(delta: float) -> void:
	# No rigged model (placeholder, or still building): frame the unit's top.
	var top := unit.global_position + Vector3.UP * 1.45
	var forward := -unit.global_basis.z
	forward.y = 0.0
	forward = forward.normalized() if forward.length() > 0.01 else Vector3.FORWARD
	_move_camera(top + forward * 0.9 + Vector3.UP * 0.1, top, Vector3.UP, delta)


func _move_camera(pos: Vector3, look: Vector3, up: Vector3, delta: float) -> void:
	if _snap:
		_cam.global_position = pos
		_snap = false
	else:
		_cam.global_position = _cam.global_position.lerp(pos, 1.0 - exp(-FOLLOW * delta))
	var dir := look - _cam.global_position
	if dir.length() < 0.001:
		return
	if absf(dir.normalized().dot(up.normalized())) > 0.98:
		up = Vector3.FORWARD
	_cam.look_at(look, up)


## Finds (or re-finds, after a model rebuild) the head bone and hangs the
## tracking attachment on it. False when the model has no such bone.
func _resolve_head() -> bool:
	if is_instance_valid(_head) and is_instance_valid(_skel) and _head.is_inside_tree():
		return true
	_head = null
	_skel = null
	if unit.visual == null:
		return false
	for n in unit.visual.find_children("*", "Skeleton3D", true, false):
		var skel := n as Skeleton3D
		var bone := _find_head_bone(skel)
		if bone < 0:
			continue
		_skel = skel
		_head = BoneAttachment3D.new()
		_head.name = "FaceFeedHead"
		_head.bone_name = skel.get_bone_name(bone)
		skel.add_child(_head)
		_has_head_local = false
		_snap = true
		return true
	return false


static func _find_head_bone(skel: Skeleton3D) -> int:
	var bone := skel.find_bone(HEAD_BONE)
	if bone >= 0:
		return bone
	for i in skel.get_bone_count():
		var bone_name := skel.get_bone_name(i).to_lower()
		if bone_name.ends_with("head") and not bone_name.contains("end"):
			return i
	return -1
