"""Spin off a rifle-free, IK-free duplicate of soldier_rig.blend for
practicing the IK rigging by hand.

Starts from assets/soldier_rig.blend and strips:
  * the Rifle object and its Child Of constraint
  * the IK control bones (hand_ik/foot_ik/hand_pole/foot_pole), the IK and
    Copy Rotation constraints on the deform bones, their drivers, and the
    ik_arm_L/R, ik_leg_L/R custom properties
  * the "run_ik" action (built against those controls, so it has nothing to
    play back once they're gone)

Leaves the mesh, deform-only armature, and all 11 FK-authored actions
(idle, run, aim_hold, etc.) intact as reference while you build your own IK
rig on top.

Run headless:
    blender -b -P tools/make_character_only.py -- --src assets/soldier_rig.blend --dst assets/soldier_character_only.blend
"""

import os
import sys

import bpy

IK_BONE_NAMES = [f"{kind}_{part}.{side}" for kind in ("hand", "foot")
                 for part in ("ik", "pole") for side in ("L", "R")]
IK_PROPS = ("ik_arm_L", "ik_arm_R", "ik_leg_L", "ik_leg_R")


def strip(src_path, dst_path):
    bpy.ops.wm.open_mainfile(filepath=src_path)
    rig = bpy.data.objects["Rig"]

    rifle = bpy.data.objects.get("Rifle")
    if rifle is not None:
        bpy.data.objects.remove(rifle, do_unlink=True)

    run_ik = bpy.data.actions.get("run_ik")
    if run_ik is not None:
        bpy.data.actions.remove(run_ik)

    for pb in rig.pose.bones:
        for con in list(pb.constraints):
            if con.type in ("IK", "COPY_ROTATION") and (
                    con.subtarget in IK_BONE_NAMES or
                    (con.type == "IK" and con.pole_subtarget in IK_BONE_NAMES)):
                pb.constraints.remove(con)

    for prop in IK_PROPS:
        if prop in rig.keys():
            del rig[prop]

    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.mode_set(mode="EDIT")
    eb = rig.data.edit_bones
    for name in IK_BONE_NAMES:
        if name in eb:
            eb.remove(eb[name])
    bpy.ops.object.mode_set(mode="OBJECT")

    os.makedirs(os.path.dirname(dst_path), exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=dst_path)
    size = os.path.getsize(dst_path) / 1024.0
    print(f"[make_character_only] wrote {dst_path} ({size:.0f} KB) — "
          f"{len(bpy.data.objects)} objects, {len(bpy.data.actions)} actions, "
          f"{len(rig.data.bones)} bones")


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if "--src" not in argv or "--dst" not in argv:
        raise SystemExit(
            "usage: blender -b -P tools/make_character_only.py -- "
            "--src <path.blend> --dst <path.blend>")
    strip(os.path.abspath(argv[argv.index("--src") + 1]),
          os.path.abspath(argv[argv.index("--dst") + 1]))


main()
