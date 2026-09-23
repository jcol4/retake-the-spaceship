"""Builds the worm-mass .blend files by instancing the single worm into a heap.

    blender.exe -b art_src/worm_anims.blend -P tools/build_worm_piles.py

Writes art_src/worm_pile_clutch.blend, _knot.blend and _tide.blend, then each is
rendered exactly like any other character:

    blender.exe -b art_src/worm_pile_tide.blend -P tools/render_sprites.py -- \
        --variant worm_tide --character WormPile --poses idle,walk

WHY INSTANCE THE WORM INSTEAD OF SCULPTING A PILE. The mechanic is that a mass
IS its worms -- `WormUnit.worm_count()` is `ceil(hp / 5)`, damage removes whole
worms, and the sprite is meant to be a picture of exactly that. A sculpted mound
would be a second asset that has to be kept looking like a number it does not
contain. Instancing also inherits the thing that was expensive to get right the
first time: `VARIANT_BUCKET_ZERO["worm"]` (20.2 degrees) is a measured fact about
this armature's odd rest orientation, and copies of that armature need no new
measurement.

THE PILE IS ONE OBJECT TO THE RENDERER. `render_sprites.py` turns a single
`--character` through eight buckets and assigns the pose's action to it. So every
instance is parented to one Empty named `WormPile`, and that Empty is what turns.
The action the renderer assigns to the Empty does nothing (its channels name
bones the Empty does not have) -- each instance carries its own copy, which is
what lets them be out of phase.

OUT OF PHASE IS THE WHOLE POINT. Sixteen worms sharing one action is sixteen
copies of a single drawing, which reads as a rock. Each instance therefore gets
a COPY of the action with its keyframes shifted and a Cycles modifier added, so
at any scene frame every worm is at a different point in the same thrash. That is
the difference between a pile that writhes and a pile that sits.
"""

import math
import os
import random
import sys

import bpy

SRC_ARMATURE = "Armature"
PILE_EMPTY = "WormPile"

# name, worms, spread radius (m), mound height (m)
#
# Counts are each tier's TOP, matching `WormUnit.TIER_FLOOR`: the sheet is drawn
# at the tier's largest and `unit_visual` scales it DOWN across the tier's range
# (TIER_MIN_SCALE). Drawing the largest is deliberate -- scaling a detailed pile
# down reads fine, scaling a sparse one up does not.
#
# Radius and height are metres in the worm's own .blend, which is authored to
# real scale (the worm is 0.5 m long). A 1.5 m tile is the budget; the Tide's
# 0.52 m spread keeps a 0.5 m worm's ends inside it.
PILES = [
    ("clutch", 5, 0.22, 0.10),
    ("knot", 9, 0.36, 0.17),
    ("tide", 16, 0.52, 0.26),
]

# Fixed, so a re-run reproduces the same pile rather than reshuffling art that
# has already been judged on screen.
SEED = 20260922


def fcurves_of(action):
    """Every F-curve in `action`, across Blender's two action layouts.

    Blender 4.4 moved actions to layers/strips/channelbags ("slotted actions")
    and dropped `action.fcurves`. Both are handled because the .blend decides
    which one exists, not the script.
    """
    if hasattr(action, "fcurves"):
        return list(action.fcurves)
    out = []
    for layer in getattr(action, "layers", []):
        for strip in getattr(layer, "strips", []):
            for bag in getattr(strip, "channelbags", []):
                out.extend(bag.fcurves)
    return out


def shift_action(action, offset):
    """Slides every key by `offset` frames and makes the result loop forever.

    The Cycles modifier is what keeps a shifted action from running out: the
    renderer samples the ORIGINAL action's frame range, and an instance shifted
    +9 frames would otherwise hold its last pose for the tail of every cycle.
    """
    for fcurve in fcurves_of(action):
        for key in fcurve.keyframe_points:
            key.co.x += offset
            key.handle_left.x += offset
            key.handle_right.x += offset
        if not any(m.type == "CYCLES" for m in fcurve.modifiers):
            fcurve.modifiers.new("CYCLES")
        fcurve.update()


