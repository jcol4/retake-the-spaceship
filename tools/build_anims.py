"""Merge Mixamo animation FBX files onto one rigged character, export one GLB.

Mixamo hands out one FBX per clip, each carrying its own copy of the skeleton.
Godot wants a single scene with a single AnimationPlayer holding every clip. This
script is the bridge: import the skinned character once, then for each animation
FBX lift its action onto the character's armature and throw the duplicate
skeleton away.

Bone names are normalised by stripping Mixamo's "mixamorig:" prefix. The colon is
the reason: Godot animation track paths are themselves colon-delimited
("Skeleton3D:BoneName"), so a colon inside a bone name is asking for trouble.
Stripping it also gives clean NodePaths for BoneAttachment3D ("RightHand").

Clip names come from CLIP_MAP, which is the single place Mixamo's catalogue
vocabulary meets the game's clip names in unit_visual.gd. Re-sourcing a clip is a
one-line change here and nothing downstream notices.

Source FBX lives in art_src/, which carries a .gdignore so Godot's resource
scanner never sees it: the character FBX alone is 142 MB, and letting Godot
import build inputs it will never load at runtime wastes a lot of disk. Only the
exported GLB belongs under assets/.

Run headless:
    blender -b -P tools/build_anims.py -- --inspect
    blender -b -P tools/build_anims.py -- --character art_src/T-Pose.fbx \
        --anims art_src/anims --export assets/soldier_mixamo.glb
"""

import argparse
import glob
import math
import os
import re
import sys

import bpy
from mathutils import Quaternion, Vector

# Mixamo is not consistent about this: most clips use "mixamorig:", but some
# downloads come back as "mixamorig1:" (and higher). Matching the digits matters
# -- "mixamorig:" is not a substring of "mixamorig1:", so a plain string strip
# silently leaves those bones prefixed, and every track in the clip then points
# at a bone the character does not have. The clip imports, exports and plays,
# and moves nothing.
MIXAMO_PREFIX = re.compile(r"mixamorig\d*:")

# Mixamo catalogue name (the FBX filename, sans extension) -> game clip name.
# The game side lives in scripts/unit_visual.gd; keep the right column matching
# the constants there.
#
# Keys are matched loosely -- case, spacing and punctuation are normalised -- so
# "Rifle Run To Stop.fbx", "rifle_run_to_stop.fbx" and "Rifle Run To Stop (1).fbx"
# all land on the same entry. Anything unmatched is reported with the exact key
# to paste in, never silently skipped.
#
# Entries below the divider are GUESSES at catalogue names, written ahead of the
# download so the clips work on arrival. A guess that misses costs one log line.
# A value may be a single clip name, a tuple of names (one source serving
# several game clips), or None (present on disk but deliberately unused).
CLIP_MAP = {
    # Stances.
    "Rifle Idle": "idle",
    "Rifle Run In Place": "run",
    "Idle Crouching": "crouch_idle",
    # Mixamo has no overwatch animation, and overwatch IS a held aim, so one
    # source clip serves both.
    "Rifle Aiming Idle": ("aim_hold", "overwatch_hold"),
    # Transitions -- one-shots that bridge one stance into another.
    "Rifle Run To Stop": "run_stop",
    "Stand To Crouch": "stand_to_crouch",
    "Crouch To Standing With Rifle": "crouch_to_stand",
    # Actions.
    "Firing Rifle": "shoot_recoil",
    "Reloading": "reload",
    "Toss Grenade": "throw_grenade",
    "Hit Reaction": "hit_react",
    "Dying": "downed",
    # Superseded by "Rifle Run In Place". Kept on disk as the reference that
    # measured the 4.34 m/s stride (see docs/mixamo-pipeline-plan.md 2.1);
    # mapped to None so it doesn't collide with the in-place version.
    "Rifle Run": None,
}

# NOT YET SOURCED -- no Mixamo clip found, so unit_visual.gd falls back to its
# FALLBACK_TIME timer for these and the unit holds its stance:
#   interact  -- searching a console/terminal
#   melee     -- alien-side attack; no alien rig exists yet either
# Turn clips are also unsourced; see docs/mixamo-pipeline-plan.md 5.3.

