class_name Ragdoll
extends Node3D
## A unit's fall as physics: rigid bodies over the model's skeleton, pushed by
## the round that dropped it, settling into a body on the deck.
##
## PURELY VISUAL. Nothing about the fight reads it: the unit's tile, its click
## body and every line-of-sight ray are untouched, and the bodies live on their
## own collision layer (LAYER) that no game query asks about. Peers simulate it
## independently from the same replicated hit, so two screens can disagree by a
## few centimetres about where an arm landed and nothing cares.
##
## Lifecycle, driven by UnitVisual:
##   start()  the animation is paused at the current frame; bodies spawn on that
##            pose, take the hit, and from then on the skeleton follows them.
##   settle   once everything has stopped moving (SETTLE_DRIFT), or MAX_TIME runs
##            out, the bodies are freed and the last pose stays written into the
##            skeleton. A settled corpse costs nothing per frame.
##   clear()  puts everything back — the pose from before the fall, the gun in the
##            hands — for a revive or a playback rewind.
##
## Built from plain RigidBody3D + Generic6DOFJoint3D rather than PhysicalBone3D:
## the merc's armature is scaled (0.68), and physical bones under a scaled
## skeleton read their pose back without the scale. Here every body is unscaled
## world-space and the scale lives in a per-bone offset, so it cannot leak.
##
## The simulation runs in the frame of the skeleton AS IT WAS when the fall
## started, so a body carried off mid-fall (or later) takes its pose along.

signal settled

enum HitKind { NONE, BULLET, MELEE, BLAST }

## Ragdoll bodies. No game query includes it — LOS and lighting ray layer 1,
## picking layers 1/2, cover is layer 3 (value 4).
const LAYER := 1 << 9
## The per-ragdoll catch floor (see `_build_catch`), which only ragdolls touch.
const CATCH_LAYER := 1 << 10
## Walls/ground/platforms (1), cover blocks (4), other ragdolls, the catch floor.
const MASK := 1 | 4 | LAYER | CATCH_LAYER

## Half-width of the catch floor: a body stays within about a tile of where it
## fell even at a ledge, because the game still has it on its own tile.
const CATCH_HALF := 1.5

## A round's push, N·s: the SAME for every round wherever it lands, applied
## where it enters along the line it travelled (`_strike`) — so a light head
## or arm whips where the heavy chest only rocks, and a hit off the centre line
## turns the body as well as pushing it. Well above a real round's momentum
## (a few N·s), which would barely show; well below enough to throw a body —
## a person shot falls, they do not fly.
const BULLET_IMPULSE := 30.0
## A swing lands heavier and slower than a round.
const MELEE_IMPULSE := 40.0
## Ceiling on the velocity one hit may give the part it lands on, m/s: what
## keeps a round into a 2 kg forearm a snap rather than a flail.
const MAX_PART_DV := 3.5
## The collapse the killing hit sets going, m/s, into the upper body (spine up)
## with the pelvis taking PELVIS_SHARE of it and the legs none: the body pivots
## over its planted feet and goes over the way the round was travelling. Not
## the round's own momentum — the legs giving way under a body that is being
## driven backwards.
const BULLET_BODY_DV := 1.5
const MELEE_BODY_DV := 1.8
const PELVIS_SHARE := 0.35
## Every round of the burst AFTER the one that dropped the body (`add_round`)
## is a full BULLET_IMPULSE of its own, plus this much more lean into the upper
## body. Added to the fall, not replacing it — the body jerks with each hit as
## it goes down.
const ROUND_BODY_DV := 0.15
## Where a follow-up round strikes, as Combat.BodyPart weights: mostly centre
## mass, which is where a burst walks.
const ROUND_PARTS := [[1, 0.6], [0, 0.08], [2, 0.08], [3, 0.08], [4, 0.08], [5, 0.08]]
## Ceiling on how fast the body AS A WHOLE (its centre of mass) may be going
## sideways after a round or a swing lands, m/s. Just above what one killing
## shot gives it, so a single shot is untouched; it is what stops a long burst
## stacking into a slide across the room while each round still snaps the part
## it strikes.
const MAX_SHOVE := 1.3
## A blast pushes every part away from the centre, and up.
const BLAST_DV := 2.6
const BLAST_LIFT := 1.2
## No shot at all (a bleed-out, a scripted death): a nudge, so a body standing
## balanced on straight legs does not stay standing.
const NONE_DV := 0.25

## Muscle tone: each tick, every joint gives up this fraction of the spin
## between its two parts (times the joint's own `tone` in RIGS) — a damper on
## the joint, done by hand because Godot Physics ignores 6DOF angular motors.
## Starts firm and fades to TONE_END over TONE_FADE: the body goes over as one
## piece while the knees give, rather than folding straight down like a puppet
## with its strings cut — and once down, nothing flails.
const TONE_START := 0.35
const TONE_END := 0.04
const TONE_FADE := 0.9
## Tuning hook for tools/ragdoll_lab.gd: scales TONE_START.
static var tone_scale := 1.0
## Damping on every body, on top of the joint tone.
const LINEAR_DAMP := 0.05
const ANGULAR_DAMP := 1.5
const FRICTION := 0.9

## Settled once no body has moved more than SETTLE_DRIFT metres across
## SETTLE_WINDOWS consecutive windows of SETTLE_WINDOW seconds. Measured on
## position rather than speed: a resting body under Godot Physics keeps a faint
## joint tremble whose speed never quite reaches zero, and freezing it is
## exactly what settling is for.
const SETTLE_DRIFT := 0.012
const SETTLE_WINDOW := 0.25
const SETTLE_WINDOWS := 2
const MIN_TIME := 0.8
const MAX_TIME := 6.0

