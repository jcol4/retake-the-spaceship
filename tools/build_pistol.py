"""Builds the sidearm, art_src/guns/pistol.blend, from Poly Haven's Service Pistol.

  blender.exe -b -P tools/build_pistol.py -- <service_pistol_1k.gltf> [--variant b]

SOURCE: "Service Pistol" by Mateusz Sadek, Poly Haven, CC0
(https://polyhaven.com/a/service_pistol). Download the 1k glTF
(api.polyhaven.com/files/service_pistol -> gltf.1k, keeping its textures/ and
.bin beside it) and pass the .gltf. The asset ships two copies side by side:
`_a` with a plain worn grip (the default) and `_b` wrapped in blue tape.

Like tools/build_guns.py, this starts from art_src/guns/rifle.blend so the gun
keeps the rifle's `grip_support` and `muzzle_flash` objects, and swaps the
rifle's mesh for the pistol's. The .blend it writes is the pistol's SOURCE from
then on: hand edits there are kept unless this is re-run.

FITTING THE GRIP CONTRACT (gun space: +Y down the barrel, +Z up, origin = the
trigger hand; see tools/standardize_gun_mount.py)
-----------------------------------------------------------------------------
* The barrel stays on +Y: aim, muzzle flash and flashlight all read it.
* The pistol's web-of-hand point (top-back of the grip, under the tang) lands
  on the rifle grip's (build_guns.lower_group's back-top corner). That is where
  the trigger hand closes, so the pistol sits in the fist of every rifle pose
  the pistol falls back to. The rifle's grip is raked further back (~23 deg vs
  ~10), so the fingers cross the pistol grip slightly; pistol poses are posed
  on the pistol itself and do not care.
* `muzzle_flash` moves to the pistol's muzzle, keeping its rotation and scale.
* `grip_support` (the LEFT hand's IK target, a wrist position) moves to the
  left of and below the grip, for a two-handed hold where the support hand
  wraps the trigger hand. Its rotation is the rifle's: a starting point to set
  by hand while posing the first pistol action.
* Real size (0.22 m long) is kept; the long guns are real size too.
"""

import os
import sys

import bpy
from mathutils import Matrix, Vector

SOURCE = "art_src/guns/rifle.blend"
SOURCE_GUN = "rifle"
OUT = "art_src/guns/pistol.blend"
NAME = "pistol"
PARTS = ("pistol", "slide", "hammer", "trigger")

## Measured on the imported `_a` copy (Blender import space: +X down the
## barrel, +Z up). The `_b` copy is the same mesh 0.15 m higher in Z.
VARIANT_Z = {"a": 0.0, "b": 0.15}
PISTOL_WEB = Vector((-0.026, 0.020))     # (x, z): top-back of the grip
PISTOL_MUZZLE = Vector((0.174, 0.060))   # (x, z): barrel tip, on the bore
## Gun space (y, z): the rifle grip's back-top corner (build_guns.lower_group).
RIFLE_WEB = Vector((0.030, 0.004))
## Left wrist for a two-handed hold, gun space.
GRIP_SUPPORT = Vector((-0.075, 0.035, -0.060))


def import_variant(path, variant):
    """The variant's parts joined into one mesh, in gun space."""
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=os.path.abspath(path))
    imported = [o for o in bpy.data.objects if o not in before]
    keep = [o for o in imported if o.type == "MESH"
            and any(o.name == "service_pistol_%s_%s" % (p, variant) for p in PARTS)]
    if len(keep) != len(PARTS):
        sys.exit("[pistol] expected %d parts of variant %r, found %s"
                 % (len(PARTS), variant, [o.name for o in keep]))
    for o in imported:
        if o not in keep:
            bpy.data.objects.remove(o, do_unlink=True)

    # Import space -> gun space: +X (barrel) to +Y is +90 deg about Z; then
    # shift the web point onto the rifle's and drop the variant's Z offset.
    web = Vector((PISTOL_WEB.x, 0.0, PISTOL_WEB.y + VARIANT_Z[variant]))
    to_gun = (Matrix.Translation((0.0, RIFLE_WEB.x, RIFLE_WEB.y))
              @ Matrix.Rotation(1.5707963, 4, "Z")
              @ Matrix.Translation(-web))
    for o in keep:
        o.data = o.data.copy()
        o.data.transform(to_gun @ o.matrix_world)
        o.parent = None
        o.matrix_world = Matrix.Identity(4)

    bpy.ops.object.select_all(action="DESELECT")
    for o in keep:
        o.select_set(True)
    bpy.context.view_layer.objects.active = keep[0]
    bpy.ops.object.join()
    joined = bpy.context.view_layer.objects.active
    muzzle = to_gun @ Vector((PISTOL_MUZZLE.x, 0.0, PISTOL_MUZZLE.y + VARIANT_Z[variant]))
    return joined, muzzle


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if not argv:
        sys.exit(__doc__)
    variant = argv[argv.index("--variant") + 1] if "--variant" in argv else "a"

    bpy.ops.wm.open_mainfile(filepath=os.path.abspath(SOURCE))
    gun = bpy.data.objects[SOURCE_GUN]
    joined, muzzle_at = import_variant(argv[0], variant)

    old = gun.data
    gun.data = joined.data
    gun.data.name = NAME
    bpy.data.objects.remove(joined, do_unlink=True)
    bpy.data.meshes.remove(old)
    gun.name = NAME
    gun.modifiers.clear()  # the long guns' bevel is for their flat prisms

    muzzle = bpy.data.objects["muzzle_flash"]
    muzzle.location = muzzle_at
    support = bpy.data.objects["grip_support"]
    support.location = GRIP_SUPPORT

    for mat in list(bpy.data.materials):
        if mat.users == 0:
            bpy.data.materials.remove(mat)
    bpy.ops.outliner.orphans_purge(do_recursive=True)
    bpy.ops.file.pack_all()  # the textures travel with the .blend

    path = os.path.abspath(OUT)
    bpy.ops.wm.save_as_mainfile(filepath=path)
    co = [v.co for v in gun.data.vertices]
    lo = [round(min(c[i] for c in co), 3) for i in range(3)]
    hi = [round(max(c[i] for c in co), 3) for i in range(3)]
    print("[pistol] variant %s: %d faces, bounds %s..%s, muzzle %s -> %s"
          % (variant, len(gun.data.polygons), lo, hi,
             tuple(round(v, 3) for v in muzzle_at), path))


if __name__ == "__main__":
    main()
