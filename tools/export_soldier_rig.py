"""Export the Contractor rig from its hand-authored source file.

assets/soldier_rig.blend is the source of truth for Contractor animations —
edit actions there directly in Blender (Action Editor / dope sheet / graph
editor) and re-run this to ship the result. tools/gen_soldier.py still owns
the mesh, materials and rig proportions (it refuses to touch soldier.glb for
exactly this reason — see its --export guard), but no longer owns poses: it
only produces a fresh soldier_rig.blend to hand-animate from scratch if the
base body changes.

Run headless:
    blender -b -P tools/export_soldier_rig.py -- --blend assets/soldier_rig.blend --export assets/soldier.glb

After any change to the aim_hold action's hand.R orientation, re-run
tools/_debug_aim.gd (see its own docstring) — the rifle's mount transform in
scenes/character_base.tscn is a fixed offset solved against that pose, and
goes stale the moment it moves.
"""

import os
import sys

import bpy


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if "--blend" not in argv or "--export" not in argv:
        raise SystemExit(
            "usage: blender -b -P tools/export_soldier_rig.py -- "
            "--blend <path.blend> --export <path.glb>")
    blend_path = os.path.abspath(argv[argv.index("--blend") + 1])
    export_path = os.path.abspath(argv[argv.index("--export") + 1])

    bpy.ops.wm.open_mainfile(filepath=blend_path)

    rig_obj = bpy.data.objects["Rig"]
    mesh_obj = bpy.data.objects["Soldier"]

    actions = [a.name for a in bpy.data.actions]
    print(f"[export_soldier_rig] {len(actions)} actions: {', '.join(sorted(actions))}")

    os.makedirs(os.path.dirname(export_path), exist_ok=True)
    bpy.ops.object.select_all(action="DESELECT")
    for obj in (rig_obj, mesh_obj):
        obj.select_set(True)
    bpy.context.view_layer.objects.active = rig_obj
    bpy.ops.export_scene.gltf(
        filepath=export_path,
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_yup=True,
        export_animations=True,
        export_animation_mode="ACTIONS",
    )
    size = os.path.getsize(export_path) / 1024.0
    print(f"[export_soldier_rig] wrote {export_path} ({size:.0f} KB)")


main()
