"""Generate a blockout rifle sized to this rig's hands, and export it to GLB.

Deliberately featureless. The job is not to look like a gun, it is to give the
hands something correctly proportioned to hold, so the weapon mount can be
judged against real geometry instead of against a stand-in that is the wrong
length. Detail comes later, on top of proportions that are already right.

WHY THESE DIMENSIONS

Measured off the character with tools/_debug_facing.gd, the distance from the
right hand to the left hand is:

    aim_hold     0.468 m
    crouch_idle  0.345 m
    run          0.334 m
    idle         0.320 m

The old rifle was 0.455 m from grip to muzzle, so in the aim pose the support
hand landed 13 mm PAST the muzzle -- holding thin air just beyond the barrel.

A rigid weapon cannot pin both hands when the gap swings 0.32-0.47 m, so the fix
is not one magic length: it is a HANDGUARD LONG ENOUGH TO ABSORB THE VARIANCE.
This one runs 0.18-0.54 m forward of the grip, which contains every measured gap
with margin at both ends. The support hand slides along it between clips, which
is exactly what a real support hand does.

CONVENTIONS (both load-bearing -- scripts/weapon_mount.gd assumes them)

  * Origin sits at the TRIGGER, not the stock butt or the mesh centre. The mount
    places this point in the right hand.
  * Barrel runs along Blender +Y, which the glTF exporter maps to -Z, Godot's
    forward. Up is Blender +Z, exported as Godot +Y.

Run headless:
    blender -b -P tools/gen_rifle.py -- --export assets/rifle.glb
"""

import argparse
import os
import sys

import bpy

# All measurements in metres, in Blender space, relative to the trigger.
# +Y is down the barrel, +Z is up out of the sights, +X is the weapon's right.
GRIP_TO_MUZZLE = 0.62
HANDGUARD = (0.18, 0.54)  # contains every measured hand gap, 0.320-0.468
MUZZLE = (0.0, GRIP_TO_MUZZLE, 0.022)

# Lighter than the reference kit deliberately. This is a blockout whose whole
# purpose is being LOOKED at against the body while the mount is tuned, and at
# near-black it disappears into an equally near-black character under the ship's
# deliberately dim lighting. Darken it once the proportions are settled.
MAT_METAL = ("Metal", (0.115, 0.120, 0.132, 1.0), 0.38, 0.90)
MAT_POLY = ("Polymer", (0.080, 0.081, 0.088, 1.0), 0.72, 0.00)

# name, (x0,x1), (y0,y1), (z0,z1), material
PARTS = [
    # Receiver: the block the whole weapon hangs off, spanning the trigger.
    ("Receiver", (-0.022, 0.022), (-0.060, 0.190), (-0.008, 0.048), MAT_METAL),
    # Stock, running back behind the grip to the shoulder.
    ("StockTube", (-0.014, 0.014), (-0.150, -0.055), (0.006, 0.034), MAT_METAL),
    ("StockPad", (-0.021, 0.021), (-0.255, -0.150), (-0.004, 0.044), MAT_POLY),
    # Pistol grip, below and behind the trigger.
    ("Grip", (-0.019, 0.019), (-0.072, -0.008), (-0.145, -0.006), MAT_POLY),
    # Trigger guard, the loop the trigger finger sits in.
    ("GuardFront", (-0.013, 0.013), (0.012, 0.026), (-0.052, -0.008), MAT_METAL),
    ("GuardUnder", (-0.013, 0.013), (-0.020, 0.026), (-0.062, -0.046), MAT_METAL),
    # Magazine, angled forward out of the receiver.
    ("Magazine", (-0.016, 0.016), (0.036, 0.082), (-0.190, -0.006), MAT_POLY),
    # Handguard -- the part that actually matters. See the header.
    ("Handguard", (-0.024, 0.024), HANDGUARD, (-0.004, 0.044), MAT_POLY),
    # Barrel beyond the handguard, out to the muzzle.
    ("Barrel", (-0.011, 0.011), (HANDGUARD[1], GRIP_TO_MUZZLE), (0.011, 0.033), MAT_METAL),
    # Sight rail along the top. Carries no sights, but it establishes which way
    # is up at a glance, which is the whole reason to look at a blockout.
    ("Rail", (-0.013, 0.013), (-0.040, 0.300), (0.048, 0.060), MAT_METAL),
]


def log(msg):
    print(f"[gen_rifle] {msg}")


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


def box(name, xs, ys, zs, mat_spec):
    bpy.ops.mesh.primitive_cube_add(size=1.0)
    obj = bpy.context.active_object
    obj.name = name
    obj.scale = ((xs[1] - xs[0]) / 2.0, (ys[1] - ys[0]) / 2.0, (zs[1] - zs[0]) / 2.0)
    obj.location = ((xs[0] + xs[1]) / 2.0, (ys[0] + ys[1]) / 2.0, (zs[0] + zs[1]) / 2.0)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    obj.data.materials.append(material(mat_spec))
    return obj


def build(out_path, bevel):
    bpy.ops.wm.read_factory_settings(use_empty=True)

    parts = [box(*p) for p in PARTS]
    for obj in parts:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = parts[0]
    bpy.ops.object.join()
    rifle = bpy.context.active_object
    rifle.name = "Rifle"

    if bevel > 0.0:
        # A hard 90-degree edge is the signature of programmer art: a chamfer
        # catches a highlight line, and at this camera distance those lines are
        # most of what the eye actually resolves.
        mod = rifle.modifiers.new("Bevel", "BEVEL")
        mod.width = bevel
        mod.segments = 2
        mod.limit_method = "ANGLE"
        mod.angle_limit = 0.5236  # 30 degrees
        bpy.ops.object.modifier_apply(modifier=mod.name)

    # Muzzle as an exported empty rather than a number copied into the scene:
    # where a shot leaves the weapon is a property OF the weapon, so it should
    # travel with the model instead of being duplicated in character_base.tscn
    # and silently going stale the next time the barrel length changes.
    # Left at scene top level, not parented to the mesh, so it lands as a
    # sibling of Rifle under the GLB root -- the layout the scene expects.
    bpy.ops.object.empty_add(type="PLAIN_AXES", radius=0.02, location=MUZZLE)
    bpy.context.active_object.name = "Muzzle"

    verts = len(rifle.data.vertices)
    tris = sum(len(p.vertices) - 2 for p in rifle.data.polygons)
    log(f"built {verts} verts / {tris} tris")
    log(f"  grip -> muzzle : {GRIP_TO_MUZZLE:.3f} m")
    log(f"  handguard span : {HANDGUARD[0]:.3f} - {HANDGUARD[1]:.3f} m")
    log(f"  hand gaps covered: idle 0.320, run 0.334, crouch 0.345, aim 0.468")
    log(f"  MUZZLE (blender) : {MUZZLE}")
    log(f"  MUZZLE (godot)   : ({MUZZLE[0]}, {MUZZLE[2]}, {-MUZZLE[1]})")

    bpy.ops.export_scene.gltf(filepath=out_path, export_format="GLB",
                              export_animations=False)
    log(f"exported {out_path}")


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--export", default="assets/rifle.glb")
    p.add_argument("--bevel", type=float, default=0.0025)
    args = p.parse_args(argv)
    build(args.export, args.bevel)


if __name__ == "__main__":
    main()
