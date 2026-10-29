"""Builds the civilian's `run` from the merc's, with empty hands.

    blender.exe -b assets/civilian_cleaned.blend -P tools/build_civilian_run.py

The civilian is skinned to the same rig as the merc (identical bone names and
rest pose), so the merc's `run` drives its legs, hips and torso unchanged. What
does NOT carry over is the arms: the merc's hands are keyed onto a rifle, and
without the rifle they hover in front of the chest holding nothing.

So the arm channels are dropped and re-keyed as an unarmed run -- elbows bent,
hands pumping along the sides, each arm swinging opposite its own leg. The
phase is read off the feet frame by frame rather than restated, so it stays in
step with the legs whatever the merc's run does.

Also sets the armature to the merc's object scale (merc_anim.blend's Armature
is 0.683), so the civilian stands at merc height in game.

Writes the .blend in place (Blender keeps the previous save as .blend1).
Re-runnable: an existing `run` is replaced.
"""

import bpy
from mathutils import Matrix, Quaternion, Vector

MERC_BLEND = "art_src/merc_anim.blend"
ACTION = "run"
MERC_SCALE = 0.683

## Channels the merc's run spends on holding the rifle. Everything else (legs,
## hips, spine, head, fingers) is kept as authored.
ARM_BONES = [
    "IK-hand.L", "IK-hand.R", "TARGET-arm.L", "TARGET-arm.R",
    "hand.L", "hand.R", "arm.L", "arm.R", "forearm.L", "forearm.R",
    "clav.L", "clav.R", "weapon",
]

# Hand path relative to its own shoulder, in armature space (rest units, before
# MERC_SCALE; the rig faces -Y, +X is the character's left). `s` is the swing:
# +1 fully forward, -1 fully back.
SWING_FORWARD = 0.30   # -Y reach either side of neutral
HAND_DROP = 0.60       # below the shoulder at neutral
SWING_LIFT = 0.12      # forward hands ride higher, back hands lower
# Sideways, the hand is placed off the body's centre line rather than the
# shoulder: the rifle run twists the chest, and a shoulder-relative hand would
# follow that twist straight across the torso.
HAND_SIDE = 0.32       # clear of the hips at the back of the swing
HAND_IN = 0.06         # tucked slightly inward at the front
## Torso bones whose stride oscillation is damped, and how much of it is kept.
TORSO_BONES = ["hip", "spine_1", "chest"]
TORSO_KEEP = 0.4
# Elbow pole, relative to the shoulder: behind and a little out, so the elbows
# trail the body the way a runner's do.
POLE = Vector((0.15, 0.70, -0.35))


def append_run():
    old = bpy.data.actions.get(ACTION)
    if old is not None:
        bpy.data.actions.remove(old)
    with bpy.data.libraries.load(bpy.path.abspath("//../" + MERC_BLEND), link=False) as (_src, dst):
        dst.actions = [ACTION]
    action = dst.actions[0]
    action.name = ACTION
    action.use_fake_user = True
    return action


def strip_channels(action):
    """Drops the rifle-holding arm channels and every object-level curve (the
    merc's run keys the armature's own rotation and the gun Empty's)."""
    prefixes = tuple('pose.bones["%s"].' % b for b in ARM_BONES)
    for layer in action.layers:
        for strip in layer.strips:
            for bag in list(strip.channelbags):
                if bag.slot.identifier != "OBArmature":
                    strip.channelbags.remove(bag)
                    continue
                for fc in list(bag.fcurves):
                    if fc.data_path.startswith(prefixes) or not fc.data_path.startswith("pose.bones"):
                        bag.fcurves.remove(fc)
    for slot in list(action.slots):
        if slot.identifier != "OBArmature":
            action.slots.remove(slot)


