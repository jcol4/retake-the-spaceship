"""PLACEHOLDER death for the security robot: it powers down -- the pelvis drops
over its planted feet into a deep kneel, the torso folds forward, the head
drops -- and stays there.

    blender -b assets/sec_robot_v2.blend -P tools/build_robot_die.py

Why it exists: in game the robot dies as a RAGDOLL (scripts/ragdoll.gd, merc
profile -- the robot shares the merc's bone names), but UnitVisual only
ragdolls a model that HAS an authored `downed`, and plays that clip instead
whenever the ragdoll cannot run (off screen, or Ragdoll.MAX_ACTIVE already
falling). Its last frame is then the corpse. Replace it with a real death clip
(a Mixamo death run through tools/retarget_mixamo_robot.py --action die) when
there is one.

A slump rather than a topple on purpose: rotating the whole rig swings the IK
knee targets with it and folds the legs into a ball. Here every IK control
stays where the idle put it and only the pelvis and spine move.

Starts from `idle` frame 1, so it blends from the stance the robot stands in.
"""
import math
import bpy
from mathutils import Matrix, Vector

ACTION = "die"
SOURCE = "idle"
# frame: (pelvis drop in armature units, spine fold degrees, head drop degrees)
# Gravity-ish: slow to start, fast through the middle, a small settle bounce.
KEYS = {1: (0.00, 0, 0), 3: (0.08, 3, 5), 5: (0.30, 10, 15), 7: (0.58, 22, 30),
        8: (0.70, 28, 38), 9: (0.66, 30, 42), 10: (0.68, 30, 44), 12: (0.68, 30, 45)}
# How the fold is shared between the spine bones.
SPINE = {"spine_1": 0.4, "chest": 0.6}

rig = next(o for o in bpy.data.objects if o.type == 'ARMATURE' and o.parent is None)
src = bpy.data.actions[SOURCE]
ad = rig.animation_data
ad.action = src
bpy.context.scene.frame_set(1)
base = {pb.name: pb.matrix_basis.copy() for pb in rig.pose.bones}

old = bpy.data.actions.get(ACTION)
if old:
    bpy.data.actions.remove(old)
act = bpy.data.actions.new(ACTION)
act.use_fake_user = True
ad.action = act
PB = rig.pose.bones


def bend(name, deg):
    """Tips a bone forward (top toward -Y, the robot's front) about its head."""
    pb = PB[name]
    h = pb.matrix.translation.copy()
    pb.matrix = (Matrix.Translation(h) @ Matrix.Rotation(math.radians(deg), 4, 'X')
                 @ Matrix.Translation(-h) @ pb.matrix)
    bpy.context.view_layer.update()


def pose_at(drop, fold, nod):
    for pb in PB:
        pb.matrix_basis = base[pb.name]
    bpy.context.view_layer.update()
    PB["hip"].matrix = Matrix.Translation(Vector((0, 0, -drop))) @ PB["hip"].matrix
    bpy.context.view_layer.update()
    for name, share in SPINE.items():
        bend(name, fold * share)
    bend("head", nod)


def lowest_z():
    dg = bpy.context.evaluated_depsgraph_get()
    low = 1e9
    for ob in bpy.data.objects:
        if ob.type != 'MESH' or ob.hide_render:
            continue
        ev = ob.evaluated_get(dg)
        me = ev.to_mesh()
        low = min(low, min((ev.matrix_world @ v.co).z for v in me.vertices))
        ev.to_mesh_clear()
    return low


for frame, (drop, fold, nod) in sorted(KEYS.items()):
    pose_at(drop, fold, nod)
    for pb in PB:
        for path in ("location", "rotation_quaternion", "scale"):
            pb.keyframe_insert(path, frame=frame, group=pb.name)
act.use_frame_range = True
act.frame_start, act.frame_end = 1, max(KEYS)
bpy.context.scene.frame_set(max(KEYS))
print("[robot_die] lowest vertex at end: %.3f m" % lowest_z())
ad.action = bpy.data.actions[SOURCE]
bpy.ops.wm.save_mainfile()
