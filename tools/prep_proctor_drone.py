"""Turns the WIP drone sculpt into the Proctor's export source.

    blender -b assets/sec_drone_v0.blend -P tools/prep_proctor_drone.py
    blender -b art_src/proctor_drone.blend -P tools/export_models.py -- --prop proctor

The WIP file (assets/sec_drone_v0.blend) is kitbashed from the Securus mesh and
sits at whatever angle it was modelled at. Rather than edit it in place, this
writes a SEPARATE file, art_src/proctor_drone.blend, that meets the static-prop
contract export_models.py's `--prop` path expects:

  * one mesh object named `proctor`, transforms applied, metres;
  * its centre (the body the drone tilts about) at the origin;
  * forward -- the lens face -- along Blender +Y, which is the game's -Z;
  * up along +Z;
  * an `eye` Empty at the lens, which UnitVisual lights green/orange/red
    from the unit's alert state (CerberusUnit.EYE_COLOR). Its scale is the
    lens size, since UnitVisual sizes the glow in the socket's own space.

Hover height and the tilt are NOT modelled: the game hangs the drone in the air
and tips it into its motion (UnitVisual's drone section), so the model is the
drone at rest, level, centred.

Rerun after editing the WIP file. Forward is found from the geometry -- the
body is the largest cylinder-ish part and the lens is its end FARTHEST from the
rest of the parts -- so a change that keeps that layout needs no edits here.
"""
import math
import os
import sys

import bmesh
import bpy
import numpy as np
from mathutils import Matrix, Vector

OUT = os.path.join("art_src", "proctor_drone.blend")
NAME = "proctor"
## Uniform scale applied on the way through. The sculpt is ~0.5 m across; the
## tactical camera wants a little more than that to read the silhouette.
SCALE = 1.3
## The glowing lens's radius as a fraction of the body's radius.
LENS_FRACTION = 0.45
## How far the lens centre sits back from the body's front face, as a fraction
## of the lens radius: a dome proud of the face, not a ball stuck on it.
LENS_SINK = 0.55
## UnitVisual.EYE_RADIUS -- the glow sphere's radius before the socket's scale.
EYE_RADIUS = 0.032


def components(bm):
    seen = set()
    out = []
    for v in bm.verts:
        if v.index in seen:
            continue
        stack = [v]
        comp = []
        seen.add(v.index)
        while stack:
            x = stack.pop()
            comp.append(x)
            for e in x.link_edges:
                y = e.other_vert(x)
                if y.index not in seen:
                    seen.add(y.index)
                    stack.append(y)
        out.append(comp)
    return out


def main():
    src = next((o for o in bpy.data.objects if o.type == "MESH" and o.visible_get()), None)
    if src is None:
        sys.exit("[prep_proctor_drone] no visible mesh in %s" % bpy.data.filepath)
    # Saved mid-edit: leaving edit mode flushes the edit mesh into the data,
    # which until then still holds whatever was there on entering it.
    if bpy.context.object is not None and bpy.context.object.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")
    for o in list(bpy.data.objects):
        if o is not src:
            bpy.data.objects.remove(o, do_unlink=True)
    src.name = NAME
    src.data.name = NAME

    # Bake the object transform into the vertices, so everything below is in
    # world metres.
    src.data.transform(src.matrix_world)
    src.matrix_world = Matrix.Identity(4)

    bm = bmesh.new()
    bm.from_mesh(src.data)
    bm.verts.ensure_lookup_table()
    # Stray vertices (no faces) left over from the kitbash: they export as
    # nothing but stretch the bounds every tool measures.
    loose = [v for v in bm.verts if not v.link_faces]
    bmesh.ops.delete(bm, geom=loose, context="VERTS")
    bm.verts.ensure_lookup_table()
    parts = [np.array([list(v.co) for v in c]) for c in components(bm)]
    if not parts:
        sys.exit("[prep_proctor_drone] mesh is empty")

    # The body: the fattest CYLINDER. A part is a cylinder when, about one of
    # its principal axes, every vertex sits at nearly the same radius; the
    # armour shells are bigger but nowhere near round, so they never qualify.
    def cylinder(p):
        cc = p.mean(0)
        _, _, axes = np.linalg.svd(p - cc)
        best = None
        for i in range(3):
            a = axes[i]
            off = (p - cc) - np.outer((p - cc) @ a, a)
            r = np.linalg.norm(off, axis=1)
            spread = float(r.std() / max(r.mean(), 1e-6))
            if best is None or spread < best[0]:
                best = (spread, a, float(r.mean()))
        return best
    cyls = [(p, *cylinder(p)) for p in parts if len(p) >= 8]
    round_parts = [t for t in cyls if t[1] < 0.15]
    if not round_parts:
        sys.exit("[prep_proctor_drone] no cylindrical body part found")
    body, _, axis, radius = max(round_parts, key=lambda t: t[3])
    c = body.mean(0)
    axis = axis / np.linalg.norm(axis)
    along = (body - c) @ axis
    # The lens is the end facing AWAY from everything else.
    rest = np.concatenate([p for p in parts if p is not body]) if len(parts) > 1 else body
    if float((rest.mean(0) - c) @ axis) > 0:
        axis = -axis
        along = -along
    # Flatten onto the deck plane: a drone at rest looks level, whatever tilt
    # the sculpt was left at.
    fwd = Vector((float(axis[0]), float(axis[1]), 0.0))
    if fwd.length < 1e-4:
        sys.exit("[prep_proctor_drone] body axis is vertical; cannot find forward")
    fwd.normalize()
    front = float(along.max())

    # Yaw forward onto +Y, centre the body on the origin, scale.
    yaw = math.atan2(fwd.x, fwd.y)  # angle from +Y, clockwise seen from above
    centre = Vector(c.tolist())
    xf = (Matrix.Scale(SCALE, 4) @ Matrix.Rotation(yaw, 4, "Z")
          @ Matrix.Translation(-centre))
    bmesh.ops.transform(bm, matrix=xf, verts=bm.verts)
    bm.to_mesh(src.data)
    bm.free()
    src.data.update()

    lens_r = radius * SCALE * LENS_FRACTION
    eye = bpy.data.objects.new("eye", None)
    src.users_collection[0].objects.link(eye)
    eye.empty_display_type = "SPHERE"
    eye.empty_display_size = lens_r
    eye.parent = src
    eye.location = (0.0, front * SCALE - lens_r * LENS_SINK, 0.0)
    eye.scale = (lens_r / EYE_RADIUS,) * 3

    for o in list(bpy.data.objects):
        if o.type in ("CAMERA", "LIGHT"):
            bpy.data.objects.remove(o, do_unlink=True)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(OUT), copy=True)
    lo = [min(v.co[i] for v in src.data.vertices) for i in range(3)]
    hi = [max(v.co[i] for v in src.data.vertices) for i in range(3)]
    print("[prep_proctor_drone] wrote %s: %d verts, bounds %s..%s, lens r=%.3f at y=%.3f"
          % (OUT, len(src.data.vertices), [round(x, 3) for x in lo],
             [round(x, 3) for x in hi], lens_r, eye.location.y))


main()
