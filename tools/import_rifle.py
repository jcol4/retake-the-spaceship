"""Convert art_src/RIfleLow.fbx into assets/rifle.glb, in the mount's conventions.

Replaces tools/gen_rifle.py as the source of assets/rifle.glb. That script stays
as the blockout it always was: it is still the fastest way to re-derive the
proportions from scratch if the rig changes, and this file is measured against
it below.

WHY A CUSTOM IMPORTER

The source is ASCII FBX 6100, which Blender's importer refuses outright ("ASCII
FBX files are not supported"). tools/fbx_ascii.py parses the handful of records
a static prop needs. There is no texture to recover -- the material points at a
Diffuse.psd on the original author's machine -- so materials are assigned here
by region instead.

CONVENTIONS (copied from gen_rifle.py; scripts/weapon_mount.gd assumes them)

  * Origin sits at the TRIGGER. The mount places this point in the right hand.
  * Barrel runs along Blender +Y, which the glTF exporter maps to -Z, Godot's
    forward. Up is Blender +Z, exported as Godot +Y.
  * `Muzzle` is an empty at the barrel tip, a SIBLING of the mesh under the GLB
    root, because character_base.tscn addresses it as RifleMount/rifle/Muzzle.

WHY THIS SCALE

The source model is 1.471 units end to end with no meaningful unit, and its
trigger is 1.008 units behind the muzzle. Scaling so that trigger-to-muzzle
matches the blockout's tuned 0.62 m gives s = 0.615, and every other landmark
then lands on the blockout's independently-tuned figures:

    feature       this model      gen_rifle.py
    pistol grip   -0.085..-0.014  -0.072..-0.008
    magazine      +0.073..+0.172  +0.036..+0.082
    stock butt    -0.285          -0.255

Two separately-derived numbers agreeing is the reason to trust the scale; a
bounding box alone would not have told us anything.

The support hand sits 0.400 m forward of the grip (the fixed anchor that
tools/build_anims.py now locks every clip onto), which on this model lands at
Y +0.400 -- mid-handguard, 0.220 m short of the muzzle. The blockout needed a
0.18-0.54 m handguard to absorb a gap that used to swing 0.320-0.468 m; that
variance is gone, so the only requirement left is that 0.400 m be ON the
handguard, and it is, with room either side.

Run headless:
    blender -b -P tools/import_rifle.py -- --export assets/rifle.glb
"""

import argparse
import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fbx_ascii

SOURCE = "art_src/RIfleLow.fbx"

# Trigger position in SOURCE space, read off the receiver underside: the gap
# between the magazine's rear face (-0.059) and the pistol grip's front (+0.083).
TRIGGER_Y = 0.060
GRIP_TO_MUZZLE = 0.62  # metres, matching gen_rifle.py so the mount stays tuned
SUPPORT_Y = 0.380  # where build_anims.py pins the left hand; see SPLICES

# Bands of Y removed to compact the weapon from 905 mm to roughly 745 mm.
#
# NOT a uniform scale, deliberately. Scaling shrinks the pistol grip and the
# magazine along with everything else, and those are the parts sized to a human
# hand -- the hand does not scale with them, so an 84% rifle reads as a toy and
# fights the finger wrap. Length has to come out of the parts a hand never
# touches.
#
# Both bands are chosen inside a CONSTANT cross-section run, measured by
# intersecting faces with the plane rather than binning vertices (a low-poly
# tube has vertices only at its ends, so a vertex histogram reports an empty gap
# exactly where the surface is):
#
#   handguard  Y +0.180..+0.580  constant 16.5 mm half-width, 66 mm tall
#   stock tube Y -0.285..-0.100  constant 18.3 mm half-width
#
# Because the section does not change across a band, closing the gap leaves no
# seam and no reshaping -- the two cut faces are identical. splice() verifies the
# band really is vertex-free and refuses otherwise, since collapsing a band that
# contained detail would silently flatten it.
#
# The receiver, pistol grip, magazine and trigger group are outside both bands
# and keep their exact dimensions.
# Both bands sit inside a measured vertex-free run, NOT merely inside the
# feature: the collapsible stock carries ridges along its length, and a first
# attempt at [-0.200,-0.160] straddled a vertex plane at -0.1965. The usable
# clear run there is -0.2574..-0.1965 (60.9 mm), so the cut is taken well inside
# it. Re-measure both if the source model is ever replaced.
SPLICES = [
    (0.250, 0.370),    # 120 mm out of the handguard: muzzle 0.620 -> 0.500
    (-0.250, -0.210),  # 40 mm out of the stock tube: butt -0.285 -> -0.245
]