# Clips that should loop in Godot. Everything else is a one-shot -- note that
# run_stop is deliberately absent: it is a settle, and looping it would stutter.
LOOPING = {"idle", "run", "aim_hold", "crouch_idle", "overwatch_hold"}


def normalize(name):
    """Fold a filename to a loose match key: lowercase, alphanumerics only."""
    return " ".join("".join(
        c if c.isalnum() else " " for c in name).lower().split())


CLIP_MAP_NORM = {normalize(k): v for k, v in CLIP_MAP.items()}

# Mixamo FBX is authored in centimetres. Blender's importer usually corrects
# this, but "usually" is not good enough to build a pipeline on -- --inspect
# reports the real height so this can be set from measurement, not belief.
TARGET_HEIGHT_M = 1.8
HEIGHT_TOLERANCE = 0.5


def log(msg):
    # Prefixed so the report is greppable out of Blender's own import chatter.
    print(f"[build_anims] {msg}")


def reset_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def import_fbx(path, with_anim):
    """Import one FBX and return the armature object it brought in.

    Import settings must be IDENTICAL for the character and every clip.
    Actions store rotations in bone-local space, so anything that changes bone
    roll (automatic_bone_orientation in particular) silently invalidates a
    transferred action unless both sides were imported the same way.
    """
    before = set(bpy.data.objects)
    bpy.ops.import_scene.fbx(
        filepath=path,
        use_anim=with_anim,
        automatic_bone_orientation=False,
        ignore_leaf_bones=False,
        use_image_search=False,
    )
    new = [o for o in bpy.data.objects if o not in before]
    arms = [o for o in new if o.type == "ARMATURE"]
    if not arms:
        raise RuntimeError(f"no armature in {path}")
    return arms[0], new


def strip_prefix(arm):
    """Drop the 'mixamorig<n>:' prefix from every bone name. Also fixes the
    action's fcurve data paths, which embed the bone name as a string literal."""
    renamed = 0
    for bone in arm.data.bones:
        stripped = MIXAMO_PREFIX.sub("", bone.name, count=1)
        if stripped != bone.name:
            bone.name = stripped
            renamed += 1
    act = arm.animation_data.action if arm.animation_data else None
    if act:
        for fc in act.fcurves:
            fc.data_path = MIXAMO_PREFIX.sub("", fc.data_path)
    return renamed


def describe(arm, extra, label):
    log(f"--- {label} ---")
    log(f"  armature object : {arm.name}")
    log(f"  bones           : {len(arm.data.bones)}")
    names = [b.name for b in arm.data.bones]
    log(f"  first 12 bones  : {names[:12]}")
    log(f"  armature dims   : {tuple(round(v, 4) for v in arm.dimensions)}")
    log(f"  armature scale  : {tuple(round(v, 4) for v in arm.scale)}")
    meshes = [o for o in extra if o.type == "MESH"]
    for m in meshes:
        log(f"  mesh {m.name!r}: verts={len(m.data.vertices)} "
            f"dims={tuple(round(v, 4) for v in m.dimensions)}")
    act = arm.animation_data.action if arm.animation_data else None
    if act:
        fr = act.frame_range
        log(f"  action          : {act.name!r} "
            f"frames={fr[0]:.1f}..{fr[1]:.1f} fcurves={len(act.fcurves)}")
        if act.fcurves:
            log(f"  sample fcurve   : {act.fcurves[0].data_path}")
    else:
        log("  action          : none")


def shrink_textures(max_px):
    """Downscale oversized embedded textures in place.

    Mixamo characters ship 4096-square maps, which is most of a 150 MB GLB for a
    21k-vert body -- and pointless at this game's camera distance. Nothing
    downstream reads these at full resolution, and disk here is tight.
    """
    for img in bpy.data.images:
        w, h = img.size
        if w == 0 or h == 0:
            continue
        if max(w, h) <= max_px:
            log(f"  texture {img.name!r}: {w}x{h} (kept)")
            continue
        scale = max_px / max(w, h)
        new = (max(1, int(w * scale)), max(1, int(h * scale)))
        img.scale(*new)
        log(f"  texture {img.name!r}: {w}x{h} -> {new[0]}x{new[1]}")