## How many ragdolls may simulate at once. One more falls back to the animated
## collapse (UnitVisual) — a grenade into a crowd should not stall a frame.
const MAX_ACTIVE := 8
static var active_count := 0

## The rigs this knows how to ragdoll, tried in order (`profile_for`).
##
##   root    the pelvis bone; also how the rig is recognised, with any name
##           prefix in front of it (Mixamo exports vary: "mixamorig:", "mixamorig5_")
##   legs    bones a shot's push skips — their feet are on the deck
##   follow  follower -> the driven bone it keeps its offset to, for a bone that
##           is not that bone's child in the hierarchy
##   parts   Combat.BodyPart -> bones a round to that part may strike
##
## Per body:
##   bone      the bone it drives
##   mass      kg
##   shapes    in the body's own frame (the bone's rest axes, unscaled):
##               capsule  a -> b (bone heads), `extend` past b, radius `r`
##               box      centred on bone a's head + `offset`; `size`
##               sphere   centred on bone a's head + `offset`; radius `r`
##   tone      how firmly the joint holds at first (see TONE_START)
##   limits    joint to the nearest driven ancestor, in degrees per bone axis,
##             relative to the REST pose: [x_lo, x_hi, y_lo, y_hi, z_lo, z_hi].
##             Y runs along the bone on both rigs; which of X/Z is the bend
##             differs per limb and is noted on each rig.
const RIGS := [
	## The exported merc/soldier skeleton (tools/export_models.py). X is the bend
	## for every joint, Z the sideways swing. Hands and feet are parented to IK
	## bones rather than to the forearm and shin, so they ride as followers.
	{
		"root": "hip",
		"legs": ["leg.L", "shin.L", "leg.R", "shin.R"],
		"bodies": [
			{"bone": "hip", "mass": 12.0, "shapes": [
				{"type": "box", "a": "hip", "size": Vector3(0.30, 0.25, 0.22), "offset": Vector3(0, 0.04, 0)}]},
			{"bone": "spine_1", "mass": 9.0, "tone": 1.0, "limits": [-20, 22, -20, 20, -15, 15], "shapes": [
				{"type": "box", "a": "spine_1", "size": Vector3(0.30, 0.24, 0.20), "offset": Vector3(0, 0.12, 0)}]},
			{"bone": "chest", "mass": 15.0, "tone": 1.0, "limits": [-20, 28, -20, 20, -15, 15], "shapes": [
				{"type": "box", "a": "chest", "size": Vector3(0.36, 0.26, 0.24), "offset": Vector3(0, 0.12, 0)}]},
			{"bone": "head", "mass": 5.0, "tone": 0.6, "limits": [-45, 45, -75, 75, -55, 55], "shapes": [
				{"type": "sphere", "a": "head", "r": 0.12, "offset": Vector3(0, 0.11, 0)}]},
			{"bone": "arm.L", "mass": 2.5, "tone": 0.35, "limits": [-40, 100, -60, 60, -95, 50], "shapes": [
				{"type": "capsule", "a": "arm.L", "b": "forearm.L", "r": 0.05}]},
			{"bone": "forearm.L", "mass": 2.0, "tone": 0.3, "limits": [0, 145, -60, 60, -30, 30], "shapes": [
				{"type": "capsule", "a": "forearm.L", "b": "hand.L", "extend": 0.09, "r": 0.045}]},
			{"bone": "arm.R", "mass": 2.5, "tone": 0.35, "limits": [-40, 100, -60, 60, -50, 95], "shapes": [
				{"type": "capsule", "a": "arm.R", "b": "forearm.R", "r": 0.05}]},
			{"bone": "forearm.R", "mass": 2.0, "tone": 0.3, "limits": [0, 145, -60, 60, -30, 30], "shapes": [
				{"type": "capsule", "a": "forearm.R", "b": "hand.R", "extend": 0.09, "r": 0.045}]},
			{"bone": "leg.L", "mass": 9.0, "tone": 0.8, "limits": [-25, 85, -25, 25, -15, 40], "shapes": [
				{"type": "capsule", "a": "leg.L", "b": "shin.L", "r": 0.075}]},
			{"bone": "shin.L", "mass": 5.0, "tone": 1.0, "limits": [-130, 3, -8, 8, -8, 8], "shapes": [
				{"type": "capsule", "a": "shin.L", "b": "foot.L", "r": 0.055},
				{"type": "box", "a": "foot.L", "size": Vector3(0.10, 0.08, 0.22), "offset": Vector3(0, 0.03, 0.05)}]},
			{"bone": "leg.R", "mass": 9.0, "tone": 0.8, "limits": [-25, 85, -25, 25, -40, 15], "shapes": [
				{"type": "capsule", "a": "leg.R", "b": "shin.R", "r": 0.075}]},
			{"bone": "shin.R", "mass": 5.0, "tone": 1.0, "limits": [-130, 3, -8, 8, -8, 8], "shapes": [
				{"type": "capsule", "a": "shin.R", "b": "foot.R", "r": 0.055},
				{"type": "box", "a": "foot.R", "size": Vector3(0.10, 0.08, 0.22), "offset": Vector3(0, 0.03, 0.05)}]},
		],
		"follow": {"hand.L": "forearm.L", "hand.R": "forearm.R", "foot.L": "shin.L", "foot.R": "shin.R"},
		"parts": {0: ["head"], 1: ["chest", "chest", "spine_1"], 2: ["arm.L", "forearm.L"],
			3: ["arm.R", "forearm.R"], 4: ["leg.L", "shin.L"], 5: ["leg.R", "shin.R"]},
	},
	## Mixamo (the Fodder zombie, the civilian). Spine, neck and legs bend on X as
	## above, Z the sideways swing. The arms are turned a quarter: on an upper arm
	## X lowers it to the side and Z swings it forward, and the elbow bends on Z
	## (positive on the left, negative on the right). Hands and feet are plain
	## children, so nothing follows.
	{
		"root": "Hips",
		"legs": ["LeftUpLeg", "LeftLeg", "RightUpLeg", "RightLeg"],
		"bodies": [
			{"bone": "Hips", "mass": 12.0, "shapes": [
				{"type": "box", "a": "Hips", "size": Vector3(0.30, 0.22, 0.20), "offset": Vector3(0, -0.02, 0)}]},
			{"bone": "Spine", "mass": 9.0, "tone": 1.0, "limits": [-20, 22, -20, 20, -15, 15], "shapes": [
				{"type": "box", "a": "Spine", "size": Vector3(0.30, 0.22, 0.20), "offset": Vector3(0, 0.11, 0)}]},
			{"bone": "Spine2", "mass": 15.0, "tone": 1.0, "limits": [-25, 38, -25, 25, -20, 20], "shapes": [
				{"type": "box", "a": "Spine2", "size": Vector3(0.36, 0.22, 0.22), "offset": Vector3(0, 0.09, 0)}]},
			{"bone": "Head", "mass": 5.0, "tone": 0.6, "limits": [-45, 45, -75, 75, -55, 55], "shapes": [
				{"type": "sphere", "a": "Head", "r": 0.11, "offset": Vector3(0, 0.09, 0)}]},
			{"bone": "LeftArm", "mass": 2.5, "tone": 0.35, "limits": [-50, 95, -60, 60, -40, 100], "shapes": [
				{"type": "capsule", "a": "LeftArm", "b": "LeftForeArm", "r": 0.05}]},
			{"bone": "LeftForeArm", "mass": 2.0, "tone": 0.3, "limits": [-30, 30, -60, 60, 0, 145], "shapes": [
				{"type": "capsule", "a": "LeftForeArm", "b": "LeftHand", "extend": 0.12, "r": 0.045}]},
			{"bone": "RightArm", "mass": 2.5, "tone": 0.35, "limits": [-50, 95, -60, 60, -100, 40], "shapes": [
				{"type": "capsule", "a": "RightArm", "b": "RightForeArm", "r": 0.05}]},
			{"bone": "RightForeArm", "mass": 2.0, "tone": 0.3, "limits": [-30, 30, -60, 60, -145, 0], "shapes": [
				{"type": "capsule", "a": "RightForeArm", "b": "RightHand", "extend": 0.12, "r": 0.045}]},
			{"bone": "LeftUpLeg", "mass": 9.0, "tone": 0.8, "limits": [-25, 85, -25, 25, -15, 40], "shapes": [
				{"type": "capsule", "a": "LeftUpLeg", "b": "LeftLeg", "r": 0.075}]},
			{"bone": "LeftLeg", "mass": 5.0, "tone": 1.0, "limits": [-130, 3, -8, 8, -8, 8], "shapes": [
				{"type": "capsule", "a": "LeftLeg", "b": "LeftFoot", "r": 0.055},
				{"type": "box", "a": "LeftFoot", "size": Vector3(0.10, 0.08, 0.24), "offset": Vector3(0, 0.07, 0.06)}]},
			{"bone": "RightUpLeg", "mass": 9.0, "tone": 0.8, "limits": [-25, 85, -25, 25, -40, 15], "shapes": [
				{"type": "capsule", "a": "RightUpLeg", "b": "RightLeg", "r": 0.075}]},
			{"bone": "RightLeg", "mass": 5.0, "tone": 1.0, "limits": [-130, 3, -8, 8, -8, 8], "shapes": [
				{"type": "capsule", "a": "RightLeg", "b": "RightFoot", "r": 0.055},
				{"type": "box", "a": "RightFoot", "size": Vector3(0.10, 0.08, 0.24), "offset": Vector3(0, 0.07, 0.06)}]},
		],
		"follow": {},
		"parts": {0: ["Head"], 1: ["Spine2", "Spine2", "Spine"], 2: ["LeftArm", "LeftForeArm"],
			3: ["RightArm", "RightForeArm"], 4: ["LeftUpLeg", "LeftLeg"], 5: ["RightUpLeg", "RightLeg"]},
		## Fodder dismemberment (FodderGibs): GibPlanner part -> the bone whose
		## whole subtree comes off, and the stump's radius there, metres. A rig
		## with no "gib" block never gibs.
		"gib": {
			"head": {"bone": "Head", "stump": 0.065},
			"arm_l": {"bone": "LeftArm", "stump": 0.05},
			"arm_r": {"bone": "RightArm", "stump": 0.05},
			"leg_l": {"bone": "LeftUpLeg", "stump": 0.07},
			"leg_r": {"bone": "RightUpLeg", "stump": 0.07},
		},
	},
]


