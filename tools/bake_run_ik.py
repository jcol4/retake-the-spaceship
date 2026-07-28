"""Author a run cycle on the IK control rig, as a new action "run_ik".

Samples the existing FK "run" action at each of its keyframes (world position
+ rotation of hand.L/R and foot.L/R, plus the elbow/knee position to work out
which way the pole should sit), converts each into the IK control bones' own
local space, and keys hand_ik/foot_ik/hand_pole/foot_pole plus the four
ik_arm_L, ik_arm_R, ik_leg_L, ik_leg_R sliders (on at 1.0 for the whole clip)
into a new action. Scrubbing "run_ik" with the sliders on should move the
deform bones (upperarm, lowerarm, hand, thigh, shin, foot) through
essentially the same run cycle as the original FK "run" action — verified by
tools/verify_run_ik.py, which measures the drift between the two.

Also inserts a single ik_* = 0.0 keyframe into every OTHER existing action,
at that action's own start frame. These are plain custom properties on the
armature OBJECT, not per-action state — without this, switching from run_ik
to (say) idle in the same session would leave IK stuck on, since idle has no
track for these properties to override the leftover value with.

Caveat this does NOT handle: the IK constraints only run live inside
Blender. glTF/Godot don't evaluate constraints, so exporting run_ik via
tools/export_soldier_rig.py as-is would ship an action with keys on the
control bones and NONE on the deform bones — invisible in-game. Shipping
this clip would need a bake pass (Blender's own Bake Action operator, run
with "Visual Keying" so it captures the constrained result onto the deform
bones) before export. Not done here since it wasn't asked for.

Run headless:
    blender -b -P tools/bake_run_ik.py -- --blend assets/soldier_rig.blend
"""

import math
import os
import sys

import bpy
from mathutils import Vector

SIDES = ("L", "R")
POLE_DIST = 0.4
# Everything the IK chains don't drive. These still need their FK rotation
# (and, for hips, location) copied straight across from "run" — the control
# rig only covers the arms and legs, so without this the torso just sits at
# whatever it last was (rest pose, on a fresh action), silently pulling the
# shoulders and hips off the run cycle's actual lean/twist/bob every frame
# except the ones where that lean happens to be zero.
TORSO_BONES = ("hips", "spine", "chest", "neck", "head", "shoulder.L", "shoulder.R")


def get_action_frames(action, bone_prefixes):
    frames = set()
    for layer in action.layers:
        for strip in layer.strips:
            for slot in action.slots:
                try:
                    cb = strip.channelbag(slot)
                except Exception:
                    cb = None
                if not cb:
                    continue
                for fc in cb.fcurves:
                    if bone_prefixes is None or any(p in fc.data_path for p in bone_prefixes):
                        for kp in fc.keyframe_points:
                            frames.add(round(kp.co.x, 4))
    return sorted(frames)


def world_head_to_local(bone_name, rig, world_head):
    b = rig.data.bones[bone_name]
    m3 = b.matrix_local.to_3x3()
    rest_head = b.matrix_local.translation
    return m3.inverted() @ (world_head - rest_head)


def world_rot_to_local_quat(bone_name, rig, world_rot3x3):
    b = rig.data.bones[bone_name]
    m3 = b.matrix_local.to_3x3()
    local3x3 = m3.inverted() @ world_rot3x3
    return local3x3.to_quaternion()


def set_frame(f):
    whole = math.floor(f)
    bpy.context.scene.frame_set(int(whole), subframe=f - whole)
    bpy.context.view_layer.update()


def pole_position(shoulder, elbow, wrist):
    axis = (wrist - shoulder).normalized()
    proj = shoulder + axis * (elbow - shoulder).dot(axis)
    perp = elbow - proj
    if perp.length < 1e-6:
        perp = Vector((0.0, 1.0, 0.0))
    return elbow + perp.normalized() * POLE_DIST