# Same two materials as the blockout, and light for the same reason: a near-black
# weapon against an equally near-black character has no silhouette under the
# ship's dim lighting. See weapon-art-plan.md section 3.
MAT_METAL = ("Metal", (0.115, 0.120, 0.132, 1.0), 0.38, 0.90)
MAT_POLY = ("Polymer", (0.080, 0.081, 0.088, 1.0), 0.72, 0.00)


def log(msg):
    print(f"[import_rifle] {msg}")


def material(spec):
    name, colour, roughness, metallic = spec
    mat = bpy.data.materials.get(name)
    if mat:
        return mat
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = colour
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    return mat


def splice(objs, lo, hi):
    """Delete the Y band [lo, hi] and close the gap, keeping the trigger at 0.

    Everything on the far side of the band from the origin slides toward it by
    the band's width; everything between the origin and the band holds still.
    That keeps the trigger -- the point the mount places in the hand -- fixed,
    so shortening the weapon never invalidates the grip tuning.
    """
    amount = hi - lo
    behind = hi <= 0.0  # band sits between the trigger and the butt
    moved = 0
    inside = 0
    for o in objs:
        for v in o.data.vertices:
            y = v.co.y
            if behind:
                if y <= lo:
                    v.co.y = y + amount
                    moved += 1
                elif y < hi:
                    v.co.y = hi
                    inside += 1
            else:
                if y >= hi:
                    v.co.y = y - amount
                    moved += 1
                elif y > lo:
                    v.co.y = lo
                    inside += 1
    if inside:
        raise SystemExit(
            f"splice [{lo:+.3f},{hi:+.3f}] found {inside} vertices INSIDE the "
            f"band. That band is not a constant cross-section, so closing it "
            f"would flatten real detail into a plane. Move the band, or narrow "
            f"it, so it falls in a featureless run.")
    log(f"  spliced {amount*1000:.0f} mm out of "
        f"[{lo:+.3f},{hi:+.3f}] ({moved} verts moved, band was clean)")
    return amount


def is_polymer(name, centre):
    """Which parts read as furniture rather than as receiver and barrel.

    Region tests rather than an authored split, because the source is one
    material across two objects. Kept to the three features that are spatially
    isolated -- stock, pistol grip, magazine -- so a centroid cannot land in the
    wrong one. The handguard is left metal: on an AR-pattern rifle the full
    length rail genuinely is aluminium, and guessing at its boundary with the
    receiver would only produce a blotchy seam mid-weapon.
    """
    if name == "Cargador":  # the magazine, already its own object
        return True
    if centre.y < -0.13:  # stock, well behind everything else
        return True
    if -0.11 < centre.y < 0.005 and centre.z < -0.02:  # pistol grip
        return True
    return False