## The rig `skeleton` matches, as {"rig": <entry of RIGS>, "prefix": <bone-name
## prefix>}, or {} when this cannot ragdoll it.
static func profile_for(skeleton: Skeleton3D) -> Dictionary:
	if skeleton == null:
		return {}
	for rig: Dictionary in RIGS:
		var root: String = rig.root
		for i in skeleton.get_bone_count():
			var name := skeleton.get_bone_name(i)
			if not name.ends_with(root):
				continue
			var prefix := name.left(name.length() - root.length())
			if _has_all(skeleton, rig, prefix):
				return {"rig": rig, "prefix": prefix}
	return {}


static func _has_all(skeleton: Skeleton3D, rig: Dictionary, prefix: String) -> bool:
	for spec: Dictionary in rig.bodies:
		if skeleton.find_bone(prefix + String(spec.bone)) < 0:
			return false
	for f: String in rig.follow:
		if skeleton.find_bone(prefix + f) < 0 or skeleton.find_bone(prefix + String(rig.follow[f])) < 0:
			return false
	return true


## Whether `skeleton` is a rig this can ragdoll.
static func supports(skeleton: Skeleton3D) -> bool:
	return not profile_for(skeleton).is_empty()


## The parts `skeleton` can lose (RIGS "gib"), as part -> {bone: index, stump:
## radius}; {} for a rig that never gibs.
static func gib_parts(skeleton: Skeleton3D) -> Dictionary:
	var profile := profile_for(skeleton)
	if profile.is_empty() or not profile.rig.has("gib"):
		return {}
	var out := {}
	for part: String in profile.rig.gib:
		var spec: Dictionary = profile.rig.gib[part]
		var bi := skeleton.find_bone(profile.prefix + String(spec.bone))
		if bi >= 0:
			out[StringName(part)] = {"bone": bi, "stump": float(spec.stump)}
	return out