# Hips translation channels. The Hips bone points up, so in bone-local space Y
# is vertical bob (keep it -- that IS the weight read) and X/Z are horizontal
# travel. Armature object scale is 0.01, so these values are in centimetres.
HIPS_VERTICAL = 1
HIPS_HORIZONTAL = (0, 2)
ROOT_MOTION_LIMIT_M = 0.05


def root_motion(act, fps):
    """Net horizontal Hips travel over the clip, in metres, and its speed."""
    drift = {}
    for fc in act.fcurves:
        if not (fc.data_path.endswith(".location") and '"Hips"' in fc.data_path):
            continue
        if fc.array_index not in HIPS_HORIZONTAL or not fc.keyframe_points:
            continue
        pts = fc.keyframe_points
        drift[fc.array_index] = (pts[-1].co[1] - pts[0].co[1]) / 100.0
    dist = sum(v * v for v in drift.values()) ** 0.5
    frames = act.frame_range[1] - act.frame_range[0]
    speed = dist / (frames / fps) if frames else 0.0
    return dist, speed


# How --strip-root removes horizontal travel, per clip.
#
#   "linear"  subtract the straight-line trend, keeping intra-cycle sway. Right
#             for cyclic locomotion, where forward speed is roughly constant so
#             a straight line is a good model of the travel.
#   "hold"    pin the channel to its first value. Right for a one-shot that ends
#             stationary: a deceleration travels fast-then-slow, and subtracting
#             a straight line from that curve leaves the body drifting forward
#             early and backward late -- a visible slide in both directions.
#   "none"    leave the travel alone. Right where the displacement IS the
#             animation and it stays within a tile.
STRIP_MODE = {
    "run_stop": "hold",
    "downed": "none",  # a body falling forward should travel; 0.34m is in-tile
}
DEFAULT_STRIP_MODE = "linear"


def strip_root_motion(act, mode):
    """Remove horizontal Hips travel according to `mode` (see STRIP_MODE)."""
    if mode == "none":
        return
    for fc in act.fcurves:
        if not (fc.data_path.endswith(".location") and '"Hips"' in fc.data_path):
            continue
        if fc.array_index not in HIPS_HORIZONTAL or len(fc.keyframe_points) < 2:
            continue
        pts = fc.keyframe_points
        f0, v0 = pts[0].co
        f1, v1 = pts[-1].co
        if f1 == f0:
            continue
        # "hold" is just "linear" with the trend replaced by a flat line at the
        # starting value, so the two share one loop.
        slope = 0.0 if mode == "hold" else (v1 - v0) / (f1 - f0)
        for kp in pts:
            target = v0 + slope * (kp.co[0] - f0)
            offset = kp.co[1] - target if mode == "hold" else slope * (kp.co[0] - f0)
            kp.co[1] -= offset
            kp.handle_left[1] -= offset
            kp.handle_right[1] -= offset
        fc.update()


# Source frame ranges to keep, per clip, in Mixamo's own frame numbering.
#
# "Firing Rifle" is ONE shot with a long settle, not a burst loop: measured with
# a per-frame hand-displacement dump, the kick runs f4-f13 (peak f8) and the
# remaining 23 frames are low-amplitude drift. unit_visual.gd replays this clip
# from the start once per round on a 0.11s cadence, so it has to BEGIN at the
# kick -- untrimmed, the three dead lead-in frames are the only part a burst
# would ever reach, and the weapon would never visibly move.
TRIM = {
    "shoot_recoil": (4, 14),
}


