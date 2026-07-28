"""Check that "run_ik" reproduces "run" on the deform bones.

Run headless:
    blender -b -P tools/verify_run_ik.py -- --blend assets/soldier_rig.blend
"""

import math
import os
import sys

import bpy

SIDES = ("L", "R")
BONES = [f"{b}.{s}" for b in ("upperarm", "lowerarm", "hand", "thigh", "shin", "foot")
         for s in SIDES]


def set_frame(f):
    whole = math.floor(f)
    bpy.context.scene.frame_set(int(whole), subframe=f - whole)
    bpy.context.view_layer.update()


def get_action_frames(action):
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
                    for kp in fc.keyframe_points:
                        frames.add(round(kp.co.x, 4))
    return sorted(frames)


def sample(rig, action, frame):
    rig.animation_data.action = action
    if action.slots:
        rig.animation_data.action_slot = action.slots[0]
    set_frame(frame)
    return {b: (rig.pose.bones[b].head.copy(), rig.pose.bones[b].tail.copy()) for b in BONES}


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    blend_path = os.path.abspath(argv[argv.index("--blend") + 1])
    bpy.ops.wm.open_mainfile(filepath=blend_path)
    rig = bpy.data.objects["Rig"]
    run = bpy.data.actions["run"]
    run_ik = bpy.data.actions["run_ik"]

    for prop in ("ik_arm_L", "ik_arm_R", "ik_leg_L", "ik_leg_R"):
        rig[prop] = 1.0

    frames = get_action_frames(run)
    # Sample every FK frame first, then every IK frame, rather than
    # alternating actions at the same frame number back-to-back — the latter
    # pattern doesn't reliably force Blender to re-evaluate the pose (frame_set
    # appears to skip work when the frame number doesn't change even if the
    # active action just did), which silently produced 0.0mm "matches" here
    # before this was noticed.
    fk_samples = {f: sample(rig, run, f) for f in frames}
    ik_samples = {f: sample(rig, run_ik, f) for f in frames}
    worst = (0.0, None, None)
    for f in frames:
        fk, ik = fk_samples[f], ik_samples[f]
        for b in BONES:
            for a, c in zip(fk[b], ik[b]):
                d = (a - c).length
                if d > worst[0]:
                    worst = (d, b, f)
    print(f"[verify_run_ik] worst deform-bone drift between run and run_ik: "
          f"{worst[0] * 1000:.1f} mm on {worst[1]} at frame {worst[2]}")

    for prop in ("ik_arm_L", "ik_arm_R", "ik_leg_L", "ik_leg_R"):
        rig[prop] = 0.0
    rig.animation_data.action = run
    set_frame(0)
    for b in ("hand.L", "hand.R"):
        before = rig.pose.bones[b].head.copy()
    rig.animation_data.action = None


main()