## `root` and every bone under it.
static func subtree(skeleton: Skeleton3D, root: int) -> PackedInt32Array:
	var out := PackedInt32Array([root])
	var i := 0
	while i < out.size():
		out.append_array(skeleton.get_bone_children(out[i]))
		i += 1
	return out


## The scale a severed part's root bone is drawn at: everything under it folds
## into its head. Not zero, so nothing downstream inverts a singular basis.
const SEVERED_SCALE := Vector3.ONE * 1e-4


var _rig: Dictionary = {}
var _prefix := ""

var _skel: Skeleton3D = null
## The skeleton's global transform when the fall began, and its inverse — the
## frame the whole simulation is expressed in (see the class comment).
var _s0 := Transform3D.IDENTITY
var _s0inv := Transform3D.IDENTITY
## bone index -> RigidBody3D
var _bodies: Dictionary = {}
## bone index -> body-space offset to the bone (carries the armature's scale)
var _offset: Dictionary = {}
## follower bone index -> [target bone index, offset from target]
var _follow: Dictionary = {}
## Every bone's local pose before the fall, for `clear`.
var _pose0: Dictionary = {}
var _parents: PackedInt32Array = PackedInt32Array()
## bone index -> the body's rest frame, which the joint zero was taken from.
var _rest_frame: Dictionary = {}
## child bone index -> [parent bone index, RIGS limits]
var _joint_of: Dictionary = {}
var _catch: StaticBody3D = null
var _joints: Array[Joint3D] = []
## [child body, parent body, tone weight] per joint — see `_apply_tone`.
var _tones: Array = []

var _gun: Node3D = null
var _gun_parent: Node = null
var _gun_local := Transform3D.IDENTITY
var _gun_body: RigidBody3D = null
## Where the settled gun goes: a node that moves with the unit.
var _anchor: Node3D = null

## Hits waiting for the first physics tick (see `start`), and rounds that
## arrive between ticks.
var _pending: Array = []
var _round_rng := RandomNumberGenerator.new()
var _time := 0.0
var _still := 0
var _window := 0.0
var _marks: Array[Vector3] = []
var _simulating := false
var _counted := false


## Starts the fall. `hit` is the replicated hit record (Unit.hit_record):
##   kind  HitKind     from  Vector3, where the attack came from (world)
##   part  Combat.BodyPart or -1      seed  int, for the small random choices
## `gun` is the node holding the weapon model (dropped as its own body, or
## left alone when null); `anchor` is where it is parked once it settles.
## `floor_y` is the deck height the unit stands on. `severed` holds the root
## bone indices of parts that came off (FodderGibs): no body is built anywhere
## in their subtrees — no invisible colliders — and each root is drawn folded
## away (SEVERED_SCALE). `clear` puts them back with the rest of the pose.
func start(skeleton: Skeleton3D, hit: Dictionary, floor_y: float,
		gun: Node3D = null, anchor: Node3D = null, severed: PackedInt32Array = PackedInt32Array()) -> void:
	_skel = skeleton
	var profile := profile_for(skeleton)
	_rig = profile.rig
	_prefix = profile.prefix
	_anchor = anchor
	_s0 = skeleton.global_transform
	_s0inv = _s0.affine_inverse()
	var count := skeleton.get_bone_count()
	_parents.resize(count)
	for i in count:
		_parents[i] = skeleton.get_bone_parent(i)
		_pose0[i] = skeleton.get_bone_pose(i)

	# Rest and current pose of every bone, world space.
	var rest_g: Array[Transform3D] = []
	var pose_g: Array[Transform3D] = []
	rest_g.resize(count)
	pose_g.resize(count)
	for i in count:
		rest_g[i] = _s0 * skeleton.get_bone_global_rest(i)
		pose_g[i] = _s0 * skeleton.get_bone_global_pose(i)

	for f: String in _rig.follow:
		var fi := _bone(f)
		var ti := _bone(_rig.follow[f])
		_follow[fi] = [ti, skeleton.get_bone_global_pose(ti).affine_inverse() \
			* skeleton.get_bone_global_pose(fi)]

	var gone := {}
	for root_bi in severed:
		for bi in subtree(skeleton, root_bi):
			gone[bi] = true
	for fi: int in _follow.keys():
		if gone.has(fi) or gone.has(int(_follow[fi][0])):
			_follow.erase(fi)

	# Bodies, built on the REST pose: the joints take their zero from where the
	# bodies are when the joint is made, and the limits are written against the
	# rest pose (a straight leg, a T-pose arm). Moved onto the current pose after.
	for spec: Dictionary in _rig.bodies:
		var bi := _bone(spec.bone)
		if gone.has(bi):
			continue
		var body := _make_body(spec, bi, rest_g)
		_bodies[bi] = body
		_rest_frame[bi] = body.global_transform
	for spec: Dictionary in _rig.bodies:
		var bi := _bone(spec.bone)
		if spec.has("limits") and _bodies.has(bi):
			_make_joint(spec, bi, _driven_ancestor(bi))
	# After `_pose0` was taken, so `clear` restores the scale too. Nothing drives
	# these bones from here on (they have no bodies), so the fold stays put.
	for root_bi in severed:
		skeleton.set_bone_pose_scale(root_bi, SEVERED_SCALE)
	# Overlapping pairs never collide with each other, or the solver's first act
	# is to blow them apart — checked on the rest pose AND the pose the body falls
	# from (hands meet on a rifle, in front of the chest).
	var list := _bodies.values()
	var skip: Dictionary = {}
	_mark_touching(list, skip)
	for bi: int in _bodies:
		var body: RigidBody3D = _bodies[bi]
		var b := _ortho(pose_g[bi])
		body.global_transform = b
		_offset[bi] = b.affine_inverse() * pose_g[bi]
	_mark_touching(list, skip)

	_build_catch(floor_y)
	if gun != null:
		_drop_gun(gun)
	# Not applied yet: a body's mass and inertia reach the physics server on its
	# first step, and an impulse before that lands on the 1 kg default — ten
	# times too hard on a 15 kg chest. `_physics_process` applies it after one tick.
	_pending.append(hit)
	_round_rng.seed = int(hit.get("seed", 0)) + 1
	_simulating = true
	_counted = true
	active_count += 1