def trim_action(act, first, last):
    """Keep only keys in [first, last] and shift the result to start at frame 1."""
    offset = first - 1
    for fc in act.fcurves:
        for kp in reversed(fc.keyframe_points):
            if kp.co[0] < first or kp.co[0] > last:
                fc.keyframe_points.remove(kp)
        for kp in fc.keyframe_points:
            kp.co[0] -= offset
            kp.handle_left[0] -= offset
            kp.handle_right[0] -= offset
        fc.update()


# Per-clip yaw correction in degrees, applied to the Hips so the whole body
# turns. Positive is measured empirically, not derived -- verify with
# tools/_debug_aim.gd after changing.
#
# Why this exists: Mixamo's aiming clips do not aim along the character's own
# forward. Measured in Godot, the grip-to-handguard axis in aim_hold sits 31.6
# degrees to the character's left. face_toward() turns the unit so its -Z points
# at the target, so without this every shot would leave the barrel 31.6 degrees
# off what the unit is looking at -- and the muzzle-mounted flashlight with it.
#
# Yawing the Hips is not a hack around the animation, it IS the animation: a
# bladed rifle stance genuinely has the body turned relative to the aim line, so
# rotating the body until the weapon lines up with forward is the anatomically
# correct reading rather than a fudge.
ROOT_YAW = {
    "aim_hold": -31.6,
    "overwatch_hold": -31.6,
}


def apply_root_yaw(act, degrees):
    """Yaw the entire body by `degrees` via the Hips rotation channels."""
    # The Hips bone points up in its rest pose, so the bone's local Y axis is
    # world vertical and rotating about it yaws the whole character. Composing
    # on the left applies the rotation in the rest frame rather than in the
    # already-rotated pose frame, which is what makes this a clean yaw.
    rot = Quaternion((0.0, 1.0, 0.0), math.radians(degrees))
    chan = {}
    for fc in act.fcurves:
        if fc.data_path.endswith(".rotation_quaternion") and '"Hips"' in fc.data_path:
            chan[fc.array_index] = fc
    if len(chan) != 4:
        raise RuntimeError(
            f"{act.name!r}: expected 4 Hips rotation_quaternion channels, "
            f"found {sorted(chan)}")

    count = len(chan[0].keyframe_points)
    for k in range(count):
        # mathutils orders quaternions (w, x, y, z), matching array_index 0..3.
        q = rot @ Quaternion([chan[i].keyframe_points[k].co[1] for i in range(4)])
        for i in range(4):
            kp = chan[i].keyframe_points[k]
            kp.co[1] = q[i]
            # Bezier handles cannot be rotated component-wise in any meaningful
            # way, so pin them and switch to linear. Mixamo bakes a key on every
            # frame, so with 30 keys a second the interpolation shape between
            # them is not something the eye can resolve.
            kp.handle_left[1] = q[i]
            kp.handle_right[1] = q[i]
            kp.interpolation = "LINEAR"
    for fc in chan.values():
        fc.update()


# ---------------------------------------------------------------------------
# Support-hand lock.
#
# Mixamo does not constrain hands to a prop. Each rifle clip was authored on its
# own, so the distance between the hands -- which two hands on one rigid weapon
# physically cannot change -- drifts from 317 mm in `idle` to 466 mm in
# `aim_hold`. Measured with tools/measure_support.py; re-run it after touching
# anything here.
#
# That 150 mm swing is fatal to the weapon plan (weapon-art-plan.md Sec 4): a
# weapon is mounted rigidly to the right hand, so a handguard built to satisfy
# `aim_hold` leaves the support hand visibly off the weapon during `idle` and
# `run`. There is no handguard length that covers the spread -- 400 mm, half the
# length of the rifle.
#
# The fix is to re-solve the left arm so the wrist sits at a FIXED offset from
# the right hand in every clip. This is a one-time correction to the animation,
# not per-weapon data: the weapon models still build against a single anchor, so
# the one-rig / one-animation-set constraint survives intact.
#
# Both constants come out of measure_support.py's LOCK TARGET block, derived
# from shoot_recoil + stand_to_crouch + crouch_to_stand. Those three agree to
# within 49 mm and 7.6 degrees, sit at ~400 mm (anatomically right for a rifle),
# and are the median cluster -- so locking here asks the smallest correction of
# the 466 mm and 317 mm outliers.
SUPPORT_OFFSET = Vector((-0.097290, 0.368303, 0.120797))
SUPPORT_ROTATION = Quaternion((0.665569, -0.327842, 0.612605, -0.272492))

