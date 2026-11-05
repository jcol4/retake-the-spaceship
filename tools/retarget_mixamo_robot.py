"""Retarget a Mixamo clip onto the sec_robot IK rig.

blender -b assets/sec_robot_v2.blend -P tools/retarget_mixamo_robot.py -- \
    --fbx art_src/walking_anim/Walking.fbx --action walk --center [--frames N] [--out other.blend]

Inferred mapping (the rigs share no names or proportions):
  * spine/neck/head/clavicles: world-space rotation delta from the Mixamo
    rest pose applied on top of the robot rest pose.
  * hips + feet: positions, scaled by leg-length ratio, written to `hip` and
    the `IK-foot.*` controls so planted feet stay planted.
  * arms: Mixamo arm/forearm deltas run FK on the robot's own bone lengths;
    the resulting wrist drives `IK-hand.*`, the elbow drives `TARGET-arm.*`.
  * knee poles ride the thigh delta.
Everything else is keyed at rest. Mixamo frames are resampled so the loop
spans --frames robot frames (last key == first key, like `run`);
clips must start and end on the same pose (true for Mixamo loops and these one-shots).
Both rigs face -Y with Z up (Mixamo in world space, robot in armature space),
so no axis conversion is needed.
"""
import sys
import argparse
import bpy
from mathutils import Matrix, Vector

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
ap = argparse.ArgumentParser()
ap.add_argument("--fbx", required=True)
ap.add_argument("--action", default="walk")
ap.add_argument("--frames", type=int, default=0,
                help="clip length in robot frames (default: source duration at --fps)")
ap.add_argument("--src-fps", type=float, default=30.0)
ap.add_argument("--fps", type=float, default=12.0, help="robot file frame rate")
ap.add_argument("--center", action="store_true",
                help="remove the clip's mean lateral hip offset (Walking.fbx drifts ~6cm)")
ap.add_argument("--out", default="", help="save a copy here instead of overwriting")
ap.add_argument("--rig", default="Armature")
args = ap.parse_args(argv)

rig = bpy.data.objects[args.rig]
RB = rig.data.bones
PB = rig.pose.bones

# ---- import mixamo -------------------------------------------------------
# Clips downloaded "with skin" bring a mesh, materials and PACKED textures;
# packed images survive saving even at 0 users, so remove everything new.
IMPORT_COLLS = ("objects", "meshes", "materials", "images", "textures",
                "node_groups", "armatures", "actions", "collections")
before = {c: set(getattr(bpy.data, c)) for c in IMPORT_COLLS}
bpy.ops.import_scene.fbx(filepath=args.fbx)
created = {c: [i for i in getattr(bpy.data, c) if i not in before[c]] for c in IMPORT_COLLS}
new_objs = created["objects"]
mix = next(o for o in new_objs if o.type == 'ARMATURE')
f0, f1 = mix.animation_data.action.frame_range
cycle_src = f1 - f0  # Mixamo's last frame duplicates the first


def mname(n):
    return "mixamorig:" + n


def rot3(m):
    return m.to_3x3().normalized()


MW = mix.matrix_world.copy()
mrest = {b.name: MW @ b.matrix_local for b in mix.data.bones}

# ---- sample mixamo -------------------------------------------------------
N = args.frames or max(2, round(cycle_src * args.fps / args.src_fps))
sc = bpy.context.scene
samples = []
for k in range(N + 1):
    t = f0 + cycle_src * (k % N) / N  # k == N wraps to the exact first frame
    fi = int(t)
    sc.frame_set(fi, subframe=t - fi)
    samples.append({pb.name: MW @ pb.matrix for pb in mix.pose.bones})

# optional lateral centring: the Mixamo walk sits ~6cm off origin in X
hx = sum(smp[mname("Hips")].translation.x for smp in samples[:N]) / N if args.center else 0.0

# ---- robot dims ------------------------------------------------------------
R = {b.name: b.matrix_local.copy() for b in RB}
r_leg = (R["leg.L"].translation - Vector(RB["shin.L"].tail_local)).length
m_leg = (mrest[mname("LeftUpLeg")].translation - mrest[mname("LeftFoot")].translation).length
s = r_leg / m_leg
print(f"[retarget] scale {s:.3f}  src frames {f0}-{f1}  -> {N} robot frames")


def delta(smp, mb):
    return rot3(smp[mname(mb)]) @ rot3(mrest[mname(mb)]).inverted()


def mpos(smp, mb):
    v = smp[mname(mb)].translation.copy()
    v.x -= hx
    return v


def mrestpos(mb):
    return mrest[mname(mb)].translation.copy()


