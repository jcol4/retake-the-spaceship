"""Add the ammo bar to each primary weapon: a strip on the gun's right side that
the game shortens and recolours as the magazine empties.

  blender.exe -b -P tools/add_gun_ammo_bars.py

Writes each gun's .blend in place (Blender keeps the previous save as .blend1).
Run it again to rebuild the bars: any existing one is deleted first, and nothing
else in the .blend is touched, so hand edits to a gun survive. Then export as
usual (export_models.py --gun <gun>).

The bar is an object of its own, a child of the gun, with its ORIGIN AT THE REAR
END and no rotation: Godot sees the bore as local -Z, so unit_visual.gd scales
the node's Z to drain it toward the stock. Its material is a placeholder; the
game replaces it with its own glow.
"""

import os

import bmesh
import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree

OUT_DIR = "art_src/guns"
BAR = "ammo_bar"

## Gun space: +X right, +Y down the barrel, +Z up. Each span sits on the receiver,
## behind where the left hand closes (build_guns.SUPPORT_Y) and above the right
## hand: (rear y, front y, bottom z, top z), read off that gun's parts.
SPANS = {
    "assault_rifle": (-0.0225, 0.1575, 0.065, 0.085),
    "battle_rifle": (-0.0175, 0.2225, 0.062, 0.082),
    "lmg": (-0.0325, 0.2375, 0.064, 0.084),
    "smg": (-0.010, 0.140, 0.058, 0.078),
    "shotgun": (-0.009, 0.191, 0.060, 0.080),
}
## How far the face stands off the gun's widest point under it, and how far the
## box runs back into the gun, so it reads as a panel rather than a floating card.
LIFT = 0.002
DEPTH = 0.006
## Samples of the gun's side under the span, per axis.
SAMPLES = 8


def side_x(gun, y0, y1, z0, z1):
    """The gun's outermost +X anywhere under the span, in the gun's own space."""
    dg = bpy.context.evaluated_depsgraph_get()
    ev = gun.evaluated_get(dg)
    mesh = ev.to_mesh()
    bm = bmesh.new()
    bm.from_mesh(mesh)
    ev.to_mesh_clear()
    tree = BVHTree.FromBMesh(bm)
    bm.free()
    best = None
    for i in range(SAMPLES + 1):
        for j in range(SAMPLES + 1):
            y = y0 + (y1 - y0) * i / SAMPLES
            z = z0 + (z1 - z0) * j / SAMPLES
            hit = tree.ray_cast(Vector((1.0, y, z)), Vector((-1.0, 0.0, 0.0)))[0]
            if hit is not None and (best is None or hit.x > best):
                best = hit.x
    if best is None:
        raise SystemExit("[ammo_bar] %s: nothing under the span" % gun.name)
    return best


def placeholder_material():
    mat = bpy.data.materials.get("ammo_bar_glow") or bpy.data.materials.new("ammo_bar_glow")
    color = (1.0, 0.95, 0.6, 1.0)
    mat.diffuse_color = color  # the viewport/workbench colour
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    if bsdf:
        bsdf.inputs["Base Color"].default_value = color
        bsdf.inputs["Emission Color"].default_value = color
        bsdf.inputs["Emission Strength"].default_value = 1.0
    return mat


def build_bar(gun, span):
    y0, y1, z0, z1 = span
    outer = side_x(gun, y0, y1, z0, z1) + LIFT
    inner = outer - DEPTH
    length = y1 - y0
    verts = [(x, y, z) for x in (inner, outer) for y in (0.0, length) for z in (z0, z1)]
    faces = [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)]
    mesh = bpy.data.meshes.new(BAR)
    mesh.from_pydata(verts, [], faces)
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(mesh)
    bm.free()
    mesh.update()
    mesh.materials.append(placeholder_material())
    bar = bpy.data.objects.new(BAR, mesh)
    bpy.context.scene.collection.objects.link(bar)
    bar.parent = gun
    bar.location = (0.0, y0, 0.0)
    return outer


def main():
    for name, span in SPANS.items():
        path = os.path.abspath(os.path.join(OUT_DIR, name + ".blend"))
        bpy.ops.wm.open_mainfile(filepath=path)
        old = bpy.data.objects.get(BAR)
        if old is not None:
            bpy.data.objects.remove(old, do_unlink=True)
        outer = build_bar(bpy.data.objects[name], span)
        bpy.ops.wm.save_mainfile()
        print("[ammo_bar] %s: y %.3f..%.3f, face at x %.4f" % (name, span[0], span[1], outer))


main()