## Undoes the fall: the pre-fall pose, the gun back in the hands, every body
## gone. The node frees itself.
func clear() -> void:
	_finish_bodies()
	if _gun != null and is_instance_valid(_gun) and _gun_parent != null \
			and is_instance_valid(_gun_parent):
		_gun.reparent(_gun_parent, false)
		_gun.transform = _gun_local
	if _skel != null and is_instance_valid(_skel):
		for i: int in _pose0:
			_skel.set_bone_pose(i, _pose0[i])
	queue_free()


## Each joint's current angles against its RIGS limits, degrees, as the joint
## itself measures them (sign-corrected back to RIGS' convention). A pose
## outside its limits at the start is a body the solver will snap — the main
## source of a ragdoll that leaps. For tools/ragdoll_lab.gd.
func debug_joint_angles() -> String:
	var out := ""
	for bi: int in _joint_of:
		var pi: int = _joint_of[bi][0]
		var lim: Array = _joint_of[bi][1]
		var a: Transform3D = (_bodies[pi] as RigidBody3D).global_transform
		var b: Transform3D = (_bodies[bi] as RigidBody3D).global_transform
		var rel: Basis = (b.basis.inverse() * a.basis) * ((_rest_frame[pi] as Transform3D).basis.inverse() * (_rest_frame[bi] as Transform3D).basis)
		var e := -rel.get_euler(EULER_ORDER_XYZ) * (180.0 / PI)
		var bad := ""
		for k in 3:
			if e[k] < float(lim[k * 2]) - 1.0 or e[k] > float(lim[k * 2 + 1]) + 1.0:
				bad += "xyz"[k]
		out += "  %s (%.0f, %.0f, %.0f)%s
" % [_skel.get_bone_name(bi), e.x, e.y, e.z,
			("  OUT " + bad) if bad != "" else ""]
	return out


## Another round of the burst striking the falling body (UnitVisual.take_round).
## `part` is Combat.BodyPart, or -1 to strike where rounds go (ROUND_PARTS).
func add_round(from: Vector3, part: int = -1) -> void:
	if not _simulating:
		return
	if part < 0:
		var r := _round_rng.randf()
		for w: Array in ROUND_PARTS:
			r -= float(w[1])
			if r <= 0.0:
				part = int(w[0])
				break
		if part < 0:
			part = 1  # Combat.BodyPart.TORSO; by value, so Ragdoll compiles alone
	_pending.append({"kind": HitKind.BULLET, "from": from, "part": part,
		"seed": _round_rng.randi(), "round": true})


func is_simulating() -> bool:
	return _simulating


## The live bodies, for FodderGibs to keep its parts from colliding with the
## body they came off.
func bodies() -> Array:
	return _bodies.values()


func _exit_tree() -> void:
	_release_count()


func _release_count() -> void:
	if _counted:
		_counted = false
		active_count = maxi(active_count - 1, 0)


# --- Construction --------------------------------------------------------------


func _make_body(spec: Dictionary, bi: int, rest_g: Array[Transform3D]) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.name = "rb_" + String(spec.bone).replace(".", "_")
	body.top_level = true
	body.mass = spec.mass
	body.collision_layer = LAYER
	body.collision_mask = MASK
	body.linear_damp = LINEAR_DAMP
	body.angular_damp = ANGULAR_DAMP
	var mat := PhysicsMaterial.new()
	mat.friction = FRICTION
	mat.bounce = 0.0
	body.physics_material_override = mat
	var frame := _ortho(rest_g[bi])
	var inv := frame.affine_inverse()
	for s: Dictionary in spec.shapes:
		var cs := CollisionShape3D.new()
		var a := rest_g[_bone(s.a)].origin
		match s.type:
			"capsule":
				var b := rest_g[_bone(s.b)].origin
				b += (b - a).normalized() * float(s.get("extend", 0.0))
				var la := inv * a
				var lb := inv * b
				var cap := CapsuleShape3D.new()
				cap.radius = s.r
				cap.height = la.distance_to(lb) + 2.0 * float(s.r)
				cs.shape = cap
				cs.transform = Transform3D(_basis_along(lb - la), (la + lb) * 0.5)
			"box":
				var box := BoxShape3D.new()
				box.size = s.size
				cs.shape = box
				cs.position = inv * a + Vector3(s.offset)
			"sphere":
				var sph := SphereShape3D.new()
				sph.radius = s.r
				cs.shape = sph
				cs.position = inv * a + Vector3(s.offset)
		body.add_child(cs)
	add_child(body)
	body.global_transform = frame
	return body


