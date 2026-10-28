"""Renders a side view of each gun .blend, all at the same scale, to one PNG each.

  blender.exe -b -P tools/preview_guns.py -- <out_dir> art_src/guns/rifle.blend [more.blend ...]

Every gun is drawn in its own gun space, so the grip (origin) lands on the same
pixel in every image: lining two previews up is the visual check that the grips
are standardized. The grip and grip_support are marked with small spheres.
"""

import math
import os
import sys

import bpy
from mathutils import Vector

FRAME = 1.5   # metres across the image; fits the longest gun with room to spare
SIZE = 640


def preview(blend, out_dir):
    bpy.ops.wm.open_mainfile(filepath=os.path.abspath(blend))
    name = os.path.splitext(os.path.basename(blend))[0]
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE_NEXT" if "BLENDER_EEVEE_NEXT" in \
        [e.identifier for e in bpy.types.RenderSettings.bl_rna.properties["engine"].enum_items] \
        else "BLENDER_EEVEE"
    scene.render.resolution_x = SIZE
    scene.render.resolution_y = int(SIZE * 0.6)
    scene.render.film_transparent = False
    world = scene.world or bpy.data.worlds.new("w")
    scene.world = world
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (0.3, 0.32, 0.36, 1)
    world.node_tree.nodes["Background"].inputs[1].default_value = 1.0

    # The marker is the old flash mesh; drawn, it hides the barrel.
    flash = bpy.data.objects.get("muzzle_flash")
    if flash:
        flash.hide_render = True
        bpy.ops.mesh.primitive_uv_sphere_add(radius=0.008, location=flash.matrix_world.translation)
    for marker in ("grip_support",):
        obj = bpy.data.objects.get(marker)
        if obj:
            bpy.ops.mesh.primitive_uv_sphere_add(radius=0.012, location=obj.matrix_world.translation)
    bpy.ops.mesh.primitive_uv_sphere_add(radius=0.012, location=(0, 0, 0))

    # Camera on +X looking -X, so the barrel (+Y) points right.
    cam_data = bpy.data.cameras.new("cam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = FRAME
    cam = bpy.data.objects.new("cam", cam_data)
    scene.collection.objects.link(cam)
    cam.location = (3.0, 0.3, -0.05)
    cam.rotation_euler = (math.radians(90), 0, math.radians(90))
    scene.camera = cam
    sun_data = bpy.data.lights.new("sun", "SUN")
    sun_data.energy = 3.0
    sun = bpy.data.objects.new("sun", sun_data)
    sun.rotation_euler = (math.radians(50), 0, math.radians(60))
    scene.collection.objects.link(sun)

    scene.render.filepath = os.path.join(os.path.abspath(out_dir), name + ".png")
    bpy.ops.render.render(write_still=True)
    print("[preview] %s" % scene.render.filepath)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:]
    out_dir, blends = argv[0], argv[1:]
    os.makedirs(out_dir, exist_ok=True)
    for blend in blends:
        preview(blend, out_dir)


if __name__ == "__main__":
    main()
