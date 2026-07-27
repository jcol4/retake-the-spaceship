extends SceneTree
## Proves UnitVisual.play_burst actually fires N rounds and re-kicks the weapon
## for each one. The failure this guards against is silent: play() on the clip
## already running is a no-op, so without the seek every round after the first
## emits its muzzle event over a weapon that never moved.
##
## Run: godot_console.exe --headless --path <proj> --script res://tools/_debug_burst.gd

const ROUNDS := 5

var _vis: Node3D
var _anim: AnimationPlayer
var _rifle: Node3D
var _shots := 0
var _done := false


func _initialize() -> void:
	_vis = load("res://scenes/character_base.tscn").instantiate()
	root.add_child(_vis)
	_anim = _vis.get_node("soldier/AnimationPlayer")
	_rifle = _vis.get_node("soldier/Rig/Skeleton3D/RifleMount/rifle")
	_vis.muzzle.connect(_on_muzzle)
	_run()


func _run() -> void:
	# Nodes added during _initialize have not run _ready yet, so UnitVisual has
	# not resolved its AnimationPlayer. Without this the burst silently takes the
	# no-clip fallback and the test measures nothing.
	await process_frame
	print("[burst] anim=%s has_recoil=%s" % [_vis.anim, _anim.has_animation("shoot_recoil")])
	var started := Time.get_ticks_msec()
	await _vis.play_burst(ROUNDS)
	var elapsed := (Time.get_ticks_msec() - started) / 1000.0
	print("[burst] %d rounds in %.2fs (expected %d)" % [_shots, elapsed, ROUNDS])
	print("[burst] back to stance: '%s'" % _anim.current_animation)
	_done = true


func _on_muzzle() -> void:
	_shots += 1
	var dir := -_rifle.global_transform.basis.z.normalized()
	print("[burst] round %d  clip='%s' t=%.3f  barrel pitch=%+.1f"
		% [_shots, _anim.current_animation, _anim.current_animation_position,
		rad_to_deg(asin(dir.y))])


func _process(_delta: float) -> bool:
	return _done
