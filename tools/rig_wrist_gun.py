"""Turn the robot's fitted wrist gun into a swappable one on a standard wrist
mount, write the gun out as its own asset, and give `fire_gun` a recoil kick.

  blender.exe -b assets/sec_robot_v3.blend -P tools/rig_wrist_gun.py -- \
      --gun-object lmg --name wrist_lmg

The robot's counterpart of tools/standardize_gun_mount.py, for a gun that rides
the forearm rather than the hands.

WHAT CHANGES
------------
Before: `forearm.L` bone -> `lmg`, the gun modelled in place with its origin at
the point it bolts on, barrels down +Y and top +Z.

After: `forearm.L` bone -> `wrist_mount` -> `<name>` -> `muzzle_flash`,
`muzzle_flash_2`, ... where
  * `wrist_mount` is an Empty that takes over the gun's exact bone relation, so
    nothing moves on any frame of any action. Its `gun` property names the gun
    the .blend previews; export_models.py writes it into the sidecar as the
    default, and hides the preview so the .glb carries only the mount;
  * `<name>` is the preview gun at an IDENTITY transform under the mount;
  * there is one muzzle marker per barrel, found from the mesh (the vertex rings
    at the +Y end), at the bore's centre with the gun's axes. glTF turns +Y down
    the bore into Godot's -Z, which is what MuzzleFlash fires along. The game
    fires them in NAME order, one per round (UnitVisual._play_burst), so a
    twin-barrel gun alternates.

That is the whole wrist-gun contract: any gun modelled with its mount point at
the origin, barrels +Y, top +Z and a `muzzle_flash` (plus `muzzle_flash_2`... for
more barrels) at each bore drops onto `wrist_mount`.

The gun is ALSO written on its own to art_src/wrist_guns/<name>.blend, at the
origin. That file is the asset (`export_models.py --wrist-gun <name>` makes
assets/models/wrist_guns/<name>.glb); the copy in the robot's .blend is only a
preview to animate against, exactly like the merc's rifle. Edit the gun in the
asset file, or rerun this on a fresh robot .blend.

`fire_gun` is the held aim the rounds go out from. It gets a kick: IK-hand.L
driven KICK_BACK back down the bore and KICK_UP up on frame 2, and home again by
frame KICK_END, so it starts and ends on the held pose (the game restarts it
every round with no blend). The game time-scales it to one round's cadence.

Every step is skipped if already done. The gun's world transform is checked on
every frame of every action against the original; the script aborts on drift.
"""

import argparse
import os
import sys

import bpy
from mathutils import Matrix, Vector

ARMATURE = "Armature"
BONE = "forearm.L"
MOUNT = "wrist_mount"
MUZZLE = "muzzle_flash"
FIRE_ACTION = "fire_gun"
KICK_BONE = "IK-hand.L"
## Metres, world, at the hand. The IK bends the elbow with it, so the muzzle
## travels further: about 6 cm at these values, over the 0.11 s a round lasts.
KICK_BACK = 0.035
KICK_UP = 0.012
KICK_PEAK = 2
KICK_END = 4
## How close to the gun's +Y end a vertex must be to count as part of a bore's
## end ring, and how far apart two rings must be to count as two barrels.
RING_DEPTH = 0.003
RING_GAP = 0.02


def _args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--gun-object", default="lmg", help="the fitted gun in the robot .blend")
    p.add_argument("--name", default="wrist_lmg", help="the wrist gun's asset name")
    p.add_argument("--out", default=None, help="asset .blend (default art_src/wrist_guns/<name>.blend)")
    return p.parse_args(argv)


def _fail(msg):
    sys.exit("[rig_wrist_gun] " + msg)


def _frames(action):
    a, b = (int(round(x)) for x in action.frame_range)
    return range(a, b + 1)


def _sample_gun(arm, gun):
    """The gun's world matrix on every frame of every action."""
    scene = bpy.context.scene
    saved = arm.animation_data.action
    out = {}
    for action in bpy.data.actions:
        arm.animation_data.action = action
        if arm.animation_data.action_slot is None and action.slots:
            arm.animation_data.action_slot = action.slots[0]
        for f in _frames(action):
            scene.frame_set(f)
            out[(action.name, f)] = gun.matrix_world.copy()
    arm.animation_data.action = saved
    return out


def _max_drift(before, after):
    worst = 0.0
    for key, m in before.items():
        n = after[key]
        worst = max(worst, max(abs(x - y) for r1, r2 in zip(m, n) for x, y in zip(r1, r2)))
    return worst


def _barrel_tips(gun):
    """Bore centres at the gun's +Y end, in its local space, sorted +X first."""
    verts = [v.co for v in gun.data.vertices]
    end = max(v.y for v in verts)
    ring = [v for v in verts if end - v.y < RING_DEPTH]
    clusters = []
    for v in ring:
        for c in clusters:
            if (Vector((v.x, v.z)) - Vector((c[0].x, c[0].z))).length < RING_GAP:
                c.append(v)
                break
        else:
            clusters.append([v])
    tips = [sum(c, Vector()) / len(c) for c in clusters]
    for t in tips:
        t.y = end
    return sorted(tips, key=lambda t: -t.x)


