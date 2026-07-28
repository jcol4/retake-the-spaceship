"""Pose assets/soldier_character_only.blend into a T-pose and save a copy.

This rig's rest pose is arms-down, not a T-pose (upperarm.head/tail share the
same X — the bone points straight down — see tools/gen_soldier.py's BONES
dict), so getting a T-pose means actually posing it: 90 degrees of shoulder
abduction on each arm, everything else at rest. Detaches the active action
first (so opening the file shows this pose by default, not frame 0 of
whatever action happens to be assigned) but leaves all 11 actions in the file
to scrub through in the Action Editor same as before.

Run headless:
    blender -b -P tools/make_tpose.py -- --src assets/soldier_character_only.blend --dst assets/soldier_character_only_tpose.blend
"""

import math
import os
import sys

import bpy


def make_tpose(src_path, dst_path):
    bpy.ops.wm.open_mainfile(filepath=src_path)
    rig = bpy.data.objects["Rig"]

    rig.animation_data.action = None
    for pb in rig.pose.bones:
        pb.rotation_mode = "XYZ"
        pb.rotation_euler = (0.0, 0.0, 0.0)
        pb.location = (0.0, 0.0, 0.0)

    # Abduct each upperarm 90 degrees out to horizontal. Z sign convention
    # confirmed while tuning the elbow flare earlier this session: negative Z
    # abducts a .L bone, positive Z abducts the mirrored .R bone.
    rig.pose.bones["upperarm.L"].rotation_euler = (0.0, 0.0, math.radians(-90))
    rig.pose.bones["upperarm.R"].rotation_euler = (0.0, 0.0, math.radians(90))

    bpy.context.view_layer.update()

    os.makedirs(os.path.dirname(dst_path), exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=dst_path)
    size = os.path.getsize(dst_path) / 1024.0
    print(f"[make_tpose] wrote {dst_path} ({size:.0f} KB)")


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if "--src" not in argv or "--dst" not in argv:
        raise SystemExit(
            "usage: blender -b -P tools/make_tpose.py -- "
            "--src <path.blend> --dst <path.blend>")
    make_tpose(os.path.abspath(argv[argv.index("--src") + 1]),
               os.path.abspath(argv[argv.index("--dst") + 1]))


main()