# Mixamo's left arm chain, post prefix strip.
ARM_ROOT, ARM_MID, ARM_TIP = "LeftArm", "LeftForeArm", "LeftHand"
HAND_R_BONE = "RightHand"

# Clips where both hands are on the weapon. Everything else either drops the
# support hand (reload reaches for a magazine) or lets go entirely (downed,
# hit_react, throw_grenade), so locking them would fight the animation.
SUPPORT_LOCKED = {
    "idle", "run", "aim_hold", "overwatch_hold", "crouch_idle",
    "run_stop", "stand_to_crouch", "crouch_to_stand", "shoot_recoil",
}


def _bind_action(arm, act):
    """Assign `act` for evaluation, and prove it actually took.

    Blender 4.4 moved actions to a slotted system. An action lifted off a
    now-deleted armature carries no slot binding to this one, and assigning it
    leaves the pose at rest while reporting success -- the same silent-success
    class of failure that already cost this pipeline two debugging rounds, which
    is why this verifies rather than trusts.
    """
    ad = arm.animation_data
    ad.action = act
    if hasattr(ad, "action_slot") and ad.action_slot is None:
        slots = getattr(act, "slots", None)
        if slots:
            ad.action_slot = slots[0]

    bpy.context.scene.frame_set(int(act.frame_range[0]))
    bpy.context.view_layer.update()
    moved = any(
        arm.pose.bones[n].rotation_quaternion.angle > 1e-4
        for n in (ARM_ROOT, ARM_MID, ARM_TIP) if n in arm.pose.bones)
    if not moved:
        raise RuntimeError(
            f"{act.name!r}: assigning the action left the arm at rest -- the "
            f"action slot did not bind, so every frame would solve against the "
            f"rest pose and the lock would be silently meaningless")


def _solve_elbow(shoulder, elbow, wrist, target):
    """Two-bone IK. Returns the new elbow position.

    The current (mocap) elbow is the pole hint, so the animator's elbow
    direction survives and only the wrist actually moves. Solving from scratch
    with a fixed pole would flatten the arm's character across every clip.
    """
    l1 = (elbow - shoulder).length
    l2 = (wrist - elbow).length
    to_target = target - shoulder
    d = to_target.length
    if d < 1e-6:
        return elbow
    # Clamped just inside full extension: at exactly l1+l2 the elbow offset h
    # collapses to zero and the joint direction becomes undefined, which pops.
    d = max(min(d, (l1 + l2) * 0.999), abs(l1 - l2) + 1e-5)
    axis = to_target.normalized()

    a = (d * d + l1 * l1 - l2 * l2) / (2.0 * d)
    h = math.sqrt(max(0.0, l1 * l1 - a * a))

    # Component of the current elbow perpendicular to the shoulder->target line.
    perp = (elbow - shoulder) - axis * (elbow - shoulder).dot(axis)
    if perp.length < 1e-6:
        perp = axis.orthogonal()
    return shoulder + axis * a + perp.normalized() * h


def _point_bone(pb, target):
    """Rotate `pb` about its head so its tail points at `target`."""
    m = pb.matrix
    head = m.translation.copy()
    current = (pb.tail - pb.head)
    desired = target - head
    if current.length < 1e-6 or desired.length < 1e-6:
        return
    rot = current.normalized().rotation_difference(desired.normalized())
    new = (rot.to_matrix() @ m.to_3x3()).to_4x4()
    new.translation = head
    pb.matrix = new


