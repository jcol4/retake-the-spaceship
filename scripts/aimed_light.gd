class_name AimedLight
extends SpotLight3D
## A weapon light that sits on the muzzle but points where the UNIT faces.
##
## Those are two different directions whenever the carry pose holds the rifle
## across the body, which every pose in the set does — it was measured at 85
## degrees off forward in idle and 80 in run back when the poses were mocap, and
## the drawn art inherited the same carry. A light rigidly parented to the muzzle
## therefore sprays sideways while the unit is plainly looking ahead.
##
## That is not merely ugly. LightingManager computes which tiles a unit lights
## from `-unit.global_transform.basis.z` (lighting_manager.gd), i.e. from unit
## facing, and those tiles decide which aliens notice the unit. A beam pointing
## somewhere else makes the screen disagree with the rules, and the rule this
## exists to hold is that what you see lit is what the unit can actually see by.
##
## So: position follows the weapon, orientation follows the unit. The beam still
## visibly leaves the barrel, and it always agrees with the simulation.
##
## Uses top_level so the muzzle's rotation is ignored while its position is
## still tracked by hand below.

## Node supplying position — normally the muzzle. Defaults to the parent.
@export var origin_path: NodePath = ^".."
## Node whose basis the aim is expressed in. Empty means `owner`, which is the
## Visual root and shares the unit's basis.
@export var facing_path: NodePath

## Where the beam points, in `facing`'s LOCAL space. Default -Z is straight
## ahead, which is what every character without a measured barrel gets.
##
## The merc overwrites this with his rifle's actual bore, measured off two
## locators on the barrel (tools/render_sprites.py --markers) and about 18
## degrees off his shoulders. That is a deliberate change of policy from what
## the note above describes: the light now follows the RIFLE rather than the
## torso, and `lighting_manager.gd` is aimed by the same vector so the rules
## still light exactly what the screen does.
##
## STABLE, not per-frame. The bore sways ~5 degrees through an idle cycle, and
## LightingManager recomputes only on discrete triggers (move, toggle, turn
## start) -- so a swaying gameplay cone would sample whichever animation frame
## happened to be showing when a unit moved, and two identical moves could light
## different tiles. The drawn beam sways; what the rules aim by must not.
var bore_direction := Vector3(0.0, 0.0, -1.0)

var _origin: Node3D = null
var _facing: Node3D = null


func _ready() -> void:
	# Detach from the parent's transform entirely; _process reimposes position.
	top_level = true
	_origin = get_node_or_null(origin_path) as Node3D
	_facing = get_node_or_null(facing_path) as Node3D if not facing_path.is_empty() \
		else owner as Node3D
	if _origin == null or _facing == null:
		push_warning("AimedLight: origin=%s facing=%s" % [_origin, _facing])
		set_process(false)


func _process(_delta: float) -> void:
	# Deliberately not skipped while invisible: a light toggled back on mid-turn
	# should already be pointing the right way rather than snapping on the
	# following frame.
	var facing := _facing.global_transform.basis.orthonormalized()
	global_transform = Transform3D(aim_basis(facing * bore_direction),
		_origin.global_position)


## A basis whose -Z (a Godot light's forward) lies along `aim`.
static func aim_basis(aim: Vector3) -> Basis:
	if aim.length_squared() < 1e-8:
		return Basis()
	var dir := aim.normalized()
	# looking_at needs an `up` that is not parallel to the aim. A rifle bore is
	# nowhere near vertical, so this only guards against a degenerate caller.
	var up := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.999 else Vector3.FORWARD
	return Basis.looking_at(dir, up)