def rig_mount(arm, gun, name):
    if bpy.data.objects.get(MOUNT):
        print("[rig_wrist_gun] %s already exists; mount step skipped" % MOUNT)
        return bpy.data.objects[name]
    if gun.parent != arm or gun.parent_type != "BONE" or gun.parent_bone != BONE:
        _fail("%s must be bone-parented to %s first" % (gun.name, BONE))
    before = _sample_gun(arm, gun)
    mount = bpy.data.objects.new(MOUNT, None)
    mount.empty_display_type = "PLAIN_AXES"
    mount.empty_display_size = 0.1
    for coll in gun.users_collection:
        coll.objects.link(mount)
    # Takes the gun's bone relation over whole, so it sits where the gun's
    # origin does on every frame.
    mount.parent = arm
    mount.parent_type = "BONE"
    mount.parent_bone = BONE
    mount.matrix_parent_inverse = gun.matrix_parent_inverse.copy()
    mount.matrix_basis = gun.matrix_basis.copy()
    mount["gun"] = name
    gun.parent = mount
    gun.parent_type = "OBJECT"
    gun.matrix_parent_inverse = Matrix.Identity(4)
    gun.matrix_basis = Matrix.Identity(4)
    gun.name = name
    gun.data.name = name
    drift = _max_drift(before, _sample_gun(arm, gun))
    print("[rig_wrist_gun] %s -> %s -> %s, max drift %.2e" % (BONE, MOUNT, name, drift))
    if drift > 1e-5:
        _fail("the gun moved (%.2e); nothing saved" % drift)
    return gun


def add_muzzles(gun):
    if any(c.name.startswith(MUZZLE) for c in gun.children):
        print("[rig_wrist_gun] muzzle markers already exist; skipped")
        return
    tips = _barrel_tips(gun)
    if not tips:
        _fail("found no barrel ends on %s" % gun.name)
    for i, tip in enumerate(tips):
        marker = bpy.data.objects.new(MUZZLE if i == 0 else "%s_%d" % (MUZZLE, i + 1), None)
        marker.empty_display_type = "ARROWS"  # +Y is down the bore
        marker.empty_display_size = 0.05
        for coll in gun.users_collection:
            coll.objects.link(marker)
        marker.parent = gun
        marker.matrix_parent_inverse = Matrix.Identity(4)
        marker.location = tip
        print("[rig_wrist_gun] %s at %s" % (marker.name, tuple(round(v, 4) for v in tip)))


def add_kick(arm, gun):
    action = bpy.data.actions.get(FIRE_ACTION)
    if action is None:
        _fail("no %r action" % FIRE_ACTION)
    if int(round(action.frame_range[1])) > 1:
        print("[rig_wrist_gun] %s already runs past frame 1; kick skipped" % FIRE_ACTION)
        return
    scene = bpy.context.scene
    arm.animation_data.action = action
    if arm.animation_data.action_slot is None and action.slots:
        arm.animation_data.action_slot = action.slots[0]
    scene.frame_set(1)
    pb = arm.pose.bones[KICK_BONE]
    held = pb.location.copy()
    gun_before = gun.matrix_world.translation.copy()
    bore = (gun.matrix_world.to_3x3() @ Vector((0, 1, 0))).normalized()
    push = -bore * KICK_BACK + Vector((0, 0, KICK_UP))
    to_arm = arm.matrix_world.inverted().to_3x3()
    kicked = pb.matrix.copy()
    kicked.translation += to_arm @ push
    pb.matrix = kicked
    bpy.context.view_layer.update()
    pb.keyframe_insert("location", frame=KICK_PEAK)
    pb.location = held
    pb.keyframe_insert("location", frame=KICK_END)
    # Snaps back into the kick, eases home.
    for bag in (b for layer in action.layers for s in layer.strips for b in s.channelbags):
        for fc in bag.fcurves:
            if fc.data_path == 'pose.bones["%s"].location' % KICK_BONE:
                for kp in fc.keyframe_points:
                    if int(round(kp.co.x)) == 1:
                        kp.interpolation = "LINEAR"
    action.use_frame_range = True
    action.frame_start, action.frame_end = 1, KICK_END
    scene.frame_set(KICK_PEAK)
    moved = (gun.matrix_world.translation - gun_before).length
    scene.frame_set(KICK_END)
    home = (gun.matrix_world.translation - gun_before).length
    print("[rig_wrist_gun] %s kick: gun moves %.3f m at frame %d, %.1e off home at frame %d"
          % (FIRE_ACTION, moved, KICK_PEAK, home, KICK_END))
    if home > 1e-4:
        _fail("the kick does not come home")


def write_asset(gun, out):
    """Strips the scene to the gun and its markers, at the origin, and saves it
    as the asset. Run LAST: the robot's .blend is already written."""
    keep = {gun} | set(gun.children_recursive)
    for obj in list(bpy.data.objects):
        if obj not in keep:
            bpy.data.objects.remove(obj, do_unlink=True)
    gun.parent = None
    gun.matrix_parent_inverse = Matrix.Identity(4)
    gun.matrix_basis = Matrix.Identity(4)
    for action in list(bpy.data.actions):
        bpy.data.actions.remove(action)
    for arm in list(bpy.data.armatures):
        bpy.data.armatures.remove(arm)
    bpy.data.orphans_purge(do_recursive=True)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=out, copy=True)
    print("[rig_wrist_gun] wrote %s" % out)


def main():
    args = _args()
    arm = bpy.data.objects.get(ARMATURE)
    gun = bpy.data.objects.get(args.name) or bpy.data.objects.get(args.gun_object)
    if arm is None or gun is None:
        _fail("need %r and %r (or %r)" % (ARMATURE, args.gun_object, args.name))
    gun = rig_mount(arm, gun, args.name)
    add_muzzles(gun)
    add_kick(arm, gun)
    bpy.ops.wm.save_mainfile()
    print("[rig_wrist_gun] saved %s" % bpy.data.filepath)
    out = args.out or os.path.join(os.path.dirname(os.path.dirname(bpy.data.filepath)),
                                   "art_src", "wrist_guns", args.name + ".blend")
    write_asset(gun, os.path.abspath(out))


if __name__ == "__main__":
    main()
