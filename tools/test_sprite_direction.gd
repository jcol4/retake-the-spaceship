extends SceneTree
## The eight-direction sprite bucketing, the mirror rule, and the thing the snap
## camera makes necessary — that a camera yaw change re-buckets every character
## even though nothing turned.
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
##
## The eight EXACT cases are the only ones a running game produces: the rig sits
## at 45 degrees and units may only face one of the eight grid directions, so
## every real relative yaw is -45 plus a multiple of 45. The two off-axis cases
## pin down the boundaries anyway — a bucket that silently rounded the wrong way
## would still show the wrong art the moment either invariant was relaxed.
##
## Note which half is which: the four WORLD AXES land on the screen DIAGONALS,
## because the rig is yawed 45 and not 0, and the four world diagonals land on
## the screen cardinals. That inversion is the single easiest thing to get
## backwards here, so every case below names the world direction it came from.
const CASES := [
	[-45.0, &"ne"],   # world -Z: away from the camera and to the RIGHT
	[0.0, &"n"],      # world -Z-X diagonal: straight away from the camera
	[45.0, &"nw"],    # world -X
	[90.0, &"w"],     # world +Z-X diagonal
	[135.0, &"sw"],   # world +Z, toward the camera and left
	[180.0, &"s"],    # world +Z+X diagonal: straight toward the camera
	[225.0, &"se"],   # world +X
	[270.0, &"e"],    # world -Z+X diagonal
	[315.0, &"ne"],   # a full turn from -45 is where it started
	[-135.0, &"se"],  # negative yaws wrap rather than clamping
	[44.0, &"nw"],    # just short of the nw/w boundary at 67.5
	[68.0, &"w"],     # and just past it
]

## Bucket boundaries, in relative degrees. A unit can never hold one of these —
## they sit halfway between two drawn directions — but which way they round has
## to be DECIDED rather than left to floating-point noise, because a yaw tween
## passes through them on every turn.
const BOUNDARIES := [
	-22.5, 22.5, 67.5, 112.5, 157.5, 202.5, 247.5, 292.5,
]

var _failures := 0
var _visual


func _initialize() -> void:
	_visual = load("res://scripts/unit_visual.gd")
	_check_buckets()
	_check_boundaries()
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


func _check_boundaries() -> void:
	# Not WHICH way they round — only that they land on a real bucket rather
	# than out of range, and that a hair either side of one never skips a
	# direction. A skip would read on screen as the sprite snapping through a
	# pose it should have passed smoothly.
	for deg: float in BOUNDARIES:
		var lo: int = _visual.direction_bucket(deg_to_rad(deg - 0.01))
		var hi: int = _visual.direction_bucket(deg_to_rad(deg + 0.01))
		var n: int = _visual.DIRECTIONS.size()
		_check(wrapi(hi - lo, 0, n) <= 1,
			"boundary at %.0f deg steps one bucket at most (%d -> %d)" % [deg, lo, hi])


func _check_mirror() -> void:
	# Five drawn + three mirrored. Every mirror entry must point at a direction
	# that IS drawn — one aiming at another mirror entry would resolve to
	# nothing.
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
	# TWO steps without any unit having turned — the rig snaps 90 degrees and a
	# bucket is 45. That is also what makes the snap free in art terms: a whole
	# number of steps, never a fraction of one, so the eight drawn directions
	# cover all four camera positions.
	var rig = load("res://scenes/camera_rig.tscn").instantiate()
	root.add_child(rig)
	await process_frame

	# A unit facing world -Z, which is the axis a unit spawns on.
	var unit_yaw := 0.0
	var before: int = _visual.direction_bucket(unit_yaw - rig.rotation.y)
	_check(_visual.DIRECTIONS[before] == &"ne",
		"at the rig's start yaw, world -Z reads as ne (got %s)" % _visual.DIRECTIONS[before])
	rig.snap_by(1)  # instant with no display
	await process_frame
	var after: int = _visual.direction_bucket(unit_yaw - rig.rotation.y)
	# BACKWARDS two steps, not forwards: the camera turning one way is the world
	# appearing to turn the other, and direction subtracts the camera yaw. 6 is
	# -2 modulo the eight buckets. The sign is cosmetic; that it is a WHOLE
	# number of steps is not, because that is what makes the snap cost no
	# additional art.
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