def build(out_path, source, smooth_angle):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    objs = fbx_ascii.to_blender(source)
    if not objs:
        raise SystemExit(f"no meshes parsed out of {source}")
    log(f"parsed {len(objs)} object(s): {[o.name for o in objs]}")

    # Source has the muzzle at -Y and the stock at +Y. A 180 degree turn about
    # the up axis is the correction -- and it is a rotation, not a mirror, so the
    # weapon stays right-handed and the ejection port stays on the shooter's
    # right. Mirroring in X would have looked identical here and been wrong.
    turn = Matrix.Rotation(math.radians(180), 4, "Z")
    for o in objs:
        o.matrix_world = turn @ o.matrix_world
        bpy.context.view_layer.objects.active = o
        o.select_set(True)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

    pts = [o.matrix_world @ v.co for o in objs for v in o.data.vertices]
    max_y = max(p.y for p in pts)
    # Muzzle face centre, not the bounding box corner: the tip is a ring of
    # vertices, and its centre is where a shot actually leaves.
    tip = [p for p in pts if p.y > max_y - 0.01]
    bore = Vector((sum(p.x for p in tip) / len(tip), max_y,
                   sum(p.z for p in tip) / len(tip)))
    log(f"muzzle face: {len(tip)} verts, centre "
        f"({bore.x:+.4f}, {bore.y:+.4f}, {bore.z:+.4f}) source units")

    trigger_y = -TRIGGER_Y  # the 180 degree turn negated it
    scale = GRIP_TO_MUZZLE / (bore.y - trigger_y)
    # Origin on the bore axis in X and Z, dropped below it by the same 0.022 m
    # the blockout used, so grip_offset in the scene keeps meaning what it did.
    origin = Vector((bore.x, trigger_y, bore.z - 0.022 / scale))
    log(f"scale {scale:.5f}  (source {bore.y - trigger_y:.4f} u -> "
        f"{GRIP_TO_MUZZLE:.3f} m trigger to muzzle)")

    place = Matrix.Scale(scale, 4) @ Matrix.Translation(-origin)
    for o in objs:
        o.matrix_world = place @ o.matrix_world
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

    # Compaction happens here, in final metres, BEFORE the material regions are
    # assigned: is_polymer() tests absolute Y, so it has to see the coordinates
    # the weapon actually ships with.
    for lo_y, hi_y in SPLICES:
        splice(objs, lo_y, hi_y)

    metal, poly = material(MAT_METAL), material(MAT_POLY)
    for o in objs:
        me = o.data
        me.materials.append(metal)
        me.materials.append(poly)
        for p in me.polygons:
            centre = Vector((0.0, 0.0, 0.0))
            for vi in p.vertices:
                centre += me.vertices[vi].co
            p.material_index = 1 if is_polymer(o.name, centre / len(p.vertices)) else 0

    bpy.ops.object.join()
    rifle = bpy.context.active_object
    rifle.name = "Rifle"
    # Source normals are not parsed, so shading is flat out of the box. That is
    # right for the receiver and wrong for the barrel; an angle split gets both.
    bpy.ops.object.shade_auto_smooth(angle=math.radians(smooth_angle))

    # Muzzle read back off the finished mesh rather than from GRIP_TO_MUZZLE.
    # The splices move the barrel tip, so the constant is now the length BEFORE
    # compaction and using it here would leave the muzzle -- and the shots and
    # light that come off it -- floating 120 mm past the end of the barrel. This
    # is the same staleness that screenshot.gd had baked in.
    fv = [rifle.matrix_world @ v.co for v in rifle.data.vertices]
    tip_y = max(p.y for p in fv)
    tip = [p for p in fv if p.y > tip_y - 0.006]
    muzzle = Vector((sum(p.x for p in tip) / len(tip), tip_y,
                     sum(p.z for p in tip) / len(tip)))
    bpy.ops.object.empty_add(type="PLAIN_AXES", radius=0.02, location=muzzle)
    bpy.context.active_object.name = "Muzzle"

    lo = Vector([min((rifle.matrix_world @ v.co)[i] for v in rifle.data.vertices)
                 for i in range(3)])
    hi = Vector([max((rifle.matrix_world @ v.co)[i] for v in rifle.data.vertices)
                 for i in range(3)])
    tris = sum(len(p.vertices) - 2 for p in rifle.data.polygons)
    poly_tris = sum(len(p.vertices) - 2 for p in rifle.data.polygons
                    if p.material_index == 1)
    log(f"built {len(rifle.data.vertices)} verts / {tris} tris "
        f"({poly_tris} polymer, {tris - poly_tris} metal)")
    log(f"  overall length  : {hi.y - lo.y:.3f} m "
        f"(Y {lo.y:+.3f} .. {hi.y:+.3f}, trigger at 0)")
    log(f"  width / height  : {hi.x - lo.x:.3f} / {hi.z - lo.z:.3f} m")
    log(f"  grip -> muzzle  : {muzzle.y:.3f} m "
        f"(was {GRIP_TO_MUZZLE:.3f} before compaction)")
    log(f"  support hand at : Y {SUPPORT_Y:+.3f} m, "
        f"{muzzle.y - SUPPORT_Y:.3f} m short of the muzzle")
    log(f"  MUZZLE (blender): ({muzzle.x:.3f}, {muzzle.y:.3f}, {muzzle.z:.3f})")
    log(f"  MUZZLE (godot)  : ({muzzle.x:.3f}, {muzzle.z:.3f}, {-muzzle.y:.3f})")
    # The support hand is pinned by the animation, so compaction slides it
    # FORWARD relative to the mesh. Past the handguard it would grip bare
    # barrel, which is the one way these cuts can go wrong silently.
    ahead = muzzle.y - SUPPORT_Y
    if ahead < 0.05:
        log(f"  WARNING: only {ahead*1000:.0f} mm of weapon ahead of the support "
            f"hand -- it is at or past the muzzle. Cut less, or move SUPPORT_OFFSET.")

    bpy.ops.export_scene.gltf(filepath=out_path, export_format="GLB",
                              export_animations=False)
    log(f"exported {out_path}")


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--source", default=SOURCE)
    p.add_argument("--export", default="assets/rifle.glb")
    p.add_argument("--smooth-angle", type=float, default=35.0)
    args = p.parse_args(argv)
    build(args.export, args.source, args.smooth_angle)


if __name__ == "__main__":
    main()
