extends SceneTree
## Boots the real game and logs every animation change on one unit, so
## self-driven clips can be verified. A behaviour that fires on a random timer
## cannot be checked by a screenshot or by the --auto smoke test: --auto runs
## headless, and headless sets Unit._instant, which disables exactly this class
## of animation on purpose.
##
## Must run WINDOWED. Headless would report the unit sitting in one clip forever
## and look like a bug in the thing being tested.
##
##   WATCH_GROUP=enemy_units WATCH_NAME=Swarm WATCH_SECONDS=60 \
##     godot --path . --script res://tools/_debug_anim_watch.gd
##
## Environment:
##   WATCH_GROUP    unit group to search   (default player_units)
##   WATCH_NAME     node-name substring    (default none; takes the first)
##   WATCH_SECONDS  how long to watch      (default 45)

var _elapsed := 0.0
var _seconds := 45.0
var _unit: Node3D = null
var _anim: AnimationPlayer = null
var _last := ""
var _counts := {}
var _started := false


func _env(key: String, fallback: String) -> String:
	return OS.get_environment(key) if OS.has_environment(key) else fallback


func _initialize() -> void:
	_seconds = float(_env("WATCH_SECONDS", "45"))
	change_scene_to_file.call_deferred("res://scenes/main.tscn")


func _find() -> void:
	_started = true
	var units := root.get_tree().get_nodes_in_group(_env("WATCH_GROUP", "player_units"))
	var want := _env("WATCH_NAME", "")
	if not want.is_empty():
		units = units.filter(func(n: Node) -> bool: return want in String(n.name))
	if units.is_empty():
		print("[watch] no matching unit")
		quit()
		return
	_unit = units[0]
	# Read the resolved player off UnitVisual rather than guessing a node path:
	# the path differs per character, and that is the whole point of anim_path.
	var vis: Node = _unit.get_node_or_null("Visual")
	_anim = vis.get("anim") if vis else null
	if _anim == null:
		print("[watch] ", _unit.name, " has no AnimationPlayer")
		quit()
		return
	print("[watch] watching ", _unit.name, " for ", _seconds, "s; clips: ",
		_anim.get_animation_list())


func _process(delta: float) -> bool:
	_elapsed += delta
	# One second of grace for the scene to build before anything is looked up.
	if not _started:
		if _elapsed < 1.0:
			return false
		_find()
		return false
	if _anim == null:
		return true

	var now := _anim.current_animation
	if now != _last:
		print("[watch] %6.2fs  %s -> %s" % [_elapsed, _last if _last else "(none)", now])
		_last = now
		_counts[now] = int(_counts.get(now, 0)) + 1

	if _elapsed < _seconds:
		return false
	print("[watch] --- ", _elapsed, "s elapsed; times each clip started ---")
	for name in _counts:
		print("[watch]   ", name, ": ", _counts[name])
	quit()
	return true
