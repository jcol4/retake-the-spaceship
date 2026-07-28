"""Sanity-check the IK rig added by tools/add_ik_controls.py.

1. Confirms FK playback (ik_* props at their default 0.0) is unchanged versus
   the pre-IK backup, at a run-cycle frame where the arms and legs are both
   mid-bend.
2. Turns ik_arm_R and ik_leg_R on, moves the hand/foot IK targets, and prints
   the resulting elbow/knee positions so bend direction can be checked
   against what run's FK-authored poses already do.

Run headless:
    blender -b -P tools/verify_ik_controls.py -- --blend assets/soldier_rig.blend --backup assets/soldier_rig.blend.bak
"""

import os
import sys

import bpy
from mathutils import Vector


def snapshot_fk(blend_path, frame):
    bpy.ops.wm.open_mainfile(filepath=blend_path)
    rig = bpy.data.objects["Rig"]
    rig.animation_data.action = bpy.data.actions["run"]
    if rig.animation_data.action.slots:
        rig.animation_data.action_slot = rig.animation_data.action.slots[0]
    bpy.context.scene.frame_set(frame)
    bpy.context.view_layer.update()
    names = ("lowerarm.L", "lowerarm.R", "hand.L", "hand.R",
             "shin.L", "shin.R", "foot.L", "foot.R")
    return {n: (rig.pose.bones[n].head.copy(), rig.pose.bones[n].tail.copy())
            for n in names}


def check_fk_unchanged(blend_path, backup_path, frame):
    before = snapshot_fk(backup_path, frame)
    after = snapshot_fk(blend_path, frame)
    worst = 0.0
    for name in before:
        for a, b in zip(before[name], after[name]):
            worst = max(worst, (a - b).length)
    print(f"[verify] FK playback drift at frame {frame}: {worst * 1000:.4f} mm "
          f"(should be ~0)")
    return worst


def check_ik_bend(blend_path):
    bpy.ops.wm.open_mainfile(filepath=blend_path)
    rig = bpy.data.objects["Rig"]
    rig.animation_data.action = None
    bpy.context.view_layer.update()

    rig["ik_arm_R"] = 1.0
    rig["ik_leg_R"] = 1.0
    bpy.context.view_layer.update()

    # Pull the hand target forward and in, which should make the elbow swing
    # forward/out (matching how run's FK poses already bend it) rather than
    # kinking backward.
    def world_offset_to_local(bone_name, world_offset):
        # pose_bone.location is expressed in the bone's own rest orientation,
        # not world space, even for an unparented bone.
        mat = rig.data.bones[bone_name].matrix_local.to_3x3()
        return mat.inverted() @ world_offset

    hand_ik = rig.pose.bones["hand_ik.R"]
    shoulder = rig.pose.bones["upperarm.R"].head.copy()
    hand_ik.location = (0.0, 0.0, 0.0)
    bpy.context.view_layer.update()
    rest_hand = hand_ik.head.copy()
    offset = Vector((0.15, -0.15, 0.0))
    hand_ik.location = world_offset_to_local("hand_ik.R", offset)
    bpy.context.view_layer.update()

    elbow = rig.pose.bones["lowerarm.R"].head.copy()
    hand = rig.pose.bones["hand.R"].head.copy()
    print(f"[verify] shoulder={shoulder}")
    print(f"[verify] elbow (after IK pull)={elbow}")
    print(f"[verify] hand (should be near target {rest_hand + offset})={hand}")

    foot_ik = rig.pose.bones["foot_ik.R"]
    hip = rig.pose.bones["thigh.R"].head.copy()
    rest_foot = foot_ik.head.copy()
    foot_offset = Vector((0.0, 0.25, 0.15))
    foot_ik.location = world_offset_to_local("foot_ik.R", foot_offset)
    bpy.context.view_layer.update()
    knee = rig.pose.bones["shin.R"].head.copy()
    foot = rig.pose.bones["foot.R"].head.copy()
    print(f"[verify] hip={hip}")
    print(f"[verify] knee (after IK pull)={knee}")
    print(f"[verify] foot (should be near target {rest_foot + foot_offset})={foot}")

    import math
    mesh_obj = bpy.data.objects["Soldier"]
    cam_data = bpy.data.cameras.new("VerifyCam")
    cam_obj = bpy.data.objects.new("VerifyCam", cam_data)
    bpy.context.scene.collection.objects.link(cam_obj)
    cam_obj.location = (2.6, -2.6, 1.1)
    cam_obj.rotation_euler = (math.radians(80), 0, math.radians(45))
    bpy.context.scene.camera = cam_obj
    light_data = bpy.data.lights.new("VerifySun", type="SUN")
    light_data.energy = 3
    light_obj = bpy.data.objects.new("VerifySun", light_data)
    bpy.context.scene.collection.objects.link(light_obj)
    light_obj.rotation_euler = (math.radians(60), 0, math.radians(30))
    scene = bpy.context.scene
    try:
        scene.render.engine = "BLENDER_EEVEE_NEXT"
    except TypeError:
        scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 700
    scene.render.resolution_y = 700
    scene.world = bpy.data.worlds.new("VerifyWorld")
    scene.world.color = (0.5, 0.5, 0.55)
    out = os.path.abspath("out/verify_ik_pull.png")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    scene.render.filepath = out
    bpy.ops.render.render(write_still=True)
    print(f"[verify] rendered {out}")


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    blend_path = os.path.abspath(argv[argv.index("--blend") + 1])
    backup_path = os.path.abspath(argv[argv.index("--backup") + 1])
    check_fk_unchanged(blend_path, backup_path, 4)
    check_ik_bend(blend_path)


main()
