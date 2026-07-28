class_name AimedLight
extends SpotLight3D
## A weapon light that sits on the muzzle but points where the UNIT faces.
##
## Those are two different directions once the animation set is mocap. The
## carry poses hold the rifle across the body — measured at 85 degrees off
## forward in idle and 80 in run — so a light rigidly parented to the muzzle
## sprays sideways while the unit is plainly looking ahead.
##
## That is not merely ugly. LightingManager computes which tiles a unit lights
## from `-unit.global_transform.basis.z` (lighting_manager.gd), i.e. from unit
## facing, and those tiles decide which aliens notice the unit. A beam pointing
## somewhere else makes the screen disagree with the rules — the exact thing
## character_base.tscn's original comment set out to guarantee ("what you see
## lit is what the unit can actually see by").
##
## So: position follows the weapon, orientation follows the unit. The beam still
## visibly leaves the barrel, and it always agrees with the simulation.
##
## Uses top_level so the muzzle's rotation is ignored while its position is
## still tracked by hand below.

## Node supplying position — normally the muzzle. Defaults to the parent.
@export var origin_path: NodePath = ^".."
## Node whose -Z is the aim direction. Empty means `owner`, which is the Visual
## root and shares the unit's basis.
@export var facing_path: NodePath

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
	# Deliberately not skipped while invisible: the Beam child reads this
	# transform too, and a light toggled back on mid-turn should already be
	# pointing the right way rather than snapping on the following frame.
	global_transform = Transform3D(_facing.global_transform.basis.orthonormalized(),
		_origin.global_position)
