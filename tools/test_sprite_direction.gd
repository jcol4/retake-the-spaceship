extends SceneTree
## Phase 6 of MIGRATION_PLAN.md: the 8-direction sprite bucketing, the mirror
## rule, and the thing the snap camera makes necessary — that a camera yaw change
## re-buckets every character even though nothing turned.
##
##   godot --headless --path . --script res://tools/test_sprite_direction.gd
##
## The bucket maths is checked statically, against known yaws, rather than by
## looking at a screenshot: "the sprite faces the wrong way" is exactly the class
## of bug that looks plausible in a still and is obvious in a table.
##
## Scripts are load()ed rather than named, because unit_visual.gd references the
## GridManager and LightingManager autoloads at COMPILE time and a --script tool
## is compiled before autoloads register.

## [relative yaw in degrees, expected screen direction].
##
## Godot's forward is -Z and screen-right at yaw 0 is +X, so a unit yawed +90
## faces -X, which is screen-LEFT. The index therefore runs anticlockwise, and
## these cases are what pins that down.
const CASES := [
	[0.0, &"n"],      # facing the same way the camera looks: back to the viewer
	[45.0, &"nw"],
	[90.0, &"w"],     # facing screen-left
	[135.0, &"sw"],
	[180.0, &"s"],    # facing the camera
	[225.0, &"se"],
	[270.0, &"e"],    # facing screen-right
	[315.0, &"ne"],
	[360.0, &"n"],    # a full turn is where it started
	[-90.0, &"e"],    # negative yaws wrap rather than clamping
	[22.0, &"n"],     # just short of the halfway point, so it rounds back
	[23.0, &"nw"],    # and just past it
]

var _failures := 0
var _visual


func _initialize() -> void:
	_visual = load("res://scripts/unit_visual.gd")
	_check_buckets()
	_check_mirror()
	await _check_camera_relative()

	print("")
	if _failures == 0:
		print("sprite direction: ALL CHECKS PASSED")
		quit(0)
	else:
		print("sprite direction: %d CHECK(S) FAILED" % _failures)
		quit(1)


func _check_buckets() -> void:
	for case: Array in CASES:
		var bucket: int = _visual.direction_bucket(deg_to_rad(case[0]))
		var got: StringName = _visual.DIRECTIONS[bucket]
		_check(got == case[1], "yaw %+7.1f deg -> %s (got %s)" % [case[0], case[1], got])


func _check_mirror() -> void:
	# The 5-drawn + 3-mirrored rule. Exactly three directions may be mirrored,
	# and each must point at a direction that IS drawn — a mirror entry aiming at
	# another mirror entry would resolve to nothing.
	var mirror: Dictionary = _visual.MIRROR
	_check(mirror.size() == 3, "3 directions are mirrored (got %d)" % mirror.size())
	for dir: StringName in mirror:
		var entry: Array = mirror[dir]
		_check(not mirror.has(entry[0]), "%s mirrors %s, which is drawn" % [dir, entry[0]])
		_check(entry[1] == true, "%s is flipped horizontally" % dir)
	var drawn := 0
	for dir: StringName in _visual.DIRECTIONS:
		if not mirror.has(dir):
			drawn += 1
	_check(drawn == 5, "5 directions are drawn (got %d)" % drawn)


func _check_camera_relative() -> void:
	# The requirement the snap camera adds: sprite direction is unit yaw MINUS
	# camera yaw, so a quarter turn of the camera moves every bucket by exactly
	# two steps without any unit having turned. That is also what makes the snap
	# free in art terms — two whole steps, never a fraction of one.
	var rig = load("res://scenes/camera_rig.tscn").instantiate()
	root.add_child(rig)
	await process_frame

	var unit_yaw := 0.0
	var before: int = _visual.direction_bucket(unit_yaw - rig.rotation.y)
	rig.snap_by(1)  # instant with no display
	await process_frame
	var after: int = _visual.direction_bucket(unit_yaw - rig.rotation.y)
	# BACKWARDS two steps, not forwards: the camera turning one way is the world
	# appearing to turn the other, and direction subtracts the camera yaw. 6 is
	# -2 modulo the eight buckets. The sign is cosmetic; that it is a WHOLE two
	# steps is not, because that is what makes the snap cost no additional art.
	var step: int = wrapi(after - before, 0, _visual.DIRECTIONS.size())
	_check(step == 6, "one camera snap moves the bucket 2 steps back (got %d)" % step)

	rig.snap_by(1)
	rig.snap_by(1)
	rig.snap_by(1)
	await process_frame
	var full: int = _visual.direction_bucket(unit_yaw - rig.rotation.y)
	_check(full == before, "four snaps return the bucket to where it started")


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