def copy_rig(src_arm, index):
    """One worm: a copy of the armature plus its skinned meshes.

    Object data is SHARED (only the object wrappers are copied), so sixteen
    worms cost one mesh and one armature in the file. Pose and animation are
    per-object, which is exactly the split this needs.
    """
    arm = src_arm.copy()
    if src_arm.animation_data and src_arm.animation_data.action:
        arm.animation_data_create()
        act = src_arm.animation_data.action.copy()
        act.name = "%s.pile%02d" % (src_arm.animation_data.action.name, index)
        arm.animation_data.action = act
        # Slotted actions need the slot re-pointed as well as the action; the
        # copy carries its own slots, so match the source's by name.
        src_slot = getattr(src_arm.animation_data, "action_slot", None)
        if src_slot is not None:
            for slot in getattr(act, "slots", []):
                if slot.name_display == src_slot.name_display:
                    arm.animation_data.action_slot = slot
                    break
    bpy.context.scene.collection.objects.link(arm)

    for child in src_arm.children:
        if child.type != "MESH":
            continue
        mesh = child.copy()
        # Its own animation, if it had any, would re-drive the shared data.
        if mesh.animation_data:
            mesh.animation_data_clear()
        bpy.context.scene.collection.objects.link(mesh)
        mesh.parent = arm
        mesh.matrix_parent_inverse = child.matrix_parent_inverse.copy()
        for modifier in mesh.modifiers:
            # Repoint EVERY armature modifier, including the ones left pointing
            # at nothing: an unrepointed one binds the copy to the original rig
            # and every instance collapses onto the same pose.
            if modifier.type == "ARMATURE":
                modifier.object = arm if modifier.object is not None else None
        for modifier in mesh.modifiers:
            if modifier.type == "ARMATURE" and modifier.object is src_arm:
                modifier.object = arm
    return arm


def build(name, count, radius, height, src_arm, action_len):
    rng = random.Random(SEED + count)

    empty = bpy.data.objects.new(PILE_EMPTY, None)
    empty.empty_display_type = "PLAIN_AXES"
    empty.empty_display_size = 0.3
    bpy.context.scene.collection.objects.link(empty)

    for i in range(count):
        arm = copy_rig(src_arm, i)

        # Golden-angle spiral, so the heap fills evenly instead of clumping the
        # way plain random placement does at these small counts.
        theta = i * 2.39996
        r = radius * math.sqrt((i + 0.5) / count)
        jitter = radius * 0.12
        x = math.cos(theta) * r + rng.uniform(-jitter, jitter)
        y = math.sin(theta) * r + rng.uniform(-jitter, jitter)
        # Worms nearer the middle ride higher: a mound, not a puddle.
        z = height * (1.0 - r / radius) * rng.uniform(0.45, 1.0)

        arm.location = (x, y, z)
        # Only Z is randomised. The rig already lies ~93 degrees about X (the
        # bone chain was built upright and laid flat), and the renderer writes Z
        # on the PARENT only -- so tilting an instance about X or Y here would
        # stand a worm on end.
        arm.rotation_euler = (
            src_arm.rotation_euler.x,
            src_arm.rotation_euler.y,
            src_arm.rotation_euler.z + rng.uniform(-math.pi, math.pi),
        )
        arm.parent = empty

        if arm.animation_data and arm.animation_data.action:
            shift_action(arm.animation_data.action, rng.uniform(0, action_len))

    # The originals are the template, not part of the pile.
    for obj in list(src_arm.children) + [src_arm]:
        bpy.data.objects.remove(obj, do_unlink=True)

    out = os.path.join("art_src", "worm_pile_%s.blend" % name)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(out), copy=True)
    print("[build_worm_piles] wrote %s (%d worms, r=%.2f m, h=%.2f m)"
          % (out, count, radius, height))


def main():
    src_arm = bpy.data.objects.get(SRC_ARMATURE)
    if src_arm is None:
        sys.exit("[build_worm_piles] no object named %r in this .blend" % SRC_ARMATURE)

    action = src_arm.animation_data.action if src_arm.animation_data else None
    if action is None:
        sys.exit("[build_worm_piles] %r carries no action to phase-shift" % SRC_ARMATURE)
    action_len = max(1.0, action.frame_range[1] - action.frame_range[0])

    # Each pile is built from a FRESH read of the template, because building one
    # deletes the original rig out of the scene.
    source = bpy.data.filepath
    for name, count, radius, height in PILES:
        bpy.ops.wm.open_mainfile(filepath=source)
        src = bpy.data.objects.get(SRC_ARMATURE)
        build(name, count, radius, height, src, action_len)


main()