func _make_joint(spec: Dictionary, bi: int, parent_bi: int) -> void:
	if parent_bi < 0:
		return
	var child: RigidBody3D = _bodies[bi]
	var parent: RigidBody3D = _bodies[parent_bi]
	var j := Generic6DOFJoint3D.new()
	j.name = "j_" + String(spec.bone).replace(".", "_")
	j.top_level = true
	add_child(j)
	# Pivot on the child's bone head, axes the child's own rest axes, so the
	# limits read in that bone's frame (see RIGS).
	j.global_transform = child.global_transform
	var lim: Array = spec.limits
	_tones.append([child, parent, float(spec.get("tone", 1.0))])
	for axis in 3:
		# The 6DOF joint measures the PARENT's turn relative to the child (Godot's
		# calculateAngleInfo: B⁻¹·A), the reverse of how RIGS writes them — so a
		# knee that bends -140° from rest reads as +140° to the joint.
		var lo := -deg_to_rad(float(lim[axis * 2 + 1]))
		var hi := -deg_to_rad(float(lim[axis * 2]))
		_joint_axis(j, axis, lo, hi)
	_joint_of[bi] = [parent_bi, lim]
	j.node_a = parent.get_path()
	j.node_b = child.get_path()
	_joints.append(j)


func _joint_axis(j: Generic6DOFJoint3D, axis: int, lo: float, hi: float) -> void:
	match axis:
		0:
			j.set_flag_x(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT, true)
			j.set_param_x(Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT, lo)
			j.set_param_x(Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT, hi)
		1:
			j.set_flag_y(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT, true)
			j.set_param_y(Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT, lo)
			j.set_param_y(Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT, hi)
		2:
			j.set_flag_z(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT, true)
			j.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT, lo)
			j.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT, hi)


func _driven_ancestor(bi: int) -> int:
	var p := _parents[bi]
	while p >= 0 and not _bodies.has(p):
		p = _parents[p]
	return p


func _mark_touching(list: Array, skip: Dictionary) -> void:
	for i in list.size():
		for j in range(i + 1, list.size()):
			var key := Vector2i(i, j)
			if not skip.has(key) and _touching(list[i], list[j]):
				skip[key] = true
				(list[i] as RigidBody3D).add_collision_exception_with(list[j])


## Whether two bodies overlap where they are. By bounding spheres, which errs
## toward ignoring a pair.
func _touching(a: RigidBody3D, b: RigidBody3D) -> bool:
	for sa: CollisionShape3D in a.get_children().filter(func(n: Node) -> bool: return n is CollisionShape3D):
		for sb: CollisionShape3D in b.get_children().filter(func(n: Node) -> bool: return n is CollisionShape3D):
			var pa := a.global_transform * sa.position
			var pb := b.global_transform * sb.position
			if pa.distance_to(pb) < _bound(sa.shape) + _bound(sb.shape) + 0.02:
				return true
	return false


static func _bound(shape: Shape3D) -> float:
	if shape is CapsuleShape3D:
		return (shape as CapsuleShape3D).height * 0.5
	if shape is BoxShape3D:
		return (shape as BoxShape3D).size.length() * 0.5
	if shape is SphereShape3D:
		return (shape as SphereShape3D).radius
	return 0.5


## A floor under the fall that only ragdolls touch, flush with the deck: keeps a
## body that drops at a ledge on (about) its own tile, which is where the game
## still has it, and is a floor at all on any deck without ground collision.
func _build_catch(floor_y: float) -> void:
	_catch = StaticBody3D.new()
	_catch.name = "catch"
	_catch.top_level = true
	_catch.collision_layer = CATCH_LAYER
	_catch.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(CATCH_HALF * 2.0, 0.4, CATCH_HALF * 2.0)
	cs.shape = box
	_catch.add_child(cs)
	add_child(_catch)
	_catch.global_position = Vector3(_s0.origin.x, floor_y - 0.2, _s0.origin.z)


## The gun leaves the hands: its node goes onto a body of its own, falls, and
## once settled is parked on `_anchor` so it moves with the corpse.
func _drop_gun(gun: Node3D) -> void:
	_gun = gun
	_gun_parent = gun.get_parent()
	_gun_local = gun.transform
	var aabb := _world_aabb(gun)
	if aabb.size.length() < 0.05:
		return  # nothing drawn to drop
	_gun_body = RigidBody3D.new()
	_gun_body.name = "rb_gun"
	_gun_body.top_level = true
	_gun_body.mass = 3.5
	_gun_body.collision_layer = 0
	_gun_body.collision_mask = 1 | 4 | CATCH_LAYER
	_gun_body.angular_damp = 1.0
	var mat := PhysicsMaterial.new()
	mat.friction = 0.8
	mat.bounce = 0.05
	_gun_body.physics_material_override = mat
	add_child(_gun_body)
	_gun_body.global_transform = Transform3D(Basis.IDENTITY, aabb.get_center())
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	# World-axis box around the gun as it is held. Crude, but a dropped rifle is
	# small on screen and only has to land on the floor rather than in it.
	box.size = aabb.size.max(Vector3.ONE * 0.04)
	cs.shape = box
	_gun_body.add_child(cs)
	gun.reparent(_gun_body, true)