def damp_torso(action):
    """Pulls each TORSO_BONES key toward that bone's mean pose by TORSO_KEEP.

    The merc swings his shoulders ~37 degrees a stride to carry the rifle
    across his body; an unarmed runner barely twists, and with the full swing
    the forward hand reads from the front as reaching across the chest. The
    mean is kept, so the forward lean survives -- only the oscillation shrinks.
    """
    bag = next(b for layer in action.layers for strip in layer.strips
               for b in strip.channelbags if b.slot.identifier == "OBArmature")
    for bone in TORSO_BONES:
        path = 'pose.bones["%s"].rotation_quaternion' % bone
        curves = [bag.fcurves.find(path, index=i) for i in range(4)]
        if None in curves:
            continue
        frames = sorted({k.co.x for fc in curves for k in fc.keyframe_points})
        quats = [Quaternion([fc.evaluate(f) for fc in curves]).normalized() for f in frames]
        mean = Quaternion([sum(q[i] for q in quats) / len(quats) for i in range(4)]).normalized()
        for fc in curves:
            fc.keyframe_points.clear()
        for f, q in zip(frames, quats):
            if q.dot(mean) < 0:
                q.negate()
            damped = mean.slerp(q, TORSO_KEEP)
            for i, fc in enumerate(curves):
                fc.keyframe_points.insert(f, damped[i])


def key_arms(arm, action):
    scene = bpy.context.scene
    f0, f1 = (int(v) for v in action.frame_range)
    pb = arm.pose.bones
    bones = arm.data.bones

    # Stride extent, for normalising the swing to [-1, 1].
    strides = []
    for f in range(f0, f1 + 1):
        scene.frame_set(f)
        strides.append(pb["foot.L"].head.y - pb["foot.R"].head.y)
    reach = max(abs(d) for d in strides) or 1.0

    for f, stride in zip(range(f0, f1 + 1), strides):
        scene.frame_set(f)
        # Left foot forward (-Y) -> left arm back.
        swing = {"L": stride / reach, "R": -stride / reach}
        for side, sign in (("L", 1.0), ("R", -1.0)):
            s = swing[side]
            shoulder = pb["arm." + side].head.copy()
            target = Vector((
                sign * (HAND_SIDE - HAND_IN * max(s, 0.0)),
                shoulder.y - SWING_FORWARD * s - 0.05,
                shoulder.z - HAND_DROP + SWING_LIFT * s,
            ))
            pole = shoulder + Vector((sign * POLE.x, POLE.y, POLE.z))

            ik = pb["IK-hand." + side]
            tgt = pb["TARGET-arm." + side]
            tgt.matrix = Matrix.Translation(pole) @ bones[tgt.name].matrix_local.to_3x3().to_4x4()
            ik.matrix = Matrix.Translation(target) @ bones[ik.name].matrix_local.to_3x3().to_4x4()
            bpy.context.view_layer.update()

            # The hand keeps its rest relation to the forearm -- a straight
            # wrist -- once the IK has bent the elbow.
            fore = pb["forearm." + side]
            fore_rest = bones[fore.name].matrix_local
            hand_rest = bones["hand." + side].matrix_local
            hand = fore.matrix @ fore_rest.inverted() @ hand_rest
            ik_m = hand @ hand_rest.inverted() @ bones[ik.name].matrix_local
            ik_m.translation = target
            ik.matrix = ik_m
            bpy.context.view_layer.update()

            for bone in (ik, tgt):
                bone.keyframe_insert("location", frame=f)
                bone.keyframe_insert("rotation_quaternion", frame=f)


def main():
    arm = bpy.data.objects["Armature"]
    arm.scale = (MERC_SCALE,) * 3
    action = append_run()
    strip_channels(action)
    damp_torso(action)
    arm.animation_data_create()
    arm.animation_data.action = action
    arm.animation_data.action_slot = action.slots[0]
    for name in ARM_BONES:
        pose_bone = arm.pose.bones.get(name)
        if pose_bone is not None:
            pose_bone.location = (0, 0, 0)
            pose_bone.rotation_quaternion = (1, 0, 0, 0)
            pose_bone.scale = (1, 1, 1)
    key_arms(arm, action)
    # Back on the idle, so the file opens standing.
    idle = bpy.data.actions.get("idle")
    if idle is not None:
        arm.animation_data.action = idle
        arm.animation_data.action_slot = idle.slots[0]
    bpy.ops.wm.save_mainfile()
    print("[build_civilian_run] keyed %s, frames %d-%d" % (ACTION, *action.frame_range))


main()
