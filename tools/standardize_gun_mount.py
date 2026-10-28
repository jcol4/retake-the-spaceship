"""Turn the merc's fitted rifle into a swappable gun on a standard grip mount.

  blender.exe -b art_src/merc_anim.blend -P tools/standardize_gun_mount.py -- \
      art_src/merc_anim_gunswap.blend art_src/guns/rifle.blend

WHAT CHANGES
------------
Before: `weapon` bone -> `Empty` (scale 0.328, rotated) -> `AssaultRifle2_1`
(scale 0.254, offset past the stock) -> `Empty.001` (the left hand's IK target)
and `muzzle_flash`. Every gun would have to reproduce those exact offsets.

After: `weapon` bone -> `weapon_mount` -> `rifle`, where
  * `weapon_mount` sits on the primary (trigger-hand) grip, at unit world scale,
    with +Y down the barrel and +Z up -- glTF turns that into Godot's -Z
    forward, +Y up;
  * `rifle` has an IDENTITY transform under the mount: the old offsets are baked
    into its mesh, so the gun's origin IS the grip;
  * `grip_support` (was Empty.001) is where the left hand goes, and
    `muzzle_flash` the barrel tip.

That is the whole gun contract: any gun modelled with its grip at the origin,
barrel +Y, top +Z, and a `grip_support` and `muzzle_flash` child drops onto
`weapon_mount` and the existing animation holds it. The left hand's IK keeps
following `grip_support`, so a gun whose support grip sits elsewhere re-poses
the left arm in Blender; in game the arm is baked, so keep `grip_support` where
this rifle's is (see GRIP_SUPPORT in the printout) or the hand will float.

The world transform of the rifle and both hands is checked against the
original on every few frames of every action; the script aborts on drift.
"""

import os
import sys

import bpy
from mathutils import Matrix, Vector

ARMATURE = "Armature"
HOLDER, MOUNT = "Empty", "weapon_mount"
RIFLE, GUN = "AssaultRifle2_1", "rifle"
SUPPORT, GRIP_SUPPORT = "Empty.001", "grip_support"
MUZZLE = "muzzle_flash"
CHECK_BONES = ("hand.L", "hand.R", "forearm.L", "forearm.R")
FRAME_STEP = 2
TOLERANCE = 1e-4


def armature_actions(arm):
    """(action, slot) for every action that animates the armature."""
    out = []
    for action in bpy.data.actions:
        for slot in action.slots:
            if slot.target_id_type == "OBJECT" and slot.name_display == arm.name:
                out.append((action, slot))
    return out


def sample(arm, rifle, verts):
    """World positions of a spread of rifle vertices and of the hand bones, per
    (action, frame). Vertex indices survive mesh.transform, so before and after
    are comparable point for point."""
    scene = bpy.context.scene
    saved = (arm.animation_data.action, arm.animation_data.action_slot)
    # Some actions key the armature OBJECT's location; the sweep would leave the
    # last one's value behind in the saved file, shifting the whole export.
    saved_basis = arm.matrix_basis.copy()
    out = {}
    for action, slot in armature_actions(arm):
        arm.animation_data.action = action
        arm.animation_data.action_slot = slot
        start, end = (int(v) for v in action.frame_range)
        for frame in range(start, end + 1, FRAME_STEP):
            scene.frame_set(frame)
            mw = rifle.matrix_world
            points = [mw @ rifle.data.vertices[i].co for i in verts]
            points += [arm.matrix_world @ arm.pose.bones[b].head for b in CHECK_BONES]
            out[(action.name, frame)] = points
    arm.animation_data.action, arm.animation_data.action_slot = saved
    arm.matrix_basis = saved_basis
    scene.frame_set(scene.frame_current)
    return out


def loc_rot(m):
    """`m` with its scale removed."""
    loc, rot, _ = m.decompose()
    return Matrix.LocRotScale(loc, rot, None)


