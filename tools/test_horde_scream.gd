extends SceneTree
## A horde's wake-up scream (SwarmUnit._enter_combat): one body screams for the
## whole pack, and it is the one nearest the prey, a tie broken at random.
##
##   godot --headless --path . --script res://tools/test_horde_scream.gd
##
## Headless plays no animation, so what is asserted is the PICK
## (`SwarmUnit.screamer`), on bodies that never enter the tree. Scripts are
## load()ed for the reason test_horde.gd gives.

const SWARM := "res://scenes/swarm_unit.tscn"
const PREY := Vector3i(10, 0, 10)

var _failures := 0
var _swarm_script


func _initialize() -> void:
	_swarm_script = load("res://scripts/swarm_unit.gd")

	var near = _body("near", Vector3i(8, 0, 10))
	var far = _body("far", Vector3i(4, 0, 10))
	var farther = _body("farther", Vector3i(2, 0, 2))
	var pick = _swarm_script.screamer(_pack([far, near, farther]), PREY)
	_check(pick == near, "the body nearest the prey screams (got %s)" % pick.name)
	_check(_swarm_script.screamer(_pack([far]), PREY) == far, "a lone body screams for itself")

	# Four bodies one tile off the prey on each side: every one is as near as the
	# next, so the pick must land on each of them across enough packs.
	var tied: Array = []
	for offset in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
		tied.append(_body("tied", PREY + offset))
	var picked := {}
	for i in 64:
		for body in tied:
			body.horde_id = "horde_%d" % i
		picked[_swarm_script.screamer(_pack(tied + [far]), PREY)] = true
	_check(not picked.has(far), "a tie is broken among the tied, never the far body")
	_check(picked.size() == tied.size(), "a tie is broken at random (%d of %d picked)" % [picked.size(), tied.size()])
	var again = _swarm_script.screamer(_pack(tied + [far]), PREY)
	_check(again == _swarm_script.screamer(_pack(tied + [far]), PREY), "the same pack in the same round picks the same body")

	for body in tied + [near, far, farther]:
		body.free()
	print("")
	if _failures == 0:
		print("horde scream: ALL CHECKS PASSED")
		quit(0)
	else:
		print("horde scream: %d CHECK(S) FAILED" % _failures)
		quit(1)


func _body(body_name: String, at: Vector3i):
	var body = load(SWARM).instantiate()
	body.name = body_name
	body.grid_pos = at
	return body


## A typed Array[SwarmUnit] built at run time — the type cannot be named in a
## --script tool.
func _pack(items: Array) -> Array:
	return Array(items, TYPE_OBJECT, &"Node3D", _swarm_script)


func _check(ok: bool, label: String) -> void:
	if ok:
		print("  ok    " + label)
	else:
		print("  FAIL  " + label)
		_failures += 1
