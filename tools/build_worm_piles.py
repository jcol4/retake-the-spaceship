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

EVERY ACTION, NOT THE ACTIVE ONE. The phase-shifted copies are made for all of
the worm's actions, named `<action>.pileNN`, and `render_sprites.py` hands each
instance the copy matching the pose it is rendering (it finds them by the
`pile_index` property this script writes). Copying only the action that happened
to be active when the file was built was the earlier bug, and it was invisible in
the output: the pile's `walk` sheet rendered a pile of worms playing `worm idle`,
because that was what the instances carried and the renderer only ever spoke to
the Empty. Correct file names, correct frame counts, wrong animation.

ONE DIRECTION, NOT SIXTEEN. Every instance takes the template's rest yaw
unchanged, so the worms lie parallel. Randomising each worm's yaw -- which this
script used to do -- gives a starburst that reads as debris: with the bodies
crossing at every angle there is no shared line for the eye to follow, and the
pile looks the same coming and going. Parallel bodies moving out of phase read as
one animal instead, and the mass gains a front, which is what a unit that walks
at you needs. The cost is that the heap can no longer be a disc: sixteen parallel
half-metre worms on a 0.52 m disc are one bundle, so placement spreads them
ACROSS the shared axis and keeps them close along it (see SPREAD_ACROSS).
"""

import math
import os
import random
import sys

import bpy

SRC_ARMATURE = "Armature"
PILE_EMPTY = "WormPile"

# Written on every instance and read by `render_sprites.py` to find that
# instance's copy of the action it is about to render. Keep in step with
# `PILE_INDEX_PROP` there.
PILE_INDEX_PROP = "pile_index"

# name, worms, spread radius (m), mound height (m)
#
# Counts are each tier's TOP, matching `WormUnit.TIER_FLOOR`: the sheet is drawn
# at the tier's largest and `unit_visual` scales it DOWN across the tier's range
# (TIER_MIN_SCALE). Drawing the largest is deliberate -- scaling a detailed pile
# down reads fine, scaling a sparse one up does not.
#
# Radius and height are metres in the worm's own .blend, which is authored to
# real scale (the worm is 0.5 m long). A 1.5 m tile is the budget. The radius is
# no longer a disc's, though: SPREAD_ACROSS and SPREAD_ALONG read it as an
# ellipse, so the Tide's 0.52 m becomes 0.99 m across the bodies by 1.12 m along
# them once a worm's own length is counted.
PILES = [
    ("clutch", 5, 0.22, 0.10),
    ("knot", 9, 0.36, 0.17),
    ("tide", 16, 0.52, 0.26),
]

# The spread radius above, read as an ELLIPSE: stretched ACROSS the worms' shared
# axis and squashed ALONG it. Parallel bodies need their room side by side, not
# end to end -- the worm is 0.5 m long and 0.06 m wide, so it is its own
# longitudinal spread already, and scattering along the axis only pulls the ends
# out into a frayed streak. Across the axis is where one worm can be told from
# its neighbour.
#
# TUNED BY EYE, against the one word the pile has to earn: mass. The first pair
# tried was 1.35 / 0.45, which gave the Tide 1.40 m across for 16 bodies -- 0.09 m
# apart, comfortably more than the 0.06 m each one occupies, and the sheet came
# out a picket fence of separately legible worms rather than a heap. Closing it to
# 0.99 m puts the spacing just under a body width, so neighbours overlap and the
# silhouette closes up into one writhing thing you can still count worms in.
#
# The footprint stays inside the 1.5 m tile: 0.99 m across by 1.12 m along (0.5 m
# of worm plus 0.62 m of scatter), against the 1.54 m disc the random-yaw version
# drew.
SPREAD_ACROSS = 0.95
SPREAD_ALONG = 0.60

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


def action_period(action):
    """Frames one loop of `action` lasts.

    `end - start`, not the key count: a 24-key cycle keyed 1..24 holds the same
    pose at both ends, so its period is 23. `render_sprites.sample_frames` drops
    the duplicate for the same reason, and offsets drawn against the wrong
    number quietly bunch two instances onto the same drawing.
    """
    start, end = action.frame_range
    return max(1.0, end - start)


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


def pile_action_name(base, index):
    """The name `render_sprites.py` looks an instance's copy up by.

    A contract between two files, so it lives in one function rather than in two
    format strings.
    """
    return "%s.pile%02d" % (base, index)


def match_slot(action, slot_name):
    """The slot in `action` named `slot_name`, or its only slot, or None.

    A slotted action's fcurves hang off a SLOT, and assigning the action without
    pointing `action_slot` at one plays nothing at all -- the rig just holds its
    rest pose, on every frame, with no error. Copies carry their own slots, so
    the source's slot has to be matched by name rather than reused.
    """
    slots = list(getattr(action, "slots", []))
    if not slots:
        return None
    for slot in slots:
        if slot.name_display == slot_name:
            return slot
    return slots[0] if len(slots) == 1 else None


def phase_offset(index, count, period, rng):
    """Where in the cycle instance `index` sits.

    STRATIFIED, not uniform random: `index / count` of the way through, jittered
    inside its own slice. Plain `rng.uniform(0, period)` is what this used to do
    and at these counts it clumps -- draw 16 numbers out of 23 frames and several
    land within a frame of each other, which puts identical worms side by side,
    the exact artefact the phase shift exists to prevent. Slices guarantee a
    16-worm Tide covers the thrash at ~1.4-frame spacing; the jitter keeps the
    result from looking counted.
    """
    slice_width = period / count
    return (index + rng.uniform(0.2, 0.8)) * slice_width


def horizontal_points(arm, depsgraph):
    """World-space vertices of everything skinned to `arm`, as evaluated now."""
    points = []
    for child in arm.children:
        if child.type != "MESH":
            continue
        evaluated = child.evaluated_get(depsgraph)
        mesh = evaluated.to_mesh()
        matrix = evaluated.matrix_world
        points.extend(matrix @ v.co for v in mesh.vertices)
        evaluated.to_mesh_clear()
    return points


def measure_body(arm):
    """(yaw radians, centre across, centre along) of one worm, in world space.

    MEASURED rather than written down, because all three are facts about the
    template's rest orientation -- the rig lies ~93 degrees about X with a 20.2
    degree yaw -- and constants here would be a second copy of that to keep in
    step.

    Yaw is the principal axis of the horizontal vertex cloud; the worm is 0.5 m
    long and 0.06 m wide, so the axis is unambiguous. The centre is the middle of
    the BOUNDING BOX in that axis's frame, not the vertex centroid: the worm
    tapers from a spiked head to a thin tail, so its centroid sits well inside
    the thick end, and centring a pile on centroids leaves the silhouette 0.08 m
    (about 8 px of a 256 px sheet) off the Empty.

    Which matters because the Empty is what the renderer spins. Off-centre, the
    mass does not turn, it orbits -- 15 px of sideways drift between opposite
    facings, read as a unit skidding about its own feet. Random yaws used to hide
    this by averaging the bodies' offsets away; parallel ones do not.

    Measured across the ACTION, not on one frame, because the frame the file
    happened to be saved on is not a property of the worm. A thrash is roughly
    symmetric over its cycle, so the mean box centre is the centre of the motion
    rather than of a moment in it.
    """
    scene = bpy.context.scene
    original_frame = scene.frame_current

    action = arm.animation_data.action if arm.animation_data else None
    if action is None:
        frames = [original_frame]
    else:
        start, end = action.frame_range
        frames = [int(round(start)) + i for i in range(max(1, int(round(end - start))))]

    clouds = []
    for frame in frames:
        scene.frame_set(frame)
        cloud = horizontal_points(arm, bpy.context.evaluated_depsgraph_get())
        if cloud:
            clouds.append(cloud)
    scene.frame_set(original_frame)

    if not clouds:
        sys.exit("[build_worm_piles] %r has no mesh children to measure" % arm.name)

    # The axis comes off every frame at once, so it is the axis of the whole
    # motion and not of whichever one was sampled first.
    every = [p for cloud in clouds for p in cloud]
    n = len(every)
    cx = sum(p.x for p in every) / n
    cy = sum(p.y for p in every) / n
    sxx = sum((p.x - cx) ** 2 for p in every) / n
    syy = sum((p.y - cy) ** 2 for p in every) / n
    sxy = sum((p.x - cx) * (p.y - cy) for p in every) / n
    theta = 0.5 * math.atan2(2.0 * sxy, sxx - syy)

    def projected(points, angle):
        """(across, along) of `points` about an axis at `angle`."""
        ax, ay = math.cos(angle), math.sin(angle)
        return ([-p.x * ay + p.y * ax for p in points],
                [p.x * ax + p.y * ay for p in points])

    # The covariance gives the axis but not which of the two perpendiculars it
    # is; pick the one the body is actually longer along.
    across, along = projected(every, theta)
    if max(along) - min(along) < max(across) - min(across):
        theta += math.pi / 2.0

    mid_across = 0.0
    mid_along = 0.0
    for cloud in clouds:
        across, along = projected(cloud, theta)
        mid_across += (min(across) + max(across)) / 2.0
        mid_along += (min(along) + max(along)) / 2.0
    return theta, mid_across / len(clouds), mid_along / len(clouds)


def copy_rig(src_arm, index, count, rng):
    """One worm: a copy of the armature plus its skinned meshes.

    Object data is SHARED (only the object wrappers are copied), so sixteen
    worms cost one mesh and one armature in the file. Pose and animation are
    per-object, which is exactly the split this needs.

    The armature gets a phase-shifted copy of EVERY action in the file, each at
    the same point in its own cycle, so a worm keeps its place in the mass
    whichever pose is being rendered.
    """
    arm = src_arm.copy()
    arm[PILE_INDEX_PROP] = index
    arm.animation_data_create()

    src_slot_name = None
    src_action = None
    if src_arm.animation_data is not None:
        src_action = src_arm.animation_data.action
        src_slot = getattr(src_arm.animation_data, "action_slot", None)
        if src_slot is not None:
            src_slot_name = src_slot.name_display

    # One shift FRACTION per instance, applied to each action against its own
    # period, rather than a fresh offset per action: the fraction is this worm's
    # identity in the mass, and a worm that jumped to a different place in the
    # queue between idle and walk would pop on the pose change.
    bases = sorted(a.name for a in bpy.data.actions if ".pile" not in a.name)
    for base in bases:
        source = bpy.data.actions[base]
        act = source.copy()
        want = pile_action_name(base, index)
        act.name = want
        # Or the save drops it. Only the ONE copy assigned below has a user, and
        # Blender does not write datablocks nothing points at -- so without this
        # the file comes back holding the idle copies and nothing else, and the
        # renderer's lookup fails on the first pose that is not idle. Which is
        # the good version of that failure: it used to render silently.
        act.use_fake_user = True
        if act.name != want:
            sys.exit("[build_worm_piles] Blender renamed %r to %r -- "
                     "render_sprites looks these copies up by name, so a rename "
                     "means the instance silently plays the unshifted action"
                     % (want, act.name))
        shift_action(act, phase_offset(index, count, action_period(source), rng))

    # Whatever the template had open, so opening the pile in Blender shows
    # something moving. The renderer reassigns per pose regardless.
    if src_action is not None:
        active = bpy.data.actions.get(pile_action_name(src_action.name, index))
        if active is not None:
            arm.animation_data.action = active
            slot = match_slot(active, src_slot_name)
            if slot is not None:
                arm.animation_data.action_slot = slot

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


def build(name, count, radius, height, src_arm):
    rng = random.Random(SEED + count)

    yaw, body_across, body_along = measure_body(src_arm)
    # Unit vectors along the worms and across them, in the Empty's space (the
    # Empty sits at the origin unrotated while the pile is built, so its space
    # and the world's are the same here).
    along = (math.cos(yaw), math.sin(yaw))
    across = (-math.sin(yaw), math.cos(yaw))
    print("[build_worm_piles] %s: bodies lie along %.1f deg, one body's centre "
          "sits (%.3f across, %.3f along) m off its origin -- placement is "
          "measured from these"
          % (name, math.degrees(yaw), body_across, body_along))

    empty = bpy.data.objects.new(PILE_EMPTY, None)
    empty.empty_display_type = "PLAIN_AXES"
    empty.empty_display_size = 0.3
    bpy.context.scene.collection.objects.link(empty)

    # Placed first, in the (across, along, up) frame, so the whole set can be
    # recentred before anything is committed to an object.
    slots = []
    for i in range(count):
        # Golden-angle spiral, so the heap fills evenly instead of clumping the
        # way plain random placement does at these small counts. The angle is
        # then read into an ELLIPSE -- wide across the bodies, narrow along them
        # -- which is what keeps parallel worms side by side rather than nose to
        # tail (SPREAD_ACROSS).
        theta = i * 2.39996
        t = math.sqrt((i + 0.5) / count)
        r = radius * t
        jitter = radius * 0.12
        lateral = math.cos(theta) * r * SPREAD_ACROSS + rng.uniform(-jitter, jitter)
        axial = (math.sin(theta) * r + rng.uniform(-jitter, jitter)) * SPREAD_ALONG
        # Worms nearer the middle ride higher: a mound, not a puddle. Driven off
        # `t` rather than the stretched offsets, so the mound stays even.
        slots.append((lateral, axial, height * (1.0 - t) * rng.uniform(0.45, 1.0)))

    # RECENTRED on the Empty, which is the point the renderer spins the pile
    # about. A spiral truncated at 5, 9 or 16 points does not average to its own
    # centre -- the Tide's landed 0.11 m off -- and an off-centre mass does not
    # turn, it orbits: the heap slides across the canvas from facing to facing
    # and the unit looks like it is being dragged around its own feet. Harmless
    # while the yaws were random and the bodies filled a disc; visible the moment
    # they line up. The body's own offset from its armature origin (cx, cy) comes
    # off here too, for the same reason and in the same step -- which is why both
    # corrections are done in the (across, along) frame rather than in world XY.
    mean_lateral = sum(s[0] for s in slots) / count + body_across
    mean_axial = sum(s[1] for s in slots) / count + body_along

    for i, (lateral, axial, z) in enumerate(slots):
        arm = copy_rig(src_arm, i, count, rng)
        lateral -= mean_lateral
        axial -= mean_axial
        x = across[0] * lateral + along[0] * axial
        y = across[1] * lateral + along[1] * axial

        arm.location = (x, y, z)
        # The template's rest yaw, UNCHANGED, on every instance: the worms lie
        # parallel and the mass has a front (see the module docstring). Nothing
        # here may touch X or Y either -- the rig already lies ~93 degrees about
        # X (the bone chain was built upright and laid flat), and the renderer
        # writes Z on the PARENT only, so tilting an instance would stand a worm
        # on end.
        arm.rotation_euler = src_arm.rotation_euler.copy()
        arm.parent = empty

    # The originals are the template, not part of the pile.
    for obj in list(src_arm.children) + [src_arm]:
        bpy.data.objects.remove(obj, do_unlink=True)

    out = os.path.join("art_src", "worm_pile_%s.blend" % name)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(out), copy=True)
    shifted = len([a for a in bpy.data.actions if ".pile" in a.name])
    print("[build_worm_piles] wrote %s (%d worms, %.2f m across x %.2f m along, "
          "h=%.2f m, %d phase-shifted actions)"
          % (out, count, radius * 2 * SPREAD_ACROSS, radius * 2 * SPREAD_ALONG,
             height, shifted))


def main():
    src_arm = bpy.data.objects.get(SRC_ARMATURE)
    if src_arm is None:
        sys.exit("[build_worm_piles] no object named %r in this .blend" % SRC_ARMATURE)
    if not bpy.data.actions:
        sys.exit("[build_worm_piles] this .blend carries no actions to phase-shift")

    # Each pile is built from a FRESH read of the template, because building one
    # deletes the original rig out of the scene.
    source = bpy.data.filepath
    for name, count, radius, height in PILES:
        bpy.ops.wm.open_mainfile(filepath=source)
        src = bpy.data.objects.get(SRC_ARMATURE)
        build(name, count, radius, height, src)


main()