def lock_support_hand(arm, act):
    """Re-solve the left arm so the support hand grips at a fixed offset.

    Runs in two passes on purpose. Pass one evaluates the untouched mocap to
    read each frame's shoulder/elbow/wrist and solve against it; pass two writes
    the results. Interleaving them would have each frame solving against the
    partially-rewritten curves of the frames before it.
    """
    for name in (ARM_ROOT, ARM_MID, ARM_TIP, HAND_R_BONE):
        if name not in arm.pose.bones:
            raise RuntimeError(
                f"rig has no bone {name!r} -- support lock needs Mixamo's arm "
                f"chain; bones present start {[b.name for b in arm.pose.bones][:8]}")

    _bind_action(arm, act)

    root = arm.pose.bones[ARM_ROOT]
    mid = arm.pose.bones[ARM_MID]
    tip = arm.pose.bones[ARM_TIP]
    hand_r = arm.pose.bones[HAND_R_BONE]

    # pose_bone.matrix is armature-OBJECT space, and a Mixamo import carries a
    # 0.01 object scale, so SUPPORT_OFFSET (metres) has to be divided by it to
    # land in the same units as the bone translations.
    scale = arm.matrix_world.to_scale()
    if max(abs(scale.x - scale.y), abs(scale.x - scale.z)) > 1e-6:
        raise RuntimeError(f"non-uniform armature scale {tuple(scale)}")
    s = scale.x

    scene = bpy.context.scene
    start, end = (int(round(x)) for x in act.frame_range)
    solved = []
    moved_mm = []
    for f in range(start, end + 1):
        scene.frame_set(f)
        bpy.context.view_layer.update()

        basis = hand_r.matrix.to_3x3().normalized()
        target = hand_r.matrix.translation + basis @ (SUPPORT_OFFSET / s)
        moved_mm.append((target - tip.matrix.translation).length * s * 1000.0)

        elbow = _solve_elbow(
            root.matrix.translation.copy(), mid.matrix.translation.copy(),
            tip.matrix.translation.copy(), target)

        _point_bone(root, elbow)
        bpy.context.view_layer.update()
        _point_bone(mid, target)
        bpy.context.view_layer.update()

        # Grip orientation, not just position: a wrist free to spin would let
        # the hand roll off the handguard even with the position pinned.
        m = (basis @ SUPPORT_ROTATION.to_matrix()).to_4x4()
        m.translation = tip.matrix.translation
        tip.matrix = m
        bpy.context.view_layer.update()

        solved.append((f, root.rotation_quaternion.copy(),
                       mid.rotation_quaternion.copy(),
                       tip.rotation_quaternion.copy()))

    # Drop the mocap curves for these three bones before rewriting, so no
    # original key survives at a frame the solve did not produce.
    for fc in list(act.fcurves):
        if not fc.data_path.endswith(".rotation_quaternion"):
            continue
        if '"' in fc.data_path and fc.data_path.split('"')[1] in (
                ARM_ROOT, ARM_MID, ARM_TIP):
            act.fcurves.remove(fc)

    for f, q_root, q_mid, q_tip in solved:
        for pb, q in ((root, q_root), (mid, q_mid), (tip, q_tip)):
            pb.rotation_quaternion = q
            pb.keyframe_insert("rotation_quaternion", frame=f, group=pb.name)

    arm.animation_data.action = None
    return sum(moved_mm) / len(moved_mm), max(moved_mm)


def clip_files(anim_dir):
    return sorted(glob.glob(os.path.join(anim_dir, "*.fbx")))


def inspect(character, anim_dir):
    reset_scene()
    arm, extra = import_fbx(character, with_anim=False)
    n = strip_prefix(arm)
    log(f"stripped prefix from {n} bones")
    describe(arm, extra, f"CHARACTER {os.path.basename(character)}")
    char_bones = {b.name for b in arm.data.bones}

    for path in clip_files(anim_dir):
        reset_scene()
        c_arm, c_extra = import_fbx(path, with_anim=True)
        strip_prefix(c_arm)
        describe(c_arm, c_extra, f"CLIP {os.path.basename(path)}")
        clip_bones = {b.name for b in c_arm.data.bones}
        missing = sorted(char_bones - clip_bones)
        surplus = sorted(clip_bones - char_bones)
        log(f"  bones vs character: missing={len(missing)} surplus={len(surplus)}")
        if missing:
            log(f"    missing: {missing[:10]}")
        if surplus:
            log(f"    surplus: {surplus[:10]}")

    log("=== inspect complete ===")


