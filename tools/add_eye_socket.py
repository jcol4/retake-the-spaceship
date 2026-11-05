"""Adds (or moves) the `eye` Empty a character's glowing eye is drawn at.

    blender -b assets/sec_robot_v2.blend -P tools/add_eye_socket.py -- \
        --bone head --at 0 -0.235 2.379

`--at` is the eye's centre in ARMATURE space (the rest pose), e.g. the middle of
the robot's camera lens, measured off the mesh. The Empty is parented to `--bone`
so it rides the head through every animation and the ragdoll; the glTF export
carries it as a bone attachment, and UnitVisual.EYE_NODE lights it in game (an
emissive lens and a small light). Nothing else in the pipeline needs to know.
"""
import argparse
import sys

import bpy
from mathutils import Matrix, Vector

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
ap = argparse.ArgumentParser()
ap.add_argument("--bone", default="head")
ap.add_argument("--at", type=float, nargs=3, required=True)
ap.add_argument("--name", default="eye")
ap.add_argument("--size", type=float, default=0.05, help="display size only")
args = ap.parse_args(argv)

rig = next(o for o in bpy.data.objects if o.type == 'ARMATURE' and o.parent is None)
eye = bpy.data.objects.get(args.name)
if eye is None:
    eye = bpy.data.objects.new(args.name, None)
    rig.users_collection[0].objects.link(eye)
eye.empty_display_type = 'SPHERE'
eye.empty_display_size = args.size
eye.parent = rig
eye.parent_type = 'BONE'
eye.parent_bone = args.bone
# A bone child sits at the bone's TAIL in the bone's rest frame; place it by
# its armature-space rest position instead, so --at means what it says.
bone = rig.data.bones[args.bone]
tail = bone.matrix_local @ Matrix.Translation(Vector((0, bone.length, 0)))
eye.matrix_parent_inverse = Matrix.Identity(4)
eye.matrix_basis = tail.inverted() @ Matrix.Translation(Vector(args.at))
pose_position = rig.data.pose_position
rig.data.pose_position = 'REST'  # report where it sits at rest, not mid-idle
bpy.context.view_layer.update()
rest = rig.matrix_world.inverted() @ eye.matrix_world
print("[eye] %s on %s at armature %s (rest)" % (eye.name, args.bone,
      tuple(round(v, 3) for v in rest.translation)))
rig.data.pose_position = pose_position
bpy.ops.wm.save_mainfile()