def restructure(arm, holder, rifle, support, muzzle):
    view = bpy.context.view_layer
    # Constant object-level keys would pin these back to their OLD local values
    # the moment an action plays (`run` keys the holder, the rifle and support
    # have one-frame actions, fire_shoot shrinks the muzzle marker). The game
    # never shows the marker -- MuzzleFlash mounts beside it -- so its key goes.
    for obj in (holder, rifle, support, muzzle):
        obj.animation_data_clear()
    view.update()

    rifle_w = rifle.matrix_world.copy()
    support_w = support.matrix_world.copy()
    muzzle_w = muzzle.matrix_world.copy()

    # The mount's axes: the rifle's long axis, signed toward the muzzle, and its
    # up axis made orthogonal to it. Origin stays on the holder -- the grip.
    basis = rifle_w.to_3x3()
    forward = basis.col[0].normalized()
    if forward.dot(muzzle_w.translation - rifle_w.translation) < 0:
        forward = -forward
    up = basis.col[2].normalized()
    up = (up - forward * up.dot(forward)).normalized()
    side = forward.cross(up)
    mount_w = Matrix.Identity(4)
    for i, axis in enumerate((side, forward, up)):
        for r in range(3):
            mount_w[r][i] = axis[r]
    mount_w.translation = holder.matrix_world.translation

    holder.matrix_world = mount_w
    view.update()

    # Bake rifle-in-mount into the vertices; the object itself sits at identity.
    rifle.data.transform(mount_w.inverted() @ rifle_w)
    rifle.matrix_parent_inverse = Matrix.Identity(4)
    rifle.matrix_basis = Matrix.Identity(4)
    view.update()

    for child, world in ((support, loc_rot(support_w)), (muzzle, muzzle_w)):
        child.matrix_parent_inverse = Matrix.Identity(4)
        child.matrix_world = world
    view.update()

    holder.name = MOUNT
    holder["gun"] = GUN
    rifle.name = GUN
    rifle.data.name = GUN
    support.name = GRIP_SUPPORT

    print("[gun] mount at grip %s" % (tuple(round(v, 4) for v in mount_w.translation),))
    print("[gun] GRIP_SUPPORT in gun space %s" % (tuple(round(v, 4) for v in support.matrix_local.translation),))
    print("[gun] MUZZLE in gun space %s" % (tuple(round(v, 4) for v in muzzle.matrix_local.translation),))


def compare(before, after, label="VERIFY", labels=()):
    worst, where = 0.0, None
    per_point = {}
    for key, points in before.items():
        for i, (a, b) in enumerate(zip(points, after[key])):
            d = (a - b).length
            per_point[i] = max(per_point.get(i, 0.0), d)
            if d > worst:
                worst, where = d, key
    print("[gun] %s %d samples, worst drift %.6f m at %s" % (label, len(before), worst, where))
    print("[gun]   per point: %s" % ", ".join(
        "%s=%.5f" % (labels[i] if i < len(labels) else i, d) for i, d in sorted(per_point.items())))
    return worst


def check(before, after, labels):
    if compare(before, after, labels=labels) > TOLERANCE:
        sys.exit("[gun] drift over tolerance -- not saving")


def save_gun_file(path):
    """The gun alone, at the world origin: what a new gun's .blend looks like."""
    gun = bpy.data.objects[GUN]
    keep = {gun} | set(gun.children_recursive)
    for obj in [o for o in bpy.data.objects if o not in keep]:
        bpy.data.objects.remove(obj, do_unlink=True)
    # Children ride along: their transforms are already relative to the gun.
    gun.parent = None
    gun.matrix_parent_inverse = Matrix.Identity(4)
    gun.matrix_basis = Matrix.Identity(4)
    for action in list(bpy.data.actions):
        bpy.data.actions.remove(action)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bpy.ops.outliner.orphans_purge(do_recursive=True)
    bpy.ops.wm.save_as_mainfile(filepath=path)
    print("[gun] wrote %s" % path)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:]
    character_out, gun_out = (os.path.abspath(p) for p in argv[:2])
    objs = bpy.data.objects
    arm, rifle = objs[ARMATURE], objs[RIFLE]
    n = len(rifle.data.vertices)
    verts = sorted({0, n // 5, 2 * n // 5, 3 * n // 5, 4 * n // 5, n - 1})

    for obj in (objs[HOLDER], rifle, objs[SUPPORT], objs[MUZZLE]):
        obj.animation_data_clear()
    labels = ["v%d" % i for i in verts] + list(CHECK_BONES)
    # A throwaway pass: the very first evaluation after load reads the left
    # hand's IK target from the saved file rather than from the posed rig.
    sample(arm, rifle, verts)
    before = sample(arm, rifle, verts)
    # The left hand IKs onto an object that hangs off the armature -- a
    # dependency cycle. Measure how repeatable the ORIGINAL is before blaming
    # the restructure for any drift.
    compare(before, sample(arm, rifle, verts), "BASELINE", labels)
    restructure(arm, objs[HOLDER], rifle, objs[SUPPORT], objs[MUZZLE])
    after = sample(arm, rifle, verts)
    check(before, after, labels)

    bpy.ops.wm.save_as_mainfile(filepath=character_out)
    print("[gun] wrote %s" % character_out)
    save_gun_file(gun_out)


if __name__ == "__main__":
    main()