def compose(rot, loc):
    m = rot.to_4x4()
    m.translation = loc
    return m


SIDE = {"L": "Left", "R": "Right"}
ROT_MAP = {"spine_1": "Spine1", "chest": "Spine2", "neck": "Neck", "head": "Head",
           "clav.L": "LeftShoulder", "clav.R": "RightShoulder"}


def solve(smp):
    P = {}  # armature-space pose matrices
    B = {}  # resulting matrix_basis

    def nominal(name):
        par = RB[name].parent
        return P[par.name] @ (R[par.name].inverted() @ R[name]) if par else R[name]

    def put(name, target):
        B[name] = nominal(name).inverted() @ target
        P[name] = target

    def put_rot(name, rot):  # head stays where the parent chain puts it
        put(name, compose(rot, nominal(name).translation))

    def rest_rot(name, d):
        return d @ rot3(R[name])

    put("Main", R["Main"])
    hip_loc = R["hip"].translation + s * (mpos(smp, "Hips") - mrestpos("Hips"))
    put("hip", compose(rest_rot("hip", delta(smp, "Hips")), hip_loc))
    for b, mb in ROT_MAP.items():
        put_rot(b, rest_rot(b, delta(smp, mb)))
    for sd, mx in SIDE.items():
        # arm FK on robot proportions -> IK hand + elbow pole
        da, df = delta(smp, mx + "Arm"), delta(smp, mx + "ForeArm")
        put_rot("arm." + sd, rest_rot("arm." + sd, da))
        put_rot("forearm." + sd, rest_rot("forearm." + sd, df))
        sh = P["arm." + sd].translation
        elbow = sh + da @ (R["forearm." + sd].translation - R["arm." + sd].translation)
        wrist = elbow + df @ (R["IK-hand." + sd].translation - R["forearm." + sd].translation)
        put("IK-hand." + sd, compose(rest_rot("IK-hand." + sd, delta(smp, mx + "Hand")), wrist))
        put("TARGET-arm." + sd, compose(rot3(R["TARGET-arm." + sd]),
            elbow + da @ (R["TARGET-arm." + sd].translation - R["forearm." + sd].translation)))
        # legs: thigh/shin FK as fallback, IK foot from scaled ankle position
        dt, dsn = delta(smp, mx + "UpLeg"), delta(smp, mx + "Leg")
        put_rot("leg." + sd, rest_rot("leg." + sd, dt))
        put_rot("shin." + sd, rest_rot("shin." + sd, dsn))
        knee = P["leg." + sd].translation + dt @ (R["shin." + sd].translation - R["leg." + sd].translation)
        ankle = R["IK-foot." + sd].translation + s * (mpos(smp, mx + "Foot") - mrestpos(mx + "Foot"))
        put("IK-foot." + sd, compose(rest_rot("IK-foot." + sd, delta(smp, mx + "Foot")), ankle))
        put("TARGET_leg." + sd, compose(rot3(R["TARGET_leg." + sd]),
            knee + dt @ (R["TARGET_leg." + sd].translation - R["shin." + sd].translation)))
    return B


# ---- bake ------------------------------------------------------------------
old = bpy.data.actions.get(args.action)
if old:
    bpy.data.actions.remove(old)
act = bpy.data.actions.new(args.action)
act.use_fake_user = True
rig.animation_data_create()
if rig.animation_data.action:
    rig.animation_data.action.use_fake_user = True  # keep `run` alive
rig.animation_data.action = act
prevq = {}
for k, smp in enumerate(samples):
    B = solve(smp)
    for pb in PB:
        loc, q, _ = B.get(pb.name, Matrix.Identity(4)).decompose()
        if pb.name in prevq:
            q.make_compatible(prevq[pb.name])
        prevq[pb.name] = q
        pb.location, pb.rotation_quaternion, pb.scale = loc, q, Vector((1, 1, 1))
        for path in ("location", "rotation_quaternion", "scale"):
            pb.keyframe_insert(path, frame=1 + k, group=pb.name)
act.use_frame_range = True
act.frame_start, act.frame_end = 1, N + 1

# ---- clean up import -------------------------------------------------------
for c in IMPORT_COLLS:  # objects first, so their data is free to remove
    coll = getattr(bpy.data, c)
    for item in created[c]:
        coll.remove(item)
sc.frame_set(1)
print(f"[retarget] baked '{args.action}' frames 1-{N + 1}; actions:", [a.name for a in bpy.data.actions])
if args.out:
    bpy.ops.wm.save_as_mainfile(filepath=args.out, copy=True)
else:
    bpy.ops.wm.save_mainfile()
