extends SceneTree

var checks := 0
func _initialize() -> void:
	var size := Vector2i(5, 8)
	for mirror in [false, true]:
		for rot in 4:
			var seen := {}
			for y in size.y:
				for x in size.x:
					var p := ParcelTransform.apply(Vector2i(x, y), size, rot, mirror)
					_check(Rect2i(Vector2i.ZERO, ParcelTransform.extent(size, rot)).has_point(p), "transformed bounds")
					_check(not seen.has(p), "bijection")
					seen[p] = true
			for side in 4:
				var length := size.y if side % 2 == 0 else size.x
				var socket := Vector3i(side, 1, 2)
				var transformed := ParcelTransform.socket(socket, size, rot, mirror)
				var new_size := ParcelTransform.extent(size, rot)
				for index in range(1, 3):
					var p := ParcelTransform.apply(ParcelTransform.edge_cell(side, index, size), size, rot, mirror)
					_check(p == ParcelTransform.edge_cell(transformed.x, transformed.y, new_size) or p == ParcelTransform.edge_cell(transformed.x, transformed.y + 1, new_size), "socket endpoint")
				_check(length >= 3, "asymmetric edge")
				var wall := ParcelTransform.side(side, rot, mirror)
				var at := ParcelTransform.apply(Vector2i(2, 3), size, rot, mirror)
				var mount := ParcelTransform.wall_transform(at, wall, Vector3(0.3, 1, 0.7))
				var normal := Vector3(MapData.SIDE_STEP[wall])
				_check(is_equal_approx((mount.origin - Vector3(at.x * 1.5, 0, at.y * 1.5)).dot(normal), 0.75), "back flush")
				_check(mount.basis.z.dot(normal) < -0.999, "front away from wall")
				_check(mount.basis.determinant() > 0, "positive scale")
				_check(ParcelTransform.side(ParcelTransform.side(side, rot, false), 4 - rot, false) == side, "side round trip")
			var rect := ParcelTransform.rect(Rect2i(1, 2, 3, 2), size, rot, mirror)
			_check(rect.get_area() == 6, "footprint area")
	print("Parcel transforms: %d checks passed" % checks)
	quit()

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		push_error(message)
		quit(1)
		assert(ok, message)
