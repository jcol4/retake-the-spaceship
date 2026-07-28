"""Add an IK control layer to assets/soldier_rig.blend, in place.

Adds, per arm and leg:
  * an IK target bone (hand_ik.L/R, foot_ik.L/R) you move to pose the limb
  * a pole bone (hand_pole.L/R, foot_pole.L/R) that controls which way the
    elbow/knee bends — the rest pose has each limb perfectly straight
    (upperarm/lowerarm and thigh/shin colinear), which is exactly the
    configuration Blender's IK solver cannot resolve without one
  * an IK constraint on the chain's last deform bone (lowerarm/shin,
    chain_count=2, so it drives both bones in the chain)
  * a Copy Rotation constraint on the tip bone (hand/foot) so its orientation
    follows the IK target too, not just the chain's position

All eight of those constraints get their influence driven by four custom
properties on the armature OBJECT (not a bone, so they show up in the
Object Properties tab regardless of pose-mode bone selection):
  ik_arm_L, ik_arm_R, ik_leg_L, ik_leg_R  (0 = pure FK, 1 = pure IK)

They default to 0.0, which is the entire point: the 11 actions already
baked in this file were keyed as pure FK rotations on the deform bones
directly, and an IK constraint at influence 1 would silently override
whatever rotation was keyed there. At influence 0 the new constraints are
no-ops, so existing playback is bit-for-bit unaffected — verified by
tools/verify_ik_controls.py, which renders the run action before relying on
that claim rather than asserting it.

New animation work: set the relevant ik_* property to 1 (Object Properties >
Custom Properties, or drive it from a bone with a driver if you want it
inside pose mode) and move the *_ik / *_pole bones instead of keying
upperarm/lowerarm/thigh/shin rotations directly.

Run headless:
    blender -b -P tools/add_ik_controls.py -- --blend assets/soldier_rig.blend
"""

import os
import sys

import bpy
from mathutils import Vector

SIDES = ("L", "R")
POLE_FORWARD = 0.40   # metres the pole sits in front of the elbow/knee
# Measured, not derived — see tools/verify_run_ik.py, which drives run_ik and
# checks the deform bones land back on top of the original FK "run" action.
# 0.0 (the first guess) bends the right direction but is tens of mm off the
# real FK position; sweeping pole_angle in 1-degree steps against that ground
# truth found arms exact at -90 deg and legs exact at +90 deg, uniformly
# across L/R (this rig has no L/R asymmetry in bone roll, so it's not a
# mirrored +/-90 split). Re-sweep if the rest pose or bone rolls change.
POLE_ANGLE_ARM = -1.5707963267948966   # -90 degrees
POLE_ANGLE_LEG = 1.5707963267948966    # +90 degrees


def add_ik(blend_path):
    bpy.ops.wm.open_mainfile(filepath=blend_path)
    rig_obj = bpy.data.objects["Rig"]
    bpy.context.view_layer.objects.active = rig_obj

    bpy.ops.object.mode_set(mode="EDIT")
    eb = rig_obj.data.edit_bones

    for side in SIDES:
        hand = eb[f"hand.{side}"]
        hand_ik = eb.new(f"hand_ik.{side}")
        hand_ik.head, hand_ik.tail, hand_ik.roll = hand.head.copy(), hand.tail.copy(), hand.roll
        hand_ik.parent = None

        elbow = eb[f"upperarm.{side}"].tail.copy()
        hand_pole = eb.new(f"hand_pole.{side}")
        hand_pole.head = elbow + Vector((0.0, POLE_FORWARD, 0.0))
        hand_pole.tail = hand_pole.head + Vector((0.0, 0.0, 0.05))
        hand_pole.parent = None

        foot = eb[f"foot.{side}"]
        foot_ik = eb.new(f"foot_ik.{side}")
        foot_ik.head, foot_ik.tail, foot_ik.roll = foot.head.copy(), foot.tail.copy(), foot.roll
        foot_ik.parent = None

        knee = eb[f"thigh.{side}"].tail.copy()
        foot_pole = eb.new(f"foot_pole.{side}")
        foot_pole.head = knee + Vector((0.0, POLE_FORWARD, 0.0))
        foot_pole.tail = foot_pole.head + Vector((0.0, 0.0, 0.05))
        foot_pole.parent = None

    bpy.ops.object.mode_set(mode="OBJECT")

    for prop in ("ik_arm_L", "ik_arm_R", "ik_leg_L", "ik_leg_R"):
        rig_obj[prop] = 0.0
        # id_properties_ui exists on the object in 4.x for min/max/soft range
        # so the property shows as a 0..1 slider rather than a bare float.
        ui = rig_obj.id_properties_ui(prop)
        ui.update(min=0.0, max=1.0, soft_min=0.0, soft_max=1.0, default=0.0)

    def drive_influence(constraint, prop_name):
        fcurve = constraint.driver_add("influence")
        driver = fcurve.driver
        driver.type = "AVERAGE"
        var = driver.variables.new()
        var.name = "ik"
        var.type = "SINGLE_PROP"
        target = var.targets[0]
        target.id_type = "OBJECT"
        target.id = rig_obj
        target.data_path = f'["{prop_name}"]'

    def setup_chain(tip_bone, chain_bone, ik_target, pole_target, prop_name, pole_angle):
        ik = rig_obj.pose.bones[chain_bone].constraints.new("IK")
        ik.target = rig_obj
        ik.subtarget = ik_target
        ik.chain_count = 2
        ik.pole_target = rig_obj
        ik.pole_subtarget = pole_target
        ik.pole_angle = pole_angle
        ik.influence = 0.0
        drive_influence(ik, prop_name)

        cr = rig_obj.pose.bones[tip_bone].constraints.new("COPY_ROTATION")
        cr.target = rig_obj
        cr.subtarget = ik_target
        cr.influence = 0.0
        drive_influence(cr, prop_name)

    for side in SIDES:
        setup_chain(f"hand.{side}", f"lowerarm.{side}",
                    f"hand_ik.{side}", f"hand_pole.{side}", f"ik_arm_{side}",
                    POLE_ANGLE_ARM)
        setup_chain(f"foot.{side}", f"shin.{side}",
                    f"foot_ik.{side}", f"foot_pole.{side}", f"ik_leg_{side}",
                    POLE_ANGLE_LEG)

    bpy.ops.wm.save_mainfile(filepath=blend_path)
    print(f"[add_ik_controls] saved {blend_path} with IK controls "
          f"(ik_arm_L/R, ik_leg_L/R default 0.0 — pure FK, unchanged playback)")


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if "--blend" not in argv:
        raise SystemExit("usage: blender -b -P tools/add_ik_controls.py -- --blend <path.blend>")
    add_ik(os.path.abspath(argv[argv.index("--blend") + 1]))


main()