def build(character, anim_dir, out_path, fps, max_texture, strip_root,
          support_lock=True):
    reset_scene()
    bpy.context.scene.render.fps = fps

    arm, _ = import_fbx(character, with_anim=False)
    strip_prefix(arm)
    arm.name = "Rig"
    if max_texture:
        shrink_textures(max_texture)
    if arm.animation_data is None:
        arm.animation_data_create()
    char_bones = {b.name for b in arm.data.bones}
    log(f"character rig: {len(char_bones)} bones")

    built = []
    source_of = {}
    for path in clip_files(anim_dir):
        stem = os.path.splitext(os.path.basename(path))[0]
        key = normalize(stem)
        if key not in CLIP_MAP_NORM:
            log(f"SKIP {stem!r}: no CLIP_MAP entry "
                f"-- add {stem!r}: \"<clip name>\" to CLIP_MAP")
            continue
        targets = CLIP_MAP_NORM[key]
        if targets is None:
            log(f"  ignoring {stem!r} (mapped to None on purpose)")
            continue
        if isinstance(targets, str):
            targets = (targets,)

        c_arm, c_extra = import_fbx(path, with_anim=True)
        strip_prefix(c_arm)
        act = c_arm.animation_data.action if c_arm.animation_data else None
        if act is None:
            log(f"SKIP {stem!r}: no action in file")
            continue

        # Fatal, not a warning. A clip whose tracks name bones the character
        # does not have produces a GLB that imports and plays and animates
        # nothing -- the exact silent-success failure this pipeline has already
        # hit twice. Both sides come off the same Mixamo skeleton, so any
        # mismatch here is a bug, not a tolerance.
        bad = sorted(
            {fc.data_path.split('"')[1] for fc in act.fcurves if '"' in fc.data_path}
            - char_bones)
        if bad:
            raise RuntimeError(
                f"{stem!r}: {len(bad)} of {len(bad) + len(char_bones)} animated "
                f"bones are unknown to the character rig, e.g. {bad[:5]} -- "
                f"check the mixamorig prefix survived stripping")

        # Trim before measuring: root motion over the kept range is what
        # matters, and the reported length should be the shipped length.
        if targets[0] in TRIM:
            first, last = TRIM[targets[0]]
            # tuple(), not the raw property: act.frame_range is a live view that
            # would report post-trim values by the time it is logged.
            src = tuple(act.frame_range)
            trim_action(act, first, last)
            log(f"  trimmed {targets[0]!r}: source f{src[0]:.0f}..{src[1]:.0f} "
                f"-> kept f{first}..{last} ({(last - first) / fps:.3f}s)")

        # Root motion is measured and stripped BEFORE any copy is taken, so
        # every target of a multi-target entry gets the same corrected curves.
        dist, speed = root_motion(act, fps)
        fr = act.frame_range
        log(f"  {stem!r} -> {'+'.join(targets)} "
            f"({(fr[1] - fr[0]) / fps:.3f}s, {len(act.fcurves)} fcurves)")
        if dist > ROOT_MOTION_LIMIT_M:
            # Almost always means the Mixamo "In Place" box was left unchecked.
            # Reported rather than silently fixed, because the speed is the
            # number unit.gd's MOVE_SPEED has to match to avoid foot skate.
            mode = STRIP_MODE.get(targets[0], DEFAULT_STRIP_MODE)
            log(f"    ROOT MOTION: travels {dist:.3f}m at {speed:.2f} m/s"
                f"{f' -- stripped ({mode})' if strip_root else ''}")
            if strip_root:
                strip_root_motion(act, mode)

        # One source clip can serve several game clips -- aim_hold and
        # overwatch_hold are the same held-rifle pose, and Mixamo has no
        # separate overwatch animation. Copies after the first, so each glTF
        # animation owns its own curves.
        # Copies are all taken BEFORE any per-target edit, so a correction
        # applied to the first target cannot leak into the others.
        pairs = [(clip, act if i == 0 else act.copy())
                 for i, clip in enumerate(targets)]
        for clip, target_act in pairs:
            name = f"{clip}-loop" if clip in LOOPING else clip
            if clip in source_of:
                raise RuntimeError(
                    f"two files both map to clip {clip!r}: "
                    f"{source_of[clip]!r} and {stem!r} -- map one to None")
            source_of[clip] = stem
            target_act.name = name
            target_act.use_fake_user = True
            if clip in ROOT_YAW:
                apply_root_yaw(target_act, ROOT_YAW[clip])
                log(f"    yawed {clip!r} by {ROOT_YAW[clip]:+.1f} deg")
            # After the yaw: the lock solves against evaluated world-space bone
            # positions, so it has to see the pose the clip actually ships with.
            if support_lock and clip in SUPPORT_LOCKED:
                mean_mm, max_mm = lock_support_hand(arm, target_act)
                log(f"    support-locked {clip!r}: wrist moved "
                    f"{mean_mm:.1f}mm mean, {max_mm:.1f}mm max")
            built.append((name, fr[1] - fr[0], len(target_act.fcurves)))

        # The clip's own skeleton and any stray objects go; only its action stays.
        for o in c_extra:
            bpy.data.objects.remove(o, do_unlink=True)

    if not built:
        raise RuntimeError("no clips built -- check CLIP_MAP against the filenames")

    # Each action gets its own NLA track, and the export runs in NLA_TRACKS mode
    # rather than ACTIONS mode.
    #
    # ACTIONS mode silently dropped whichever action was assigned as active --
    # exporting 2 of 3 clips with no warning. Blender 4.4 moved actions to a
    # slotted system, and an action lifted off a deleted armature has no slot
    # binding to this one, which the active-action path does not survive.
    # NLA tracks sidestep the question: one track per clip, each exported as one
    # glTF animation named after the track, nothing implicit.
    ad = arm.animation_data
    ad.action = None
    for name, _, _ in built:
        act = bpy.data.actions[name]
        track = ad.nla_tracks.new()
        track.name = name
        track.strips.new(name, int(act.frame_range[0]), act)

    bpy.ops.export_scene.gltf(
        filepath=out_path,
        export_format="GLB",
        export_animations=True,
        export_animation_mode="NLA_TRACKS",
        export_bake_animation=True,
        export_apply=False,
    )
    log(f"exported {out_path} with {len(built)} clips:")
    for name, frames, curves in built:
        log(f"  {name:<20} {frames / fps:.3f}s")


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--character", default="art_src/T-Pose.fbx")
    p.add_argument("--anims", default="art_src/anims")
    p.add_argument("--export", default="assets/soldier_mixamo.glb")
    p.add_argument("--fps", type=int, default=30)
    p.add_argument("--max-texture", type=int, default=1024,
                   help="downscale embedded textures to this many pixels on the "
                        "long edge; 0 leaves them alone")
    p.add_argument("--strip-root", action="store_true",
                   help="remove net horizontal Hips travel from travelling "
                        "clips; prefer re-downloading with Mixamo's In Place "
                        "box checked, which does this at source")
    p.add_argument("--no-support-lock", action="store_true",
                   help="skip re-solving the left arm onto a fixed grip offset; "
                        "leaves Mixamo's 317-466mm hand-separation drift in "
                        "place, which no single weapon model can satisfy")
    p.add_argument("--inspect", action="store_true",
                   help="report format facts and exit without exporting")
    args = p.parse_args(argv)

    if args.inspect:
        inspect(args.character, args.anims)
    else:
        build(args.character, args.anims, args.export, args.fps, args.max_texture,
              args.strip_root, support_lock=not args.no_support_lock)


if __name__ == "__main__":
    main()