def bake(blend_path):
    bpy.ops.wm.open_mainfile(filepath=blend_path)
    rig = bpy.data.objects["Rig"]
    run_action = bpy.data.actions["run"]

    for side in SIDES:
        rig.pose.bones[f"hand_ik.{side}"].rotation_mode = "QUATERNION"
        rig.pose.bones[f"foot_ik.{side}"].rotation_mode = "QUATERNION"

    frames = get_action_frames(run_action, None)
    print(f"[bake_run_ik] sampling {len(frames)} frames from 'run': {frames}")

    rig.animation_data.action = run_action
    if run_action.slots:
        rig.animation_data.action_slot = run_action.slots[0]

    samples = []
    for f in frames:
        set_frame(f)
        data = {}
        for side in SIDES:
            data[side] = dict(
                shoulder=rig.pose.bones[f"upperarm.{side}"].head.copy(),
                elbow=rig.pose.bones[f"lowerarm.{side}"].head.copy(),
                # hand.head == lowerarm.tail exactly (no rest offset), so this
                # doubles as both the wrist and the true IK chain tip.
                wrist=rig.pose.bones[f"hand.{side}"].head.copy(),
                hand_rot=rig.pose.bones[f"hand.{side}"].matrix.to_3x3().copy(),
                hip=rig.pose.bones[f"thigh.{side}"].head.copy(),
                knee=rig.pose.bones[f"shin.{side}"].head.copy(),
                # NOT foot.head: the rig has a small built-in ankle offset
                # (foot.head sits ~4cm from shin.tail even at rest, unlike the
                # arm where hand.head == lowerarm.tail exactly). Blender's IK
                # constraint aligns the chain's actual tip — shin.tail — with
                # the target, so that's what the target and pole math both
                # need to use, or every leg frame carries a constant ~4cm
                # target error the solver "corrects" into a wrong pose instead.
                ankle=rig.pose.bones[f"shin.{side}"].tail.copy(),
                # Copy Rotation still wants the true foot bone's orientation.
                foot_rot=rig.pose.bones[f"foot.{side}"].matrix.to_3x3().copy(),
            )
        data["torso"] = {
            name: (rig.pose.bones[name].rotation_euler.copy(),
                   rig.pose.bones[name].location.copy())
            for name in TORSO_BONES
        }
        samples.append((f, data))

    old = bpy.data.actions.get("run_ik")
    if old is not None:
        bpy.data.actions.remove(old)

    run_ik = bpy.data.actions.new("run_ik")
    run_ik.use_fake_user = True
    rig.animation_data.action = run_ik

    for f, data in samples:
        set_frame(f)
        for side in SIDES:
            d = data[side]
            hand_ik = rig.pose.bones[f"hand_ik.{side}"]
            hand_ik.location = world_head_to_local(f"hand_ik.{side}", rig, d["wrist"])
            hand_ik.rotation_quaternion = world_rot_to_local_quat(
                f"hand_ik.{side}", rig, d["hand_rot"])
            hand_ik.keyframe_insert("location", frame=f)
            hand_ik.keyframe_insert("rotation_quaternion", frame=f)

            hp = rig.pose.bones[f"hand_pole.{side}"]
            hp.location = world_head_to_local(
                f"hand_pole.{side}", rig, pole_position(d["shoulder"], d["elbow"], d["wrist"]))
            hp.keyframe_insert("location", frame=f)

            foot_ik = rig.pose.bones[f"foot_ik.{side}"]
            foot_ik.location = world_head_to_local(f"foot_ik.{side}", rig, d["ankle"])
            foot_ik.rotation_quaternion = world_rot_to_local_quat(
                f"foot_ik.{side}", rig, d["foot_rot"])
            foot_ik.keyframe_insert("location", frame=f)
            foot_ik.keyframe_insert("rotation_quaternion", frame=f)

            fp = rig.pose.bones[f"foot_pole.{side}"]
            fp.location = world_head_to_local(
                f"foot_pole.{side}", rig, pole_position(d["hip"], d["knee"], d["ankle"]))
            fp.keyframe_insert("location", frame=f)

        for name in TORSO_BONES:
            rot, loc = data["torso"][name]
            pb = rig.pose.bones[name]
            pb.rotation_euler = rot
            pb.keyframe_insert("rotation_euler", frame=f)
            if name == "hips":
                pb.location = loc
                pb.keyframe_insert("location", frame=f)

    for prop in ("ik_arm_L", "ik_arm_R", "ik_leg_L", "ik_leg_R"):
        rig[prop] = 1.0
        rig.keyframe_insert(f'["{prop}"]', frame=frames[0])
        rig.keyframe_insert(f'["{prop}"]', frame=frames[-1])
        rig[prop] = 0.0  # leave the live value back at the safe default

    run_ik.use_frame_range = True
    run_ik.frame_start, run_ik.frame_end = frames[0], frames[-1]

    # Safety net: every OTHER action gets an explicit ik_* = 0 key at its own
    # start, so switching back to it can't inherit run_ik's sliders left on.
    for action in list(bpy.data.actions):
        if action is run_ik:
            continue
        rig.animation_data.action = action
        start = action.frame_range[0]
        set_frame(start)
        for prop in ("ik_arm_L", "ik_arm_R", "ik_leg_L", "ik_leg_R"):
            rig[prop] = 0.0
            rig.keyframe_insert(f'["{prop}"]', frame=start)

    rig.animation_data.action = None
    for prop in ("ik_arm_L", "ik_arm_R", "ik_leg_L", "ik_leg_R"):
        rig[prop] = 0.0

    bpy.ops.wm.save_mainfile(filepath=blend_path)
    print(f"[bake_run_ik] saved {blend_path} with new action 'run_ik' "
          f"({len(bpy.data.actions)} actions total)")


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if "--blend" not in argv:
        raise SystemExit("usage: blender -b -P tools/bake_run_ik.py -- --blend <path.blend>")
    bake(os.path.abspath(argv[argv.index("--blend") + 1]))


main()