func _world_aabb(root: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if not mi.is_visible_in_tree() or mi.mesh == null:
			continue
		var box := mi.global_transform * mi.get_aabb()
		if first:
			out = box
			first = false
		else:
			out = out.merge(box)
	return out


# --- The hit ---------------------------------------------------------------------


func _apply_hit(hit: Dictionary) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(hit.get("seed", 0))
	var kind: int = int(hit.get("kind", HitKind.NONE))
	var from: Vector3 = hit.get("from", Vector3.ZERO)
	var pelvis: RigidBody3D = _bodies[_bone(_rig.root)]
	var dir := pelvis.global_position - from
	dir.y = 0.0
	if kind == HitKind.NONE or dir.length() < 0.01:
		var a := rng.randf() * TAU
		dir = Vector3(cos(a), 0, sin(a))
	dir = dir.normalized()
	match kind:
		HitKind.BULLET, HitKind.MELEE:
			var follow_up: bool = hit.get("round", false)
			var body_dv := BULLET_BODY_DV if kind == HitKind.BULLET else MELEE_BODY_DV
			if follow_up:
				body_dv = ROUND_BODY_DV
			for bi: int in _bodies:
				var b := _bodies[bi] as RigidBody3D
				var push := dir * body_dv * _upper_share(bi)
				# The first hit sets the fall going; a follow-up round adds to it.
				b.linear_velocity = b.linear_velocity + push if follow_up else push
			_strike(_struck_body(int(hit.get("part", 1)), rng), from,
				BULLET_IMPULSE if kind == HitKind.BULLET else MELEE_IMPULSE, rng)
			_cap_shove()
			# A body dropped mid-run keeps its run (Unit reaction fire). After the
			# cap, which holds the SHOT's shove, not momentum the body already had.
			var carry: Vector3 = hit.get("carry", Vector3.ZERO)
			if not follow_up and carry != Vector3.ZERO:
				for b: RigidBody3D in _bodies.values():
					b.linear_velocity += Vector3(carry.x, 0.0, carry.z)
		HitKind.BLAST:
			for b: RigidBody3D in _bodies.values():
				var away := b.global_position - from
				var falloff := clampf(1.0 - away.length() / 4.0, 0.25, 1.0)
				away.y = maxf(away.y, 0.0)
				b.linear_velocity = away.normalized() * BLAST_DV * falloff \
					+ Vector3.UP * BLAST_LIFT * falloff
		_:
			for b: RigidBody3D in _bodies.values():
				b.linear_velocity = dir * NONE_DV
	if _gun_body != null and not hit.get("round", false):
		_gun_body.linear_velocity = dir * 0.4 + Vector3(0, 0.3, 0)
		_gun_body.angular_velocity = Vector3(rng.randf_range(-2, 2), rng.randf_range(-1, 1),
			rng.randf_range(-2, 2))


## One round (or swing) into the body, the way a round goes in: aimed at a spot
## on `aimed`'s shape, traced along the line from `from` through it, and pushed
## where that line first enters ANY part of this body — an arm across the chest
## takes the round meant for the chest — along the line it travelled, dip and
## all. Off the part's centre, so the push turns it as well as moving it.
func _strike(aimed: RigidBody3D, from: Vector3, impulse: float, rng: RandomNumberGenerator) -> void:
	var aim := _aim_point(aimed, rng)
	var line := aim - from
	if line.length() < 0.01:
		line = aimed.global_position - from
	var bdir := line.normalized()
	var body := aimed
	var entry := aim
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	if space != null:
		# From a little way out along the line rather than from the muzzle: only
		# this body's last stretch matters, and starting at the muzzle would let a
		# corpse or another falling body in between take it.
		var q := PhysicsRayQueryParameters3D.create(aim - bdir * 0.9, aim + bdir * 0.4, LAYER)
		var res := space.intersect_ray(q)
		if not res.is_empty() and res.collider is RigidBody3D and _bodies.values().has(res.collider):
			body = res.collider
			entry = res.position
	var j := minf(impulse, body.mass * MAX_PART_DV)
	body.apply_impulse(bdir * j, entry - body.global_position)


## A spot somewhere on `body`'s main shape, not its centre: within 60% of the
## shape's reach from its middle, so rounds land spread over the part.
func _aim_point(body: RigidBody3D, rng: RandomNumberGenerator) -> Vector3:
	for c in body.get_children():
		var cs := c as CollisionShape3D
		if cs == null:
			continue
		var reach := Vector3.ONE * 0.05
		if cs.shape is CapsuleShape3D:
			var cap := cs.shape as CapsuleShape3D
			reach = Vector3(cap.radius, cap.height * 0.5 - cap.radius, cap.radius)
		elif cs.shape is BoxShape3D:
			reach = (cs.shape as BoxShape3D).size * 0.5
		elif cs.shape is SphereShape3D:
			reach = Vector3.ONE * (cs.shape as SphereShape3D).radius
		var local := Vector3(rng.randf_range(-1, 1) * reach.x, rng.randf_range(-1, 1) * reach.y,
			rng.randf_range(-1, 1) * reach.z) * 0.6
		return cs.global_transform * local
	return body.global_position


## Holds the centre of mass to MAX_SHOVE sideways, taking the excess off every
## part alike so their motion relative to each other — the jolt — survives.
## Runs on velocities only: an impulse just applied has already reached them.
func _cap_shove() -> void:
	var momentum := Vector3.ZERO
	var mass := 0.0
	for b: RigidBody3D in _bodies.values():
		momentum += b.linear_velocity * b.mass
		mass += b.mass
	var com := momentum / maxf(mass, 0.001)
	com.y = 0.0
	var speed := com.length()
	if speed <= MAX_SHOVE:
		return
	var excess := com * (1.0 - MAX_SHOVE / speed)
	for b: RigidBody3D in _bodies.values():
		b.linear_velocity -= excess


## How much of the shot's push a body takes: the upper body all of it, the
## pelvis PELVIS_SHARE, the legs none (their feet are on the deck).
func _upper_share(bi: int) -> float:
	var name := _skel.get_bone_name(bi).trim_prefix(_prefix)
	if name == _rig.root:
		return PELVIS_SHARE
	if name in _rig.legs:
		return 0.0
	return 1.0


func _struck_body(part: int, rng: RandomNumberGenerator) -> RigidBody3D:
	var names: Array = _rig.parts.get(part, _rig.parts[1])
	var name: String = names[rng.randi() % names.size()]
	# A part that came off (FodderGibs) has no body: the round goes into the
	# torso instead.
	var bi := _bone(name)
	if not _bodies.has(bi):
		bi = _bone(String(_rig.parts[1][0]))
	if not _bodies.has(bi):
		bi = _bone(_rig.root)
	return _bodies[bi]


func _bone(name: String) -> int:
	return _skel.find_bone(_prefix + name)


# --- Running ---------------------------------------------------------------------


func _process(_delta: float) -> void:
	if _simulating:
		_drive()


func _physics_process(delta: float) -> void:
	if not _simulating:
		return
	if not _pending.is_empty() and _time > 0.0:
		for h: Dictionary in _pending:
			_apply_hit(h)
		_pending.clear()
	_time += delta
	_apply_tone()
	_window += delta
	if _window >= SETTLE_WINDOW:
		_window = 0.0
		var now: Array[Vector3] = []
		for b: RigidBody3D in _bodies.values():
			now.append(b.global_position)
		if _gun_body != null:
			now.append(_gun_body.global_position)
		var moved := _marks.size() != now.size()
		if not moved:
			for i in now.size():
				if now[i].distance_to(_marks[i]) > SETTLE_DRIFT:
					moved = true
					break
		_marks = now
		_still = 0 if moved else _still + 1
	if (_time >= MIN_TIME and _still >= SETTLE_WINDOWS) or _time >= MAX_TIME:
		_settle()


## The joint damper (see TONE_START): pulls each pair's spins toward each other,
## weighted by mass so the heavy part barely notices the light one.
func _apply_tone() -> void:
	var k := smoothstep(0.0, TONE_FADE, _time)
	var base := lerpf(TONE_START * tone_scale, TONE_END, k)
	for t: Array in _tones:
		var c := t[0] as RigidBody3D
		var p := t[1] as RigidBody3D
		var beta := clampf(base * float(t[2]), 0.0, 0.9)
		var diff := (p.angular_velocity - c.angular_velocity) * beta
		var total := c.mass + p.mass
		c.angular_velocity += diff * (p.mass / total)
		p.angular_velocity -= diff * (c.mass / total)


## Writes the bodies into the skeleton, in the start frame (`_s0`).
func _drive() -> void:
	if _skel == null or not is_instance_valid(_skel):
		return
	var g: Dictionary = {}
	for bi: int in _bodies:
		g[bi] = _s0inv * ((_bodies[bi] as RigidBody3D).global_transform * (_offset[bi] as Transform3D))
	for fi: int in _follow:
		var f: Array = _follow[fi]
		g[fi] = (g[f[0]] as Transform3D) * (f[1] as Transform3D)
	# Parents first, so each local pose is taken against its parent's NEW pose.
	var memo: Dictionary = {}
	for bi: int in g:
		var p := _parents[bi]
		var parent_g := _global_of(p, g, memo) if p >= 0 else Transform3D.IDENTITY
		_skel.set_bone_pose(bi, parent_g.affine_inverse() * (g[bi] as Transform3D))


## A bone's skeleton-space pose this frame: driven/followed bones from `g`,
## everything else its parent's times its own unchanged local pose.
func _global_of(bi: int, g: Dictionary, memo: Dictionary) -> Transform3D:
	if g.has(bi):
		return g[bi]
	if memo.has(bi):
		return memo[bi]
	var p := _parents[bi]
	var local := _skel.get_bone_pose(bi)
	var out := (_global_of(p, g, memo) * local) if p >= 0 else local
	memo[bi] = out
	return out


func _settle() -> void:
	_drive()
	_simulating = false
	if _gun_body != null and _gun != null and is_instance_valid(_gun):
		var park: Node = _anchor if _anchor != null and is_instance_valid(_anchor) else self
		_gun.reparent(park, true)
	_finish_bodies()
	settled.emit()


func _finish_bodies() -> void:
	_simulating = false
	_release_count()
	for j in _joints:
		if is_instance_valid(j):
			j.queue_free()
	_joints.clear()
	for b: RigidBody3D in _bodies.values():
		if is_instance_valid(b):
			b.queue_free()
	_bodies.clear()
	if _gun_body != null and is_instance_valid(_gun_body):
		# The gun was parked first (`_settle`), or is about to be restored (`clear`).
		if _gun != null and is_instance_valid(_gun) and _gun.get_parent() == _gun_body:
			_gun.reparent(self, true)
		_gun_body.queue_free()
	_gun_body = null
	if _catch != null and is_instance_valid(_catch):
		_catch.queue_free()
	_catch = null


static func _ortho(t: Transform3D) -> Transform3D:
	return Transform3D(t.basis.orthonormalized(), t.origin)


## A basis whose Y runs along `dir` (capsules stand on Y).
static func _basis_along(dir: Vector3) -> Basis:
	var y := dir.normalized()
	var ref := Vector3.FORWARD if absf(y.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT
	var x := ref.cross(y).normalized()
	var z := x.cross(y).normalized()
	return Basis(x, y, z)
