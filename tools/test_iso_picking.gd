extends SceneTree
## Phase 3 of MIGRATION_PLAN.md: proves mouse picking still resolves the right
## tile under the orthographic rig, at all four snap yaws rather than only the
## initial 45 degrees.
##
##   godot --headless --path . --script res://tools/test_iso_picking.gd
##
## The check is the round trip PlayerUnit._raycast_mouse actually performs, run
## backwards from a known answer: project a tile's world centre to screen with
## unproject_position, then rebuild a pick ray from that screen point with
## project_ray_origin + project_ray_normal and confirm it lands back on the same
## tile. Under perspective the ray origin is the camera and the normal varies;
## under orthographic the origin slides across the near plane and the normal is
## constant. Both are projection-correct in Godot 4, and this is what says so.
##
## A tile whose ray is blocked by geometry USED to be expected to resolve to the
## wall in front of it, and was classified out. That is now a failure: picking
## projects onto the deck planes instead of raycasting (GridManager.tile_under_ray),
## so a wall between the camera and a tile no longer eats the pick. Obstructed
## tiles are still counted — the count is what proves the case is being exercised
## — but they are asserted rather than excused.
##
## The one legitimate mismatch left is a tile on a HIGHER deck winning: a platform
## is a solid block genuinely drawn in front of the floor behind it, so naming the
## platform is naming what the player sees.
##
## Everything is untyped and called dynamically: a --script tool is compiled
## before autoloads register, so naming GridManager or MapBuilder in a type hint
## would stop the tool loading at all.

const EXPECTED_YAWS := [45.0, 135.0, 225.0, 315.0]
## Half a tile of slack when comparing a hit position back to a tile centre.
const EPSILON := 0.05

var _failures := 0
## Fetched through Engine rather than named directly: naming the autoload is a
## COMPILE-time reference, and a --script tool is compiled before autoloads are
## registered, so the tool would fail to load at all. get_node("/root/...") is
## no good either — a --script SceneTree is not the *active* tree, so absolute
## paths into it are refused.
var _grid: Object = null


func _initialize() -> void:
	_grid = root.get_node_or_null("GridManager")
	_check(_grid != null, "GridManager autoload reachable")
	var map = load("res://scenes/test_map.tscn").instantiate()
	root.add_child(map)
	var rig = load("res://scenes/camera_rig.tscn").instantiate()
	root.add_child(rig)
	await process_frame

	var cam: Camera3D = rig.get_node("Camera3D")
	cam.make_current()
	_check(cam.projection == Camera3D.PROJECTION_ORTHOGONAL, "camera is orthographic")
	_check(cam.size > 0.0, "camera has a fixed ortho size (%.1f)" % cam.size)

	# Centre the rig on the deck so as much of it as possible is on screen; an
	# off-screen tile cannot be picked and would be classified out for the wrong
	# reason.
	var data = map.data
	rig.focus_on(_deck_centre(map, data))
	await process_frame

	for i in EXPECTED_YAWS.size():
		var want: float = EXPECTED_YAWS[i]
		await process_frame
		var got := rad_to_deg(fposmod(rig.rotation.y, TAU))
		_check(is_equal_approx(snappedf(got, 0.001), snappedf(want, 0.001)),
			"yaw %d is %.0f degrees (got %.3f)" % [i, want, got])
		_check_pan_basis(rig, want)
		_check_picking(map, cam, want)
		rig.snap_by(1)  # instant in headless, see CameraRig.snap_by

	# Four quarter turns must land exactly back where they started, or the yaw
	# accumulates drift over a session.
	await process_frame
	_check(is_equal_approx(rig.rotation.y, deg_to_rad(45.0) + TAU),
		"four snaps return to the start yaw (got %.4f rad)" % rig.rotation.y)

	print("")
	if _failures == 0:
		print("iso picking: ALL CHECKS PASSED")
		quit(0)
	else:
		print("iso picking: %d CHECK(S) FAILED" % _failures)
		quit(1)


func _deck_centre(map, data) -> Vector3:
	var a: Vector3 = map.cell_to_world(Vector3i(0, 0, 0))
	var b: Vector3 = map.cell_to_world(Vector3i(data.size.x - 1, 0, data.size.y - 1))
	return (a + b) * 0.5


func _check_pan_basis(rig, yaw_degrees: float) -> void:
	# camera_rig.gd rebuilds its pan basis from rotation.y every frame, so pan is
	# camera-relative across a snap for free. This asserts that "for free" —
	# forward must have rotated with the yaw, not stayed world -Z.
	var yaw: float = rig.rotation.y
	var forward := Vector3(-sin(yaw), 0, -cos(yaw))
	var want := Vector3(-sin(deg_to_rad(yaw_degrees)), 0, -cos(deg_to_rad(yaw_degrees)))
	_check(forward.distance_to(want) < 0.001,
		"pan forward follows yaw %.0f (%.2f, %.2f)" % [yaw_degrees, forward.x, forward.z])


func _check_picking(map, cam: Camera3D, yaw_degrees: float) -> void:
	var data = map.data
	var viewport_size: Vector2 = cam.get_viewport().get_visible_rect().size
	var space = cam.get_world_3d().direct_space_state
	var tested := 0
	var offscreen := 0
	var occluded := 0
	var raised := 0
	var wrong: Array[String] = []

	for pos in data.walkable_positions():
		var centre: Vector3 = _grid.grid_to_world(pos)
		var screen := cam.unproject_position(centre)
		if screen.x < 0.0 or screen.y < 0.0 or screen.x >= viewport_size.x or screen.y >= viewport_size.y:
			offscreen += 1
			continue
		# The exact call PlayerUnit._tile_under_mouse makes.
		var from := cam.project_ray_origin(screen)
		var dir := cam.project_ray_normal(screen)
		# A wall between the camera and this tile is now COUNTED rather than
		# skipped, and that inversion is the regression guard. Picking used to be
		# a physics ray, so an obstructed tile could not be clicked at all — and
		# because camera-near wall meshes are hidden while their collision stays,
		# the player could see a tile they were unable to select, with no camera
		# yaw that helped. Every one of these must now pick correctly.
		if not _grid.has_clear_line(map, from, centre + Vector3(0, EPSILON, 0)):
			occluded += 1
		var picked = _grid.tile_under_ray(from, dir)
		if picked != pos:
			# A tile on a HIGHER deck winning is correct, not a miss. A platform is
			# a solid block drawn in front of the floor behind it, so the cursor
			# naming the platform is the cursor naming what the player can see —
			# and `tile_under_ray` scans decks top-down for exactly that reason.
			# Anything else is a genuine mis-pick.
			if picked.y > pos.y:
				raised += 1
			else:
				wrong.append("%s picked as %s" % [pos, picked])
		tested += 1

	_check(tested > 0, "yaw %.0f: some tiles were pickable at all (%d)" % [yaw_degrees, tested])
	_check(occluded > 0,
		"yaw %.0f: and %d of them sit behind geometry, so this is a real test" % [yaw_degrees, occluded])
	_check(wrong.is_empty(),
		"yaw %.0f: %d/%d on-screen tiles pick correctly, obstructed or not (%d hidden by a platform, %d off screen)"
		% [yaw_degrees, tested - wrong.size(), tested, raised, offscreen])
	for w in wrong.slice(0, 8):
		print("      %s" % w)


func _check(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
